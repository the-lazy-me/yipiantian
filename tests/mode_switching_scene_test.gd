extends SceneTree
## M2-02: entering wallpaper mode ends input and tool state, saves once without
## committing a pending action, and restoring returns the same farm. Uses the
## real macOS desktop library; skips elsewhere.

const Store = preload("res://farm/farm_store.gd")
const Farm = preload("res://farm/farm_state.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const Settings = preload("res://settings/settings_store.gd")
const NativeClass: String = "MacDesktop"

var scene: Node3D
var folder: String
var now: float = 1800000000.0
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if OS.get_name() != "macOS" or not ClassDB.class_exists(NativeClass):
		print("MODE_SWITCHING_SCENE_TEST skipped platform=%s class=%s" % [
			OS.get_name(), str(ClassDB.class_exists(NativeClass))])
		quit(0)
		return
	folder = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().path_join(
		".local/verification/mode-switch-%d" % Time.get_ticks_usec())
	var store := Store.new(folder)
	_expect(store.load_state().ok, "Isolated fixture starts empty")
	var farm := Farm.new(now)
	var decorations := Decorations.new()
	_expect(store.save(farm.snapshot(), decorations.snapshot()).ok, "Fixture saves through the versioned owner")

	root.size = Vector2i(1600, 900)
	scene = load("res://scenes/main.tscn").instantiate()
	scene.name = "FarmExperience"
	scene.store = Store.new(folder)
	scene.settings_store = Settings.new(folder.path_join("settings"))
	scene.clock = func() -> float: return now
	root.add_child(scene)
	current_scene = scene
	var loaded: bool = false
	for _attempt: int in 100:
		await create_timer(0.1).timeout
		if scene._loaded: loaded = true; break
	_expect(loaded, "Main scene admits the fixture")
	if not loaded:
		await _finish()
		return
	if not scene.desktop_wallpaper.available():
		print("MODE_SWITCHING_SCENE_TEST skipped desktop unavailable")
		await _finish()
		return
	var tools_ready: bool = await _until(func() -> bool: return scene._tools_available(), 10000)
	_expect(tools_ready, "Main scene settles into an operable state")
	if not tools_ready:
		await _finish()
		return

	var before: Dictionary = scene.farm_state.snapshot()
	var changed: Array[Dictionary] = []
	scene.farm_changed.connect(func(result: Dictionary) -> void: changed.append(result))
	# Arm a real tool on a cell, plus the transient press state a live click
	# would carry, so the mode change has something pending to end.
	scene.selected_field = 2
	scene.selected_cell = "cell_06"
	scene._open_palette("tools")
	await create_timer(0.3).timeout
	scene._select_tool("water")
	scene._tool_press = {"field": 2, "cell": "cell_06", "tool": "water"}
	scene._dragging = true
	_expect(scene.selected_tool == "water", "Fixture arms a tool before switching")
	scene._enter_wallpaper()
	var entered: bool = await _until(func() -> bool: return scene.desktop_wallpaper.active, 10000)
	_expect(entered, "Wallpaper mode attaches to the desktop")
	_expect(not scene.hud.visible, "Wallpaper mode hides the HUD")
	_expect(scene.selected_tool.is_empty() and scene.selected_palette.is_empty(),
		"Entering wallpaper ends the armed tool and palette")
	_expect(scene._tool_press.is_empty() and not scene._dragging,
		"Entering wallpaper drops the pending press and drag")
	_expect(scene.get_viewport().gui_disable_input, "Wallpaper mode disables game input")
	_expect(scene.farm_state.snapshot() == before, "Entering wallpaper does not commit the pending action")
	_expect(changed.is_empty(), "Entering wallpaper emits no farm change")
	_expect(not scene.window_activity.is_foreground(),
		"Window activity owns the wallpaper presentation state")
	_expect(not scene.farm_audio.is_foreground(),
		"Wallpaper mode counts as unfocused for audio, so loops and actions stay silent")

	scene.desktop_wallpaper.restore()
	var restored: bool = await _until(
		func() -> bool: return not scene.desktop_wallpaper.active and not scene.desktop_wallpaper.busy, 10000)
	_expect(restored, "Restoring returns to an ordinary window")
	_expect(scene.hud.visible, "Restoring shows the HUD")
	_expect(not scene.get_viewport().gui_disable_input, "Restoring accepts input again")
	_expect(scene.farm_audio.is_foreground() == scene.window_activity.is_foreground(),
		"Restoring returns audio to whatever focus the window actually has")
	_expect(scene.farm_state.snapshot() == before, "Restoring leaves the authoritative farm unchanged")
	_expect(changed.is_empty(), "A full mode round trip commits no farm action")

	# A second round trip must not duplicate work or fork state.
	scene._enter_wallpaper()
	var entered_again: bool = await _until(func() -> bool: return scene.desktop_wallpaper.active, 10000)
	_expect(entered_again, "A second entry attaches again")
	scene.desktop_wallpaper.restore()
	var restored_again: bool = await _until(
		func() -> bool: return not scene.desktop_wallpaper.active and not scene.desktop_wallpaper.busy, 10000)
	_expect(restored_again, "A second restore settles")
	_expect(scene.farm_state.snapshot() == before, "Repeated switching still leaves one authoritative state")
	_expect(changed.is_empty(), "Repeated switching commits nothing")
	var disk: Dictionary = Store.new(folder).load_state()
	_expect(disk.ok and disk.farm == before, "The on-disk farm is the same single version, not a fork")

	# Back-to-back requests while a transition is in flight must be ignored
	# rather than queued into a second attach/restore.
	scene._enter_wallpaper()
	scene._enter_wallpaper()
	_expect(await _until(func() -> bool: return scene.desktop_wallpaper.active, 10000),
		"Rapid double entry attaches once")
	_expect(scene.desktop_wallpaper.active and not scene.desktop_wallpaper.busy,
		"The second entry request did not queue another transition")
	scene.desktop_wallpaper.restore()
	scene.desktop_wallpaper.restore()
	_expect(await _until(
		func() -> bool: return not scene.desktop_wallpaper.active and not scene.desktop_wallpaper.busy, 10000),
		"Rapid double restore lands back in an ordinary window")
	_expect(scene.farm_state.snapshot() == before and changed.is_empty(),
		"Rapid switching neither commits nor forks the world")

	# Time passes while the world is not presented; restoring settles it once.
	var grown_before: float = float(
		scene.farm_state.get_cell("field_04", "cell_06").get("growth_seconds", 0.0))
	scene._enter_wallpaper()
	_expect(await _until(func() -> bool: return scene.desktop_wallpaper.active, 10000),
		"A third entry attaches")
	now += 7200.0
	scene.desktop_wallpaper.restore()
	_expect(await _until(
		func() -> bool: return not scene.desktop_wallpaper.active and not scene.desktop_wallpaper.busy, 10000),
		"A third restore settles")
	_expect(float(scene.farm_state.get_cell("field_04", "cell_06").get("growth_seconds", 0.0)) > grown_before,
		"Restoring settles the time spent away from the presented world")
	_expect(changed.is_empty(), "Settling after a mode round trip emits no farm command result")
	await _finish()


func _until(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call(): return true
		await create_timer(0.05).timeout
	return condition.call()


func _finish() -> void:
	if is_instance_valid(scene):
		scene.farm_audio.shutdown()
		await create_timer(0.1).timeout
		root.remove_child(scene)
		scene.queue_free()
		await process_frame
		await process_frame
	for failure: String in failures:
		push_error(failure)
	print("MODE_SWITCHING_SCENE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
