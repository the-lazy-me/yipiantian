extends SceneTree
## M4 切片：权威广播别人的提交时携带动作执行者的身份。
##
## 甲（小满）提交一次真实收获，乙（阿青）只连接不提交。乙必须从权威推送的
## 同一条 change 里读到 `from_id`/`from_name`，这样客户端能显示“小满 收了
## 青菜”，而不是一条匿名状态变化。
##
## 顺序是确定的：父进程先让乙加入并写出就绪文件，再启动甲提交。成员各自
## 一个进程，因为同一进程只能有一个 /root/WorldSession。
##
## 角色：--role=host、--role=member，由父进程编排。

const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const PLAYER_SECRET: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const WorldInvite = preload("res://world/world_invite.gd")
const FarmCommand = preload("res://farm/farm_command.gd")

const GRANT_ID: String = "activity-member"
const WORLD: String = "world-activity"
const ACTOR_ID: String = "player_00000000000000000000000000000021"
const ACTOR_NAME: String = "小满"
const WATCHER_ID: String = "player_00000000000000000000000000000022"
const WATCHER_NAME: String = "阿青"

const TIMEOUT: float = 15.0
const HOST_LIFETIME: float = 150.0
const MEMBER_LIFETIME: float = 60.0
const START: float = 1800000000.0
## field_03/cell_06 在默认布局里直接是成熟作物，不需要额外的种植/推进时间。
const FIELD: String = "field_03"
const CELL: String = "cell_06"

var role: String = "parent"
var dir: String = ""
var port: int = 0
var url: String = ""
var who: String = ""
var report_path: String = ""
var ready_path: String = ""
var stop_path: String = ""
var command_id: String = "activity-harvest"

var crypto := Crypto.new()
var host: WorldHost
var member: WorldMember
var checks: int = 0
var failures: Array[String] = []
var join_reason: String = ""
var lost: String = ""
var replies: Dictionary = {}
var remote_changes: Array = []
var host_pid: int = -1
var watcher_pid: int = -1
var actor_pid: int = -1


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--dir="): dir = argument.trim_prefix("--dir=")
		elif argument.begins_with("--port="): port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--url="): url = argument.trim_prefix("--url=")
		elif argument.begins_with("--who="): who = argument.trim_prefix("--who=")
		elif argument.begins_with("--report="): report_path = argument.trim_prefix("--report=")
		elif argument.begins_with("--ready="): ready_path = argument.trim_prefix("--ready=")
		elif argument.begins_with("--stop="): stop_path = argument.trim_prefix("--stop=")
		elif argument.begins_with("--id="): command_id = argument.trim_prefix("--id=")
	_run.call_deferred()


func _run() -> void:
	match role:
		"host": await _run_host()
		"member": await _run_member()
		_: await _run_parent()


# ------------------------------------------------------------------ parent

