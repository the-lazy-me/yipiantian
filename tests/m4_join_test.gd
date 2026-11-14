extends SceneTree
## M4-02 prototype: a real authoritative host plus a real member client over
## loopback WSS, with the two gates (invite HMAC, then protocol/rules/world
## join). Proves accepted commands reach the stored world exactly once, and
## that version/world mismatches are refused with a named reason.
##
## Roles are separate processes because SceneMultiplayer/RPC is per SceneTree:
## --role=host, --role=member. The parent orchestrates and asserts.

const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const FarmStore = preload("res://farm/farm_store.gd")

const TIMEOUT: float = 15.0
const HOST_LIFETIME: float = 120.0
const START: float = 1800000000.0

var role: String = "parent"
var dir: String = ""
var port: int = 0
var url: String = ""
var cn: String = ""
var report_path: String = ""
var invite: bool = false
var world: String = ""
var badge: String = ""
var version: int = 1

var crypto := Crypto.new()
var host: WorldHost
var member: WorldMember
var checks: int = 0
var failures: Array[String] = []
var joined_state: Dictionary = {}
var replies: Dictionary = {}
var join_reason: String = ""
var lost: String = ""
var summary: Dictionary = {}


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--dir="): dir = argument.trim_prefix("--dir=")
		elif argument.begins_with("--port="): port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--url="): url = argument.trim_prefix("--url=")
		elif argument.begins_with("--cn="): cn = argument.trim_prefix("--cn=")
		elif argument.begins_with("--report="): report_path = argument.trim_prefix("--report=")
		elif argument.begins_with("--world="): world = argument.trim_prefix("--world=")
		elif argument.begins_with("--badge="): badge = argument.trim_prefix("--badge=")
		elif argument.begins_with("--version="): version = argument.trim_prefix("--version=").to_int()
		elif argument == "--invite": invite = true
	_run.call_deferred()


func _run() -> void:
	match role:
		"host": await _run_host()
		"member": await _run_member()
		_: await _run_parent()


# ------------------------------------------------------------------ parent

