extends RefCounted
## M8-02 rule-bank loans: one-time bank capital, fixed-fee fixed-term contracts,
## full repayment and a deterministic overdue sweep. Pure rules: no clock, disk,
## scene or network access.
##
## Cash authority stays on the existing balances (ADR-014). `economy.bank.cash`
## is the bank's real cash and `economy.accounts[borrower].cash` the borrower's.
## A contract is a durable business row, not a second wallet. Every cash move
## posts one balanced journal entry:
##
##   bank_open    debit  bank             credit issuance
##   loan_issue   debit  account:<who>    credit bank
##   loan_repay   debit  bank             credit account:<who>
##
## The fee is a fixed percentage of the principal, charged once at repayment and
## kept by the bank. It never grows with time, so a year offline cannot compound
## a debt. Overdue only changes the contract status; it does not add fees,
## seize assets, write off principal or create a second collection path.
##
## A loan id is its borrow command id. A contract row therefore also makes
## borrowing idempotent after the bounded command window evicts the original
## result. Repayment stores its accepted command id on the contract for the same
## reason; the repaid status alone already prevents a second debit.

const Ledger = preload("res://farm/ledger_state.gd")
const OwnerIds = preload("res://farm/owner_id.gd")

const WORLD_OWNER: String = "@world"
const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_COMMAND_ID_LENGTH: int = 128
const MAX_PAYLOAD_LENGTH: int = 512
const MAX_COMMAND_RESULTS: int = 64

## Experiment bounds. Principal range is deliberately small enough that the
## 2000 COIN bank can fund more than one borrower.
const MIN_PRINCIPAL: int = 10
const MAX_PRINCIPAL: int = 1000
const FEE_PERCENT: int = 5
## Fixed 7, 14 and 30 day terms. A quote never accepts an unlisted term.
const TERMS: Array[int] = [604800, 1209600, 2592000]
const MAX_LOANS: int = 256

const STATUS_OPEN: String = "open"
const STATUS_OVERDUE: String = "overdue"
const STATUS_REPAID: String = "repaid"
const STATUSES: Array[String] = [STATUS_OPEN, STATUS_OVERDUE, STATUS_REPAID]

const CONTRACT_KEYS: Array[String] = [
	"id", "borrower", "principal", "fee", "term", "due_utc", "opened_utc",
	"status", "paid", "repaid_utc", "repay_id",
]


static func initial_state() -> Dictionary:
	return {}


static func fee_for(principal: int) -> int:
	# Ceiling of 5%, at least one COIN. Integer arithmetic keeps the quote exact.
	return maxi(1, (principal * FEE_PERCENT + 99) / 100)


## Pure quote. `now_utc` moves the due date but never the fee.
static func quote(principal: Variant, term: Variant, now_utc: float = 0.0) -> Dictionary:
	if not _is_bounded_principal(principal):
		return _quote_error("invalid_principal")
	if not _is_term(term):
		return _quote_error("invalid_term")
	if not _valid_time(now_utc):
		return _quote_error("invalid_time")
	var fee: int = fee_for(int(principal))
	var total: int = int(principal) + fee
	var due_utc: float = float(now_utc) + float(int(term))
	if not _is_count(total) or due_utc > float(MAX_SAFE_INTEGER):
		return _quote_error("invalid_due")
	return {
		"ok": true, "reason": "", "principal": int(principal), "fee": fee,
		"total": total, "term": int(term), "due_utc": due_utc,
	}


