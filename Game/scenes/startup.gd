extends CanvasLayer
## Lightweight entry: preferences, threaded resources, staged construction,
## first-run measurement/choice, then ownership passes to the farm scene.

const FarmTheme = preload("res://ui/farm_theme.gd")
const Settings = preload("res://settings/settings_store.gd")
const Presets = preload("res://settings/graphics_presets.gd")
const Benchmark = preload("res://settings/startup_benchmark.gd")
const WorldClient = preload("res://world/world_client.gd")
const WorldHosting = preload("res://world/world_hosting.gd")
const PlayerProfile = preload("res://social/player_profile.gd")
const RoomPanel = preload("res://ui/room_panel.gd")
const FARM: String = "res://scenes/main.tscn"
const ROOM_WORLD: String = "world"
var settings_store: Settings
var farm_store: RefCounted
var farm_scene: Node3D
var _loaded: Dictionary
var _first: bool = false
var _recording: bool = false
var _loading: bool = false
var _resource_worker: Thread
var _packed: PackedScene
var _status: Label
var _progress: ProgressBar
var _choices: VBoxContainer
const SLIDER_TIERS: Array[String] = ["low", "standard", "high"]
var _slider: HSlider
var _tier_labels: Array[Label] = []
var _continue: Button
var _unsaved_continue: Button
var _retry: Button
var _recommendation: Label
var _selected: String = "standard"
var _recommended: String = "standard"
var _measured: bool = false
var _starting: bool = false
## A pasted join code puts this launch into a shared world instead of a local
## save: the world is fetched before the farm scene is built, because its layout
## decides which island that scene must construct.
var _join_code: String = ""
var _player_id: String = ""
## Empty means anonymous. A room needs a name only when it also gets a player
## id: the authority rejects a claimed id without a usable display name.
var _player_name: String = ""
var profile: PlayerProfile
var _world_client: WorldClient
var _world_state: Dictionary = {}
## Captured from the client's signals. Lambdas must write member state: a local
## variable captured by a lambda is a copy, so waiting on it would always time out.
var _join_failure: String = ""
## The room panel holds the local build while it is open. Joining has to happen
## before the farm scene is assembled: the world decides the island layout, and
## a local farm would already be running (and saving) behind it.
var _room_panel: RoomPanel
var _room_button: Button
var _hosting: WorldHosting
var _room_open: bool = false
var _joining: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_window().min_size = Vector2i(960, 600)
	if OS.has_feature("editor") and OS.get_cmdline_user_args().has("--dev-preview"):
		get_window().mode = Window.MODE_EXCLUSIVE_FULLSCREEN
	_build_ui()
	_begin.call_deferred()


