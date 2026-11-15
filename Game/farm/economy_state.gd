extends RefCounted
## M7-01 economy ledger and cash accounts. Pure rules: no clock, disk or scene.
##
## The farm snapshot owns this table. Goods stay in the existing player bags and
## public inventory (ADR-005); this module owns cash, the one-time demo
## conversion audit and the idempotent ledger for its own commands.
##
## Every command carries a durable id. A replay returns the recorded result and
## changes nothing. The ledger is a bounded window like the farm command ledger,
## so the two operations that must never repeat even after eviction also keep a
## durable marker: `accounts[owner].granted` and the single `conversion` record.

const Catalog = preload("res://farm/economy_catalog.gd")
const OwnerIds = preload("res://farm/owner_id.gd")
const Market = preload("res://farm/market_state.gd")
const Ledger = preload("res://farm/ledger_state.gd")

const WORLD_OWNER: String = "@world"
const CURRENCY: String = Catalog.CURRENCY
## Experiment value: enough to join a few trades, not enough to skip a harvest.
const OPENING_GRANT: int = 120
const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_COMMAND_ID_LENGTH: int = 128
const MAX_PAYLOAD_LENGTH: int = 512
const MAX_COMMAND_RESULTS: int = 64
const STATE_KEYS: Array[String] = [
	"currency", "sequence", "issued", "accounts", "conversion", "command_results", "market",
	"ledger",
]


static func initial_state() -> Dictionary:
	return {
		"currency": CURRENCY,
		"sequence": 0,
		"issued": 0,
		"accounts": {},
		"conversion": {},
		"command_results": {},
		"market": Market.initial_state(),
		"ledger": Ledger.initial_state(),
	}


static func valid_owner(value: Variant) -> bool:
	# `@world` is the public inventory's owner and is not a legal player id, so
	# no member can occupy the same account key.
	return value is String and (value == WORLD_OWNER or OwnerIds.valid(value))


static func valid(state: Variant) -> bool:
	if not state is Dictionary:
		return false
	# An M7-01 economy document has no `market` and an M7 economy has no
	# `ledger`; both restore as the empty shape they would have had instead of
	# requiring a migration. Every other key stays mandatory.
	var legacy_market: bool = not state.has("market")
	var legacy_ledger: bool = not state.has("ledger")
	var expected_size: int = STATE_KEYS.size() - (1 if legacy_market else 0) \
		- (1 if legacy_ledger else 0)
	if state.size() != expected_size:
		return false
	for key: String in STATE_KEYS:
		if key == "market" and legacy_market:
			continue
		if key == "ledger" and legacy_ledger:
			continue
		if not state.has(key):
			return false
	if state.currency != CURRENCY:
		return false
	if not _is_count(state.sequence) or int(state.sequence) >= MAX_SAFE_INTEGER \
			or not _is_count(state.issued):
		return false
	if not state.accounts is Dictionary or not state.conversion is Dictionary \
			or not state.command_results is Dictionary:
		return false
	if not Market.valid(state):
		return false
	if not legacy_ledger and not Ledger.valid(state.ledger):
		return false
	var cash_total: int = Market.merchant_cash(state) + Market.escrowed_cash(state)
	for owner: Variant in state.accounts:
		if not valid_owner(owner):
			return false
		var account: Variant = state.accounts[owner]
		if not account is Dictionary or account.size() != 2:
			return false
		if not _is_count(account.get("cash")) or not account.get("granted") is bool:
			return false
		cash_total += int(account.cash)
	# ADR-012 decision 5: `issued` is the net issuance, so accounts, merchant cash
	# and buy escrow must equal it exactly. The check sits outside the loop so an
	# empty accounts table cannot skip it.
	if cash_total != int(state.issued):
		return false
	# A present journal must reproduce every authoritative balance. A legacy
	# document without the key is admitted above and gets an opening checkpoint
	# on restore instead of a migration file.
	if not legacy_ledger and not reconcile(state).ok:
		return false
	if not _valid_conversion(state.conversion):
		return false
	return _valid_results(state.command_results)


static func cash(state: Dictionary, owner: String) -> int:
	var account: Variant = state.accounts.get(owner)
	return int(account.cash) if account is Dictionary else 0


static func issued(state: Dictionary) -> int:
	return int(state.issued)


static func total_cash(state: Dictionary) -> int:
	# Merchant cash is issued money too, so it belongs in the conservation view
	# even though the merchant is not a player account.
	var total: int = Market.merchant_cash(state) + Market.escrowed_cash(state)
	for account: Variant in state.accounts.values():
		if account is Dictionary:
			total += int(account.get("cash", 0))
	return total


