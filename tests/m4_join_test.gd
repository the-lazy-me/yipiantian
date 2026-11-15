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
const PLAYER_SECRET: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const WorldInvite = preload("res://world/world_invite.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const FarmStore = preload("res://farm/farm_store.gd")

const GRANT_ID: String = "join-member"

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
var grant: String = ""
var secret_file: String = ""
var world: String = ""
var version: int = 1
var kind: String = "member"
var player_override: String = ""
var secret_override: String = ""

var crypto := Crypto.new()
var host: WorldHost
var member: WorldMember
var checks: int = 0
var failures: Array[String] = []
var joined_state: Dictionary = {}
var replies: Dictionary = {}
var join_reason: String = ""
var lost: String = ""


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--dir="): dir = argument.trim_prefix("--dir=")
		elif argument.begins_with("--port="): port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--url="): url = argument.trim_prefix("--url=")
		elif argument.begins_with("--cn="): cn = argument.trim_prefix("--cn=")
		elif argument.begins_with("--report="): report_path = argument.trim_prefix("--report=")
		elif argument.begins_with("--world="): world = argument.trim_prefix("--world=")
		elif argument.begins_with("--role-kind="): kind = argument.trim_prefix("--role-kind=")
		elif argument.begins_with("--version="): version = argument.trim_prefix("--version=").to_int()
		elif argument.begins_with("--grant="): grant = argument.trim_prefix("--grant=")
		elif argument.begins_with("--secret-file="): secret_file = argument.trim_prefix("--secret-file=")
		elif argument.begins_with("--player-id="): player_override = argument.trim_prefix("--player-id=")
		elif argument.begins_with("--player-secret="): secret_override = argument.trim_prefix("--player-secret=")
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
	var restored: Dictionary = good.get("restored", {}) as Dictionary
	_expect(bool(restored.get("ok", false)),
		"A joined member restores the whole world from the summary snapshot")
	_expect(int(restored.get("sequence", -1)) == 1,
		"The restored snapshot carries the committed sequence")
	_expect(int(restored.get("layout_fields", 0)) > 0, "The restored snapshot carries the layout")
	_expect(bool(restored.get("sowed", false)),
		"The restored snapshot carries the member's own commit")
	_expect(str(restored.get("season", "")) != "", "The restored snapshot carries the season")
	_expect(int(restored.get("decorations", 0)) > 0,
		"The restored snapshot carries the decoration state")

	# 1b. A named identity is bound to its first credential. The same id with the
	# right secret keeps joining; another secret is refused with a named reason
	# instead of silently acting as that player.
	var identity_id: String = "player_identity_00000000000000000001"
	var identity: Dictionary = await _member("identity", [
		"--invite", "--url=wss://127.0.0.1:%d" % port, "--cn=localhost",
		"--world=" + host_world, "--role-kind=identity",
		"--player-id=" + identity_id, "--player-secret=" + PLAYER_SECRET])
	_expect(bool(identity.get("joined", false)),
		"A named identity joins and binds its player id")
	var wrong_secret: Dictionary = await _member("identity-wrong", [
		"--invite", "--url=wss://127.0.0.1:%d" % port, "--cn=localhost",
		"--world=" + host_world, "--role-kind=identity",
		"--player-id=" + identity_id,
		"--player-secret=eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtOTk="])
	_expect(not bool(wrong_secret.get("joined", false)),
		"Another credential cannot claim a bound player id")
	_expect(str(wrong_secret.get("reason", "")) == "player_proof",
		"The refusal names the credential mismatch")
	var same_secret: Dictionary = await _member("identity-again", [
		"--invite", "--url=wss://127.0.0.1:%d" % port, "--cn=localhost",
		"--world=" + host_world, "--role-kind=identity",
		"--player-id=" + identity_id, "--player-secret=" + PLAYER_SECRET])
	_expect(bool(same_secret.get("joined", false)),
		"The bound identity still joins with its own credential")
	var roster: Array = (same_secret.get("roster", []) as Array)
	var named_rows: int = 0
	for row: Variant in roster:
		if row is Dictionary and str((row as Dictionary).get("player_id", "")) == identity_id:
			named_rows += 1
	_expect(named_rows >= 1, "The roster names the bound identity")

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

	var grants: Dictionary = _read_json(dir.path_join("grants.json"))
	# 5. A one-time grant works once and then names why it was refused.
	var first_once: Dictionary = await _member("once-1", [
		"--invite", "--url=wss://127.0.0.1:%d" % port, "--cn=localhost",
		"--world=" + host_world, "--grant=" + str(grants.get("one_time", "")),
		"--secret-file=" + dir.path_join("secret-%s.bin" % str(grants.get("one_time", "")))])
	_expect(bool(first_once.get("joined", false)), "A one-time grant admits its first holder")
	var second_once: Dictionary = await _member("once-2", [
		"--invite", "--url=wss://127.0.0.1:%d" % port, "--cn=localhost",
		"--world=" + host_world, "--grant=" + str(grants.get("one_time", "")),
		"--secret-file=" + dir.path_join("secret-%s.bin" % str(grants.get("one_time", "")))])
	_expect(not bool(second_once.get("joined", false)),
		"A one-time grant does not admit a second holder")
	_expect(str(second_once.get("reason", "")) == "invite_used",
		"The refusal says the grant was already used")

	# 6. A visitor grant joins but may not harvest.
	var visitor: Dictionary = await _member("visitor", [
		"--invite", "--url=wss://127.0.0.1:%d" % port, "--cn=localhost",
		"--world=" + host_world, "--grant=" + str(grants.get("visitor", "")),
		"--secret-file=" + dir.path_join("secret-%s.bin" % str(grants.get("visitor", ""))),
		"--role-kind=visitor"])
	_expect(bool(visitor.get("joined", false)), "A visitor grant admits its holder")
	_expect(str(visitor.get("role_seen", "")) == "visitor",
		"The visitor learns which role it actually has")
	_expect(str(visitor.get("harvest_reason", "")) == "forbidden",
		"A visitor may not take produce")
	_expect(bool(visitor.get("water_ok", false)), "A visitor may still tend a crop")
	_expect(str(visitor.get("build_reason", "")) == "forbidden",
		"A named visitor may not build a homestead")
	_expect(str(visitor.get("theft_reason", "")) == "forbidden",
		"A named visitor may not change their theft standing")

	# 7. An expired grant is refused with the reason that lets the UI ask for
	# a new code instead of showing a generic failure.
	var expired: Dictionary = await _member("expired", [
		"--invite", "--url=wss://127.0.0.1:%d" % port, "--cn=localhost",
		"--world=" + host_world, "--grant=" + str(grants.get("expired", "")),
		"--secret-file=" + dir.path_join("secret-%s.bin" % str(grants.get("expired", "")))])
	_expect(not bool(expired.get("joined", false)), "An expired grant is refused")
	_expect(str(expired.get("reason", "")) == "invite_expired",
		"The refusal says the grant expired")

	_write(dir.path_join("stop"), "stop")
	await _wait_process(host_pid, 15000)
	var stored: Dictionary = _read_json(dir.path_join("host.json"))
	_expect(not stored.is_empty(), "Host writes its summary")
	_expect(int(stored.get("members_joined", 0)) == 5,
		"Exactly five members joined: matching, one-time holder, visitor and two identity joins")
	_expect(int(stored.get("commands", 0)) == 2,
		"Two commands were committed: the member's sow and the visitor's watering")
	_expect(int(stored.get("sequence", 0)) == 2, "The stored world has two committed events")
	var disk: Dictionary = FarmStore.new(dir.path_join("world")).load_state()
	_expect(disk.ok and disk.has("farm") and int(disk.farm.transaction.sequence) == 2,
		"The on-disk world is the authority that accepted both commands")
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
	var opened: Dictionary = host.configure(dir.path_join("world"), START, world)
	if not opened.ok:
		_host_fail("open_" + str(opened.reason))
		return
	# Three grants with different meanings: the reusable member grant every
	# accepted client uses, a one-time member grant, a visitor grant, and an
	# already-expired grant.
	var granted: Dictionary = host.add_grant(
		WorldInvite.make(GRANT_ID, secret, WorldInvite.MEMBER, world, 0.0, false))
	if not granted.ok:
		_host_fail("grant_" + str(granted.reason))
		return
	var one_time: Dictionary = WorldInvite.make("join-once",
		crypto.generate_random_bytes(32), WorldInvite.MEMBER, world, 0.0, true)
	var visitor: Dictionary = WorldInvite.make("join-visitor",
		crypto.generate_random_bytes(32), WorldInvite.VISITOR, world, 0.0, false)
	var expired: Dictionary = WorldInvite.make("join-expired",
		crypto.generate_random_bytes(32), WorldInvite.MEMBER, world, START - 1.0, false)
	for extra: Dictionary in [one_time, visitor, expired]:
		if not host.add_grant(extra).ok:
			_host_fail("grant_extra")
			return
	# The member processes need each secret on disk, one file per grant.
	for extra: Dictionary in [one_time, visitor, expired]:
		var out := FileAccess.open(dir.path_join("secret-%s.bin" % extra.id), FileAccess.WRITE)
		if out == null:
			_host_fail("secret_file")
			return
		out.store_buffer(extra.secret)
		out.close()
	_write(dir.path_join("grants.json"), JSON.stringify({"one_time": one_time.id,
		"visitor": visitor.id, "expired": expired.id}))
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
		var file := FileAccess.open(
			dir.path_join("invite.bin") if secret_file.is_empty() else secret_file, FileAccess.READ)
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
	if invite:
		member.grant_id = GRANT_ID if grant.is_empty() else grant
	member.world_id = world
	member.protocol_version = version
	if kind == "visitor":
		# Give the visitor a claimed player id so the build/set_theft refusal is
		# decided by role, not by an earlier "no_player" guard.
		member.player_id = "player_0000000000000000000000000000000v"
		member.player_secret = Marshalls.base64_to_raw(PLAYER_SECRET)
		member.display_name = "访客"
	if not player_override.is_empty():
		member.player_id = player_override
		member.display_name = "身份测试"
	if not secret_override.is_empty():
		member.player_secret = Marshalls.base64_to_raw(secret_override)
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
	var build_sent: bool = false
	var summary_sent: bool = false
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	var role_kind: String = kind
	var command: Dictionary = FarmCommand.make_sow(
		"join-sow", "field_01", "cell_01", "greens", START)
	if role_kind == "visitor":
		# A visitor probes both sides of the permission line: taking produce is
		# refused, tending is allowed.
		command = FarmCommand.make("join-harvest", "field_03", "cell_06", START)
	while Time.get_ticks_msec() < deadline:
		if not started and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			started = true
			root.multiplayer.send_auth(1, member.auth_hello())
		if role_kind == "identity" and member.is_joined():
			# A named identity joins, reads one summary and leaves: the world's
			# command counts stay attributable to the behavioural members.
			if not summary_sent:
				summary_sent = true
				member.request_summary.rpc_id(1)
			elif replies.has("summary"):
				await create_timer(0.2).timeout
				break
			await create_timer(0.05).timeout
			continue
		if member.is_joined() and not sent:
			sent = true
			member.submit_command(command)
		if role_kind == "visitor" and replies.has("join-harvest"):
			# The refusal is the expected result; now show the allowed action.
			# field_04/cell_06 starts young and unwatered, so tending it is legal.
			if not retried:
				retried = true
				member.submit_command(FarmCommand.make_water(
					"join-water", "field_04", "cell_06", START))
		if role_kind == "visitor" and replies.has("join-water"):
			# A named visitor may tend but may not build or change their own
			# theft standing: those are member permissions in the invite table.
			if not build_sent:
				build_sent = true
				member.submit_command(FarmCommand.make_build(
					"join-build", "yard_a", "cottage", START))
				member.submit_command(FarmCommand.make_set_theft("join-theft", true, START))
			elif replies.has("join-build") and replies.has("join-theft"):
				await create_timer(0.3).timeout
				break
		if role_kind != "visitor" and replies.has("join-sow") and not retried:
			retried = true
			# Same id again: the authority must replay, not apply twice.
			member.submit_command(command)
		if role_kind != "visitor" and retried and replies.has("join-sow"):
			if not summary_sent:
				# The whole world travels with the summary, not just the field view.
				summary_sent = true
				member.request_summary.rpc_id(1)
			elif replies.has("summary"):
				await create_timer(0.2).timeout
				break
		if not join_reason.is_empty() or not lost.is_empty():
			await create_timer(0.2).timeout
			break
		await create_timer(0.05).timeout
	var harvest: Dictionary = replies.get("join-harvest", {}) as Dictionary
	var water_reply: Dictionary = replies.get("join-water", {}) as Dictionary
	var build: Dictionary = replies.get("join-build", {}) as Dictionary
	var theft: Dictionary = replies.get("join-theft", {}) as Dictionary
	# Rebuild the local authority from what the summary carried, so the parent can
	# assert it is the whole world rather than a field view.
	var restored: Dictionary = member.restore_state()
	var restored_report: Dictionary = {"ok": bool(restored.get("ok", false)),
		"reason": str(restored.get("reason", ""))}
	if restored.get("ok", false):
		var local_farm: RefCounted = restored.farm
		restored_report["sequence"] = local_farm.event_sequence()
		restored_report["layout_fields"] = (local_farm.snapshot().layout.fields as Array).size()
		restored_report["sowed"] = not str(
			local_farm.get_cell("field_01", "cell_01").get("crop_id", "")).is_empty()
		restored_report["season"] = str(local_farm.snapshot().season)
		restored_report["decorations"] = (restored.decorations as RefCounted).snapshot().size()
	_report({
		"joined": member.is_joined(), "reason": join_reason if not join_reason.is_empty() else lost,
		"world_seen": str(joined_state.get("world_id", "")),
		"role_seen": str(member.role),
		"first_reply": replies.get("join-sow", {}),
		"replay_sequence": int((replies.get("join-sow", {}) as Dictionary).get("sequence", -1)),
		"replay_duplicate": bool((replies.get("join-sow", {}) as Dictionary).get("duplicate", false)),
		"harvest_reason": str(harvest.get("reason", "")),
		"water_ok": bool(water_reply.get("ok", false)),
		"build_reason": str(build.get("reason", "")),
		"theft_reason": str(theft.get("reason", "")),
		"roster": member.roster,
		"restored": restored_report,
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
