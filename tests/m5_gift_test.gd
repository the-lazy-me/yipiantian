extends SceneTree
## M5 切片：赠送真的跨玩家转移并落盘，重放不多发。
##
## 甲（小满）先收获一次，把一篮 greens 收进自己的口袋；乙（阿青）只连接、
## 保持在线。甲送出一篮给乙，再用同一个命令 id 重放，最后提交一笔余额不足的
## 新赠送。代替断言：
##   - 甲的口袋从 1 变 0，乙的口袋从 0 变 1，且宿主落盘的 farm.json 一致；
##   - 同一命令 id 的重放返回 duplicate=true 且不再转移；
##   - 余额不足的赠送被具名拒绝，序号不前进。
##
## 顺序是确定的：父进程先让乙加入并写出就绪文件，再启动甲。成员各自一个
## 进程，因为同一进程只能有一个 /root/WorldSession。
##
## 角色：--role=host、--role=member，由父进程编排。

const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const FarmState = preload("res://farm/farm_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")

const GRANT_ID: String = "gift-member"
const WORLD: String = "world-gift"
const ACTOR_ID: String = "player_00000000000000000000000000000031"
const ACTOR_NAME: String = "小满"
const WATCHER_ID: String = "player_00000000000000000000000000000032"
const WATCHER_NAME: String = "阿青"

const HARVEST_ID: String = "gift-harvest"
const GIFT_ID: String = "gift-once"
const OVER_GIFT_ID: String = "gift-over"

const TIMEOUT: float = 15.0
const HOST_LIFETIME: float = 150.0
const MEMBER_LIFETIME: float = 60.0
const START: float = 1800000000.0
## field_03/cell_06 在默认布局里直接是成熟作物，收获一篮 greens。
const FIELD: String = "field_03"
const CELL: String = "cell_06"
const CROP: String = "greens"

var role: String = "parent"
var dir: String = ""
var port: int = 0
var url: String = ""
var who: String = ""
var report_path: String = ""
var ready_path: String = ""
var stop_path: String = ""
var summarize_path: String = ""
var command_id: String = ""

var crypto := Crypto.new()
var host: WorldHost
var member: WorldMember
var checks: int = 0
var failures: Array[String] = []
var join_reason: String = ""
var lost: String = ""
var replies: Dictionary = {}
var reply_history: Dictionary = {}
var summary_count: int = 0
var auth_sent: bool = false
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
		elif argument.begins_with("--summarize="): summarize_path = argument.trim_prefix("--summarize=")
	_run.call_deferred()


func _run() -> void:
	match role:
		"host": await _run_host()
		"member": await _run_member()
		_: await _run_parent()


# ------------------------------------------------------------------ parent

