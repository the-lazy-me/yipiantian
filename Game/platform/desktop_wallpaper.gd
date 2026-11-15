extends Node
## Private inherited pipes bind this host to this game; no network listener. Mouse forwarding is limited to the uncovered desktop.
##
## macOS embeds the game window through the macos_desktop GDExtension instead of
## a separate host process; that path observes only and never forwards input.
signal changed(active: bool)
signal visibility_changed(uncovered: bool)
signal restoring
signal failed(message: String)
signal quit_requested
signal pointer_moved(position: Vector2, flags: int)
signal interaction_changed(enabled: bool)
signal suspended_changed(paused: bool)
signal workarea_changed(area: Vector4)
signal pointer_left
signal pointer_button(position: Vector2, button: int, pressed: bool, factor: float, flags: int)

const MacDesktopBridge = preload("res://platform/mac_desktop.gd")

## Two consecutive 500 ms occlusion samples (about one second) must agree
## before the state flips, so a menu-bar drop-down or a notification banner
## does not pause and resume the wallpaper on every appearance.
const OCCLUSION_SAMPLES: int = 2

var interacting: bool = false

var active: bool = false
var busy: bool = false
var _host: Dictionary = {}
var _pipe: FileAccess
var _pending: String = ""
var _window_state: Dictionary = {}
var _deadline: int = 0
var _stopping: bool = false
var _quit_after_restore: bool = false
var _finishing: bool = false
var _mac: MacDesktopBridge
var _desktop_layer: int = -2147483648
var _layer_check_at: int = 0
var _system_check_at: int = 0
var _occlusion_check_at: int = 0
var _suspended: bool = false
var _system_paused: bool = false
var _occlusion_paused: bool = false
var _occlusion_streak: int = 0

## Sleep/lock suspension is reported through visibility_changed, which
## WindowActivity already owns: it pauses the scene, stops the render loop,
## releases deep-idle resources and settles elapsed farm time on resume.

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_mac = MacDesktopBridge.new()
	set_process(false)

func executable_path() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join(".local/builds/windows/FarmDesktop.exe")
	return OS.get_executable_path().get_base_dir().path_join("FarmDesktop.exe")

func supported() -> bool:
	return OS.get_name() == "Windows" or _mac.is_ready()

## macOS embeds the window but ignores mouse events, so the desktop shows the
## farm without forwarding clicks. Only Windows offers in-place interaction.
func interaction_supported() -> bool:
	return not _mac.is_ready()

func available() -> bool:
	if not supported() or DisplayServer.get_name() == "headless": return false
	if _mac.is_ready(): return true
	return FileAccess.file_exists(executable_path())

func enter() -> void:
	if busy or active or not _host.is_empty(): return
	if _mac.is_ready():
		_enter_macos()
		return
	if not available():
		failed.emit("桌面组件未找到，请使用包含 FarmDesktop.exe 的完整游戏包。")
		return
	busy = true
	var window: Window = get_window()
	_window_state = {"mode": window.mode, "screen": window.current_screen, "position": window.position,
		"size": window.size, "borderless": window.borderless}
	window.mode = Window.MODE_WINDOWED
	window.borderless = true
	window.current_screen = int(_window_state.screen)
	# Give the engine a frame to leave exclusive fullscreen before native reparenting.
	await get_tree().process_frame
	_host = OS.execute_with_pipe(executable_path(), PackedStringArray([
		str(DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)), str(OS.get_process_id())]), false)
	if _host.is_empty():
		_reset_window()
		busy = false
		failed.emit("桌面模式未能启动，已返回农场。")
		return
	_pipe = _host.stdio
	_pending = ""
	_stopping = false
	_quit_after_restore = false
	_deadline = Time.get_ticks_msec() + 7000
	set_process(true)

func restore() -> void:
	if _mac.is_ready():
		_restore_macos()
		return
	if _host.is_empty() or _stopping: return
	restoring.emit()
	busy = true
	_deadline = Time.get_ticks_msec() + 5000
	_send("RESTORE")

func set_interacting(value: bool) -> void:
	# The macOS window ignores mouse events at the desktop layer; there is no
	# input to forward, so the interaction state never changes.
	if _mac.is_ready(): return
	if not active or busy: return
	busy = true
	_deadline = Time.get_ticks_msec() + 5000
	restoring.emit()
	_send("INTERACT" if value else "OBSERVE")

func _send(command: String) -> void:
	if _pipe == null: return
	_pipe.store_buffer((command + "\n").to_utf8_buffer())
	if _pipe.get_error() != OK:
		push_error("DESKTOP_HOST pipe write failed: " + command)

