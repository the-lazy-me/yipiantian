extends SceneTree
## M10-04 居民对话的真实网络测试：真实 `world_server.gd --residents` + loopback
## WSS，RPC 29/30，而不是纯规则或 `HeadlessWorld` 接缝。
##
## 覆盖：
##   - 具名成员 `say` 成功，关系/记忆/对话状态落盘，回复只带本人状态；
##   - 访客与匿名连接被拒绝（`forbidden` / `no_player`），不写状态；
##   - 超预算请求得到 `payload_too_large`，连发触发 `rate_limited`，连接继续可用；
##   - 重启后关系、记忆与对话状态保留，冷却继续拒绝；
##   - `state` 读取对成员开放，且不泄露另一名玩家的对话事实。
##
## 运行产物写在 `.local/verification/resident-dialogue-network-<ticks>/`。一次只开
## 一个 `WorldClient`，因为它总是创建 `/root/WorldSession`。

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")
const NpcDialogue = preload("res://npc/npc_dialogue.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const START: float = 1800084000.0
## 重启必须晚于已保存的对话时刻，且仍在 600 秒冷却内，才能断言冷却跨重启生效。
const RESTART_AT: float = START + 30.0
const WORLD: String = "world-resident-dialogue-network"
const PLAYER_A: String = "player_00000000000000000000000000000501"
const PLAYER_B: String = "player_00000000000000000000000000000502"
const VISITOR_ID: String = "player_00000000000000000000000000000503"
const NAME_A: String = "阿金"
const NAME_B: String = "阿木"
const VISITOR_NAME: String = "围观者"
const LIN: String = NpcRoster.NPC_LIN_SHEN
const OVER_BUDGET_BYTES: int = 50000
const RATE_REQUESTS: int = 26

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
var _dialogue_pending: Dictionary = {}
var state_before_stop: Dictionary = {}
var bytes_before_stop: PackedByteArray


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/resident-dialogue-network-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	if not await _start_authority(PLAYER_A, START):
		_finish()
		return
	var codes: Dictionary = _join_codes()
	_expect(not str(codes.get("member", "")).is_empty()
			and not str(codes.get("visitor", "")).is_empty(),
		"Member and visitor join codes are built from the operator's material")
	if str(codes.get("member", "")).is_empty() or str(codes.get("visitor", "")).is_empty():
		await _stop_server()
		_finish()
		return

	await _test_member(codes)
	await _close_client()
	await _test_visitor(codes)
	await _close_client()
	await _test_anonymous(codes)
	await _close_client()
	await _test_limits(codes)
	await _close_client()
	await _capture_before_stop(codes)
	await _close_client()

	bytes_before_stop = _bytes(_residents_path())
	_expect(not bytes_before_stop.is_empty(),
		"The dialogue sidecar exists before the restart")
	await _stop_server()
	if not await _start_authority(PLAYER_A, RESTART_AT):
		_finish()
		return
	await _test_restart(_join_codes())
	await _close_client()
	await _stop_server()
	_finish()


# ------------------------------------------------------------------ member

func _test_member(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The named member joins over WSS")
	if client == null or not client.joined:
		return
	var before: Dictionary = await _dialogue("dialogue-state-before", "state", {})
	_expect(bool(before.get("ok", false)), "The member may read the dialogue state")
	var before_row: Dictionary = _row(_state(before), LIN)
	_expect(int(before_row.get("affinity", -1)) == 0,
		"The fresh member starts with zero affinity towards the resident")
	_expect(int(before_row.get("daily_affinity", -1)) == 0,
		"The fresh member has no daily affinity yet")

	var reply: Dictionary = await _dialogue("dialogue-say-1", "say", {
		"npc_id": LIN, "category": NpcDialogue.CATEGORY_GREET,
		"command_id": "dialogue-net-greet-1",
	})
	_expect(bool(reply.get("ok", false)), "The member's greeting is accepted: "
		+ str(reply.get("reason", "")))
	_expect(NpcDialogue.valid_reply_kind(str(reply.get("reply_kind", ""))),
		"The reply names a fixed template")
	_expect(int(reply.get("affinity_delta", 0)) == 1,
		"The greeting grants the fixed +1")
	_expect(str(reply.get("viewer", "")) in ["", PLAYER_A],
		"The reply belongs to the member")
	_expect(not str(reply.get("memory_summary", "")).is_empty(),
		"The reply carries the fixed memory summary")
	var state: Dictionary = _state(reply)
	var row: Dictionary = _row(state, LIN)
	_expect(int(row.get("affinity", -1)) == 1,
		"The returned state shows the member's new affinity")
	_expect(float(row.get("last_dialogue_utc", 0.0)) > 0.0,
		"The returned state shows the dialogue time")
	_expect(int(row.get("daily_affinity", -1)) == 1,
		"The returned state shows the daily counter")

	# 冷却中的第二次对话被拒绝。
	var cooled: Dictionary = await _dialogue("dialogue-say-2", "say", {
		"npc_id": LIN, "category": NpcDialogue.CATEGORY_THANK,
		"command_id": "dialogue-net-thank-2",
	})
	_expect(not bool(cooled.get("ok", true))
			and str(cooled.get("reason", "")) == "cooldown",
		"A second dialogue inside the cooldown is refused")
	_expect(not str(cooled.get("reason_text", "")).is_empty(),
		"The cooldown refusal carries Chinese text")
	_expect(int(cooled.get("affinity_delta", -1)) == 0,
		"The refused dialogue reports no delta")
	var after: Dictionary = await _dialogue("dialogue-state-after", "state", {})
	var after_row: Dictionary = _row(_state(after), LIN)
	_expect(int(after_row.get("affinity", -1)) == 1,
		"The refused dialogue left the affinity unchanged")

	# 同一 command id 重放返回首次回复且标记 duplicate。
	var replay: Dictionary = await _dialogue("dialogue-say-replay", "say", {
		"npc_id": LIN, "category": NpcDialogue.CATEGORY_GREET,
		"command_id": "dialogue-net-greet-1",
	})
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"The same command id returns the first reply as a duplicate")
	_expect(_refusals.is_empty(), "The member dialogue causes no authority loss")


# ------------------------------------------------------------------ readers

func _test_visitor(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("visitor", "")), VISITOR_ID,
		VISITOR_NAME, PLAYER_SECRET_A), "A named visitor joins with the visitor code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")
	var read: Dictionary = await _dialogue("visitor-state", "state", {})
	_expect(bool(read.get("ok", false)), "A visitor may read the dialogue state")
	_expect((_state(read).get("residents", []) as Array).size() == NpcRoster.IDS.size(),
		"The visitor gets one row per resident")
	var write: Dictionary = await _dialogue("visitor-say", "say", {
		"npc_id": LIN, "category": NpcDialogue.CATEGORY_GREET,
		"command_id": "dialogue-net-visitor",
	})
	_expect(not bool(write.get("ok", true)),
		"A visitor's dialogue write is refused")
	_expect(str(write.get("reason", "")) == "forbidden",
		"The visitor refusal is named forbidden")
	_expect(not str(write.get("reason_text", "")).is_empty(),
		"The visitor refusal carries Chinese text")
	_expect(_refusals.is_empty(), "The visitor dialogue causes no authority loss")