func _run_parent() -> void:
	dir = _repo().path_join(".local/verification/m5-gift-%d" % Time.get_ticks_usec())
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

	# 乙先加入并确认就绪；此后甲的收获与赠送广播必然有在线接收者。
	watcher_pid = OS.create_process(_exe(), _args_for("member", [
		"--who=watcher", "--report=" + dir.path_join("watcher.json"),
		"--ready=" + dir.path_join("watcher.ready"),
		"--stop=" + dir.path_join("member.stop"),
		"--summarize=" + dir.path_join("summarize")]), false)
	_expect(watcher_pid > 0, "观察成员进程启动")
	_expect(await _wait_file(dir.path_join("watcher.ready"), 25000),
		"观察成员先加入并报告就绪")

	actor_pid = OS.create_process(_exe(), _args_for("member", [
		"--who=actor", "--report=" + dir.path_join("actor.json")]), false)
	_expect(actor_pid > 0, "执行成员进程启动")
	var actor: Dictionary = await _wait_history(dir.path_join("actor.json"),
		int((TIMEOUT + 25.0) * 1000.0))
	_expect(not actor.is_empty(), "执行成员报告结果")
	_expect(bool(actor.get("joined", false)), "执行成员已加入")
	if not actor.is_empty():
		print("M5_GIFT_ACTOR " + JSON.stringify(actor))

	var history: Dictionary = actor.get("history", {}) as Dictionary
	var harvested: Array = history.get(HARVEST_ID, []) as Array
	var gifts: Array = history.get(GIFT_ID, []) as Array
	var over: Array = history.get(OVER_GIFT_ID, []) as Array

	# (1) 收获进入甲自己的口袋；回复里就带着发送者余额。
	var harvest: Dictionary = harvested[0] as Dictionary if harvested.size() > 0 else {}
	_expect(bool(harvest.get("ok", false)), "甲的收获被权威接受")
	_expect(int(harvest.get("reward_amount", 0)) == 1, "甲恰好收获一篮")
	_expect(int((harvest.get("bags", {}) as Dictionary).get(CROP, -1)) == 1,
		"收获后甲的口袋里 greens=1")
	var harvest_sequence: int = int(harvest.get("sequence", -1))

	# (2) 赠送跨玩家转移。
	var first_gift: Dictionary = gifts[0] as Dictionary if gifts.size() > 0 else {}
	_expect(bool(first_gift.get("ok", false)), "赠送被权威接受")
	_expect(not bool(first_gift.get("duplicate", false)), "第一次赠送不是重放")
	_expect(int((first_gift.get("bags", {}) as Dictionary).get(CROP, -1)) == 0,
		"送出后甲的口袋 greens=0")
	var gift_sequence: int = int(first_gift.get("sequence", -1))
	_expect(gift_sequence == harvest_sequence + 1, "赠送推进一个事件序号")

	# (3) 同一命令 id 重放：成功但标记 duplicate，不重复转移。
	var replay: Dictionary = gifts[1] as Dictionary if gifts.size() > 1 else {}
	_expect(bool(replay.get("ok", false)), "重放返回原成功结果")
	_expect(bool(replay.get("duplicate", false)), "重放被标记为 duplicate")
	_expect(int(replay.get("sequence", -1)) == gift_sequence, "重放不推进事件序号")
	_expect(int((replay.get("bags", {}) as Dictionary).get(CROP, -1)) == 0,
		"重放后甲的口袋仍为 greens=0")

	# (4) 余额为 0 时再送一篮：具名拒绝，不产生新事件。
	var refused: Dictionary = over[0] as Dictionary if over.size() > 0 else {}
	_expect(not bool(refused.get("ok", true)), "余额不足的赠送被拒绝")
	_expect(str(refused.get("reason", "")) == "insufficient",
		"拒绝原因是 insufficient")
	_expect(int(refused.get("sequence", -1)) == gift_sequence,
		"失败的赠送不推进事件序号")

	# (5) 乙拉取最新 summary，从恢复出的 FarmState 读双方口袋。
	# 触发文件带上刚提交的序号，避免把加入时的旧 summary 当成最终状态。
	_write(dir.path_join("summarize"), str(gift_sequence))
	var watcher: Dictionary = await _wait_summary(dir.path_join("watcher.json"), 20000)
	_write(dir.path_join("member.stop"), "stop")
	await _wait_process(watcher_pid, 10000)
	if watcher_pid > 0 and OS.is_process_running(watcher_pid):
		OS.kill(watcher_pid)
		await _wait_process(watcher_pid, 5000)
	watcher = _read_json(dir.path_join("watcher.json"))
	print("M5_GIFT_WATCHER " + JSON.stringify(watcher))

	_expect(not watcher.is_empty(), "观察成员报告结果")
	_expect(bool(watcher.get("joined", false)), "观察成员保持在线")
	_expect(str(watcher.get("reason", "")) == "", "观察成员没有失去权威")
	_expect(bool(watcher.get("summary_received", false)), "观察成员收到了 summary")
	_expect(bool(watcher.get("restore_ok", false)), "观察成员从 summary 恢复了 FarmState")
	var bags: Dictionary = watcher.get("bags", {}) as Dictionary
	var actor_bag: Dictionary = bags.get("actor", {}) as Dictionary
	var watcher_bag: Dictionary = bags.get("watcher", {}) as Dictionary
	_expect(int(watcher_bag.get(CROP, -1)) == 1, "乙的口袋收到 greens=1")
	_expect(int(actor_bag.get(CROP, -1)) == 0, "甲的口袋剩余 greens=0")
	var seen: Array = watcher.get("remote_changes", []) as Array
	_expect(_has_gift_change(seen), "观察成员在线看到了赠送广播")

	# (6) 权威落盘的 farm.json 与新快照一致。
	var disk: Dictionary = FarmStore.new(dir.path_join("world")).load_state()
	_expect(bool(disk.get("ok", false)) and disk.has("farm"), "宿主的世界从磁盘重新加载")
	if disk.has("farm"):
		var restored := FarmState.new()
		_expect(restored.restore_snapshot(disk.farm), "落盘的农场快照可恢复")
		_expect(int(restored.bag(ACTOR_ID).get(CROP, -1)) == 0,
			"落盘后甲的口袋 greens=0")
		_expect(int(restored.bag(WATCHER_ID).get(CROP, -1)) == 1,
			"落盘后乙的口袋 greens=1")
	var raw: Dictionary = _read_json(dir.path_join("world/farm.json"))
	var raw_bags: Dictionary = (raw.get("farm", {}) as Dictionary).get("bags", {}) as Dictionary
	var raw_actor: Dictionary = raw_bags.get(ACTOR_ID, {}) as Dictionary
	var raw_watcher: Dictionary = raw_bags.get(WATCHER_ID, {}) as Dictionary
	# JSON 往返会把整数变成浮点，比较前统一归一化。
	_expect(int(raw_actor.get(CROP, -1)) == 0, "farm.json 里甲的口袋 greens=0")
	_expect(int(raw_watcher.get(CROP, -1)) == 1, "farm.json 里乙的口袋 greens=1")

	await _cleanup()
	_finish()