## Cash already committed to open buy orders for one owner. This is a derived
## view, not a stored balance: the order rows remain authoritative, and the
## owner's account cash is already the available amount.
static func frozen_cash(state: Dictionary, owner: String) -> int:
	return Market.escrowed_cash_for(state, owner)


## Available plus escrowed cash for one owner. The total is the amount the
## ledger checkpoint should show before an order is placed.
static func funds(state: Dictionary, owner: String) -> Dictionary:
	if not valid_owner(owner) and owner != Market.MERCHANT:
		return {}
	var available: int = Market.merchant_cash(state) if owner == Market.MERCHANT \
		else cash(state, owner)
	var frozen: int = frozen_cash(state, owner)
	return {
		"owner": owner, "available": available, "frozen": frozen,
		"total": available + frozen,
	}


## Compares the journal checkpoint with every authoritative cash holder. A
## successful result also proves the zero-sum identity and the ADR-012 net issue
## equation; a legacy economy without a ledger reports `legacy=true` and is not
## treated as a mismatch.
static func reconcile(state: Dictionary) -> Dictionary:
	if not state.get("ledger") is Dictionary:
		return {
			"ok": true, "reason": "", "legacy": true, "total_cash": total_cash(state),
			"issued": int(state.issued), "issuance": 0, "burned": 0,
			"accounts": 0, "merchant": 0, "escrow": 0, "entries": 0, "sequence": 0,
		}
	var ledger: Dictionary = state.ledger
	if not Ledger.valid(ledger):
		return _reconcile_error("invalid_ledger")
	var expected: Dictionary = {}
	var accounts_total: int = 0
	for owner: Variant in state.accounts:
		var account: Variant = state.accounts[owner]
		if account is Dictionary:
			var owner_cash: int = int(account.get("cash", 0))
			expected[Ledger.owner_code(str(owner))] = owner_cash
			accounts_total += owner_cash
	var merchant_cash: int = Market.merchant_cash(state)
	var escrow_cash: int = Market.escrowed_cash(state)
	expected[Ledger.MERCHANT] = merchant_cash
	expected[Ledger.ESCROW] = escrow_cash
	var cash_total: int = accounts_total + merchant_cash + escrow_cash
	for code: Variant in expected:
		if Ledger.balance(ledger, str(code)) != int(expected[code]):
			return _reconcile_error("ledger_balance_mismatch")
	for code: Variant in ledger.balances:
		# A checkpoint for an account that no longer exists would hide cash.
		if Ledger.is_account_code(code) and not expected.has(code):
			return _reconcile_error("unknown_account")
	var issuance: int = -Ledger.balance(ledger, Ledger.ISSUANCE)
	var burned: int = Ledger.balance(ledger, Ledger.BURN)
	if issuance < 0 or burned < 0 or issuance - burned != int(state.issued) \
			or cash_total != int(state.issued):
		return _reconcile_error("ledger_not_conserved")
	return {
		"ok": true, "reason": "", "legacy": false, "total_cash": cash_total,
		"issued": int(state.issued), "issuance": issuance, "burned": burned,
		"accounts": accounts_total, "merchant": merchant_cash, "escrow": escrow_cash,
		"entries": ledger.entries.size(), "sequence": int(ledger.sequence),
	}


## Reserve report for the current slice. M8-01 has no deposits or loans, so the
## claim side is zero and every issued COIN is held as cash. M8-02 will add
## deposit liabilities here instead of inventing a second wallet.
static func reserve_statement(state: Dictionary) -> Dictionary:
	var report: Dictionary = reconcile(state)
	var accounts_total: int = 0
	for account: Variant in state.accounts.values():
		if account is Dictionary:
			accounts_total += int(account.get("cash", 0))
	var cash_total: int = total_cash(state)
	var claims: int = 0
	return {
		"ok": bool(report.ok), "reason": str(report.get("reason", "")),
		"legacy": bool(report.get("legacy", false)),
		"total_cash": cash_total, "issued": issued(state),
		"accounts": accounts_total, "merchant": Market.merchant_cash(state),
		"escrow": Market.escrowed_cash(state),
		"issuance": int(report.get("issuance", 0)), "burned": int(report.get("burned", 0)),
		"claims": claims, "reserve": cash_total, "covered": cash_total >= claims,
		"entries": int(report.get("entries", 0)), "sequence": int(report.get("sequence", 0)),
	}


static func ledger_snapshot(state: Dictionary) -> Dictionary:
	var ledger: Variant = state.get("ledger")
	return ledger.duplicate(true) if ledger is Dictionary else Ledger.initial_state()