func _build_ui() -> void:
	var root := Control.new()
	root.name = "Loading"
	root.theme = FarmTheme.create()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var background := ColorRect.new()
	background.color = FarmTheme.PAPER
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(background)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = 560
	column.add_theme_constant_override("separation", 18)
	center.add_child(column)
	var title := Label.new()
	title.text = "我有一片田"
	title.add_theme_font_size_override("font_size", 38)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	_status = Label.new()
	_status.name = "Stage"
	_status.text = "正在读取设置…"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	_progress = ProgressBar.new()
	_progress.name = "Progress"
	_progress.custom_minimum_size.y = 8
	_progress.show_percentage = false
	_progress.add_theme_stylebox_override("background", FarmTheme.paper(FarmTheme.EDGE, 4))
	_progress.add_theme_stylebox_override("fill", FarmTheme.paper(FarmTheme.LEAF, 4))
	column.add_child(_progress)
	_choices = VBoxContainer.new()
	_choices.name = "QualityChoices"
	column.add_child(_choices)
	_recommendation = Label.new()
	_recommendation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_recommendation.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_choices.add_child(_recommendation)
	_slider = HSlider.new()
	_slider.name = "QualitySlider"
	_slider.min_value = 0
	_slider.max_value = 2
	_slider.step = 1
	_slider.tick_count = 3
	_slider.ticks_on_borders = true
	_slider.custom_minimum_size.y = 40
	_slider.mouse_force_pass_scroll_events = false
	_choices.add_child(_slider)
	var labels := HBoxContainer.new()
	_choices.add_child(labels)
	for index: int in 3:
		var label := Label.new()
		label.text = ["低", "中", "高"][index]
		label.horizontal_alignment = [HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_RIGHT][index]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		labels.add_child(label)
		_tier_labels.append(label)
	_slider.value_changed.connect(_select_slider)
	_continue = Button.new()
	_continue.text = "进入农场"
	_continue.custom_minimum_size.y = 52
	for state: String in ["normal", "hover", "pressed", "hover_pressed"]:
		var fill: Color = FarmTheme.INK.lightened(.1) if state == "hover" else FarmTheme.INK
		_continue.add_theme_stylebox_override(state, FarmTheme.framed_paper(fill, true))
	for state: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		_continue.add_theme_color_override(state, FarmTheme.PAPER)
	_choices.add_child(_continue)
	_continue.pressed.connect(_confirm)
	_unsaved_continue = Button.new()
	_unsaved_continue.text = "本次使用，不保存"
	_unsaved_continue.custom_minimum_size.y = 44
	_choices.add_child(_unsaved_continue)
	_unsaved_continue.hide()
	_unsaved_continue.pressed.connect(func() -> void:
		if _starting: return
		_starting = true
		_choices.hide()
		_progress.show()
		_apply_tier(_selected)
		while farm_scene._high_quality_pending: await get_tree().process_frame
		await _finish())
	_choices.hide()
	_retry = Button.new()
	_retry.text = "重试加载"
	_retry.custom_minimum_size.y = 44
	column.add_child(_retry)
	_retry.pressed.connect(_retry_start)
	_retry.hide()
	var notice := Label.new()
	notice.name = "DevelopmentNotice"
	notice.text = "当前为开发中试玩版，可能存在较多问题，\n内容与体验仍在完善。"
	notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	notice.add_theme_font_size_override("font_size", 17)
	column.add_child(notice)
	_room_button = Button.new()
	_room_button.name = "Neighbors"
	_room_button.text = "联机：加入朋友的农场，或开一间房"
	_room_button.custom_minimum_size.y = 40
	column.add_child(_room_button)
	_room_button.pressed.connect(_open_room)


func _begin() -> void:
	# The local profile is the default identity; command-line flags still win, so
	# tests and operators can override it for one launch.
	if profile == null:
		profile = PlayerProfile.new()
		var loaded_profile: Dictionary = profile.load_profile()
		if not bool(loaded_profile.get("ok", false)):
			# The session continues with a new identity; name the change in the log
			# so it cannot be mistaken for a normal first launch later.
			push_warning("STARTUP_PROFILE kind=%s reason=%s" % [
				str(loaded_profile.get("kind", "")), str(loaded_profile.get("reason", ""))])
	_player_id = profile.player_id
	_player_name = profile.display_name
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--record-session="): _recording = true
		elif argument.begins_with("--join-code="): _join_code = argument.trim_prefix("--join-code=")
		elif argument.begins_with("--player-id="): _player_id = argument.trim_prefix("--player-id=")
		elif argument.begins_with("--player-name="): _player_name = argument.trim_prefix("--player-name=")
	if not _recording:
		if settings_store == null: settings_store = Settings.new()
		_loaded = settings_store.load_settings()
		# A joined world needs no first-run measurement; that choice belongs to
		# the machine, and the world already knows how it looks.
		_first = _loaded.ok and _loaded.kind == "first" and _join_code.is_empty()
		if _first:
			var memory: Dictionary = OS.get_memory_info()
			var unified: bool = OS.get_name() == "macOS" and Engine.get_architecture_name() == "arm64"
			_recommended = Presets.recommend(RenderingServer.get_video_adapter_type(), int(memory.get("physical", 0)), OS.get_processor_count(), get_window().size.x * get_window().size.y, unified)
	await show_stage(3.0, "正在加载模型与贴图…")
	if not _join_code.is_empty():
		await show_stage(8.0, "正在进入世界…")
		if not await _connect_world():
			return
	_request_resources()


func _request_resources() -> void:
	if _loading or is_instance_valid(farm_scene): return
	_retry.hide()
	_status.text = "正在加载模型与贴图…"
	_progress.indeterminate = true
	_resource_worker = Thread.new()
	# In 4.7.2 load_threaded_request leaks LoadToken objects with this scene's
	# dependency graph. A single owned worker with synchronous resource loading
	# avoids that path; scene instantiation remains on the main thread.
	var error: Error = _resource_worker.start(func() -> Resource: return ResourceLoader.load(FARM, "PackedScene"))
	if error != OK:
		_resource_worker = null
		_fail("农场资源未能开始加载，请重试。", "request_%d" % error)
		return
	_loading = true


