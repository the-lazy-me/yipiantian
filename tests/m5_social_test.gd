extends SceneTree
## M5-01: the social record over a real authoritative session.
##
## Two players with stable ids meet in one world: one invites, the other accepts
## and sends a private message that reaches an already-connected member as a
## push. The recipient blocks the sender; the sender is refused and the message
## disappears from the recipient's inbox. The block is lifted, the relationship
## is rebuilt, and the host stops so the parent can prove the record survived on
## disk. An anonymous member (no player id) is refused by the social surface, and
## a malformed player id is refused at join.
##
## Roles: --role=host, --role=member. The parent orchestrates.

const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const PLAYER_SECRET: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const WorldInvite = preload("res://world/world_invite.gd")
const SocialStore = preload("res://social/social_store.gd")

const GRANT_ID: String = "social-member"
const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"
const TEXT: String = "门口放了两把小葱。"

const TIMEOUT: float = 15.0
const HOST_LIFETIME: float = 180.0
const START: float = 1800000000.0

var role: String = "parent"
var dir: String = ""
var port: int = 0
var url: String = ""
var world: String = "world-social"
var report_path: String = ""
var ready_path: String = ""
var who: String = ""
var bad_player: bool = false
var steps: Array = []

var crypto := Crypto.new()
var host: WorldHost
var member: WorldMember
var checks: int = 0
var failures: Array[String] = []
var join_reason: String = ""
var lost: String = ""
var results: Array = []
var events: Array = []
var awaiting: String = ""
var step_index: int = 0
var watch_until: float = 0.0


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--dir="): dir = argument.trim_prefix("--dir=")
		elif argument.begins_with("--port="): port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--url="): url = argument.trim_prefix("--url=")
		elif argument.begins_with("--report="): report_path = argument.trim_prefix("--report=")
		elif argument.begins_with("--ready="): ready_path = argument.trim_prefix("--ready=")
		elif argument.begins_with("--who="): who = argument.trim_prefix("--who=")
		elif argument.begins_with("--steps="):
			steps.assign(argument.trim_prefix("--steps=").split(",", false))
		elif argument.begins_with("--bad-player"): bad_player = true
	_run.call_deferred()


func _run() -> void:
	match role:
		"host": await _run_host()
		"member": await _run_member()
		_: await _run_parent()


# ------------------------------------------------------------------ parent