static func ledger_entries(state: Dictionary) -> Array:
	var ledger: Variant = state.get("ledger")
	return Ledger.entries(ledger) if ledger is Dictionary else []


static func ledger_entry(state: Dictionary, entry_id: String) -> Dictionary:
	var ledger: Variant = state.get("ledger")
	return Ledger.entry(ledger, entry_id) if ledger is Dictionary else {}


static func ledger_balance(state: Dictionary, code: String) -> int:
	var ledger: Variant = state.get("ledger")
	return Ledger.balance(ledger, code) if ledger is Dictionary else 0


## Builds the opening checkpoint for a document written before the ledger
## existed. No journal entry is invented: the snapshot starts with an empty
## journal and a checkpoint equal to the cash authorities it already has, so
## the first new command can reconcile without a migration file.
static func adopt_ledger(state: Dictionary) -> void:
	if state.get("ledger") is Dictionary:
		return
	var balances: Dictionary = {}
	for owner: Variant in state.accounts:
		var account: Variant = state.accounts[owner]
		if account is Dictionary:
			var owner_cash: int = int(account.get("cash", 0))
			if owner_cash != 0:
				balances[Ledger.owner_code(str(owner))] = owner_cash
	var merchant_cash: int = Market.merchant_cash(state)
	if merchant_cash != 0:
		balances[Ledger.MERCHANT] = merchant_cash
	var escrow_cash: int = Market.escrowed_cash(state)
	if escrow_cash != 0:
		balances[Ledger.ESCROW] = escrow_cash
	var net_issued: int = int(state.issued)
	if net_issued != 0:
		# Gross burn history is not recoverable from a pre-ledger document, so
		# the whole net issue starts on the issuance side.
		balances[Ledger.ISSUANCE] = -net_issued
	state.ledger = {"sequence": 0, "entries": {}, "balances": balances}


static func normalize_ledger(state: Dictionary) -> void:
	if not state.get("ledger") is Dictionary:
		adopt_ledger(state)
	Ledger.normalize(state.ledger)


static func _reconcile_error(reason: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "legacy": false, "total_cash": 0,
		"issued": 0, "issuance": 0, "burned": 0, "accounts": 0, "merchant": 0,
		"escrow": 0, "entries": 0, "sequence": 0,
	}


## Issues the one-time opening grant. The owner is supplied by the authority,
## never by the command payload; a second id for an existing owner is refused
## instead of paying twice.
static func open_account(state: Dictionary, owner: String, command_id: String, now_utc: float) -> Dictionary:
	if not _valid_command_id(command_id):
		return _result(false, "invalid_command", 0)
	if not _valid_time(now_utc):
		return _result(false, "invalid_time", 0)
	if not valid_owner(owner) or owner == WORLD_OWNER:
		return _result(false, "invalid_owner", 0)
	var payload: String = JSON.stringify(["open_account", owner, float(now_utc)])
	var replay: Dictionary = _replay(state, command_id, payload)
	if not replay.is_empty():
		return replay
	if state.accounts.has(owner):
		var existing: Variant = state.accounts[owner]
		if existing is Dictionary and bool(existing.get("granted", false)):
			return _result(false, "already_granted", 0)
		# A seller receives settlement proceeds without opening an account. That
		# proceeds-only account is granted=false, so the one-time opening grant is
		# still available exactly once. It is a grant, not a second issuance path.
		if not existing is Dictionary or not _is_count(int(existing.get("cash", 0)) + OPENING_GRANT):
			return _result(false, "invalid_amount", 0)
	if not _is_count(int(state.issued) + OPENING_GRANT):
		return _result(false, "invalid_amount", 0)
	# The entry and the balance move on the same candidate. Validation above
	# means the grant itself cannot fail after the journal accepts it.
	var posted: Dictionary = Ledger.post(state.ledger, Ledger.KIND_OPEN_ACCOUNT, command_id,
		now_utc, [
			Ledger.debit_line(Ledger.owner_code(owner), OPENING_GRANT),
			Ledger.credit_line(Ledger.ISSUANCE, OPENING_GRANT),
		])
	if not posted.ok:
		return _result(false, str(posted.reason), 0)
	if state.accounts.has(owner):
		var existing_account: Dictionary = state.accounts[owner]
		existing_account.cash = int(existing_account.cash) + OPENING_GRANT
		existing_account.granted = true
	else:
		state.accounts[owner] = {"cash": OPENING_GRANT, "granted": true}
	state.issued = int(state.issued) + OPENING_GRANT
	var stored: Dictionary = {"ok": true, "reason": "", "amount": OPENING_GRANT}
	_record(state, command_id, payload, stored)
	return {"ok": true, "reason": "", "amount": OPENING_GRANT, "duplicate": false}


