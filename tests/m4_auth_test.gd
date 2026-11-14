extends SceneTree
## M4-01 prototype: WSS over a self-signed certificate plus a SceneMultiplayer
## authentication gate, on loopback only. Proves (or disproves) three things
## before the transport decision is recorded:
##   T1  a client can verify a self-signed certificate, including one addressed
##       by IP through a common-name override;
##   T3  a peer that has not finished authentication cannot reach business RPC;
##   --  an invite-authenticated peer can run one command round trip.
##
## Roles are separate processes because SceneMultiplayer/RPC state is per
## SceneTree: --role=server, --role=client. The parent orchestrates both.
## Everything stays below .local/verification; no real save is touched.

const TIMEOUT: float = 12.0
const SERVER_LIFETIME: float = 90.0

var role: String = "parent"
var dir: String = ""
var port: int = 0
var invite: bool = false
var url: String = ""
var common_name: String = ""
var report_path: String = ""

var crypto := Crypto.new()
var endpoint: Endpoint
var peer: WebSocketMultiplayerPeer
var secret: PackedByteArray
var challenges: Dictionary = {}
var authenticated: Dictionary = {}
var checks: int = 0
var failures: Array[String] = []
var pre_auth_commands: int = 0
var post_auth_commands: int = 0
var notes: Array[String] = []
var connected: bool = false
var replies: int = 0
var failure_reason: String = ""


class Endpoint extends Node:
	@rpc("any_peer", "call_remote", "reliable", 0)
	func farm_command(payload: String) -> void:
		received.emit(payload, multiplayer.get_remote_sender_id())

	@rpc("authority", "call_remote", "reliable", 1)
	func command_result(payload: String) -> void:
		answered.emit(payload)

	signal received(payload: String, sender: int)
	signal answered(payload: String)


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--dir="): dir = argument.trim_prefix("--dir=")
		elif argument.begins_with("--port="): port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--url="): url = argument.trim_prefix("--url=")
		elif argument.begins_with("--cn="): common_name = argument.trim_prefix("--cn=")
		elif argument.begins_with("--report="): report_path = argument.trim_prefix("--report=")
		elif argument == "--invite": invite = true
	_run.call_deferred()


func _run() -> void:
	match role:
		"server": await _run_server()
		"client": await _run_client()
		_: await _run_parent()


# ------------------------------------------------------------------ parent

