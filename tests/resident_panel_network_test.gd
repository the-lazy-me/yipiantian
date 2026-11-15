extends SceneTree
## M10-04 居民面板的真实网络测试：真实 `world_server.gd` + loopback WSS +
## RPC 25/26 + 真实 `resident_panel.gd`。面板按 `main.gd` 的方式接线：刷新只发
## 一次 `request_residents(..., "state")`，答复整份刷新，断线由场景清空并标明
## 不可用。
##
## 覆盖两种权威启动：
##   - `--residents` 启用：面板显示权威名册顺序、名称、角色、人格、关系、记忆、
##     意图与真实购买；刷新只产生一个答复且不写 `residents.json`；
##   - 断线：面板清空并显示“世界尚未打开”；
##   - 同一目录不带 `--residents` 重启：面板显示“居民未启用”，无居民行，
##     sidecar 逐字节不变。
##
## 运行产物写在 `.local/verification/resident-panel-network-<ticks>/`。

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")
const NpcRoles = preload("res://npc/npc_roles.gd")
const NpcPersonality = preload("res://npc/npc_personality.gd")
const ResidentPanel = preload("res://ui/resident_panel.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const START: float = 1800056400.0
## 重启晚于已保存的记忆时刻与本次运行，仍在 300 秒采购冷却内；居民关闭时不
## 会再产生动作，sidecar 因此逐字节不变。
const RESTART_AT: float = START + 120.0
const WORLD: String = "world-resident-panel-network"
const PLAYER_A: String = "player_00000000000000000000000000000301"
const PLAYER_B: String = "player_00000000000000000000000000000302"
const NAME_B: String = "阿木"

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var url: String = ""
var checks: int = 0
var failures: Array[String] = []
var client: WorldClient
var resident_panel: ResidentPanel
var _ready: bool = false
var _refusals: Array[String] = []
var _events: Array = []
var _command_pending: Dictionary = {}
var _lost_seen: bool = false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/resident-panel-network-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	root.size = Vector2i(1280, 720)
	_mount_panel()
	await process_frame

	if not await _start_authority(PLAYER_A, START, true):
		_finish()
		return
	var codes: Dictionary = _join_codes()
	_expect(not str(codes.get("member", "")).is_empty(),
		"The member join code is built from the operator's material")
	if str(codes.get("member", "")).is_empty():
		await _stop_server()
		_finish()
		return

	await _phase_enabled(codes)
	var bytes_before_disable: PackedByteArray = _bytes(_residents_path())
	_expect(not bytes_before_disable.is_empty(),
		"The resident sidecar exists before the connection drops")
	await _phase_disconnect()
	await _close_client()
	await _stop_server()

	if not await _start_authority(PLAYER_A, RESTART_AT, false):
		_finish()
		return
	await _phase_disabled(_join_codes(), bytes_before_disable)
	await _close_client()
	await _stop_server()
	_finish()


# -------------------------------------------------------------- panel wiring

## Mirrors `main.gd`: the scene owns the panel and forwards refreshes; every
## authority reply replaces the panel's whole view; a lost connection clears it.
func _mount_panel() -> void:
	resident_panel = ResidentPanel.new()
	resident_panel.name = "Residents"
	root.add_child(resident_panel)
	resident_panel.refresh_requested.connect(_resident_refresh)
	resident_panel.close_requested.connect(func() -> void: pass)


func _resident_refresh() -> void:
	if client == null or not client.request_residents("resident-state", "state"):
		resident_panel.show_unavailable("not_open")


func _on_residents_result(request_id: String, payload: Dictionary) -> void:
	_events.append({"request_id": request_id, "payload": payload.duplicate(true)})
	resident_panel.apply_result(payload)


func _on_lost(reason: String) -> void:
	_refusals.append(reason)
	_lost_seen = true
	# Mirrors `main.gd._on_remote_lost`: the resident view is authority-owned, so
	# a broken connection clears it instead of leaving a stale roster on screen.
	resident_panel.show_unavailable("not_open")


## Mirrors `main.gd._on_remote_reconnecting`: a dropped link clears the resident
## panel while the rest of the world keeps its last confirmed frame.
func _on_reconnecting(_attempt: int, _delay: float) -> void:
	_lost_seen = true
	resident_panel.show_unavailable("not_open")


func _open_panel(label: String) -> Dictionary:
	resident_panel.open_panel(resident_panel.view.duplicate(true))
	_expect(resident_panel.is_open(), "Opening the resident panel shows it (%s)" % label)
	var before: int = _events.size()
	var refresh: Button = resident_panel.find_child("Refresh", true, false) as Button
	refresh.pressed.emit()
	var reply: Dictionary = await _next_event(before,
		"resident panel state (%s)" % label)
	_expect(bool(reply.get("ok", false)),
		"The panel receives a real authority state (%s, reason=%s)"
			% [label, str(reply.get("reason", ""))])
	return reply


# ------------------------------------------------------------------- enabled

func _phase_enabled(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The member joins over WSS")
	if client == null or not client.joined:
		return
	var opened: Dictionary = await _submit(FarmCommand.make_market_open(
		"resident-panel-net-market", client.world_time()))
	_expect(bool(opened.get("ok", false)),
		"The member opens the merchant market (reason=%s)"
			% str(opened.get("reason", "")))

	# The first economy tick gives each resident a real purchase. Poll through
	# the panel's own request path so the rendered view is the authority's.
	var rows: Array = []
	for attempt: int in 8:
		if attempt > 0:
			await create_timer(0.5).timeout
		var reply: Dictionary = await _open_panel("enabled-%d" % attempt)
		var value: Variant = _state(reply).get("residents", [])
		if value is Array:
			rows = value
		if _purchased(rows):
			break
	_expect(_purchased(rows),
		"The enabled authority has a completed purchase for every resident")
	_check_panel(rows, "enabled")

	# Refreshing sends exactly one request and renders one replacement.
	var before: int = _events.size()
	var refresh: Button = resident_panel.find_child("Refresh", true, false) as Button
	refresh.pressed.emit()
	await _wait(func() -> bool: return _events.size() > before, 15000)
	_expect(_events.size() == before + 1,
		"One refresh press produces exactly one authority reply")
	await create_timer(0.4).timeout
	_expect(_events.size() == before + 1,
		"No second request is sent by a single refresh")
	var last_payload: Dictionary = (_events.back() as Dictionary).get("payload", {})
	_expect(JSON.stringify(_state(last_payload).get("residents", [])) \
			== JSON.stringify(rows),
		"The refresh renders the same authoritative rows")

	# Refreshing never writes the resident document.
	var bytes_before: PackedByteArray = _bytes(_residents_path())
	for index: int in 3:
		var mark: int = _events.size()
		refresh.pressed.emit()
		await _wait(func() -> bool: return _events.size() > mark, 15000)
	_expect(_bytes(_residents_path()) == bytes_before,
		"Refreshing the read-only panel leaves residents.json byte-identical")


func _check_panel(rows: Array, label: String) -> void:
	_expect(bool(resident_panel.view.get("available", false)),
		"%s: the panel keeps the authoritative available flag" % label)
	_expect(resident_panel.residents.size() == NpcRoster.IDS.size(),
		"%s: the panel has one block per roster resident" % label)
	var ids: Array = []
	var rendered: Array = []
	for row_value: Variant in resident_panel.residents:
		if row_value is Dictionary:
			ids.append(str((row_value as Dictionary).get("id", "")))
	for child: Node in _list().get_children():
		rendered.append(str(child.name))
	var expected: Array = []
	for npc_id: String in NpcRoster.IDS:
		expected.append("Resident_" + npc_id)
	_expect(JSON.stringify(ids) == JSON.stringify(NpcRoster.IDS),
		"%s: the panel keeps NpcRoster.IDS order" % label)
	_expect(rendered == expected,
		"%s: the rendered blocks follow the authority order" % label)
	for npc_id: String in NpcRoster.IDS:
		var name_text: String = _label("Name_" + npc_id)
		_expect(name_text.contains(str(NpcRoster.DISPLAY_NAMES.get(npc_id, "")))
				and name_text.contains(NpcRoles.role_of(npc_id)),
			"%s: %s shows its authoritative name and role" % [label, npc_id])
		var traits_text: String = _label("Traits_" + npc_id)
		var traits_ok: bool = not traits_text.is_empty()
		for trait_name: String in NpcPersonality.TRAITS:
			if not traits_text.contains(str(NpcPersonality.LABELS[trait_name])):
				traits_ok = false
		_expect(traits_ok, "%s: %s shows all five trait readings" % [label, npc_id])
		for peer_id: String in NpcRoster.IDS:
			if peer_id == npc_id:
				continue
			_expect(resident_panel.find_child(
					"Relation_%s_%s" % [npc_id, peer_id], true, false) != null,
				"%s: %s renders its relation with %s" % [label, npc_id, peer_id])
		_expect(_label("Memory_" + npc_id).contains("记忆 "),
			"%s: %s shows its memory count" % [label, npc_id])
		_expect(_label("Intent_" + npc_id).contains("已消费意图"),
			"%s: %s shows its consumed intent count" % [label, npc_id])
		_expect(_label("Purchase_" + npc_id).contains("最近购买 ")
				and not _label("Purchase_" + npc_id).contains("暂无"),
			"%s: %s shows its completed purchase" % [label, npc_id])


# ----------------------------------------------------------------- disconnect

func _phase_disconnect() -> void:
	_expect(resident_panel.is_open(), "The panel is still open before the connection drops")
	_lost_seen = false
	await _stop_server()
	var lost: bool = await _wait(func() -> bool: return _lost_seen, 15000)
	_expect(lost, "The client observes the real authority loss")
	_expect(resident_panel.view.is_empty() or not bool(
			resident_panel.view.get("available", true)),
		"A lost connection leaves no available resident view")
	_expect(_status() == "世界尚未打开",
		"The panel says the world is not open after the connection drops")
	_expect(not _list().visible and _list().get_child_count() == 0,
		"A lost connection clears and disables the resident list")


# ------------------------------------------------------------------ disabled

func _phase_disabled(codes: Dictionary, bytes_before: PackedByteArray) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The member joins the authority started without residents")
	if client == null or not client.joined:
		return
	var reply: Dictionary = await _open_panel("disabled")
	var state: Dictionary = _state(reply)
	_expect(not bool(state.get("available", true)),
		"An authority without --residents reports unavailable")
	_expect(str(state.get("reason", "")) == "disabled",
		"The disabled view names the disabled reason")
	_expect(_status() == "居民未启用",
		"The panel says residents are disabled")
	_expect(not _list().visible and _list().get_child_count() == 0,
		"The disabled panel renders no resident row")
	_expect(_bytes(_residents_path()) == bytes_before,
		"A disabled authority leaves residents.json byte-identical")
	await create_timer(0.4).timeout
	_expect(_bytes(_residents_path()) == bytes_before,
		"Staying on the disabled authority does not write residents.json")


# ------------------------------------------------------------------ helpers

func _state(reply: Dictionary) -> Dictionary:
	var value: Variant = reply.get("state")
	return value if value is Dictionary else {}


func _purchased(rows: Array) -> bool:
	if rows.size() != NpcRoster.IDS.size():
		return false
	for row_value: Variant in rows:
		if not row_value is Dictionary:
			return false
		if int((row_value as Dictionary).get("intents_consumed", 0)) <= 0:
			return false
		var purchase: Variant = (row_value as Dictionary).get("last_purchase")
		if not purchase is Dictionary or (purchase as Dictionary).is_empty():
			return false
	return true


func _list() -> VBoxContainer:
	return resident_panel.find_child("ResidentList", true, false) as VBoxContainer


func _status() -> String:
	var label: Label = resident_panel.find_child("ResidentStatus", true, false) as Label
	return label.text if label != null else ""


func _label(node_name: String) -> String:
	var label: Label = resident_panel.find_child(node_name, true, false) as Label
	return label.text if label != null else ""


func _next_event(before: int, label: String, timeout_ms: int = 15000) -> Dictionary:
	var arrived: bool = await _wait(func() -> bool: return _events.size() > before,
		timeout_ms)
	if not arrived:
		_expect(false, "A %s reply arrives" % label)
		return {}
	var entry: Dictionary = _events[_events.size() - 1]
	var payload: Variant = entry.get("payload")
	return payload if payload is Dictionary else {}


# ------------------------------------------------------------------- clients

func _open_client(code: String, player_id: String, display_name: String,
		secret_text: String) -> bool:
	_ready = false
	_refusals.clear()
	_events.clear()
	_command_pending.clear()
	_lost_seen = false
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
			_now: float) -> void:
		_ready = true)
	client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
	client.lost.connect(_on_lost)
	client.reconnecting.connect(_on_reconnecting)
	client.residents_result.connect(_on_residents_result)
	client.committed.connect(_on_committed)
	var secret: PackedByteArray = Marshalls.base64_to_raw(secret_text) \
		if not player_id.is_empty() else PackedByteArray()
	if not client.start(code, player_id, display_name, secret):
		return false
	var arrived: bool = await _wait(func() -> bool:
		return (_ready and client.joined) or not _refusals.is_empty(), 20000)
	if not arrived or not _ready or not client.joined:
		_expect(false, "The client joins: refusals=%s" % str(_refusals))
		return false
	return true