func _process(_delta: float) -> void:
	if not _loading or _resource_worker.is_alive(): return
	var resource: Resource = _resource_worker.wait_to_finish()
	_resource_worker = null
	_loading = false
	_progress.indeterminate = false
	if not resource is PackedScene:
		_fail("农场资源加载失败，请重试。", "resource_failed")
		return
	_packed = resource
	# A room decision is pending: building the local farm now would race it.
	if _room_open or _joining: return
	_assemble.call_deferred()


func _exit_tree() -> void:
	if _resource_worker != null and _resource_worker.is_started():
		_resource_worker.wait_to_finish()
	if _hosting != null:
		_hosting.stop()
		_hosting = null


## Connects with the pasted code and waits for the first authoritative state.
## Returns false after showing why, so the launch stops before building a farm.
func _connect_world(silent: bool = false) -> bool:
	_world_state = {}
	_join_failure = ""
	var client := WorldClient.new()
	client.name = "WorldClient"
	add_child(client)
	client.state_ready.connect(func(farm: RefCounted, decorations: RefCounted, now_utc: float) -> void:
		_world_state = {"farm": farm, "decorations": decorations, "now_utc": now_utc})
	client.refused.connect(func(reason: String) -> void: _join_failure = reason)
	client.lost.connect(func(reason: String) -> void: _join_failure = reason)
	if not client.start(_join_code, _player_id, _player_name, profile.player_secret if profile != null else PackedByteArray()):
		if not _join_failure.is_empty() and not silent:
			_fail(_join_message(_join_failure), "join_" + _join_failure)
		return false
	var deadline: int = Time.get_ticks_msec() + 20000
	while not _world_state.has("farm") and _join_failure.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.05).timeout
	if not _world_state.has("farm"):
		var reason: String = _join_failure if not _join_failure.is_empty() else "timeout"
		client.close()
		client.queue_free()
		if not silent:
			_fail(_join_message(reason), "join_" + reason)
		return false
	_world_client = client
	return true


func _retry_start() -> void:
	_retry.hide()
	if _world_client != null:
		_world_client.close()
		_world_client.queue_free()
		_world_client = null
	if _join_code.is_empty():
		_request_resources()
		return
	_status.text = "正在重新连接世界…"
	if await _connect_world():
		_request_resources()


# ------------------------------------------------------------------ rooms
#
# The loading screen is the only place a room can still be chosen: once the
# farm scene exists it is already a local world with its own save and clock.

func _open_room() -> void:
	if _room_panel == null:
		_room_panel = RoomPanel.new()
		_room_panel.name = "RoomPanel"
		add_child(_room_panel)
		_room_panel.join_requested.connect(_join_room)
		_room_panel.host_requested.connect(_host_room)
		_room_panel.rotate_requested.connect(_rotate_room_codes)
		_room_panel.local_requested.connect(_stay_local)
		_room_panel.closed.connect(_on_room_closed)
	_room_open = true
	_room_panel.set_player_name(_player_name)
	_room_panel.show_idle()


func _on_room_closed() -> void:
	if not _room_open: return
	_room_open = false
	_resume_loading()


func _stay_local() -> void:
	_room_panel.hide()
	_room_open = false
	_joining = false
	_stop_room()
	_resume_loading()


func _resume_loading() -> void:
	# A joined world also lands here: `_world_client` being set is precisely the
	# case that must assemble now, with the remote seed `_assemble()` fills in.
	if _joining or is_instance_valid(farm_scene): return
	if _packed != null:
		_assemble.call_deferred()


func _join_room(code: String) -> void:
	if is_instance_valid(farm_scene):
		_room_panel.show_idle()
		_room_panel.show_status("这一局已经在本机农场里了，重新启动游戏后才能加入房间。")
		return
	var who: String = _room_panel.player_name()
	# An id without a name is refused by the authority (the name is what
	# neighbours see), so the room asks for one before dialing. Anonymous entry
	# still works when no profile could be loaded.
	if profile != null and not profile.player_id.is_empty():
		if not PlayerProfile.valid_name(who):
			_room_panel.show_status("先写一个名字（最多 24 个字），邻居才知道怎么称呼你。")
			return
		_player_name = who
		_player_id = profile.player_id
		profile.save_profile(who)
	elif not who.is_empty():
		_player_name = who
	_attempt_join(code)


