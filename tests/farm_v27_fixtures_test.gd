extends SceneTree
## M0-01: load each isolated v27 fixture through the real FarmStore boundary
## and assert its documented outcome. No product code and no player data.

const Store = preload("res://farm/farm_store.gd")
const Farm = preload("res://farm/farm_state.gd")
const START: float = 1800000000.0
## The largest timestamp a document may carry is the exact-JSON integer bound,
## not the largest finite double: a baseline of 1e300 would freeze every cell
## because no real `now` ever reaches it.
const BOUNDARY_BASELINE: float = Farm.MAX_TIME_SECONDS

var checks: int = 0
var failures: Array[String] = []
var fixture_root: String
var work_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var repo_root: String = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
	fixture_root = repo_root.path_join("tests/fixtures/v27")
	work_root = repo_root.path_join(".local/verification/v27-fixture-test-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(work_root)
	_test_normal()
	_test_boundary()
	_test_truncated()
	_test_corrupt()
	_test_empty()
	_test_unknown_version()
	for failure: String in failures:
		push_error(failure)
	print("V27_FIXTURES_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), fixture_root])
	quit(0 if failures.is_empty() else 1)


func _test_normal() -> void:
	var loaded: Dictionary = _load("normal")
	_expect(loaded.ok and loaded.kind == "loaded", "normal: loads as a current save")
	_expect(loaded.get("migrated", true) == false, "normal: version 27 is not reported as migrated")
	_expect(loaded.farm.fields.field_02.cells.cell_02.crop_id == "radish", "normal: growing crop restored")
	_expect(is_equal_approx(loaded.farm.fields.field_02.cells.cell_02.growth_seconds, 1380.0), "normal: elapsed growth restored")
	_expect(loaded.farm.harvested.greens == 3 and loaded.farm.inventory.greens == 0, "normal: lifetime harvest and current inventory stay independent")
	_expect(loaded.farm.neighbors.willow.pending and loaded.farm.neighbors.willow.round == 0, "normal: in-flight neighbour basket restored")
	_expect(loaded.farm.animals.LakeDuck1.visits == 1 and loaded.farm.animals.LakeDuck1.shared == 1, "normal: animal interaction counters restored")
	_expect(loaded.farm.kitchen.records.leaf_stir.made == 1 and loaded.farm.kitchen.display == "leaf_stir", "normal: completed kitchen record and display restored")
	_expect(loaded.farm.memories.marks.arrange == START + 2100.0 and loaded.farm.memories.photos.is_empty(), "normal: observation timestamp restored")
	_expect(loaded.farm.layout.fence_style == "crossed", "normal: layout edit restored")
	_expect(loaded.decorations.pot.slot_id == "ground_01" and loaded.decorations.pot.quarter_turn == 3, "normal: confirmed decoration restored")
	_expect(Store.new(_isolate("normal")).load_state().farm == loaded.farm, "normal: reload is deterministic")


func _test_boundary() -> void:
	var loaded: Dictionary = _load("boundary")
	_expect(loaded.ok and loaded.kind == "loaded", "boundary: maximum-sized valid state loads")
	_expect(loaded.farm.harvested.greens == Farm.MAX_HARVEST_COUNT and loaded.farm.inventory.radish == Farm.MAX_HARVEST_COUNT, "boundary: exact-integer maximum counts restored")
	var cells: Dictionary = loaded.farm.fields.field_01.cells
	_expect(cells.size() == 64, "boundary: 8x8 field restores all cells")
	_expect(is_equal_approx(cells.cell_01.growth_seconds, 4321.123456789), "boundary: fractional growth seconds restored")
	_expect(cells.cell_01.last_settled_utc_seconds == BOUNDARY_BASELINE, "boundary: largest accepted timestamp restored")
	_expect(loaded.farm.layout.fields[0].columns == 8 and loaded.farm.layout.fields[0].rows == 8, "boundary: resized field layout restored")
	_expect(Store.new(_isolate("boundary")).load_state().farm == loaded.farm, "boundary: reload is deterministic")


func _test_truncated() -> void:
	var loaded: Dictionary = _load("truncated")
	_expect(not loaded.ok and loaded.kind == "corrupt", "truncated: rejected as corrupt")
	_expect(_unchanged("truncated"), "truncated: rejected bytes are preserved")


func _test_corrupt() -> void:
	var loaded: Dictionary = _load("corrupt")
	_expect(not loaded.ok and loaded.kind == "corrupt", "corrupt: non-JSON rejected as corrupt")
	_expect(_unchanged("corrupt"), "corrupt: rejected bytes are preserved")


func _test_empty() -> void:
	var loaded: Dictionary = _load("empty")
	_expect(not loaded.ok and loaded.kind == "corrupt", "empty: zero-byte file is corrupt, not first launch")


func _test_unknown_version() -> void:
	var loaded: Dictionary = _load("unknown-version")
	_expect(not loaded.ok and loaded.kind == "unsupported", "unknown-version: newer version is unsupported, distinct from corruption")
	_expect(_unchanged("unknown-version"), "unknown-version: rejected bytes are preserved")
	var store := Store.new(_isolate("unknown-version"))
	store.load_state()
	_expect(not store.save(Farm.new(START).snapshot(), _decorations()).ok, "unknown-version: rejected save locks gameplay writes")


func _load(name: String) -> Dictionary:
	return Store.new(_isolate(name)).load_state()


func _isolate(name: String) -> String:
	var folder: String = work_root.path_join(name)
	if not DirAccess.dir_exists_absolute(folder):
		DirAccess.make_dir_recursive_absolute(folder)
		var source: String = fixture_root.path_join(name + ".json")
		var target: String = folder.path_join(Store.MAIN)
		var file := FileAccess.open(target, FileAccess.WRITE)
		assert(file != null, "Cannot stage fixture " + name)
		file.store_buffer(FileAccess.get_file_as_bytes(source))
		file.close()
	return folder


func _unchanged(name: String) -> bool:
	return FileAccess.get_file_as_bytes(_isolate(name).path_join(Store.MAIN)) == FileAccess.get_file_as_bytes(fixture_root.path_join(name + ".json"))


func _decorations() -> Dictionary:
	return load("res://farm/decoration_state.gd").new().snapshot()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
