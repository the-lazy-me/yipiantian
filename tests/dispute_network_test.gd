extends SceneTree
## M12-04 执法闭环真实网络测试：真实 `world_server.gd` + loopback WSS，RPC
## 23/24，而不是纯规则或 HeadlessWorld 接缝。
##
## 房主 A 以 `--host-player` 启动并成为文档花名册里的唯一权威。成员 B 通过
## `WorldClient.request_dispute()` 立案、提交证据、申诉；B 的受理/裁定请求被
## 拒绝为 forbidden；A 受理、裁定、更正并结案；访客可以读但不能写；匿名连接
## 可以读但没有玩家身份；超预算请求得到 payload_too_large 且连接继续工作；
## 重启后案件、裁定与审计保留，同一 command id 仍返回 duplicate 且文档字节
## 不变。所有运行产物在 .local/verification/dispute-network-<ticks>/。
##
## 两个具名成员使用不同的安装凭据（ADR-029），一次只开一个 `WorldClient`，
## 因为它总是创建 `/root/WorldSession`。

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const Disputes = preload("res://world/dispute_state.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const START: float = 1800000000.0
const WORLD: String = "world-dispute-network"
const PLAYER_A: String = "player_00000000000000000000000000000081"
const PLAYER_B: String = "player_00000000000000000000000000000082"
const PLAYER_C: String = "player_00000000000000000000000000000083"
const VISITOR_ID: String = "player_00000000000000000000000000000084"
const NAME_A: String = "阿金"
const NAME_B: String = "阿木"
const VISITOR_NAME: String = "围观者"
const CASE_ID: String = "case_net_1"
const EVENT_ID: String = "event_net_alpha"
const FILE_ID: String = "dispute-net-file"
const EVIDENCE_ID: String = "dispute-net-evidence"
const ACCEPT_ID: String = "dispute-net-accept"
const RULE_ID: String = "dispute-net-rule"
const APPEAL_ID: String = "dispute-net-appeal"
const CORRECT_ID: String = "dispute-net-correct"
const CLOSE_ID: String = "dispute-net-close"
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
var _dispute_pending: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/dispute-network-%d" % Time.get_ticks_usec())
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

	await _test_member_files(codes)
	await _close_client()
	await _test_admin_accepts_and_rules(codes)
	await _close_client()
	await _test_member_appeals(codes)
	await _close_client()
	await _test_admin_corrects_and_closes(codes)
	await _close_client()
	await _test_visitor(codes)
	await _close_client()
	await _test_anonymous(codes)
	await _close_client()

	var bytes_before_stop: PackedByteArray = _bytes(_disputes_path())
	_expect(not bytes_before_stop.is_empty(),
		"The completed case is persisted before the restart")
	await _stop_server()
	if not await _start_authority(PLAYER_A, START + 3600.0):
		_finish()
		return
	var restart_codes: Dictionary = _join_codes()
	await _test_restart(restart_codes, bytes_before_stop)
	await _close_client()
	await _stop_server()
	_finish()


# --------------------------------------------------------------- member files

func _test_member_files(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The filing member joins over WSS")
	if client == null or not client.joined:
		return
	var view: Dictionary = await _dispute("dispute-net-state-fresh", "state")
	_expect(bool(view.get("ok", false)), "The authority answers a dispute state request")
	var fresh: Dictionary = _state(view)
	for key: String in ["available", "now_utc", "viewer", "is_authority",
			"authority_roles", "cases", "public"]:
		_expect(fresh.has(key), "The dispute view carries %s" % key)
	_expect(bool(fresh.get("available", false)),
		"A hosted room has a dispute authority")
	_expect(not bool(fresh.get("is_authority", true)),
		"An ordinary member is not the dispute authority")
	_expect((fresh.get("cases", []) as Array).is_empty()
			and (fresh.get("public", []) as Array).is_empty(),
		"A fresh room has no cases")

	var filed: Dictionary = await _dispute(FILE_ID, "file", {
		"case_id": CASE_ID, "against": PLAYER_C, "event_ids": [EVENT_ID],
		"command_id": FILE_ID,
	})
	_expect(bool(filed.get("ok", false))
			and str(filed.get("status", "")) == Disputes.STATUS_FILED,
		"An ordinary member files a case over channel 23 (reason=%s)"
			% str(filed.get("reason", "")))
	_expect(str(filed.get("case_id", "")) == CASE_ID,
		"The filing reply names the case")
	var stored: Dictionary = _disputes_doc()
	_expect(int(stored.get("version", -1)) == 1
			and str(stored.get("world_id", "")) == WORLD,
		"disputes.json carries version 1 and the world identity")
	var commands: Variant = stored.get("commands", [])
	_expect(commands is Array and not (commands as Array).is_empty(),
		"disputes.json persists the replay journal")

	var bytes_before: PackedByteArray = _bytes(_disputes_path())
	var replay: Dictionary = await _dispute(FILE_ID, "file", {
		"case_id": CASE_ID, "against": PLAYER_C, "event_ids": [EVENT_ID],
		"command_id": FILE_ID,
	})
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the filing request id returns duplicate")
	_expect(_bytes(_disputes_path()) == bytes_before,
		"A filing replay leaves disputes.json byte-identical")
	var conflict: Dictionary = await _dispute(FILE_ID, "file", {
		"case_id": CASE_ID, "against": PLAYER_A, "event_ids": [EVENT_ID],
		"command_id": FILE_ID,
	})
	_expect(str(conflict.get("reason", "")) == "command_conflict",
		"A different filing under the same request id conflicts")
	_expect(_bytes(_disputes_path()) == bytes_before,
		"A filing conflict leaves disputes.json byte-identical")

	var evidence: Dictionary = await _dispute(EVIDENCE_ID, "evidence", {
		"case_id": CASE_ID, "evidence_id": "ev_net_1",
		"kind": Disputes.EVIDENCE_AUTHORITY_EVENT, "source": EVENT_ID,
		"command_id": EVIDENCE_ID,
	})
	_expect(bool(evidence.get("ok", false)),
		"A party submits evidence over channel 23")
	var evidence_replay: Dictionary = await _dispute(EVIDENCE_ID, "evidence", {
		"case_id": CASE_ID, "evidence_id": "ev_net_1",
		"kind": Disputes.EVIDENCE_AUTHORITY_EVENT, "source": EVENT_ID,
		"command_id": EVIDENCE_ID,
	})
	_expect(bool(evidence_replay.get("ok", false))
			and bool(evidence_replay.get("duplicate", false)),
		"Replaying the evidence request id returns duplicate")

	var refused_accept: Dictionary = await _dispute("dispute-net-member-accept",
		"accept", {"case_id": CASE_ID, "command_id": "dispute-net-member-accept"})
	_expect(str(refused_accept.get("reason", "")) == "forbidden",
		"A non-admin accept is refused as forbidden")
	_expect(not str(refused_accept.get("reason_text", "")).is_empty(),
		"The forbidden accept carries a human-readable reason")
	var refused_rule: Dictionary = await _dispute("dispute-net-member-rule", "rule", {
		"case_id": CASE_ID,
		"decision": {"advisor": false, "authority": true,
			"outcome": "upheld", "reason": "越权裁定"},
		"command_id": "dispute-net-member-rule",
	})
	_expect(str(refused_rule.get("reason", "")) == "forbidden",
		"A non-admin ruling is refused as forbidden")
	var member_view: Dictionary = _state(await _dispute(
		"dispute-net-member-state", "state"))
	_expect(_case_row(member_view, CASE_ID).size() > 0,
		"The filing member sees the related case")
	_expect(str(_case_row(member_view, CASE_ID).get("status", ""))
			== Disputes.STATUS_FILED,
		"Refused authority writes leave the case filed")


# ------------------------------------------------------------ admin decision

func _test_admin_accepts_and_rules(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host administrator joins over WSS")
	if client == null or not client.joined:
		return
	var view: Dictionary = _state(await _dispute("dispute-net-admin-state", "state"))
	var authority_view: Dictionary = _state(await _dispute(
		"dispute-net-admin-state-2", "state"))
	_expect(bool(authority_view.get("is_authority", false)),
		"The host sees itself as the dispute authority")
	_expect(_case_row(view, CASE_ID).size() > 0,
		"The administrator sees every case")
	_expect((_case_row(view, CASE_ID).get("evidence", []) as Array).size() == 1,
		"The administrator sees the submitted evidence")

	var accepted: Dictionary = await _dispute(ACCEPT_ID, "accept", {
		"case_id": CASE_ID, "command_id": ACCEPT_ID,
	})
	_expect(bool(accepted.get("ok", false))
			and str(accepted.get("status", "")) == Disputes.STATUS_ACCEPTED,
		"The administrator accepts the case over channel 23")
	var bytes_after_accept: PackedByteArray = _bytes(_disputes_path())
	var accept_replay: Dictionary = await _dispute(ACCEPT_ID, "accept", {
		"case_id": CASE_ID, "command_id": ACCEPT_ID,
	})
	_expect(bool(accept_replay.get("ok", false))
			and bool(accept_replay.get("duplicate", false)),
		"Replaying the accept request id returns duplicate")
	_expect(_bytes(_disputes_path()) == bytes_after_accept,
		"An accept replay leaves disputes.json byte-identical")

	var ruled: Dictionary = await _dispute(RULE_ID, "rule", {
		"case_id": CASE_ID,
		"decision": {"advisor": false, "authority": true,
			"outcome": "upheld", "reason": "证据成立"},
		"command_id": RULE_ID,
	})
	_expect(bool(ruled.get("ok", false))
			and str(ruled.get("status", "")) == Disputes.STATUS_RULED,
		"The administrator rules the case")
	var ruled_view: Dictionary = _state(await _dispute(
		"dispute-net-ruled-state", "state"))
	var row: Dictionary = _case_row(ruled_view, CASE_ID)
	_expect(str((row.get("ruling") as Dictionary).get("outcome", "")) == "upheld"
			and str((row.get("ruling") as Dictionary).get("by", "")) == PLAYER_A,
		"The ruling is visible with its author and outcome")
	var rule_replay: Dictionary = await _dispute(RULE_ID, "rule", {
		"case_id": CASE_ID,
		"decision": {"advisor": false, "authority": true,
			"outcome": "upheld", "reason": "证据成立"},
		"command_id": RULE_ID,
	})
	_expect(bool(rule_replay.get("ok", false))
			and bool(rule_replay.get("duplicate", false)),
		"Replaying the ruling request id returns duplicate")


# ---------------------------------------------------------------- appeal path

func _test_member_appeals(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The filing member rejoins to appeal")
	if client == null or not client.joined:
		return
	var before: Dictionary = _state(await _dispute("dispute-net-appeal-state-1", "state"))
	var ruling_value: Variant = _case_row(before, CASE_ID).get("ruling")
	var ruling_before: Dictionary = (ruling_value as Dictionary).duplicate(true)
	var appeal: Dictionary = await _dispute(APPEAL_ID, "appeal", {
		"case_id": CASE_ID, "reason": "不服裁定", "command_id": APPEAL_ID,
	})
	_expect(bool(appeal.get("ok", false))
			and str(appeal.get("status", "")) == Disputes.STATUS_APPEALED,
		"The filing member appeals the ruling over channel 23")
	var after: Dictionary = _state(await _dispute("dispute-net-appeal-state-2", "state"))
	_expect((_case_row(after, CASE_ID).get("ruling") as Dictionary) == ruling_before,
		"An appeal preserves the original ruling")
	var bytes_after_appeal: PackedByteArray = _bytes(_disputes_path())
	var appeal_replay: Dictionary = await _dispute(APPEAL_ID, "appeal", {
		"case_id": CASE_ID, "reason": "不服裁定", "command_id": APPEAL_ID,
	})
	_expect(bool(appeal_replay.get("ok", false))
			and bool(appeal_replay.get("duplicate", false)),
		"Replaying the appeal request id returns duplicate")
	_expect(_bytes(_disputes_path()) == bytes_after_appeal,
		"An appeal replay leaves disputes.json byte-identical")


# ------------------------------------------------------ correction and close

func _test_admin_corrects_and_closes(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The administrator rejoins to correct and close")
	if client == null or not client.joined:
		return
	var before: Dictionary = _state(await _dispute("dispute-net-correct-state-1", "state"))
	var ruling_value: Variant = _case_row(before, CASE_ID).get("ruling")
	var ruling_before: Dictionary = (ruling_value as Dictionary).duplicate(true)
	var corrected: Dictionary = await _dispute(CORRECT_ID, "correct", {
		"case_id": CASE_ID, "reason": "补充证据后更正", "command_id": CORRECT_ID,
	})
	_expect(bool(corrected.get("ok", false))
			and str(corrected.get("status", "")) == Disputes.STATUS_CORRECTED,
		"The administrator corrects the appealed case")
	var closed: Dictionary = await _dispute(CLOSE_ID, "close", {
		"case_id": CASE_ID, "command_id": CLOSE_ID,
	})
	_expect(bool(closed.get("ok", false))
			and str(closed.get("status", "")) == Disputes.STATUS_CLOSED,
		"The administrator closes the corrected case")
	var after: Dictionary = _state(await _dispute("dispute-net-closed-state", "state"))
	var row: Dictionary = _case_row(after, CASE_ID)
	_expect((row.get("ruling") as Dictionary) == ruling_before,
		"Correction and closing preserve the original ruling")
	_expect(_audit_actions(row) == ["accept", "rule", "correct", "close"],
		"The audit trail records every administrator action")
	_expect((row.get("appeals", []) as Array).size() == 1
			and (row.get("corrections", []) as Array).size() == 1,
		"Closing keeps the appeal and correction history")

	# The raw request-side budget is answered, not silently dropped.
	_dispute_pending.erase("")
	var huge: String = JSON.stringify({
		"request_id": "dispute-net-huge", "action": "state",
		"args": {"padding": "x".repeat(OVER_BUDGET_BYTES)},
	})
	_expect(huge.to_utf8_buffer().size() > 48 * 1024,
		"The oversized dispute request really exceeds the wire budget")
	client.member.dispute_request.rpc_id(1, huge)
	var over_budget: Dictionary = await _dispute_key("", 15000)
	_expect(str(over_budget.get("reason", "")) == "payload_too_large",
		"An over-budget dispute request gets a named refusal")
	var alive: Dictionary = await _dispute("dispute-net-state-after-huge", "state")
	_expect(bool(alive.get("ok", false))
			and str(_case_row(_state(alive), CASE_ID).get("status", ""))
				== Disputes.STATUS_CLOSED,
		"The connection keeps working after the over-budget refusal")


# ----------------------------------------------------------- permission paths

func _test_visitor(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("visitor", "")), VISITOR_ID, VISITOR_NAME,
		PLAYER_SECRET_A), "A named visitor joins with the visitor code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")
	var view: Dictionary = _state(await _dispute("visitor-state-1", "state"))
	_expect(bool(_state(await _dispute("visitor-state-2", "state")).get("available", false)),
		"A visitor may read the dispute view")
	_expect((view.get("public", []) as Array).size() == 1,
		"The visitor sees the public status row")
	_expect((view.get("cases", []) as Array).is_empty(),
		"The visitor sees no case details")
	var refused: Dictionary = await _dispute("visitor-file-1", "file", {
		"case_id": "case_visitor", "against": PLAYER_C,
		"event_ids": [EVENT_ID], "command_id": "visitor-file-1",
	})
	_expect(str(refused.get("reason", "")) == "forbidden",
		"A visitor's dispute write is refused as forbidden")
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The visitor refusal carries a human-readable reason")
	var after: Dictionary = await _dispute("visitor-state-3", "state")
	_expect(bool(after.get("ok", false)), "The visitor can still read after a refusal")


func _test_anonymous(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), "", "", ""),
		"An anonymous connection joins")
	if client == null or not client.joined:
		return
	var view: Dictionary = _state(await _dispute("anonymous-state-1", "state"))
	_expect((view.get("public", []) as Array).size() == 1,
		"An anonymous member sees the public status row")
	_expect((view.get("cases", []) as Array).is_empty(),
		"The anonymous member sees no case details")
	var refused: Dictionary = await _dispute("anonymous-file-1", "file", {
		"case_id": "case_anonymous", "against": PLAYER_C,
		"event_ids": [EVENT_ID], "command_id": "anonymous-file-1",
	})
	_expect(str(refused.get("reason", "")) == "no_player",
		"An anonymous dispute write is refused for lack of a player identity")
	var after: Dictionary = await _dispute("anonymous-state-2", "state")
	_expect(bool(after.get("ok", false)),
		"The anonymous member can still read after a refusal")


# --------------------------------------------------------------------- restart

func _test_restart(codes: Dictionary, bytes_before_stop: PackedByteArray) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The filing member rejoins the restarted authority")
	if client == null or not client.joined:
		return
	_expect(_bytes(_disputes_path()) == bytes_before_stop,
		"The restart loads disputes.json without rewriting it")
	var state_reply: Dictionary = await _dispute("restart-state-1", "state")
	_expect(bool(state_reply.get("ok", false)),
		"The restarted authority answers a state request")
	var view: Dictionary = _state(state_reply)
	var row: Dictionary = _case_row(view, CASE_ID)
	_expect(str(row.get("status", "")) == Disputes.STATUS_CLOSED,
		"The closed case survives the restart")
	_expect(_audit_actions(row) == ["accept", "rule", "correct", "close"],
		"The full audit trail survives the restart")
	_expect(str((row.get("ruling") as Dictionary).get("outcome", "")) == "upheld",
		"The original ruling survives the restart")

	var file_replay: Dictionary = await _dispute(FILE_ID, "file", {
		"case_id": CASE_ID, "against": PLAYER_C, "event_ids": [EVENT_ID],
		"command_id": FILE_ID,
	})
	_expect(bool(file_replay.get("ok", false))
			and bool(file_replay.get("duplicate", false)),
		"The filing request id still replays after the restart (reason=%s)"
			% str(file_replay.get("reason", "")))
	_expect(_bytes(_disputes_path()) == bytes_before_stop,
		"A member replay leaves disputes.json byte-identical")

	await _close_client()
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The administrator rejoins the restarted authority")
	if client == null or not client.joined:
		return
	var close_replay: Dictionary = await _dispute(CLOSE_ID, "close", {
		"case_id": CASE_ID, "command_id": CLOSE_ID,
	})
	_expect(bool(close_replay.get("ok", false))
			and bool(close_replay.get("duplicate", false)),
		"The administrator's close request id still replays after the restart")
	var accept_replay: Dictionary = await _dispute(ACCEPT_ID, "accept", {
		"case_id": CASE_ID, "command_id": ACCEPT_ID,
	})
	_expect(bool(accept_replay.get("ok", false))
			and bool(accept_replay.get("duplicate", false)),
		"The administrator's accept request id still replays after the restart")
	_expect(_bytes(_disputes_path()) == bytes_before_stop,
		"Restart replays leave disputes.json byte-identical")


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
	if OS.get_name() != "Windows":
		var ready: Dictionary = _server_line("server.log", "WORLD_SERVER_READY ")
		_expect(str(ready.get("state", "")) == "running",
			"The ready line reports the running state")
		_expect(str(ready.get("host_player", "")) == host_player,
			"The ready line records the host player")
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


func _open_client(code: String, player_id: String, display_name: String,
		secret_text: String) -> bool:
	_ready = false
	_refusals.clear()
	_dispute_pending.clear()
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
			_now: float) -> void:
		_ready = true)
	client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
	client.lost.connect(func(reason: String) -> void: _refusals.append(reason))
	client.dispute_result.connect(_on_dispute_result)
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
	_dispute_pending.clear()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout


