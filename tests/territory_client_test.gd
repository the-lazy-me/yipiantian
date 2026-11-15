extends SceneTree
## 地籍客户端入口：真实 loopback WSS 上的主张/释放。
##
## 父进程拉起一个真实权威和三个真实成员（A、B、访客），每一步只通过命令文件
## 驱动成员，结果与权威摘要分别写进各自报告。它验证：
##   - A 主张无主地块成功，摘要中该槽归 A；
##   - B 释放 A 的地块被拒（not_owner），归属不变；
##   - A 释放成功后地块回到 unclaimed；
##   - 访客主张被拒（forbidden）；
##   - 未知 action 被拒（unknown_action）。
##
## 全部运行在 .local/verification 下。

const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const WorldInvite = preload("res://world/world_invite.gd")

const PLAYER_SECRET: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const START: float = 1800000000.0
const WORLD: String = "world-territory-client"
const MEMBER_GRANT: String = "territory-member"
const VISITOR_GRANT: String = "territory-visitor"
const TIMEOUT: int = 25000
const WATCH_SECONDS: float = 120.0
const HOST_LIFETIME: float = 180.0

const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"
const VISITOR: String = "player_00000000000000000000000000000003"
const ALICE_NAME: String = "阿青"
const BOB_NAME: String = "小满"
const VISITOR_NAME: String = "路人"

const PARCEL_A: String = "parcel_01"
const PARCEL_B: String = "parcel_02"

var role: String = "parent"
var dir: String = ""
var port: int = 0
var url: String = ""
var who: String = ""
var grant_role: String = WorldInvite.MEMBER
var report_path: String = ""
var ready_path: String = ""
var stop_path: String = ""
var command_path: String = ""

var crypto := Crypto.new()
var host: WorldHost
var member: WorldMember
var checks: int = 0
var failures: Array[String] = []
var join_reason: String = ""
var lost: String = ""
var results: Dictionary = {}
var command_nonce: int = 0


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--dir="): dir = argument.trim_prefix("--dir=")
		elif argument.begins_with("--port="): port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--url="): url = argument.trim_prefix("--url=")
		elif argument.begins_with("--who="): who = argument.trim_prefix("--who=")
		elif argument.begins_with("--grant="): grant_role = argument.trim_prefix("--grant=")
		elif argument.begins_with("--report="): report_path = argument.trim_prefix("--report=")
		elif argument.begins_with("--ready="): ready_path = argument.trim_prefix("--ready=")
		elif argument.begins_with("--stop="): stop_path = argument.trim_prefix("--stop=")
		elif argument.begins_with("--cmd="): command_path = argument.trim_prefix("--cmd=")
	_run.call_deferred()


func _run() -> void:
	match role:
		"host": await _run_host()
		"member": await _run_member()
		_: await _run_parent()


# ------------------------------------------------------------------ parent