func _run_parent() -> void:
	dir = _root().path_join(".local/verification/m4-auth-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var key: CryptoKey = crypto.generate_rsa(2048)
	_expect(key != null, "RSA key generates")
	var cert: X509Certificate = crypto.generate_self_signed_certificate(
		key, "CN=localhost,O=farm,C=CN")
	_expect(cert != null and not cert.save_to_string().is_empty(),
		"Self-signed certificate is created")
	_expect(key.save(dir.path_join("server.key")) == OK
		and cert.save(dir.path_join("server.crt")) == OK,
		"Key and certificate are written for the server process")
	secret = crypto.generate_random_bytes(32)
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
	await _orchestrate()
	_finish()


func _orchestrate() -> void:
	var server_pid: int = OS.create_process(_exe(), _child_args("server"), false)
	_expect(server_pid > 0, "Server process starts")
	if server_pid <= 0:
		return
	if not await _wait_file(dir.path_join("server.ready"), 20000):
		_expect(false, "Server reports ready")
		_write(dir.path_join("stop"), "stop")
		return

	# The certificate names "localhost"; the server binds loopback, so every
	# client must reach it by IP and name the certificate explicitly.
	var endpoint_url: String = "wss://127.0.0.1:%d" % port
	var good: Dictionary = await _client("authorized", [
		"--invite", "--url=" + endpoint_url, "--cn=localhost"])
	_expect(bool(good.get("authenticated", false)),
		"An invited client completes authentication")
	_expect(int(good.get("commands", 0)) == 1,
		"The authenticated client's command reaches the authority")
	_expect(int(good.get("replies", 0)) == 1,
		"The authority answers the authenticated client")

	var bad: Dictionary = await _client("uninvited", ["--url=" + endpoint_url, "--cn=localhost"])
	_expect(not bool(bad.get("authenticated", false)),
		"An uninvited client never becomes a peer")
	_expect(int(bad.get("replies", 0)) == 0,
		"The authority never answers an uninvited client")

	# Same invite, but the certificate is not pinned to a matching name: the
	# handshake must fail before any invite is presented.
	var unpinned: Dictionary = await _client("unpinned", ["--invite", "--url=" + endpoint_url])
	_expect(not bool(unpinned.get("authenticated", false)),
		"A self-signed certificate is not accepted for an IP without a common-name override")
	_expect(str(unpinned.get("reason", "")) != "",
		"The unpinned client reports why it never joined")

	_write(dir.path_join("stop"), "stop")
	await _wait_process(server_pid, 15000)
	var summary: Dictionary = _read_json(dir.path_join("server.json"))
	_expect(not summary.is_empty(), "Server writes its summary")
	_expect(int(summary.get("authenticated", 0)) == 1, "Only the invited peer was authenticated")
	_expect(int(summary.get("rejected", 0)) == 1, "The uninvited peer was rejected at the gate")
	_expect(int(summary.get("unauthenticated_commands", -1)) == 0,
		"No business RPC was accepted from an unauthenticated peer")
	_expect(int(summary.get("post_auth_commands", 0)) == 1,
		"Only the authenticated peer's command was executed")
	if not summary.is_empty():
		print("M4_AUTH_SERVER " + JSON.stringify(summary))


func _client(label: String, extra: Array) -> Dictionary:
	# Each client is a separate process and reports through a file, so the parent
	# never blocks on a captured pipe (a full pipe would deadlock both sides).
	var report: String = dir.path_join("client-%s.json" % label)
	var args: PackedStringArray = _child_args("client", extra)
	args.append("--report=" + report)
	var pid: int = OS.create_process(_exe(), args, false)
	_expect(pid > 0, "Client process '%s' starts" % label)
	var parsed: Dictionary = {}
	# The client stops on its own budget; give it extra room so a slow TLS
	# failure is reported rather than cut off.
	if pid > 0 and await _wait_file(report, int((TIMEOUT + 15.0) * 1000.0)):
		parsed = _read_json(report)
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
		await _wait_process(pid, 5000)
	_expect(not parsed.is_empty(), "Client process '%s' reports a result" % label)
	if not parsed.is_empty():
		print("M4_AUTH_CLIENT %s %s" % [label, JSON.stringify(parsed)])
	return parsed
	return parsed


# ------------------------------------------------------------------ server

func _run_server() -> void:
	var key := CryptoKey.new()
	var cert := X509Certificate.new()
	if key.load(dir.path_join("server.key")) != OK:
		_server_fail("key_load")
		return
	if cert.load(dir.path_join("server.crt")) != OK:
		_server_fail("cert_load")
		return
	var invite_file := FileAccess.open(dir.path_join("invite.bin"), FileAccess.READ)
	if invite_file == null:
		_server_fail("invite_load")
		return
	secret = invite_file.get_buffer(invite_file.get_length())
	invite_file.close()

	peer = WebSocketMultiplayerPeer.new()
	var listen: int = peer.create_server(port, "127.0.0.1", TLSOptions.server(key, cert))
	if listen != OK:
		_server_fail("listen_%d" % listen)
		return
	root.multiplayer.multiplayer_peer = peer
	root.multiplayer.auth_callback = _server_auth
	root.multiplayer.peer_connected.connect(func(id: int) -> void:
		notes.append("peer_connected:%d" % id))
	root.multiplayer.peer_disconnected.connect(func(id: int) -> void:
		notes.append("peer_disconnected:%d" % id))
	root.multiplayer.peer_authentication_failed.connect(func(id: int) -> void:
		notes.append("auth_failed:%d" % id))
	# Connect the command sink before anyone can authenticate, so a leaked
	# pre-authentication RPC is counted instead of vanishing.
	endpoint = Endpoint.new()
	endpoint.name = "Endpoint"
	endpoint.received.connect(_server_received)
	root.add_child(endpoint)
	_write(dir.path_join("server.ready"), "ready")

	var deadline: int = Time.get_ticks_msec() + int(SERVER_LIFETIME * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(dir.path_join("stop")):
			break
		await create_timer(0.1).timeout
	_write(dir.path_join("server.json"), JSON.stringify({
		"authenticated": authenticated.size(),
		"rejected": int(notes.filter(func(note: String) -> bool: return note.begins_with("reject:")).size()),
		"unauthenticated_commands": pre_auth_commands,
		"post_auth_commands": post_auth_commands,
		"notes": notes,
	}))
	quit(0)


func _server_auth(id: int, data: PackedByteArray) -> void:

	if not challenges.has(id):
		# First message only opens the challenge; its content is never trusted.
		challenges[id] = crypto.generate_random_bytes(32)
		root.multiplayer.send_auth(id, challenges[id])
		return
	var expected: PackedByteArray = crypto.hmac_digest(
		HashingContext.HASH_SHA256, secret, challenges[id])
	if not crypto.constant_time_compare(expected, data):
		notes.append("reject:%d" % id)
		# No complete_auth: the peer must fail authentication, not be accepted
		# and then removed.
		root.multiplayer.disconnect_peer(id)
		return
	authenticated[id] = true
	root.multiplayer.complete_auth(id)


func _server_received(payload: String, sender: int) -> void:
	if not authenticated.has(sender):
		pre_auth_commands += 1
		notes.append("pre_auth_command:%d" % sender)
		return
	post_auth_commands += 1
	endpoint.command_result.rpc_id(sender, "ok:%s" % payload)


# ------------------------------------------------------------------ client

func _run_client() -> void:
	var cert := X509Certificate.new()
	var cert_text: String = FileAccess.get_file_as_string(dir.path_join("server.crt"))
	if cert_text.is_empty() or cert.load_from_string(cert_text) != OK:
		failure_reason = "cert_load"
		_client_report()
		return
	secret = PackedByteArray()
	if invite:
		var invite_file := FileAccess.open(dir.path_join("invite.bin"), FileAccess.READ)
		if invite_file != null:
			secret = invite_file.get_buffer(invite_file.get_length())
			invite_file.close()
	var tls: TLSOptions = TLSOptions.client(cert, common_name) if not common_name.is_empty() \
		else TLSOptions.client(cert)
	peer = WebSocketMultiplayerPeer.new()
	if peer.create_client(url, tls) != OK:
		failure_reason = "create_client"
		_client_report()
		return
	root.multiplayer.multiplayer_peer = peer
	root.multiplayer.auth_callback = _client_auth
	endpoint = Endpoint.new()
	endpoint.name = "Endpoint"
	endpoint.answered.connect(func(_payload: String) -> void: replies += 1)
	root.add_child(endpoint)
	root.multiplayer.peer_connected.connect(func(id: int) -> void:
		if id == 1:
			# Authentication has finished on both sides; business RPC is legal.
			endpoint.farm_command.rpc_id(1, "sow"))
	root.multiplayer.connected_to_server.connect(func() -> void: connected = true)
	root.multiplayer.connection_failed.connect(func() -> void:
		failure_reason = "connection_failed")
	root.multiplayer.server_disconnected.connect(func() -> void:
		failure_reason = "server_disconnected")

	# With auth_callback set, SceneMultiplayer withholds peer_connected until
	# authentication finishes, so the handshake cannot start from that signal.
	# The client opens it as soon as the transport itself is connected.
	var started: bool = false
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if not started and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			started = true
			root.multiplayer.send_auth(1, "start".to_utf8_buffer())
			# Try a business RPC before the handshake can finish; the authority
			# must not execute it.
			endpoint.farm_command.rpc_id(1, "early")
		if connected and replies > 0:
			break
		if failure_reason == "server_disconnected" and not connected:
			break
		await create_timer(0.05).timeout
	if not started:
		failure_reason = failure_reason if not failure_reason.is_empty() else "never_connected"
	_client_report()


func _client_auth(_id: int, data: PackedByteArray) -> void:

	if secret.is_empty():
		# No invite: answer with random bytes so the gate rejects this peer.
		root.multiplayer.send_auth(1, crypto.generate_random_bytes(32))
		root.multiplayer.complete_auth(1)
		return
	root.multiplayer.send_auth(1, crypto.hmac_digest(HashingContext.HASH_SHA256, secret, data))
	root.multiplayer.complete_auth(1)


func _client_report() -> void:
	var payload: Dictionary = {
		"authenticated": connected,
		"commands": 1 if connected else 0,
		"replies": replies,
		"reason": failure_reason,
		"peer_status": peer.get_connection_status() if peer != null else -1,
	}
	if not report_path.is_empty():
		_write(report_path, JSON.stringify(payload))
	print("M4_AUTH_CLIENT " + JSON.stringify(payload))
	quit(0)


# ------------------------------------------------------------------ shared

func _root() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _script_path() -> String:
	return _root().path_join("tests/m4_auth_test.gd")


func _exe() -> String:
	return OS.get_executable_path()


func _child_args(child_role: String, extra: Array = []) -> PackedStringArray:
	var args := PackedStringArray([
		"--headless", "--path", _root().path_join("Game"),
		"--script", _script_path(),
		"--", "--role=" + child_role, "--dir=" + dir, "--port=%d" % port,
	])
	for value: String in extra:
		args.append(value)
	return args


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
	print("M4_AUTH_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
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


func _server_fail(reason: String) -> void:
	_write(dir.path_join("server.json"), JSON.stringify({"error": reason}))
	quit(1)