func _has_gift_change(changes: Array) -> bool:
	for entry: Variant in changes:
		if entry is Dictionary:
			var command: Dictionary = (entry as Dictionary).get("command", {}) as Dictionary
			if str(command.get("kind", "")) == FarmCommand.GIFT \
					and str((entry as Dictionary).get("from_id", "")) == ACTOR_ID:
				return true
	return false


## 等到执行成员写出完整报告（含 history），避免读到半截 JSON。
func _wait_history(path: String, timeout_ms: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var parsed: Dictionary = _read_json(path)
		if bool(parsed.get("done", false)):
			return parsed
		await create_timer(0.05).timeout
	return _read_json(path)


## 等到观察成员报告 summary_received=true 且已带有恢复出的口袋。
func _wait_summary(path: String, timeout_ms: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var parsed: Dictionary = _read_json(path)
		if bool(parsed.get("done", false)) and bool(parsed.get("summary_received", false)) \
				and parsed.has("bags"):
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
	member.display_name = ACTOR_NAME if who == "actor" else WATCHER_NAME
	root.add_child(member)
	root.multiplayer.auth_callback = _member_auth
	member.join_failed.connect(func(reason: String) -> void: join_reason = reason)
	member.authority_lost.connect(func(reason: String) -> void: lost = reason)
	member.reply_received.connect(_on_reply)
	member.remote_change.connect(_on_remote_change)
	member.connect_to(url, secret, WORLD)

	if who == "watcher":
		await _watch()
	else:
		await _act()
	# done 标记最后才写，父进程不会把中间状态的报告当成最终结果。
	_write_report(true)
	quit(0)


## 甲：收获一次 → 赠送一次 → 同 id 重放 → 余额不足的新赠送。
func _act() -> void:
	var steps: Array[Dictionary] = [
		{"id": HARVEST_ID, "command": FarmCommand.make(HARVEST_ID, FIELD, CELL, START)},
		{"id": GIFT_ID, "command": FarmCommand.make_gift(GIFT_ID, WATCHER_ID, CROP, 1, START)},
		{"id": GIFT_ID, "command": FarmCommand.make_gift(GIFT_ID, WATCHER_ID, CROP, 1, START)},
		{"id": OVER_GIFT_ID, "command": FarmCommand.make_gift(OVER_GIFT_ID, WATCHER_ID, CROP, 1, START)},
	]
	# 第 2 步复用同一个命令 id，所以要等第二个同 id 回复才算重放完成。
	var needed: Array[int] = [1, 1, 2, 1]
	var started: bool = false
	var step: int = 0
	var deadline: int = Time.get_ticks_msec() + int(MEMBER_LIFETIME * 1000.0)
	while Time.get_ticks_msec() < deadline:
		_maybe_send_auth()
		if not started and member.is_joined():
			started = true
			member.submit_command(steps[0].command)
		if started and step < steps.size() \
				and _history(str(steps[step].id)).size() >= needed[step]:
			step += 1
			if step < steps.size():
				member.submit_command(steps[step].command)
		if step >= steps.size():
			await create_timer(0.3).timeout
			break
		if not join_reason.is_empty() or not lost.is_empty():
			await create_timer(0.2).timeout
			break
		await create_timer(0.05).timeout


## 乙：保持在线，收到 summarize 触发后拉取一次 summary，再报告恢复出的口袋。
func _watch() -> void:
	var started: bool = false
	var ready_written: bool = false
	var summary_requested: bool = false
	var expected_sequence: int = -1
	var deadline: int = Time.get_ticks_msec() + int(MEMBER_LIFETIME * 1000.0)
	while Time.get_ticks_msec() < deadline:
		_maybe_send_auth()
		if not started and member.is_joined():
			started = true
		if member.is_joined() and not ready_written:
			ready_written = true
			if not ready_path.is_empty():
				_write(ready_path, "ready")
			_write_report()
		if not summarize_path.is_empty() and FileAccess.file_exists(summarize_path) \
				and not summary_requested:
			summary_requested = true
			expected_sequence = FileAccess.get_file_as_string(summarize_path).strip_edges().to_int()
			# request_summary() 只是本地 RPC 桩，必须用 rpc_id 才会真正发往权威。
			member.request_summary.rpc_id(1)
		if summary_requested and _summary_sequence() >= expected_sequence:
			# 让 summary 的应用与报告写入完成后再退出。
			await create_timer(0.1).timeout
			break
		if not stop_path.is_empty() and FileAccess.file_exists(stop_path):
			break
		if not join_reason.is_empty() or not lost.is_empty():
			await create_timer(0.2).timeout
			break
		await create_timer(0.05).timeout


## 最近一次 summary 的权威序号；加入时自动拉取的那份通常比触发请求更早。
func _summary_sequence() -> int:
	var history: Array = _history("summary")
	if history.is_empty():
		return -1
	return int((history[-1] as Dictionary).get("committed_sequence", -1))


## 传输层一旦连上就发起邀请证明；不发送的话宿主会一直等待认证并最终断开。
func _maybe_send_auth() -> void:
	if auth_sent or member == null:
		return
	var peer_state: MultiplayerPeer = root.multiplayer.multiplayer_peer as MultiplayerPeer
	if peer_state == null or peer_state.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	auth_sent = true
	root.multiplayer.send_auth(1, member.auth_hello())


func _on_reply(request_id: String, payload: Dictionary) -> void:
	replies[request_id] = payload
	if not reply_history.has(request_id):
		reply_history[request_id] = []
	(reply_history[request_id] as Array).append(payload)
	if request_id == "summary":
		summary_count += 1
	_write_report()


func _history(id: String) -> Array:
	return reply_history.get(id, []) as Array


func _on_remote_change(entry: Dictionary) -> void:
	remote_changes.append(entry)
	_write_report()


func _write_report(done: bool = false) -> void:
	if report_path.is_empty() or member == null:
		return
	var restored: Dictionary = member.restore_state()
	var bags: Dictionary = {}
	if bool(restored.get("ok", false)):
		var farm: FarmState = restored.farm
		bags = {
			"actor": farm.bag(ACTOR_ID),
			"watcher": farm.bag(WATCHER_ID),
		}
	_write(report_path, JSON.stringify({
		"done": done,
		"joined": member.is_joined(),
		"reason": join_reason if not join_reason.is_empty() else lost,
		"history": reply_history,
		"summary_received": replies.has("summary") and summary_count > 0,
		"restore_ok": bool(restored.get("ok", false)),
		"bags": bags,
		"last_sequence": member.last_sequence,
		"remote_changes": remote_changes,
	}))


func _report_with_reason(reason: String) -> void:
	if not report_path.is_empty():
		_write(report_path, JSON.stringify({
			"joined": false, "reason": reason, "history": {}, "summary_received": false,
			"restore_ok": false, "bags": {}, "remote_changes": []}))
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
		"--script", _repo().path_join("tests/m5_gift_test.gd"),
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
	print("M5_GIFT_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
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
