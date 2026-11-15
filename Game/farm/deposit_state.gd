extends RefCounted
## M8 bank deposits: player principal held by the rule bank, with a full-cash
## withdrawal rule and a named refusal when the bank cannot back a payout. Pure
## rules: no clock, disk, scene or network access; every time comes from the
## caller.
##
## A deposit is a liability, not a second wallet. Cash authority stays on the
## existing balances (ADR-014): a deposit moves real cash from the player's
## account to `economy.bank.cash`, and the bank owes the principal back. The
## deposit document only records that debt:
##
##   economy.deposits = {
##     accounts: {<player_id>: {principal: int, deposited_utc: float}},
##   }
##
## Every deposit and withdrawal posts one balanced journal entry, so
## `total_cash` and `issued` never change:
##
##   deposit_in    debit  bank             credit account:<player>
##   deposit_out   debit  account:<player> credit bank
##
## The bank cash equation from ADR-017 gains the deposit liability:
##
##   bank.cash == capital - outstanding principal + collected fees + deposits
##
## Interest is deliberately absent (ADR-017 forbids compounding, and this slice
## is principal only). A rate would turn a deposit into a growing payout
## obligation with its own funding, maturity and accrual rules; none of that is
## in scope. `deposited_utc` is informational and records the most recent
## accepted deposit, so callers can show when the balance last moved.
##
## Withdrawal pays only what the bank really holds: `bank.cash >= amount` or the
## command is refused with `insufficient_reserve`. This is not a rate limiter.
## The bank may have lent part of the deposits out, so cash can run out; paying
## each accepted withdrawal in full, in whatever order they arrive, protects the
## remaining depositors' claims instead of overdrawing the bank and leaving
## everybody's debt unbacked. A percentage reserve floor would permanently lock
## the last slice of deposits and is therefore not used. The report can show
## `covered=false`, which means exactly that some claims cannot be paid from
## bank cash right now.
##
## Replay guard: command ids use the economy's shared bounded
## `command_results` window, exactly like loans and payments. Deposits have no
## durable per-command business row (a principal row cannot tell a 50 COIN
## deposit from a 90 COIN one), so the window is the guard and the live
## journal's unique `event_id` is a secondary one while the entry is retained.
## After the window and the journal both evict the event, an old deposit id
## could move cash again; the same boundary is documented for `pay` (ADR-014
## §6.1). The authority/network wiring must add a durable guard before deposits
## are exposed to clients.

const Ledger = preload("res://farm/ledger_state.gd")
const OwnerIds = preload("res://farm/owner_id.gd")

const WORLD_OWNER: String = "@world"
const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_COMMAND_ID_LENGTH: int = 128
const MAX_PAYLOAD_LENGTH: int = 512
const MAX_COMMAND_RESULTS: int = 64

## Experiment bounds, on the same scale as loans (10..1000 COIN). A minimum of
## 10 keeps dust rows out of the deposit table; a single deposit mirrors the
## loan principal ceiling. One account may hold at most one bank capital's
## worth, so no single depositor can claim more than the bank was ever given.
const MIN_DEPOSIT: int = 10
const MAX_DEPOSIT: int = 1000
## One account may hold at most one maximum-size deposit, so no single
## depositor can hold a claim larger than a whole loan principal and the
## deposit table stays on the same scale as the loan table.
const MAX_PRINCIPAL: int = MAX_DEPOSIT
const MAX_DEPOSIT_ACCOUNTS: int = 256

const STATE_KEYS: Array[String] = ["accounts"]
const ACCOUNT_KEYS: Array[String] = ["principal", "deposited_utc"]


static func initial_state() -> Dictionary:
	return {"accounts": {}}


## Principal owed to one player. A missing table or row is a zero claim.
static func principal(document: Variant, player: String) -> int:
	if not document is Dictionary:
		return 0
	var accounts: Variant = document.get("accounts")
	if not accounts is Dictionary or not accounts.get(player) is Dictionary:
		return 0
	var row: Dictionary = accounts[player]
	return int(row.get("principal", 0)) if _is_count(row.get("principal")) else 0


## Total deposit liability. This is the `claims` side of the reserve report and
## the last term of the bank cash equation; it is derived from the account rows,
## never stored a second time.
static func liability(document: Variant) -> int:
	if not document is Dictionary:
		return 0
	var accounts: Variant = document.get("accounts")
	if not accounts is Dictionary:
		return 0
	var total: int = 0
	for row: Variant in accounts.values():
		if row is Dictionary and _is_count(row.get("principal")):
			total += int(row.principal)
			if not _is_count(total):
				return 0
	return total


static func account_count(document: Variant) -> int:
	if not document is Dictionary or not document.get("accounts") is Dictionary:
		return 0
	return document.accounts.size()


