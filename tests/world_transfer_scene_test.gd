extends SceneTree
## End-to-end macOS/headless transfer flow through the real game scene and menu.

const Farm = preload("res://farm/farm_state.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const SettingsStore = preload("res://settings/settings_store.gd")
const Transfer = preload("res://farm/world_transfer.gd")
const START: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []
var root_dir: String
var scene: Node3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = ProjectSettings.globalize_path("res://").path_join("../.local/verification/world-transfer-scene-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(root_dir)
	root.size = Vector2i(1280, 720)
	var source_save: String = root_dir.path_join("source-save")
	var incoming_save: String = root_dir.path_join("incoming-save")
	var source: Dictionary = _make_save(source_save, 0)
	var incoming: Dictionary = _make_save(incoming_save, 1)
	_expect(source.ok and incoming.ok, "Scene fixtures are committed")
	if not source.ok or not incoming.ok:
		_report()
		return
	var incoming_package: String = root_dir.path_join("incoming-package")
	var exported: Dictionary = Transfer.export_world(incoming_save, incoming_package)
	_expect(exported.ok, "Incoming package is exported")
	await _open_scene(source_save)
	if scene == null or not scene._loaded:
		_report()
		return
	scene._open_menu()
	await process_frame
	_expect(scene.game_menu.visible, "World menu opens on the real farm")
	var export_target: String = root_dir.path_join("exported-package")
	scene.game_menu.export_path_override = export_target
	scene.game_menu._export_world.pressed.emit()
	_expect(await _wait_until(func() -> bool: return not scene.game_menu._world_status.text.is_empty(), 5.0), "Export finishes from the menu")
	_expect(scene.game_menu._world_status.text.contains("已导出"), "Export result is reported in the menu")
	_expect(_package_exists(export_target), "Menu export writes a package directory")
	scene.game_menu.import_path_override = incoming_package
	scene.game_menu._import_world.pressed.emit()
	await process_frame
	_expect(scene.game_menu._world_import_confirmation.visible, "Import selection shows the summary before writing")
	_expect(scene.game_menu._world_import_text.text.contains("原存档会保留在"), "Summary explains the preserved old world")
	scene.game_menu._world_import_confirmation.get_node("Column/Actions/Confirm").pressed.emit()
	var replacement: Node3D = await _wait_replacement(scene)
	_expect(replacement != null, "Confirmed import reloads the farm")
	if replacement != null:
		_expect(replacement.farm_state.snapshot() == incoming.farm, "Reloaded farm is the imported world")
		_expect(replacement.farm_state.snapshot().inventory != source.farm.inventory, "Imported inventory replaced the previous world")
		var loaded: Dictionary = FarmStore.new(source_save).load_state()
		_expect(loaded.ok and loaded.farm == incoming.farm and loaded.decorations == incoming.decorations, "Disk holds the imported snapshot")
		var identity: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(source_save.path_join("identity.json")))
		_expect(identity.player_id == exported.package.player_id and identity.device_id == exported.package.device_id, "Reloaded save keeps the package identity")
		_expect(DirAccess.dir_exists_absolute(source_save.path_join("import-backups")), "Import keeps the previous world in a backup directory")
		replacement.farm_audio.shutdown()
		replacement.queue_free()
		await create_timer(0.15).timeout
	_report()


func _make_save(folder: String, variant: int) -> Dictionary:
	var store := FarmStore.new(folder)
	if store.load_state().kind != "missing":
		return {"ok": false}
	var farm := Farm.new(START)
	farm.mature_all_crops(START)
	if variant == 0:
		farm.harvest("field_03", "cell_06", START)
	else:
		farm.harvest("field_04", "cell_06", START)
		farm.harvest("field_05", "cell_06", START)
	farm.settle(START + 3600.0)
	var decorations := Decorations.new()
	decorations.unlock(farm.snapshot().harvested)
	decorations.place("pot", "ground_04", 3 if variant == 0 else 1)
	var saved: Dictionary = store.save(farm.snapshot(), decorations.snapshot())
	if saved.ok:
		saved = store.save(farm.snapshot(), decorations.snapshot())
	return {"ok": saved.ok, "farm": farm.snapshot(), "decorations": decorations.snapshot()}


func _open_scene(save_directory: String) -> void:
	scene = load("res://scenes/main.tscn").instantiate()
	scene.store = FarmStore.new(save_directory)
	scene.settings_store = SettingsStore.new(root_dir.path_join("preferences"))
	scene.clock = func() -> float: return START
	root.add_child(scene)
	await _wait_until(func() -> bool: return scene._loaded, 10.0)


func _wait_replacement(old: Node3D) -> Node3D:
	var deadline: int = Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		for child: Node in root.get_children():
			if child != old and child is Node3D and child.has_method("settle_farm") and child.get("_loaded") == true:
				return child
		await create_timer(0.1).timeout
	return null


func _wait_until(predicate: Callable, seconds: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await create_timer(0.05).timeout
	return predicate.call()


func _package_exists(directory: String) -> bool:
	var worlds: String = directory.path_join("worlds")
	if not DirAccess.dir_exists_absolute(worlds):
		return false
	return not DirAccess.get_directories_at(worlds).is_empty()


func _report() -> void:
	for failure: String in failures:
		push_error(failure)
	print("WORLD_TRANSFER_SCENE_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), root_dir])
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