func _run_parent() -> void:
	dir = _repo().path_join(".local/verification/m4-activity-%d" % Time.get_ticks_usec())
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
		await _cleanup()
		_finish()
		return

	host_pid = OS.create_process(_exe(), _args_for("host", []), false)
	_expect(host_pid > 0, "宿主进程启动")
	if host_pid <= 0 or not await _wait_file(dir.path_join("host.ready"), 25000):
		_expect(false, "宿主报告就绪")
		await _cleanup()
		_finish()
		return

	# 乙先加入并确认就绪，父进程才启动甲，这样甲的提交必然发生在乙入册之后。
	watcher_pid = OS.create_process(_exe(), _args_for("member", [
		"--who=watcher", "--report=" + dir.path_join("watcher.json"),
		"--ready=" + dir.path_join("watcher.ready"),
		"--stop=" + dir.path_join("member.stop")]), false)
	_expect(watcher_pid > 0, "观察成员进程启动")
	_expect(await _wait_file(dir.path_join("watcher.ready"), 25000),
		"观察成员先加入并报告就绪")

	actor_pid = OS.create_process(_exe(), _args_for("member", [
		"--who=actor", "--report=" + dir.path_join("actor.json"),
		"--id=" + command_id]), false)
	_expect(actor_pid > 0, "执行成员进程启动")
	var actor: Dictionary = await _wait_report(dir.path_join("actor.json"),
		int((TIMEOUT + 20.0) * 1000.0))
	_expect(not actor.is_empty(), "执行成员报告结果")
	_expect(bool(actor.get("joined", false)), "执行成员已加入")
	var reply: Dictionary = actor.get("reply", {}) as Dictionary
	_expect(bool(reply.get("ok", false)), "执行成员的收获被权威接受")
	var actor_sequence: int = int(actor.get("sequence", -1))
	if not actor.is_empty():
		print("M4_ACTIVITY_ACTOR " + JSON.stringify(actor))

	# 乙的进程在收到广播后自己写报告；父进程只等它至少出现一条 change。
	var watcher: Dictionary = await _wait_changes(dir.path_join("watcher.json"), 1, 20000)
	_write(dir.path_join("member.stop"), "stop")
	await _wait_process(watcher_pid, 10000)
	if watcher_pid > 0 and OS.is_process_running(watcher_pid):
		OS.kill(watcher_pid)
		await _wait_process(watcher_pid, 5000)
	watcher = _read_json(dir.path_join("watcher.json"))
	print("M4_ACTIVITY_WATCHER " + JSON.stringify(watcher))

	_expect(not watcher.is_empty(), "观察成员报告结果")
	_expect(bool(watcher.get("joined", false)), "观察成员保持在线")
	_expect(str(watcher.get("reason", "")) == "", "观察成员没有失去权威")
	var seen: Array = watcher.get("remote_changes", []) as Array
	_expect(seen.size() == 1, "观察成员恰好收到一条 change")
	if seen.size() == 1:
		var change: Dictionary = seen[0] as Dictionary
		_expect(str(change.get("from_id", "")) == ACTOR_ID,
			"change 携带提交者的 player_id")
		_expect(str(change.get("from_name", "")) == ACTOR_NAME,
			"change 携带提交者的显示名（小满）")
		var command: Dictionary = change.get("command", {}) as Dictionary
		_expect(str(command.get("kind", "")) == "harvest", "change 携带收获命令")
		_expect(int(change.get("sequence", -1)) == actor_sequence,
			"change 的序号与执行成员收到的回复一致")

	await _cleanup()
	_finish()