func _on_dispute_result(request_id: String, payload: Dictionary) -> void:
	_dispute_pending[request_id] = payload


func _dispute(request_id: String, action: String,
		args: Dictionary = {}) -> Dictionary:
	_dispute_pending.erase(request_id)
	if client == null or not client.request_dispute(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	return await _dispute_key(request_id, 15000)


func _dispute_key(request_id: String, timeout_ms: int) -> Dictionary:
	var arrived: bool = await _wait(func() -> bool:
		return _dispute_pending.has(request_id), timeout_ms)
	if not arrived:
		_expect(false, "A dispute reply arrives for request %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _dispute_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


# ------------------------------------------------------------------- fixtures

func _state(reply: Dictionary) -> Dictionary:
	var value: Variant = reply.get("state")
	return value if value is Dictionary else {}


func _case_row(view: Dictionary, case_id: String) -> Dictionary:
	var rows: Variant = view.get("cases")
	if rows is Array:
		for row_value: Variant in rows:
			if row_value is Dictionary \
					and str((row_value as Dictionary).get("case_id", "")) == case_id:
				return row_value
	return {}


func _audit_actions(case_row: Dictionary) -> Array:
	var actions: Array = []
	var audit_value: Variant = case_row.get("audit")
	if audit_value is Array:
		for row_value: Variant in audit_value:
			if row_value is Dictionary:
				actions.append(str((row_value as Dictionary).get("action", "")))
	return actions


func _disputes_path() -> String:
	return world_dir.path_join("disputes.json")


func _disputes_doc() -> Dictionary:
	if not FileAccess.file_exists(_disputes_path()):
		return {}
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(_disputes_path()))
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
	print("DISPUTE_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
