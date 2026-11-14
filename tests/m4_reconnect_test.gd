extends SceneTree
## M4 断线自动重连切片。
##
## 真实链路：启动 world_server.gd 子进程，WorldClient 用加入码进世界并提交一次
## 收获与一次建造；写 stop 文件让服务器干净退出，断言客户端进入 reconnecting 而不是永久
## lost；随后在相同端口、相同数据目录重启服务器，断言客户端 40 秒内 reconnected
## 且用权威快照整份校正本地，序号、收获记录与住宅与落盘的 farm.json 一致。

const WorldClient = preload("res://world/world_client.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const FarmState = preload("res://farm/farm_state.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const WORLD: String = "world-reconnect"
const PLAYER: String = "player_00000000000000000000000000000011"
const NAME: String = "阿青"

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var checks: int = 0
var failures: Array[String] = []
var client: WorldClient
var state: Dictionary = {}
var state_count: int = 0
var reconnect_events: Array[Dictionary] = []
var reconnected_sequences: Array[int] = []
var lost_reasons: Array[String] = []
var committed_replies: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(".local/verification/m4-reconnect-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if port <= 0:
		_finish()
		return

	server_pid = _start_server()
	_expect(server_pid > 0, "The authority process starts")
	if server_pid <= 0:
		_finish()
		return
	var running: bool = await _wait_for_status("running", 20000)
	_expect(running, "The authority is serving the world")
	if not running:
		_finish()
		return

	var code: String = _join_code()
	_expect(code.begins_with(WorldJoinCode.PREFIX),
		"A join code is built from what the host created")

	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(_on_state_ready)
	client.refused.connect(_on_refused)
	client.lost.connect(_on_lost)
	client.reconnecting.connect(_on_reconnecting)
	client.reconnected.connect(_on_reconnected)
	client.committed.connect(_on_committed)
	_expect(client.start(code, PLAYER, NAME), "The client accepts the join code")
	var joined: bool = await _wait(func() -> bool:
		return state.has("farm") or not lost_reasons.is_empty(), 25000)
	_expect(joined and state.has("farm"), "The client receives the authoritative world%s"
		% ("" if state.has("farm") else " (got %s)" % str(lost_reasons)))
	if not state.has("farm"):
		_finish()
		return

	# 让权威状态前进一次：重连校正后的序号和收获记录必须与落盘一致。
	var command: Dictionary = FarmCommand.make("reconnect-%d" % Time.get_ticks_usec(),
		"field_03", "cell_06", client.world_time())
	_expect(client.submit(command), "The client submits a harvest to the authority")
	var answered: bool = await _wait(func() -> bool: return not committed_replies.is_empty(), 10000)
	var reply: Dictionary = {}
	if not committed_replies.is_empty():
		reply = committed_replies[0].get("reply", {}) as Dictionary
	_expect(answered and bool(reply.get("ok", false)),
		"The authority commits the harvest (reply=%s)" % JSON.stringify(reply))
	if not bool(reply.get("ok", false)):
		_finish()
		return

	# 建造也走同一条权威通道；干净停机与重连后住宅必须原样还在。
	var build: Dictionary = FarmCommand.make_build("build-%d" % Time.get_ticks_usec(),
		"yard_a", "cottage", client.world_time())
	_expect(client.submit(build), "The client submits a build to the authority")
	var built: bool = await _wait(func() -> bool: return committed_replies.size() >= 2, 10000)
	var build_reply: Dictionary = {}
	if committed_replies.size() >= 2:
		build_reply = committed_replies[1].get("reply", {}) as Dictionary
	_expect(built and bool(build_reply.get("ok", false)),
		"The authority commits the build (reply=%s)" % JSON.stringify(build_reply))
	if not bool(build_reply.get("ok", false)):
		_finish()
		return

	# 干净停机后来自服务器的落盘是重连要对齐的权威状态。
	var stopped_pid: int = server_pid
	await _stop_server()
	_expect(not OS.is_process_running(stopped_pid), "Stopping the room ends the authority process")
	var saved: Dictionary = _read_json(world_dir.path_join("farm.json"))
	var persisted_farm: Dictionary = saved.get("farm", {}) as Dictionary
	# 落盘的 JSON 会把整数读成浮点；先走与客户端相同的恢复路径归一化，再逐项
	# 比较，否则差异只是类型而不是世界状态。
	var persisted_state := FarmState.new()
	var restorable: bool = persisted_state.restore_snapshot(persisted_farm)
	_expect(restorable, "The stopped authority wrote a restorable world")
	var persisted_snapshot: Dictionary = persisted_state.snapshot() if restorable else persisted_farm
	var persisted_sequence: int = int(
		(persisted_snapshot.get("transaction", {}) as Dictionary).get("sequence", -1))
	var persisted_harvested: Dictionary = persisted_snapshot.get("harvested", {}) as Dictionary
	_expect(persisted_sequence >= 1 and int(persisted_harvested.get("greens", 0)) == 1,
		"The authority persisted the harvest (sequence=%d)" % persisted_sequence)
	var persisted_buildings: Dictionary = persisted_snapshot.get("buildings", {}) as Dictionary
	_expect(persisted_buildings.has("yard_a")
		and str((persisted_buildings.get("yard_a", {}) as Dictionary).get("blueprint", "")) == "cottage",
		"The authority persisted the build (buildings=%s)" % JSON.stringify(persisted_buildings))

	# 客户端应当自动进入重连，而不是永久 lost。
	var retrying: bool = await _wait(func() -> bool: return not reconnect_events.is_empty(), 15000)
	_expect(retrying, "The client starts reconnecting after the authority disappears%s"
		% ("" if retrying else " (lost=%s)" % str(lost_reasons)))
	_expect(lost_reasons.is_empty(), "A transient disconnect is not a permanent loss")
	if not reconnect_events.is_empty():
		var first: Dictionary = reconnect_events[0]
		_expect(int(first.get("attempt", 0)) == 1 and is_equal_approx(float(first.get("delay", 0.0)), 1.0),
			"The first retry waits one second (got %s)" % str(first))
	if not retrying:
		_finish()
		return

	# 在相同端口、相同数据目录重启，邀请与证书都从盘上复用。
	await create_timer(0.3).timeout
	server_pid = _start_server()
	_expect(server_pid > 0, "The authority restarts on the same port")
	var restarted: bool = await _wait_for_status("running", 20000)
	_expect(restarted, "The restarted authority serves the same world")
	if not restarted:
		_finish()
		return

	var reconnected: bool = await _wait(func() -> bool: return not reconnected_sequences.is_empty(), 40000)
	_expect(reconnected, "The client reconnects within the backoff window (events=%s)"
		% str(reconnect_events))
	_expect(reconnected and int(reconnected_sequences[0]) == persisted_sequence,
		"The reconnect reports the persisted sequence (got %s, expected %d)"
		% [str(reconnected_sequences), persisted_sequence])
	_expect(state_count >= 2, "The reconnect delivers a fresh authoritative summary")
	_expect(lost_reasons.is_empty(), "The reconnect never emits a permanent loss")

	if state.has("farm"):
		var after: Dictionary = state.farm.snapshot()
		var after_sequence: int = int(
			(after.get("transaction", {}) as Dictionary).get("sequence", -1))
		var after_harvested: Dictionary = after.get("harvested", {}) as Dictionary
		_expect(after_sequence == persisted_sequence,
			"The corrected world keeps the authoritative sequence (got %d, expected %d)"
			% [after_sequence, persisted_sequence])
		_expect(int(after_harvested.get("greens", 0)) == int(persisted_harvested.get("greens", -1)),
			"The corrected world keeps the persisted harvest")
		_expect(after.get("layout") == persisted_snapshot.get("layout"),
			"The corrected world keeps the persisted courtyard")
		_expect(after.get("inventory") == persisted_snapshot.get("inventory"),
			"The corrected world keeps the persisted inventory")
		_expect(after.get("buildings") == persisted_snapshot.get("buildings"),
			"The corrected world keeps the persisted housing")
	else:
		_expect(false, "The reconnected client has farm state to compare")

	# 初次加入就被拒时不能进入无限重试：同一张码重试不会得到不同答案，原因
	# 必须立刻交回调用方。用一个秘密不对的加入码验证这条边界。
	client.close()
	client.queue_free()
	client = null
	await process_frame
	await process_frame
	var bad: WorldClient = WorldClient.new()
	bad.name = "BadClient"
	root.add_child(bad)
	var refusals: Array[String] = []
	var bad_retries: Array = []
	bad.refused.connect(func(reason: String) -> void: refusals.append(reason))
	bad.lost.connect(func(reason: String) -> void: refusals.append("lost:" + reason))
	bad.reconnecting.connect(func(attempt: int, _delay: float) -> void: bad_retries.append(attempt))
	var parsed: Dictionary = WorldJoinCode.decode(_join_code())
	var bogus: Dictionary = WorldInvite.make("server-invite",
		Crypto.new().generate_random_bytes(32), WorldInvite.MEMBER, WORLD, 0.0, false)
	var bad_code: String = WorldJoinCode.encode(bogus, str(parsed.get("url", "")),
		str(parsed.get("certificate", "")), str(parsed.get("server_name", "")))
	_expect(bad.start(bad_code, "", ""), "A code with the wrong secret still dials")
	var refused_seen: bool = await _wait(func() -> bool: return not refusals.is_empty(), 15000)
	_expect(refused_seen, "A first join with the wrong secret is refused, not retried (got %s)"
		% str(refusals))
	await create_timer(3.0).timeout
	_expect(bad_retries.is_empty(), "A refused first join does not queue retries")
	bad.close()
	bad.queue_free()
	await process_frame

	await _stop_server()
	_finish()


# ------------------------------------------------------------------ callbacks

func _on_state_ready(farm: RefCounted, decorations: RefCounted, now_utc: float) -> void:
	state = {"farm": farm, "decorations": decorations, "now_utc": now_utc}
	state_count += 1


func _on_refused(reason: String) -> void:
	lost_reasons.append("refused:" + reason)


func _on_lost(reason: String) -> void:
	lost_reasons.append(reason)


func _on_reconnecting(attempt: int, delay: float) -> void:
	reconnect_events.append({"attempt": attempt, "delay": delay})


func _on_reconnected(sequence: int) -> void:
	reconnected_sequences.append(sequence)


func _on_committed(request_id: String, reply: Dictionary) -> void:
	committed_replies.append({"id": request_id, "reply": reply})


# ------------------------------------------------------------------ server

func _start_server() -> int:
	var args := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--run-seconds=0",
	])
	return OS.create_process(OS.get_executable_path(), args, false)