## Moves already-issued cash between two accounts. It is the payment primitive
## M7-02 will call after a quote is accepted; it never changes the issued total.
static func pay(state: Dictionary, from_owner: String, to_owner: String, amount: Variant,
		command_id: String, now_utc: float) -> Dictionary:
	if not _valid_command_id(command_id):
		return _result(false, "invalid_command", 0)
	if not _valid_time(now_utc):
		return _result(false, "invalid_time", 0)
	if not valid_owner(from_owner) or not valid_owner(to_owner) or from_owner == to_owner:
		return _result(false, "invalid_owner", 0)
	if not _is_positive_count(amount):
		return _result(false, "invalid_amount", 0)
	var count: int = int(amount)
	var payload: String = JSON.stringify(["pay", from_owner, to_owner, count, float(now_utc)])
	var replay: Dictionary = _replay(state, command_id, payload)
	if not replay.is_empty():
		return replay
	var from_account: Variant = state.accounts.get(from_owner)
	var to_account: Variant = state.accounts.get(to_owner)
	if not from_account is Dictionary or not to_account is Dictionary:
		return _result(false, "unknown_account", 0)
	if int(from_account.cash) < count:
		return _result(false, "insufficient", 0)
	# A transfer is one balanced entry: the receiver is debited and the payer is
	# credited for the same amount, so issued cash does not change.
	var posted: Dictionary = Ledger.post(state.ledger, Ledger.KIND_PAY, command_id, now_utc, [
		Ledger.debit_line(Ledger.owner_code(to_owner), count),
		Ledger.credit_line(Ledger.owner_code(from_owner), count),
	])
	if not posted.ok:
		return _result(false, str(posted.reason), 0)
	from_account.cash = int(from_account.cash) - count
	to_account.cash = int(to_account.cash) + count
	var stored: Dictionary = {"ok": true, "reason": "", "amount": count}
	_record(state, command_id, payload, stored)
	return {"ok": true, "reason": "", "amount": count, "duplicate": false}


## Records the opening stock of the existing bags and public inventory. Goods
## are not copied or moved: the existing tables remain the inventory authority.
## The command runs at most once per world, and a replay of the same id and
## source returns the original totals instead of stacking them.
static func convert_demo(state: Dictionary, source: Dictionary, command_id: String,
		now_utc: float) -> Dictionary:
	if not _valid_command_id(command_id):
		return _result(false, "invalid_command", 0)
	if not _valid_time(now_utc):
		return _result(false, "invalid_time", 0)
	var normalized: Dictionary = normalize_source(source)
	if not normalized.ok:
		return _result(false, str(normalized.reason), 0)
	var digest: String = str(normalized.digest)
	var existing: Dictionary = state.conversion
	if not existing.is_empty():
		if str(existing.id) != command_id:
			return _result(false, "already_converted", 0)
		if str(existing.digest) != digest:
			return _result(false, "command_conflict", 0)
		var replay: Dictionary = _replay(state, command_id, _conversion_payload(digest, now_utc))
		if not replay.is_empty():
			return replay
		return {"ok": true, "reason": "", "amount": int(existing.goods_total), "duplicate": true}
	var payload: String = _conversion_payload(digest, now_utc)
	var recorded: Dictionary = _replay(state, command_id, payload)
	if not recorded.is_empty():
		return recorded
	state.conversion = {
		"id": command_id, "digest": digest, "owners": normalized.source,
		"goods_total": int(normalized.total), "at_utc": now_utc,
	}
	var stored: Dictionary = {"ok": true, "reason": "", "amount": int(normalized.total)}
	_record(state, command_id, payload, stored)
	return {"ok": true, "reason": "", "amount": int(normalized.total), "duplicate": false}


