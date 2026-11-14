extends SceneTree
## M3-01: headless world session, command chain, long advance and storage failures.
## Fixtures stay below .local/verification.

const Farm = preload("res://farm/farm_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const START: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	test_root = project_root.get_base_dir().path_join(
		".local/verification/headless-world-runtime-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(test_root)
	_run()
	for failure: String in failures:
		push_error(failure)
	print("HEADLESS_WORLD_RUNTIME_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run() -> void:
	_test_fresh_start()
	_test_command_chain()
	_test_command_lag()
	_test_long_advance()
	_test_reopen_after_actions()
	_test_failure_preserves_save()
	_test_corrupt_load_preserves_file()


func _test_fresh_start() -> void:
	var directory: String = test_root.path_join("fresh")
	var world := HeadlessWorld.new()
	var opened: Dictionary = world.open(directory, START)
	_expect(opened.ok and opened.kind == "created", "A new world starts without a scene or save")
	_expect(world.farm.hud_state().inventory.greens == 0, "The new world has an empty inventory")
	_expect(get_root().get_child_count() == 0, "No scene node is instantiated")
	var saved: Dictionary = world.save()
	_expect(saved.ok, "The fresh world saves through FarmStore")
	_expect(FileAccess.file_exists(directory.path_join(FarmStore.MAIN)), "The save file is created")

	var reopened := HeadlessWorld.new()
	var reloaded: Dictionary = reopened.open(directory, START)
	_expect(reloaded.ok and reloaded.kind == "loaded", "The saved world reopens")
	_expect(reopened.farm.snapshot() == world.farm.snapshot(), "Reopened farm matches the saved snapshot")
	_expect(reopened.decorations.snapshot() == world.decorations.snapshot(), "Reopened decorations match")


func _test_command_chain() -> void:
	var directory: String = test_root.path_join("commands")
	var world := HeadlessWorld.new()
	_expect(world.open(directory, START).ok, "A command-chain world starts")
	var sow: Dictionary = FarmCommand.make_sow("chain-sow", "field_01", "cell_01", "greens", START)
	var sown: Dictionary = world.execute(sow)
	_expect(sown.ok and sown.stage == "committed", "Sow commits through the command chain")
	_expect(FileAccess.file_exists(directory.path_join(FarmStore.MAIN)), "Each committed command saves")
	var water: Dictionary = FarmCommand.make_water("chain-water", "field_01", "cell_01", START + 60)
	_expect(world.execute(water).ok, "Water commits through the command chain")
	_expect(world.farm.get_cell("field_01", "cell_01").watered, "Water reaches the rule owner")
	_expect(world.advance_to(START + 9000).ok, "Logical time advances without a scene")
	_expect(world.farm.get_cell("field_01", "cell_01").stage == "mature", "The crop matures by UTC settlement")

	var harvest: Dictionary = FarmCommand.make("chain-harvest", "field_01", "cell_01", START + 9000)
	var harvested: Dictionary = world.execute(harvest)
	_expect(harvested.ok and harvested.reward_crop_id == "greens", "Harvest commits one reward")
	_expect(world.farm.hud_state().inventory.greens == 1, "Harvest adds exactly one crop")
	_expect(world.farm.get_cell("field_01", "cell_01").stage == "empty", "The harvested cell becomes empty")

	var replay: Dictionary = world.execute(harvest)
	_expect(replay.ok and replay.duplicate, "A repeated harvest command is reported as duplicate")
	_expect(world.farm.hud_state().inventory.greens == 1, "A repeated harvest does not mint a second crop")
	_expect(world.execute(sow).duplicate, "A repeated sow command is reported as duplicate")
	_expect(world.execute(water).duplicate, "A repeated water command is reported as duplicate")
	_expect(world.farm.hud_state().inventory.greens == 1, "Replayed commands leave inventory unchanged")
	var backwards: Dictionary = world.execute(
		FarmCommand.make_water("chain-backwards", "field_01", "cell_02", START - 10))
	_expect(not backwards.ok and backwards.reason == "time_backwards",
		"A command before the world baseline is refused")
	_expect(not world.advance_to(START + 1).ok, "A backwards advance is refused")

	var direct := Farm.new(START, {}, world.nature)
	direct.sow("field_01", "cell_01", "greens", START)
	direct.water("field_01", "cell_01", START + 60)
	direct.harvest("field_01", "cell_01", START + 9000)
	var world_snapshot: Dictionary = world.farm.snapshot()
	var direct_snapshot: Dictionary = direct.snapshot()
	world_snapshot.erase("transaction")
	direct_snapshot.erase("transaction")
	_expect(world_snapshot == direct_snapshot, "The command chain matches direct FarmState calls")


func _test_command_lag() -> void:
	# 跨进程客户端用上一次摘要的时钟打戳，命令到达时总是略落后于权威时钟。
	var directory: String = test_root.path_join("lag")
	var world := HeadlessWorld.new()
	_expect(world.open(directory, START).ok, "A lag world starts")
	_expect(world.advance_to(START + 600.0).ok, "The lag world advances ahead of the client clock")
	var lagged: Dictionary = world.execute(FarmCommand.make_sow(
		"lag-sow", "field_01", "cell_01", "greens", world.now_utc - 0.5))
	_expect(lagged.ok, "A command inside the transit allowance still commits")
	var stale: Dictionary = world.execute(FarmCommand.make_sow(
		"lag-stale", "field_01", "cell_02", "greens",
		world.now_utc - HeadlessWorld.COMMAND_CLOCK_TOLERANCE - 1.0))
	_expect(not stale.ok and stale.reason == "time_backwards",
		"A command older than the transit allowance is still refused")


func _test_long_advance() -> void:
	var directory: String = test_root.path_join("long")
	var world := HeadlessWorld.new()
	_expect(world.open(directory, START).ok, "A long-advance world starts")
	world.execute(FarmCommand.make_sow("long-sow", "field_01", "cell_01", "greens", START))
	world.execute(FarmCommand.make_water("long-water", "field_01", "cell_01", START + 60))
	var target: float = START + 30.0 * 86400.0
	var advanced: Dictionary = world.advance_to(target)
	_expect(advanced.ok, "A thirty-day advance succeeds")

	var direct := Farm.new(START, {}, world.nature)
	direct.sow("field_01", "cell_01", "greens", START)
	direct.water("field_01", "cell_01", START + 60)
	direct.settle(target)
	var world_snapshot: Dictionary = world.farm.snapshot()
	var direct_snapshot: Dictionary = direct.snapshot()
	# The command ledger is command-boundary state; rule settlement is compared
	# without it, and its own persistence is asserted separately.
	world_snapshot.erase("transaction")
	direct_snapshot.erase("transaction")
	_expect(world_snapshot == direct_snapshot, "Long advance matches direct FarmState settlement")
	_expect(world.farm.get_cell("field_01", "cell_01").stage == "mature", "Growth stays capped at maturity")
	_expect(world.save().ok, "The long-advanced world saves")
	var reopened := HeadlessWorld.new()
	_expect(reopened.open(directory, target).ok, "The long-advanced world reopens")
	_expect(reopened.farm.snapshot() == world.farm.snapshot(), "Long-advanced state reopens identically")


func _test_reopen_after_actions() -> void:
	var directory: String = test_root.path_join("reopen")
	var world := HeadlessWorld.new()
	_expect(world.open(directory, START).ok, "The reopen fixture starts")
	world.execute(FarmCommand.make_sow("reopen-sow", "field_01", "cell_01", "greens", START))
	world.execute(FarmCommand.make_water("reopen-water", "field_01", "cell_01", START + 60))
	world.advance_to(START + 9000)
	world.execute(FarmCommand.make("reopen-harvest", "field_01", "cell_01", START + 9000))
	_expect(world.save().ok, "The acted-on world saves")
	var saved_farm: Dictionary = world.farm.snapshot()
	var saved_decorations: Dictionary = world.decorations.snapshot()
	var reopened := HeadlessWorld.new()
	var loaded: Dictionary = reopened.open(directory, START + 9000)
	_expect(loaded.ok and loaded.kind == "loaded", "A separate session reopens the commit")
	_expect(reopened.farm.snapshot() == saved_farm, "Reopened farm keeps the committed harvest")
	_expect(reopened.decorations.snapshot() == saved_decorations, "Reopened decorations keep unlocks")
	_expect(reopened.farm.event_sequence() == 3, "The committed event sequence survives the restart")
	var replay: Dictionary = reopened.execute(FarmCommand.make("reopen-harvest", "field_01", "cell_01", START + 9000))
	_expect(replay.ok and replay.duplicate, "A restarted world replays the committed id from its ledger")
	_expect(reopened.farm.snapshot() == saved_farm, "The replayed id changes neither state nor ledger")


func _test_failure_preserves_save() -> void:
	var directory: String = test_root.path_join("failure")
	var world := HeadlessWorld.new()
	_expect(world.open(directory, START).ok, "The failure fixture starts")
	_expect(world.execute(FarmCommand.make_sow("keep-sow", "field_01", "cell_01", "greens", START)).ok,
		"The failure fixture saves a baseline")
	var main_path: String = directory.path_join(FarmStore.MAIN)
	var baseline: Dictionary = world.farm.snapshot()
	var bytes: String = FileAccess.get_file_as_string(main_path)

	var immature: Dictionary = world.execute(FarmCommand.make("early-harvest", "field_01", "cell_01", START + 10))
	_expect(not immature.ok and immature.reason == "not_mature", "An immature harvest is refused")
	_expect(world.farm.snapshot() == baseline, "A refused command leaves authoritative state unchanged")
	_expect(FileAccess.get_file_as_string(main_path) == bytes, "A refused command leaves the save bytes unchanged")
	var invalid: Dictionary = world.execute({})
	_expect(not invalid.ok and invalid.reason == "invalid_command", "An invalid command is refused")
	_expect(FileAccess.get_file_as_string(main_path) == bytes, "An invalid command leaves the save bytes unchanged")

	# Two writers loaded the same baseline. The first commit invalidates the
	# second one's expected file; the second candidate must be dropped.
	var writer_a := HeadlessWorld.new()
	var writer_b := HeadlessWorld.new()
	_expect(writer_a.open(directory, START).ok, "Writer A opens the baseline")
	_expect(writer_b.open(directory, START).ok, "Writer B opens the baseline")
	_expect(writer_a.execute(FarmCommand.make_water("writer-a", "field_01", "cell_01", START + 20)).ok,
		"Writer A commits first")
	var writer_a_snapshot: Dictionary = writer_a.farm.snapshot()
	var writer_b_before: Dictionary = writer_b.farm.snapshot()
	var blocked: Dictionary = writer_b.execute(FarmCommand.make_water("writer-b", "field_01", "cell_01", START + 30))
	_expect(not blocked.ok and blocked.reason == "save_changed_on_disk",
		"A stale writer is rejected by the storage boundary")
	_expect(writer_b.farm.snapshot() == writer_b_before, "A failed save drops the stale candidate")
	var final := HeadlessWorld.new()
	var reloaded: Dictionary = final.open(directory, START + 30)
	_expect(reloaded.ok and final.farm.snapshot() == writer_a_snapshot,
		"The last committed writer remains authoritative")


func _test_corrupt_load_preserves_file() -> void:
	var directory: String = test_root.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(directory)
	var main_path: String = directory.path_join(FarmStore.MAIN)
	var file := FileAccess.open(main_path, FileAccess.WRITE)
	file.store_string("{not json")
	file.close()
	var world := HeadlessWorld.new()
	var opened: Dictionary = world.open(directory, START)
	_expect(not opened.ok and opened.reason == "load_corrupt", "A corrupt save refuses to start")
	_expect(FileAccess.get_file_as_string(main_path) == "{not json",
		"A refused load leaves the corrupt file for explicit recovery")


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS " + message)
	else:
		failures.append(message)
		print("FAIL " + message)
