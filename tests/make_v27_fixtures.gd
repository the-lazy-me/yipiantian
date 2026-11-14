extends SceneTree
## Generates the M0-01 v27 save fixtures through the real FarmStore serializer.
## Usage: "$GODOT" --headless --path Game --script "$PWD/tests/make_v27_fixtures.gd"
## Output: tests/fixtures/v27/*.json. All data is synthetic; no player paths.

const Farm = preload("res://farm/farm_state.gd")
const Store = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const START: float = 1800000000.0
const BOUNDARY_BASELINE: float = 1.7976931348623157e308

var repo_root: String
var fixture_root: String
var work_root: String


func _initialize() -> void:
	repo_root = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
	fixture_root = repo_root.path_join("tests/fixtures/v27")
	work_root = repo_root.path_join(".local/verification/v27-fixtures-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(fixture_root)
	DirAccess.make_dir_recursive_absolute(work_root)
	var normal: String = _normal()
	_write("normal.json", normal)
	_write("boundary.json", _boundary())
	_write("truncated.json", normal.substr(0, normal.length() / 2))
	_write("corrupt.json", "not-json\n")
	_write("empty.json", "")
	var parsed: Dictionary = JSON.parse_string(normal)
	parsed.version = 99
	_write("unknown-version.json", JSON.stringify(parsed, "\t"))
	print("V27_FIXTURES root=%s" % fixture_root)
	quit(0)


func _normal() -> String:
	var farm := Farm.new(START)
	# One complete growth round and one growing round.
	farm.sow("field_01", "cell_01", "greens", START)
	farm.water("field_01", "cell_01", START + 60.0)
	farm.settle(START + 1800.0)
	farm.harvest("field_01", "cell_01", START + 1800.0)
	farm.sow("field_02", "cell_02", "radish", START + 1800.0)
	farm.water("field_02", "cell_02", START + 1860.0)
	# A neighbour basket in flight.
	farm.share_basket("willow", 0, {"greens": 1})
	# Independent lifetime count and current inventory (valid v27 shapes).
	var data: Dictionary = farm.snapshot()
	data.inventory.greens = 2
	data.harvested.greens = 3
	farm.restore_snapshot(data)
	# Completed kitchen recipe and one fed animal.
	farm.kitchen_action("start", {"recipe": "leaf_stir", "crop": "greens"}, 0, START + 2000.0)
	farm.kitchen_action("collect", {"station": "stove"}, 1, START + 2020.0)
	farm.animal_action("LakeDuck1", "feed", "greens", 0)
	# A non-default layout value plus a placed decoration.
	var layout: Dictionary = farm.snapshot().layout
	layout.fence_style = "crossed"
	farm.apply_layout(layout, START + 2100.0)
	var decorations := Decorations.new()
	decorations.unlock(farm.snapshot().harvested)
	decorations.place("pot", "ground_01", 3)
	return _serialize(farm, decorations, "normal")


func _boundary() -> String:
	var plan := Farm.Plan.new()
	for i: int in plan.fields.size():
		plan.fields[i] = Farm.Plan.resized_field(plan.fields[i], 8, 8, Vector2(5.0, 3.81))
	var farm := Farm.new(10000.0, plan.snapshot())
	var data: Dictionary = farm.snapshot()
	for field_id: String in farm.field_ids():
		for cell_id: String in farm.cell_ids(field_id):
			data.fields[field_id].cells[cell_id] = {
				"crop_id": "radish",
				"growth_seconds": 4321.123456789,
				"last_settled_utc_seconds": BOUNDARY_BASELINE,
				"watered": true,
				"ground": "ready",
			}
	for crop_id: String in Farm.Crops.crop_ids():
		data.harvested[crop_id] = Farm.MAX_HARVEST_COUNT
		data.inventory[crop_id] = Farm.MAX_HARVEST_COUNT
	var decorations := Decorations.new()
	return _serialize(farm, decorations, "boundary", data)


func _serialize(farm: RefCounted, decorations: RefCounted, name: String, farm_data: Dictionary = {}) -> String:
	var folder: String = work_root.path_join(name)
	DirAccess.make_dir_recursive_absolute(folder)
	var store := Store.new(folder)
	assert(store.load_state().kind == "missing")
	var farm_snapshot: Dictionary = farm.snapshot() if farm_data.is_empty() else farm_data
	var saved: Dictionary = store.save(farm_snapshot, decorations.snapshot())
	assert(saved.ok, "Fixture serializer rejected " + name + ": " + str(saved))
	return FileAccess.get_file_as_string(folder.path_join(Store.MAIN))


func _write(filename: String, text: String) -> void:
	var path: String = fixture_root.path_join(filename)
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null, "Cannot write fixture " + path)
	file.store_string(text)
	file.close()
	print("V27_FIXTURE %s bytes=%d" % [filename, text.to_utf8_buffer().size()])