## Validates and canonicalizes one declared opening stock. Zero quantities are
## dropped so two equivalent declarations have the same digest; negatives and
## fractional values are refused rather than floored.
static func normalize_source(source: Dictionary) -> Dictionary:
	var normalized: Dictionary = {}
	var total: int = 0
	for owner: Variant in source:
		if not valid_owner(owner):
			return {"ok": false, "reason": "invalid_owner"}
		var goods: Variant = source[owner]
		if not goods is Dictionary:
			return {"ok": false, "reason": "invalid_goods"}
		var clean: Dictionary = {}
		for good_id: Variant in goods:
			if not Catalog.is_good(good_id):
				return {"ok": false, "reason": "invalid_good"}
			var amount: Variant = goods[good_id]
			if not _is_count(amount):
				return {"ok": false, "reason": "invalid_amount"}
			if int(amount) > MAX_SAFE_INTEGER - total:
				return {"ok": false, "reason": "invalid_amount"}
			if int(amount) > 0:
				clean[str(good_id)] = int(amount)
				total += int(amount)
		if not clean.is_empty():
			normalized[str(owner)] = clean
	var text: String = JSON.stringify(normalized, "", true, false)
	return {"ok": true, "source": normalized, "total": total, "digest": _sha256(text)}


## Public bridge for the market slice. Orders own their rules but reuse this
## bounded ledger, so the world keeps one command-id window instead of two.
static func replay(state: Dictionary, command_id: String, payload: String) -> Dictionary:
	return _replay(state, command_id, payload)


static func record(state: Dictionary, command_id: String, payload: String, result: Dictionary) -> void:
	_record(state, command_id, payload, result)


static func _valid_conversion(value: Dictionary) -> bool:
	if value.is_empty():
		return true
	if value.size() != 5:
		return false
	for key: String in ["id", "digest", "owners", "goods_total", "at_utc"]:
		if not value.has(key):
			return false
	if not _valid_command_id(value.id) or not _valid_digest(value.digest):
		return false
	if not _is_count(value.goods_total) or not _valid_time(value.at_utc):
		return false
	if not value.owners is Dictionary:
		return false
	var total: int = 0
	for owner: Variant in value.owners:
		if not valid_owner(owner):
			return false
		var goods: Variant = value.owners[owner]
		if not goods is Dictionary or goods.is_empty():
			return false
		for good_id: Variant in goods:
			if not Catalog.is_good(good_id):
				return false
			var amount: Variant = goods[good_id]
			if not _is_positive_count(amount):
				return false
			total += int(amount)
			if total > MAX_SAFE_INTEGER:
				return false
	return total == int(value.goods_total)


static func _valid_results(value: Dictionary) -> bool:
	if value.size() > MAX_COMMAND_RESULTS:
		return false
	for command_id: Variant in value:
		if not _valid_command_id(command_id):
			return false
		var entry: Variant = value[command_id]
		if not entry is Dictionary or entry.size() != 2:
			return false
		var payload: Variant = entry.get("payload")
		if not payload is String or payload.length() > MAX_PAYLOAD_LENGTH:
			return false
		var result: Variant = entry.get("result")
		if not result is Dictionary or result.size() != 3:
			return false
		if not result.get("ok") is bool or not result.get("reason") is String:
			return false
		if not _is_count(result.get("amount")):
			return false
	return true


static func _replay(state: Dictionary, command_id: String, payload: String) -> Dictionary:
	var results: Dictionary = state.command_results
	if not results.has(command_id):
		return {}
	var entry: Variant = results[command_id]
	if not entry is Dictionary or str(entry.get("payload", "")) != payload:
		return {"ok": false, "reason": "command_conflict", "amount": 0, "duplicate": true}
	var result: Dictionary = entry.result
	return {
		"ok": bool(result.get("ok", false)), "reason": str(result.get("reason", "")),
		"amount": int(result.get("amount", 0)), "duplicate": true,
	}


static func _record(state: Dictionary, command_id: String, payload: String, result: Dictionary) -> void:
	state.sequence = int(state.sequence) + 1
	state.command_results[command_id] = {"payload": payload, "result": result}
	while state.command_results.size() > MAX_COMMAND_RESULTS:
		state.command_results.erase(state.command_results.keys()[0])


static func _conversion_payload(digest: String, now_utc: float) -> String:
	return JSON.stringify(["convert_demo", digest, float(now_utc)])


static func _valid_command_id(value: Variant) -> bool:
	return value is String and not value.is_empty() and value.length() <= MAX_COMMAND_ID_LENGTH


static func _valid_digest(value: Variant) -> bool:
	if not value is String or value.length() != 64:
		return false
	for index: int in value.length():
		var code: int = value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 97 and code <= 102)):
			return false
	return true


static func _is_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) and number == floorf(number)


static func _is_positive_count(value: Variant) -> bool:
	return _is_count(value) and float(value) > 0.0


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


static func _result(ok: bool, reason: String, amount: int) -> Dictionary:
	return {"ok": ok, "reason": reason, "amount": amount, "duplicate": false}


static func _sha256(text: String) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(text.to_utf8_buffer())
	return hashing.finish().hex_encode()
