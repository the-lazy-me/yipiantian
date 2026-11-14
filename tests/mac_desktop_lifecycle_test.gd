extends SceneTree
## macOS desktop embed: locking the session or sleeping the displays stops
## presentation, and both wake and exit restore the layered window.
## Skips on other platforms or when the native library has not been built.

const Store = preload("res://farm/farm_store.gd")
const SettingsStore = preload("res://settings/settings_store.gd")
const NativeClass: String = "MacDesktop"

var scene: Node3D
var folder: String
var checks: int = 0
var failures: Array[String] = []
var _paused_signals: Array[bool] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if OS.get_name() != "macOS" or not ClassDB.class_exists(NativeClass):
		print("MAC_DESKTOP_LIFECYCLE_TEST skipped platform=%s class=%s" % [
			OS.get_name(), str(ClassDB.class_exists(NativeClass))])
		quit(0)
		return
	folder = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join(
		".local/verification/mac-desktop-lifecycle-%d" % Time.get_ticks_usec())
	root.size = Vector2i(1280, 720)
	await _open_scene()
	var window: Window = root
	var before: Dictionary = {
		"size": window.size, "position": window.position, "borderless": window.borderless, "mode": window.mode,
	}
	var native: Object = ClassDB.instantiate(NativeClass)
	var handle: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	var desktop_level: int = int(native.probe().get("desktop_level", 0))
	var wallpaper: Node = scene.desktop_wallpaper
	wallpaper.suspended_changed.connect(func(paused: bool) -> void: _paused_signals.append(paused))

	scene._enter_wallpaper()
	await _until(func() -> bool: return wallpaper.active, 6000)
	_expect(wallpaper.active, "Wallpaper entry completes")
	_expect(int(native.system_state()) == 3, "Native system state reports an active session")
	# The poller would immediately resume against the real awake system; the
	# suspend/resume transitions are driven directly in this test.
	wallpaper.set_process(false)

	_expect(await _max_draw_calls(0.4) > 0, "The running wallpaper presents frames")

	wallpaper._set_suspended(true)
	_expect(wallpaper.is_suspended(), "Suspend marks the wallpaper as paused")
	_expect(scene.window_activity.is_suspended(), "Suspend stops presentation through WindowActivity")
	_expect(paused, "Suspend pauses simulation while UTC time keeps accruing")
	_expect(not RenderingServer.is_render_loop_enabled(), "Suspend stops the render loop")

	wallpaper._set_suspended(false)
	_expect(not wallpaper.is_suspended(), "Resume marks the wallpaper as running")
	_expect(not scene.window_activity.is_suspended(), "Resume restarts presentation")
	_expect(RenderingServer.is_render_loop_enabled(), "Resume restarts the render loop")
	_expect(not paused, "Resume unpauses simulation")
	_expect(await _max_draw_calls(0.5) > 0, "Resumed wallpaper draws again")
	await create_timer(0.3).timeout
	_expect(window.borderless, "Resume keeps the window borderless")
	_expect(int(native.layer(handle)) == desktop_level + 1,
		"Resume reasserts the desktop layer: %d" % int(native.layer(handle)))

	# Suspending and then exiting must not leave the viewport frozen.
	wallpaper._set_suspended(true)
	_expect(wallpaper.is_suspended(), "Second suspend is accepted")
	wallpaper.restore()
	await _until(func() -> bool: return not wallpaper.active and not wallpaper.busy, 6000)
	_expect(not wallpaper.active and not wallpaper.busy, "Exit from suspension completes")
	_expect(not wallpaper.is_suspended(), "Exit clears suspension")
	_expect(window.mode == int(before.mode), "Exit restores the original window mode: %d" % window.mode)
	_expect(not scene.window_activity.is_suspended(), "Exit leaves presentation running")
	for _attempt: int in 12:
		if int(native.layer(handle)) == 0: break
		await process_frame
	_expect(int(native.layer(handle)) == 0, "Exit returns the window level to normal")
	_expect(window.size == before.size and window.position == before.position,
		"Exit restores window geometry: %s/%s" % [str(window.size), str(window.position)])
	_expect(_paused_signals == [true, false, true, false], "Suspension transitions were signalled: %s" % str(_paused_signals))

	await _close_scene()
	print("MAC_DESKTOP_LIFECYCLE_TEST checks=%d failures=%d" % [checks, failures.size()])
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


## Highest draw-call count observed over a window; 0 means nothing was drawn.
func _max_draw_calls(seconds: float) -> int:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	var best: int = 0
	while Time.get_ticks_msec() < deadline:
		await process_frame
		best = maxi(best, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	return best


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)