func _process(_delta: float) -> void:
	if _mac.is_ready():
		_process_macos()
		return
	if _host.is_empty() or _finishing: return
	if not OS.is_process_running(int(_host.pid)):
		var unexpected: bool = not _stopping
		await _finish()
		if unexpected: failed.emit("桌面组件已停止，已恢复游戏显示。")
		return
	# Windows pipe length is the number of immediately available bytes (PeekNamedPipe).
	var count: int = int(_pipe.get_length()) if _pipe != null else 0
	if count > 0:
		_pending += _pipe.get_buffer(mini(count, 4096)).get_string_from_utf8()
		if _pending.length() > 8192:
			failed.emit("桌面组件返回了无效状态，正在恢复游戏。")
			restore()
			_pending = ""
		while _pending.contains("\n"):
			var split: int = _pending.find("\n")
			var line: String = _pending.substr(0, split)
			_pending = _pending.substr(split + 1)
			_receive(line)
	if busy and Time.get_ticks_msec() > _deadline:
		# Closing our pipe makes the host restore its owned window and terminate.
		push_error("DESKTOP_HOST timed out; closing inherited pipe for native rollback")
		_pipe.close()
		_pipe = null
		_stopping = true
		busy = false
		failed.emit("桌面切换超时，正在取消；请稍后重试。")

func _receive(line: String) -> void:
	if line.begins_with("WORKAREA "):
		var values: PackedStringArray = line.split(" ", false)
		if values.size() != 5: return
		for i: int in range(1, 5):
			if not values[i].is_valid_float(): return
		var area := Vector4(float(values[1]), float(values[2]), float(values[3]), float(values[4]))
		if area.is_finite() and area.x >= 0 and area.y >= 0 and area.z <= 1 and area.w <= 1 and area.z > area.x and area.w > area.y:
			workarea_changed.emit(area)
		return
	if line == "LEAVE":
		pointer_left.emit()
		return
	if line.begins_with("POINTER ") or line.begins_with("BUTTON "):
		var parts: PackedStringArray = line.split(" ", false)
		var is_button: bool = parts[0] == "BUTTON"
		var offset: int = 3 if is_button else 1
		if active and not busy and parts.size() == (7 if is_button else 4) and parts[offset].is_valid_float() and parts[offset+1].is_valid_float():
			var point := Vector2(float(parts[offset]), float(parts[offset+1]))
			if point.is_finite() and point.x >= 0.0 and point.x < 1.0 and point.y >= 0.0 and point.y < 1.0:
				if not is_button:
					if parts[3].is_valid_int() and int(parts[3]) >= 0 and int(parts[3]) <= 15:
						pointer_moved.emit(point, int(parts[3]))
				elif parts[1] in ["1", "2", "3", "4", "5", "6", "7", "8", "9"] and parts[2] in ["0", "1"] and parts[5].is_valid_float() and parts[6].is_valid_int():
					var factor: float = float(parts[5])
					if is_finite(factor) and factor >= 0.0 and factor <= 100.0 and int(parts[6]) >= 0 and int(parts[6]) <= 15:
						pointer_button.emit(point, int(parts[1]), parts[2] == "1", factor, int(parts[6]))
		return
	print("DESKTOP_HOST " + line)
	match line:
		"RESTORING", "ATTACHING":
			busy = true
			_deadline = Time.get_ticks_msec() + 5000
			restoring.emit()
		"INTERACTIVE", "OBSERVING":
			interacting = line == "INTERACTIVE"
			busy = false
			interaction_changed.emit(interacting)
		"ATTACHED":
			interacting = false
			active = true
			busy = false
			changed.emit(true)
		"VISIBLE": visibility_changed.emit(true)
		"COVERED": visibility_changed.emit(false)
		"RESTORED":
			_stopping = true
			_send("STOP")
		"QUIT": _quit_after_restore = true
		_:
			if line.begins_with("ERROR "):
				failed.emit("桌面模式暂时不可用，正在恢复游戏。" + "（" + line.trim_prefix("ERROR ") + "）")

