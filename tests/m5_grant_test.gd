extends SceneTree
## M5-02: collaboration grants over a real session.
##
## A visitor cannot harvest until the world owner issues a grant naming that
## command and field. The grant admits exactly that field, is withdrawn by its
## issuer, and a time-limited grant stops working when the world clock passes its
## deadline. Revocation has to constrain the very next command, not only a new
## session.
##
## Roles: --role=host, --role=member.

const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const PLAYER_SECRET: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const WorldInvite = preload("res://world/world_invite.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Crops = preload("res://farm/crop_catalog.gd")

const GRANT_ID: String = "collab-member"
const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"
const CAROL: String = "player_00000000000000000000000000000003"
const TIMEOUT: float = 15.0
const HOST_LIFETIME: float = 180.0
const START: float = 1800000000.0

var role: String = "parent"
var dir: String = ""
var port: int = 0
var url: String = ""
var world: String = "world-collab"
var report_path: String = ""
var who: String = ""
var steps: Array = []
var at_utc: float = START
var grant_id: String = ""

var crypto := Crypto.new()
var host: WorldHost
var member: WorldMember
var checks: int = 0
var failures: Array[String] = []
var join_reason: String = ""
var lost: String = ""
var results: Array = []
var awaiting: String = ""
var step_index: int = 0


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--dir="): dir = argument.trim_prefix("--dir=")
		elif argument.begins_with("--port="): port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--url="): url = argument.trim_prefix("--url=")
		elif argument.begins_with("--report="): report_path = argument.trim_prefix("--report=")
		elif argument.begins_with("--who="): who = argument.trim_prefix("--who=")
		elif argument.begins_with("--steps="):
			steps.assign(argument.trim_prefix("--steps=").split(",", false))
		elif argument.begins_with("--at="): at_utc = argument.trim_prefix("--at=").to_float()
		elif argument.begins_with("--grant-id="): grant_id = argument.trim_prefix("--grant-id=")
	_run.call_deferred()


func _run() -> void:
	match role:
		"host": await _run_host()
		"member": await _run_member()
		_: await _run_parent()


# ------------------------------------------------------------------ parent

func _run_parent() -> void:
	dir = _repo().path_join(".local/verification/m5-grant-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var key: CryptoKey = crypto.generate_rsa(2048)
	var cert: X509Certificate = crypto.generate_self_signed_certificate(
		key, "CN=localhost,O=farm,C=CN")
	_expect(key != null and cert != null and key.save(dir.path_join("server.key")) == OK
		and cert.save(dir.path_join("server.crt")) == OK, "Server key and certificate are written")
	var secret: PackedByteArray = crypto.generate_random_bytes(32)
	var file := FileAccess.open(dir.path_join("invite.bin"), FileAccess.WRITE)
	_expect(file != null, "Invite secret is written")
	if file != null:
		file.store_buffer(secret)
		file.close()
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

	# (1) The role alone does not permit harvesting.
	var before: Dictionary = await _member("bob-before", {
		"--who": "bob", "--steps": "harvest:field_03:cell_07,state"})
	_expect(_reason(before, 0) == "forbidden", "A visitor cannot harvest without a grant")

	# (2) The owner grants exactly one command on one field.
	var granting: Dictionary = await _member("alice-grant", {
		"--who": "alice", "--steps": "grant:bob:harvest:field_03,state"})
	_expect(_ok(granting, 0), "The owner issues a field-scoped harvest grant")
	var issued: String = _grant_id(granting, 1, "out")
	_expect(not issued.is_empty(), "The issued grant is visible to its issuer")
	if not granting.get("results", []).is_empty():
		print("M5_GRANT_ID %s" % issued)

	# (3) The grant admits the owner's own crop on that field and nothing else.
	var granted: Dictionary = await _member("bob-granted", {
		"--who": "bob", "--steps": "state,harvest:field_03:cell_07,harvest:field_04:cell_06"})
	_expect(((_state_of(granted, 0).get("grants", []) as Array).size()) == 1,
		"The grantee sees the grant addressed to it")
	_expect(_ok(granted, 1), "The granted harvest is accepted")
	_expect(int(_field_of(granted, 1).get("reward_amount", 0)) == 1, "The granted harvest paid once")
	_expect(bool(_field_of(granted, 1).get("authorized", false)),
		"The reply states the grant was in force, so the sender replays the same verdict")
	_expect(not _field_of(granted, 2).has("authorized"),
		"A refused harvest carries no grant stamp")
	_expect(_reason(granted, 2) == "forbidden", "The same grant does not cover another field")

	# (4) Revocation constrains the next command, not only a new session.
	var revoking: Dictionary = await _member("alice-revoke", {
		"--who": "alice", "--steps": "revoke,state", "--grant-id": issued})
	_expect(_ok(revoking, 0), "The issuer revokes the grant")
	_expect(((_state_of(revoking, 1).get("grants", []) as Array).is_empty()),
		"The revoked grant leaves the issuer's view")
	var after: Dictionary = await _member("bob-after-revoke", {
		"--who": "bob", "--steps": "harvest:field_03:cell_10"})
	_expect(_reason(after, 0) == "forbidden", "The revoked grant no longer admits the command")

	# (5) A time-limited grant dies at its deadline as the authority clock passes
	# it. A command timestamp no longer advances that clock, so the fixture waits
	# past a short deadline instead of using a synthetic future command time.
	var expiring: Dictionary = await _member("alice-expiry", {
		"--who": "alice", "--steps": "grant-expiring:bob,state"})
	_expect(_ok(expiring, 0), "A time-limited grant is issued")
	await create_timer(11.0).timeout
	var watering: Dictionary = await _member("bob-expiry", {
		"--who": "bob", "--steps": "water:field_04:cell_06,harvest:field_03:cell_10"})
	_expect(_ok(watering, 0), "The world clock has passed the grant's deadline")
	_expect(_reason(watering, 1) == "forbidden", "The grant stops admitting commands at its deadline")

	# (6) Only the issuer may revoke. A live grant is used so the refusal is about
	# identity, not about the expired-grant cleanup.
	var fresh: Dictionary = await _member("alice-fresh", {
		"--who": "alice", "--steps": "grant:bob:harvest:field_03,state"})
	var fresh_grant: String = _grant_id(fresh, 1, "out")
	_expect(not fresh_grant.is_empty(), "A live grant is issued for the revocation check")
	var foreign: Dictionary = await _member("bob-foreign-revoke", {
		"--who": "bob", "--steps": "revoke", "--grant-id": fresh_grant})
	_expect(_reason(foreign, 0) == "not_issuer", "A grantee cannot revoke someone else's grant")
	var cleaned: Dictionary = await _member("alice-cleanup", {
		"--who": "alice", "--steps": "revoke", "--grant-id": fresh_grant})
	_expect(_ok(cleaned, 0), "The issuer withdraws the live grant")

	# (7) A hostile expiry payload is a named refusal, not a script error, and it
	# leaves the social document unchanged.
	var bad_expiry: Dictionary = await _member("alice-bad-expiry", {
		"--who": "alice", "--steps": "grant-bad-expiry:null,grant-bad-expiry:array,"
			+ "grant-bad-expiry:object,state"})
	_expect(_reason(bad_expiry, 0) == "invalid_grant", "A null expiry is refused by name")
	_expect(_reason(bad_expiry, 1) == "invalid_grant", "An array expiry is refused by name")
	_expect(_reason(bad_expiry, 2) == "invalid_grant", "An object expiry is refused by name")
	_expect((_state_of(bad_expiry, 3).get("grants", []) as Array).is_empty(),
		"A refused grant leaves the document unchanged")

	# (8) A visitor cannot manufacture consent: it may not issue a grant, and a
	# grant from anyone other than the cell's owner never authorizes harvest.
	var bob_grant: Dictionary = await _member("bob-grant", {
		"--who": "bob", "--steps": "grant:alice:harvest:field_03"})
	_expect(_reason(bob_grant, 0) == "forbidden", "A visitor cannot issue a collaboration grant")
	var foreign_crop: Dictionary = await _member("alice-foreign-crop", {
		"--who": "alice", "--steps": "harvest:field_03:cell_08,harvest:field_03:cell_09,"
			+ "harvest:field_03:cell_10"})
	_expect(_reason(foreign_crop, 0) == "theft_disabled",
		"A non-owner's grant cannot authorize harvesting Bob's crop")
	_expect(_reason(foreign_crop, 1) == "theft_disabled",
		"A non-owner's grant cannot authorize harvesting a third party's crop")
	_expect(_ok(foreign_crop, 2), "The landlord still harvests her own crop")

	_write(dir.path_join("stop"), "stop")
	await _wait_process(host_pid, 15000)
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
	if pid > 0:
		parsed = await _wait_json(report, int((TIMEOUT + 20.0) * 1000.0))
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
		await _wait_process(pid, 5000)
	_expect(not parsed.is_empty(), "Member process '%s' reports a result" % label)
	if not parsed.is_empty():
		print("M5_GRANT_MEMBER %s %s" % [label, JSON.stringify(parsed.get("results", []))])
	return parsed


func _step(results_of: Dictionary, index: int) -> Dictionary:
	var rows: Array = results_of.get("results", []) as Array
	if index >= rows.size():
		return {}
	return rows[index] as Dictionary


func _ok(results_of: Dictionary, index: int) -> bool:
	return bool(_step(results_of, index).get("ok", false))


func _reason(results_of: Dictionary, index: int) -> String:
	return str(_step(results_of, index).get("reason", ""))


func _state_of(results_of: Dictionary, index: int) -> Dictionary:
	var payload: Variant = _step(results_of, index).get("payload", {})
	if not payload is Dictionary:
		return {}
	return payload.get("state", {}) as Dictionary


func _grant_id(results_of: Dictionary, index: int, direction: String) -> String:
	var grants: Array = _state_of(results_of, index).get("grants", []) as Array
	for row: Dictionary in grants:
		if str(row.get("direction", "")) == direction:
			return str(row.get("id", ""))
	return ""


func _field_of(results_of: Dictionary, index: int) -> Dictionary:
	var payload: Variant = _step(results_of, index).get("payload", {})
	return payload if payload is Dictionary else {}


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
	# Give each player a mature crop so the fixture can prove who may consent for
	# a cell. The stock opening crops have no `planted_by`; they are not a stand-in
	# for an owner's own harvest.
	if not _seed_owned_crop("field_03", "cell_07", ALICE) \
			or not _seed_owned_crop("field_03", "cell_08", BOB) \
			or not _seed_owned_crop("field_03", "cell_09", CAROL) \
			or not _seed_owned_crop("field_03", "cell_10", ALICE):
		_host_fail("seed_owned_crops")
		return
	# One reusable member grant (the owner) and one visitor grant (the guest).
	if not host.add_grant(
			WorldInvite.make(GRANT_ID, secret, WorldInvite.MEMBER, world, 0.0, false)).ok:
		_host_fail("grant_member")
		return
	if not host.add_grant(WorldInvite.make("collab-visitor", secret,
			WorldInvite.VISITOR, world, 0.0, false)).ok:
		_host_fail("grant_visitor")
		return
	_write(dir.path_join("host.ready"), "ready")
	var deadline: int = Time.get_ticks_msec() + int(HOST_LIFETIME * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(dir.path_join("stop")):
			break
		# The authority clock advances with real time, not with the settled
		# world clock the summary carries. A member cannot infer it from the
		# snapshot, so the host publishes it for the deadline fixtures.
		_write(dir.path_join("clock.txt"), "%.3f" % host.world.authority_now_utc())
		await create_timer(0.1).timeout
	_write(dir.path_join("host.json"), JSON.stringify({"ok": true}))
	quit(0)


## Writes a mature crop owned by `player_id` through the public snapshot API.
## The fixture needs a real `planted_by` owner, which the stock opening crops
## deliberately do not have.
func _seed_owned_crop(field_id: String, cell_id: String, player_id: String) -> bool:
	var snapshot: Dictionary = host.world.farm.snapshot()
	if not snapshot.fields.has(field_id) or not snapshot.fields[field_id].cells.has(cell_id):
		return false
	var cell: Dictionary = snapshot.fields[field_id].cells[cell_id]
	cell.crop_id = "greens"
	cell.growth_seconds = float(Crops.definition("greens").duration_seconds)
	cell.last_settled_utc_seconds = START
	cell.watered = false
	cell.ground = "ready"
	cell.planted_by = player_id
	return host.world.farm.restore_snapshot(snapshot)


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
	member.grant_id = GRANT_ID if who == "alice" else "collab-visitor"
	member.world_id = world
	member.player_id = _id_of(who)
	member.player_secret = Marshalls.base64_to_raw(PLAYER_SECRET)
	member.display_name = _name_of(who)
	root.add_child(member)
	root.multiplayer.auth_callback = _member_auth
	member.join_failed.connect(func(reason: String) -> void: join_reason = reason)
	member.authority_lost.connect(func(reason: String) -> void: lost = reason)
	member.social_result.connect(func(_request_id: String, payload: Dictionary) -> void:
		results.append({"step": awaiting, "ok": bool(payload.get("ok", false)),
			"reason": str(payload.get("reason", "")), "payload": payload})
		awaiting = "")
	member.reply_received.connect(func(request_id: String, payload: Dictionary) -> void:
		if request_id in ["summary", "catch_up", "change"]:
			return
		results.append({"step": awaiting, "ok": bool(payload.get("ok", false)),
			"reason": str(payload.get("reason", "")), "payload": payload})
		awaiting = "")
	member.connect_to(url, secret, world)
	var started: bool = false
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if not started and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			started = true
			root.multiplayer.send_auth(1, member.auth_hello())
		# The join reply makes the member usable, but the summary that carries the
		# authority clock arrives separately. Steps that compute a deadline from
		# that clock must not run on the empty pre-summary snapshot.
		if member.is_joined() and awaiting.is_empty() and not member.snapshot.is_empty():
			if step_index >= steps.size():
				break
			var step: String = str(steps[step_index])
			step_index += 1
			_issue(step)
		if not join_reason.is_empty() or not lost.is_empty():
			break
		await create_timer(0.05).timeout
	var report: Dictionary = {
		"joined": member.is_joined(),
		"reason": join_reason if not join_reason.is_empty() else lost,
		"results": results,
	}
	if not report_path.is_empty():
		_write(report_path, JSON.stringify(report))
	print("M5_GRANT " + JSON.stringify(report))
	quit(0)


func _issue(step: String) -> void:
	var parts: PackedStringArray = step.split(":", false)
	awaiting = step
	# Command ids are unique across processes: two sessions must never collide on
	# the authority's idempotency ledger by accident.
	var command_id: String = "cmd-%d-%d" % [OS.get_process_id(), step_index]
	match parts[0]:
		"state":
			member.request_social("social-state", "state")
		"grant":
			member.request_social("social-grant-%d-%d" % [OS.get_process_id(), step_index], "grant",
				{"player_id": _id_of(parts[1]),
				"kinds": [parts[2]] if parts.size() > 2 else [],
				"fields": [parts[3]] if parts.size() > 3 else [],
				"expires_at": 0.0})
		"grant-expiring":
			# The deadline must be relative to the authority's live clock: it
			# advances with real time, while the summary's `now_utc` is only the
			# settled world clock. The host publishes that clock for the fixture,
			# so a slow CI host no longer issues an already-expired grant.
			var issued_at: float = _authority_clock()
			member.request_social("social-grant-expiring-%d-%d" % [OS.get_process_id(), step_index], "grant", {
				"player_id": _id_of(parts[1]), "kinds": ["harvest"], "fields": [],
				"expires_at": issued_at + 10.0})
		"grant-bad-expiry":
			# Send a JSON type the authority must refuse without calling float().
			var label: String = str(parts[1]) if parts.size() > 1 else ""
			var bad: Variant = null
			match label:
				"array": bad = []
				"object": bad = {}
				_: bad = null
			member.request_social("social-grant-bad-%d" % step_index, "grant", {
				"player_id": _id_of("bob"), "kinds": ["harvest"], "fields": [],
				"expires_at": bad})
		"revoke":
			member.request_social("social-revoke-%d-%d" % [OS.get_process_id(), step_index], "revoke", {"id": grant_id})
		"harvest":
			member.submit_command(FarmCommand.make(command_id, parts[1], parts[2], at_utc))
		"water", "till", "weed":
			member.submit_command(FarmCommand.make_tidy(
				command_id, parts[0], parts[1], parts[2], at_utc))
		_:
			awaiting = ""
			results.append({"step": step, "ok": false, "reason": "unknown_step"})


func _member_auth(_id: int, data: PackedByteArray) -> void:
	root.multiplayer.send_auth(1,
		crypto.hmac_digest(HashingContext.HASH_SHA256, member.secret, data))
	root.multiplayer.complete_auth(1)


# ------------------------------------------------------------------ shared

func _id_of(who_id: String) -> String:
	if who_id == "alice":
		return ALICE
	if who_id == "carol":
		return CAROL
	return BOB


func _name_of(who_id: String) -> String:
	return "阿青" if who_id == "alice" else "小满"


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
		"--script", _repo().path_join("tests/m5_grant_test.gd"),
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
	print("M5_GRANT_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)


func _wait_file(path: String, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(path):
			return true
		await create_timer(0.05).timeout
	return FileAccess.file_exists(path)


## 子进程的报告文件在 Windows 上可能已经存在但还没写完。等到能解析出字典再读，
## 否则一次半截读取会让整个成员步骤被误判为没有结果。
func _wait_json(path: String, timeout_ms: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var parsed: Dictionary = _read_json(path)
		if not parsed.is_empty():
			return parsed
		await create_timer(0.05).timeout
	return _read_json(path)


func _wait_process(pid: int, timeout_ms: int) -> void:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline and OS.is_process_running(pid):
		await create_timer(0.05).timeout


## The host publishes its live authority clock in `clock.txt`. A member cannot
## derive it from the summary: `now_utc` there is the settled world clock, which
## only advances when the world settles, not with real elapsed time.
func _authority_clock() -> float:
	var text: String = FileAccess.get_file_as_string(dir.path_join("clock.txt")).strip_edges()
	if text.is_empty():
		return START
	var value: Variant = text.to_float()
	return float(value) if float(value) > 0.0 else START


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
