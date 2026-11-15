extends RefCounted
## M0 command boundary: validate, execute on a candidate, replay within one
## batch. No scene, clock, disk or network access.
##
## The committed ledger lives in FarmState, not here: a candidate carries its
## own command result and event sequence, so FarmStore persists the resource
## change and the idempotent result as one snapshot.

const FarmState = preload("res://farm/farm_state.gd")
const Market = preload("res://farm/market_state.gd")
const Loans = preload("res://farm/loan_state.gd")
const Catalog = preload("res://farm/economy_catalog.gd")

const HARVEST: String = "harvest"
const SOW: String = "sow"
const WATER: String = "water"
const WEED: String = "weed"
const TILL: String = "till"
const GIFT: String = "gift"
const SET_THEFT: String = "set_theft"
const BUILD: String = "build"
const DEMOLISH: String = "demolish"
## M9 economy commands. Identity (payer, borrower, owner) is never part of a
## command: the authority resolves it from the connection and passes it as
## `actor`, exactly like gift and build.
const ACCOUNT_OPEN: String = "account_open"
const PAY: String = "pay"
const MARKET_OPEN: String = "market_open"
const MARKET_PLACE: String = "market_place"
const MARKET_CANCEL: String = "market_cancel"
const MARKET_SHIP: String = "market_ship"
const MARKET_DELIVER: String = "market_deliver"
const BANK_OPEN: String = "bank_open"
const LOAN_BORROW: String = "loan_borrow"
const LOAN_REPAY: String = "loan_repay"
const ECONOMY_KINDS: Array[String] = [
	ACCOUNT_OPEN, PAY, MARKET_OPEN, MARKET_PLACE, MARKET_CANCEL, MARKET_SHIP,
	MARKET_DELIVER, BANK_OPEN, LOAN_BORROW, LOAN_REPAY,
]
const KIND: String = HARVEST
const KINDS: Array[String] = [
	HARVEST, SOW, WATER, WEED, TILL, GIFT, SET_THEFT, BUILD, DEMOLISH,
	ACCOUNT_OPEN, PAY, MARKET_OPEN, MARKET_PLACE, MARKET_CANCEL, MARKET_SHIP,
	MARKET_DELIVER, BANK_OPEN, LOAN_BORROW, LOAN_REPAY,
]
const MAX_ID_LENGTH: int = 128
const MAX_AMOUNT: int = 9007199254740991


func execute(state: RefCounted, command: Dictionary, actor: String = "") -> Dictionary:
	if not valid(command):
		return {"ok": false, "reason": "invalid_command", "duplicate": false, "command_id": ""}
	var id: String = command.id
	var recorded: Dictionary = state.command_result(id)
	if not recorded.is_empty():
		if recorded.payload != _payload(command, actor):
			return {"ok": false, "reason": "command_conflict", "duplicate": true, "command_id": id}
		var replay: Dictionary = recorded.result.duplicate(true)
		replay.duplicate = true
		return {"ok": bool(replay.get("ok", false)), "reason": replay.get("reason", ""), "result": replay,
			"duplicate": true, "command_id": id}
	var candidate = state.copy()
	var result: Dictionary = _apply(candidate, command, actor)
	# A rule can resolve an action as already applied in its own durable window
	# even when this bounded command window no longer holds the result. That is
	# still a replay: committing it would write an unchanged candidate, grow the
	# transaction window and broadcast a change that did not happen.
	var domain_duplicate: bool = bool(result.get("duplicate", false))
	if result.ok and not domain_duplicate:
		if not candidate.commit_command(id, _payload(command, actor), result):
			return {"ok": false, "reason": "invalid_result", "duplicate": false, "command_id": id}
	return {"ok": bool(result.ok), "reason": result.get("reason", ""), "result": result,
		"candidate": candidate if result.ok and not domain_duplicate else null,
		"duplicate": domain_duplicate, "command_id": id}


