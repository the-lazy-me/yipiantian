extends SceneTree
## Narrow frame-cap policy check. Does not grab focus or change another window.
## Run windowed with `-- --dev-preview`; the policy needs the real display server
## and the explicit preview flag.

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless" or not OS.get_cmdline_user_args().has("--dev-preview"):
		print("WINDOW_PREVIEW_ACTIVITY_TEST skipped display=%s dev_preview=%s" % [
			DisplayServer.get_name(), str(OS.get_cmdline_user_args().has("--dev-preview"))])
		quit(0)
		return
	var activity: Node = load("res://atmosphere/window_activity.gd").new()
	root.add_child(activity)
	activity._active = true
	activity._apply_frame_limit()
	_check(Engine.max_fps == 60, "Normal foreground defaults to 60 FPS")
	activity.set_wallpaper(true)
	activity.set_wallpaper_interacting(true)
	_check(Engine.max_fps == 60, "Interactive desktop remains capped at 60 FPS")
	activity.set_wallpaper_interacting(false)
	_check(Engine.max_fps == 30, "Visible desktop observation remains at 30 FPS")
	activity.set_wallpaper_visible(false)
	_check(Engine.max_fps == 20, "Covered desktop keeps pumping its host while drawing is suspended")
	activity.set_wallpaper(false)
	activity.set_foreground_frame_limit(60)
	activity._active = false
	activity._apply_frame_limit()
	_check(Engine.max_fps == 60, "Visible second-screen preview must not fall to 15 FPS")
	root.mode = Window.MODE_MINIMIZED
	# The window server may apply miniaturization on a later frame.
	for _frame: int in 120:
		if root.mode == Window.MODE_MINIMIZED: break
		await process_frame
	_check(root.mode == Window.MODE_MINIMIZED, "The test window minimizes")
	activity._apply_frame_limit()
	_check(Engine.max_fps == 20, "Minimized preview keeps pumping its host while drawing is suspended")
	root.mode = Window.MODE_WINDOWED
	# macOS deminiaturizes asynchronously; the frame policy reads the real mode.
	for _frame: int in 120:
		if root.mode != Window.MODE_MINIMIZED: break
		await process_frame
	_check(root.mode != Window.MODE_MINIMIZED, "The test window leaves the minimized state")
	activity.set_foreground_frame_limit(30)
	activity._active = false
	activity._apply_frame_limit()
	_check(Engine.max_fps == 30, "Preview respects a lower selected frame cap")
	activity._active = true
	activity._apply_frame_limit()
	_check(Engine.max_fps == 30, "Foreground limit is restored")
	activity.free()
	for failure: String in failures:
		push_error(failure)
	print("WINDOW_PREVIEW_ACTIVITY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS " + message)
	else:
		failures.append(message)
		print("FAIL " + message)
