extends SceneTree
## M11-03 规则决议真实网络测试：真实 `world_server.gd` + loopback WSS，RPC 27/28，
## 而不是纯规则或 HeadlessWorld 接缝。
##
## 房主 A 以 `--host-player` 启动并成为具名成员。成员 B 通过
## `WorldClient.request_resolutions()` 提案；匿名成员可以只读但不能写；超预算请求
## 得到 `payload_too_large` 且连接继续工作；重启后规则版本、决议文档与命令日志
## 保留，同一 command id 仍返回 duplicate 且文件字节不变。
##
## 两个具名成员使用不同的安装凭据（ADR-029），一次只开一个 `WorldClient`，因为它
## 总是创建 `/root/WorldSession`。所有运行产物在
## `.local/verification/resolution-network-<ticks>/`。

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const Resolution = preload("res://world/resolution_state.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const START: float = 1800000000.0
const WORLD: String = "world-resolution-network"
const PLAYER_A: String = "player_00000000000000000000000000000071"
const PLAYER_B: String = "player_00000000000000000000000000000072"
const NAME_A: String = "阿金"
const NAME_B: String = "阿木"
const RESOLUTION_ID: String = "res_net_bridge"
const PROPOSE_ID: String = "resolution-net-propose"
const OVER_BUDGET_BYTES: int = 50000

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var url: String = ""
var checks: int = 0
var failures: Array[String] = []
var client: WorldClient
var _ready: bool = false
var _refusals: Array[String] = []
var _resolution_pending: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/resolution-network-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	if not await _start_authority(PLAYER_A, START):
		_finish()
		return
	var codes: Dictionary = _join_codes()
	if str(codes.get("member", "")).is_empty() or str(codes.get("visitor", "")).is_empty():
		_expect(false, "Member and visitor join codes are built")
		await _stop_server()
		_finish()
		return

	await _test_member_proposes(codes)
	await _close_client()
	await _test_anonymous_read_only(codes)
	await _close_client()

	var bytes_before_stop: PackedByteArray = _bytes(_resolutions_path())
	_expect(not bytes_before_stop.is_empty(),
		"The proposed resolution is persisted before the restart")
	await _stop_server()
	if not await _start_authority(PLAYER_A, START + 3600.0):
		_finish()
		return
	await _test_restart(_join_codes(), bytes_before_stop)
	await _close_client()
	await _stop_server()
	_finish()


# --------------------------------------------------------------- member writes

func _test_member_proposes(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The proposing member joins over WSS")
	if client == null or not client.joined:
		return
	var fresh: Dictionary = await _resolution("resolution-net-state-fresh", "state")
	_expect(bool(fresh.get("ok", false)),
		"The authority answers a resolution state request")
	var view: Dictionary = _state(fresh)
	for key: String in ["available", "now_utc", "viewer", "is_member",
			"rules_version", "versions", "effects", "resolutions"]:
		_expect(view.has(key), "The resolution view carries %s" % key)
	_expect(int(view.get("rules_version", -1)) == 0
			and (view.get("resolutions", []) as Array).is_empty(),
		"A fresh room has no resolutions and rules version 0")

	var now: float = client.world_time()
	var proposed: Dictionary = await _resolution(PROPOSE_ID, "propose", {
		"resolution_id": RESOLUTION_ID,
		"proposal": {
			"kind": Resolution.KIND_PUBLIC_WORKS,
			"title": "修桥",
			"vote_start_utc": now + 60.0,
			"vote_end_utc": now + 3660.0,
			"effective_utc": now + 7260.0,
		},
		"command_id": PROPOSE_ID,
	})
	_expect(bool(proposed.get("ok", false))
			and str(proposed.get("status", "")) == Resolution.STATUS_PROPOSED,
		"A member files a resolution over channel 27 (reason=%s)"
			% str(proposed.get("reason", "")))
	_expect(str(proposed.get("resolution_id", "")) == RESOLUTION_ID,
		"The reply names the resolution")
	var proposed_row: Dictionary = _row(_state(proposed), RESOLUTION_ID)
	_expect(str(proposed_row.get("proposed_by", "")) == PLAYER_B,
		"The connection identity becomes the proposer, not a payload field")
	_expect(int(proposed_row.get("approvals", -1)) == 0
			and (proposed_row.get("approvers", []) as Array).is_empty()
			and int(proposed_row.get("rejections", -1)) == 0,
		"A proposer sees zero counts and, as a related viewer, empty voter identities")

	var stored: Dictionary = _document(_resolutions_path())
	_expect(int(stored.get("version", -1)) == 1
			and str(stored.get("world_id", "")) == WORLD,
		"resolutions.json carries version 1 and the world identity")
	_expect(stored.get("commands", []) is Array
			and not (stored.get("commands", []) as Array).is_empty(),
		"resolutions.json persists the replay journal")

	var bytes_before: PackedByteArray = _bytes(_resolutions_path())
	var replay: Dictionary = await _resolution(PROPOSE_ID, "propose", {
		"resolution_id": RESOLUTION_ID,
		"proposal": {
			"kind": Resolution.KIND_PUBLIC_WORKS,
			"title": "修桥",
			"vote_start_utc": now + 60.0,
			"vote_end_utc": now + 3660.0,
			"effective_utc": now + 7260.0,
		},
		"command_id": PROPOSE_ID,
	})
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the propose request id returns duplicate")
	_expect(_bytes(_resolutions_path()) == bytes_before,
		"A propose replay leaves resolutions.json byte-identical")

	var unknown: Dictionary = await _resolution("resolution-net-unknown", "dissolve", {
		"resolution_id": RESOLUTION_ID, "command_id": "resolution-net-unknown",
	})
	_expect(str(unknown.get("reason", "")) == "unknown_action",
		"An unknown resolution action is refused over the wire")
	_expect(not str(unknown.get("reason_text", "")).is_empty(),
		"The unknown-action refusal carries human-readable text")

	# The raw request-side budget is answered, not silently dropped.
	_resolution_pending.erase("")
	var huge: String = JSON.stringify({
		"request_id": "resolution-net-huge", "action": "state",
		"args": {"padding": "x".repeat(OVER_BUDGET_BYTES)},
	})
	_expect(huge.to_utf8_buffer().size() > 48 * 1024,
		"The oversized resolution request really exceeds the wire budget")
	client.member.resolutions_request.rpc_id(1, huge)
	var over_budget: Dictionary = await _resolution_key("", 15000)
	_expect(str(over_budget.get("reason", "")) == "payload_too_large",
		"An over-budget resolution request gets a named refusal")
	var alive: Dictionary = await _resolution("resolution-net-state-after-huge", "state")
	_expect(bool(alive.get("ok", false))
			and str(_row(_state(alive), RESOLUTION_ID).get("status", ""))
				== Resolution.STATUS_PROPOSED,
		"The connection keeps working after the over-budget refusal")


# -------------------------------------------------------------- anonymous read

func _test_anonymous_read_only(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), "", "", ""),
		"An anonymous connection joins")
	if client == null or not client.joined:
		return
	var view: Dictionary = _state(await _resolution("anonymous-state-1", "state"))
	_expect(int(view.get("rules_version", -1)) == 0
			and not _row(view, RESOLUTION_ID).is_empty(),
		"An anonymous member can read the resolution list")
	var refused: Dictionary = await _resolution("anonymous-propose", "propose", {
		"resolution_id": "res_anon",
		"proposal": {
			"kind": Resolution.KIND_PUBLIC_WORKS, "title": "匿名提案",
			"vote_start_utc": client.world_time() + 60.0,
			"vote_end_utc": client.world_time() + 3660.0,
			"effective_utc": client.world_time() + 7260.0,
		},
		"command_id": "anonymous-propose",
	})
	_expect(str(refused.get("reason", "")) == "no_player",
		"An anonymous resolution write is refused for lack of a player identity")
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The anonymous refusal carries human-readable text")
	var after: Dictionary = await _resolution("anonymous-state-2", "state")
	_expect(bool(after.get("ok", false))
			and str(_row(_state(after), RESOLUTION_ID).get("status", ""))
				== Resolution.STATUS_PROPOSED,
		"The anonymous member can still read and the attempted write changed nothing")