func _attempt_join(code: String) -> void:
	_joining = true
	_room_open = true
	_join_code = code
	_join_failure = ""
	_room_panel.show_joining()
	var joined: bool = await _connect_world(true)
	_joining = false
	if not joined:
		var reason: String = _join_failure if not _join_failure.is_empty() else "timeout"
		_room_panel.show_failure(_join_message(reason))
		return
	# A joined world decides its own island and needs no first-run measurement.
	_first = false
	_room_open = false
	_room_panel.hide()
	_resume_loading()


func _host_room() -> void:
	if is_instance_valid(farm_scene):
		_room_panel.show_status("这一局已经在本机农场里了，重新启动游戏后才能开房。")
		return
	_stop_room()
	_hosting = WorldHosting.new()
	var directory: String = ProjectSettings.globalize_path("user://").path_join(
		"rooms").path_join(ROOM_WORLD)
	var started: Dictionary = _hosting.start(directory, ROOM_WORLD, _free_port(),
		_player_id)
	if not bool(started.get("ok", false)):
		_hosting = null
		_room_panel.show_failure(_host_message(str(started.get("reason", ""))))
		return
	_room_open = true
	_room_panel.show_joining()
	_room_panel.show_status("正在开房，稍等…")
	var deadline: int = Time.get_ticks_msec() + 30000
	var answer: Dictionary = {"ok": false, "reason": "pending"}
	while Time.get_ticks_msec() < deadline:
		answer = _hosting.poll()
		if bool(answer.get("ok", false)): break
		if str(answer.get("reason", "")) != "pending": break
		await get_tree().create_timer(0.2).timeout
	if not bool(answer.get("ok", false)):
		var reason: String = str(answer.get("reason", "timeout"))
		_stop_room()
		_room_panel.show_failure(_host_message(reason))
		return
	var join_code: String = str(answer.get("join_code", ""))
	var visitor_code: String = str(answer.get("visitor_join_code", ""))
	var url: String = str(answer.get("url", ""))
	_room_panel.show_room(join_code, visitor_code)
	DisplayServer.clipboard_set(join_code)
	if visitor_code.is_empty():
		_room_panel.show_status("房间开在 %s，成员加入码已复制；访客加入码暂不可用，重启房间再试。" % url)
	else:
		_room_panel.show_status("房间开在 %s，成员加入码已复制；访客照料码只能浇水、除草。" % url)


func _stop_room() -> void:
	if _hosting == null: return
	_hosting.stop()
	_hosting = null


## Rotating a room's codes is a stop-and-restart on this machine: the old
## process must exit before the authority can read the new invitation. The panel
## already asked the player; this only performs it and reports the outcome.
func _rotate_room_codes() -> void:
	if _hosting == null or not _hosting.is_running():
		_room_panel.show_rotate_failure("房间没有在运行，无法更换加入码；重新开房后再试。")
		return
	if is_instance_valid(farm_scene):
		_room_panel.show_rotate_failure("进入农场后不能再更换加入码；重新启动游戏后开房再换。")
		return
	_room_panel.show_rotating()
	# The rotation is synchronous (stop + file replacement + restart); let the
	# progress line paint before that work blocks the frame.
	await get_tree().process_frame
	var answer: Dictionary = _hosting.rotate_invites(8000)
	if not bool(answer.get("ok", false)):
		var reason: String = str(answer.get("reason", "timeout"))
		# The authority may have failed to come back; keep the fact visible with
		# the reason instead of pretending the old room is still healthy.
		_room_panel.show_rotate_failure(_rotate_message(reason))
		return
	_room_panel.show_rotated(str(answer.get("join_code", "")),
		str(answer.get("visitor_join_code", "")))


func _rotate_message(reason: String) -> String:
	match reason:
		"not_started": return "房间没有在运行，无法更换加入码；重新开房后再试。"
		"unsupported_build":
			return "这个版本不能更换加入码，需要用带服务器脚本的开发版本运行。"
		"invite_missing": return "房间数据里找不到当前加入码，旧码仍然有效；请重开房后再试。"
		"write_failed": return "新加入码没有写入成功，旧码仍然有效；请检查磁盘空间后重试。"
		"archive_failed", "replace_failed":
			return "新加入码没有替换成功，已恢复旧码；请稍后重试。"
		"data_dir_locked":
			return "房间进程还没有完全退出，加入码没有更换；请稍后重试，旧码仍然有效。"
		"server_exited", "listen_failed":
			return "房间重启失败（%s），已恢复旧码；请稍后重试。" % reason
		"timeout":
			return "房间重启超时，加入码没有更换；已在旧码上重新开房，旧码仍然有效。"
	if reason.ends_with("_restart_failed"):
		return "更换失败，房间未能重新启动（%s）；请重新开房。" % reason.trim_suffix("_restart_failed")
	if reason.ends_with("_rollback_failed"):
		return "更换失败，旧加入码也未能恢复（%s）；请用 invite.previous.bin 手动恢复后重开房。" % reason.trim_suffix("_rollback_failed")
	return "加入码没有更换（%s），旧码仍然有效。" % reason