func _run_parent() -> void:
	dir = _repo().path_join(".local/verification/m5-social-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var key: CryptoKey = crypto.generate_rsa(2048)
	var cert: X509Certificate = crypto.generate_self_signed_certificate(
		key, "CN=localhost,O=farm,C=CN")
	_expect(key != null and cert != null and key.save(dir.path_join("server.key")) == OK
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
	var host_pid: int = OS.create_process(_exe(), _args("host", []), false)
	_expect(host_pid > 0, "Host process starts")
	if host_pid <= 0 or not await _wait_file(dir.path_join("host.ready"), 25000):
		_expect(false, "Host reports ready")
		_finish()
		return

	# (1) Alice invites Bob and sees the outgoing request.
	var invitation: Dictionary = await _member("alice-invite", {
		"--who": "alice", "--steps": "invite:bob,state"})
	_expect(bool(invitation.get("joined", false)), "Alice joins with a stable player id")
	var invite_steps: Array = invitation.get("results", []) as Array
	_expect(_ok(invite_steps, 0), "Alice's invitation is accepted by the authority")
	var invited_state: Dictionary = _state_of(invite_steps, 1)
	_expect((invited_state.get("pending", []) as Array).size() == 1,
		"Alice sees one pending invitation")
	_expect(_pending_direction(invited_state) == "out", "The invitation is outgoing for Alice")

	# (2) A watcher is already connected when Bob sends his message, so delivery
	# is observed as a push rather than inferred from a later read.
	var watcher_report: String = dir.path_join("member-watcher.json")
	var watcher_pid: int = OS.create_process(_exe(), _args("member", [
		"--who=alice", "--steps=watch:12", "--report=" + watcher_report,
		"--ready=" + dir.path_join("watcher.ready")]), false)
	_expect(watcher_pid > 0, "The watching member starts")
	_expect(await _wait_file(dir.path_join("watcher.ready"), 25000),
		"The watching member reports that it joined")

	# (3) Bob answers the invitation and sends a private message.
	var bob: Dictionary = await _member("bob", {
		"--who": "bob", "--steps": "state,accept:alice,send:alice"})
	var bob_steps: Array = bob.get("results", []) as Array
	var bob_view: Dictionary = _state_of(bob_steps, 0)
	_expect(_pending_direction(bob_view) == "in", "Bob sees the invitation as incoming")
	_expect(_ok(bob_steps, 1), "Bob accepts the invitation")
	var sent_state: Dictionary = _state_of(bob_steps, 2)
	var inbox: Array = sent_state.get("inbox", []) as Array
	_expect(inbox.size() == 1 and str((inbox[0] as Dictionary).text) == TEXT,
		"Bob sees his message in his own inbox")

	if await _wait_file(watcher_report, 20000):
		var watched: Dictionary = _read_json(watcher_report)
		events = watched.get("events", []) as Array
	if watcher_pid > 0 and OS.is_process_running(watcher_pid):
		OS.kill(watcher_pid)
		await _wait_process(watcher_pid, 5000)
	_expect(events.size() == 1, "The connected recipient receives exactly one pushed message")
	if events.size() == 1:
		var event: Dictionary = (events[0] as Dictionary).get("message", {}) as Dictionary
		_expect(str(event.get("from", "")) == BOB, "The pushed message names its sender")
		_expect(str(event.get("text", "")) == TEXT, "The pushed message carries its text")
		_expect(str((events[0] as Dictionary).get("event", "")) == "message",
			"The push is typed as a message event")

	# (4) Alice returns: the contact and message are still there, then blocking
	# hides the message and ends the relationship.
	var alice_return: Dictionary = await _member("alice-return", {
		"--who": "alice", "--steps": "state,block:bob,state"})
	var return_steps: Array = alice_return.get("results", []) as Array
	var alice_view: Dictionary = _state_of(return_steps, 0)
	_expect((alice_view.get("contacts", []) as Array).size() == 1,
		"The contact survives a reconnect")
	_expect((alice_view.get("inbox", []) as Array).size() == 1,
		"The private message is visible to its recipient")
	_expect(_ok(return_steps, 1), "Alice blocks Bob")
	var blocked_view: Dictionary = _state_of(return_steps, 2)
	_expect((blocked_view.get("contacts", []) as Array).is_empty(),
		"Blocking removes the contact")
	_expect((blocked_view.get("blocks", []) as Array).size() == 1, "The block is recorded")
	_expect((blocked_view.get("inbox", []) as Array).is_empty(),
		"Blocking hides the blocked player's messages from the recipient")

	# (5) A blocked sender is refused, not silently dropped.
	var blocked_bob: Dictionary = await _member("bob-blocked", {
		"--who": "bob", "--steps": "send:alice"})
	var blocked_steps: Array = blocked_bob.get("results", []) as Array
	_expect(_reason(blocked_steps, 0) == "blocked", "The blocked sender is refused with a named reason")

	# (5b) A public message is stored for everyone but never pushed to a viewer
	# in a blocked relationship with its sender.
	var public_report: String = dir.path_join("member-public-watcher.json")
	var public_pid: int = OS.create_process(_exe(), _args("member", [
		"--who=alice", "--steps=watch:12", "--report=" + public_report,
		"--ready=" + dir.path_join("public-watcher.ready")]), false)
	_expect(public_pid > 0, "The blocked viewer's watcher starts")
	_expect(await _wait_file(dir.path_join("public-watcher.ready"), 25000),
		"The blocked viewer's watcher joins")
	var public_send: Dictionary = await _member("bob-public", {
		"--who": "bob", "--steps": "send-public"})
	_expect(_ok(public_send.get("results", []) as Array, 0),
		"A blocked sender may still broadcast a public message")
	var public_events: Array = []
	if await _wait_file(public_report, 20000):
		public_events = _read_json(public_report).get("events", []) as Array
	if public_pid > 0 and OS.is_process_running(public_pid):
		OS.kill(public_pid)
		await _wait_process(public_pid, 5000)
	_expect(public_events.is_empty(),
		"A public message is not pushed to a viewer who blocked its sender")

	# (6) Lifting the block allows a new relationship.
	var alice_final: Dictionary = await _member("alice-final", {
		"--who": "alice", "--steps": "unblock:bob,invite:bob,state"})
	var final_steps: Array = alice_final.get("results", []) as Array
	_expect(_ok(final_steps, 0), "The block is lifted")
	_expect(_ok(final_steps, 1), "A new invitation is sent after unblocking")
	var bob_final: Dictionary = await _member("bob-final", {
		"--who": "bob", "--steps": "accept:alice"})
	_expect(_ok(bob_final.get("results", []) as Array, 0), "Bob accepts the rebuilt relationship")

	# (7) An anonymous member has no social record; a malformed id never joins.
	var anonymous: Dictionary = await _member("anonymous", {"--steps": "state"})
	_expect(str(anonymous.get("reason", "")) == "", "A member without a player id still joins")
	_expect(_reason(anonymous.get("results", []) as Array, 0) == "no_player",
		"An anonymous member is refused by the social surface")
	var malformed: Dictionary = await _member("malformed", {
		"--who": "bad", "--bad-player": "1", "--steps": "state"})
	_expect(not bool(malformed.get("joined", false)), "A malformed player id is refused at join")
	_expect(str(malformed.get("reason", "")) == "invalid_player",
		"The refusal names the invalid player")

	_write(dir.path_join("stop"), "stop")
	await _wait_process(host_pid, 15000)
	# (8) The record is on disk, not only in the authority's memory.
	var stored: Dictionary = SocialStore.new(dir.path_join("world")).load_state()
	_expect(bool(stored.get("ok", false)), "The social document reloads from disk")
	if stored.get("ok", false):
		var document: Dictionary = stored.state
		var players: Dictionary = document.get("players", {}) as Dictionary
		_expect(players.has(ALICE) and players.has(BOB),
			"Both players survive the authority stopping")
		_expect((players[ALICE].contacts as Dictionary).has(BOB),
			"Alice's contact is durable")
		_expect((players[BOB].contacts as Dictionary).has(ALICE),
			"Bob's contact is durable")
		var durable_message: bool = false
		for message: Dictionary in document.get("messages", []):
			durable_message = durable_message or (str(message.text) == TEXT and str(message.from) == BOB)
		_expect(durable_message, "The message survives the authority stopping")
	_finish()


func _member(label: String, options: Dictionary) -> Dictionary:
	var extra: Array[String] = []
	for key: String in options:
		extra.append("%s=%s" % [key, str(options[key])])
	var report: String = dir.path_join("member-%s.json" % label)
	extra.append("--report=" + report)
	var pid: int = OS.create_process(_exe(), _args("member", extra), false)
	_expect(pid > 0, "Member process '%s' starts" % label)
	var parsed: Dictionary = {}
	if pid > 0 and await _wait_file(report, int((TIMEOUT + 20.0) * 1000.0)):
		parsed = _read_json(report)
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
		await _wait_process(pid, 5000)
	_expect(not parsed.is_empty(), "Member process '%s' reports a result" % label)
	if not parsed.is_empty():
		print("M5_SOCIAL_MEMBER %s %s" % [label, JSON.stringify(parsed.get("results", []))])
	return parsed


func _ok(steps: Array, index: int) -> bool:
	return index < steps.size() and bool((steps[index] as Dictionary).get("result", {}).get("ok", false))


func _reason(steps: Array, index: int) -> String:
	if index >= steps.size():
		return ""
	return str((steps[index] as Dictionary).get("result", {}).get("reason", ""))


func _state_of(steps: Array, index: int) -> Dictionary:
	if index >= steps.size():
		return {}
	var payload: Dictionary = (steps[index] as Dictionary).get("result", {}) as Dictionary
	return payload.get("state", {}) as Dictionary


func _pending_direction(state: Dictionary) -> String:
	var pending: Array = state.get("pending", []) as Array
	if pending.is_empty():
		return ""
	return str((pending[0] as Dictionary).get("direction", ""))


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
	if not host.add_grant(
			WorldInvite.make(GRANT_ID, secret, WorldInvite.MEMBER, world, 0.0, false)).ok:
		_host_fail("grant")
		return
	var joins: Array[int] = []
	host.member_joined.connect(func(id: int) -> void: joins.append(id))
	_write(dir.path_join("host.ready"), "ready")
	var deadline: int = Time.get_ticks_msec() + int(HOST_LIFETIME * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(dir.path_join("stop")):
			break
		await create_timer(0.1).timeout
	_write(dir.path_join("host.json"), JSON.stringify({
		"joins": joins.size(), "players": host.social.get("players", {}).size(),
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
	member.display_name = _name_of(who)
	member.player_id = "bad id" if bad_player else _id_of(who)
	member.player_secret = Marshalls.base64_to_raw(PLAYER_SECRET)
	root.add_child(member)
	root.multiplayer.auth_callback = _member_auth
	member.join_failed.connect(func(reason: String) -> void: join_reason = reason)
	member.authority_lost.connect(func(reason: String) -> void: lost = reason)
	member.social_result.connect(func(request_id: String, payload: Dictionary) -> void:
		results.append({"step": request_id, "result": payload})
		awaiting = "")
	member.social_event.connect(func(payload: Dictionary) -> void:
		events.append(payload))
	member.connect_to(url, secret, world)
	var started: bool = false
	var ready_written: bool = false
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if not started and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			started = true
			root.multiplayer.send_auth(1, member.auth_hello())
		if member.is_joined():
			if not ready_written:
				ready_written = true
				if not ready_path.is_empty():
					_write(ready_path, "ready")
			if watch_until > 0.0:
				if Time.get_ticks_msec() >= int(watch_until * 1000.0):
					break
			elif awaiting.is_empty():
				if step_index >= steps.size():
					break
				var step: String = str(steps[step_index])
				step_index += 1
				if step.begins_with("watch:"):
					watch_until = Time.get_ticks_msec() / 1000.0 \
						+ step.trim_prefix("watch:").to_float()
				else:
					_issue(step)
		if not join_reason.is_empty() or not lost.is_empty():
			break
		await create_timer(0.05).timeout
	var report: Dictionary = {
		"joined": member.is_joined(),
		"reason": join_reason if not join_reason.is_empty() else lost,
		"results": results, "events": events,
	}
	if not report_path.is_empty():
		_write(report_path, JSON.stringify(report))
	print("M5_SOCIAL " + JSON.stringify(report))
	quit(0)


func _issue(step: String) -> void:
	var parts: PackedStringArray = step.split(":", false)
	var request_id: String = "step-%d-%s" % [results.size(), parts[0]]
	awaiting = request_id
	var target: String = ""
	if parts.size() > 1:
		target = _id_of(parts[1])
	match parts[0]:
		"state":
			member.request_social(request_id, "state")
		"invite":
			member.request_social(request_id, "invite",
				{"player_id": target, "name": _name_of(parts[1])})
		"accept":
			member.request_social(request_id, "accept", {"player_id": target})
		"decline":
			member.request_social(request_id, "decline", {"player_id": target})
		"remove":
			member.request_social(request_id, "remove", {"player_id": target})
		"block":
			member.request_social(request_id, "block", {"player_id": target, "reason": "测试"})
		"unblock":
			member.request_social(request_id, "unblock", {"player_id": target})
		"send":
			member.request_social(request_id, "send", {"to": target, "text": TEXT})
		"send-public":
			member.request_social(request_id, "send", {"to": "", "text": TEXT})
		"read":
			member.request_social(request_id, "read", {"id": parts[1]})
		_:
			awaiting = ""
			results.append({"step": request_id, "result": {"ok": false, "reason": "unknown_step"}})


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
	return who_id


func _name_of(who_id: String) -> String:
	if who_id == "alice":
		return "阿青"
	if who_id == "bob":
		return "小满"
	return who_id if not who_id.is_empty() else "旅人"


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
		"--script", _repo().path_join("tests/m5_social_test.gd"),
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
	print("M5_SOCIAL_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
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
