extends SceneTree
## Small UI smoke for the world page: injected paths bypass native dialogs and
## the import summary/confirm/cancel wiring works without loading the 3D scene.

const GameMenu = preload("res://ui/game_menu.gd")
const SettingsStore = preload("res://settings/settings_store.gd")

var checks: int = 0
var failures: Array[String] = []
var menu: GameMenu
var root_dir: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = ProjectSettings.globalize_path("res://").path_join("../.local/verification/world-transfer-ui-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(root_dir)
	root.size = Vector2i(1280, 720)
	menu = GameMenu.new()
	root.add_child(menu)
	await process_frame
	menu.present(SettingsStore.DEFAULTS.duplicate(true))
	await process_frame
	_expect(menu._tabs.size() == 6 and menu._tabs[menu.WORLD_TAB].text == "世界", "Settings exposes a 世界 tab")
	menu._show_page(menu.WORLD_TAB)
	_expect(menu._pages[menu.WORLD_TAB].name == "World", "World tab selects the world page")
	root.size = Vector2i(960, 600)
	await process_frame
	await process_frame
	_expect(root.get_visible_rect().encloses(menu.get_node("Modal/Paper").get_global_rect()), "World page fits the minimum window")
	_expect(menu._pages[menu.WORLD_TAB].get_global_rect().encloses(menu._export_world.get_global_rect()) and menu._pages[menu.WORLD_TAB].get_global_rect().encloses(menu._import_world.get_global_rect()), "World actions stay inside their page")
	_expect(menu._export_world.visible and menu._export_world.text == "导出世界", "World page has an export entry")
	_expect(menu._import_world.visible and menu._import_world.text == "导入世界", "World page has an import entry")
	var export_paths: Array[String] = []
	var import_paths: Array[String] = []
	menu.world_export_requested.connect(func(path: String) -> void: export_paths.append(path))
	menu.world_import_requested.connect(func(path: String) -> void: import_paths.append(path))
	var export_dir: String = root_dir.path_join("export")
	var import_dir: String = root_dir.path_join("import")
	menu.export_path_override = export_dir
	menu.import_path_override = import_dir
	menu._export_world.pressed.emit()
	_expect(export_paths == [export_dir], "Export button uses the injected path instead of opening a dialog")
	menu._import_world.pressed.emit()
	_expect(import_paths == [import_dir], "Import button uses the injected path instead of opening a dialog")
	var summary: Dictionary = {
		"world_id": "0123456789abcdef0123456789abcdef",
		"exported_at_utc_seconds": 1800000000,
		"backup_path": root_dir.path_join("backup"),
	}
	menu.present_world_import(summary)
	await process_frame
	_expect(menu._world_import_confirmation.visible, "Import summary opens for confirmation")
	_expect(root.get_visible_rect().encloses(menu._world_import_confirmation.get_global_rect()), "Import summary fits the minimum window")
	_expect(not menu._paper.visible, "Import confirmation replaces the settings panel")
	_expect(menu._world_import_text.text.contains("原存档会保留在"), "Summary explains where the old world is kept")
	_expect(menu._world_import_text.text.contains(root_dir.path_join("backup")), "Summary names the backup directory")
	_expect(menu._world_import_text.text.contains("导入后会替换"), "Summary explains which progress is replaced")
	menu.world_import_failed("测试失败：原存档未改变。")
	_expect(menu._world_import_error.visible and menu._world_import_error.text.contains("未改变"), "Import failure is shown in the confirmation")
	var cancelled: Array[bool] = []
	menu.world_import_cancelled.connect(func() -> void: cancelled.append(true))
	_expect(menu.cancel_world_import_confirmation(), "Cancel closes the import confirmation")
	_expect(not menu._world_import_confirmation.visible and menu._paper.visible and cancelled.size() == 1, "Cancel restores the settings panel and reports cancellation")
	var confirmed: Array[bool] = []
	menu.world_import_confirmed.connect(func() -> void: confirmed.append(true))
	menu.present_world_import(summary)
	menu._world_import_confirmation.get_node("Column/Actions/Confirm").pressed.emit()
	_expect(confirmed.size() == 1, "Confirm emits the import request")
	menu.export_path_override = ""
	menu.import_path_override = ""
	menu.queue_free()
	await process_frame
	for failure: String in failures:
		push_error(failure)
	print("WORLD_TRANSFER_UI_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), root_dir])
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
