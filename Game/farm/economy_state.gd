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

const WORLD_OWNER: String = "@world"
const CURRENCY: String = Catalog.CURRENCY
## Experiment value: enough to join a few trades, not enough to skip a harvest.
const OPENING_GRANT: int = 120
const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_COMMAND_ID_LENGTH: int = 128
const MAX_PAYLOAD_LENGTH: int = 512
const MAX_COMMAND_RESULTS: int = 64
const STATE_KEYS: Array[String] = [
	"currency", "sequence", "issued", "accounts", "conversion", "command_results",
]


static func initial_state() -> Dictionary:
	return {
		"currency": CURRENCY,
		"sequence": 0,
		"issued": 0,
		"accounts": {},
		"conversion": {},
		"command_results": {},
	}


static func valid_owner(value: Variant) -> bool:
	# `@world` is the public inventory's owner and is not a legal player id, so
	# no member can occupy the same account key.
	return value is String and (value == WORLD_OWNER or OwnerIds.valid(value))


static func valid(state: Variant) -> bool:
	if not state is Dictionary or state.size() != STATE_KEYS.size():
		return false
	for key: String in STATE_KEYS:
		if not state.has(key):
			return false
	if state.currency != CURRENCY:
		return false
	if not _is_count(state.sequence) or not _is_count(state.issued):
		return false
	if not state.accounts is Dictionary or not state.conversion is Dictionary \
			or not state.command_results is Dictionary:
		return false
	var cash_total: int = 0
	for owner: Variant in state.accounts:
		if not valid_owner(owner):
			return false
		var account: Variant = state.accounts[owner]
		if not account is Dictionary or account.size() != 2:
			return false
		if not _is_count(account.get("cash")) or not account.get("granted") is bool:
			return false
		cash_total += int(account.cash)
		if cash_total > int(state.issued):
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
	var total: int = 0
	for account: Variant in state.accounts.values():
		if account is Dictionary:
			total += int(account.get("cash", 0))
	return total


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
		return _result(false, "already_granted", 0)
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
