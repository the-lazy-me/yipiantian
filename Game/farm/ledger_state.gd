extends RefCounted
## M8-01 double-entry journal over the existing cash accounts. Pure rules: no
## clock, disk, scene or network access.
##
## Balances stay authoritative in `economy.accounts`, the merchant cash row and
## open buy-order escrow. This module never replaces them: it records one
## balanced journal entry per business event and keeps a compact per-account
## balance checkpoint for reconciliation. A journal entry is evidence, not a
## second wallet.
##
## Chart of accounts:
##   account:<owner>  a player cash account (the same integer as `cash`)
##   merchant         the rule merchant's cash row
##   escrow           cash held by open buy orders
##   bank             the rule bank's cash row (`economy.bank.cash`)
##   issuance         credit-side equity for money created by a grant, budget
##                    or the bank's one-time capital
##   burn             debit-side expense for money destroyed as a fee
##
## Signed balances are debit-positive. Every entry has equal debit and credit
## totals, so the sum of all checkpoint balances stays zero. Cash accounts sum
## to `total_cash`, `issuance` is a negative credit balance and `burn` a
## positive debit balance; therefore `total_cash == issuance - burned`, which
## is exactly the ADR-012 net-issue quantity `issued`.
##
## The live journal is bounded. Evicting the lowest sequence never changes a
## checkpoint balance, so reconciliation and the zero-sum identity survive.
## `opening` is a reconciliation baseline, not audit evidence: without the
## evicted entries, the gross `issuance` and `burn` checkpoint amounts can be
## shifted against each other while their sum and every cash balance stay
## exact. Read `economy.issued` for the authoritative net figure and never
## present the two system balances as a historical issuance report.
## Idempotency is not derived from this journal either: commands replay from
## the bounded command window or a durable business row, and a replayed command
## never reaches `post`.

const OwnerIds = preload("res://farm/owner_id.gd")

const MAX_SAFE_INTEGER: int = 9007199254740991
## Experiment bound: each trade, paid command and fee is one entry. A valid
## world can exceed this over time, so the oldest entries are evicted while the
## balance checkpoint keeps reconciliation exact.
const MAX_ENTRIES: int = 512
## A trade is the widest business event: buyer refund, seller credit, fee burn
## and one escrow credit. Four lines bound the stored entry size.
const MAX_LINES: int = 4
const MAX_EVENT_ID_LENGTH: int = 160
const ENTRY_ID_PREFIX: String = "ledger_"
## System-generated event ids use these namespaces. A user command id may not
## start with one: otherwise a crafted command id could collide with a trade or
## expiry event and permanently block that sweep through `event_id` uniqueness.
const RESERVED_EVENT_PREFIXES: Array[String] = [
	"trade_", "expire_", "merchant_quote_",
]

const WORLD_OWNER: String = "@world"
const MERCHANT: String = "merchant"
const ESCROW: String = "escrow"
const ISSUANCE: String = "issuance"
const BURN: String = "burn"
## M8-02 system bank cash. It is a real cash holder like the merchant, not a
## player account, so it has its own code instead of `account:bank`.
const BANK: String = "bank"
const ACCOUNT_PREFIX: String = "account:"
const SYSTEM_ACCOUNTS: Array[String] = [MERCHANT, ESCROW, ISSUANCE, BURN, BANK]

const KIND_OPEN_ACCOUNT: String = "open_account"
const KIND_PAY: String = "pay"
const KIND_MERCHANT_BUDGET: String = "merchant_budget"
const KIND_ESCROW_HOLD: String = "escrow_hold"
const KIND_ESCROW_RELEASE: String = "escrow_release"
const KIND_TRADE: String = "trade"
const KIND_SHIPPING_FEE: String = "shipping_fee"
const KIND_BANK_OPEN: String = "bank_open"
const KIND_LOAN_ISSUE: String = "loan_issue"
const KIND_LOAN_REPAY: String = "loan_repay"
const KINDS: Array[String] = [
	KIND_OPEN_ACCOUNT, KIND_PAY, KIND_MERCHANT_BUDGET, KIND_ESCROW_HOLD,
	KIND_ESCROW_RELEASE, KIND_TRADE, KIND_SHIPPING_FEE, KIND_BANK_OPEN,
	KIND_LOAN_ISSUE, KIND_LOAN_REPAY,
]

const STATE_KEYS: Array[String] = ["sequence", "entries", "balances", "opening"]
const ENTRY_KEYS: Array[String] = [
	"id", "sequence", "kind", "event_id", "at_utc", "debit", "credit", "lines",
]
const LINE_KEYS: Array[String] = ["account", "debit", "credit"]


static func initial_state() -> Dictionary:
	return {"sequence": 0, "entries": {}, "balances": {}, "opening": {}}


static func owner_code(owner: String) -> String:
	return ACCOUNT_PREFIX + owner


