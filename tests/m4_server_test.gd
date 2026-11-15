extends SceneTree
## M4-05: the deployable headless authority, as an operator would run it.
##
## Drives the real entry point (`Game/world/world_server.gd`) as a subprocess and
## checks what deployment actually promises:
##   - a clean directory starts, creates key/cert/invite, and reports readiness;
##   - the invite is printed exactly once, on the run that creates it;
##   - a member reaches it over WSS using only what the operator hands out;
##   - restarting from the same directory resumes the same world and sequence;
##   - bad options are refused with a reason instead of half-starting;
##   - read_only stops writes from an already connected member;
##   - stopping writes a status file and saves.
##
## All fixtures live under .local/verification.

const WorldMember = preload("res://world/world_member.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const FarmStore = preload("res://farm/farm_store.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const TIMEOUT: float = 30.0

var dir: String = ""
var checks: int = 0
var failures: Array[String] = []
var crypto := Crypto.new()
var pending: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(".local/verification/m4-server-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)

	_test_bad_options()
	_test_failed_start_keeps_markers()
	_test_first_run_material()
	await _test_deployment(dir.path_join("world"))
	_finish()


# ------------------------------------------------------- failed start markers

## A start that fails validation must not clear deployment state it never owned:
## the read-only retirement marker has to survive a refused start, and only a
## stale stop marker is the run's own scratch file.
func _test_failed_start_keeps_markers() -> void:
	var directory: String = dir.path_join("marker-kept")
	DirAccess.make_dir_recursive_absolute(directory)
	var read_only := FileAccess.open(directory.path_join("read-only"), FileAccess.WRITE)
	if read_only != null:
		read_only.store_string("1")
		read_only.close()
	var refused: Dictionary = _run_once(["--data-dir=" + directory, "--port=abc",
		"--run-seconds=2"])
	_expect(int(refused.exit_code) != 0, "A start with an invalid port fails")
	_expect(FileAccess.file_exists(directory.path_join("read-only")),
		"A failed start does not clear the read-only retirement marker")
	_expect(not FileAccess.file_exists(directory.path_join("authority.lock")),
		"A failed start releases the directory lock")


# --------------------------------------------------------------- bad options

func _test_bad_options() -> void:
	# A server that half-starts on bad input is worse than one that refuses:
	# the operator would think the world is being served when it is not.
	var missing: Dictionary = _run_once(["--port=7801", "--run-seconds=2"])
	_expect(int(missing.exit_code) != 0, "A start without --data-dir fails")
	_expect(str(missing.output).contains("missing_data_dir"),
		"The refusal names the missing data directory")

	var bad_port: Dictionary = _run_once([
		"--data-dir=" + dir.path_join("bad-port"), "--port=abc", "--run-seconds=2"])
	_expect(int(bad_port.exit_code) != 0, "A non-numeric port is refused")
	_expect(str(bad_port.output).contains("invalid_option"),
		"The refusal names the invalid option")
	_expect(not FileAccess.file_exists(dir.path_join("bad-port/farm.json")),
		"A refused start does not create a world")
	_expect(not FileAccess.file_exists(dir.path_join("bad-port/world.key")),
		"A refused start does not create world material")

	# Out-of-range numbers are refused, not clamped: an operator who asked for
	# port 70000 must not get a server quietly listening on 65535.
	var clamped: Dictionary = _run_once([
		"--data-dir=" + dir.path_join("clamped-port"), "--port=70000", "--run-seconds=2"])
	_expect(int(clamped.exit_code) != 0, "A port outside 1-65535 is refused")
	_expect(str(clamped.output).contains("invalid_option"),
		"The refusal names the invalid option")
	_expect(not DirAccess.dir_exists_absolute(dir.path_join("clamped-port")),
		"A refused port creates no directory")

	# A relative --data-dir is a different failure: making it absolute would
	# silently bind the world to whatever directory the process happened to run
	# in. The refusal must also stop before the first write, not just before
	# serving: quit() ends the frame, so a missing return falls through.
	var relative: String = dir.trim_prefix(_repo() + "/").path_join("relative-leak")
	var leaked: String = _repo().path_join(relative)
	var relative_run: Dictionary = _run_once([
		"--data-dir=" + relative, "--port=7802", "--run-seconds=2"])
	_expect(int(relative_run.exit_code) != 0, "A relative data directory is refused")
	_expect(str(relative_run.output).contains("relative_data_dir"),
		"The refusal names the relative data directory")
	_expect(not DirAccess.dir_exists_absolute(leaked),
		"A refused relative data directory creates nothing")
	if DirAccess.dir_exists_absolute(leaked):
		DirAccess.remove_absolute(leaked)


# ----------------------------------------------------------- first-run output

func _test_first_run_material() -> void:
	var first_dir: String = dir.path_join("first")
	var port: int = _free_port()
	var join_url: String = "wss://192.168.1.20:%d" % port
	var run: Dictionary = _run_once([
		"--data-dir=" + first_dir, "--port=%d" % port, "--run-seconds=3",
		"--join-url=" + join_url])
	_expect(int(run.exit_code) == 0, "A bounded first run exits cleanly")
	var ready: Dictionary = _line_payload(run.output, "WORLD_SERVER_READY")
	_expect(not ready.is_empty(), "The first run reports readiness on stdout")
	_expect(str(ready.get("opened", "")) == "created", "The first run creates the world")
	_expect(str(ready.get("state", "")) == "running", "The first run reports running")
	var fingerprint: String = str(ready.get("cert_fingerprint", ""))
	_expect(fingerprint.count(":") == 31, "The first run reports a SHA-256 certificate fingerprint")
	var decoded: Dictionary = WorldInvite.decode(str(ready.get("invite_code", "")))
	_expect(decoded.ok, "The printed invite code parses")
	var invite: Dictionary = decoded.get("grant", {})
	_expect(str(invite.get("world_id", "")) == "world" and str(invite.get("role", "")) == "member",
		"The printed code names the world and the role it confers")
	_expect((invite.get("secret", PackedByteArray()) as PackedByteArray)
		== FileAccess.get_file_as_bytes(first_dir.path_join("invite.bin")),
		"The printed code carries the persisted secret")
	# One pasted value instead of a code, an address and a certificate file.
	var join: Dictionary = WorldJoinCode.decode(str(ready.get("join_code", "")))
	_expect(join.ok, "The first run prints a join code when given an endpoint")
	_expect(str(join.get("url", "")) == join_url, "The join code carries the operator's endpoint")
	_expect(str((join.get("grant", {}) as Dictionary).get("id", ""))
		== str(invite.get("id", "")), "The join code carries the same invitation")
	_expect(str(join.get("certificate", "")) == FileAccess.get_file_as_bytes(
		first_dir.path_join("server.crt")).get_string_from_ascii(),
		"The join code pins the served certificate")
	_expect(str(join.get("server_name", "")) == "localhost",
		"The join code names the certificate's subject")
	_expect(WorldJoinCode.tls_options(str(join.get("certificate", "")),
		str(join.get("server_name", ""))) != null, "The join code yields usable TLS options")
	var stopped: Dictionary = _line_payload(run.output, "WORLD_SERVER_STOP")
	_expect(bool(stopped.get("ok", false)), "The bounded run saves before exiting")

	# The invite is a secret: a restart must not print it again.
	var second: Dictionary = _run_once([
		"--data-dir=" + first_dir, "--port=%d" % _free_port(), "--run-seconds=2"])
	var reopened: Dictionary = _line_payload(second.output, "WORLD_SERVER_READY")
	_expect(str(reopened.get("opened", "")) == "loaded", "A restart loads the existing world")
	_expect(not reopened.has("invite_code"), "A restart does not reprint the invite secret")
	_expect(not reopened.has("join_code"), "A restart does not reprint the join code")
	_expect(str(reopened.get("cert_fingerprint", "")) == fingerprint,
		"A restart keeps the certificate a member already pinned")


# --------------------------------------------------------------- deployment

func _test_deployment(world_dir: String) -> void:
	var port: int = _free_port()
	var first: Dictionary = await _start(world_dir, port)
	_expect(not first.is_empty(), "A server directory starts as an authority")
	if first.is_empty():
		return
	_expect(str(first.get("state", "")) == "running", "The authority reports running")
	_expect(str(first.get("opened", "")) == "created",
		"The first start of an empty directory creates the world")
	_expect(int(first.get("port", 0)) == port, "The status file names the running port")
	_expect(FileAccess.file_exists(world_dir.path_join("server-status.json")),
		"A status file is written for health checks")

	# A member only needs what the operator hands over: the code and the
	# certificate. The code names the grant the host will look up.
	var decoded: Dictionary = WorldInvite.decode(
		WorldInvite.encode(WorldInvite.make("server-invite",
			FileAccess.get_file_as_bytes(world_dir.path_join("invite.bin")),
			WorldInvite.MEMBER, "world", 0.0, false)))
	_expect(decoded.ok, "The operator's invite round-trips through the code form")
	var invite: Dictionary = decoded.get("grant", {})
	var cert := X509Certificate.new()
	_expect(cert.load(world_dir.path_join("server.crt")) == OK, "The member loads the served certificate")
	var member: WorldMember = await _join(port, invite, cert, "world")
	_expect(member != null, "A member joins the deployed authority over WSS")
	if member != null:
		var submitted: Dictionary = await _submit(member, "deploy-sow",
			FarmCommand.make_sow("deploy-sow", "field_01", "cell_01", "greens",
				Time.get_unix_time_from_system()))
		_expect(bool(submitted.get("ok", false)), "The deployed authority accepts a command")
		_expect(int(submitted.get("sequence", 0)) == 1, "The command advanced the authority's sequence")
		await _leave()
	await _stop(world_dir, int(first.get("pid", 0)))

	var stopped: Dictionary = _status(world_dir)
	_expect(str(stopped.get("state", "")) == "stopped", "The status file records the stop")
	_expect(bool(stopped.get("saved", false)), "The stop saved the world")
	var saved: Dictionary = FarmStore.new(world_dir).load_state()
	_expect(saved.ok, "The world is readable after the server stops")
	if saved.ok:
		_expect(int(saved.farm.transaction.sequence) == 1,
			"The committed command was persisted by the deployed server")

	# Restart: the same directory is the same world, one sequence later.
	var second_port: int = _free_port()
	var restarted: Dictionary = await _start(world_dir, second_port)
	_expect(not restarted.is_empty(), "The directory restarts as an authority")
	_expect(str(restarted.get("world_id", "")) == "world", "The restart keeps the world identity")
	_expect(int(restarted.get("sequence", -1)) == 1, "The restart resumes the saved sequence")
	var member2: WorldMember = await _join(second_port, invite, cert, "world")
	_expect(member2 != null, "The member reconnects to the restarted authority")
	if member2 != null:
		var next: Dictionary = await _submit(member2, "deploy-sow-2",
			FarmCommand.make_sow("deploy-sow-2", "field_01", "cell_02", "greens",
				Time.get_unix_time_from_system() + 1.0))
		_expect(bool(next.get("ok", false)), "The restarted authority accepts work")
		_expect(int(next.get("sequence", 0)) == 2, "The restart continued the saved sequence")
		await _leave()

	# Retirement is an operator file, so a deploy script works the same on every
	# platform; Windows has no portable process signal.
	var marker := FileAccess.open(world_dir.path_join("read-only"), FileAccess.WRITE)
	if marker != null:
		marker.store_string("1")
		marker.close()
	await create_timer(0.8).timeout
	_expect(bool(_status(world_dir).get("read_only", false)),
		"The operator read-only marker is reflected in the status file")
	var farm_path: String = world_dir.path_join("farm.json")
	var retired_bytes: PackedByteArray = FileAccess.get_file_as_bytes(farm_path)
	# A read-only authority must not write anything, including the social record:
	# names are recorded by the next writable authority, not by the retired one.
	var social_path: String = world_dir.path_join("social.json")
	var social_before: PackedByteArray = FileAccess.get_file_as_bytes(social_path) \
		if FileAccess.file_exists(social_path) else PackedByteArray()
	var retired_member: WorldMember = await _join(second_port, invite, cert, "world",
		"retired-joiner", "Retired Joiner")
	_expect(retired_member != null, "A retired authority still lets a member connect and read")
	if retired_member != null:
		var refused: Dictionary = await _submit(retired_member, "deploy-after-retire",
			FarmCommand.make_water("deploy-after-retire", "field_01", "cell_01",
				Time.get_unix_time_from_system() + 2.0))
		_expect(not bool(refused.get("ok", true)), "A retired authority refuses a command")
		_expect(str(refused.get("reason", "")) == "read_only", "The refusal names read-only mode")
		await _leave()
	# Let at least one economy tick and one growth/tick pass in read-only mode.
	await create_timer(2.5).timeout
	var live_bytes: PackedByteArray = FileAccess.get_file_as_bytes(farm_path)
	_expect(live_bytes == retired_bytes,
		"A read-only authority does not rewrite the farm file while running")
	var retired_status: Dictionary = _status(world_dir)
	_expect(bool(retired_status.get("read_only", false)),
		"The running status still reports read-only")
	await _stop(world_dir, int(restarted.get("pid", 0)))
	var social_after: PackedByteArray = FileAccess.get_file_as_bytes(social_path) \
		if FileAccess.file_exists(social_path) else PackedByteArray()
	_expect(social_after == social_before,
		"A read-only authority writes no social record when a new player joins")
	var stopped_status: Dictionary = _status(world_dir)
	_expect(str(stopped_status.get("save", "")) == "read_only_skipped",
		"A retired authority skips the exit save")
	var stopped_bytes: PackedByteArray = FileAccess.get_file_as_bytes(farm_path)
	_expect(stopped_bytes == retired_bytes,
		"A read-only authority does not rewrite the farm file at exit")
	var after_retire: Dictionary = FarmStore.new(world_dir).load_state()
	if after_retire.ok:
		_expect(int(after_retire.farm.transaction.sequence) == 2,
			"The refused command was never written")

	# The read-only marker is durable deployment state, not a per-run scratch
	# file: a restart of the same directory must still refuse writes.
	var third_port: int = _free_port()
	var again: Dictionary = await _start(world_dir, third_port)
	_expect(not again.is_empty(), "A restart ignores the previous run's stop marker")
	_expect(bool(again.get("read_only", false)),
		"A restart of a retired directory still reports read-only")
	var retired_member2: WorldMember = await _join(third_port, invite, cert, "world")
	_expect(retired_member2 != null, "The restarted retired authority still serves reads")
	if retired_member2 != null:
		var refused_again: Dictionary = await _submit(retired_member2, "deploy-after-reopen",
			FarmCommand.make_water("deploy-after-reopen", "field_01", "cell_01",
				Time.get_unix_time_from_system() + 3.0))
		_expect(str(refused_again.get("reason", "")) == "read_only",
			"A restarted retired authority still refuses writes")
		await _leave()
	await _stop(world_dir, int(again.get("pid", 0)))

	# A second authority on the same directory is refused while the first is live.
	var locked_port: int = _free_port()
	var first_live: Dictionary = await _start(world_dir, locked_port)
	_expect(not first_live.is_empty(), "A fresh authority starts on the directory")
	var contender: Dictionary = _run_once(["--data-dir=" + world_dir,
		"--port=%d" % _free_port(), "--run-seconds=2"])
	_expect(int(contender.exit_code) != 0, "A second authority on the same directory fails")
	_expect(str(contender.output).contains("data_dir_locked"),
		"The refusal names the directory lock")
	_expect(bool(_status(world_dir).get("read_only", false)),
		"A locked-out start leaves the running authority's read-only state alone")
	await _stop(world_dir, int(first_live.get("pid", 0)))


# ------------------------------------------------------------ server driver

func _start(world_dir: String, port: int) -> Dictionary:
	var pid: int = OS.create_process(_exe(), PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT),
		"--", "--data-dir=" + world_dir, "--port=%d" % port, "--run-seconds=0",
	]), false)
	if pid <= 0:
		return {}
	# A stale status file from an earlier stop would otherwise be read as ready;
	# the entry overwrites it, so wait for one that names this process.
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var status: Dictionary = _status(world_dir)
		if str(status.get("state", "")) == "running" and int(status.get("pid", 0)) == pid:
			return status
		await create_timer(0.05).timeout
	return {}