## 等到报告里至少出现 `count` 条 change；等待期间报告可能尚未落盘。
func _wait_changes(path: String, count: int, timeout_ms: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	var latest: Dictionary = {}
	while Time.get_ticks_msec() < deadline:
		latest = _read_json(path)
		if (latest.get("remote_changes", []) as Array).size() >= count:
			return latest
		await create_timer(0.05).timeout
	return _read_json(path)


## 等到执行成员的一份完整报告，避免读到正在写入的半截 JSON。
func _wait_report(path: String, timeout_ms: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var parsed: Dictionary = _read_json(path)
		if parsed.has("reply"):
			return parsed
		await create_timer(0.05).timeout
	return _read_json(path)


func _cleanup() -> void:
	if dir.is_empty():
		return
	_write(dir.path_join("member.stop"), "stop")
	_write(dir.path_join("stop"), "stop")
	for pid: int in [actor_pid, watcher_pid]:
		if pid > 0:
			await _wait_process(pid, 5000)
			if OS.is_process_running(pid):
				OS.kill(pid)
				await _wait_process(pid, 5000)
	if host_pid > 0:
		await _wait_process(host_pid, 10000)
		if OS.is_process_running(host_pid):
			OS.kill(host_pid)
			await _wait_process(host_pid, 5000)
	_remove_tree(dir)


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
	var opened: Dictionary = host.configure(dir.path_join("world"), START, WORLD)
	if not opened.ok:
		_host_fail("open_" + str(opened.reason))
		return
	# 两个具名成员共用一张可重复使用的邀请。
	if not host.add_grant(
			WorldInvite.make(GRANT_ID, secret, WorldInvite.MEMBER, WORLD, 0.0, false)).ok:
		_host_fail("grant")
		return
	_write(dir.path_join("host.ready"), "ready")
	var deadline: int = Time.get_ticks_msec() + int(HOST_LIFETIME * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(dir.path_join("stop")):
			break
		await create_timer(0.1).timeout
	_write(dir.path_join("host.json"), JSON.stringify({
		"commands": host.world.farm.committed_command_count() if host.world.farm != null else 0,
		"sequence": host.world.farm.event_sequence() if host.world.farm != null else 0,
	}))
	quit(0)


# ------------------------------------------------------------------ member

func _run_member() -> void:
	var cert := X509Certificate.new()
	var text: String = FileAccess.get_file_as_string(dir.path_join("server.crt"))
	if text.is_empty() or cert.load_from_string(text) != OK:
		_report_with_reason("cert_load")
		return
	var secret: PackedByteArray = PackedByteArray()
	var file := FileAccess.open(dir.path_join("invite.bin"), FileAccess.READ)
	if file != null:
		secret = file.get_buffer(file.get_length())
		file.close()
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client(url, TLSOptions.client(cert, "localhost")) != OK:
		_report_with_reason("create_client")
		return
	root.multiplayer.multiplayer_peer = peer
	member = WorldMember.new()
	member.name = WorldMember.SESSION_NODE_NAME
	member.secret = secret
	member.grant_id = GRANT_ID
	member.world_id = WORLD
	member.player_id = ACTOR_ID if who == "actor" else WATCHER_ID
	member.player_secret = Marshalls.base64_to_raw(PLAYER_SECRET)
	member.display_name = ACTOR_NAME if who == "actor" else WATCHER_NAME
	root.add_child(member)
	root.multiplayer.auth_callback = _member_auth
	member.join_failed.connect(func(reason: String) -> void: join_reason = reason)
	member.authority_lost.connect(func(reason: String) -> void: lost = reason)
	member.reply_received.connect(func(request_id: String, payload: Dictionary) -> void:
		replies[request_id] = payload)
	member.remote_change.connect(_on_remote_change)
	member.connect_to(url, secret, WORLD)

	var started: bool = false
	var announced: bool = false
	var sent: bool = false
	var command: Dictionary = FarmCommand.make(command_id, FIELD, CELL, START)
	var deadline: int = Time.get_ticks_msec() + int(MEMBER_LIFETIME * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if not started and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			started = true
			root.multiplayer.send_auth(1, member.auth_hello())
		if member.is_joined() and not announced:
			announced = true
			if not ready_path.is_empty():
				_write(ready_path, "ready")
				# 观察成员就绪时先落一份空报告，让父进程可以提前判断连接状态。
				_write_report()
			else:
				member.submit_command(command)
				sent = true
		if not stop_path.is_empty() and FileAccess.file_exists(stop_path):
			break
		if sent and replies.has(command_id):
			# 给权威推送一点时间到达，再结束进程。
			await create_timer(0.3).timeout
			break
		if not join_reason.is_empty() or not lost.is_empty():
			await create_timer(0.2).timeout
			break
		await create_timer(0.05).timeout
	_write_report()
	quit(0)


## 每收到一条别人提交的 change 就更新报告；父进程据此断言身份字段。
func _on_remote_change(entry: Dictionary) -> void:
	remote_changes.append(entry)
	_write_report()


func _write_report() -> void:
	if report_path.is_empty():
		return
	var reply: Dictionary = replies.get(command_id, {}) as Dictionary
	_write(report_path, JSON.stringify({
		"joined": member.is_joined(),
		"reason": join_reason if not join_reason.is_empty() else lost,
		"reply": reply, "sequence": int(reply.get("sequence", -1)),
		"last_sequence": member.last_sequence,
		"remote_changes": remote_changes,
	}))


func _report_with_reason(reason: String) -> void:
	if not report_path.is_empty():
		_write(report_path, JSON.stringify({"joined": false, "reason": reason, "reply": {}}))
	quit(0)


func _member_auth(_id: int, data: PackedByteArray) -> void:
	root.multiplayer.send_auth(1,
		crypto.hmac_digest(HashingContext.HASH_SHA256, member.secret, data))
	root.multiplayer.complete_auth(1)


# ------------------------------------------------------------------ shared

func _host_fail(reason: String) -> void:
	_write(dir.path_join("host.json"), JSON.stringify({"error": reason}))
	quit(1)


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _args_for(child_role: String, extra: Array) -> PackedStringArray:
	var args := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join("tests/m4_activity_test.gd"),
		"--", "--role=" + child_role, "--dir=" + dir, "--port=%d" % port,
	])
	for value: String in extra:
		args.append(value)
	args.append("--url=wss://127.0.0.1:%d" % port)
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
	print("M4_ACTIVITY_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)


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


## 递归删除隔离目录；残留的世界文件和证书都必须清掉。
func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for name: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(name))
	for name: String in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(name))
	DirAccess.remove_absolute(path)