func _enter_macos() -> void:
	busy = true
	_stopping = false
	var window: Window = get_window()
	_window_state = {"mode": window.mode, "screen": window.current_screen, "position": window.position,
		"size": window.size, "borderless": window.borderless}
	# DisplayServer reports pixels; Window positioning uses logical points.
	_fit_wallpaper_window()
	# Godot reapplies the window style after a mode change; attach after it settles.
	await get_tree().process_frame
	await get_tree().process_frame
	if _stopping:
		_reset_window()
		return
	var handle: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	_desktop_layer = int(_mac.probe().get("desktop_level", -2147483648)) + 1
	if handle == 0 or not _mac.attach(handle):
		_reset_window()
		busy = false
		failed.emit("桌面模式未能启动，已返回农场。")
		return
	# Resizing can reset the level once more; hold it before declaring success.
	for _attempt: int in 6:
		await get_tree().process_frame
		if _stopping:
			_mac.detach(handle)
			_reset_window()
			return
		if _mac.layer(handle) != _desktop_layer: _mac.reassert(handle)
	# Drop commands left over from an earlier session before the menu appears.
	_mac.take_command()
	_mac.show_status_item()
	active = true
	interacting = false
	busy = false
	_suspended = false
	_system_paused = false
	_occlusion_paused = false
	_occlusion_streak = 0
	_layer_check_at = Time.get_ticks_msec() + 500
	_system_check_at = Time.get_ticks_msec() + 500
	_occlusion_check_at = Time.get_ticks_msec() + 500
	set_process(true)
	changed.emit(true)

func _fit_wallpaper_window() -> void:
	var window: Window = get_window()
	var screen: int = clampi(int(_window_state.get("screen", window.current_screen)), 0, DisplayServer.get_screen_count() - 1)
	window.mode = Window.MODE_WINDOWED
	window.borderless = true
	window.current_screen = screen
	var scale: float = maxf(DisplayServer.screen_get_scale(screen), 1.0)
	var screen_size: Vector2i = DisplayServer.screen_get_size(screen)
	var screen_pos: Vector2i = DisplayServer.screen_get_position(screen)
	window.size = Vector2i(roundi(screen_size.x / scale), roundi(screen_size.y / scale))
	window.position = Vector2i(roundi(screen_pos.x / scale), roundi(screen_pos.y / scale))


func _process_macos() -> void:
	if not active: return
	var handle: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	if handle == 0: return
	var now: int = Time.get_ticks_msec()
	if now >= _system_check_at:
		_system_check_at = now + 500
		_poll_macos_system()
	# Covers the occlusion case: while paused for another reason the sample
	# still has to run so the window can recover on its own. A lock/sleep pause
	# suppresses it, because an invisible screen reports no visible window.
	if not _system_paused and now >= _occlusion_check_at:
		_occlusion_check_at = now + 500
		_poll_macos_occlusion(handle)
	if not _suspended and now >= _layer_check_at:
		_layer_check_at = now + 500
		if _mac.layer(handle) != _desktop_layer: _mac.reassert(handle)
	var command: int = _mac.take_command()
	if command == 1:
		restore()
	elif command == 2:
		_quit_after_restore = true
		restore()

## Stops presentation while the user session is locked or the displays sleep.
## Scene processing pauses; elapsed UTC time is settled when it resumes.
func _poll_macos_system() -> void:
	var paused: bool = (_mac.system_state() & 3) != 3
	# A display that just woke can report its own window as invisible for a poll
	# or two; wait one interval before that is allowed to count as coverage.
	if _system_paused and not paused:
		_occlusion_streak = 0
		_occlusion_check_at = Time.get_ticks_msec() + 500
	_system_paused = paused
	_apply_suspension()


## Covered by another application: presentation pauses through the same
## visibility_changed path as lock/sleep. Only runs while the system itself is
## awake, so the two causes never compete for the signal.
##
## A hidden or minimized window also clears NSWindowOcclusionStateVisible, but
## that is not occlusion: the window is gone rather than covered. Such a sample
## holds the current state and drops the pending candidate, so minimizing the
## wallpaper never leaves it stuck paused once it returns.
func _poll_macos_occlusion(handle: int) -> void:
	# A restore can await for several frames; a sample taken mid-detach must not
	# pause presentation again after WindowActivity already started resuming.
	if _stopping or _system_paused:
		# An asleep or locked screen reports no visible window; do not let that
		# read as coverage or the resume would depend on a stale sample.
		_occlusion_streak = 0
		return
	var window: Window = get_window()
	if not _occlusion_step(_mac.occlusion_visible(handle),
			window.visible and window.mode != Window.MODE_MINIMIZED):
		return
	_apply_suspension(false)
	print("DESKTOP_OCCLUSION covered=%s" % str(_occlusion_paused))


