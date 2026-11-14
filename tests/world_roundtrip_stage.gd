extends SceneTree
## Cross-device world handoff stage used by world-roundtrip.yml.
## Each stage runs in a separate CI job and prints one ROUNDTRIP_STAGE line.

const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const WorldTransfer = preload("res://farm/world_transfer.gd")
const Importer = preload("res://farm/v27_importer.gd")
const START: float = 1800000000.0
const HARVEST_AT: float = 1800009000.0

var mode: String = ""
var directory: String = ""
var package_source: String = ""
var export_target: String = ""
var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--mode="): mode = argument.trim_prefix("--mode=")
		elif argument.begins_with("--dir="): directory = argument.trim_prefix("--dir=")
		elif argument.begins_with("--package="): package_source = argument.trim_prefix("--package=")
		elif argument.begins_with("--export="): export_target = argument.trim_prefix("--export=")
	match mode:
		"create": _create()
		"modify": _modify()
		"continue": _continue()
		_: _expect(false, "Unknown stage mode: " + mode)
	_finish()


func _create() -> void:
	var world := HeadlessWorld.new()
	_expect(world.open(directory, START).ok, "create: world opens")
	_expect(world.execute(FarmCommand.make_sow("roundtrip-sow", "field_01", "cell_01", "greens", START)).ok,
		"create: sow commits")
	_expect(world.execute(FarmCommand.make_water("roundtrip-water", "field_01", "cell_01", START + 60.0)).ok,
		"create: water commits")
	_expect(world.advance_to(HARVEST_AT).ok and world.farm.get_cell("field_01", "cell_01").stage == "mature",
		"create: crop matures at the shared logical time")
	_expect(world.save().ok, "create: mature world saves")
	var exported: Dictionary = WorldTransfer.export_world(directory, export_target)
	_expect(exported.ok, "create: world exports: " + str(exported.get("kind", "")))
	if not exported.ok:
		return
	var summary: Dictionary = exported.summary
	_expect(not str(summary.world_id).is_empty() and not str(summary.player_id).is_empty(),
		"create: package carries stable world and player identity")
	_report({"world_id": summary.world_id, "farm_id": summary.farm_id,
		"player_id": summary.player_id, "device_id": summary.device_id})


func _modify() -> void:
	var imported: Dictionary = _apply()
	if not imported.get("ok", false):
		return
	var world := HeadlessWorld.new()
	_expect(world.open(directory, HARVEST_AT).ok, "modify: imported world opens")
	var cell: Dictionary = world.farm.get_cell("field_01", "cell_01")
	_expect(cell.stage == "mature" and cell.crop_id == "greens",
		"modify: imported crop keeps crop, stage and lifetime")
	_expect(world.farm.hud_state().harvested.greens == 0, "modify: imported world has no prior harvest")
	_expect(world.execute(FarmCommand.make("roundtrip-harvest", "field_01", "cell_01", HARVEST_AT)).ok,
		"modify: harvest commits on the second machine")
	_expect(world.execute(FarmCommand.make_sow("roundtrip-radish", "field_01", "cell_02", "radish", HARVEST_AT)).ok,
		"modify: second machine adds a new crop")
	_expect(world.save().ok, "modify: modified world saves")
	var exported: Dictionary = WorldTransfer.export_world(directory, export_target)
	_expect(exported.ok, "modify: modified world exports: " + str(exported.get("kind", "")))
	if not exported.ok:
		return
	var summary: Dictionary = exported.summary
	var identity: Dictionary = Importer.read_identity(directory.path_join(Importer.IDENTITY_FILE))
	_expect(identity.get("ok", false)
		and identity.get("identity", {}).get("player_id", "") == imported.summary.player_id,
		"modify: export keeps the package player identity")
	# world_id and farm_id are content-derived dedup keys, so a real modification
	# legitimately changes them; identity must not change.
	_expect(summary.player_id == imported.summary.player_id
		and summary.device_id == imported.summary.device_id,
		"modify: export keeps the package identity")
	_expect(bool(summary.get("changed", false)), "modify: export records the changed world")
	_report({"world_id": summary.world_id, "farm_id": summary.farm_id,
		"player_id": summary.player_id, "device_id": summary.device_id})


func _continue() -> void:
	var imported: Dictionary = _apply()
	if not imported.get("ok", false):
		return
	var world := HeadlessWorld.new()
	_expect(world.open(directory, HARVEST_AT).ok, "continue: returned world opens")
	var data: Dictionary = world.farm.snapshot()
	var cell_one: Dictionary = data.fields.field_01.cells.cell_01
	var cell_two: Dictionary = data.fields.field_01.cells.cell_02
	_expect(data.harvested.greens == 1 and data.inventory.greens == 1,
		"continue: the harvest made on the other machine is present exactly once")
	_expect(cell_one.crop_id == "", "continue: the harvested cell stays empty")
	_expect(cell_two.crop_id == "radish" and int(cell_two.growth_seconds) == 0,
		"continue: the crop planted on the other machine is present")
	var identity: Dictionary = Importer.read_identity(directory.path_join(Importer.IDENTITY_FILE))
	var saved_identity: Dictionary = identity.get("identity", {})
	_expect(identity.get("ok", false)
		and saved_identity.get("player_id", "") == imported.summary.player_id
		and saved_identity.get("device_id", "") == imported.summary.device_id,
		"continue: identity follows the package across both machines")
	_report({"world_id": imported.summary.world_id, "farm_id": imported.summary.farm_id,
		"player_id": imported.summary.player_id, "device_id": imported.summary.device_id})


func _apply() -> Dictionary:
	var prepared: Dictionary = WorldTransfer.prepare_import(package_source, directory)
	_expect(prepared.ok, "import: package validates before writing: " + str(prepared.get("kind", "")))
	if not prepared.ok:
		return {}
	var applied: Dictionary = WorldTransfer.apply_import(prepared, directory)
	_expect(applied.ok and applied.get("identity_saved", false),
		"import: state and identity commit together: " + str(applied.get("kind", "")))
	if not applied.ok:
		return {}
	return prepared


func _report(extra: Dictionary) -> void:
	var report: Dictionary = {"mode": mode, "ok": failures.is_empty(), "checks": checks,
		"failures": failures.size()}
	report.merge(extra, true)
	print("ROUNDTRIP_STAGE " + JSON.stringify(report))


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("WORLD_ROUNDTRIP_STAGE mode=%s checks=%d failures=%d" % [mode, checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
