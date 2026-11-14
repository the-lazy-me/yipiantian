extends RefCounted
## M0 harvest command boundary: validate, execute on a candidate, replay within
## one batch. No scene, clock, disk or network access.

const KIND: String = "harvest"
const MAX_ID_LENGTH: int = 128

var _committed: Dictionary = {} # command id -> {payload, result}


func execute(state: RefCounted, command: Dictionary) -> Dictionary:
	if not valid(command):
		return {"ok": false, "reason": "invalid_command", "duplicate": false, "command_id": ""}
	var id: String = command.id
	if _committed.has(id):
		var recorded: Dictionary = _committed[id]
		if recorded.payload != _payload(command):
			return {"ok": false, "reason": "command_conflict", "duplicate": true, "command_id": id}
		var replay: Dictionary = recorded.result.duplicate(true)
		replay.duplicate = true
		return {"ok": bool(replay.get("ok", false)), "reason": replay.get("reason", ""), "result": replay,
			"duplicate": true, "command_id": id}
	var candidate = state.copy()
	var result: Dictionary = candidate.harvest(command.field_id, command.cell_id, float(command.at_utc))
	return {"ok": bool(result.ok), "reason": result.get("reason", ""), "result": result,
		"candidate": candidate if result.ok else null, "duplicate": false, "command_id": id}


func commit(command: Dictionary, result: Dictionary) -> bool:
	# Only the caller that successfully persisted and accepted the candidate enters
	# here, so a replayed id can never describe an uncommitted reward.
	if not valid(command) or not result.get("ok", false):
		return false
	_committed[command.id] = {"payload": _payload(command), "result": result.duplicate(true)}
	return true


func committed_count() -> int:
	return _committed.size()


static func valid(command: Dictionary) -> bool:
	if command.size() != 5:
		return false
	var id: Variant = command.get("id")
	if not id is String or id.is_empty() or id.length() > MAX_ID_LENGTH:
		return false
	if command.get("kind") != KIND:
		return false
	if not command.get("field_id") is String or command.field_id.is_empty():
		return false
	if not command.get("cell_id") is String or command.cell_id.is_empty():
		return false
	var at: Variant = command.get("at_utc")
	return (at is int or at is float) and is_finite(float(at)) and float(at) >= 0.0


static func make(id: String, field_id: String, cell_id: String, at_utc: float) -> Dictionary:
	return {"id": id, "kind": KIND, "field_id": field_id, "cell_id": cell_id, "at_utc": at_utc}


static func _payload(command: Dictionary) -> String:
	return JSON.stringify([command.kind, command.field_id, command.cell_id, float(command.at_utc)])