func _run_parent() -> void:
	dir = _repo().path_join(".local/verification/territory-client-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir.path_join("world"))
	var key: CryptoKey = crypto.generate_rsa(2048)
	var cert: X509Certificate = crypto.generate_self_signed_certificate(
		key, "CN=localhost,O=farm,C=CN")
	_expect(key != null and cert != null and key.save(dir.path_join("server.key")) == OK
		and cert.save(dir.path_join("server.crt")) == OK, "服务器密钥与证书已写入")
	_expect(_write_secret(dir.path_join("member-invite.bin"))
		and _write_secret(dir.path_join("visitor-invite.bin")), "两份邀请密钥已写入")
	port = _free_port()
	_expect(port > 0, "回环端口可用")
	if not failures.is_empty():
		_finish()
		return
	var host_pid: int = OS.create_process(_exe(), _args("host", []), false)
	_expect(host_pid > 0, "权威进程启动")
	if host_pid <= 0 or not await _wait_file(dir.path_join("host.ready"), TIMEOUT):
		_expect(false, "权威报告就绪")
		_finish()
		return

	var alice_pid: int = _spawn("alice", "alice", WorldInvite.MEMBER)
	var bob_pid: int = _spawn("bob", "bob", WorldInvite.MEMBER)
	var visitor_pid: int = _spawn("visitor", "visitor", WorldInvite.VISITOR)
	_expect(await _wait_file(dir.path_join("alice.ready"), TIMEOUT), "A 报告已加入")
	_expect(await _wait_file(dir.path_join("bob.ready"), TIMEOUT), "B 报告已加入")
	_expect(await _wait_file(dir.path_join("visitor.ready"), TIMEOUT), "访客报告已加入")
	var alice_ready: Dictionary = _read_json(dir.path_join("alice.json"))
	var bob_ready: Dictionary = _read_json(dir.path_join("bob.json"))
	var visitor_ready: Dictionary = _read_json(dir.path_join("visitor.json"))
	_expect(bool(alice_ready.get("joined", false))
		and str(alice_ready.get("role", "")) == WorldInvite.MEMBER, "A 以成员身份加入")
	_expect(bool(bob_ready.get("joined", false))
		and str(bob_ready.get("role", "")) == WorldInvite.MEMBER, "B 以成员身份加入")
	_expect(bool(visitor_ready.get("joined", false))
		and str(visitor_ready.get("role", "")) == WorldInvite.VISITOR, "访客以访客身份加入")

	# 初始摘要：默认地籍里两块地都无主。
	var alice_initial: Dictionary = await _wait_parcel(dir.path_join("alice.json"),
		PARCEL_A, "", "unclaimed", TIMEOUT)
	var initial: Dictionary = _parcel_of(alice_initial, PARCEL_A)
	_expect(str(initial.get("owner", "x")) == "" and str(initial.get("status", "")) == "unclaimed",
		"A 的初始摘要显示无主地块")

	# (1) A 主张无主地块。
	_send_command("alice", "alice-claim", "claim", PARCEL_A)
	var claim: Dictionary = await _wait_result(dir.path_join("alice.json"), "alice-claim", TIMEOUT)
	_expect(bool(claim.get("ok", false)), "A 主张无主地块成功")
	_expect(str(claim.get("action", "")) == "claim"
		and str(claim.get("parcel_id", "")) == PARCEL_A, "答复说明动作与地块")
	_expect(str(claim.get("reason_text", "")).is_empty(), "成功答复没有拒绝文案")
	var alice_claimed: Dictionary = await _wait_parcel(dir.path_join("alice.json"),
		PARCEL_A, ALICE, "claimed", TIMEOUT)
	_expect(str(_parcel_of(alice_claimed, PARCEL_A).get("owner", "")) == ALICE,
		"A 的摘要中该槽归 A")
	# 权威广播让另一个成员也看到新归属，而不靠 A 的本地回放。
	var bob_sees: Dictionary = await _wait_parcel(dir.path_join("bob.json"),
		PARCEL_A, ALICE, "claimed", TIMEOUT)
	_expect(str(_parcel_of(bob_sees, PARCEL_A).get("owner", "")) == ALICE,
		"B 的摘要随权威广播看到 A 的归属")

	# (2) B 尝试释放 A 的地块：被拒且归属不变。
	_send_command("bob", "bob-release", "release", PARCEL_A)
	var denied: Dictionary = await _wait_result(dir.path_join("bob.json"), "bob-release", TIMEOUT)
	_expect(not bool(denied.get("ok", true)), "B 不能释放 A 的地块")
	_expect(str(denied.get("reason", "")) == "not_owner", "拒绝原因是 not_owner")
	_expect(not str(denied.get("reason_text", "")).is_empty(), "拒绝带可见中文文案")
	var bob_after: Dictionary = _read_json(dir.path_join("bob.json"))
	_expect(str(_parcel_of(bob_after, PARCEL_A).get("owner", "")) == ALICE,
		"被拒后归属仍是 A")

	# (3) A 释放成功，地块回到无主。
	_send_command("alice", "alice-release", "release", PARCEL_A)
	var released: Dictionary = await _wait_result(dir.path_join("alice.json"), "alice-release", TIMEOUT)
	_expect(bool(released.get("ok", false)), "A 释放自己的地块成功")
	var alice_released: Dictionary = await _wait_parcel(dir.path_join("alice.json"),
		PARCEL_A, "", "unclaimed", TIMEOUT)
	_expect(str(_parcel_of(alice_released, PARCEL_A).get("status", "")) == "unclaimed",
		"释放后 A 的摘要回到无主")

	# (4) 访客写操作被拒，状态不变。
	_send_command("visitor", "visitor-claim", "claim", PARCEL_B)
	var visitor_denied: Dictionary = await _wait_result(dir.path_join("visitor.json"),
		"visitor-claim", TIMEOUT)
	_expect(not bool(visitor_denied.get("ok", true)), "访客不能主张地块")
	_expect(str(visitor_denied.get("reason", "")) == "forbidden", "访客被拒原因是 forbidden")
	var visitor_after: Dictionary = _read_json(dir.path_join("visitor.json"))
	_expect(str(_parcel_of(visitor_after, PARCEL_B).get("status", "")) == "unclaimed",
		"访客的主张没有改变地块状态")

	# (5) 未知 action 被拒。
	_send_command("alice", "alice-unknown", "graze", PARCEL_B)
	var unknown: Dictionary = await _wait_result(dir.path_join("alice.json"), "alice-unknown", TIMEOUT)
	_expect(not bool(unknown.get("ok", true)), "未知土地动作被拒")
	_expect(str(unknown.get("reason", "")) == "unknown_action",
		"未知动作的原因是 unknown_action")

	_write(dir.path_join("member.stop"), "stop")
	await _wait_process(alice_pid, 5000)
	await _wait_process(bob_pid, 5000)
	await _wait_process(visitor_pid, 5000)
	_write(dir.path_join("stop"), "stop")
	await _wait_process(host_pid, 15000)
	_finish()


func _spawn(label: String, member_who: String, grant: String) -> int:
	var pid: int = OS.create_process(_exe(), _args("member", [
		"--who=" + member_who, "--grant=" + grant,
		"--report=" + dir.path_join(label + ".json"),
		"--ready=" + dir.path_join(label + ".ready"),
		"--cmd=" + dir.path_join(label + ".cmd"),
		"--stop=" + dir.path_join("member.stop"),
	]), false)
	_expect(pid > 0, "成员进程 '%s' 启动" % label)
	return pid


## 写一份命令文件；成员按 nonce 只执行一次。先写临时文件再改名，避免读到半个 JSON。
func _send_command(label: String, request_id: String, action: String, parcel_id: String) -> void:
	command_nonce += 1
	var path: String = dir.path_join(label + ".cmd")
	var temporary: String = path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({
			"nonce": command_nonce, "request_id": request_id,
			"action": action, "parcel_id": parcel_id,
		}))
		file.close()
		DirAccess.rename_absolute(temporary, path)


