extends SceneTree
## M3-01 executable headless world runner. Starts a world from an isolated
## FarmStore directory, runs an optional command sequence, advances UTC through
## FarmState, saves, reopens and prints one machine-readable summary line.
##
## Usage:
##   godot --headless --path Game --script res://world/headless_runner.gd -- \
##     --data-dir=.local/verification/run --seed=7 --advance-seconds=9000 \
##     --commands="sow:field_01:cell_01:greens@0;water:field_01:cell_01@60;harvest:field_01:cell_01@9000"
##
## Command syntax: action:field:cell[:crop][@offset_seconds]. Offsets are
## relative to the world start and must not move backwards.
##
## Simulation lab: add --worlds=N (2..16). Each world runs the same command
## plan in its own subdirectory with seed base + index * 7919 and the aggregate
## is printed as one HEADLESS_WORLDS line. Repeated runs with the same seeds
## must produce identical world summaries.

const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const DEFAULT_START: float = 1800000000.0
const ACTIONS: Array[String] = ["sow", "water", "harvest", "weed", "till"]

var _checks: int = 0
var _failures: Array[String] = []


func _initialize() -> void:
	var started: int = Time.get_ticks_usec()
	var options: Dictionary = _options()
	var worlds: int = _world_count(options)
	if worlds < 0:
		quit(2)
		return
	if worlds > 1:
		_run_lab(options, worlds, started)
		return
	var report: Dictionary = _run(options)
	report["checks"] = _checks
	report["failures"] = _failures
	report["elapsed_ms"] = snappedf(float(Time.get_ticks_usec() - started) / 1000.0, 0.001)
	report["memory_static_bytes"] = int(OS.get_static_memory_usage())
	report["memory_static_peak_bytes"] = int(OS.get_static_memory_peak_usage())
	report["root_children"] = get_root().get_child_count()
	report["engine"] = Engine.get_version_info().string
	print("HEADLESS_WORLD " + JSON.stringify(report))
	quit(0 if report.get("ok", false) and _failures.is_empty() else 1)


func _world_count(options: Dictionary) -> int:
	if not options.has("worlds"):
		return 1
	var text: String = str(options.worlds)
	if not text.is_valid_int() or int(text) < 2 or int(text) > 16:
		print("HEADLESS_WORLDS " + JSON.stringify({"ok": false, "reason": "invalid_worlds"}))
		return -1
	return int(text)


func _run_lab(options: Dictionary, worlds: int, started: int) -> void:
	var raw_directory: String = str(options.get("data-dir", ""))
	if raw_directory.is_empty():
		print("HEADLESS_WORLDS " + JSON.stringify({"ok": false, "reason": "missing_argument", "argument": "data-dir"}))
		quit(2)
		return
	var base_seed: int = 0
	if options.has("seed"):
		var seed_text: String = str(options.seed)
		if not seed_text.is_valid_int():
			print("HEADLESS_WORLDS " + JSON.stringify({"ok": false, "reason": "invalid_seed"}))
			quit(2)
			return
		base_seed = int(seed_text)
	var base_directory: String = _resolve(raw_directory)
	var results: Array[Dictionary] = []
	for index: int in worlds:
		var per_world: Dictionary = options.duplicate(true)
		per_world["data-dir"] = base_directory.path_join("world-%02d" % index)
		per_world["seed"] = str(base_seed + index * 7919)
		var failures_before: int = _failures.size()
		var report: Dictionary = _run(per_world)
		var world_failures: Array = _failures.slice(failures_before)
		results.append({
			"index": index,
			"seed": int(per_world.seed),
			"ok": bool(report.get("ok", false)) and world_failures.is_empty(),
			"reason": str(report.get("reason", "")),
			"inventory": report.get("inventory", {}),
			"harvested": report.get("harvested", {}),
			"committed_commands": report.get("committed_commands", 0),
			"committed_sequence": report.get("committed_sequence", 0),
			"next_event_utc": report.get("next_event_utc", null),
			"segments": report.get("segments", 0),
			"data_directory": report.get("data_directory", ""),
			"failures": world_failures,
		})
	var aggregate: Dictionary = {
		"ok": _failures.is_empty(),
		"worlds": worlds,
		"seed": base_seed,
		"checks": _checks,
		"failures": _failures,
		"root_children": get_root().get_child_count(),
		"elapsed_ms": snappedf(float(Time.get_ticks_usec() - started) / 1000.0, 0.001),
		"memory_static_peak_bytes": int(OS.get_static_memory_peak_usage()),
		"results": results,
	}
	print("HEADLESS_WORLDS " + JSON.stringify(aggregate))
	quit(0 if aggregate.ok else 1)


