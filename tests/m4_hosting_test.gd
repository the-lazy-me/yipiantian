extends SceneTree
## M4-05 切片：由游戏自己开一间房。
##
## 桌面客户端不能在同一进程里既当权威又当玩家（一个树只有一个
## SceneMultiplayer），所以“建房”= 启动一个无头权威子进程，等它写出状态
## 文件，再把它的邀请、证书和端点拼成加入码。这里验证这条真实链路：子进程
## 真的起来了、加入码能解析、客户端能带着这张码进世界、停止后进程真的退出。

const WorldHosting = preload("res://world/world_hosting.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const WorldClient = preload("res://world/world_client.gd")

const WORLD: String = "world-hosting"
const PLAYER: String = "player_00000000000000000000000000000009"
const NAME: String = "阿青"

var checks: int = 0
var failures: Array[String] = []
var hosting: WorldHosting
var client: WorldClient
var state: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var base: String = ProjectSettings.globalize_path("user://").path_join(
		"hosting_test_%d" % Time.get_ticks_usec())
	DirAccess.remove_absolute(base)

	hosting = WorldHosting.new()
	_expect(not bool(hosting.start("relative/dir", WORLD, 21000).get("ok", false)),
		"A relative data directory is refused instead of guessed")
	_expect(not bool(hosting.start(base, WORLD, 0).get("ok", false)),
		"Port 0 is refused because nobody could address the room")
	_expect(str(hosting.poll().get("reason", "")) == "not_started",
		"Polling before starting says nothing is running")
	var started: Dictionary = hosting.start(base, WORLD, _free_port())
	_expect(bool(started.get("ok", false)), "A host starts on a LAN address")
	var ready: Dictionary = await _await_ready(40.0)
	_expect(bool(ready.get("ok", false)), "The authority reports running (reason=%s)"
		% str(ready.get("reason", "")))
	if not bool(ready.get("ok", false)):
		hosting.stop()
		_finish()
		return

	var code: String = str(ready.get("join_code", ""))
	var url: String = str(ready.get("url", ""))
	_expect(not code.is_empty(), "The room produces a join code")
	_expect(url.begins_with("wss://"), "The room is only offered over WSS")
	var host: String = url.trim_prefix("wss://").get_slice(":", 0)
	_expect(host.begins_with("127.") or host.begins_with("192.168.") or host.begins_with("10.")
		or host.begins_with("172."), "The room offers a loopback or private LAN address, not 0.0.0.0")

	var decoded: Dictionary = WorldJoinCode.decode(code)
	_expect(bool(decoded.get("ok", false)), "The produced code parses")
	_expect(str(decoded.get("url", "")) == url, "The code carries the room's address")
	var grant: Dictionary = decoded.get("grant", {}) as Dictionary
	_expect(str(grant.get("world_id", "")) == WORLD, "The code carries the room's world id")
	_expect(WorldJoinCode.tls_options(str(decoded.get("certificate", "")),
		str(decoded.get("server_name", ""))) != null,
		"The pinned certificate in the code is usable for TLS")

	for name: String in [WorldHosting.STATUS_FILE, WorldHosting.INVITE_FILE,
			WorldHosting.CERT_FILE]:
		_expect(FileAccess.file_exists(base.path_join(name)),
			"The room wrote %s" % name)
	var status: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(base.path_join(WorldHosting.STATUS_FILE))) as Dictionary
	_expect(str(status.get("state", "")) == "running", "The status file says running")
	_expect(int(status.get("port", 0)) == hosting.port, "The status file names the port")
	_expect(int(status.get("pid", 0)) == hosting.pid, "The status file names the authority process")
	_expect(hosting.is_running(), "The authority process is alive")

	# Join the room with exactly what the host would share.
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(farm: RefCounted, decorations: RefCounted, now_utc: float):
		state = {"farm": farm, "decorations": decorations, "now": now_utc})
	client.refused.connect(func(reason: String) -> void: state = {"refused": reason})
	client.lost.connect(func(reason: String) -> void: state = {"lost": reason})
	_expect(client.start(code, PLAYER, NAME), "The client accepts the room's join code")
	var joined: bool = await _await_state(25.0, "farm")
	_expect(joined, "The client receives the room's farm%s" % ("" if joined else
		" (got %s)" % str(state.get("lost", state.get("refused", "nothing")))))
	_expect(joined and float(state.get("now", 0.0)) > 0.0,
		"The room has a world clock, so it is really running")

	hosting.stop()
	_expect(not hosting.is_running(), "Stopping the room ends the authority process")
	_expect(hosting.pid == 0, "A stopped room has no process to stop twice")
	var after: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(base.path_join(WorldHosting.STATUS_FILE))) as Dictionary
	_expect(str(after.get("state", "")) == "stopped",
		"The authority records a clean stop, not a crash")

	if client != null:
		client.close()
	DirAccess.remove_absolute(base.path_join(WorldHosting.STOP_FILE))
	_finish()


## The first free-ish port in the ephemeral range. A room that fails to bind is
## retried once, because another process may have taken the guess.
func _free_port() -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = Time.get_ticks_usec()
	for attempt: int in 8:
		var port: int = rng.randi_range(20000, 45000)
		var probe := TCPServer.new()
		if probe.listen(port, "127.0.0.1") == OK:
			probe.stop()
			return port
	return 20000 + rng.randi_range(0, 999)


func _await_ready(seconds: float) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var answer: Dictionary = hosting.poll()
		if bool(answer.get("ok", false)) or not str(answer.get("reason", "")).is_empty() \
				and str(answer.get("reason", "")) != "pending":
			return answer
		await create_timer(0.2).timeout
	return hosting.poll()


func _await_state(seconds: float, key: String) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if state.has(key):
			return true
		await create_timer(0.1).timeout
	return false


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("M4_HOSTING_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