func _stop_server() -> void:
	if server_pid <= 0:
		return
	var marker := FileAccess.open(world_dir.path_join("stop"), FileAccess.WRITE)
	if marker != null:
		marker.store_string("stop")
		marker.close()
	var deadline: int = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline and OS.is_process_running(server_pid):
		await create_timer(0.05).timeout
	server_pid = 0


func _wait_for_status(expected: String, timeout_ms: int) -> bool:
	return await _wait(func() -> bool:
		return str(_read_json(world_dir.path_join("server-status.json")).get("state", "")) == expected,
		timeout_ms)


func _join_code() -> String:
	var invite_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		world_dir.path_join("invite.bin"))
	var grant: Dictionary = WorldInvite.make("server-invite", invite_bytes,
		WorldInvite.MEMBER, WORLD, 0.0, false)
	var pem: String = FileAccess.get_file_as_bytes(
		world_dir.path_join("server.crt")).get_string_from_ascii()
	return WorldJoinCode.encode(grant, "wss://127.0.0.1:%d" % port, pem, "localhost")


# ------------------------------------------------------------------ helpers

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
	if client != null:
		client.close()
		client = null
	if server_pid > 0 and OS.is_process_running(server_pid):
		OS.kill(server_pid)
	server_pid = 0
	_remove_tree(dir)
	for failure: String in failures:
		push_error(failure)
	print("M4_RECONNECT_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _remove_tree(path: String) -> void:
	if path.is_empty():
		return
	var listing := DirAccess.open(path)
	if listing == null:
		return
	listing.list_dir_begin()
	var entry: String = listing.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var full: String = path.path_join(entry)
			if listing.current_is_dir():
				_remove_tree(full)
			else:
				DirAccess.remove_absolute(full)
		entry = listing.get_next()
	listing.list_dir_end()
	DirAccess.remove_absolute(path)