## Moves cash from the player's account into the bank and records the claim.
## Returns a copy-on-write candidate economy in `document`; the input document is
## never modified and a refusal returns no candidate.
static func deposit(economy: Dictionary, player: String, amount: Variant, command_id: String,
		now_utc: float) -> Dictionary:
	if not _valid_command_id(command_id):
		return _error("invalid_command")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	if not _valid_player(player):
		return _error("invalid_player")
	if not _valid_deposit_amount(amount):
		return _error("invalid_amount")
	var count: int = int(amount)
	var document: Dictionary = _document(economy)
	if not valid(document):
		return _error("invalid_deposits")
	var payload: String = JSON.stringify(["deposit", player, count])
	var replayed: Dictionary = _replay(economy, player, command_id, payload)
	if not replayed.is_empty():
		return replayed
	if not _bank_open(economy):
		return _error("not_open")
	if not economy.get("ledger") is Dictionary:
		return _error("invalid_ledger")
	# The live journal is the second replay guard. It is checked before balances
	# so the answer does not depend on whether the player still has the cash.
	if _journal_event_used(economy, command_id):
		return _error("duplicate_event")
	var account: Variant = economy.accounts.get(player) \
		if economy.get("accounts") is Dictionary else null
	if not account is Dictionary:
		return _error("unknown_account")
	if not document.accounts.has(player) \
			and document.accounts.size() >= MAX_DEPOSIT_ACCOUNTS:
		return _error("deposit_capacity")
	if principal(document, player) + count > MAX_PRINCIPAL:
		return _error("deposit_capacity")
	if int(account.cash) < count:
		return _error("insufficient")
	var candidate: Dictionary = economy.duplicate(true)
	if not candidate.get("deposits") is Dictionary:
		candidate.deposits = initial_state()
	var posted: Dictionary = Ledger.post(candidate.ledger, Ledger.KIND_DEPOSIT_IN, command_id,
		now_utc, [
			Ledger.debit_line(Ledger.BANK, count),
			Ledger.credit_line(Ledger.owner_code(player), count),
		])
	if not posted.ok:
		return _error(str(posted.reason))
	candidate.bank.cash = int(candidate.bank.cash) + count
	candidate.accounts[player].cash = int(candidate.accounts[player].cash) - count
	if candidate.deposits.accounts.get(player) is Dictionary:
		var row: Dictionary = candidate.deposits.accounts[player]
		row.principal = int(row.principal) + count
		row.deposited_utc = float(now_utc)
	else:
		candidate.deposits.accounts[player] = {
			"principal": count, "deposited_utc": float(now_utc),
		}
	_record(candidate, command_id, payload, {"ok": true, "reason": "", "amount": count})
	# `document` is the whole candidate economy, not only the deposit subdocument:
	# the cash moved through the bank and account authorities, so the caller must
	# commit the complete candidate. It is never the input object.
	return {
		"ok": true, "reason": "", "amount": count, "duplicate": false,
		"principal": principal(candidate.deposits, player), "document": candidate,
	}


## Pays a claim back from the bank's real cash. Every accepted withdrawal is
## fully backed; the bank never pays out cash it does not hold. A zero-principal
## row is removed, so the table only carries live claims.
static func withdraw(economy: Dictionary, player: String, amount: Variant, command_id: String,
		now_utc: float) -> Dictionary:
	if not _valid_command_id(command_id):
		return _error("invalid_command")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	if not _valid_player(player):
		return _error("invalid_player")
	if not _valid_withdraw_amount(amount):
		return _error("invalid_amount")
	var count: int = int(amount)
	var document: Dictionary = _document(economy)
	if not valid(document):
		return _error("invalid_deposits")
	var payload: String = JSON.stringify(["withdraw", player, count])
	var replayed: Dictionary = _replay(economy, player, command_id, payload)
	if not replayed.is_empty():
		return replayed
	if not _bank_open(economy):
		return _error("not_open")
	if not economy.get("ledger") is Dictionary:
		return _error("invalid_ledger")
	if _journal_event_used(economy, command_id):
		return _error("duplicate_event")
	var account: Variant = economy.accounts.get(player) \
		if economy.get("accounts") is Dictionary else null
	if not account is Dictionary:
		return _error("unknown_account")
	var current: int = principal(document, player)
	if not document.accounts.has(player) or count > current:
		return _error("insufficient")
	if int(economy.bank.cash) < count:
		# The bank cannot back this payout. Refusing keeps the depositor's whole
		# claim intact instead of overdrawing the bank for one early withdrawal.
		return _error("insufficient_reserve")
	var candidate: Dictionary = economy.duplicate(true)
	var posted: Dictionary = Ledger.post(candidate.ledger, Ledger.KIND_DEPOSIT_OUT, command_id,
		now_utc, [
			Ledger.debit_line(Ledger.owner_code(player), count),
			Ledger.credit_line(Ledger.BANK, count),
		])
	if not posted.ok:
		return _error(str(posted.reason))
	candidate.bank.cash = int(candidate.bank.cash) - count
	candidate.accounts[player].cash = int(candidate.accounts[player].cash) + count
	var row: Dictionary = candidate.deposits.accounts[player]
	row.principal = int(row.principal) - count
	if int(row.principal) == 0:
		candidate.deposits.accounts.erase(player)
	_record(candidate, command_id, payload, {"ok": true, "reason": "", "amount": count})
	return {
		"ok": true, "reason": "", "amount": count, "duplicate": false,
		"principal": principal(candidate.deposits, player), "document": candidate,
	}