static func is_account_code(value: Variant) -> bool:
	return value is String and str(value).begins_with(ACCOUNT_PREFIX)


static func owner_from_code(value: String) -> String:
	return value.substr(ACCOUNT_PREFIX.length())


## `@world` is the public inventory owner. `@merchant` is not a player id and
## has its own system account, so `account:@merchant` is not accepted here.
static func valid_account_code(value: Variant) -> bool:
	if not value is String:
		return false
	var code: String = str(value)
	if code in SYSTEM_ACCOUNTS:
		return true
	if not code.begins_with(ACCOUNT_PREFIX):
		return false
	var owner: String = owner_from_code(code)
	return owner == WORLD_OWNER or OwnerIds.valid(owner)


static func line(account: String, debit: int, credit: int) -> Dictionary:
	return {"account": account, "debit": debit, "credit": credit}


static func debit_line(account: String, amount: int) -> Dictionary:
	return line(account, amount, 0)


static func credit_line(account: String, amount: int) -> Dictionary:
	return line(account, 0, amount)


static func valid(state: Variant) -> bool:
	if not state is Dictionary:
		return false
	# A ledger written before `opening` existed restores as if it had been
	# derived from the checkpoint minus its live entries. Every other size is
	# exact, so an unknown key still cannot slip in.
	var legacy_opening: bool = not state.has("opening")
	var expected_size: int = STATE_KEYS.size() - (1 if legacy_opening else 0)
	if state.size() != expected_size:
		return false
	for key: String in STATE_KEYS:
		if key == "opening" and legacy_opening:
			continue
		if not state.has(key):
			return false
	if not _is_count(state.sequence) or int(state.sequence) >= MAX_SAFE_INTEGER:
		return false
	if not state.entries is Dictionary or state.entries.size() > MAX_ENTRIES:
		return false
	if not state.balances is Dictionary:
		return false
	var balance_total: int = 0
	for code: Variant in state.balances:
		if not valid_account_code(code):
			return false
		if not _is_signed_count(state.balances[code]):
			return false
		balance_total += int(state.balances[code])
		if not _is_signed_count(balance_total):
			return false
	# Equal debits and credits in every entry are what keep this zero.
	if balance_total != 0:
		return false
	var sequences: Dictionary = {}
	var event_ids: Dictionary = {}
	var active_net: Dictionary = {}
	for entry_id: Variant in state.entries:
		var entry_value: Variant = state.entries[entry_id]
		if not _valid_entry(entry_id, entry_value, int(state.sequence)):
			return false
		var sequence: int = int(entry_value.sequence)
		if sequences.has(sequence):
			return false
		sequences[sequence] = true
		# Two live entries with one event id make event-based evidence
		# ambiguous, so they are refused even when both are balanced.
		var event_id: String = str(entry_value.event_id)
		if event_ids.has(event_id):
			return false
		event_ids[event_id] = true
		for raw_line: Variant in entry_value.lines:
			# A live entry may only reference a checkpoint balance that exists.
			if not state.balances.has(raw_line.account):
				return false
			var code: String = str(raw_line.account)
			var net: int = int(active_net.get(code, 0)) + int(raw_line.debit) \
				- int(raw_line.credit)
			if not _is_signed_count(net):
				return false
			active_net[code] = net
	var opening: Dictionary = {}
	if legacy_opening:
		for code: Variant in state.balances:
			var derived: int = int(state.balances[code]) - int(active_net.get(str(code), 0))
			if not _is_signed_count(derived):
				return false
			opening[str(code)] = derived
	else:
		if not state.opening is Dictionary:
			return false
		var opening_total: int = 0
		for code: Variant in state.opening:
			if not valid_account_code(code) or not state.balances.has(code):
				return false
			if not _is_signed_count(state.opening[code]):
				return false
			opening_total += int(state.opening[code])
			if not _is_signed_count(opening_total):
				return false
			opening[str(code)] = int(state.opening[code])
		if opening_total != 0:
			return false
	# balances[code] == opening[code] + the live entries' net on that code.
	var codes: Dictionary = {}
	for code: Variant in state.balances:
		codes[str(code)] = true
	for code: Variant in active_net:
		codes[str(code)] = true
	for code: Variant in opening:
		codes[str(code)] = true
	for code: Variant in codes:
		var expected: int = int(opening.get(str(code), 0)) + int(active_net.get(str(code), 0))
		if not _is_signed_count(expected) \
				or int(state.balances.get(str(code), 0)) != expected:
			return false
	return true