func _run(options: Dictionary) -> Dictionary:
	var raw_directory: String = str(options.get("data-dir", ""))
	if not _check(not raw_directory.is_empty(), "data-dir"):
		return {"ok": false, "reason": "missing_argument", "argument": "data-dir"}
	var seed_value: int = 0
	if options.has("seed"):
		var seed_text: String = str(options.seed)
		if not _check(seed_text.is_valid_int(), "seed"):
			return {"ok": false, "reason": "invalid_seed"}
		seed_value = int(seed_text)
	var start: float = DEFAULT_START + float(posmod(seed_value, 86400))
	if options.has("start-utc"):
		var start_text: String = str(options["start-utc"])
		if not _check(_nonnegative(start_text), "start-utc"):
			return {"ok": false, "reason": "invalid_start_utc"}
		start = float(start_text)
	var advance: float = 0.0
	if options.has("advance-seconds"):
		var advance_text: String = str(options["advance-seconds"])
		if not _check(_nonnegative(advance_text), "advance-seconds"):
			return {"ok": false, "reason": "invalid_advance_seconds"}
		advance = float(advance_text)
	var explicit_target: bool = options.has("target-utc")
	var target: float = start + advance
	if explicit_target:
		var target_text: String = str(options["target-utc"])
		if not _check(_nonnegative(target_text), "target-utc"):
			return {"ok": false, "reason": "invalid_target_utc"}
		target = float(target_text)

	var data_directory: String = _resolve(raw_directory)
	# M3-01 experiments only run on isolated data. The live v27 save is not a
	# valid target until the command/recovery boundary exists (M3-03).
	var live_save: String = ProjectSettings.globalize_path("user://farm-v27").simplify_path()
	if data_directory == live_save:
		_check(false, "live_save_directory")
		return {"ok": false, "reason": "live_save_directory", "seed": seed_value,
			"start_utc": start, "data_directory": _label(data_directory)}
	var world := HeadlessWorld.new()
	var opened: Dictionary = world.open(data_directory, start)
	if not _check(opened.ok, "world_open:" + str(opened.get("reason", ""))):
		return {"ok": false, "reason": str(opened.reason), "seed": seed_value,
			"start_utc": start, "data_directory": _label(data_directory)}
	var command_results: Array[Dictionary] = _execute_commands(
		world, str(options.get("commands", "")), start)
	var last_command_time: float = start
	for entry: Dictionary in command_results:
		last_command_time = maxf(last_command_time, float(entry.at_utc))
	for entry: Dictionary in command_results:
		if not entry.ok:
			return {"ok": false, "reason": "command_" + str(entry.reason), "seed": seed_value,
				"start_utc": start, "data_directory": _label(data_directory),
				"commands": command_results}
	if target < last_command_time:
		if explicit_target:
			_check(false, "target_before_commands")
			return {"ok": false, "reason": "target_before_commands", "seed": seed_value,
				"start_utc": start, "data_directory": _label(data_directory)}
		target = last_command_time
	var advanced: Dictionary = world.advance_to(target)
	_check(advanced.ok, "advance:" + str(advanced.get("reason", "")))
	if not advanced.ok:
		return {"ok": false, "reason": str(advanced.reason), "seed": seed_value,
			"start_utc": start, "data_directory": _label(data_directory)}
	var saved: Dictionary = world.save()
	_check(saved.ok, "save:" + str(saved.get("kind", "")))
	var summary: Dictionary = world.summary()

	var reopened := HeadlessWorld.new()
	var reopen: Dictionary = reopened.open(data_directory, target)
	_check(reopen.ok, "reopen:" + str(reopen.get("reason", "")))
	if reopen.ok:
		_check(reopened.farm.snapshot() == world.farm.snapshot(), "reopen_farm")
		_check(reopened.decorations.snapshot() == world.decorations.snapshot(), "reopen_decorations")
	# A headless SceneTree script has no scene node; this is the runtime check
	# that the main 3D farm was not instantiated.
	_check(get_root().get_child_count() == 0, "no_scene_nodes")

	var report: Dictionary = summary.duplicate(true)
	report["ok"] = saved.ok and advanced.ok and reopen.ok and _failures.is_empty()
	report["seed"] = seed_value
	report["start_utc"] = start
	report["target_utc"] = target
	report["advance_seconds"] = target - start
	report["segments"] = int(advanced.get("segments", 0))
	report["opened"] = opened.kind
	report["commands"] = command_results
	report["data_directory"] = _label(data_directory)
	return report