## Feeds one sample into the debounce. `present` is false while the window is
## minimized or hidden: those also clear NSWindowOcclusionStateVisible, but the
## window is gone rather than covered. Holding the current state and dropping
## the candidate means a minimized wallpaper never resumes into a stuck pause.
func _occlusion_step(visible: bool, present: bool) -> bool:
	if not present:
		_occlusion_streak = 0
		return false
	return _occlusion_settled(visible)


## Debounce state machine over consecutive samples: a sample that disagrees
## with the current state starts (or extends) a candidate streak, and only
## OCCLUSION_SAMPLES agree before the state flips. Returns true exactly on the
## frame the state changes, which is the only frame worth logging.
func _occlusion_settled(visible: bool) -> bool:
	var covered: bool = not visible
	if covered == _occlusion_paused:
		_occlusion_streak = 0
		return false
	_occlusion_streak += 1
	if _occlusion_streak < OCCLUSION_SAMPLES:
		return false
	_occlusion_streak = 0
	_occlusion_paused = covered
	return true


## The only place presentation is paused or resumed. Both causes combine here;
## _set_suspended stays the sole emitter of visibility_changed.
func _apply_suspension(raise_window: bool = true) -> void:
	_set_suspended(_system_paused or _occlusion_paused, raise_window)


func _set_suspended(paused: bool, raise_window: bool = true) -> void:
	if paused == _suspended: return
	_suspended = paused
	if paused:
		visibility_changed.emit(false)
	else:
		visibility_changed.emit(true)
		# Presentation was frozen; reassert the frame and the desktop layer.
		_fit_wallpaper_window()
		# Coming back from lock/sleep is a deliberate return to the farm; coming
		# back from coverage happens because the user moved another app away, so
		# raising this window would steal the focus they just used.
		if raise_window: DisplayServer.window_move_to_foreground()
		_layer_check_at = 0
		_system_check_at = Time.get_ticks_msec() + 500
		_reassert_after_resume()
	suspended_changed.emit(paused)


func _reassert_after_resume() -> void:
	var handle: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	if handle == 0: return
	for _attempt: int in 3:
		await get_tree().process_frame
		if not active or _suspended: return
		_mac.reassert(handle)


func is_suspended() -> bool:
	return _suspended

func _restore_macos() -> void:
	if not active and not busy: return
	_stopping = true
	busy = true
	restoring.emit()
	if _suspended:
		# WindowActivity resumes presentation when set_wallpaper(false) follows.
		_suspended = false
		suspended_changed.emit(false)
	# A stale coverage reading must not survive into the next entry.
	_system_paused = false
	_occlusion_paused = false
	_occlusion_streak = 0
	active = false
	interacting = false
	var handle: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	if handle != 0:
		_mac.detach(handle)
		# The compositor can report the old layer for a frame or two.
		for _attempt: int in 3:
			await get_tree().process_frame
			if _mac.layer(handle) == 0: break
			_mac.detach(handle)
		if _mac.layer(handle) != 0:
			push_warning("MAC_DESKTOP window level did not return to normal")
	_mac.hide_status_item()
	_reset_window()
	busy = false
	set_process(false)
	changed.emit(false)
	if _quit_after_restore:
		_quit_after_restore = false
		quit_requested.emit()

func _reset_window() -> void:
	if _window_state.is_empty(): return
	var window: Window = get_window()
	# Native desktop resizing updates DisplayServer's fullscreen detection, while
	# Window.mode may still cache WINDOWED. Explicitly leave the native mode first.
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	window.mode = Window.MODE_WINDOWED
	window.borderless = bool(_window_state.borderless)
	window.current_screen = clampi(int(_window_state.screen), 0, DisplayServer.get_screen_count()-1)
	window.size = _window_state.size
	window.position = _window_state.position
	window.mode = int(_window_state.mode) as Window.Mode
	_window_state.clear()

func _finish() -> void:
	_finishing = true
	# Drain native window messages before applying the original Godot window mode.
	await get_tree().process_frame
	await get_tree().process_frame
	_reset_window()
	active = false
	interacting = false
	busy = false
	if _pipe != null: _pipe.close()
	_pipe = null
	_host.clear()
	set_process(false)
	changed.emit(false)
	_finishing = false
	if _quit_after_restore: quit_requested.emit()

func _exit_tree() -> void:
	# WindowActivity restores presentation on its own exit; only drop the flag.
	_suspended = false
	if _mac != null and _mac.is_ready():
		var handle: int = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
		if active and handle != 0: _mac.detach(handle)
		# Removes workspace observers and the menu-bar item even at shutdown.
		_mac.shutdown()
	if _pipe != null:
		_send("STOP")
		_pipe.close()
	_host.clear()
