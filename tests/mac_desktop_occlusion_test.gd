extends SceneTree
## macOS wallpaper occlusion: a covered window pauses presentation through the
## same visibility_changed path as lock/sleep, a single jittering sample never
## flips it, an invisible (minimized) window is not treated as covered, and a
## lock/sleep suspension owns the state while it lasts.
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
		print("MAC_DESKTOP_OCCLUSION_TEST skipped platform=%s class=%s" % [
			OS.get_name(), str(ClassDB.class_exists(NativeClass))])
		quit(0)
		return
	folder = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join(
		".local/verification/mac-desktop-occlusion-%d" % Time.get_ticks_usec())
	root.size = Vector2i(1280, 720)
	await _open_scene()
	var window: Window = root
	var before: Dictionary = {
		"size": window.size, "position": window.position, "borderless": window.borderless, "mode": window.mode,
	}
	var handle: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	var wallpaper: Node = scene.desktop_wallpaper
	wallpaper.suspended_changed.connect(func(paused: bool) -> void: _paused_signals.append(paused))

	scene._enter_wallpaper()
	await _until(func() -> bool: return wallpaper.active, 6000)
	_expect(wallpaper.active, "Wallpaper entry completes")
	# The real poller would sample the live desktop; every sample here is
	# injected so the window's actual overlap with other apps stays irrelevant.
	wallpaper.set_process(false)
	_expect(not wallpaper.is_suspended(), "Wallpaper starts presenting")
	_expect(await _max_draw_calls(0.4) > 0, "The running wallpaper presents frames")

	# One covered sample is a candidate, not a state change.
	_expect(not wallpaper._occlusion_settled(false), "A single covered sample does not flip")
	wallpaper._apply_suspension()
	_expect(not wallpaper.is_suspended(), "A single covered sample keeps presenting")
	_expect(RenderingServer.is_render_loop_enabled(), "A single covered sample keeps the render loop")
	# A visible sample in between cancels the streak; another covered sample is
	# still only one, so a drop-down menu that appears and leaves never pauses.
	wallpaper._occlusion_settled(true)
	_expect(not wallpaper._occlusion_settled(false), "Interrupted coverage restarts the streak")
	wallpaper._apply_suspension()
	_expect(not wallpaper.is_suspended(), "Jittering coverage keeps presenting")

	# The second consecutive covered sample flips and pauses presentation.
	_expect(wallpaper._occlusion_settled(false), "The second covered sample flips")
	wallpaper._apply_suspension(false)
	_expect(wallpaper.is_suspended(), "Coverage marks the wallpaper as paused")
	_expect(scene.window_activity.is_suspended(), "Coverage stops presentation through WindowActivity")
	_expect(paused, "Coverage pauses simulation")
	_expect(not RenderingServer.is_render_loop_enabled(), "Coverage stops the render loop")

	# A minimized or hidden window also reports no visible window. It is not
	# coverage, so the paused state is held and the debounce candidate dropped
	# instead of reading the absent window as either state.
	_expect(not wallpaper._occlusion_step(false, false), "An absent window never flips")
	_expect(wallpaper._occlusion_streak == 0, "An absent window drops the coverage candidate")
	wallpaper._apply_suspension()
	_expect(wallpaper.is_suspended(), "An absent window keeps the paused state")

	# Two visible samples after the window returns resume presentation.
	_expect(not wallpaper._occlusion_settled(true), "The first visible sample does not flip")
	_expect(wallpaper._occlusion_settled(true), "The second visible sample flips back")
	wallpaper._apply_suspension(false)
	_expect(not wallpaper.is_suspended(), "Resume marks the wallpaper as running")
	_expect(not scene.window_activity.is_suspended(), "Resume restarts presentation")
	_expect(RenderingServer.is_render_loop_enabled(), "Resume restarts the render loop")
	_expect(not paused, "Resume unpauses simulation")
	_expect(await _max_draw_calls(0.5) > 0, "Resumed wallpaper draws again")

	# While lock/sleep owns the pause, coverage samples change nothing: the
	# screen reports no visible window and must not leave a stuck candidate.
	wallpaper._system_paused = true
	wallpaper._apply_suspension()
	_expect(wallpaper.is_suspended(), "Lock/sleep suspension pauses presentation")
	wallpaper._poll_macos_occlusion(handle)
	wallpaper._poll_macos_occlusion(handle)
	_expect(wallpaper.is_suspended(), "Coverage samples do not resume a locked session")
	_expect(not wallpaper._occlusion_paused, "Coverage samples do not claim a locked session")
	_expect(wallpaper._occlusion_streak == 0, "Coverage samples drop under lock/sleep")
	wallpaper._system_paused = false
	wallpaper._apply_suspension()
	_expect(not wallpaper.is_suspended(), "Unlocking resumes presentation")

	# Exiting from an occluded pause must not leave a frozen viewport or flags
	# for the next entry.
	wallpaper._occlusion_settled(false)
	wallpaper._occlusion_settled(false)
	wallpaper._apply_suspension(false)
	_expect(wallpaper.is_suspended(), "Coverage pauses again before exit")
	wallpaper.restore()
	await _until(func() -> bool: return not wallpaper.active and not wallpaper.busy, 6000)
	_expect(not wallpaper.active and not wallpaper.busy, "Exit from an occluded pause completes")
	_expect(not wallpaper.is_suspended(), "Exit clears suspension")
	_expect(not wallpaper._occlusion_paused and wallpaper._occlusion_streak == 0, "Exit clears coverage state")
	_expect(not scene.window_activity.is_suspended(), "Exit leaves presentation running")
	_expect(RenderingServer.is_render_loop_enabled(), "Exit leaves the render loop enabled")
	_expect(window.mode == int(before.mode), "Exit restores the original window mode: %d" % window.mode)
	_expect(window.size == before.size and window.position == before.position,
		"Exit restores window geometry: %s/%s" % [str(window.size), str(window.position)])
	_expect(_paused_signals == [true, false, true, false, true, false],
		"Suspension transitions were signalled: %s" % str(_paused_signals))

	await _close_scene()
	print("MAC_DESKTOP_OCCLUSION_TEST checks=%d failures=%d" % [checks, failures.size()])
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
