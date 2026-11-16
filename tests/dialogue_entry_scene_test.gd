extends SceneTree
## 对话面板的主场景入口：真实 `main.tscn` + 真实 `world_server.gd` + loopback
## WSS + 真实 `dialogue_panel.gd`。窗口运行（不加 `--headless`），因为它需要
## 真实绘制帧来截图。
##
## 访问角色用访客：访客可以读 `dialogues_view()`，但 `say` 被权威以 `forbidden`
## 拒绝。这样一次真实点按能同时证明「意图确实转发到权威」和「拒绝显示权威原文」
## 两件事，而不是在客户端伪造一段拒绝。
##
## 覆盖：
##   - 共享世界底栏出现「对话」入口，真实鼠标点按能打开面板并渲染权威行；
##   - 点按「问候」后，面板显示权威原文 `当前身份不能执行这个操作。`，且拒绝
##     不改动上一次确认的视图；
##   - 打开中的面板拥有 Esc：一次 Esc 关闭对话面板，不关闭其它面板、不清空
##     世界工具；居民面板仍各自持有自己的 Esc；
##   - 权威断开后对话面板清空并显示「世界尚未打开」。
##
## 产物写在 `.local/verification/dialogue-entry-<ticks>/`。

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const SettingsStore = preload("res://settings/settings_store.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const START: float = 1800064000.0
const WORLD: String = "world-dialogue-entry"
const HOST_PLAYER: String = "player_00000000000000000000000000000401"
const VISITOR_PLAYER: String = "player_00000000000000000000000000000402"
const VISITOR_SECRET: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtNDI="
const REFUSAL: String = "当前身份不能执行这个操作。"

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var checks: int = 0
var failures: Array[String] = []
var client: WorldClient
var scene: Node3D
var _joined: bool = false
var _lost: bool = false
var _reconnecting: bool = false
var _refusals: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(".local/verification/dialogue-entry-%d"
		% Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	root.size = Vector2i(1600, 900)
	if not await _start_authority():
		_finish()
		return
	var code: String = _visitor_code()
	_expect(not code.is_empty(), "The visitor join code is built from the invite")
	if code.is_empty():
		await _stop_server()
		_finish()
		return
	if not await _open_client(code):
		await _stop_server()
		_finish()
		return
	await _mount_scene()

	# 共享世界底栏有「对话」入口；入口是文字按钮，不加新的图标槽。
	var entry: Button = scene.hud.get_node("Layout/FarmControls/Dialogue") as Button
	_expect(entry != null and entry.visible, "A shared world shows the dialogue entry")
	_expect(entry != null and entry.text == "对话", "The dialogue entry is labelled 对话")
	_expect(entry != null and entry.icon == null,
		"The dialogue entry stays text-only like the other world entries")
	# 新增入口不能把底栏撑出窗口：共享世界已有 17 个可见入口。
	var bar: HBoxContainer = scene.hud.get_node("Layout/FarmControls") as HBoxContainer
	var previous_right: float = -1.0
	var visible_entries: int = 0
	var fits: bool = true
	for child: Node in bar.get_children():
		if not (child is Button) or not (child as Button).visible:
			continue
		var rect: Rect2 = (child as Button).get_global_rect()
		visible_entries += 1
		if not root.get_visible_rect().encloses(rect) or rect.position.x < previous_right:
			fits = false
		previous_right = rect.end.x
	_expect(fits and visible_entries == 17,
		"All %d visible bar entries fit 1600px without overlapping" % visible_entries)

	# 真实鼠标点按底栏入口打开面板；刷新请求走真实 RPC。
	if entry != null:
		await _click(entry)
	var opened: bool = await _wait(_panel_ready, 15000)
	_expect(opened, "Clicking the bar entry opens the dialogue panel with an authoritative view")
	if not opened:
		await _shot("open-failed")
		await _stop_server()
		_finish()
		return
	_expect(scene.dialogue_panel.residents.size() == NpcRoster.IDS.size(),
		"The panel renders one row per authoritative resident")
	var status_line: Label = scene.dialogue_panel.find_child("DialogueStatus", true, false) as Label
	_expect(status_line != null and status_line.text == "对话已启用｜%d 位居民"
			% NpcRoster.IDS.size(),
		"An available authority view shows the enabled line")
	_expect(scene.dialogue_panel.is_open(), "The scene's own panel is the one shown")
	await _shot("panel")

	# 访客点按一次真实按钮：意图经 RPC 29 到权威，权威拒绝，面板显示原文。
	var rows_before: String = JSON.stringify(scene.dialogue_panel.residents)
	var button: Button = scene.dialogue_panel.find_child("Say_greet", true, false) as Button
	_expect(button != null and not button.disabled,
		"A ready resident enables the fixed say buttons")
	var status: Label = scene.dialogue_panel.find_child("Status", true, false) as Label
	if button != null:
		await _click(button)
	var refused: bool = await _wait(func() -> bool:
		return status != null and status.text == REFUSAL, 15000)
	_expect(refused, "An authority refusal is shown with the authority's own text")
	_expect(JSON.stringify(scene.dialogue_panel.residents) == rows_before,
		"A refused say keeps the last confirmed rows instead of inventing a reply")
	await _shot("refusal")

	# Esc 归属：对话面板打开时一次 Esc 只关它自己，不碰工具和其它面板。
	scene.selected_tool = "water"
	await _escape()
	_expect(not scene.dialogue_panel.visible and scene.selected_tool == "water",
		"Esc closes the dialogue panel and leaves the world tool alone")
	_expect(scene.resident_panel != null and not scene.resident_panel.visible,
		"Closing dialogue does not touch the resident panel")
	# 居民面板有独立的 Esc，不会顺带打开或关闭对话面板。
	scene._open_residents()
	await process_frame
	_expect(scene.resident_panel.visible, "The resident panel opens on its own entry")
	await _escape()
	_expect(not scene.resident_panel.visible and not scene.dialogue_panel.visible,
		"Esc closes the resident panel only; the dialogue panel stays closed")

	# 断线：对话视图属于权威，连接消失后清空并标明世界未打开。
	scene._open_dialogue()
	await process_frame
	_expect(scene.dialogue_panel.visible, "The dialogue panel is open before the link drops")
	await _stop_server()
	var cleared: bool = await _wait(_dialogue_cleared, 20000)
	_expect(cleared, "A lost authority clears the dialogue view and says the world is not open")
	_expect(_lost or _reconnecting,
		"The client observed the authority loss (lost=%s reconnecting=%s)"
			% [_lost, _reconnecting])
	await _shot("disconnected")

	await _close_client()
	_finish()


# ------------------------------------------------------------------ scene

func _mount_scene() -> void:
	scene = load("res://scenes/main.tscn").instantiate()
	scene.store = null
	scene.settings_store = SettingsStore.new(dir.path_join("preferences"))
	scene.remote = client
	scene.remote_seed = _seed
	root.add_child(scene)
	await create_timer(0.8).timeout
	_expect(scene._loaded, "The farm scene loads the shared world")


# ------------------------------------------------------------------ input

func _click(control: Control) -> void:
	await process_frame
	var ancestor: Node = control.get_parent()
	while ancestor != null:
		if ancestor is ScrollContainer:
			ancestor.ensure_control_visible(control)
			await process_frame
			await process_frame
			break
		ancestor = ancestor.get_parent()
	var point: Vector2 = control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	await process_frame
	for down: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		root.push_input(event, true)
		await process_frame
	await process_frame


func _escape() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_ESCAPE
	event.pressed = true
	root.push_input(event, true)
	await process_frame
	await process_frame


func _shot(label: String) -> void:
	await create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(dir.path_join(label + ".png"))


# ----------------------------------------------------------------- client

var _seed: Dictionary = {}


func _open_client(code: String) -> bool:
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(farm: RefCounted, decorations: RefCounted,
			now: float) -> void:
		_seed = {"farm": farm, "decorations": decorations, "now_utc": now})
	client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
	client.lost.connect(func(reason: String) -> void:
		_lost = true
		_refusals.append(reason))
	# 正常断线先进入退避重连，不是立即放弃；面板在这条路径上也要清空。
	client.reconnecting.connect(func(_attempt: int, _delay: float) -> void:
		_reconnecting = true)
	if not client.start(code, VISITOR_PLAYER, "阿青",
			Marshalls.base64_to_raw(VISITOR_SECRET)):
		_expect(false, "The client accepts the join code")
		return false
	var arrived: bool = await _wait(func() -> bool:
		return (not _seed.is_empty() and client.joined) or not _refusals.is_empty(), 20000)
	_expect(arrived and not _seed.is_empty(),
		"The client receives the authoritative world (refusals=%s)" % str(_refusals))
	return arrived and not _seed.is_empty()


func _close_client() -> void:
	if client != null and is_instance_valid(client):
		client.close()
		client.queue_free()
		client = null
	await process_frame
	await process_frame


func _visitor_code() -> String:
	var invite_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		world_dir.path_join("invite.bin"))
	var visitor_secret: PackedByteArray = Crypto.new().hmac_digest(
		HashingContext.HASH_SHA256, invite_bytes, "farm-visitor".to_utf8_buffer())
	var grant: Dictionary = WorldInvite.make("server-visitor", visitor_secret,
		WorldInvite.VISITOR, WORLD, 0.0, false)
	var pem: String = FileAccess.get_file_as_bytes(
		world_dir.path_join("server.crt")).get_string_from_ascii()
	return WorldJoinCode.encode(grant, "wss://127.0.0.1:%d" % port, pem, "localhost")