# --------------------------------------------------------------------- restart

func _test_restart(codes: Dictionary, bytes_before_stop: PackedByteArray) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The proposing member rejoins the restarted authority")
	if client == null or not client.joined:
		return
	_expect(_bytes(_resolutions_path()) == bytes_before_stop,
		"The restart loads resolutions.json without rewriting it")
	var state_reply: Dictionary = await _resolution("restart-state-1", "state")
	_expect(bool(state_reply.get("ok", false)),
		"The restarted authority answers a state request")
	var row: Dictionary = _row(_state(state_reply), RESOLUTION_ID)
	_expect(str(row.get("status", "")) == Resolution.STATUS_PROPOSED
			and str(row.get("proposed_by", "")) == PLAYER_B,
		"The proposed resolution survives the restart")
	var replay: Dictionary = await _resolution(PROPOSE_ID, "propose", {
		"resolution_id": RESOLUTION_ID,
		"proposal": {
			"kind": Resolution.KIND_PUBLIC_WORKS, "title": "修桥",
			"vote_start_utc": float(row.get("vote_start_utc", 0.0)),
			"vote_end_utc": float(row.get("vote_end_utc", 0.0)),
			"effective_utc": float(row.get("effective_utc", 0.0)),
		},
		"command_id": PROPOSE_ID,
	})
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"The propose request id still replays after the restart (reason=%s)"
			% str(replay.get("reason", "")))
	_expect(_bytes(_resolutions_path()) == bytes_before_stop,
		"A post-restart replay leaves resolutions.json byte-identical")