## Appends one balanced entry and updates the checkpoint on the caller's
## candidate. All validation happens before any mutation, so a refusal leaves
## the ledger untouched.
static func post(ledger: Dictionary, kind: String, event_id: String, at_utc: float,
		raw_lines: Array) -> Dictionary:
	if not valid(ledger):
		return _error("invalid_ledger")
	if not kind in KINDS:
		return _error("invalid_kind")
	if not _valid_event_id(event_id):
		return _error("invalid_event")
	if not _valid_time(at_utc):
		return _error("invalid_time")
	for candidate_id: Variant in ledger.entries:
		if str(ledger.entries[candidate_id].event_id) == event_id:
			return _error("duplicate_event")
	if raw_lines.size() < 2 or raw_lines.size() > MAX_LINES:
		return _error("invalid_lines")
	var lines: Array = []
	var seen: Dictionary = {}
	var debit_total: int = 0
	var credit_total: int = 0
	for raw: Variant in raw_lines:
		if not raw is Dictionary or raw.size() != LINE_KEYS.size():
			return _error("invalid_lines")
		var account: Variant = raw.get("account")
		if not valid_account_code(account) or seen.has(account):
			return _error("invalid_account")
		seen[account] = true
		var debit: Variant = raw.get("debit", 0)
		var credit: Variant = raw.get("credit", 0)
		if not _is_count(debit) or not _is_count(credit):
			return _error("invalid_amount")
		var debit_amount: int = int(debit)
		var credit_amount: int = int(credit)
		# A line carries exactly one side; zero/zero and split lines are refused.
		if (debit_amount > 0) == (credit_amount > 0):
			return _error("invalid_amount")
		debit_total += debit_amount
		credit_total += credit_amount
		if not _is_count(debit_total) or not _is_count(credit_total):
			return _error("invalid_amount")
		lines.append({"account": str(account), "debit": debit_amount, "credit": credit_amount})
	if debit_total != credit_total or debit_total <= 0:
		return _error("unbalanced")
	var sequence: int = int(ledger.sequence) + 1
	if not _is_count(sequence) or sequence >= MAX_SAFE_INTEGER:
		return _error("ledger_limit")
	# Compute every balance first so an overflow cannot leave a half-applied
	# checkpoint behind.
	var updates: Dictionary = {}
	for raw_line: Dictionary in lines:
		var code: String = str(raw_line.account)
		var current: int = int(ledger.balances.get(code, 0))
		var next: int = current + int(raw_line.debit) - int(raw_line.credit)
		if not _is_signed_count(next):
			return _error("invalid_amount")
		updates[code] = next
	var entry_id: String = ENTRY_ID_PREFIX + str(sequence)
	var entry: Dictionary = {
		"id": entry_id,
		"sequence": sequence,
		"kind": kind,
		"event_id": event_id,
		"at_utc": float(at_utc),
		"debit": debit_total,
		"credit": credit_total,
		"lines": lines,
	}
	# A ledger written before `opening` existed is upgraded on the caller's
	# candidate only once every refusal above has been ruled out. Derivation is
	# deterministic for a ledger that passed validation.
	if not ledger.get("opening") is Dictionary:
		_derive_opening(ledger)
	# Plan any evictions before mutating, so an overflow cannot leave a ledger
	# whose opening and balances disagree. Evicting one entry moves its signed
	# net into `opening`; the checkpoint therefore still describes all history.
	var opening_updates: Dictionary = {}
	var evicted_ids: Array[String] = []
	var projected: int = ledger.entries.size() + 1
	if projected > MAX_ENTRIES:
		var would_evict: int = projected - MAX_ENTRIES
		var oldest: Array = []
		for candidate_id: Variant in ledger.entries:
			oldest.append(ledger.entries[candidate_id])
		oldest.sort_custom(_entry_before)
		for index: int in would_evict:
			var removed: Dictionary = oldest[index]
			evicted_ids.append(str(removed.id))
			for raw_line: Dictionary in removed.lines:
				var code: String = str(raw_line.account)
				var base: int = int(opening_updates.get(code, ledger.opening.get(code, 0)))
				var next: int = base + int(raw_line.debit) - int(raw_line.credit)
				if not _is_signed_count(next):
					return _error("invalid_amount")
				opening_updates[code] = next
	ledger.sequence = sequence
	for code: String in updates:
		ledger.balances[code] = int(updates[code])
	for code: String in opening_updates:
		ledger.opening[code] = int(opening_updates[code])
	for evicted_id: String in evicted_ids:
		ledger.entries.erase(evicted_id)
	ledger.entries[entry_id] = entry
	return {"ok": true, "reason": "", "id": entry_id, "sequence": sequence}


static func entries(state: Dictionary) -> Array:
	var result: Array = []
	if not state.get("entries") is Dictionary:
		return result
	result.assign(state.entries.values())
	result.sort_custom(_entry_before)
	var copies: Array = []
	for entry: Variant in result:
		copies.append(entry.duplicate(true))
	return copies


static func reserved_event_id(value: String) -> bool:
	for prefix: String in RESERVED_EVENT_PREFIXES:
		if value.begins_with(prefix):
			return true
	return false