## Strict shape check for the deposit subdocument. A legacy economy without the
## key is admitted by `Economy.valid` and restores as this empty shape, so this
## validator is only ever asked about a present table.
static func valid(document: Variant) -> bool:
	if not document is Dictionary or document.size() != STATE_KEYS.size():
		return false
	for key: String in STATE_KEYS:
		if not document.has(key):
			return false
	if not document.accounts is Dictionary \
			or document.accounts.size() > MAX_DEPOSIT_ACCOUNTS:
		return false
	var total: int = 0
	for player: Variant in document.accounts:
		var row: Variant = document.accounts[player]
		if not _valid_player(player):
			return false
		if not row is Dictionary or row.size() != ACCOUNT_KEYS.size():
			return false
		for key: String in ACCOUNT_KEYS:
			if not row.has(key):
				return false
		if not _is_count(row.principal) or int(row.principal) < 1 \
				or int(row.principal) > MAX_PRINCIPAL:
			return false
		if not _valid_time(row.deposited_utc):
			return false
		total += int(row.principal)
		if not _is_count(total):
			return false
	return true


## Restores JSON numbers to their canonical types. A missing key is the economy
## owner's concern (`Economy.normalize_ledger` adds the empty shape).
static func normalize(document: Dictionary) -> void:
	if not document.get("accounts") is Dictionary:
		return
	for player: Variant in document.accounts:
		var row: Variant = document.accounts[player]
		if not row is Dictionary:
			continue
		row.principal = int(row.principal)
		row.deposited_utc = float(row.deposited_utc)


static func _document(economy: Dictionary) -> Dictionary:
	var stored: Variant = economy.get("deposits")
	return stored if stored is Dictionary else initial_state()


## Shares `economy.command_results` with payments, loans and market commands, so
## a command id means one thing across the economy. Same payload/result shapes
## as `loan_state` keep `Economy._valid_results` exact.
static func _replay(economy: Dictionary, player: String, command_id: String,
		payload: String) -> Dictionary:
	var results: Variant = economy.get("command_results")
	if not results is Dictionary or not results.has(command_id):
		return {}
	var entry: Variant = results[command_id]
	if not entry is Dictionary or str(entry.get("payload", "")) != payload:
		return _error("command_conflict")
	var result: Variant = entry.get("result")
	if not result is Dictionary:
		return {}
	return {
		"ok": bool(result.get("ok", false)), "reason": str(result.get("reason", "")),
		"amount": int(result.get("amount", 0)), "duplicate": true,
		"principal": principal(_document(economy), player), "document": {},
	}


static func _record(economy: Dictionary, command_id: String, payload: String,
		result: Dictionary) -> void:
	economy.sequence = int(economy.sequence) + 1
	if not economy.get("command_results") is Dictionary:
		economy.command_results = {}
	economy.command_results[command_id] = {"payload": payload, "result": result}
	while economy.command_results.size() > MAX_COMMAND_RESULTS:
		economy.command_results.erase(economy.command_results.keys()[0])


static func _bank_open(economy: Dictionary) -> bool:
	var bank: Variant = economy.get("bank")
	return bank is Dictionary and bool(bank.get("opened", false))


static func _journal_event_used(economy: Dictionary, command_id: String) -> bool:
	var ledger: Variant = economy.get("ledger")
	if not ledger is Dictionary or not ledger.get("entries") is Dictionary:
		return false
	for entry_id: Variant in ledger.entries:
		var entry: Variant = ledger.entries[entry_id]
		if entry is Dictionary and str(entry.get("event_id", "")) == command_id:
			return true
	return false


## A depositor is a player account. `@world` is not a player, and organization
## cash accounts must keep their balance equal to the public fund document, so
## moving that cash into the bank out of band is refused.
static func _valid_player(value: Variant) -> bool:
	return value is String and str(value) != WORLD_OWNER \
		and not OwnerIds.is_organization_account(value) and OwnerIds.valid(value)


static func _valid_deposit_amount(value: Variant) -> bool:
	return _is_count(value) and int(value) >= MIN_DEPOSIT and int(value) <= MAX_DEPOSIT


## A withdrawal may take any positive part of the principal, including the
## whole balance in one command. A minimum here would leave a remainder smaller
## than the minimum permanently stuck.
static func _valid_withdraw_amount(value: Variant) -> bool:
	return _is_count(value) and int(value) >= 1 and int(value) <= MAX_PRINCIPAL


static func _is_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)


static func _valid_command_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_COMMAND_ID_LENGTH \
		and not Ledger.reserved_event_id(str(value))


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


static func _error(reason: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "amount": 0, "duplicate": false,
		"principal": 0, "document": {},
	}