static func _apply(state: RefCounted, command: Dictionary, actor: String = "") -> Dictionary:
	# The rule owner performs admission and time settlement; this boundary only
	# selects the operation and keeps a candidate private until commit.
	match command.kind:
		SOW:
			return state.sow(command.field_id, command.cell_id, command.crop_id, float(command.at_utc), actor)
		WATER:
			return state.water(command.field_id, command.cell_id, float(command.at_utc))
		WEED, TILL:
			return state.tidy(command.kind, command.field_id, command.cell_id, float(command.at_utc))
		GIFT:
			# The sender is never taken from the command: only the authority knows
			# which player this connection belongs to.
			return state.gift(actor, command.to_id, command.crop_id, command.amount)
		SET_THEFT:
			# Likewise the owner is the connection's player, never a claimed id.
			return state.set_theft(actor, bool(command.enabled))
		BUILD:
			# The owner is the connection's player, so a build cannot name a
			# different owner in its payload.
			return state.build(command.slot_id, command.blueprint, float(command.at_utc), actor)
		DEMOLISH:
			return state.demolish(command.slot_id, float(command.at_utc), actor)
		ACCOUNT_OPEN:
			# The account owner is the connection's player; the payload cannot
			# name someone else's account.
			return state.economy_open_account(command.id, actor, float(command.at_utc))
		PAY:
			return state.economy_pay(command.id, actor, command.to_id, command.amount,
				float(command.at_utc), command.seq)
		MARKET_OPEN:
			# A world-level one-time action: it opens the rule merchant for the
			# whole world and issues no cash or goods to the caller.
			return state.market_open_merchant(command.id, float(command.at_utc))
		MARKET_PLACE:
			return state.market_place_order(command.id, actor, command.side, command.good_id,
				command.price, command.quantity, float(command.expires_utc), float(command.at_utc))
		MARKET_CANCEL:
			return state.market_cancel_order(command.id, actor, command.order_id,
				float(command.at_utc))
		MARKET_SHIP:
			return state.market_ship(command.id, actor, command.origin, command.destination,
				command.good_id, command.quantity, float(command.at_utc),
				str(command.get("risk", Market.SHIPMENT_RISK_SAFE)))
		MARKET_DELIVER:
			return state.market_deliver(float(command.at_utc), command.id)
		BANK_OPEN:
			return state.economy_open_bank(command.id, float(command.at_utc))
		LOAN_BORROW:
			return state.economy_borrow_loan(command.id, actor, command.principal,
				command.term, float(command.at_utc))
		LOAN_REPAY:
			return state.economy_repay_loan(command.id, actor, command.loan_id,
				float(command.at_utc))
		_:
			return state.harvest(command.field_id, command.cell_id, float(command.at_utc), actor,
				bool(command.get("authorized", false)))


static func has_committed(state: RefCounted, id: String) -> bool:
	# A caller may retry an already committed id at its original time; that must
	# reach the replay path instead of being rejected as a backdated action.
	return not state.command_result(id).is_empty()