func _host_message(reason: String) -> String:
	match reason:
		"unsupported_build":
			return "这个版本不能在本机开房，需要用带服务器脚本的开发版本运行。"
		"directory_unwritable": return "房间存档目录无法写入，请检查磁盘空间。"
		"invalid_port": return "没有找到可用的端口，请稍后重试。"
		"spawn_failed": return "无法启动世界进程，请确认游戏文件完整。"
		"server_exited": return "世界进程启动后立即退出了，请重试。"
		"join_code": return "世界已启动，但加入码生成失败，请重试。"
	return "房间没有开成（%s）。" % reason


## The authority binds 0.0.0.0; the room needs a port nobody else took.
func _free_port() -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = Time.get_ticks_usec()
	for attempt: int in 8:
		var port: int = rng.randi_range(20000, 45000)
		var probe := TCPServer.new()
		if probe.listen(port, "127.0.0.1") == OK:
			probe.stop()
			return port
	return 20000


func _join_message(reason: String) -> String:
	match reason:
		"invalid_code", "invalid_url", "invalid_certificate", "invalid_server_name": 
			return "这串加入码不完整或已损坏，请向房主重新索取。"
		"invite_expired": return "邀请已过期，请向房主重新索取。"
		"invite_used": return "这份邀请已经被使用过。"
		"invalid_grant", "invalid_grant_id", "invalid_role", "invalid_world_id", "invalid_secret", "invalid_expiry":
			return "邀请内容无效，请向房主重新索取。"
		"world_mismatch": return "这串加入码属于另一个世界。"
		"protocol_version", "rules_version": return "双方版本不一致，无法进入同一个世界。"
		"connection_failed": return "连不上这个地址，请确认房主已经启动世界，且在同一网络。"
		"server_disconnected": return "连接被服务器关闭。"
		"timeout": return "等待世界响应超时，请稍后重试。"
		"player_proof": return "这个世界已经登记了另一个玩家档案。换回原来的档案，或请房主重置这个身份的绑定。"
		"player_invalid_secret": return "本机的玩家凭据缺失或损坏，暂时无法以具名身份进入世界。"
		"player_bindings_unavailable": return "服务器还没有准备好身份记录，请稍后再试。"
		"invalid_player": return "玩家身份或名称无效，无法进入世界。"
	if reason.begins_with("save_player_bindings_"):
		return "玩家身份没有保存成功，请稍后再试。"
	return "未能进入这个世界（%s）。" % reason


func show_stage(value: float, message: String) -> void:
	_progress.value = value
	_status.text = message
	print("STARTUP_STAGE progress=%.0f text=%s" % [value, message])
	# Two frame boundaries let Control layout and the renderer present this stage
	# before the next synchronous geometry batch starts.
	await get_tree().process_frame
	await get_tree().process_frame


func _assemble() -> void:
	await show_stage(45.0, "正在读取农场存档…" if _world_client == null else "正在准备世界…")
	var packed: PackedScene = _packed
	_packed = null
	if packed == null:
		_fail("农场场景无法打开，请重试。", "scene_missing")
		return
	farm_scene = packed.instantiate()
	farm_scene.process_mode = Node.PROCESS_MODE_DISABLED
	farm_scene.startup_progress = show_stage
	if not _recording:
		farm_scene.settings_store = settings_store
		farm_scene.startup_preferences = _loaded
	if farm_store != null: farm_scene.store = farm_store
	# Singleplayer keeps the same stable player id used for rooms, so the market
	# account and bag belong to this machine's identity.
	farm_scene.set("local_player_id", _player_id)
	if _world_client != null:
		farm_scene.remote = _world_client
		farm_scene.remote_seed = _world_state
		# The room belongs to this session: it lives until the farm scene goes.
		if _hosting != null:
			farm_scene.hosted_room = _hosting
			_hosting = null
	get_tree().root.add_child(farm_scene)
	if not farm_scene.startup_complete: await farm_scene.startup_finished
	farm_scene.startup_progress = Callable()
	farm_scene.get_node("Environment").startup_progress = Callable()
	farm_scene.process_mode = Node.PROCESS_MODE_INHERIT
	farm_scene.set_process_input(false)
	farm_scene.set_process_unhandled_input(false)
	farm_scene.camera.free_input_enabled = false
	if _first:
		await _measure()
		_show_choice()
	else:
		await _finish()