func _close_client() -> void:
	if client != null:
		if is_instance_valid(client):
			client.close()
			client.queue_free()
		client = null
	_events.clear()
	_command_pending.clear()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout


func _on_committed(request_id: String, payload: Dictionary) -> void:
	_command_pending[request_id] = payload


func _submit(command: Dictionary) -> Dictionary:
	var request_id: String = str(command.get("id", ""))
	_command_pending.erase(request_id)
	if client == null or not client.submit(command):
		return {"ok": false, "reason": "not_sent"}
	var arrived: bool = await _wait(func() -> bool:
		return _command_pending.has(request_id), 20000)
	if not arrived:
		_expect(false, "A command reply arrives for %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _command_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


# -------------------------------------------------------------------- server

func _start_authority(host_player: String, now: float, residents: bool) -> bool:
	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if port <= 0:
		return false
	url = "wss://127.0.0.1:%d" % port
	server_pid = _spawn_server(host_player, now, residents, "server.log")
	_expect(server_pid > 0, "The authority process starts")
	if server_pid <= 0:
		return false
	var running: bool = await _wait(func() -> bool:
		var status: Dictionary = _server_status()
		return str(status.get("state", "")) == "running" \
			and int(status.get("pid", 0)) == server_pid, 20000)
	_expect(running, "The authority reports ready")
	if not running:
		return false
	if OS.get_name() != "Windows":
		var ready: Dictionary = _server_line("server.log", "WORLD_SERVER_READY ")
		_expect(str(ready.get("state", "")) == "running",
			"The ready line reports the running state")
		_expect(bool(ready.get("residents", false)) == residents,
			"The ready line records the residents flag")
	return true


func _spawn_server(host_player: String, now: float, residents: bool,
		log_name: String) -> int:
	var arguments := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % now, "--run-seconds=0", "--join-url=" + url,
		"--host-player=" + host_player,
	])
	if residents:
		arguments.append("--residents")
	if OS.get_name() == "Windows":
		return OS.create_process(OS.get_executable_path(), arguments, false)
	var pieces: PackedStringArray = []
	pieces.append(_shell_quote(OS.get_executable_path()))
	for argument: String in arguments:
		pieces.append(_shell_quote(argument))
	var command: String = "exec " + " ".join(pieces) + " > " \
		+ _shell_quote(dir.path_join(log_name)) + " 2>&1"
	return OS.create_process("/bin/sh", PackedStringArray(["-c", command]), false)