## Checks everything that does not depend on the command id. A replay must be
## resolved before this runs because the accepted loan itself makes the borrower
## active.
static func validate_borrow(economy: Dictionary, borrower: String, principal: Variant,
		term: Variant, now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return _quote_error("invalid_time")
	if not _valid_borrower(borrower):
		return _quote_error("invalid_borrower")
	var quoted: Dictionary = quote(principal, term, now_utc)
	if not quoted.ok:
		return quoted
	var accounts: Variant = economy.get("accounts")
	var account: Variant = accounts.get(borrower) if accounts is Dictionary else null
	if not account is Dictionary:
		return _quote_error("unknown_account")
	if not bool(account.get("granted", false)):
		return _quote_error("account_not_open")
	if not _bank_open(economy):
		return _quote_error("bank_closed")
	if _bank_cash(economy) < int(quoted.principal):
		return _quote_error("bank_insufficient")
	if not active_loan(economy, borrower).is_empty():
		return _quote_error("loan_active")
	var loans: Variant = economy.get("loans")
	if loans is Dictionary and loans.size() >= MAX_LOANS:
		return _quote_error("loan_limit")
	return quoted


static func borrow(economy: Dictionary, borrower: String, principal: Variant, term: Variant,
		command_id: String, now_utc: float) -> Dictionary:
	if not _valid_command_id(command_id):
		return _loan_error("invalid_command")
	if not _valid_time(now_utc):
		return _loan_error("invalid_time")
	var quoted: Dictionary = quote(principal, term, now_utc)
	if not quoted.ok:
		return _loan_error(str(quoted.reason))
	var payload: String = _borrow_payload(borrower, int(principal), int(term), now_utc)
	var replayed: Dictionary = _replay(economy, command_id, payload)
	if not replayed.is_empty():
		return _replay_borrow(economy, command_id, replayed)
	# The contract table is the durable guard: the bounded command window can
	# evict the first result, but the loan row remains.
	var existing: Variant = null
	if economy.get("loans") is Dictionary:
		existing = economy.loans.get(command_id)
	if existing is Dictionary:
		var durable: Dictionary = existing
		if str(durable.borrower) != borrower or int(durable.principal) != int(principal) \
				or _contract_term(durable) != int(term):
			return _loan_error("command_conflict")
		return _borrow_success(durable, true)
	# A repayment command id is a durable guard too; reusing one as a new loan
	# id would make the same id mean two different things.
	if _is_repay_id(economy, command_id):
		return _loan_error("command_conflict")
	var checked: Dictionary = validate_borrow(economy, borrower, principal, term, now_utc)
	if not checked.ok:
		return _loan_error(str(checked.reason))
	var ledger: Variant = economy.get("ledger")
	if not ledger is Dictionary:
		return _loan_error("invalid_ledger")
	var posted: Dictionary = Ledger.post(ledger, Ledger.KIND_LOAN_ISSUE, command_id, now_utc, [
		Ledger.debit_line(Ledger.owner_code(borrower), int(checked.principal)),
		Ledger.credit_line(Ledger.BANK, int(checked.principal)),
	])
	if not posted.ok:
		return _loan_error(str(posted.reason))
	var contract: Dictionary = {
		"id": command_id, "borrower": borrower, "principal": int(checked.principal),
		"fee": int(checked.fee), "term": int(checked.term),
		"due_utc": float(checked.due_utc), "opened_utc": float(now_utc),
		"status": STATUS_OPEN, "paid": 0, "repaid_utc": 0.0, "repay_id": "",
	}
	economy.bank.cash = int(economy.bank.cash) - int(checked.principal)
	economy.accounts[borrower].cash = int(economy.accounts[borrower].cash) + int(checked.principal)
	if not economy.get("loans") is Dictionary:
		economy.loans = {}
	economy.loans[command_id] = contract
	_record(economy, command_id, payload,
		{"ok": true, "reason": "", "amount": int(checked.principal)})
	return _borrow_success(contract, false)


static func repay(economy: Dictionary, borrower: String, loan_id: String, command_id: String,
		now_utc: float) -> Dictionary:
	if not _valid_command_id(command_id) or not _valid_command_id(loan_id):
		return _loan_error("invalid_command")
	if not _valid_time(now_utc):
		return _loan_error("invalid_time")
	if not _valid_borrower(borrower):
		return _loan_error("invalid_borrower")
	var payload: String = _repay_payload(borrower, loan_id, now_utc)
	var replayed: Dictionary = _replay(economy, command_id, payload)
	if not replayed.is_empty():
		return _replay_repay(economy, loan_id, replayed)
	var loans: Variant = economy.get("loans")
	if not loans is Dictionary:
		return _loan_error("loan_not_found")
	# A contract carries the accepted repayment id, so a second charge cannot be
	# produced after the command window evicts the first result.
	for contract_id: Variant in loans:
		var candidate: Variant = loans[contract_id]
		if candidate is Dictionary and str(candidate.get("repay_id", "")) == command_id:
			if str(contract_id) != loan_id:
				return _loan_error("command_conflict")
			if str(candidate.borrower) != borrower:
				return _loan_error("not_borrower")
			var matched: Dictionary = candidate
			return _repay_success(matched, true)
	# A loan id is a durable borrow guard; a repayment may not reuse it.
	if loans.has(command_id):
		return _loan_error("command_conflict")
	var stored: Dictionary = {}
	if loans.get(loan_id) is Dictionary:
		stored = loans[loan_id]
	if stored.is_empty():
		return _loan_error("loan_not_found")
	if str(stored.borrower) != borrower:
		return _loan_error("not_borrower")
	if str(stored.status) == STATUS_REPAID:
		return _loan_error("already_repaid")
	if now_utc < float(stored.opened_utc):
		return _loan_error("invalid_time")
	var total: int = int(stored.principal) + int(stored.fee)
	if not _is_count(total):
		return _loan_error("invalid_amount")
	var account: Variant = economy.accounts.get(borrower) \
		if economy.get("accounts") is Dictionary else null
	if not account is Dictionary:
		return _loan_error("unknown_account")
	if int(account.cash) < total:
		return _loan_error("insufficient")
	var ledger: Variant = economy.get("ledger")
	if not ledger is Dictionary:
		return _loan_error("invalid_ledger")
	var posted: Dictionary = Ledger.post(ledger, Ledger.KIND_LOAN_REPAY, command_id, now_utc, [
		Ledger.debit_line(Ledger.BANK, total),
		Ledger.credit_line(Ledger.owner_code(borrower), total),
	])
	if not posted.ok:
		return _loan_error(str(posted.reason))
	economy.bank.cash = int(economy.bank.cash) + total
	account.cash = int(account.cash) - total
	stored.status = STATUS_REPAID
	stored.paid = total
	stored.repaid_utc = float(now_utc)
	stored.repay_id = command_id
	_record(economy, command_id, payload, {"ok": true, "reason": "", "amount": total})
	return _repay_success(stored, false)


## Deterministic authority sweep. Every unpaid contract whose due time has
## arrived becomes overdue. No entry, no fee, no asset movement: the contract
## status is the whole effect, so repeated sweeps and long offline gaps are
## safe.
static func settle(economy: Dictionary, now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return {"ok": false, "reason": "invalid_time", "count": 0, "overdue": []}
	var loans: Variant = economy.get("loans")
	if not loans is Dictionary:
		return {"ok": true, "reason": "", "count": 0, "overdue": []}
	var ids: Array = []
	for loan_id: Variant in loans:
		ids.append(str(loan_id))
	ids.sort()
	var newly_overdue: Array = []
	for loan_id: String in ids:
		var contract: Variant = loans[loan_id]
		if not contract is Dictionary:
			continue
		if str(contract.status) == STATUS_OPEN and float(contract.due_utc) <= now_utc:
			contract.status = STATUS_OVERDUE
			newly_overdue.append(loan_id)
	return {
		"ok": true, "reason": "", "count": newly_overdue.size(),
		"overdue": newly_overdue,
	}


static func _is_repay_id(economy: Dictionary, command_id: String) -> bool:
	var loans: Variant = economy.get("loans")
	if not loans is Dictionary:
		return false
	for contract: Variant in loans.values():
		if contract is Dictionary and str(contract.get("repay_id", "")) == command_id:
			return true
	return false


static func active_loan(economy: Dictionary, borrower: String) -> Dictionary:
	var loans: Variant = economy.get("loans")
	if not loans is Dictionary:
		return {}
	for loan_id: Variant in loans:
		var contract: Variant = loans[loan_id]
		if contract is Dictionary and str(contract.borrower) == borrower \
				and str(contract.status) in [STATUS_OPEN, STATUS_OVERDUE]:
			return contract.duplicate(true)
	return {}


## Principal still owed by open and overdue contracts. This is the bank's real
## loan asset; repaid contracts are not claims any more.
static func outstanding_principal(economy: Dictionary) -> int:
	var loans: Variant = economy.get("loans")
	if not loans is Dictionary:
		return 0
	var total: int = 0
	for contract: Variant in loans.values():
		if contract is Dictionary and str(contract.status) != STATUS_REPAID:
			total += int(contract.principal)
			if not _is_count(total):
				return 0
	return total


## Fees already kept by the bank. With no other bank cash path, this makes
## `bank.cash == capital - outstanding principal + collected fees` exact.
static func collected_fees(economy: Dictionary) -> int:
	var loans: Variant = economy.get("loans")
	if not loans is Dictionary:
		return 0
	var total: int = 0
	for contract: Variant in loans.values():
		if contract is Dictionary and str(contract.status) == STATUS_REPAID:
			total += int(contract.fee)
			if not _is_count(total):
				return 0
	return total


static func contracts(economy: Dictionary) -> Array:
	var loans: Variant = economy.get("loans")
	if not loans is Dictionary:
		return []
	var ids: Array = []
	for loan_id: Variant in loans:
		ids.append(str(loan_id))
	ids.sort()
	var result: Array = []
	for loan_id: String in ids:
		var contract: Variant = loans[loan_id]
		if contract is Dictionary:
			result.append(contract.duplicate(true))
	return result


static func valid(loans: Variant) -> bool:
	if not loans is Dictionary or loans.size() > MAX_LOANS:
		return false
	var active_borrowers: Dictionary = {}
	var repay_commands: Dictionary = {}
	var asset_total: int = 0
	for loan_id: Variant in loans:
		var contract: Variant = loans[loan_id]
		if not _valid_contract(loan_id, contract):
			return false
		if str(contract.status) != STATUS_REPAID:
			if active_borrowers.has(str(contract.borrower)):
				return false
			active_borrowers[str(contract.borrower)] = true
			asset_total += int(contract.principal)
			if not _is_count(asset_total):
				return false
		var repay_id: String = str(contract.repay_id)
		if not repay_id.is_empty():
			# Contract ids and repayment ids share one command namespace. Letting
			# them overlap would make a replayed id resolve to two different
			# durable guards depending on which table is consulted first.
			if repay_commands.has(repay_id) or loans.has(repay_id):
				return false
			repay_commands[repay_id] = true
	return true


static func normalize(loans: Dictionary) -> void:
	for loan_id: String in loans:
		var contract: Dictionary = loans[loan_id]
		for key: String in ["principal", "fee", "paid", "term"]:
			contract[key] = int(contract[key])
		for key: String in ["due_utc", "opened_utc", "repaid_utc"]:
			contract[key] = float(contract[key])


static func _valid_contract(loan_id: Variant, value: Variant) -> bool:
	if not value is Dictionary or value.size() != CONTRACT_KEYS.size():
		return false
	for key: String in CONTRACT_KEYS:
		if not value.has(key):
			return false
	if not _valid_command_id(loan_id) or not str(value.id) == str(loan_id):
		return false
	if not _valid_borrower(value.borrower):
		return false
	if not _is_bounded_principal(value.principal):
		return false
	var principal: int = int(value.principal)
	if not _is_count(value.fee) or int(value.fee) != fee_for(principal):
		return false
	if not _valid_time(value.opened_utc) or not _valid_time(value.due_utc):
		return false
	# The term is stored, not re-derived from the float difference: epoch-sized
	# doubles lose sub-second precision at power-of-two boundaries, and a
	# difference that rounds would make a valid contract unloadable. The due
	# time must still be exactly the same expression `quote()` produced.
	if not _is_count(value.term) or int(value.term) not in TERMS:
		return false
	if float(value.due_utc) != float(value.opened_utc) + float(int(value.term)):
		return false
	if not value.status is String or str(value.status) not in STATUSES:
		return false
	if not _is_count(value.paid):
		return false
	var total: int = principal + int(value.fee)
	if str(value.status) == STATUS_REPAID:
		if int(value.paid) != total:
			return false
		if not _valid_time(value.repaid_utc) or float(value.repaid_utc) < float(value.opened_utc):
			return false
		if not _valid_command_id(value.repay_id):
			return false
	else:
		if int(value.paid) != 0 or float(value.repaid_utc) != 0.0:
			return false
		if not value.repay_id is String or not str(value.repay_id).is_empty():
			return false
	return true


static func _contract_term(value: Dictionary) -> int:
	return int(value.term) if _is_count(value.get("term")) else -1


static func _borrow_success(contract: Dictionary, duplicate: bool) -> Dictionary:
	var total: int = int(contract.principal) + int(contract.fee)
	return {
		"ok": true, "reason": "", "amount": int(contract.principal),
		"fee": int(contract.fee), "total": total, "due_utc": float(contract.due_utc),
		"duplicate": duplicate,
	}


static func _repay_success(contract: Dictionary, duplicate: bool) -> Dictionary:
	var total: int = int(contract.principal) + int(contract.fee)
	return {
		"ok": true, "reason": "", "amount": total, "fee": int(contract.fee),
		"total": total, "due_utc": float(contract.due_utc), "duplicate": duplicate,
	}


static func _replay_borrow(economy: Dictionary, command_id: String, replayed: Dictionary) -> Dictionary:
	var existing: Variant = null
	if economy.get("loans") is Dictionary:
		existing = economy.loans.get(command_id)
	var result: Dictionary = {
		"ok": bool(replayed.ok), "reason": str(replayed.reason),
		"amount": int(replayed.amount), "fee": 0, "total": 0, "due_utc": 0.0,
		"duplicate": true,
	}
	if existing is Dictionary:
		var total: int = int(existing.principal) + int(existing.fee)
		result.fee = int(existing.fee)
		result.total = total
		result.due_utc = float(existing.due_utc)
	return result


static func _replay_repay(economy: Dictionary, loan_id: String, replayed: Dictionary) -> Dictionary:
	var existing: Variant = null
	if economy.get("loans") is Dictionary:
		existing = economy.loans.get(loan_id)
	var result: Dictionary = {
		"ok": bool(replayed.ok), "reason": str(replayed.reason),
		"amount": int(replayed.amount), "fee": 0, "total": 0, "due_utc": 0.0,
		"duplicate": true,
	}
	if existing is Dictionary:
		result.fee = int(existing.fee)
		result.total = int(existing.principal) + int(existing.fee)
		result.due_utc = float(existing.due_utc)
	return result


static func _borrow_payload(borrower: String, principal: int, term: int, now_utc: float) -> String:
	return JSON.stringify(["loan_borrow", borrower, principal, term, float(now_utc)])


static func _repay_payload(borrower: String, loan_id: String, now_utc: float) -> String:
	return JSON.stringify(["loan_repay", borrower, loan_id, float(now_utc)])


static func _replay(state: Dictionary, command_id: String, payload: String) -> Dictionary:
	var results: Variant = state.get("command_results")
	if not results is Dictionary or not results.has(command_id):
		return {}
	var entry: Variant = results[command_id]
	if not entry is Dictionary or str(entry.get("payload", "")) != payload:
		return {"ok": false, "reason": "command_conflict", "amount": 0}
	var result: Variant = entry.get("result")
	if not result is Dictionary:
		return {}
	return {
		"ok": bool(result.get("ok", false)), "reason": str(result.get("reason", "")),
		"amount": int(result.get("amount", 0)),
	}


static func _record(state: Dictionary, command_id: String, payload: String,
		result: Dictionary) -> void:
	state.sequence = int(state.sequence) + 1
	state.command_results[command_id] = {"payload": payload, "result": result}
	while state.command_results.size() > MAX_COMMAND_RESULTS:
		state.command_results.erase(state.command_results.keys()[0])


static func _bank_open(economy: Dictionary) -> bool:
	var bank: Variant = economy.get("bank")
	return bank is Dictionary and bool(bank.get("opened", false))


static func _bank_cash(economy: Dictionary) -> int:
	var bank: Variant = economy.get("bank")
	return int(bank.get("cash", 0)) if bank is Dictionary else 0


static func _valid_borrower(value: Variant) -> bool:
	return value is String and str(value) != WORLD_OWNER and OwnerIds.valid(value)


static func _is_bounded_principal(value: Variant) -> bool:
	return _is_count(value) and int(value) >= MIN_PRINCIPAL and int(value) <= MAX_PRINCIPAL


static func _is_term(value: Variant) -> bool:
	return _is_count(value) and int(value) in TERMS


static func _is_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)


static func _valid_command_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_COMMAND_ID_LENGTH \
		and not Ledger.reserved_event_id(str(value)) \
		and not Ledger.internal_event_id(str(value))


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


static func _quote_error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


static func _loan_error(reason: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "amount": 0, "fee": 0, "total": 0,
		"due_utc": 0.0, "duplicate": false,
	}
