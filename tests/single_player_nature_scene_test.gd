extends SceneTree
## Single-player nature wiring: the local scene reads the same nature.json as
## the world authority, writes the seed before the first farm commit, refuses a
## corrupt or newer document without touching it, and explains the selected
## cell's moisture and growth rate in the existing HUD.
##
## The real main.tscn is loaded so this fixture needs the shipped art; a clean
## checkout without LFS art cannot compile the scene and must skip it.
## Fixtures stay below .local/verification.

const Farm = preload("res://farm/farm_state.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const Nature = preload("res://farm/nature_state.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const Store = preload("res://farm/farm_store.gd")
const SettingsStore = preload("res://settings/settings_store.gd")
const DisasterMood = preload("res://presentation/disaster_mood.gd")

const BLOCK: float = Nature.WEATHER_SECONDS
const CLEAR_SEARCH_FROM: int = 83333
const CLEAR_SEARCH_BLOCKS: int = 400

var checks: int = 0
var failures: Array[String] = []
var base: String
var folder: String
var scene: Node3D


func _initialize() -> void:
	base = get_script().resource_path.get_base_dir().get_base_dir().path_join(
		".local/verification/single-player-nature-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(base)
	_run.call_deferred()


func _run() -> void:
	await _test_clear_soil_and_hud()
	await _test_corrupt_document_refused()
	await _test_unsupported_document_refused()
	await _test_seed_write_failure_blocks_actions()
	for failure: String in failures:
		push_error(failure)
	print("SINGLE_PLAYER_NATURE_TEST checks=%d failures=%d root=%s" % [
		checks, failures.size(), base])
	quit(0 if failures.is_empty() else 1)


func _test_clear_soil_and_hud() -> void:
	folder = base.path_join("clear")
	DirAccess.make_dir_recursive_absolute(folder)
	var start: int = _clear_start()
	_expect(start >= 0, "The default seed supplies four clear blocks for the fixture")
	if start < 0:
		return
	var earlier: float = float(start) * BLOCK
	var now: float = float(start + 3) * BLOCK + 60.0
	# The fixture predates nature.json. Loading it must keep the fixed default
	# seed and write it before the farm document is committed again.
	_expect(_seed_farm(earlier), "The fixture farm commits without a nature document")
	var nature_path: String = folder.path_join(NatureStore.MAIN)
	_expect(not FileAccess.file_exists(nature_path),
		"The fixture starts without a nature document")
	await _open_scene(now)
	_expect(scene._loaded, "The local scene loads a farm that has no nature document")
	_expect(FileAccess.file_exists(nature_path), "The first save writes nature.json")
	var stored: Dictionary = NatureStore.new(folder).load_state()
	_expect(stored.ok and stored.kind == "loaded", "The written nature document loads")
	_expect(int(stored.state.get("seed", -1)) == Nature.DEFAULT_SEED,
		"A missing document keeps the fixed default seed instead of rolling a new one")
	_expect(scene.nature_state != null and scene.farm_state != null,
		"The scene holds the seed source and farm it loaded")

	var dry: Dictionary = scene.farm_state.get_cell("field_03", "cell_06")
	_expect(dry.moisture < Farm.MOISTURE_GROWTH_THRESHOLD,
		"Three completed clear blocks dry the soil")
	_expect(dry.moisture_label == "dry", "The dry cell is labelled for the player")
	_expect(dry.growth_rate == Farm.GROWTH_FACTOR_DRY,
		"The dry cell reports the half growth rate")
	var field_index: int = scene.farm_state.field_ids().find("field_03")
	_expect(field_index >= 0 and scene.farm.field_id(field_index) == "field_03",
		"The visible field order matches the state field order")
	scene.selected_field = field_index
	scene._select_cell("cell_06")
	var info: Label = scene.hud.get_node("Layout/EnvironmentInfo")
	_expect(info.visible and info.text == "土壤：干燥 · 生长 50%",
		"The HUD explains the dry selected cell")

	# The disaster line is the third read-only row and follows the same view the
	# rest of the scene uses. It has no panel and hides for empty copy or before
	# the farm loads; the actual fixture time decides whether it is shown.
	var weather_info: Label = scene.hud.get_node("Layout/WeatherInfo")
	var disaster_info: Label = scene.hud.get_node("Layout/DisasterInfo")
	_expect(disaster_info != null and disaster_info.offset_top == 124.0,
		"The disaster line sits at top 124 below the weather line")
	_expect(disaster_info.offset_top >= weather_info.offset_top + 24.0,
		"The disaster line does not overlap the weather line")
	_expect(disaster_info.mouse_filter == Control.MOUSE_FILTER_IGNORE, "The disaster line does not take input")
	scene.hud.show_disaster("", true)
	_expect(not disaster_info.visible, "An empty disaster line stays hidden")
	scene.hud.show_disaster("灾害：干旱（持续至 01-15 12:00 UTC）", false)
	_expect(not disaster_info.visible, "The disaster line stays hidden before loading")
	scene.hud.show_disaster("灾害：干旱（持续至 01-15 12:00 UTC）", true)
	_expect(disaster_info.visible and disaster_info.text.begins_with("灾害："),
		"The disaster line shows a real event once loaded")
	scene._sync_weather()
	var hazards: Dictionary = scene._disaster_view()
	var expected: String = str(DisasterMood.describe(
		hazards.get("disaster", {}), hazards.get("warning", {}), scene.clock.call()).get("text", ""))
	_expect(disaster_info.visible == (not expected.is_empty()),
		"The disaster line visibility follows the current nature view")
	if not expected.is_empty():
		_expect(disaster_info.text == expected, "The disaster line shows the current text")

	# Local irrigation saturates only the selected cell and immediately restores
	# the normal rate; the same HUD line must follow the authoritative view.
	_expect(scene.farm_state.sow("field_01", "cell_01", "carrot", now).ok,
		"A carrot is sown for the wet soil check")
	scene.selected_field = scene.farm_state.field_ids().find("field_01")
	scene._select_cell("cell_01")
	_expect(scene.farm_state.water("field_01", "cell_01", now).ok,
		"Watering the selected cell succeeds")
	scene._refresh_hud()
	var wet: Dictionary = scene.farm_state.get_cell("field_01", "cell_01")
	_expect(wet.moisture_label == "wet" and wet.growth_rate == Farm.GROWTH_FACTOR_NORMAL,
		"Wet soil restores the normal growth rate")
	_expect(info.visible and info.text == "土壤：潮湿 · 生长 100%",
		"The HUD explains the wet selected cell")
	# Animal, basket and layout edits all hand a copied candidate to the same
	# write path. It must accept that candidate type and keep the seed in step.
	var candidate: RefCounted = scene.farm_state.copy()
	_expect(scene._save_state(candidate, scene.decoration_state).ok,
		"A copied candidate saves through the seed-first path")
	await _close_scene()


func _test_corrupt_document_refused() -> void:
	folder = base.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(folder)
	_expect(_seed_farm(1800000000.0), "The corrupt fixture has a valid farm document")
	var nature_path: String = folder.path_join(NatureStore.MAIN)
	var corrupt: String = "{\"version\": 1, \"state\": {"
	_write(nature_path, corrupt)
	await _open_scene(1800000000.0)
	_expect(not scene._loaded, "A corrupt nature document blocks the local scene")
	_expect(not scene.farm.visible, "No farm is shown from a refused nature document")
	_expect(_overlay_visible(), "The existing storage overlay reports the failure")
	_expect(scene.hud._storage_message.text.contains("天气记录无法读取"),
		"The failure names the weather record to the player")
	_expect(FileAccess.get_file_as_string(nature_path) == corrupt,
		"A refused nature document is preserved byte for byte")
	await _close_scene()


func _test_unsupported_document_refused() -> void:
	folder = base.path_join("unsupported")
	DirAccess.make_dir_recursive_absolute(folder)
	_expect(_seed_farm(1800000000.0), "The newer-document fixture has a valid farm document")
	var nature_path: String = folder.path_join(NatureStore.MAIN)
	var newer: String = JSON.stringify({
		"version": Nature.RULES_VERSION + 1,
		"state": {"seed": 7, "rules_version": Nature.RULES_VERSION},
	}, "\t")
	_write(nature_path, newer)
	await _open_scene(1800000000.0)
	_expect(not scene._loaded, "A newer nature document blocks the local scene")
	_expect(_overlay_visible(), "The newer document also uses the storage overlay")
	_expect(scene.hud._storage_message.text.contains("更新的版本"),
		"The newer weather record is explained to the player")
	_expect(FileAccess.get_file_as_string(nature_path) == newer,
		"A newer nature document is preserved instead of overwritten")
	await _close_scene()


func _test_seed_write_failure_blocks_actions() -> void:
	folder = base.path_join("seed-write-failure")
	DirAccess.make_dir_recursive_absolute(folder)
	_expect(_seed_farm(1800000000.0), "The write-failure fixture has a valid farm document")
	# Occupy the pending path so the seed write cannot even stage a file. The
	# farm must not be committed without the seed that explains its moisture.
	DirAccess.make_dir_recursive_absolute(folder.path_join(NatureStore.PENDING))
	await _open_scene(1800000000.0)
	_expect(scene._loaded, "The farm itself still loads")
	_expect(scene._save_failed, "A failed seed write marks the save as failed")
	_expect(_overlay_visible(), "The existing storage overlay reports the failed seed write")
	_expect(scene.hud._storage_message.text.contains("保存未完成"),
		"The player is told the latest progress is still only in this window")
	_expect(not FileAccess.file_exists(folder.path_join(NatureStore.MAIN)),
		"The failed seed write does not claim a committed nature document")
	await _close_scene()


## The default seed's first four consecutive clear blocks. The fixture farm is
## saved at the start of the first one and opened inside the fourth, so the
## three completed blocks are enough to cross the dry threshold.
func _clear_start() -> int:
	var nature := Nature.new()
	for index: int in range(CLEAR_SEARCH_FROM, CLEAR_SEARCH_FROM + CLEAR_SEARCH_BLOCKS):
		var all_clear: bool = true
		for offset: int in range(0, 4):
			var weather: Dictionary = nature.weather_at(float(index + offset) * BLOCK)
			if str(weather.get("kind", "")) != "clear":
				all_clear = false
				break
		if all_clear:
			return index
	return -1


## Writes a valid farm document into the fixture folder. FarmStore admits a
## write only after it has read the folder, which is exactly what the scene's
## own store does before saving.
func _seed_farm(at: float) -> bool:
	var store := Store.new(folder)
	var loaded: Dictionary = store.load_state()
	if loaded.ok and loaded.kind != "missing":
		return true
	return bool(store.save_state(Farm.new(at), Decorations.new()).ok)


func _open_scene(at: float) -> void:
	scene = load("res://scenes/main.tscn").instantiate()
	scene.store = Store.new(folder)
	scene.settings_store = SettingsStore.new(folder.path_join("preferences"))
	scene.clock = func() -> float: return at
	root.add_child(scene)
	await _wait(func() -> bool:
		return scene.startup_complete and (scene._loaded or _overlay_visible()), 20000)


func _close_scene() -> void:
	if scene == null:
		return
	if scene.farm_audio != null:
		scene.farm_audio.shutdown()
	scene.queue_free()
	await process_frame
	await process_frame
	scene = null


func _overlay_visible() -> bool:
	if scene == null or scene.hud == null:
		return false
	var overlay: Node = scene.get_node_or_null("HUD/Layout/StorageOverlay")
	return overlay != null and (overlay as Control).visible


func _wait(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null)
	file.store_string(text)
	file.close()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		print("FAIL " + message)