func _execute_commands(world: RefCounted, spec: String, start: float) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var body: String = spec.strip_edges()
	if body.is_empty():
		return results
	var index: int = 0
	var last_time: float = start
	for part: String in body.split(";", false):
		index += 1
		var parsed: Dictionary = _parse_command(part, start)
		if not parsed.ok:
			_check(false, "command_parse:" + str(parsed.reason))
			results.append({"ok": false, "reason": parsed.reason, "at_utc": start})
			return results
		if float(parsed.at_utc) < last_time:
			_check(false, "command_order")
			results.append({"ok": false, "reason": "command_order", "at_utc": parsed.at_utc})
			return results
		last_time = float(parsed.at_utc)
		var id: String = "headless-%d" % index
		var command: Dictionary
		match str(parsed.action):
			"sow":
				command = FarmCommand.make_sow(id, parsed.field_id, parsed.cell_id, parsed.crop_id, parsed.at_utc)
			"water":
				command = FarmCommand.make_water(id, parsed.field_id, parsed.cell_id, parsed.at_utc)
			"weed", "till":
				command = FarmCommand.make_tidy(id, parsed.action, parsed.field_id, parsed.cell_id, parsed.at_utc)
			_:
				command = FarmCommand.make(id, parsed.field_id, parsed.cell_id, parsed.at_utc)
		var execution: Dictionary = world.execute(command)
		_check(execution.ok, "command:%d:%s" % [index, parsed.action])
		results.append({
			"id": id, "kind": command.kind, "field_id": parsed.field_id, "cell_id": parsed.cell_id,
			"crop_id": str(command.get("crop_id", "")), "at_utc": parsed.at_utc,
			"ok": execution.ok, "reason": execution.reason, "duplicate": execution.duplicate,
			"stage": execution.get("stage", ""), "reward_crop_id": execution.get("reward_crop_id", ""),
			"reward_amount": execution.get("reward_amount", 0),
		})
		if not execution.ok:
			return results
	return results


func _parse_command(text: String, start: float) -> Dictionary:
	# offsets are relative seconds; an omitted offset means the world start.
	var body: String = text.strip_edges()
	if body.is_empty():
		return {"ok": false, "reason": "empty_command"}
	var at: float = start
	var at_index: int = body.rfind("@")
	if at_index >= 0:
		var offset_text: String = body.substr(at_index + 1)
		if not offset_text.is_valid_float():
			return {"ok": false, "reason": "invalid_offset"}
		at = start + float(offset_text)
		body = body.substr(0, at_index)
	if not _valid_time(at):
		return {"ok": false, "reason": "invalid_time"}
	var pieces: PackedStringArray = body.split(":", true)
	if pieces.size() < 3 or pieces.size() > 4:
		return {"ok": false, "reason": "invalid_command"}
	var action: String = pieces[0]
	if action not in ACTIONS:
		return {"ok": false, "reason": "invalid_action"}
	if action == "sow" and pieces.size() != 4:
		return {"ok": false, "reason": "missing_crop"}
	if action != "sow" and pieces.size() == 4:
		return {"ok": false, "reason": "unexpected_crop"}
	if pieces[1].is_empty() or pieces[2].is_empty():
		return {"ok": false, "reason": "invalid_target"}
	return {
		"ok": true, "action": action, "field_id": pieces[1], "cell_id": pieces[2],
		"crop_id": pieces[3] if action == "sow" else "", "at_utc": at,
	}


func _check(condition: bool, label: String) -> bool:
	_checks += 1
	if not condition:
		_failures.append(label)
	return condition


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


func _resolve(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path).simplify_path()
	if path.is_absolute_path():
		return path.simplify_path()
	return _repo_root().path_join(path).simplify_path()


func _repo_root() -> String:
	return ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/").get_base_dir()


func _label(path: String) -> String:
	# Diagnostics avoid real paths: prefer a repository-relative label, then a
	# home-relative one, and otherwise the final directory name only.
	var repo: String = _repo_root()
	if path == repo:
		return "<repo>"
	if path.begins_with(repo + "/"):
		return path.trim_prefix(repo + "/")
	var home: String = OS.get_environment("HOME")
	if home.is_empty():
		home = OS.get_environment("USERPROFILE")
	home = home.replace("\\", "/").simplify_path().trim_suffix("/")
	if not home.is_empty() and path == home:
		return "<home>"
	if not home.is_empty() and path.begins_with(home + "/"):
		return "<home>/" + path.trim_prefix(home + "/")
	return path.get_file()


static func _nonnegative(text: String) -> bool:
	return text.is_valid_float() and is_finite(float(text)) and float(text) >= 0.0


static func _valid_time(value: float) -> bool:
	return is_finite(value) and value >= 0.0