func _test_anonymous(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), "", "", ""),
		"An anonymous connection joins")
	if client == null or not client.joined:
		return
	var write: Dictionary = await _dialogue("anonymous-say", "say", {
		"npc_id": LIN, "category": NpcDialogue.CATEGORY_GREET,
		"command_id": "dialogue-net-anonymous",
	})
	_expect(not bool(write.get("ok", true)),
		"An anonymous dialogue write is refused")
	_expect(str(write.get("reason", "")) == "no_player",
		"The anonymous refusal is named no_player")
	var read: Dictionary = await _dialogue("anonymous-state", "state", {})
	_expect(not bool(_state(read).get("available", true)),
		"An anonymous reader gets no dialogue state")
	_expect(_refusals.is_empty(),
		"The anonymous dialogue causes no authority loss")


func _test_limits(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The second member joins for budget and rate limits")
	if client == null or not client.joined:
		return
	# 第二名成员的视力应看到自己全零，而不是第一名的对话事实。
	var own: Dictionary = await _dialogue("limit-state-own", "state", {})
	var own_row: Dictionary = _row(_state(own), LIN)
	_expect(int(own_row.get("affinity", -1)) == 0,
		"The second member does not see the first member's affinity")
	_expect(float(own_row.get("last_dialogue_utc", -1.0)) == 0.0,
		"The second member does not see the first member's dialogue time")
	_expect(not JSON.stringify(_state(own)).contains(PLAYER_A),
		"The state never serializes the other player's id")

	var huge: String = JSON.stringify({
		"request_id": "dialogue-huge", "action": "state",
		"args": {"padding": "x".repeat(OVER_BUDGET_BYTES)},
	})
	_expect(huge.to_utf8_buffer().size() > 48 * 1024,
		"The oversized dialogue request really exceeds the wire budget")
	_dialogue_pending.erase("")
	client.member.dialogue_request.rpc_id(1, huge)
	var over_budget: Dictionary = await _dialogue_key("", 15000)
	_expect(str(over_budget.get("reason", "")) == "payload_too_large",
		"An over-budget dialogue request gets a named refusal")
	_expect(not str(over_budget.get("reason_text", "")).is_empty(),
		"The over-budget refusal carries Chinese text")
	var alive: Dictionary = await _dialogue("dialogue-after-huge", "state", {})
	_expect(bool(alive.get("ok", false)),
		"The connection keeps working after the over-budget refusal")

	# 冷却中的同一个居民会很快消耗命令桶；用 state 连发触发限流。
	for index: int in RATE_REQUESTS:
		var request_id: String = "dialogue-rate-%d" % index
		_dialogue_pending.erase(request_id)
		client.member.dialogue_request.rpc_id(1, JSON.stringify({
			"request_id": request_id, "action": "state", "args": {},
		}))
	var limited: bool = await _wait(func() -> bool:
		return _has_reason("rate_limited"), 15000)
	_expect(limited, "A rapid burst triggers a rate_limited refusal")
	await create_timer(1.5).timeout
	var recovered: Dictionary = await _dialogue("dialogue-after-rate", "state", {})
	_expect(bool(recovered.get("ok", false)),
		"The connection keeps working after the rate limit")
	_expect(_refusals.is_empty(),
		"Budget and rate refusals do not drop the authority connection")


# ----------------------------------------------------------------- restart

func _capture_before_stop(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The member rejoins to capture the persisted state")
	if client == null or not client.joined:
		return
	state_before_stop = _state(await _dialogue("dialogue-before-stop", "state", {}))
	_expect(bool(state_before_stop.get("available", false)),
		"The dialogue state is available before the restart")
	_expect(int(_row(state_before_stop, LIN).get("affinity", -1)) == 1,
		"The captured state carries the accepted dialogue's affinity")


func _test_restart(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The member rejoins the restarted authority")
	if client == null or not client.joined:
		return
	var state: Dictionary = _state(await _dialogue("dialogue-restart", "state", {}))
	_expect(bool(state.get("available", false)),
		"The restarted authority keeps residents enabled")
	var row: Dictionary = _row(state, LIN)
	_expect(int(row.get("affinity", -1)) == 1,
		"The affinity survives the restart")
	_expect(float(row.get("last_dialogue_utc", 0.0))
			== float(_row(state_before_stop, LIN).get("last_dialogue_utc", 0.0)),
		"The dialogue time survives the restart")
	_expect(int(row.get("daily_affinity", -1)) == 1,
		"The daily counter survives the restart")
	var cooled: Dictionary = await _dialogue("dialogue-restart-say", "say", {
		"npc_id": LIN, "category": NpcDialogue.CATEGORY_GREET,
		"command_id": "dialogue-net-after-restart",
	})
	_expect(not bool(cooled.get("ok", true))
			and str(cooled.get("reason", "")) == "cooldown",
		"The persisted cooldown still refuses a new dialogue after the restart")
	_expect(_bytes(_residents_path()) == bytes_before_stop,
		"The restart loads residents.json without rewriting it")
	_expect(_refusals.is_empty(), "The restart dialogue causes no authority loss")


# ------------------------------------------------------------------ helpers

func _state(reply: Dictionary) -> Dictionary:
	var value: Variant = reply.get("state")
	return value if value is Dictionary else {}


func _row(state: Dictionary, npc_id: String) -> Dictionary:
	for row_value: Variant in state.get("residents", []):
		if row_value is Dictionary \
				and str((row_value as Dictionary).get("id", "")) == npc_id:
			return row_value
	return {}


func _dialogue(request_id: String, action: String,
		args: Dictionary = {}) -> Dictionary:
	_dialogue_pending.erase(request_id)
	if client == null or not client.request_dialogue(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	return await _dialogue_key(request_id, 15000)


func _dialogue_key(request_id: String, timeout_ms: int) -> Dictionary:
	var arrived: bool = await _wait(func() -> bool:
		return _dialogue_pending.has(request_id), timeout_ms)
	if not arrived:
		_expect(false, "A dialogue reply arrives for request %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _dialogue_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


func _has_reason(reason: String) -> bool:
	for payload_value: Variant in _dialogue_pending.values():
		if payload_value is Dictionary \
				and str((payload_value as Dictionary).get("reason", "")) == reason:
			return true
	return false


func _open_client(code: String, player_id: String, display_name: String,
		secret_text: String) -> bool:
	_ready = false
	_refusals.clear()
	_dialogue_pending.clear()
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
			_now: float) -> void:
		_ready = true)
	client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
	client.lost.connect(func(reason: String) -> void: _refusals.append(reason))
	client.dialogue_result.connect(_on_dialogue_result)
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
	_dialogue_pending.clear()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout


func _on_dialogue_result(request_id: String, payload: Dictionary) -> void:
	_dialogue_pending[request_id] = payload


# ------------------------------------------------------------------- server

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
	if OS.get_name() != "Windows":
		var ready: Dictionary = _server_line("server.log", "WORLD_SERVER_READY ")
		_expect(str(ready.get("state", "")) == "running",
			"The ready line reports the running state")
		_expect(bool(ready.get("residents", false)),
			"The ready line records the residents flag")
	return true


func _spawn_server(host_player: String, now: float, log_name: String) -> int:
	var arguments := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % now, "--run-seconds=0", "--join-url=" + url,
		"--host-player=" + host_player, "--residents",
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
	var visitor_code: String = FileAccess.get_file_as_string(
		world_dir.path_join("visitor-join-code.txt")).strip_edges()
	return {"member": member_code, "visitor": visitor_code}


func _residents_path() -> String:
	return world_dir.path_join("residents.json")


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
	print("RESIDENT_DIALOGUE_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