static func valid(command: Dictionary) -> bool:
	var kind: Variant = command.get("kind")
	if not kind is String or kind not in KINDS:
		return false
	# Sow carries one extra field (crop_id); harvest and water keep the M0 shape.
	if kind == BUILD:
		# Housing names a fixed slot, not a field or cell, and never its builder.
		if command.size() != 5 or command.has("from") or command.has("from_id"):
			return false
		var blueprint: Variant = command.get("blueprint")
		if not blueprint is String or blueprint.is_empty() or blueprint.length() > MAX_ID_LENGTH:
			return false
	elif kind == DEMOLISH:
		if command.size() != 4 or command.has("from") or command.has("from_id"):
			return false
	elif kind == GIFT:
		# A gift names no field or cell, and never carries its own sender: the
		# exact key set is what keeps `from`/`from_id` out.
		if command.size() != 6 or command.has("from") or command.has("from_id"):
			return false
		for key: String in ["to_id", "crop_id"]:
			var value: Variant = command.get(key)
			if not value is String or value.is_empty() or value.length() > MAX_ID_LENGTH:
				return false
		var amount: Variant = command.get("amount")
		if not (amount is int or amount is float) or not is_finite(float(amount)) \
				or floorf(float(amount)) != float(amount) \
				or float(amount) < 1.0 or float(amount) > float(FarmState.MAX_GIFT):
			return false
	elif kind == SET_THEFT:
		# A player states their own standing; the actor comes from the connection,
		# so a sender field is a malformed command rather than an ignored extra.
		if command.size() != 4 or command.has("from") or command.has("from_id"):
			return false
		if not command.get("enabled") is bool:
			return false
	elif kind == SOW:
		if command.size() != 6:
			return false
		var crop: Variant = command.get("crop_id")
		if not crop is String or crop.is_empty() or crop.length() > MAX_ID_LENGTH:
			return false
	elif kind == HARVEST:
		# The authority resolves the owner's grant and stamps it on the command
		# it broadcasts, so every replay reaches the same decision. A client
		# claiming it is overwritten there.
		if command.size() != 5 and command.size() != 6:
			return false
		if command.size() == 6 and not command.has("authorized"):
			return false
		if command.has("authorized") and not command.get("authorized") is bool:
			return false
	elif kind == ACCOUNT_OPEN or kind == MARKET_OPEN or kind == MARKET_DELIVER \
			or kind == BANK_OPEN:
		# No operand and, above all, no declared owner: the exact key set keeps
		# `from`/`from_id`/`owner_id` out.
		if command.size() != 3 or _has_identity_key(command):
			return false
	elif kind == PAY:
		if command.size() != 6 or _has_identity_key(command):
			return false
		# The payer is resolved from the connection; only the recipient, amount
		# and the payer's next payment sequence are supplied. The sequence is
		# durable state: a value that is not strictly increasing is stale even
		# after the bounded command window forgets the original result.
		if not _valid_id(command.get("to_id")):
			return false
		if not _positive_int(command.get("amount"), MAX_AMOUNT):
			return false
		if not _positive_int(command.get("seq"), MAX_AMOUNT):
			return false
	elif kind == MARKET_PLACE:
		if command.size() != 8 or _has_identity_key(command):
			return false
		if not command.get("side") in Market.SIDES:
			return false
		if not Catalog.is_good(command.get("good_id")):
			return false
		if not _positive_int(command.get("price"), Market.MAX_PRICE):
			return false
		if not _positive_int(command.get("quantity"), Market.MAX_QUANTITY):
			return false
		if not _valid_expiry(command.get("expires_utc"), command.get("at_utc")):
			return false
	elif kind == MARKET_CANCEL:
		if command.size() != 4 or _has_identity_key(command):
			return false
		if not Market.valid_command_id(command.get("order_id")):
			return false
	elif kind == MARKET_SHIP:
		# A shipment may explicitly declare transport risk. The older 7-key form
		# stays valid and means `safe`, so a pre-risk command still replays
		# unchanged; the 8-key form must carry a known risk value.
		if (command.size() != 7 and command.size() != 8) or _has_identity_key(command):
			return false
		if command.size() == 8 and command.get("risk") not in Market.SHIPMENT_RISKS:
			return false
		if not Catalog.is_good(command.get("good_id")):
			return false
		if not Market.valid_route(command.get("origin"), command.get("destination")):
			return false
		if not _positive_int(command.get("quantity"), Market.MAX_QUANTITY):
			return false
	elif kind == LOAN_BORROW:
		if command.size() != 5 or _has_identity_key(command):
			return false
		var borrowed_at: Variant = command.get("at_utc")
		if not _valid_time_value(borrowed_at):
			return false
		# The loan rules own the principal bounds, term list and due quote.
		if not Loans.quote(command.get("principal"), command.get("term"),
				float(borrowed_at)).ok:
			return false
	elif kind == LOAN_REPAY:
		if command.size() != 4 or _has_identity_key(command):
			return false
		if not Market.valid_command_id(command.get("loan_id")):
			return false
	elif command.size() != 5:
		return false
	var id: Variant = command.get("id")
	if not id is String or id.is_empty() or id.length() > MAX_ID_LENGTH:
		return false
	if kind == BUILD or kind == DEMOLISH:
		var slot: Variant = command.get("slot_id")
		if not slot is String or slot.is_empty() or slot.length() > MAX_ID_LENGTH:
			return false
	elif not (kind == GIFT or kind == SET_THEFT or is_economy_kind(kind)):
		if not command.get("field_id") is String or command.field_id.is_empty():
			return false
		if not command.get("cell_id") is String or command.cell_id.is_empty():
			return false
	var at: Variant = command.get("at_utc")
	return (at is int or at is float) and is_finite(float(at)) and float(at) >= 0.0