## Operator stop: write the marker and wait for the entry to save and exit.
func _stop(world_dir: String, pid: int) -> void:
	var marker := FileAccess.open(world_dir.path_join("stop"), FileAccess.WRITE)
	if marker == null:
		return
	marker.store_string("1")
	marker.close()
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		if str(_status(world_dir).get("state", "")) == "stopped":
			return
		await create_timer(0.05).timeout
	if pid > 0:
		OS.kill(pid)


## Runs the entry point to completion and returns its exit code and output.
## Only used for runs bounded by --run-seconds, so blocking is safe.
func _run_once(arguments: Array) -> Dictionary:
	var output: Array = []
	var code: int = OS.execute(_exe(), PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
	] + arguments), output, true)
	return {"exit_code": code, "output": "\n".join(output)}


func _line_payload(output: String, tag: String) -> Dictionary:
	for line: String in output.split("\n"):
		var trimmed: String = line.strip_edges()
		if not trimmed.begins_with(tag + " "):
			continue
		var parsed: Variant = JSON.parse_string(trimmed.trim_prefix(tag + " "))
		if parsed is Dictionary:
			return parsed
	return {}


func _status(world_dir: String) -> Dictionary:
	var path: String = world_dir.path_join("server-status.json")
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


# ------------------------------------------------------------ member driver

