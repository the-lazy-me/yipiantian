extends SceneTree
## Headless world entry for M0: run one harvest command without the farm scene.
## Usage: godot --headless --path Game --script res://farm/world_command_entry.gd -- --save-dir=... --id=... --field=field_03 --cell=cell_06 --now=1800000000

const FarmState = preload("res://farm/farm_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const FarmCommand = preload("res://farm/farm_command.gd")


func _initialize() -> void:
	var options: Dictionary = _options()
	for key: String in ["save-dir", "id", "field", "cell", "now"]:
		if not options.has(key) or str(options[key]).is_empty():
			_fail("missing_argument", {"argument": key})
			return
	var now: String = str(options.now)
	if not now.is_valid_float() or not is_finite(float(now)) or float(now) < 0.0:
		_fail("invalid_now", {})
		return
	var command: Dictionary = FarmCommand.make(str(options.id), str(options.field), str(options.cell), float(now))
	if not FarmCommand.valid(command):
		_fail("invalid_command", {})
		return

	var store := FarmStore.new(str(options["save-dir"]))
	var loaded: Dictionary = store.load_state()
	if not loaded.ok:
		_fail("load_" + str(loaded.kind), {})
		return
	var farm: RefCounted
	var decorations: RefCounted
	if loaded.kind == "missing":
		farm = FarmState.new(float(now))
		decorations = Decorations.new()
	else:
		farm = FarmState.new()
		if not farm.restore_snapshot(loaded.farm):
			_fail("restore_farm", {})
			return
		decorations = Decorations.new()
		if not decorations.restore_snapshot(loaded.decorations):
			_fail("restore_decorations", {})
			return

	var commands := FarmCommand.new()
	var execution: Dictionary = commands.execute(farm, command)
	if not execution.ok:
		_fail("command_" + str(execution.reason), {"command_id": command.id})
		return
	if execution.duplicate:
		_report(command, execution.result, farm, "duplicate")
		return
	var candidate: RefCounted = execution.candidate
	var snapshot: Dictionary = candidate.snapshot()
	decorations.unlock(snapshot.harvested, snapshot.kitchen)
	var saved: Dictionary = store.save_state(candidate, decorations)
	if not saved.ok:
		_fail("save_" + str(saved.kind), {"command_id": command.id})
		return
	farm.accept(candidate)
	commands.commit(command, execution.result)
	_report(command, execution.result, farm, "committed")


func _report(command: Dictionary, result: Dictionary, farm: RefCounted, stage: String) -> void:
	var hud: Dictionary = farm.hud_state()
	print("WORLD_COMMAND " + JSON.stringify({
		"ok": true, "stage": stage, "command_id": command.id, "kind": command.kind,
		"field_id": command.field_id, "cell_id": command.cell_id,
		"reward_crop_id": result.get("reward_crop_id", ""), "reward_amount": result.get("reward_amount", 0),
		"inventory": hud.inventory,
	}))
	quit(0)


func _fail(reason: String, detail: Dictionary) -> void:
	print("WORLD_COMMAND " + JSON.stringify({"ok": false, "reason": reason}.merged(detail, true)))
	quit(1)


func _options() -> Dictionary:
	var result: Dictionary = {}
	for argument: String in OS.get_cmdline_user_args():
		if not argument.begins_with("--"):
			continue
		var body: String = argument.trim_prefix("--")
		var split: int = body.find("=")
		if split <= 0:
			continue
		result[body.substr(0, split)] = body.substr(split + 1)
	return result
