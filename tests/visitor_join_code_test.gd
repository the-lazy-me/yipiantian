extends SceneTree
## A room hands out two credentials: the member code and a care-only visitor
## code produced by the authority itself. The desktop never receives the invite
## secret to derive or assemble the visitor grant; it reads the finished code
## from the room directory.
##
## The two joins are sequential, not simultaneous: SceneMultiplayer is one per
## SceneTree, and M4-06 records that limit. Joining as a member first and then as
## a visitor on the same running authority proves each code still resolves to its
## own grant instead of one overwriting the other.

const WorldHosting = preload("res://world/world_hosting.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldClient = preload("res://world/world_client.gd")

const WORLD: String = "world-visitor-code"
const MEMBER_PLAYER: String = "player_0000000000000000000000000000000a"
const VISITOR_PLAYER: String = "player_0000000000000000000000000000000b"

var checks: int = 0
var failures: Array[String] = []
var hosting: WorldHosting
var base: String = ""
var state: Dictionary = {}
var client: WorldClient


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	base = ProjectSettings.globalize_path("user://").path_join(
		"visitor_code_test_%d" % Time.get_ticks_usec())
	DirAccess.remove_absolute(base)
	hosting = WorldHosting.new()
	var started: Dictionary = hosting.start(base, WORLD, _free_port())
	_expect(bool(started.get("ok", false)), "A room starts on a LAN address")
	var ready: Dictionary = await _await_ready(40.0)
	_expect(bool(ready.get("ok", false)), "The authority reports running (reason=%s)"
		% str(ready.get("reason", "")))
	if not bool(ready.get("ok", false)):
		await _cleanup()
		_finish()
		return

	var member_code: String = str(ready.get("join_code", ""))
	var visitor_code: String = str(ready.get("visitor_join_code", ""))
	_expect(not member_code.is_empty(), "The room produces a member code")
	_expect(not visitor_code.is_empty(), "The room also produces a visitor code")
	if member_code.is_empty() or visitor_code.is_empty():
		await _cleanup()
		_finish()
		return

	var member: Dictionary = WorldJoinCode.decode(member_code)
	var visitor: Dictionary = WorldJoinCode.decode(visitor_code)
	_expect(bool(member.get("ok", false)), "The member code parses")
	_expect(bool(visitor.get("ok", false)), "The visitor code parses")
	if not bool(member.get("ok", false)) or not bool(visitor.get("ok", false)):
		await _cleanup()
		_finish()
		return
	var member_grant: Dictionary = member.grant
	var visitor_grant: Dictionary = visitor.grant
	_expect(str(member_grant.role) == WorldInvite.MEMBER, "The first code names the member role")
	_expect(str(visitor_grant.role) == WorldInvite.VISITOR, "The second code names the visitor role")
	_expect(str(member_grant.id) != str(visitor_grant.id), "The two grants have separate ids")
	_expect(member_grant.secret != visitor_grant.secret, "The two grants have separate secrets")
	_expect(str(visitor_grant.world_id) == WORLD, "The visitor code belongs to this world")
	_expect(str(member.get("url", "")) == str(visitor.get("url", "")),
		"Both codes point at the same room")
	_expect(str(member.get("certificate", "")) == str(visitor.get("certificate", "")),
		"Both codes pin the same certificate")

	_expect(WorldInvite.allows(str(visitor_grant.role), "water")
		and WorldInvite.allows(str(visitor_grant.role), "weed"),
		"The visitor grant covers watering and weeding")
	for kind: String in ["harvest", "sow", "till", "build"]:
		_expect(not WorldInvite.allows(str(visitor_grant.role), kind),
			"The visitor grant does not cover %s" % kind)
	_expect(WorldInvite.check_usable(visitor_grant,
		Time.get_unix_time_from_system() + 31536000.0, 3).ok,
		"The visitor grant is reusable and does not expire")

	# Member first, then visitor, on the same running authority.
	var member_seen: String = await _join(member_code, MEMBER_PLAYER, "阿青")
	_expect(member_seen == WorldInvite.MEMBER,
		"The member code still admits a member after the visitor grant was registered")
	await _close_client()
	# Let the authority process the disconnect and this tree free the old
	# session node before the second client takes the fixed /root/WorldSession path.
	await create_timer(0.3).timeout
	var visitor_seen: String = await _join(visitor_code, VISITOR_PLAYER, "小禾")
	_expect(visitor_seen == WorldInvite.VISITOR,
		"The visitor code admits its holder as a visitor")
	_expect(member_seen == WorldInvite.MEMBER and visitor_seen == WorldInvite.VISITOR,
		"One room admits both codes without either grant overwriting the other")

	await _cleanup()

	# A room may have no visitor code (an older writer, a write failure, or a
	# self-hosted server started without --join-url). That is not a failed room:
	# the member code and the entrance must survive on their own.
	var optional_dir: String = base + "-optional"
	_write_room_without_visitor(optional_dir)
	var optional := WorldHosting.new()
	optional.data_directory = optional_dir
	optional.world_id = WORLD
	optional.port = 34567
	optional.pid = OS.get_process_id()
	var without_visitor: Dictionary = optional.poll()
	_expect(bool(without_visitor.get("ok", false)),
		"A room without a visitor code still reports ready")
	_expect(str(without_visitor.get("visitor_join_code", "missing")) == "",
		"A missing visitor code is an empty value, not a failure")
	_expect(str(without_visitor.get("join_code", "")).begins_with(WorldJoinCode.PREFIX),
		"The member code is still produced without a visitor code")
	var broken := FileAccess.open(optional_dir.path_join(WorldHosting.VISITOR_CODE_FILE),
		FileAccess.WRITE)
	broken.store_string("not a join code")
	broken.close()
	var with_broken_visitor: Dictionary = optional.poll()
	_expect(bool(with_broken_visitor.get("ok", false))
		and str(with_broken_visitor.get("visitor_join_code", "missing")) == "",
		"An unreadable visitor code is ignored instead of failing the room")

	# Starting the authority without --join-url must not write a visitor code at
	# all; the desktop's optional handling above covers reading that directory.
	var no_url_dir: String = base + "-no-url"
	var ran: bool = await _run_server_without_join_url(no_url_dir)
	_expect(ran, "A self-hosted server starts without --join-url")
	_expect(not FileAccess.file_exists(no_url_dir.path_join(WorldHosting.VISITOR_CODE_FILE)),
		"Without --join-url no visitor code file is written")

	_finish()


## Connects with one code and returns the role the authority actually granted,
## or "" when the join never produced a first authoritative state.
func _join(code: String, player_id: String, player_name: String) -> String:
	state = {}
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
			_now_utc: float) -> void: state = {"ready": true})
	client.refused.connect(func(reason: String) -> void: state = {"refused": reason})
	client.lost.connect(func(reason: String) -> void: state = {"lost": reason})
	if not client.start(code, player_id, player_name):
		return ""
	var deadline: int = Time.get_ticks_msec() + 25000
	while Time.get_ticks_msec() < deadline and state.is_empty():
		await create_timer(0.1).timeout
	if not bool(state.get("ready", false)):
		return ""
	return str(client.member.role)


