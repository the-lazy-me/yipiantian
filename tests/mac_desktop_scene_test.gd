extends SceneTree
## macOS desktop embed: the real window is layered between the desktop and its
## icons, stays unobstructed for the observer, and returns to a normal window.
## Skips on other platforms or when the native library has not been built.

const Store = preload("res://farm/farm_store.gd")
const SettingsStore = preload("res://settings/settings_store.gd")
const NativeClass: String = "MacDesktop"

var scene: Node3D
var folder: String
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if OS.get_name() != "macOS" or not ClassDB.class_exists(NativeClass):
		print("MAC_DESKTOP_SCENE_TEST skipped platform=%s class=%s" % [
			OS.get_name(), str(ClassDB.class_exists(NativeClass))])
		quit(0)
		return
	folder = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join(
		".local/verification/mac-desktop-%d" % Time.get_ticks_usec())
	root.size = Vector2i(1280, 720)
	await _open_scene()
	var window: Window = root
	var before: Dictionary = {
		"size": window.size, "position": window.position, "borderless": window.borderless, "mode": window.mode,
	}
	var screen: int = window.current_screen
	var scale: float = maxf(DisplayServer.screen_get_scale(screen), 1.0)
	var screen_size: Vector2i = DisplayServer.screen_get_size(screen)
	var expected_size := Vector2i(roundi(screen_size.x / scale), roundi(screen_size.y / scale))
	var native: Object = ClassDB.instantiate(NativeClass)
	var handle: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	var desktop_level: int = int(native.probe().get("desktop_level", 0))
	var icon_level: int = int(native.probe().get("icon_level", 0))

	scene._enter_wallpaper()
	await _until(func() -> bool: return scene.desktop_wallpaper.active, 6000)
	_expect(scene.desktop_wallpaper.active and not scene.desktop_wallpaper.busy, "Wallpaper entry completes")
	_expect(window.borderless, "Embedded window drops its title bar")
	_expect(window.size == expected_size, "Embedded window covers the screen: %s vs %s" % [str(window.size), str(expected_size)])
	await create_timer(0.3).timeout
	_expect(not scene.game_menu.visible and not scene.hud.visible, "Menu and HUD leave the wallpaper unobstructed")
	_expect(root.gui_disable_input, "Observer mode rejects game input")
	var layer: int = int(native.layer(handle))
	_expect(layer == desktop_level + 1, "Window sits one level above the desktop (layer=%d)" % layer)
	_expect(layer > desktop_level and layer < icon_level, "Window stays below desktop icons")

	scene.desktop_wallpaper.restore()
	await _until(func() -> bool: return not scene.desktop_wallpaper.active and not scene.desktop_wallpaper.busy, 6000)
	_expect(not scene.desktop_wallpaper.active and not scene.desktop_wallpaper.busy, "Wallpaper exit completes")
	for _attempt: int in 12:
		if int(native.layer(handle)) == 0: break
		await process_frame
	_expect(int(native.layer(handle)) == 0, "Window level returns to normal")
	_expect(window.size == before.size and window.position == before.position and window.borderless == bool(before.borderless),
		"Window geometry is restored: %s/%s" % [str(window.size), str(window.position)])
	_expect(not root.gui_disable_input and scene.hud.visible, "Product UI returns after restore")

	await _close_scene()
	print("MAC_DESKTOP_SCENE_TEST checks=%d failures=%d" % [checks, failures.size()])
	for failure: String in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)


func _open_scene() -> void:
	scene = load("res://scenes/main.tscn").instantiate()
	scene.store = Store.new(folder.path_join("farm"))
	scene.settings_store = SettingsStore.new(folder.path_join("preferences"))
	scene.clock = func() -> float: return 1800000000.0
	root.add_child(scene)
	await create_timer(0.5).timeout


func _close_scene() -> void:
	scene.farm_audio.shutdown()
	await create_timer(0.1).timeout
	scene.queue_free()
	await process_frame
	await process_frame


func _until(condition: Callable, timeout_ms: int) -> void:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await process_frame


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)