static func entry(state: Dictionary, entry_id: String) -> Dictionary:
	var stored: Variant = state.get("entries", {}).get(entry_id) if state.get("entries") is Dictionary else null
	return stored.duplicate(true) if stored is Dictionary else {}


static func balance(state: Dictionary, code: String) -> int:
	if not state.get("balances") is Dictionary:
		return 0
	var value: Variant = state.balances.get(code, 0)
	return int(value) if (value is int or value is float) else 0


## Converts JSON numbers back to GDScript integers and floats. Absent optional
## subdocuments are defaulted by the economy owner before this runs.
static func normalize(state: Dictionary) -> void:
	state.sequence = int(state.sequence)
	# A ledger restored from before the `opening` subfield gets the one-time
	# derivation described by the invariant. It is a read-time shape fill, not a
	# migration file and not a rewrite of the checkpoint.
	if not state.get("opening") is Dictionary:
		_derive_opening(state)
	for entry_id: String in state.entries:
		var entry: Dictionary = state.entries[entry_id]
		entry.sequence = int(entry.sequence)
		entry.debit = int(entry.debit)
		entry.credit = int(entry.credit)
		entry.at_utc = float(entry.at_utc)
		for raw_line: Dictionary in entry.lines:
			raw_line.debit = int(raw_line.debit)
			raw_line.credit = int(raw_line.credit)
	for code: String in state.balances:
		state.balances[code] = int(state.balances[code])
	for code: String in state.opening:
		state.opening[code] = int(state.opening[code])


## opening = balances - sum(live entry nets). Only called on a structurally valid
## ledger (restore or `post`), where this exactly describes the history that the
## bounded log no longer holds.
static func _derive_opening(state: Dictionary) -> void:
	var opening: Dictionary = {}
	if state.get("balances") is Dictionary:
		for code: Variant in state.balances:
			opening[str(code)] = int(state.balances[code])
	if state.get("entries") is Dictionary:
		for entry_id: Variant in state.entries:
			var entry: Variant = state.entries[entry_id]
			if not entry is Dictionary or not entry.get("lines") is Array:
				continue
			for raw_line: Variant in entry.lines:
				if not raw_line is Dictionary:
					continue
				var code: String = str(raw_line.get("account", ""))
				opening[code] = int(opening.get(code, 0)) - int(raw_line.get("debit", 0)) \
					+ int(raw_line.get("credit", 0))
	state.opening = opening


static func _valid_entry(entry_id: Variant, value: Variant, ledger_sequence: int) -> bool:
	if not value is Dictionary or value.size() != ENTRY_KEYS.size():
		return false
	for key: String in ENTRY_KEYS:
		if not value.has(key):
			return false
	if not entry_id is String or not str(value.id) == str(entry_id):
		return false
	if not _is_count(value.sequence) or int(value.sequence) <= 0 \
			or int(value.sequence) > ledger_sequence:
		return false
	if str(value.id) != ENTRY_ID_PREFIX + str(int(value.sequence)):
		return false
	if not value.kind is String or str(value.kind) not in KINDS:
		return false
	if not _valid_event_id(value.event_id) or not _valid_time(value.at_utc):
		return false
	if not _is_count(value.debit) or not _is_count(value.credit):
		return false
	var debit_total: int = int(value.debit)
	var credit_total: int = int(value.credit)
	if debit_total <= 0 or debit_total != credit_total:
		return false
	if not value.lines is Array or value.lines.size() < 2 or value.lines.size() > MAX_LINES:
		return false
	var seen: Dictionary = {}
	var line_debit: int = 0
	var line_credit: int = 0
	for raw: Variant in value.lines:
		if not raw is Dictionary or raw.size() != LINE_KEYS.size():
			return false
		var code: Variant = raw.get("account")
		if not valid_account_code(code) or seen.has(code):
			return false
		seen[code] = true
		if not _is_count(raw.get("debit")) or not _is_count(raw.get("credit")):
			return false
		var debit_amount: int = int(raw.debit)
		var credit_amount: int = int(raw.credit)
		if (debit_amount > 0) == (credit_amount > 0):
			return false
		line_debit += debit_amount
		line_credit += credit_amount
		if not _is_count(line_debit) or not _is_count(line_credit):
			return false
	return line_debit == debit_total and line_credit == credit_total


static func _entry_before(a: Variant, b: Variant) -> bool:
	var left: Dictionary = a
	var right: Dictionary = b
	if int(left.sequence) != int(right.sequence):
		return int(left.sequence) < int(right.sequence)
	return str(left.id) < str(right.id)


static func _valid_event_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_EVENT_ID_LENGTH


static func _is_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)


static func _is_signed_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and absf(number) <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


static func _error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "id": "", "sequence": 0}