func _shell_quote(value: String) -> String:
	return "'" + value.replace("'", "'\\''") + "'"


func _server_line(log_name: String, prefix: String) -> Dictionary:
	var path: String = dir.path_join(log_name)
	if not FileAccess.file_exists(path):
		return {}
	for line: String in FileAccess.get_file_as_string(path).split("\n"):
		if line.begins_with(prefix):
			var parsed: Variant = JSON.parse_string(line.substr(prefix.length()))
			return parsed if parsed is Dictionary else {}
	return {}


func _join_codes() -> Dictionary:
	var invite_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		world_dir.path_join("invite.bin"))
	var pem: String = FileAccess.get_file_as_bytes(
		world_dir.path_join("server.crt")).get_string_from_ascii()
	var member_code: String = WorldJoinCode.encode(WorldInvite.make(
		"server-invite", invite_bytes, WorldInvite.MEMBER, WORLD, 0.0, false),
		url, pem, "localhost")
	return {"member": member_code}


func _residents_path() -> String:
	return world_dir.path_join("residents.json")


func _server_status() -> Dictionary:
	return _read_json(world_dir.path_join("server-status.json"))


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) \
		if FileAccess.file_exists(path) else PackedByteArray()


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
	var stopped: bool = not OS.is_process_running(server_pid)
	_expect(stopped, "The authority process shuts down cleanly")
	if not stopped:
		OS.kill(server_pid)
	server_pid = 0
	var marker_path: String = world_dir.path_join("stop")
	if FileAccess.file_exists(marker_path):
		DirAccess.remove_absolute(marker_path)


func _wait(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _free_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0, "127.0.0.1") != OK:
		return 0
	var chosen: int = probe.get_local_port()
	probe.stop()
	return chosen


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("RESIDENT_PANEL_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
