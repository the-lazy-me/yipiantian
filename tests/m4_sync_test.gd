extends SceneTree
## M4-03 prototype: two members against one authority, and a reconnect.
##
## 1. A watching member joins first. Two other members then submit a harvest on
##    the same mature cell at the same moment. Exactly one may win; the other
##    must get a rule refusal, and the stored inventory may only grow by one.
## 2. The watcher must learn about the winner's commit without asking: members
##    that stay connected are told about each other's changes.
## 3. A member whose command was committed reconnects as a new peer and retries
##    the same command id. The authority replays the recorded result; no second
##    reward and no sequence advance.
##
## Roles: --role=host, --role=member. The parent orchestrates.

const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const FarmStore = preload("res://farm/farm_store.gd")

const GRANT_ID: String = "sync-member"

const TIMEOUT: float = 15.0
const HOST_LIFETIME: float = 150.0
const START: float = 1800000000.0

var role: String = "parent"
var dir: String = ""
var port: int = 0
var url: String = ""
var report_path: String = ""
var invite: bool = false
var world: String = ""
var command_id: String = ""
var cell: String = "cell_06"
var watch_seconds: float = 0.0

var crypto := Crypto.new()
var host: WorldHost
var member: WorldMember
var checks: int = 0
var failures: Array[String] = []
var join_reason: String = ""
var lost: String = ""
var replies: Dictionary = {}
var remote_changes: Array = []


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--dir="): dir = argument.trim_prefix("--dir=")
		elif argument.begins_with("--port="): port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--url="): url = argument.trim_prefix("--url=")
		elif argument.begins_with("--report="): report_path = argument.trim_prefix("--report=")
		elif argument.begins_with("--world="): world = argument.trim_prefix("--world=")
		elif argument.begins_with("--id="): command_id = argument.trim_prefix("--id=")
		elif argument.begins_with("--watch-seconds="): watch_seconds = argument.trim_prefix("--watch-seconds=").to_float()
		elif argument == "--invite": invite = true
	_run.call_deferred()


func _run() -> void:
	match role:
		"host": await _run_host()
		"member": await _run_member()
		_: await _run_parent()


# ------------------------------------------------------------------ parent