# ----------------------------------------------------------------- server

func _start_authority() -> bool:
	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if port <= 0:
		return false
	var arguments := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % START, "--run-seconds=0",
		"--join-url=wss://127.0.0.1:%d" % port,
		"--host-player=" + HOST_PLAYER, "--residents",
	])
	server_pid = _spawn(arguments)
	_expect(server_pid > 0, "The authority process starts")
	if server_pid <= 0:
		return false
	var running: bool = await _wait(func() -> bool:
		var status: Dictionary = _read_json(world_dir.path_join("server-status.json"))
		return str(status.get("state", "")) == "running" \
			and int(status.get("pid", 0)) == server_pid, 20000)
	_expect(running, "The authority reports ready")
	return running


func _spawn(arguments: PackedStringArray) -> int:
	var pieces: PackedStringArray = PackedStringArray([_shell_quote(OS.get_executable_path())])
	for argument: String in arguments:
		pieces.append(_shell_quote(argument))
	var command: String = "exec " + " ".join(pieces) + " > " \
		+ _shell_quote(dir.path_join("server.log")) + " 2>&1"
	return OS.create_process("/bin/sh", PackedStringArray(["-c", command]), false)


func _shell_quote(value: String) -> String:
	return "'" + value.replace("'", "'\\''") + "'"


