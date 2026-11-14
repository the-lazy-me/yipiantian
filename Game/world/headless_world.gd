extends RefCounted
## M3-01 headless world session. Starts from the local v27 storage boundary,
## executes commands on the authoritative FarmState and persists through
## FarmStore. No scene, node, DisplayServer, GPU, clock or network access.

const FarmState = preload("res://farm/farm_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Crops = preload("res://farm/crop_catalog.gd")

var store: FarmStore
var farm: FarmState
var decorations: Decorations
var commands: FarmCommand
var now_utc: float = 0.0
var directory: String = ""


func open(save_directory: String, now_utc_seconds: float) -> Dictionary:
	# The caller supplies a logical time. Missing worlds start from it; existing
	# worlds keep their stored settlement baselines until an action or advance.
	if not _valid_time(now_utc_seconds):
		return _failure("invalid_time")
	var normalized: String = ProjectSettings.globalize_path(save_directory).simplify_path()
	if not normalized.is_absolute_path():
		return _failure("relative_path")
	directory = normalized
	store = FarmStore.new(directory)
	var loaded: Dictionary = store.load_state()
	if not loaded.ok:
		# Recovery stays an explicit storage decision; a failed load is never
		# replaced by a fresh farm.
		return _failure("load_" + str(loaded.kind))
	commands = FarmCommand.new()
	now_utc = now_utc_seconds
	if loaded.kind == "missing":
		farm = FarmState.new(now_utc_seconds)
		decorations = Decorations.new()
		return {"ok": true, "kind": "created"}
	farm = FarmState.new()
	if not farm.restore_snapshot(loaded.farm):
		farm = null
		return _failure("restore_farm")
	decorations = Decorations.new()
	if not decorations.restore_snapshot(loaded.decorations):
		farm = null
		decorations = null
		return _failure("restore_decorations")
	return {"ok": true, "kind": "loaded"}


func execute(command: Dictionary, actor: String = "") -> Dictionary:
	# A command enters the authoritative state only after its candidate was
	# written by FarmStore and the storage boundary accepted the commit.
	if farm == null:
		return _result(false, "not_open", false, "")
	# Retries of a committed id still replay; only new backdated work is refused.
	var command_id: Variant = command.get("id")
	if FarmCommand.valid(command) and not (command_id is String and FarmCommand.has_committed(farm, command_id)) \
			and float(command.at_utc) < now_utc:
		return _result(false, "time_backwards", false, str(command_id))
	var execution: Dictionary = commands.execute(farm, command, actor)
	if not execution.ok:
		return _result(false, str(execution.reason), bool(execution.duplicate), str(execution.command_id))
	if execution.duplicate:
		now_utc = maxf(now_utc, float(command.at_utc))
		var replay: Dictionary = execution.result
		return {
			"ok": bool(replay.get("ok", false)), "reason": str(replay.get("reason", "")),
			"stage": "duplicate", "duplicate": true, "command_id": command.id,
			"reward_crop_id": replay.get("reward_crop_id", ""),
			"reward_amount": replay.get("reward_amount", 0),
		}
	var candidate: RefCounted = execution.candidate
	var decoration_before: Dictionary = decorations.snapshot()
	decorations.unlock(candidate.snapshot().harvested, candidate.snapshot().kitchen)
	var saved: Dictionary = store.save_state(candidate, decorations)
	if not saved.ok:
		# Keep the in-memory decorations aligned with the last accepted commit.
		decorations.restore_snapshot(decoration_before)
		return _result(false, "save_" + str(saved.kind), false, command.id)
	farm.accept(candidate)
	now_utc = maxf(now_utc, float(command.at_utc))
	return {
		"ok": true, "reason": "", "stage": "committed", "duplicate": false, "command_id": command.id,
		"reward_crop_id": execution.result.get("reward_crop_id", ""),
		"reward_amount": execution.result.get("reward_amount", 0),
	}


func next_event_utc() -> float:
	# The next stage boundary comes from authoritative cell growth and the crop
	# durations owned by FarmState/Crops; no growth rule is duplicated here.
	# An empty or fully mature world has no future boundary and returns INF.
	if farm == null:
		return INF
	var data: Dictionary = farm.snapshot()
	var next: float = INF
	for field_id: String in data.fields:
		for cell_id: String in data.fields[field_id].cells:
			var cell: Dictionary = data.fields[field_id].cells[cell_id]
			if cell.crop_id.is_empty():
				continue
			var duration: float = Crops.definition(cell.crop_id).duration_seconds
			var growth: float = float(cell.growth_seconds)
			var baseline: float = float(cell.last_settled_utc_seconds)
			for threshold: float in [duration * Crops.YOUNG_PROGRESS, duration]:
				if growth >= threshold:
					continue
				var at: float = baseline + (threshold - growth)
				if at < next:
					next = at
	if not is_finite(next):
		return INF
	# A boundary already due before the current world time is applied by
	# settling at the current time, so it is reported as "now", not the past.
	return maxf(next, now_utc)


func advance_to(target_utc_seconds: float) -> Dictionary:
	# Growth is settled by FarmState in segments that stop on each event; the
	# final segment reaches the requested target. Backwards time is refused.
	if farm == null:
		return _failure("not_open")
	if not _valid_time(target_utc_seconds):
		return _failure("invalid_time")
	if target_utc_seconds < now_utc:
		return _failure("time_backwards")
	var changed: Array[String] = []
	var visual: Array[String] = []
	# A reopened world may hold baselines older than the supplied logical time.
	# Normalize at the current time before looking for future boundaries.
	var normalized: Dictionary = farm.settle(now_utc)
	if not normalized.ok:
		return normalized
	_merge_names(changed, normalized.get("changed_fields", []))
	_merge_names(visual, normalized.get("visual_changed", []))
	var segments: int = 0
	while true:
		var event: float = next_event_utc()
		if not is_finite(event) or event > target_utc_seconds or event <= now_utc:
			break
		var settled: Dictionary = farm.settle(event)
		if not settled.ok:
			return settled
		_merge_names(changed, settled.get("changed_fields", []))
		_merge_names(visual, settled.get("visual_changed", []))
		now_utc = event
		segments += 1
	if now_utc < target_utc_seconds:
		var final_settled: Dictionary = farm.settle(target_utc_seconds)
		if not final_settled.ok:
			return final_settled
		_merge_names(changed, final_settled.get("changed_fields", []))
		_merge_names(visual, final_settled.get("visual_changed", []))
		now_utc = target_utc_seconds
		segments += 1
	return {
		"ok": true, "reason": "", "changed_fields": changed,
		"reward_crop_id": "", "reward_amount": 0,
		"visual_changed": visual, "segments": segments,
	}


func save() -> Dictionary:
	if farm == null:
		return _failure("not_open")
	return store.save_state(farm, decorations)


## The full restorable authority as one document: the same two snapshots
## FarmStore persists, plus the logical clock. A member that lost the event tail
## restores from this instead of accepting a hole in its history.
func state_snapshot() -> Dictionary:
	if farm == null:
		return {}
	return {"now_utc": now_utc, "farm": farm.snapshot(), "decorations": decorations.snapshot()}


func summary() -> Dictionary:
	if farm == null:
		return {}
	var hud: Dictionary = farm.hud_state()
	var snapshot: Dictionary = farm.snapshot()
	var fields: Dictionary = {}
	for field_id: String in snapshot.fields:
		var cells: Dictionary = {}
		for cell_id: String in snapshot.fields[field_id].cells:
			var cell: Dictionary = farm.get_cell(field_id, cell_id)
			cells[cell_id] = {
				"crop_id": cell.crop_id, "stage": cell.stage, "ground": cell.ground,
				"growth_seconds": cell.growth_seconds, "watered": cell.watered,
			}
		fields[field_id] = cells
	var next_event: float = next_event_utc()
	return {
		"now_utc": now_utc, "inventory": hud.inventory, "harvested": hud.harvested,
		"bags": snapshot.bags.duplicate(true),
		"fields": fields, "committed_commands": farm.committed_command_count(),
		"committed_sequence": farm.event_sequence(),
		"next_event_utc": next_event if is_finite(next_event) else null,
	}


static func _merge_names(into: Array[String], values: Variant) -> void:
	if not values is Array:
		return
	for value: Variant in values:
		if value is String and not into.has(value):
			into.append(value)


static func _result(ok: bool, reason: String, duplicate: bool, command_id: String) -> Dictionary:
	return {"ok": ok, "reason": reason, "duplicate": duplicate, "command_id": command_id}


static func _failure(kind: String) -> Dictionary:
	return {"ok": false, "reason": kind}


static func _valid_time(value: float) -> bool:
	return is_finite(value) and value >= 0.0
