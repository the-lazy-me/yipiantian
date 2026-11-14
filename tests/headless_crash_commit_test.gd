extends SceneTree
## M3-03 slice: terminate a committing child at each durable file boundary and
## verify recovery keeps one committed reward. Fixtures stay below .local/.

const FarmStore = preload("res://farm/farm_store.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const START: float = 1800000000.0
const HARVEST_AT: float = 1800009000.0
const COMMAND_ID: String = "crash-harvest"
const STAGES: Array[String] = ["pending_written", "backup_replaced", "before_main_replace", "main_replaced"]

var checks: int = 0
var failures: Array[String] = []
var test_root: String
var child_directory: String = ""
var child_stage: String = ""
var child_marker: String = ""


func _initialize() -> void:
	if OS.get_cmdline_user_args().has("--child"):
		_parse_child()
		_run_child()
		return
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	test_root = project_root.get_base_dir().path_join(
		".local/verification/headless-crash-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(test_root)
	_run_parent()
	for failure: String in failures:
		push_error(failure)
	print("HEADLESS_CRASH_COMMIT_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _parse_child() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--dir="): child_directory = argument.trim_prefix("--dir=")
		elif argument.begins_with("--stage="): child_stage = argument.trim_prefix("--stage=")
		elif argument.begins_with("--marker="): child_marker = argument.trim_prefix("--marker=")


func _run_child() -> void:
	if child_directory.is_empty() or child_stage.is_empty() or child_marker.is_empty():
		quit(2)
		return
	FarmStore.fault_hook = func(stage: String) -> void:
		if stage != child_stage:
			return
		var marker := FileAccess.open(child_marker, FileAccess.WRITE)
		if marker != null:
			marker.store_string(stage)
			marker.flush()
			marker.close()
		OS.kill(OS.get_process_id())
	var world := HeadlessWorld.new()
	if not world.open(child_directory, HARVEST_AT).ok:
		quit(4)
		return
	var result: Dictionary = world.execute(FarmCommand.make(COMMAND_ID, "field_01", "cell_01", HARVEST_AT))
	if not FileAccess.file_exists(child_directory.path_join(FarmStore.MAIN)):
		# The first save has no mature fixture; sowing is the action whose
		# commit is interrupted.
		result = world.execute(FarmCommand.make_sow(COMMAND_ID, "field_01", "cell_01", "greens", HARVEST_AT))
	print("CRASH_CHILD_SURVIVED stage=%s ok=%s" % [child_stage, result.get("ok", false)])
	quit(5)


func _run_parent() -> void:
	for stage: String in STAGES:
		_check_stage(stage)
	_check_first_creation_without_prior_state()


func _check_stage(stage: String) -> void:
	var directory: String = test_root.path_join(stage)
	_expect(_prepare_committed_world(directory), "%s fixture starts from one committed mature crop" % stage)
	var marker: String = test_root.path_join(stage + ".marker")
	var output: Array = []
	var project: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	var script: String = project.get_base_dir().path_join("tests/headless_crash_commit_test.gd").simplify_path()
	var arguments: Array[String] = [
		"--headless", "--path", project, "--script", script, "--",
		"--child", "--dir=" + directory, "--stage=" + stage, "--marker=" + marker,
	]
	OS.execute(OS.get_executable_path(), arguments, output, true)
	_expect(FileAccess.file_exists(marker) and FileAccess.get_file_as_string(marker) == stage,
		"%s: child reached the named commit boundary" % stage)
	_expect(not _survived(output), "%s: child did not continue past the forced termination" % stage)
	# Each boundary leaves a different durable footprint; the main file must
	# still be one complete version, never a partial write.
	var pending: bool = FileAccess.file_exists(directory.path_join(FarmStore.PENDING))
	var backup: bool = FileAccess.file_exists(directory.path_join(FarmStore.BACKUP))
	match stage:
		"pending_written", "before_main_replace": _expect(pending, stage + ": candidate remains staged before main replacement")
		"backup_replaced": _expect(backup and pending, stage + ": previous main became backup; the new candidate is still staged")
		"main_replaced": _expect(not pending and backup, stage + ": candidate replaced main; previous main remains as backup")
	var store := FarmStore.new(directory)
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok and loaded.kind == "loaded", stage + ": recovery loads one complete committed version")
	if not loaded.ok:
		return
	var harvested: Dictionary = loaded.farm.harvested
	var cell: Dictionary = loaded.farm.fields.field_01.cells.cell_01
	if stage == "main_replaced":
		_expect(harvested.greens == 1 and cell.crop_id == "", stage + ": the acknowledged-late commit is exactly one reward")
	else:
		_expect(harvested.greens == 0 and cell.crop_id == "greens", stage + ": the uncommitted candidate never reaches the main state")
	var reopened := HeadlessWorld.new()
	_expect(reopened.open(directory, HARVEST_AT).ok, stage + ": the world reopens after the crash")
	var retry: Dictionary = reopened.execute(FarmCommand.make(COMMAND_ID, "field_01", "cell_01", HARVEST_AT))
	if stage == "main_replaced":
		_expect(retry.ok and retry.duplicate and retry.stage == "duplicate",
			stage + ": the committed result replays from the durable ledger")
	else:
		_expect(retry.ok and retry.stage == "committed", stage + ": the caller retries the lost acknowledgement once")
	_expect(reopened.farm.hud_state().harvested.greens == 1,
		stage + ": one crop is harvested across crash and retry")
	_expect(reopened.farm.get_cell("field_01", "cell_01").stage == "empty",
		stage + ": the cell is empty after the single reward")
	# The command result and sequence travel with the farm snapshot, so the
	# replay works in a brand-new process rather than relying on cell admission.
	var again: Dictionary = reopened.execute(FarmCommand.make(COMMAND_ID, "field_01", "cell_01", HARVEST_AT))
	_expect(again.duplicate and again.ok and reopened.farm.hud_state().harvested.greens == 1,
		stage + ": the retried command id replays from the ledger without a second reward")
	_expect(int(loaded.farm.transaction.sequence) == (2 if stage == "main_replaced" else 1),
		stage + ": the durable event sequence counts the fixture sow plus exactly the committed reward")


func _check_first_creation_without_prior_state() -> void:
	# A crash during the very first save leaves no committed main. The store
	# withholds it from normal loading and requires explicit recovery.
	var directory: String = test_root.path_join("first_creation")
	DirAccess.make_dir_recursive_absolute(directory)
	var marker: String = test_root.path_join("first_creation.marker")
	var output: Array = []
	var project: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	var script: String = project.get_base_dir().path_join("tests/headless_crash_commit_test.gd").simplify_path()
	var arguments: Array[String] = [
		"--headless", "--path", project, "--script", script, "--",
		"--child", "--dir=" + directory, "--stage=pending_written", "--marker=" + marker,
	]
	OS.execute(OS.get_executable_path(), arguments, output, true)
	_expect(FileAccess.file_exists(marker) and not _survived(output),
		"A first-save crash stops before any committed main")
	var store := FarmStore.new(directory)
	var loaded: Dictionary = store.load_state()
	_expect(not loaded.ok and loaded.kind == "recovery_available" and loaded.source == FarmStore.PENDING,
		"An interrupted first save is offered only as explicit recovery")
	_expect(not FileAccess.file_exists(directory.path_join(FarmStore.MAIN)),
		"An interrupted first save never manufactures a committed main")


func _survived(output: Array) -> bool:
	# Windows reports a self-terminated process as exit code 0, so the child's
	# explicit survival marker is the portable signal, not the exit status.
	for line: Variant in output:
		if str(line).begins_with("CRASH_CHILD_SURVIVED"):
			return true
	return false


func _prepare_committed_world(directory: String) -> bool:
	var world := HeadlessWorld.new()
	if not world.open(directory, START).ok:
		return false
	if not world.execute(FarmCommand.make_sow("fixture-sow", "field_01", "cell_01", "greens", START)).ok:
		return false
	if not world.advance_to(HARVEST_AT).ok:
		return false
	return world.save().ok


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