func _stop_server() -> void:
	if server_pid <= 0:
		return
	var marker := FileAccess.open(world_dir.path_join("stop"), FileAccess.WRITE)
	if marker != null:
		marker.store_string("stop")
		marker.close()
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline and OS.is_process_running(server_pid):
		await create_timer(0.05).timeout
	server_pid = 0
	var marker_path: String = world_dir.path_join("stop")
	if FileAccess.file_exists(marker_path):
		DirAccess.remove_absolute(marker_path)


# ----------------------------------------------------------------- helpers

func _dialogue_cleared() -> bool:
	if scene == null or scene.dialogue_panel == null:
		return false
	var line: Label = scene.dialogue_panel.find_child("DialogueStatus", true, false) as Label
	return scene.dialogue_panel.residents.is_empty() \
		and line != null and line.text == "世界尚未打开"


func _panel_ready() -> bool:
	if scene == null or scene.dialogue_panel == null:
		return false
	return scene.dialogue_panel.visible \
		and bool(scene.dialogue_panel.view.get("available", false))


func _wait(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _free_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0, "127.0.0.1") != OK:
		return 0
	var chosen: int = probe.get_local_port()
	probe.stop()
	return chosen


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("DIALOGUE_ENTRY_TEST checks=%d failures=%d evidence=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