static func is_economy_kind(kind: String) -> bool:
	return kind in ECONOMY_KINDS


static func _has_identity_key(command: Dictionary) -> bool:
	# These are exactly the fields a client must never supply: the authority
	# binds them from the authenticated connection.
	for key: String in ["from", "from_id", "owner", "owner_id", "payer", "borrower"]:
		if command.has(key):
			return true
	return false


static func _valid_id(value: Variant) -> bool:
	return value is String and not value.is_empty() and value.length() <= MAX_ID_LENGTH


static func _positive_int(value: Variant, max_value: int) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number == floorf(number) and number > 0.0 \
		and number <= float(max_value)


static func _valid_time_value(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


static func _valid_expiry(expires: Variant, at: Variant) -> bool:
	if not _valid_time_value(expires) or not _valid_time_value(at):
		return false
	# Same one-second floor the market rule uses, so a document round trip
	# cannot collapse the lifetime to zero.
	return float(expires) - float(at) >= 1.0


static func make(id: String, field_id: String, cell_id: String, at_utc: float) -> Dictionary:
	return {"id": id, "kind": HARVEST, "field_id": field_id, "cell_id": cell_id, "at_utc": at_utc}


static func make_sow(id: String, field_id: String, cell_id: String, crop_id: String, at_utc: float) -> Dictionary:
	return {"id": id, "kind": SOW, "field_id": field_id, "cell_id": cell_id, "crop_id": crop_id, "at_utc": at_utc}


static func make_water(id: String, field_id: String, cell_id: String, at_utc: float) -> Dictionary:
	return {"id": id, "kind": WATER, "field_id": field_id, "cell_id": cell_id, "at_utc": at_utc}


static func make_tidy(id: String, kind: String, field_id: String, cell_id: String, at_utc: float) -> Dictionary:
	return {"id": id, "kind": kind, "field_id": field_id, "cell_id": cell_id, "at_utc": at_utc}


static func make_gift(id: String, to_id: String, crop_id: String, amount: int, at_utc: float) -> Dictionary:
	return {"id": id, "kind": GIFT, "to_id": to_id, "crop_id": crop_id, "amount": amount, "at_utc": at_utc}


static func make_set_theft(id: String, enabled: bool, at_utc: float) -> Dictionary:
	return {"id": id, "kind": SET_THEFT, "enabled": enabled, "at_utc": at_utc}


static func make_build(id: String, slot_id: String, blueprint: String, at_utc: float) -> Dictionary:
	return {"id": id, "kind": BUILD, "slot_id": slot_id, "blueprint": blueprint, "at_utc": at_utc}


static func make_demolish(id: String, slot_id: String, at_utc: float) -> Dictionary:
	return {"id": id, "kind": DEMOLISH, "slot_id": slot_id, "at_utc": at_utc}


static func make_account_open(id: String, at_utc: float) -> Dictionary:
	return {"id": id, "kind": ACCOUNT_OPEN, "at_utc": at_utc}


static func make_pay(id: String, to_id: String, amount: int, seq: int,
		at_utc: float) -> Dictionary:
	return {"id": id, "kind": PAY, "to_id": to_id, "amount": amount, "seq": seq,
		"at_utc": at_utc}


static func make_market_open(id: String, at_utc: float) -> Dictionary:
	return {"id": id, "kind": MARKET_OPEN, "at_utc": at_utc}


static func make_market_place(id: String, side: String, good_id: String, price: int,
		quantity: int, expires_utc: float, at_utc: float) -> Dictionary:
	return {"id": id, "kind": MARKET_PLACE, "side": side, "good_id": good_id,
		"price": price, "quantity": quantity, "expires_utc": expires_utc, "at_utc": at_utc}


static func make_market_cancel(id: String, order_id: String, at_utc: float) -> Dictionary:
	return {"id": id, "kind": MARKET_CANCEL, "order_id": order_id, "at_utc": at_utc}


static func make_market_ship(id: String, origin: String, destination: String,
		good_id: String, quantity: int, at_utc: float,
		risk: String = Market.SHIPMENT_RISK_SAFE) -> Dictionary:
	var command: Dictionary = {"id": id, "kind": MARKET_SHIP, "origin": origin,
		"destination": destination, "good_id": good_id, "quantity": quantity,
		"at_utc": at_utc}
	# The default keeps the original 7-key shape. A declared risk is an explicit
	# operand and must travel in the command, or a replay could silently become
	# the safe route.
	if risk != Market.SHIPMENT_RISK_SAFE:
		command["risk"] = risk
	return command


static func make_market_deliver(id: String, at_utc: float) -> Dictionary:
	return {"id": id, "kind": MARKET_DELIVER, "at_utc": at_utc}


static func make_bank_open(id: String, at_utc: float) -> Dictionary:
	return {"id": id, "kind": BANK_OPEN, "at_utc": at_utc}


static func make_loan_borrow(id: String, principal: int, term: int, at_utc: float) -> Dictionary:
	return {"id": id, "kind": LOAN_BORROW, "principal": principal, "term": term, "at_utc": at_utc}


static func make_loan_repay(id: String, loan_id: String, at_utc: float) -> Dictionary:
	return {"id": id, "kind": LOAN_REPAY, "loan_id": loan_id, "at_utc": at_utc}


static func _payload(command: Dictionary, actor: String = "") -> String:
	# The existing kinds keep their pre-bag payload format so a committed id in
	# an older ledger still replays. Gift is new, so its payload binds the
	# authority-supplied sender: another connection cannot replay it as its own.
	if command.kind == GIFT:
		return JSON.stringify([command.kind, command.to_id, command.crop_id, int(command.amount),
			float(command.at_utc), actor])
	if command.kind == SET_THEFT:
		# The owner is the connection's player, so the payload binds them too.
		return JSON.stringify([command.kind, bool(command.enabled), float(command.at_utc), actor])
	if command.kind == BUILD:
		# The builder is the connection's player and becomes the owner, so the
		# payload binds both the blueprint and the actor.
		return JSON.stringify([command.kind, command.slot_id, float(command.at_utc), actor, command.blueprint])
	if command.kind == DEMOLISH:
		return JSON.stringify([command.kind, command.slot_id, float(command.at_utc), actor])
	if is_economy_kind(command.kind):
		# Every economy payload binds the connection's identity, so a different
		# session cannot replay a committed id as its own action.
		return JSON.stringify(_economy_payload(command, actor))
	var payload: Array = [command.kind, command.field_id, command.cell_id, float(command.at_utc)]
	if command.kind == SOW:
		payload.append(command.crop_id)
	elif command.kind == HARVEST and bool(command.get("authorized", false)):
		# Only a granted harvest differs: the plain form keeps the payload older
		# ledgers already carry, so a restarted world still replays them as-is.
		payload.append(true)
	return JSON.stringify(payload)


static func _economy_payload(command: Dictionary, actor: String) -> Array:
	var at: float = float(command.at_utc)
	match command.kind:
		PAY:
			return [command.kind, command.to_id, int(command.amount), at, actor, int(command.seq)]
		MARKET_PLACE:
			return [command.kind, command.side, command.good_id, int(command.price),
				int(command.quantity), float(command.expires_utc), at, actor]
		MARKET_CANCEL:
			return [command.kind, command.order_id, at, actor]
		MARKET_SHIP:
			var shipped: Array = [command.kind, command.origin, command.destination,
				command.good_id, int(command.quantity), at, actor]
			# A pre-risk command carried 7 consumer fields and still replays with
			# exactly those bytes; only a declared risk appends the new operand.
			if command.has("risk"):
				shipped.append(str(command.risk))
			return shipped
		LOAN_BORROW:
			return [command.kind, int(command.principal), int(command.term), at, actor]
		LOAN_REPAY:
			return [command.kind, command.loan_id, at, actor]
		_:
			# account_open, market_open, market_deliver and bank_open carry only
			# an id and a time; the actor still scopes the idempotent replay.
			return [command.kind, at, actor]