func _run_parent() -> void:
	dir = _repo().path_join(".local/verification/m4-join-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var key: CryptoKey = crypto.generate_rsa(2048)
	_expect(key != null, "World RSA key generates")
	var cert: X509Certificate = crypto.generate_self_signed_certificate(
		key, "CN=localhost,O=farm,C=CN")
	_expect(cert != null and key.save(dir.path_join("server.key")) == OK
		and cert.save(dir.path_join("server.crt")) == OK, "Server key and certificate are written")
	var secret: PackedByteArray = crypto.generate_random_bytes(32)
	var invite_file := FileAccess.open(dir.path_join("invite.bin"), FileAccess.WRITE)
	_expect(invite_file != null, "Invite secret is written")
	if invite_file != null:
		invite_file.store_buffer(secret)
		invite_file.close()
	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if not failures.is_empty():
		_finish()
		return

	var host_pid: int = OS.create_process(_exe(), _child("host", [
		"--world=world-alpha", "--port=%d" % port]), false)
	_expect(host_pid > 0, "Host process starts")
	if host_pid <= 0:
		_finish()
		return
	if not await _wait_file(dir.path_join("host.ready"), 25000):
		_expect(false, "Host reports ready")
		_finish()
		return
	var host_world: String = _read_text(dir.path_join("host.world"))
	_expect(not host_world.is_empty(), "Host publishes its world identity")

	# 1. A correct join: same protocol, rules and world.
	var good: Dictionary = await _member("joined", [
		"--invite", "--url=wss://127.0.0.1:%d" % port, "--cn=localhost",
		"--world=" + host_world])
	_expect(bool(good.get("joined", false)), "A matching client joins the world")
	_expect(str(good.get("world_seen", "")) == host_world,
		"The client reports the host's world identity")
	var first_reply: Dictionary = good.get("first_reply", {}) as Dictionary
	_expect(bool(first_reply.get("ok", false)), "The joined client's command is accepted")
	_expect(int(first_reply.get("sequence", 0)) == 1, "The command advanced the stored sequence once")
	_expect(int(good.get("replay_sequence", -1)) == 1,
		"Retrying the same command id replays without a second advance")
	_expect(bool(good.get("replay_duplicate", false)), "The retry is reported as a duplicate")

	# 2. Wrong world identity.
	var wrong_world: Dictionary = await _member("wrong-world", [
		"--invite", "--url=wss://127.0.0.1:%d" % port, "--cn=localhost",
		"--world=other-world"])
	_expect(not bool(wrong_world.get("joined", false)), "A client naming another world is refused")
	_expect(str(wrong_world.get("reason", "")) == "world_mismatch",
		"The refusal names the world mismatch")

	# 3. Wrong protocol version.
	var wrong_version: Dictionary = await _member("wrong-version", [
		"--invite", "--url=wss://127.0.0.1:%d" % port, "--cn=localhost",
		"--world=" + host_world, "--version=2"])
	_expect(not bool(wrong_version.get("joined", false)),
		"A client speaking another protocol version is refused")
	_expect(str(wrong_version.get("reason", "")) == "protocol_version",
		"The refusal names the protocol version mismatch")

	# 4. No invite.
	var no_invite: Dictionary = await _member("no-invite", [
		"--url=wss://127.0.0.1:%d" % port, "--cn=localhost", "--world=" + host_world])
	_expect(not bool(no_invite.get("joined", false)), "A client without an invite never joins")

	_write(dir.path_join("stop"), "stop")
	await _wait_process(host_pid, 15000)
	var stored: Dictionary = _read_json(dir.path_join("host.json"))
	_expect(not stored.is_empty(), "Host writes its summary")
	_expect(int(stored.get("members_joined", 0)) == 1, "Exactly one member joined")
	_expect(int(stored.get("commands", 0)) == 1, "Only one command was committed")
	_expect(int(stored.get("sequence", 0)) == 1, "The stored world has one committed event")
	var disk: Dictionary = FarmStore.new(dir.path_join("world")).load_state()
	_expect(disk.ok and disk.has("farm") and int(disk.farm.transaction.sequence) == 1,
		"The on-disk world is the authority that accepted the command")
	_expect(str(stored.get("rejections", "")) != "", "The host recorded its refusals")
	_finish()


func _member(label: String, extra: Array) -> Dictionary:
	var report: String = dir.path_join("member-%s.json" % label)
	var args: PackedStringArray = _child("member", extra)
	args.append("--report=" + report)
	var pid: int = OS.create_process(_exe(), args, false)
	_expect(pid > 0, "Member process '%s' starts" % label)
	var parsed: Dictionary = {}
	if pid > 0 and await _wait_file(report, int((TIMEOUT + 20.0) * 1000.0)):
		parsed = _read_json(report)
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
		await _wait_process(pid, 5000)
	_expect(not parsed.is_empty(), "Member process '%s' reports a result" % label)
	if not parsed.is_empty():
		print("M4_JOIN_MEMBER %s %s" % [label, JSON.stringify(parsed)])
	return parsed


# -------------------------------------------------------------------- host

func _run_host() -> void:
	var key := CryptoKey.new()
	var cert := X509Certificate.new()
	if key.load(dir.path_join("server.key")) != OK or cert.load(dir.path_join("server.crt")) != OK:
		_host_fail("certificate")
		return
	var invite_file := FileAccess.open(dir.path_join("invite.bin"), FileAccess.READ)
	if invite_file == null:
		_host_fail("invite")
		return
	var secret: PackedByteArray = invite_file.get_buffer(invite_file.get_length())
	invite_file.close()
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_server(port, "127.0.0.1", TLSOptions.server(key, cert)) != OK:
		_host_fail("listen")
		return
	root.multiplayer.multiplayer_peer = peer
	host = WorldHost.new()
	host.name = WorldHost.SESSION_NODE_NAME
	root.add_child(host)
	var opened: Dictionary = host.configure(dir.path_join("world"), START, secret, world)
	if not opened.ok:
		_host_fail("open_" + str(opened.reason))
		return
	var rejections: Array[String] = []
	var joins: Array[int] = []
	host.member_joined.connect(func(id: int) -> void: joins.append(id))
	host.member_rejected.connect(func(_id: int, reason: String) -> void:
		rejections.append(reason))
	_write(dir.path_join("host.world"), world)
	_write(dir.path_join("host.ready"), "ready")
	var deadline: int = Time.get_ticks_msec() + int(HOST_LIFETIME * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(dir.path_join("stop")):
			break
		await create_timer(0.1).timeout
	_write(dir.path_join("host.json"), JSON.stringify({
		"members_joined": joins.size(),
		"members_now": host.member_count(),
		"commands": host.world.farm.committed_command_count() if host.world.farm != null else 0,
		"sequence": host.world.farm.event_sequence() if host.world.farm != null else 0,
		"rejections": ",".join(PackedStringArray(rejections)),
		"world_id": host.world_id, "run_generation": host.run_generation,
	}))
	quit(0)


# ------------------------------------------------------------------ member

func _run_member() -> void:
	var cert := X509Certificate.new()
	var text: String = FileAccess.get_file_as_string(dir.path_join("server.crt"))
	if text.is_empty() or cert.load_from_string(text) != OK:
		_report({"joined": false, "reason": "cert_load"})
		return
	var invite: PackedByteArray = PackedByteArray()
	if secret_requested():
		var file := FileAccess.open(dir.path_join("invite.bin"), FileAccess.READ)
		if file != null:
			invite = file.get_buffer(file.get_length())
			file.close()
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client(url, TLSOptions.client(cert, cn)) != OK:
		_report({"joined": false, "reason": "create_client"})
		return
	root.multiplayer.multiplayer_peer = peer
	member = WorldMember.new()
	member.name = WorldMember.SESSION_NODE_NAME
	member.secret = invite
	member.world_id = world
	member.protocol_version = version
	root.add_child(member)
	root.multiplayer.auth_callback = _member_auth
	member.joined.connect(func(state: Dictionary) -> void:
		joined_state = state)
	member.join_failed.connect(func(reason: String) -> void: join_reason = reason)
	member.authority_lost.connect(func(reason: String) -> void: lost = reason)
	member.reply_received.connect(func(request_id: String, payload: Dictionary) -> void:
		replies[request_id] = payload)
	member.connect_to(url, invite, world)
	var started: bool = false
	var sent: bool = false
	var retried: bool = false
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	var command: Dictionary = FarmCommand.make_sow(
		"join-sow", "field_01", "cell_01", "greens", START)
	while Time.get_ticks_msec() < deadline:
		if not started and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			started = true
			root.multiplayer.send_auth(1, "start".to_utf8_buffer())
		if member.is_joined() and not sent:
			sent = true
			member.submit_command(command)
		if replies.has("join-sow") and not retried:
			retried = true
			# Same id again: the authority must replay, not apply twice.
			member.submit_command(command)
		if retried and replies.has("join-sow") and int(replies.size()) >= 1:
			await create_timer(0.4).timeout
			break
		if not join_reason.is_empty() or not lost.is_empty():
			await create_timer(0.2).timeout
			break
		await create_timer(0.05).timeout
	_report({
		"joined": member.is_joined(), "reason": join_reason if not join_reason.is_empty() else lost,
		"world_seen": str(joined_state.get("world_id", "")),
		"first_reply": replies.get("join-sow", {}),
		"replay_sequence": int((replies.get("join-sow", {}) as Dictionary).get("sequence", -1)),
		"replay_duplicate": bool((replies.get("join-sow", {}) as Dictionary).get("duplicate", false)),
	})


func _member_auth(_id: int, data: PackedByteArray) -> void:
	if member.secret.is_empty():
		root.multiplayer.send_auth(1, crypto.generate_random_bytes(32))
		root.multiplayer.complete_auth(1)
		return
	root.multiplayer.send_auth(1, crypto.hmac_digest(HashingContext.HASH_SHA256, member.secret, data))
	root.multiplayer.complete_auth(1)


func secret_requested() -> bool:
	return invite


# ------------------------------------------------------------------ shared

func _report(payload: Dictionary) -> void:
	if not report_path.is_empty():
		_write(report_path, JSON.stringify(payload))
	print("M4_JOIN " + JSON.stringify(payload))
	quit(0)


func _host_fail(reason: String) -> void:
	_write(dir.path_join("host.json"), JSON.stringify({"error": reason}))
	quit(1)


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _child(child_role: String, extra: Array) -> PackedStringArray:
	var args := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join("tests/m4_join_test.gd"),
		"--", "--role=" + child_role, "--dir=" + dir, "--port=%d" % port,
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
	print("M4_JOIN_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
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


func _read_text(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
