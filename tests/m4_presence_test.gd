extends SceneTree
## M4-02 切片：在线成员名册（presence）。
##
## 三个真实成员（alice、bob、匿名）连接同一权威宿主。每次加入或离开，宿主
## 通过既有 command_result 通道向所有成员推送同一份完整名册；客户端整份替换。
## bob 进程退出后 alice 的名册应在数秒内减少；bob 重连后 alice 再收到一份
## 内容相同的三行名册，列表不得增长，证明它是整份替换而不是增量追加。
##
## 同一夹具还覆盖活跃身份唯一：另一个连接声明 alice 的 player_id 会被拒绝；
## alice 断开释放后同名重连可以再次加入，其命令仍按连接身份记账。

const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const FarmCommand = preload("res://farm/farm_command.gd")

const GRANT_ID: String = "presence-member"
const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"
const ALICE_NAME: String = "阿青"
const BOB_NAME: String = "小满"
const ROLE: String = "member"
const TIMEOUT: float = 15.0
const HOST_LIFETIME: float = 180.0
const WATCH_SECONDS: float = 120.0
const START: float = 1800000000.0

var role: String = "parent"
var dir: String = ""
var port: int = 0
var url: String = ""
var world: String = "world-presence"
var report_path: String = ""
var ready_path: String = ""
var stop_path: String = ""
var who: String = ""
var command: String = ""

var crypto := Crypto.new()
var host: WorldHost
var member: WorldMember
var checks: int = 0
var failures: Array[String] = []
var join_reason: String = ""
var lost: String = ""
var sizes: Array[int] = []
var history: Array = []
var replies: Dictionary = {}


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--dir="): dir = argument.trim_prefix("--dir=")
		elif argument.begins_with("--port="): port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--url="): url = argument.trim_prefix("--url=")
		elif argument.begins_with("--report="): report_path = argument.trim_prefix("--report=")
		elif argument.begins_with("--ready="): ready_path = argument.trim_prefix("--ready=")
		elif argument.begins_with("--stop="): stop_path = argument.trim_prefix("--stop=")
		elif argument.begins_with("--who="): who = argument.trim_prefix("--who=")
		elif argument.begins_with("--command="): command = argument.trim_prefix("--command=")
	_run.call_deferred()


func _run() -> void:
	match role:
		"host": await _run_host()
		"member": await _run_member()
		_: await _run_parent()


# ------------------------------------------------------------------ parent

