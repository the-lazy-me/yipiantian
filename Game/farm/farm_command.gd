extends RefCounted
## M0 command boundary: validate, execute on a candidate, replay within one
## batch. No scene, clock, disk or network access.
##
## The committed ledger lives in FarmState, not here: a candidate carries its
## own command result and event sequence, so FarmStore persists the resource
## change and the idempotent result as one snapshot.

const HARVEST: String = "harvest"
const SOW: String = "sow"
const WATER: String = "water"
const KIND: String = HARVEST
const KINDS: Array[String] = [HARVEST, SOW, WATER]
const MAX_ID_LENGTH: int = 128


func execute(state: RefCounted, command: Dictionary) -> Dictionary:
	if not valid(command):
		return {"ok": false, "reason": "invalid_command", "duplicate": false, "command_id": ""}
	var id: String = command.id
	var recorded: Dictionary = state.command_result(id)
	if not recorded.is_empty():
		if recorded.payload != _payload(command):
			return {"ok": false, "reason": "command_conflict", "duplicate": true, "command_id": id}
		var replay: Dictionary = recorded.result.duplicate(true)
		replay.duplicate = true
		return {"ok": bool(replay.get("ok", false)), "reason": replay.get("reason", ""), "result": replay,
			"duplicate": true, "command_id": id}
	var candidate = state.copy()
	var result: Dictionary = _apply(candidate, command)
	if result.ok:
		if not candidate.commit_command(id, _payload(command), result):
			return {"ok": false, "reason": "invalid_result", "duplicate": false, "command_id": id}
	return {"ok": bool(result.ok), "reason": result.get("reason", ""), "result": result,
		"candidate": candidate if result.ok else null, "duplicate": false, "command_id": id}


static func _apply(state: RefCounted, command: Dictionary) -> Dictionary:
	# The rule owner performs admission and time settlement; this boundary only
	# selects the operation and keeps a candidate private until commit.
	match command.kind:
		SOW:
			return state.sow(command.field_id, command.cell_id, command.crop_id, float(command.at_utc))
		WATER:
			return state.water(command.field_id, command.cell_id, float(command.at_utc))
		_:
			return state.harvest(command.field_id, command.cell_id, float(command.at_utc))


static func has_committed(state: RefCounted, id: String) -> bool:
	# A caller may retry an already committed id at its original time; that must
	# reach the replay path instead of being rejected as a backdated action.
	return not state.command_result(id).is_empty()


static func valid(command: Dictionary) -> bool:
	var kind: Variant = command.get("kind")
	if not kind is String or kind not in KINDS:
		return false
	# Sow carries one extra field (crop_id); harvest and water keep the M0 shape.
	if kind == SOW:
		if command.size() != 6:
			return false
		var crop: Variant = command.get("crop_id")
		if not crop is String or crop.is_empty() or crop.length() > MAX_ID_LENGTH:
			return false
	elif command.size() != 5:
		return false
	var id: Variant = command.get("id")
	if not id is String or id.is_empty() or id.length() > MAX_ID_LENGTH:
		return false
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


static func _payload(command: Dictionary) -> String:
	var payload: Array = [command.kind, command.field_id, command.cell_id, float(command.at_utc)]
	if command.kind == SOW:
		payload.append(command.crop_id)
	return JSON.stringify(payload)