func _join(port: int, invite: Dictionary, cert: X509Certificate, world: String,
		player_id: String = "", display_name: String = "") -> WorldMember:
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client("wss://127.0.0.1:%d" % port, TLSOptions.client(cert, "localhost")) != OK:
		return null
	root.multiplayer.multiplayer_peer = peer
	var member := WorldMember.new()
	member.name = WorldMember.SESSION_NODE_NAME
	member.secret = invite.secret
	member.grant_id = str(invite.id)
	member.world_id = world
	member.player_id = player_id
	member.display_name = display_name
	root.add_child(member)
	root.multiplayer.auth_callback = func(_id: int, data: PackedByteArray) -> void:
		root.multiplayer.send_auth(1,
			crypto.hmac_digest(HashingContext.HASH_SHA256, member.secret, data))
		root.multiplayer.complete_auth(1)
	member.connect_to("wss://127.0.0.1:%d" % port, member.secret, world)
	var started: bool = false
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if not started and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			started = true
			root.multiplayer.send_auth(1, member.auth_hello())
		if member.is_joined():
			return member
		await create_timer(0.05).timeout
	await _leave()
	return null


func _submit(member: WorldMember, request_id: String, command: Dictionary) -> Dictionary:
	pending.erase(request_id)
	if not member.reply_received.is_connected(_on_reply):
		member.reply_received.connect(_on_reply)
	var sent: Dictionary = member.submit_command(command)
	if not bool(sent.get("ok", false)):
		return sent
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if pending.has(request_id):
			return pending[request_id] as Dictionary
		await create_timer(0.05).timeout
	return {"ok": false, "reason": "no_reply"}


func _on_reply(request_id: String, payload: Dictionary) -> void:
	pending[request_id] = payload


func _leave() -> void:
	for child: Node in root.get_children():
		if child is WorldMember:
			child.queue_free()
	if root.multiplayer.multiplayer_peer != null:
		root.multiplayer.multiplayer_peer.close()
		root.multiplayer.multiplayer_peer = null
	await create_timer(0.2).timeout


# ------------------------------------------------------------------ shared

func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


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
	print("M4_SERVER_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