func _parcel_of(report: Dictionary, parcel_id: String) -> Dictionary:
	var territory: Variant = report.get("territory")
	if not territory is Dictionary:
		return {}
	for value: Variant in (territory as Dictionary).get("parcels", []):
		if value is Dictionary and str((value as Dictionary).get("id", "")) == parcel_id:
			return value as Dictionary
	return {}


func _wait_parcel(path: String, parcel_id: String, owner: String, status: String,
		timeout_ms: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	var latest: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		latest = _read_json(path)
		var parcel: Dictionary = _parcel_of(latest, parcel_id)
		if str(parcel.get("owner", "missing")) == owner \
				and str(parcel.get("status", "")) == status:
			return latest
		await create_timer(0.05).timeout
	return _read_json(path)


func _wait_result(path: String, request_id: String, timeout_ms: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var report: Dictionary = _read_json(path)
		var found: Variant = (report.get("results", {}) as Dictionary).get(request_id)
		if found is Dictionary:
			return found as Dictionary
		await create_timer(0.05).timeout
	var final_report: Dictionary = _read_json(path)
	var missing: Variant = (final_report.get("results", {}) as Dictionary).get(request_id)
	return missing as Dictionary if missing is Dictionary else {}


# -------------------------------------------------------------------- host

func _run_host() -> void:
	var key := CryptoKey.new()
	var cert := X509Certificate.new()
	if key.load(dir.path_join("server.key")) != OK or cert.load(dir.path_join("server.crt")) != OK:
		_host_fail("certificate")
		return
	var member_secret: PackedByteArray = _read_secret(dir.path_join("member-invite.bin"))
	var visitor_secret: PackedByteArray = _read_secret(dir.path_join("visitor-invite.bin"))
	if member_secret.is_empty() or visitor_secret.is_empty():
		_host_fail("invite")
		return
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_server(port, "127.0.0.1", TLSOptions.server(key, cert)) != OK:
		_host_fail("listen")
		return
	root.multiplayer.multiplayer_peer = peer
	host = WorldHost.new()
	host.name = WorldHost.SESSION_NODE_NAME
	root.add_child(host)
	var opened: Dictionary = host.configure(dir.path_join("world"), START, WORLD)
	if not opened.ok:
		_host_fail("open_" + str(opened.reason))
		return
	if not host.add_grant(WorldInvite.make(MEMBER_GRANT, member_secret,
			WorldInvite.MEMBER, WORLD, 0.0, false)).ok:
		_host_fail("member_grant")
		return
	if not host.add_grant(WorldInvite.make(VISITOR_GRANT, visitor_secret,
			WorldInvite.VISITOR, WORLD, 0.0, false)).ok:
		_host_fail("visitor_grant")
		return
	_write(dir.path_join("host.ready"), "ready")
	var deadline: int = Time.get_ticks_msec() + int(HOST_LIFETIME * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(dir.path_join("stop")):
			break
		await create_timer(0.1).timeout
	_write(dir.path_join("host.json"), JSON.stringify({
		"ok": true, "sequence": host.world.farm.event_sequence() if host.world.farm != null else 0,
	}))
	quit(0)


func _host_fail(reason: String) -> void:
	_write(dir.path_join("host.json"), JSON.stringify({"error": reason}))
	quit(1)


# ------------------------------------------------------------------ member

func _run_member() -> void:
	var cert := X509Certificate.new()
	var text: String = FileAccess.get_file_as_string(dir.path_join("server.crt"))
	if text.is_empty() or cert.load_from_string(text) != OK:
		_report("cert_load")
		return
	var secret_file: String = "member-invite.bin" if grant_role == WorldInvite.MEMBER \
		else "visitor-invite.bin"
	var secret: PackedByteArray = _read_secret(dir.path_join(secret_file))
	if secret.is_empty():
		_report("invite")
		return
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client(url, TLSOptions.client(cert, "localhost")) != OK:
		_report("create_client")
		return
	root.multiplayer.multiplayer_peer = peer
	member = WorldMember.new()
	member.name = WorldMember.SESSION_NODE_NAME
	member.secret = secret
	member.grant_id = MEMBER_GRANT if grant_role == WorldInvite.MEMBER else VISITOR_GRANT
	member.world_id = WORLD
	member.player_id = _id_of(who)
	member.player_secret = Marshalls.base64_to_raw(PLAYER_SECRET)
	member.display_name = _name_of(who)
	root.add_child(member)
	root.multiplayer.auth_callback = _member_auth
	member.join_failed.connect(func(reason: String) -> void: join_reason = reason)
	member.authority_lost.connect(func(reason: String) -> void: lost = reason)
	member.territory_result.connect(func(request_id: String, payload: Dictionary) -> void:
		results[request_id] = payload
		_write_report())
	member.connect_to(url, secret, WORLD)
	var started: bool = false
	var ready_written: bool = false
	var last_nonce: int = 0
	var last_report: String = ""
	var deadline: int = Time.get_ticks_msec() + int(WATCH_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if not started and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			started = true
			root.multiplayer.send_auth(1, member.auth_hello())
		if member.is_joined() and not ready_written:
			ready_written = true
			if not ready_path.is_empty():
				_write(ready_path, "ready")
			_write_report()
		if member.is_joined() and not command_path.is_empty():
			var command: Dictionary = _read_json(command_path)
			var nonce: int = int(command.get("nonce", 0))
			if nonce > last_nonce:
				last_nonce = nonce
				var request_id: String = str(command.get("request_id", ""))
				member.request_territory(request_id, str(command.get("action", "")), {
					"parcel_id": str(command.get("parcel_id", "")),
					"command_id": request_id,
				})
		var report: String = JSON.stringify(_report_document())
		if report != last_report:
			last_report = report
			_write_report()
		if not stop_path.is_empty() and FileAccess.file_exists(stop_path):
			break
		if not join_reason.is_empty() or not lost.is_empty():
			break
		await create_timer(0.05).timeout
	_write_report()
	quit(0)


func _report_document() -> Dictionary:
	var territory: Variant = member.state.get("territory", {}) if member != null else {}
	return {
		"joined": member != null and member.is_joined(),
		"role": member.role if member != null else "",
		"reason": join_reason if not join_reason.is_empty() else lost,
		"territory": territory if territory is Dictionary else {},
		"results": results,
	}


func _write_report() -> void:
	if report_path.is_empty() or member == null:
		return
	_write(report_path, JSON.stringify(_report_document()))


func _report(reason: String) -> void:
	if not report_path.is_empty():
		_write(report_path, JSON.stringify({"joined": false, "reason": reason}))
	quit(0)


func _member_auth(_id: int, data: PackedByteArray) -> void:
	root.multiplayer.send_auth(1,
		crypto.hmac_digest(HashingContext.HASH_SHA256, member.secret, data))
	root.multiplayer.complete_auth(1)


# ------------------------------------------------------------------ shared

func _id_of(who_id: String) -> String:
	match who_id:
		"alice": return ALICE
		"bob": return BOB
		"visitor": return VISITOR
	return ""


func _name_of(who_id: String) -> String:
	match who_id:
		"alice": return ALICE_NAME
		"bob": return BOB_NAME
		"visitor": return VISITOR_NAME
	return ""


func _args(child_role: String, extra: Array) -> PackedStringArray:
	var args := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join("tests/territory_client_test.gd"),
		"--", "--role=" + child_role, "--dir=" + dir, "--port=%d" % port,
		"--url=wss://127.0.0.1:%d" % port,
	])
	for value: String in extra:
		args.append(value)
	return args


func _exe() -> String:
	return OS.get_executable_path()


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _free_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0, "127.0.0.1") != OK:
		return 0
	var chosen: int = probe.get_local_port()
	probe.stop()
	return chosen


func _write_secret(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(crypto.generate_random_bytes(32))
	file.close()
	return true


func _read_secret(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var secret: PackedByteArray = file.get_buffer(file.get_length())
	file.close()
	return secret


func _read_json(path: String) -> Dictionary:
	# The member rewrites its report while the parent polls it, so a read can
	# land between truncate and write. Retry briefly instead of treating a
	# half-written document as an empty one; JSON.new() also keeps a parse miss
	# from printing an engine error the run does not act on.
	var deadline: int = Time.get_ticks_msec() + 200
	while true:
		if FileAccess.file_exists(path):
			var parser := JSON.new()
			if parser.parse(FileAccess.get_file_as_string(path)) == OK \
					and parser.data is Dictionary:
				return parser.data as Dictionary
		if Time.get_ticks_msec() >= deadline:
			return {}
		OS.delay_msec(5)
	return {}


## Reports and markers are read by another process, so write a sibling temporary
## file and rename it; a reader never sees the truncated document.
func _write(path: String, text: String) -> void:
	var temporary: String = path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()
	if DirAccess.rename_absolute(temporary, path) != OK:
		DirAccess.remove_absolute(path)
		DirAccess.rename_absolute(temporary, path)


func _wait_file(path: String, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(path):
			return true
		await create_timer(0.05).timeout
	return FileAccess.file_exists(path)


func _wait_process(pid: int, timeout_ms: int) -> void:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline and OS.is_process_running(pid):
		await create_timer(0.05).timeout


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("TERRITORY_CLIENT_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