func _run_parent() -> void:
	dir = _repo().path_join(".local/verification/m4-presence-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var key: CryptoKey = crypto.generate_rsa(2048)
	var cert: X509Certificate = crypto.generate_self_signed_certificate(
		key, "CN=localhost,O=farm,C=CN")
	_expect(key != null and cert != null and key.save(dir.path_join("server.key")) == OK
		and cert.save(dir.path_join("server.crt")) == OK, "服务器密钥与证书已写入")
	var secret: PackedByteArray = crypto.generate_random_bytes(32)
	var invite_file := FileAccess.open(dir.path_join("invite.bin"), FileAccess.WRITE)
	_expect(invite_file != null, "邀请密钥已写入")
	if invite_file != null:
		invite_file.store_buffer(secret)
		invite_file.close()
	port = _free_port()
	_expect(port > 0, "回环端口可用")
	if not failures.is_empty():
		_finish()
		return
	var host_pid: int = OS.create_process(_exe(), _args("host", []), false)
	_expect(host_pid > 0, "宿主进程启动")
	if host_pid <= 0 or not await _wait_file(dir.path_join("host.ready"), 25000):
		_expect(false, "宿主报告就绪")
		_finish()
		return

	# (1) 三个成员同时在线：已加入者、另一个具名成员、无 player_id 的匿名成员。
	var alice_pid: int = _spawn("alice", "alice")
	var bob_pid: int = _spawn("bob", "bob")
	var anon_pid: int = _spawn("anonymous", "anonymous")
	_expect(await _wait_file(dir.path_join("alice.ready"), 25000), "alice 进程报告已加入")
	_expect(await _wait_file(dir.path_join("bob.ready"), 25000), "bob 进程报告已加入")
	_expect(await _wait_file(dir.path_join("anonymous.ready"), 25000), "匿名进程报告已加入")

	var alice_three: Dictionary = await _wait_roster(dir.path_join("alice.json"), 3, 25000)
	var bob_three: Dictionary = await _wait_roster(dir.path_join("bob.json"), 3, 25000)
	var anon_three: Dictionary = await _wait_roster(dir.path_join("anonymous.json"), 3, 25000)
	var alice_rows: Array = alice_three.get("roster", []) as Array
	var bob_rows: Array = bob_three.get("roster", []) as Array
	var anon_rows: Array = anon_three.get("roster", []) as Array
	print("M4_PRESENCE_ALICE " + JSON.stringify(alice_rows))
	print("M4_PRESENCE_BOB " + JSON.stringify(bob_rows))
	print("M4_PRESENCE_ANONYMOUS " + JSON.stringify(anon_rows))
	_expect(bool(alice_three.get("joined", false)), "alice 报告已加入")
	_expect(alice_rows.size() == 3, "三个成员在线时 alice 的名册恰好 3 行")
	_expect(bob_rows.size() == 3, "三个成员在线时 bob 的名册恰好 3 行")
	_expect(anon_rows.size() == 3, "三个成员在线时匿名成员的名册恰好 3 行")

	var bob_row: Dictionary = _row_of(alice_rows, BOB)
	var anon_row: Dictionary = _row_of(alice_rows, "")
	_expect(str(bob_row.get("name", "")) == BOB_NAME, "alice 看到 bob 的显示名")
	_expect(str(bob_row.get("role", "")) == ROLE, "alice 看到 bob 的角色")
	_expect(str(anon_row.get("player_id", "")) == "" and str(anon_row.get("name", "")) == "",
		"匿名成员以空 player_id、空名称出现")

	# (1b) 第二个连接声明 alice 的 player_id：当前会话仍在，必须被拒绝。
	var dup_pid: int = _spawn("alice-dup", "alice")
	_expect(await _wait_file(dir.path_join("alice-dup.json"), 25000),
		"重复身份的进程报告结果")
	var dup_report: Dictionary = _read_json(dir.path_join("alice-dup.json"))
	print("M4_PRESENCE_DUPLICATE " + JSON.stringify(dup_report))
	_expect(not bool(dup_report.get("joined", false)), "第二个连接不能带着已占用的身份加入")
	_expect(str(dup_report.get("reason", "")) == "player_id_in_use",
		"拒绝原因说明该 player_id 正在使用")
	await _wait_process(dup_pid, 5000)
	var after_dup: Dictionary = _read_json(dir.path_join("alice.json"))
	_expect((after_dup.get("roster", []) as Array).size() == 3,
		"被拒连接没有进入名册，在线成员仍是 3 人")

	# (2) bob 进程退出：宿主清理成员并向剩下的人推送更小的名册。
	if bob_pid > 0 and OS.is_process_running(bob_pid):
		OS.kill(bob_pid)
		await _wait_process(bob_pid, 5000)
	var alice_two: Dictionary = await _wait_roster(dir.path_join("alice.json"), 2, 15000)
	var two_rows: Array = alice_two.get("roster", []) as Array
	print("M4_PRESENCE_AFTER_EXIT " + JSON.stringify(two_rows))
	_expect(two_rows.size() == 2, "bob 退出后 alice 的名册降为 2 行")
	_expect(_row_of(two_rows, BOB).is_empty(), "离开的 bob 不再出现在名册里")

	# (3) bob 用同一身份重连：alice 再次收到内容相同的三行名册。
	var bob_again_pid: int = _spawn("bob-again", "bob")
	_expect(await _wait_file(dir.path_join("bob-again.ready"), 25000), "bob 重连进程报告已加入")
	var bob_again: Dictionary = await _wait_roster(dir.path_join("bob-again.json"), 3, 25000)
	_expect((bob_again.get("roster", []) as Array).size() == 3, "重连的 bob 自己看到 3 行名册")
	var alice_three_again: Dictionary = await _wait_roster(dir.path_join("alice.json"), 3, 25000)
	var again_rows: Array = alice_three_again.get("roster", []) as Array
	var observed: Array = alice_three_again.get("sizes", []) as Array
	var max_size: int = 0
	for value: Variant in observed:
		max_size = maxi(max_size, int(value))
	print("M4_PRESENCE_AFTER_REJOIN " + JSON.stringify(again_rows))
	print("M4_PRESENCE_SIZES " + JSON.stringify(observed))
	_expect(again_rows.size() == 3, "bob 重连后 alice 的名册仍恰好 3 行")
	_expect(JSON.stringify(again_rows) == JSON.stringify(alice_rows),
		"重连后收到的是与之前相同的名册内容")
	_expect(max_size == 3, "名册大小的历史最大值从未超过 3，重复投递没有追加条目")

	# (4) alice 断开后释放 player_id：同名连接可以再次加入，且命令记在该
	# 连接解析出的身份下，而不是名册里的另一个成员或载荷声明。
	if alice_pid > 0 and OS.is_process_running(alice_pid):
		OS.kill(alice_pid)
		await _wait_process(alice_pid, 5000)
	var bob_two: Dictionary = await _wait_roster(dir.path_join("bob-again.json"), 2, 15000)
	_expect((bob_two.get("roster", []) as Array).size() == 2,
		"alice 断开后在线成员降为 2 人")
	var alice_again_pid: int = _spawn("alice-again", "alice", ["--command=theft"])
	_expect(await _wait_file(dir.path_join("alice-again.ready"), 25000),
		"断开释放后同名连接可以再次加入")
	var alice_again: Dictionary = await _wait_roster(dir.path_join("alice-again.json"), 3, 25000)
	_expect(bool(alice_again.get("joined", false)) and
		(alice_again.get("roster", []) as Array).size() == 3,
		"重连的 alice 重新出现在 3 人名册中")
	_expect(await _wait_report(dir.path_join("alice-again.json"), "theft_ok", 20000),
		"重连 alice 的命令得到权威回复")

	# (5) 收尾。
	_write(dir.path_join("member.stop"), "stop")
	await _wait_process(alice_pid, 5000)
	await _wait_process(anon_pid, 5000)
	await _wait_process(bob_again_pid, 5000)
	await _wait_process(alice_again_pid, 5000)
	await _wait_process(dup_pid, 5000)
	_write(dir.path_join("stop"), "stop")
	await _wait_process(host_pid, 15000)
	var host_summary: Dictionary = _read_json(dir.path_join("host.json"))
	print("M4_PRESENCE_HOST " + JSON.stringify(host_summary))
	_expect(bool(host_summary.get("theft_alice", false)),
		"命令按连接绑定身份记账到 alice")
	_expect(not bool(host_summary.get("theft_bob", true)),
		"同一命令没有记到其他成员名下")
	_expect(int(host_summary.get("committed", -1)) == 1,
		"被拒的重复身份连接没有提交任何命令")
	_finish()


func _spawn(label: String, member_who: String, extra: Array = []) -> int:
	var arguments: Array = [
		"--who=" + member_who,
		"--report=" + dir.path_join(label + ".json"),
		"--ready=" + dir.path_join(label + ".ready"),
		"--stop=" + dir.path_join("member.stop"),
	]
	arguments.append_array(extra)
	var pid: int = OS.create_process(_exe(), _args("member", arguments), false)
	_expect(pid > 0, "成员进程 '%s' 启动" % label)
	return pid


func _row_of(rows: Array, player_id: String) -> Dictionary:
	for row: Variant in rows:
		if row is Dictionary and str((row as Dictionary).get("player_id", "")) == player_id:
			return row as Dictionary
	return {}


# -------------------------------------------------------------------- host

func _run_host() -> void:
	var key := CryptoKey.new()
	var cert := X509Certificate.new()
	if key.load(dir.path_join("server.key")) != OK or cert.load(dir.path_join("server.crt")) != OK:
		_host_fail("certificate")
		return
	var file := FileAccess.open(dir.path_join("invite.bin"), FileAccess.READ)
	if file == null:
		_host_fail("invite")
		return
	var secret: PackedByteArray = file.get_buffer(file.get_length())
	file.close()
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_server(port, "127.0.0.1", TLSOptions.server(key, cert)) != OK:
		_host_fail("listen")
		return
	root.multiplayer.multiplayer_peer = peer
	host = WorldHost.new()
	host.name = WorldHost.SESSION_NODE_NAME
	root.add_child(host)
	var opened: Dictionary = host.configure(dir.path_join("world"), START, world)
	if not opened.ok:
		_host_fail("open_" + str(opened.reason))
		return
	# 名册测试的多个成员共用同一张可重复使用的邀请。
	if not host.add_grant(
			WorldInvite.make(GRANT_ID, secret, WorldInvite.MEMBER, world, 0.0, false)).ok:
		_host_fail("grant")
		return
	_write(dir.path_join("host.ready"), "ready")
	var deadline: int = Time.get_ticks_msec() + int(HOST_LIFETIME * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(dir.path_join("stop")):
			break
		await create_timer(0.1).timeout
	_write(dir.path_join("host.json"), JSON.stringify({
		"ok": true,
		"theft_alice": host.world.farm.theft_enabled(ALICE),
		"theft_bob": host.world.farm.theft_enabled(BOB),
		"committed": host.world.farm.committed_command_count(),
		"sequence": host.world.farm.event_sequence(),
	}))
	quit(0)


# ------------------------------------------------------------------ member

func _run_member() -> void:
	var cert := X509Certificate.new()
	var text: String = FileAccess.get_file_as_string(dir.path_join("server.crt"))
	if text.is_empty() or cert.load_from_string(text) != OK:
		_report("cert_load")
		return
	var secret: PackedByteArray = PackedByteArray()
	var file := FileAccess.open(dir.path_join("invite.bin"), FileAccess.READ)
	if file != null:
		secret = file.get_buffer(file.get_length())
		file.close()
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client(url, TLSOptions.client(cert, "localhost")) != OK:
		_report("create_client")
		return
	root.multiplayer.multiplayer_peer = peer
	member = WorldMember.new()
	member.name = WorldMember.SESSION_NODE_NAME
	member.secret = secret
	member.grant_id = GRANT_ID
	member.world_id = world
	member.player_id = _id_of(who)
	member.display_name = _name_of(who)
	root.add_child(member)
	root.multiplayer.auth_callback = _member_auth
	member.join_failed.connect(func(reason: String) -> void: join_reason = reason)
	member.authority_lost.connect(func(reason: String) -> void: lost = reason)
	member.roster_changed.connect(_on_roster)
	member.reply_received.connect(func(request_id: String, payload: Dictionary) -> void:
		replies[request_id] = payload)
	member.connect_to(url, secret, world)
	var started: bool = false
	var ready_written: bool = false
	var command_sent: bool = false
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
		if member.is_joined() and command == "theft" and not command_sent:
			command_sent = true
			# set_theft 的目标由连接解析，而不是载荷；它把结果写在 actor 名下。
			member.submit_command(FarmCommand.make_set_theft("presence-theft-" + who, true, START))
		if command_sent and replies.has("presence-theft-" + who):
			_write_report()
			break
		if not stop_path.is_empty() and FileAccess.file_exists(stop_path):
			break
		if not join_reason.is_empty() or not lost.is_empty():
			break
		await create_timer(0.05).timeout
	_write_report()
	quit(0)


## 每收到一份名册就记录一次大小和历史，父进程据此证明整份替换不会增长列表。
func _on_roster(rows: Array[Dictionary]) -> void:
	sizes.append(rows.size())
	history.append(rows.duplicate(true))
	_write_report()


func _write_report() -> void:
	if report_path.is_empty():
		return
	_write(report_path, JSON.stringify({
		"joined": member.is_joined(),
		"reason": join_reason if not join_reason.is_empty() else lost,
		"roster": member.roster,
		"sizes": sizes,
		"history": history,
		"theft_ok": bool((replies.get("presence-theft-" + who, {}) as Dictionary).get("ok", false)),
		"theft_reason": str((replies.get("presence-theft-" + who, {}) as Dictionary).get("reason", "")),
	}))


func _member_auth(_id: int, data: PackedByteArray) -> void:
	root.multiplayer.send_auth(1,
		crypto.hmac_digest(HashingContext.HASH_SHA256, member.secret, data))
	root.multiplayer.complete_auth(1)


# ------------------------------------------------------------------ shared

func _id_of(who_id: String) -> String:
	if who_id == "alice":
		return ALICE
	if who_id == "bob":
		return BOB
	return ""


func _name_of(who_id: String) -> String:
	if who_id == "alice":
		return ALICE_NAME
	if who_id == "bob":
		return BOB_NAME
	return ""


func _report(reason: String) -> void:
	if not report_path.is_empty():
		_write(report_path, JSON.stringify({"joined": false, "reason": reason}))
	quit(0)


func _host_fail(reason: String) -> void:
	_write(dir.path_join("host.json"), JSON.stringify({"error": reason}))
	quit(1)


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _args(child_role: String, extra: Array) -> PackedStringArray:
	var args := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join("tests/m4_presence_test.gd"),
		"--", "--role=" + child_role, "--dir=" + dir, "--port=%d" % port,
		"--url=wss://127.0.0.1:%d" % port, "--world=" + world,
	])
	for value: String in extra:
		args.append(value)
	return args


func _exe() -> String:
	return OS.get_executable_path()


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
	print("M4_PRESENCE_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)


func _wait_file(path: String, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(path):
			return true
		await create_timer(0.05).timeout
	return FileAccess.file_exists(path)


## 等到某个成员的报告里名册恰好为 `count` 行，返回当时的报告。
func _wait_roster(path: String, count: int, timeout_ms: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	var latest: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		latest = _read_json(path)
		if (latest.get("roster", []) as Array).size() == count:
			return latest
		await create_timer(0.05).timeout
	return _read_json(path)


## 等到报告里某个布尔字段为 true；进程在命令回复后才写最终报告。
func _wait_report(path: String, key: String, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if bool(_read_json(path).get(key, false)):
			return true
		await create_timer(0.05).timeout
	return bool(_read_json(path).get(key, false))


func _wait_process(pid: int, timeout_ms: int) -> void:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline and OS.is_process_running(pid):
		await create_timer(0.05).timeout


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
