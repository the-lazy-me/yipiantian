extends RefCounted
## M0 command boundary: validate, execute on a candidate, replay within one
## batch. No scene, clock, disk or network access.
##
## The committed ledger lives in FarmState, not here: a candidate carries its
## own command result and event sequence, so FarmStore persists the resource
## change and the idempotent result as one snapshot.

const FarmState = preload("res://farm/farm_state.gd")

const HARVEST: String = "harvest"
const SOW: String = "sow"
const WATER: String = "water"
const WEED: String = "weed"
const TILL: String = "till"
const GIFT: String = "gift"
const SET_THEFT: String = "set_theft"
const BUILD: String = "build"
const DEMOLISH: String = "demolish"
const KIND: String = HARVEST
const KINDS: Array[String] = [HARVEST, SOW, WATER, WEED, TILL, GIFT, SET_THEFT, BUILD, DEMOLISH]
const MAX_ID_LENGTH: int = 128


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
	if result.ok:
		if not candidate.commit_command(id, _payload(command, actor), result):
			return {"ok": false, "reason": "invalid_result", "duplicate": false, "command_id": id}
	return {"ok": bool(result.ok), "reason": result.get("reason", ""), "result": result,
		"candidate": candidate if result.ok else null, "duplicate": false, "command_id": id}


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
	elif command.size() != 5:
		return false
	var id: Variant = command.get("id")
	if not id is String or id.is_empty() or id.length() > MAX_ID_LENGTH:
		return false
	if kind == BUILD or kind == DEMOLISH:
		var slot: Variant = command.get("slot_id")
		if not slot is String or slot.is_empty() or slot.length() > MAX_ID_LENGTH:
			return false
	elif kind != GIFT and kind != SET_THEFT:
		if not command.get("field_id") is String or command.field_id.is_empty():
			return false
		if not command.get("cell_id") is String or command.cell_id.is_empty():
			return false
	var at: Variant = command.get("at_utc")
	return (at is int or at is float) and is_finite(float(at)) and float(at) >= 0.0


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
	var payload: Array = [command.kind, command.field_id, command.cell_id, float(command.at_utc)]
	if command.kind == SOW:
		payload.append(command.crop_id)
	elif command.kind == HARVEST and bool(command.get("authorized", false)):
		# Only a granted harvest differs: the plain form keeps the payload older
		# ledgers already carry, so a restarted world still replays them as-is.
		payload.append(true)
	return JSON.stringify(payload)