func _run_parent() -> void:
	dir = _repo().path_join(".local/verification/m4-sync-%d" % Time.get_ticks_usec())
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
	var host_pid: int = OS.create_process(_exe(), _args_for("host", [
		"--world=world-sync", "--port=%d" % port]), false)
	_expect(host_pid > 0, "Host process starts")
	if not await _wait_file(dir.path_join("host.ready"), 25000):
		_expect(false, "Host reports ready")
		_finish()
		return

	# (1) A watcher joins and stays idle, so it has no reply of its own. Two
	# members then race for the same mature cell. Both processes are started
	# before either is awaited, so they really overlap rather than taking turns.
	var watcher_report: String = dir.path_join("member-watcher.json")
	var watcher_pid: int = OS.create_process(_exe(), _args_for("member", [
		"--id=watcher", "--report=" + watcher_report,
		"--watch-seconds=%d" % 12]), false)
	_expect(watcher_pid > 0, "The watching member starts")
	_expect(await _wait_file(dir.path_join("watcher.ready"), 25000),
		"The watching member reports that it joined")
	var race: Array[Dictionary] = await _members_together([
		["race-a", ["--id=race-a"]], ["race-b", ["--id=race-b"]]])
	var first: Dictionary = race[0]
	var second: Dictionary = race[1]
	var first_ok: bool = bool((first.get("reply", {}) as Dictionary).get("ok", false))
	var second_ok: bool = bool((second.get("reply", {}) as Dictionary).get("ok", false))
	_expect(first_ok != second_ok, "Exactly one of two concurrent harvests wins")
	# Which racer arrives first is a race, so the assertions follow the winner
	# instead of assuming a fixed order.
	var winner: Dictionary = first if first_ok else second
	var loser: Dictionary = second if first_ok else first
	var winner_id: String = "race-a" if first_ok else "race-b"
	_expect(str((loser.get("reply", {}) as Dictionary).get("reason", "")) == "empty",
		"The losing harvest is refused by the rules, not silently applied")
	_expect(int(first.get("sequence", 0)) == 1 and int(second.get("sequence", 0)) == 1,
		"Both members observed the same authority sequence")
	_expect(int((winner.get("reply", {}) as Dictionary).get("reward_amount", 0)) == 1,
		"The winner received exactly one reward")

	# (2) The watcher was told about that commit without asking for it.
	var watcher: Dictionary = {}
	if await _wait_file(watcher_report, 20000):
		watcher = _read_json(watcher_report)
	if watcher_pid > 0 and OS.is_process_running(watcher_pid):
		OS.kill(watcher_pid)
		await _wait_process(watcher_pid, 5000)
	_expect(not watcher.is_empty(), "The watching member reports a result")
	_expect(str(watcher.get("reason", "")) == "", "The watching member never lost its authority")
	_expect(bool(watcher.get("joined", false)), "The watching member stayed joined")
	var seen: Array = watcher.get("remote_changes", []) as Array
	_expect(seen.size() == 1, "The watcher saw exactly the one committed change")
	if seen.size() == 1:
		var change: Dictionary = seen[0]
		_expect(int(change.get("sequence", 0)) == 1, "The broadcast carries the commit sequence")
		_expect(str((change.get("command", {}) as Dictionary).get("kind", "")) == "harvest",
			"The broadcast carries the command a client needs to apply it")
	_expect(int(watcher.get("last_sequence", -1)) == 1,
		"The watcher advanced its applied sequence from the broadcast alone")

	# (2) The winner reconnects as a new peer and retries its committed id.
	var retry: Dictionary = await _member("retry", ["--id=" + winner_id])
	_expect(bool(retry.get("joined", false)), "A returning member rejoins as a new peer")
	_expect(bool((retry.get("reply", {}) as Dictionary).get("duplicate", false)),
		"The retried command is replayed as a duplicate")
	_expect(bool((retry.get("reply", {}) as Dictionary).get("ok", false)),
		"The replay reports the original success")
	_expect(int(retry.get("sequence", -1)) == 1, "The replay does not advance the sequence")

	_write(dir.path_join("stop"), "stop")
	await _wait_process(host_pid, 15000)
	var stored: Dictionary = _read_json(dir.path_join("host.json"))
	_expect(not stored.is_empty(), "Host writes its summary")
	_expect(int(stored.get("commands", 0)) == 1, "Only one command was ever committed")
	_expect(int(stored.get("joins", 0)) == 4,
		"Four joins succeeded (the watcher, two racers, and the return)")
	_expect(int(stored.get("sequence", 0)) == 1, "The stored world kept one event")
	var disk: Dictionary = FarmStore.new(dir.path_join("world")).load_state()
	_expect(disk.ok and disk.has("farm"), "The world reloads from disk")
	if disk.ok and disk.has("farm"):
		var snap: Dictionary = disk.farm
		_expect(int(snap.inventory.greens) == 1, "The authoritative inventory holds exactly one reward")
		_expect(int(snap.harvested.greens) == 1, "The reward was counted exactly once")
		_expect(int(snap.transaction.sequence) == 1, "One committed event on disk")
	_finish()


func _members_together(jobs: Array) -> Array[Dictionary]:
	# Launch every member first, then collect, so their commands overlap.
	var pending: Array[Dictionary] = []
	for job: Array in jobs:
		var label: String = str(job[0])
		var report: String = dir.path_join("member-%s.json" % label)
		var pid: int = OS.create_process(_exe(),
			_args_for("member", (job[1] as Array) + ["--report=" + report]), false)
		_expect(pid > 0, "Member process '%s' starts" % label)
		pending.append({"label": label, "pid": pid, "report": report})
	var out: Array[Dictionary] = []
	for job: Dictionary in pending:
		var parsed: Dictionary = {}
		if int(job.pid) > 0 and await _wait_file(str(job.report),
				int((TIMEOUT + 20.0) * 1000.0)):
			parsed = _read_json(str(job.report))
		if int(job.pid) > 0 and OS.is_process_running(int(job.pid)):
			OS.kill(int(job.pid))
			await _wait_process(int(job.pid), 5000)
		_expect(not parsed.is_empty(), "Member process '%s' reports a result" % str(job.label))
		if not parsed.is_empty():
			print("M4_SYNC_MEMBER %s %s" % [str(job.label), JSON.stringify(parsed)])
		out.append(parsed)
	return out


