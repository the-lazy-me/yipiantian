extends SceneTree
## Mode switching must be idempotent: a second entry while one is in flight is
## ignored, and restoring during entry ends in a normal window with no stuck
## state. Uses the real macOS desktop library; skips elsewhere.

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
		print("MAC_DESKTOP_SWITCH_TEST skipped platform=%s class=%s" % [
			OS.get_name(), str(ClassDB.class_exists(NativeClass))])
		quit(0)
		return
	folder = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join(
		".local/verification/mac-switch-%d" % Time.get_ticks_usec())
	root.size = Vector2i(1280, 720)
	await _open_scene()
	var window: Window = root
	var before: Dictionary = {"size": window.size, "position": window.position, "borderless": window.borderless, "mode": window.mode}
	var native: Object = ClassDB.instantiate(NativeClass)
	var handle: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)

	# Two entries in the same frame: the second must not start a parallel attach.
	scene._enter_wallpaper()
	scene._enter_wallpaper()
	await _until(func() -> bool: return scene.desktop_wallpaper.active, 6000)
	_expect(scene.desktop_wallpaper.active, "First entry attaches once")
	_expect(int(native.layer(handle)) == int(native.probe().get("desktop_level", 0)) + 1, "Entry holds the desktop layer")

	# Restore, then re-enter: the watchdog state is rebuilt, not reused.
	scene.desktop_wallpaper.restore()
	await _until(func() -> bool: return not scene.desktop_wallpaper.active and not scene.desktop_wallpaper.busy, 6000)
	_expect(not scene.desktop_wallpaper.active and not scene.desktop_wallpaper.busy, "Restore completes")
	scene._enter_wallpaper()
	await _until(func() -> bool: return scene.desktop_wallpaper.active, 6000)
	_expect(scene.desktop_wallpaper.active, "Second entry attaches again")

	# Restore in the same frame as a new entry: the entry must abort cleanly.
	scene._enter_wallpaper()
	scene.desktop_wallpaper.restore()
	await _until(func() -> bool: return not scene.desktop_wallpaper.active and not scene.desktop_wallpaper.busy, 6000)
	_expect(not scene.desktop_wallpaper.active and not scene.desktop_wallpaper.busy, "Restore during entry settles")
	for _attempt: int in 12:
		if int(native.layer(handle)) == 0: break
		await process_frame
	_expect(int(native.layer(handle)) == 0, "Window level returns to normal after cancel")
	_expect(window.size == before.size and window.position == before.position and window.borderless == bool(before.borderless),
		"Window geometry is restored after cancel: %s/%s" % [str(window.size), str(window.position)])

	await _close_scene()
	print("MAC_DESKTOP_SWITCH_TEST checks=%d failures=%d" % [checks, failures.size()])
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