func _close_client() -> void:
	if client != null:
		client.close()
		client.queue_free()
		client = null
	await process_frame
	await process_frame


## A room directory that is running but was not given --join-url: certificate,
## invite and status exist, the visitor code does not.
func _write_room_without_visitor(directory: String) -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	var crypto := Crypto.new()
	var key: CryptoKey = crypto.generate_rsa(2048)
	var certificate: X509Certificate = crypto.generate_self_signed_certificate(
		key, "CN=localhost,O=farm,C=CN")
	# `save()` writes the PEM form, which is what the server entry and poll() use.
	certificate.save(directory.path_join(WorldHosting.CERT_FILE))
	var invite_file := FileAccess.open(directory.path_join(WorldHosting.INVITE_FILE), FileAccess.WRITE)
	invite_file.store_buffer(crypto.generate_random_bytes(32))
	invite_file.close()
	var status_file := FileAccess.open(directory.path_join(WorldHosting.STATUS_FILE), FileAccess.WRITE)
	status_file.store_string(JSON.stringify({"state": "running", "port": 34567,
		"pid": OS.get_process_id()}))
	status_file.close()


## Runs the real authority entry without --join-url until it saves and exits.
func _run_server_without_join_url(directory: String) -> bool:
	DirAccess.make_dir_recursive_absolute(directory)
	var game: String = ProjectSettings.globalize_path("res://").trim_suffix("/")
	var script: String = game.get_base_dir().path_join("Game/world/world_server.gd")
	var pid: int = OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", game, "--script", script, "--",
		"--data-dir=" + directory, "--port=%d" % _free_port(), "--world=" + WORLD,
		"--run-seconds=2",
	]), false)
	if pid <= 0:
		return false
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline and OS.is_process_running(pid):
		await create_timer(0.1).timeout
	if OS.is_process_running(pid):
		OS.kill(pid)
		return false
	return true


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


func _cleanup() -> void:
	await _close_client()
	if hosting != null:
		hosting.stop()
		hosting = null
	await create_timer(0.2).timeout


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("VISITOR_JOIN_CODE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