# ------------------------------------------------------------------- authority

func _start_authority(host_player: String, now: float) -> bool:
	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if port <= 0:
		return false
	url = "wss://127.0.0.1:%d" % port
	server_pid = _spawn_server(host_player, now, "server.log")
	_expect(server_pid > 0, "The authority process starts")
	if server_pid <= 0:
		return false
	var running: bool = await _wait(func() -> bool:
		var status: Dictionary = _status()
		return str(status.get("state", "")) == "running" \
			and int(status.get("pid", 0)) == server_pid, 20000)
	_expect(running, "The authority reports ready")
	if not running:
		return false
	var status: Dictionary = _status()
	_expect(str(status.get("host_player", "")) == host_player,
		"The status file records the host player")
	return true


func _spawn_server(host_player: String, now: float, log_name: String) -> int:
	var arguments := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % now, "--run-seconds=0", "--join-url=" + url,
		"--host-player=" + host_player,
	])
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


func _join_codes() -> Dictionary:
	var invite_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		world_dir.path_join("invite.bin"))
	var pem: String = FileAccess.get_file_as_bytes(
		world_dir.path_join("server.crt")).get_string_from_ascii()
	var member_code: String = WorldJoinCode.encode(WorldInvite.make(
		"server-invite", invite_bytes, WorldInvite.MEMBER, WORLD, 0.0, false),
		url, pem, "localhost")
	var visitor_code: String = FileAccess.get_file_as_string(
		world_dir.path_join("visitor-join-code.txt")).strip_edges()
	return {"member": member_code, "visitor": visitor_code}


func _open_client(code: String, player_id: String, display_name: String,
		secret_text: String) -> bool:
	_ready = false
	_refusals.clear()
	_resolution_pending.clear()
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
			_now: float) -> void:
		_ready = true)
	client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
	client.lost.connect(func(reason: String) -> void: _refusals.append(reason))
	client.resolutions_result.connect(_on_resolution_result)
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
	_resolution_pending.clear()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout


func _on_resolution_result(request_id: String, payload: Dictionary) -> void:
	_resolution_pending[request_id] = payload


func _resolution(request_id: String, action: String,
		args: Dictionary = {}) -> Dictionary:
	_resolution_pending.erase(request_id)
	if client == null or not client.request_resolutions(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	return await _resolution_key(request_id, 15000)


func _resolution_key(request_id: String, timeout_ms: int) -> Dictionary:
	var arrived: bool = await _wait(func() -> bool:
		return _resolution_pending.has(request_id), timeout_ms)
	if not arrived:
		_expect(false, "A resolution reply arrives for request %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _resolution_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


# ------------------------------------------------------------------- fixtures

func _state(reply: Dictionary) -> Dictionary:
	var value: Variant = reply.get("state")
	return value if value is Dictionary else {}


func _row(view: Dictionary, resolution_id: String) -> Dictionary:
	var rows: Variant = view.get("resolutions")
	if rows is Array:
		for row_value: Variant in rows:
			if row_value is Dictionary \
					and str((row_value as Dictionary).get("resolution_id", "")) \
						== resolution_id:
				return row_value
	return {}


func _resolutions_path() -> String:
	return world_dir.path_join("resolutions.json")


func _document(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _status() -> Dictionary:
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
	_expect(str(_status().get("state", "")) == "stopped",
		"The shutdown is recorded in the status file")
	if not stopped:
		OS.kill(server_pid)
	server_pid = 0


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
	print("RESOLUTION_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
