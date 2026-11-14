extends SceneTree
## P0-R3: sow, advance UTC, harvest and reopen without loading the farm scene.

const Farm = preload("res://farm/farm_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const START: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []
var folder: String


func _initialize() -> void:
	folder = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join(
		".local/verification/headless-world-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(folder)
	_run()
	for failure: String in failures:
		push_error(failure)
	print("HEADLESS_WORLD_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run() -> void:
	var store := FarmStore.new(folder)
	var missing: Dictionary = store.load_state()
	_expect(missing.ok and missing.kind == "missing", "A new world loads without a scene")

	var farm := Farm.new(START)
	var decorations := Decorations.new()
	_expect(farm.sow("field_01", "cell_01", "greens", START).ok, "Sow in the rule owner")
	_expect(farm.water("field_01", "cell_01", START + 60).ok, "Water in the rule owner")
	var settled: Dictionary = farm.settle(START + 1800)
	_expect(settled.ok, "Advance logical time to maturity")
	_expect(farm.get_cell("field_01", "cell_01").stage == "mature", "Crop reaches maturity")
	var harvest: Dictionary = farm.harvest("field_01", "cell_01", START + 1800)
	_expect(harvest.ok and harvest.reward_crop_id == "greens", "Harvest returns one crop")
	_expect(farm.snapshot().inventory.greens == 1, "Harvest adds exactly one to inventory")
	_expect(farm.get_cell("field_01", "cell_01").stage == "empty", "Harvested cell becomes empty")

	var saved: Dictionary = store.save_state(farm, decorations)
	_expect(saved.ok, "Validated state commits through the storage boundary")

	var reopened := FarmStore.new(folder)
	var loaded: Dictionary = reopened.load_state()
	_expect(loaded.ok and loaded.kind == "loaded", "A separate store reopens the commit")
	if loaded.ok and loaded.kind == "loaded":
		_expect(loaded.farm == farm.snapshot(), "Reopened farm matches the authoritative snapshot")
		_expect(loaded.decorations == decorations.snapshot(), "Reopened decorations match")
	_expect(reopened.save_state(farm, decorations).ok, "Admitted store accepts a later commit")

	var text: String = FileAccess.get_file_as_string(folder.path_join(FarmStore.MAIN))
	_expect(text.contains("\"version\": %d" % FarmStore.VERSION), "Disk envelope records v27")


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS " + message)
	else:
		failures.append(message)
		print("FAIL " + message)