func _apply_tier(tier: String) -> void:
	var previous: Dictionary = farm_scene.settings_values.duplicate(true)
	farm_scene.settings_values.merge(Presets.values(tier, get_window().size.y, RenderingServer.get_current_rendering_method() == "forward_plus"), true)
	farm_scene._apply_settings(previous)


func _measure() -> void:
	await show_stage(96.0, "正在进行首次性能测试，约需几秒…")
	if not farm_scene._loaded or DisplayServer.get_name() == "headless" or not get_window().has_focus():
		return
	var old_vsync: DisplayServer.VSyncMode = DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	farm_scene.window_activity.set_startup_benchmark(true)
	_apply_tier("standard")
	var result: Dictionary = await Benchmark.sample(get_tree(), get_window())
	if result.ok:
		_measured = true
		if result.p90_ms > 22.2:
			_recommended = "low"
		elif result.p90_ms <= 16.7:
			await show_stage(97.0, "正在检查高画质表现…")
			_apply_tier("high")
			while farm_scene._high_quality_pending: await get_tree().process_frame
			var high: Dictionary = await Benchmark.sample(get_tree(), get_window())
			print("STARTUP_BENCHMARK_HIGH result=%s" % str(high))
			_recommended = "high" if high.ok and high.p90_ms <= 20.0 else "standard"
		else:
			_recommended = "standard"
	print("STARTUP_BENCHMARK result=%s recommendation=%s" % [str(result), _recommended])
	farm_scene.window_activity.set_startup_benchmark(false)
	DisplayServer.window_set_vsync_mode(old_vsync)


func _show_choice() -> void:
	_status.text = "为你的农场选择画质"
	_progress.hide()
	_selected = _recommended
	var index: int = Presets.ORDER.find(_recommended)
	_recommendation.text = ("根据刚才的运行表现，推荐%s。" if _measured else "本次未取得稳定测试结果，先推荐%s。") % Presets.TITLES[index]
	_recommendation.text += "\n之后可以在设置中调整。"
	_slider.set_value_no_signal(SLIDER_TIERS.find(_recommended))
	_select_slider(_slider.value)
	_choices.show()
	_slider.grab_focus()
	print("STARTUP_CHOICE_READY recommendation=%s measured=%s" % [_recommended, _measured])


func _select_slider(value: float) -> void:
	_selected = SLIDER_TIERS[int(value)]
	for index: int in _tier_labels.size():
		_tier_labels[index].add_theme_color_override("font_color", FarmTheme.INK if index == int(value) else FarmTheme.Tokens.MUTED)


func _confirm() -> void:
	if _starting: return
	_starting = true
	_choices.hide()
	_progress.show()
	await show_stage(98.0, "正在应用所选画质…")
	_apply_tier(_selected)
	while farm_scene._high_quality_pending: await get_tree().process_frame
	farm_scene._settings_dirty = true
	if not farm_scene._save_settings():
		_starting = false
		_choices.show()
		_progress.hide()
		_status.text = "画质已应用，但设置未能保存，请重试。"
		_continue.text = "重试保存并进入农场"
		_unsaved_continue.show()
		_continue.grab_focus()
		return
	await _finish()


func _finish() -> void:
	await show_stage(99.0, "正在准备进入农场…")
	if DisplayServer.get_name() != "headless": await RenderingServer.frame_post_draw
	_progress.value = 100
	get_tree().current_scene = farm_scene
	farm_scene.set_process_input(true)
	farm_scene.set_process_unhandled_input(true)
	farm_scene.camera.free_input_enabled = true
	if OS.has_feature("editor") and OS.get_cmdline_user_args().has("--dev-preview"):
		farm_scene._report_preview_ready.call_deferred()
	print("STARTUP_COMPLETE")
	queue_free()


func _fail(message: String, reason: String) -> void:
	_progress.indeterminate = false
	_status.text = message
	_retry.show()
	_retry.grab_focus()
	push_warning("STARTUP_FAILED stage=" + reason)