func _member(label: String, extra: Array) -> Dictionary:
	var report: String = dir.path_join("member-%s.json" % label)
	var pid: int = OS.create_process(_exe(),
		_args_for("member", extra + ["--report=" + report]), false)
	_expect(pid > 0, "Member process '%s' starts" % label)
	var parsed: Dictionary = {}
	if pid > 0 and await _wait_file(report, int((TIMEOUT + 20.0) * 1000.0)):
		parsed = _read_json(report)
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
		await _wait_process(pid, 5000)
	_expect(not parsed.is_empty(), "Member process '%s' reports a result" % label)
	if not parsed.is_empty():
		print("M4_SYNC_MEMBER %s %s" % [label, JSON.stringify(parsed)])
	return parsed


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
	# The race needs a mature crop: field_03/cell_06 starts mature in the
	# default layout, so no fixture command is required.
	var opened: Dictionary = host.configure(dir.path_join("world"), START, world)
	if not opened.ok:
		_host_fail("open_" + str(opened.reason))
		return
	var granted: Dictionary = host.add_grant(
		WorldInvite.make(GRANT_ID, secret, WorldInvite.MEMBER, world, 0.0, false))
	if not granted.ok:
		_host_fail("grant_" + str(granted.reason))
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
		"joins": joins.size(),
		"commands": host.world.farm.committed_command_count() if host.world.farm != null else 0,
		"sequence": host.world.farm.event_sequence() if host.world.farm != null else 0,
	}))
	quit(0)


# ------------------------------------------------------------------ member

func _run_member() -> void:
	var cert := X509Certificate.new()
	var text: String = FileAccess.get_file_as_string(dir.path_join("server.crt"))
	if text.is_empty() or cert.load_from_string(text) != OK:
		_report({"joined": false, "reason": "cert_load"})
		return
	var secret: PackedByteArray = PackedByteArray()
	var file := FileAccess.open(dir.path_join("invite.bin"), FileAccess.READ)
	if file != null:
		secret = file.get_buffer(file.get_length())
		file.close()
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client(url, TLSOptions.client(cert, "localhost")) != OK:
		_report({"joined": false, "reason": "create_client"})
		return
	root.multiplayer.multiplayer_peer = peer
	member = WorldMember.new()
	member.name = WorldMember.SESSION_NODE_NAME
	member.secret = secret
	member.grant_id = GRANT_ID
	member.world_id = world
	root.add_child(member)
	root.multiplayer.auth_callback = _member_auth
	member.join_failed.connect(func(reason: String) -> void: join_reason = reason)
	member.authority_lost.connect(func(reason: String) -> void: lost = reason)
	member.reply_received.connect(func(request_id: String, payload: Dictionary) -> void:
		replies[request_id] = payload)
	member.remote_change.connect(func(entry: Dictionary) -> void:
		remote_changes.append(entry))
	member.connect_to(url, secret, world)
	var started: bool = false
	var sent: bool = false
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	var command: Dictionary = FarmCommand.make(command_id, "field_03", cell, START)
	var watch_until: float = 0.0
	while Time.get_ticks_msec() < deadline:
		if not started and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			started = true
			root.multiplayer.send_auth(1, member.auth_hello())
		if member.is_joined() and not sent:
			sent = true
			if watch_seconds > 0.0:
				# A watcher submits nothing: it exists to prove that other
				# members' commits reach it without a local request.
				watch_until = Time.get_ticks_msec() + watch_seconds * 1000.0
				_write(dir.path_join("watcher.ready"), "ready")
			else:
				member.submit_command(command)
		if watch_until > 0.0 and Time.get_ticks_msec() >= watch_until:
			break
		if watch_until == 0.0 and replies.has(command_id):
			await create_timer(0.3).timeout
			break
		if not join_reason.is_empty() or not lost.is_empty():
			await create_timer(0.2).timeout
			break
		await create_timer(0.05).timeout
	var reply: Dictionary = replies.get(command_id, {}) as Dictionary
	_report({
		"joined": member.is_joined(),
		"reason": join_reason if not join_reason.is_empty() else lost,
		"reply": reply, "sequence": int(reply.get("sequence", -1)),
		"last_sequence": member.last_sequence,
		"remote_changes": remote_changes,
	})


func _member_auth(_id: int, data: PackedByteArray) -> void:
	root.multiplayer.send_auth(1,
		crypto.hmac_digest(HashingContext.HASH_SHA256, member.secret, data))
	root.multiplayer.complete_auth(1)


# ------------------------------------------------------------------ shared

func _report(payload: Dictionary) -> void:
	if not report_path.is_empty():
		_write(report_path, JSON.stringify(payload))
	print("M4_SYNC " + JSON.stringify(payload))
	quit(0)


func _host_fail(reason: String) -> void:
	_write(dir.path_join("host.json"), JSON.stringify({"error": reason}))
	quit(1)


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _args_for(child_role: String, extra: Array) -> PackedStringArray:
	var args := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join("tests/m4_sync_test.gd"),
		"--", "--role=" + child_role, "--dir=" + dir, "--port=%d" % port,
	])
	for value: String in extra:
		args.append(value)
	args.append("--url=wss://127.0.0.1:%d" % port)
	args.append("--world=world-sync")
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
	print("M4_SYNC_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
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
