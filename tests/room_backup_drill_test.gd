extends SceneTree
## M13-03: a room's complete directory survives a stop/copy/restart, and a
## truncated copy is refused without touching the original.
##
## Drives the real deployment entry (`Game/world/world_server.gd`, the same
## script `world_hosting.gd` spawns for a desktop room) exactly as an operator
## would:
##   1. start a room, join with a named identity, commit a real farm command;
##   2. stop it, copy the whole data directory to a new path (cross-machine
##      migration shape), and compare every copied byte with the original;
##   3. restart the copy on the same port with the same invite, prove the
##      identity binding still rejects a foreign proof and still admits the
##      original one, then commit a second command;
##   4. truncate one document in a copy and prove the authority refuses it while
##      the original directory is byte-for-byte unchanged;
##   5. assert exit cleanup (status stopped, no lock, no leftover process).
##
## All fixtures live under `.local/verification/room-backup-<pid>/`.

const WorldMember = preload("res://world/world_member.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const FarmStore = preload("res://farm/farm_store.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const WORLD_ID: String = "backup-drill"
const PLAYER_ID: String = "player_00000000000000000000000000000001"
## Fixed installation credential (32 raw bytes as base64), so the proof a named
## join sends is reproducible across both server runs.
const PLAYER_SECRET: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const DISPLAY_NAME: String = "阿青"
const TIMEOUT: float = 25.0
## Files a full-room backup must carry when they exist. `world.json` is the
## export package and never lives in a server data directory.
const CRITICAL_FILES: Array[String] = [
	"farm.json", "farm.backup.json", "social.json", "social.backup.json",
	"nature.json", "nature.backup.json", "player_bindings.json",
	"world.key", "server.crt", "invite.bin", "world-id.txt",
	"visitor-join-code.txt",
]

var run_dir: String = ""
var original_dir: String = ""
var copy_dir: String = ""
var damaged_dir: String = ""
var port: int = 0
var crypto := Crypto.new()
var checks: int = 0
var failures: Array[String] = []
var live_pids: Array[int] = []
var pending: Dictionary = {}
## Hash tree of the original directory once the first authority has stopped.
## The whole drill must leave it exactly as it was.
var original_baseline: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	run_dir = _repo().path_join(".local/verification/room-backup-%d" % OS.get_process_id())
	original_dir = run_dir.path_join("world-original")
	copy_dir = run_dir.path_join("world-copy")
	damaged_dir = run_dir.path_join("world-damaged")
	DirAccess.make_dir_recursive_absolute(run_dir)

	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if failures.is_empty():
		await _phase_create_room()
		await _phase_copy_and_verify()
		await _phase_restore_and_continue()
		await _phase_damaged_copy()
	_finish()


# ------------------------------------------------------- 1. room with real state

func _phase_create_room() -> void:
	var status: Dictionary = await _start(original_dir)
	_expect(not status.is_empty(), "The room starts as an authority")
	if status.is_empty():
		return
	var pid_a: int = int(status.get("pid", 0))
	_expect(str(status.get("opened", "")) == "created",
		"The first start creates the world")
	_expect(str(status.get("world_id", "")) == WORLD_ID,
		"The authority serves the requested world id")
	_expect(FileAccess.file_exists(original_dir.path_join("world.key"))
		and FileAccess.file_exists(original_dir.path_join("server.crt"))
		and FileAccess.file_exists(original_dir.path_join("invite.bin")),
		"The first run writes the key, certificate and invite")
	_expect(FileAccess.file_exists(original_dir.path_join("visitor-join-code.txt")),
		"The first run writes the care-only visitor code")

	var invite: Dictionary = _invite(original_dir)
	var cert := X509Certificate.new()
	_expect(cert.load(original_dir.path_join("server.crt")) == OK,
		"The served certificate is loadable")
	var joined: Dictionary = await _join(invite, cert, PLAYER_ID,
		Marshalls.base64_to_raw(PLAYER_SECRET), DISPLAY_NAME)
	_expect(bool(joined.get("ok", false)),
		"A named member joins the room over WSS (%s)" % str(joined.get("reason", "")))
	if not bool(joined.get("ok", false)):
		await _stop(original_dir, pid_a)
		return
	var member: WorldMember = joined.member as WorldMember
	_expect(FileAccess.file_exists(original_dir.path_join("player_bindings.json")),
		"The named join writes the identity binding sidecar")
	_expect(FarmStore.new(original_dir).load_state().ok,
		"The world documents are readable on disk while the authority runs")

	# A real persistent change through the member command path, not a hand-edit.
	var now_utc: float = Time.get_unix_time_from_system() + 1.0
	var reply: Dictionary = await _submit(member, "backup-drill-sow-1",
		FarmCommand.make_sow("backup-drill-sow-1", "field_01", "cell_01",
			"greens", now_utc))
	_expect(bool(reply.get("ok", false)),
		"The authority commits a member sow (%s)" % str(reply.get("reason", "")))
	_expect(int(reply.get("sequence", 0)) == 1,
		"The committed command advanced the sequence to 1")
	await _leave()

	await _stop(original_dir, pid_a)
	var stopped: Dictionary = _status(original_dir)
	_expect(str(stopped.get("state", "")) == "stopped",
		"The status file records the stop")
	_expect(bool(stopped.get("saved", false)), "The stop saved the world")
	_expect(not OS.is_process_running(pid_a), "The authority process exited")
	_expect(not DirAccess.dir_exists_absolute(original_dir.path_join("authority.lock")),
		"The authority lock is released on exit")
	_expect(_binding_has(original_dir), "The original binding names the joined player")

	var saved: Dictionary = FarmStore.new(original_dir).load_state()
	_expect(saved.ok, "The original world reloads after the stop")
	if saved.ok:
		_expect(int(saved.farm.transaction.sequence) == 1,
			"The committed sow was persisted by the deployed authority")
		var farm: Dictionary = saved.farm
		var cell: Dictionary = _cell(farm, "field_01", "cell_01")
		_expect(str(cell.get("crop_id", "")) == "greens",
			"The persisted field holds the sowed crop")


# ------------------------------------------- 2. whole-directory copy, byte equal

func _phase_copy_and_verify() -> void:
	var before: Dictionary = _hash_tree(original_dir)
	original_baseline = before.duplicate()
	_expect(before.size() > 0, "The original directory has files to back up")
	var copied: bool = _copy_tree(original_dir, copy_dir)
	_expect(copied, "The whole data directory copies to a clean path")
	var after_copy: Dictionary = _hash_tree(original_dir)
	_expect(_same_tree(before, after_copy),
		"Copying does not change the original directory")

	_expect(FileAccess.file_exists(copy_dir.path_join("world-id.txt")),
		"The copy carries the pinned world name")
	_expect(FileAccess.get_file_as_string(copy_dir.path_join("world-id.txt")).strip_edges()
		== WORLD_ID, "The copied world name is the same")

	var compared: int = 0
	for name: String in CRITICAL_FILES:
		var source: String = original_dir.path_join(name)
		if not FileAccess.file_exists(source):
			continue
		var target: String = copy_dir.path_join(name)
		_expect(FileAccess.file_exists(target), "The copy carries %s" % name)
		if FileAccess.file_exists(target):
			_expect(FileAccess.get_file_as_bytes(source) == FileAccess.get_file_as_bytes(target),
				"The copied %s is byte-identical" % name)
			compared += 1
	for name: String in ["farm.json", "invite.bin", "world.key", "server.crt",
			"player_bindings.json"]:
		_expect(FileAccess.file_exists(original_dir.path_join(name)),
			"The room has %s to back up" % name)
	_expect(compared >= 5, "At least five critical files were byte-compared")
	var copied_tree: Dictionary = _hash_tree(copy_dir)
	_expect(_same_tree(before, copied_tree),
		"Every copied file is byte-identical to the original tree")

	var reloaded: Dictionary = FarmStore.new(copy_dir).load_state()
	_expect(reloaded.ok, "The copied directory loads as the same world")
	if reloaded.ok:
		_expect(int(reloaded.farm.transaction.sequence) == 1,
			"The copied world resumes the saved sequence")
	_expect(_binding_has(copy_dir), "The copied binding carries the player identity")
	# Remember the copy's file count for the final measurement.
	print("ROOM_BACKUP_DRILL copy_files=%d" % copied_tree.size())


# ------------------------------------ 3. restart the copy on the same port/identity

func _phase_restore_and_continue() -> void:
	# Same port on purpose: stopping must actually release the listener, and the
	# migrated directory must not inherit a live lock.
	var status: Dictionary = await _start(copy_dir)
	_expect(not status.is_empty(), "The copied directory starts on the same port")
	if status.is_empty():
		return
	var pid_b: int = int(status.get("pid", 0))
	_expect(int(status.get("port", 0)) == port, "The restarted authority reuses the port")
	_expect(str(status.get("opened", "")) == "loaded",
		"The restarted authority loads the copied world")
	_expect(str(status.get("world_id", "")) == WORLD_ID,
		"The restarted authority keeps the world identity")

	var invite: Dictionary = _invite(copy_dir)
	var cert := X509Certificate.new()
	_expect(cert.load(copy_dir.path_join("server.crt")) == OK,
		"The copied certificate is loadable")

	# A different proof for a bound id must still be refused: that is what makes
	# "binding retained" observable rather than ordinary first-use trust.
	var foreign: Dictionary = await _join(invite, cert, PLAYER_ID,
		crypto.generate_random_bytes(32), DISPLAY_NAME)
	_expect(not bool(foreign.get("ok", false)),
		"A foreign proof for the bound player is refused")
	_expect(str(foreign.get("reason", "")) == "player_proof",
		"The refusal names the identity proof (%s)" % str(foreign.get("reason", "")))

	var joined: Dictionary = await _join(invite, cert, PLAYER_ID,
		Marshalls.base64_to_raw(PLAYER_SECRET), DISPLAY_NAME)
	_expect(bool(joined.get("ok", false)),
		"The original identity still joins the migrated room (%s)"
			% str(joined.get("reason", "")))
	if not bool(joined.get("ok", false)):
		await _stop(copy_dir, pid_b)
		return
	var member: WorldMember = joined.member as WorldMember
	_expect(int(member.last_sequence) == 1,
		"The migrated session starts from the saved sequence")

	var reply: Dictionary = await _submit(member, "backup-drill-water-2",
		FarmCommand.make_water("backup-drill-water-2", "field_01", "cell_01",
			Time.get_unix_time_from_system() + 2.0))
	_expect(bool(reply.get("ok", false)),
		"The migrated authority accepts a new command (%s)" % str(reply.get("reason", "")))
	_expect(int(reply.get("sequence", 0)) == 2,
		"The migrated authority continued the sequence to 2")
	await _leave()

	await _stop(copy_dir, pid_b)
	var stopped: Dictionary = _status(copy_dir)
	_expect(str(stopped.get("state", "")) == "stopped",
		"The migrated authority writes a stopped status")
	_expect(not OS.is_process_running(pid_b), "The migrated authority process exited")
	_expect(not DirAccess.dir_exists_absolute(copy_dir.path_join("authority.lock")),
		"The migrated authority releases its lock on exit")

	var saved: Dictionary = FarmStore.new(copy_dir).load_state()
	_expect(saved.ok, "The migrated world reloads after the second stop")
	if saved.ok:
		_expect(int(saved.farm.transaction.sequence) == 2,
			"The second committed command was persisted")
		var farm: Dictionary = saved.farm
		var cell: Dictionary = _cell(farm, "field_01", "cell_01")
		_expect(bool(cell.get("watered", false)),
			"The persisted field reflects the continued command")
	_expect(_binding_has(copy_dir), "The identity binding survived the migration")


# -------------------------------- 4. truncated copy is refused, original untouched

func _phase_damaged_copy() -> void:
	var before: Dictionary = _hash_tree(original_dir)
	_expect(_same_tree(original_baseline, before),
		"Starting and serving the copy left the original directory unchanged")
	_expect(_copy_tree(copy_dir, damaged_dir), "A second copy is made for the damage case")
	var farm_path: String = damaged_dir.path_join("farm.json")
	_expect(FileAccess.file_exists(farm_path), "The damage target exists")
	var source: PackedByteArray = FileAccess.get_file_as_bytes(farm_path)
	_expect(source.size() > 32, "The document is large enough to truncate")
	_write_bytes(farm_path, source.slice(0, 32))
	var damaged_bytes: PackedByteArray = FileAccess.get_file_as_bytes(farm_path)
	_expect(damaged_bytes.size() == 32, "The copied main document is truncated")

	var run: Dictionary = _run_once(["--data-dir=" + damaged_dir,
		"--port=%d" % port, "--world=" + WORLD_ID, "--run-seconds=2"])
	_expect(int(run.exit_code) != 0,
		"The authority refuses a truncated world (exit=%d)" % int(run.exit_code))
	_expect(str(run.output).contains("world_open"),
		"The refusal names the world open stage")
	_expect(FileAccess.get_file_as_bytes(farm_path) == damaged_bytes,
		"The refused start does not rewrite the damaged main document")
	_expect(not DirAccess.dir_exists_absolute(damaged_dir.path_join("authority.lock")),
		"The refused start releases its lock")

	var after: Dictionary = _hash_tree(original_dir)
	_expect(_same_tree(before, after),
		"The damaged copy leaves the original directory byte-for-byte unchanged")

	# The restored copy still stands on its own after the damage case.
	var restored_state: Dictionary = FarmStore.new(copy_dir).load_state()
	_expect(restored_state.ok
		and int(restored_state.farm.transaction.sequence) == 2,
		"The restored copy is still a complete world after the damage case")


# ------------------------------------------------------------------- measurement

func _finish() -> void:
	for pid: int in live_pids:
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
	live_pids.clear()

	var original_after: Dictionary = _hash_tree(original_dir)
	var restored_ok: bool = FileAccess.file_exists(copy_dir.path_join("farm.json")) \
		and _binding_has(copy_dir)
	var state_sha: String = FileAccess.get_sha256(copy_dir.path_join("farm.json")) \
		if FileAccess.file_exists(copy_dir.path_join("farm.json")) else ""
	var files: int = _hash_tree(copy_dir).size()
	var unchanged: bool = original_baseline.size() > 0 \
		and _same_tree(original_baseline, original_after)
	if original_baseline.size() == 0 and not failures.is_empty():
		# The drill stopped before the copy phase; "unchanged" is not claimed.
		unchanged = false
	print("MEASURE files=%d state_sha=%s restored=%s original_unchanged=%s" % [
		files, state_sha, str(restored_ok).to_lower(), str(unchanged).to_lower()])
	for failure: String in failures:
		push_error(failure)
	print("ROOM_BACKUP_DRILL_TEST checks=%d failures=%d root=%s" % [
		checks, failures.size(), run_dir])
	quit(0 if failures.is_empty() else 1)


# --------------------------------------------------------------- server driver

func _start(world_dir: String) -> Dictionary:
	var pid: int = OS.create_process(_exe(), PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT),
		"--", "--data-dir=" + world_dir, "--port=%d" % port,
		"--world=" + WORLD_ID, "--join-url=wss://127.0.0.1:%d" % port,
		"--run-seconds=0",
	]), false)
	if pid <= 0:
		return {}
	live_pids.append(pid)
	# A stale status file from the previous stop names a dead pid; wait for one
	# that names this process.
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var status: Dictionary = _status(world_dir)
		if str(status.get("state", "")) == "running" \
				and int(status.get("pid", 0)) == pid:
			return status
		if not OS.is_process_running(pid):
			return {}
		await create_timer(0.05).timeout
	return {}


## Operator stop: write the marker and wait for the entry to save, write the
## stopped status, release the lock and exit.
func _stop(world_dir: String, pid: int) -> void:
	var marker := FileAccess.open(world_dir.path_join("stop"), FileAccess.WRITE)
	if marker != null:
		marker.store_string("1")
		marker.close()
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var gone: bool = pid <= 0 or not OS.is_process_running(pid)
		var stopped: bool = str(_status(world_dir).get("state", "")) == "stopped"
		var unlocked: bool = not DirAccess.dir_exists_absolute(
			world_dir.path_join("authority.lock"))
		if gone and stopped and unlocked:
			return
		await create_timer(0.05).timeout
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)


func _run_once(arguments: Array) -> Dictionary:
	var output: Array = []
	var code: int = OS.execute(_exe(), PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
	] + arguments), output, true)
	return {"exit_code": code, "output": "\n".join(output)}


func _status(world_dir: String) -> Dictionary:
	var path: String = world_dir.path_join("server-status.json")
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


# --------------------------------------------------------------- member driver

func _invite(world_dir: String) -> Dictionary:
	var secret: PackedByteArray = FileAccess.get_file_as_bytes(
		world_dir.path_join("invite.bin"))
	return WorldInvite.make("server-invite", secret, WorldInvite.MEMBER,
		WORLD_ID, 0.0, false)


func _join(invite: Dictionary, cert: X509Certificate, player_id: String,
		player_secret: PackedByteArray, display_name: String) -> Dictionary:
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client("wss://127.0.0.1:%d" % port,
			TLSOptions.client(cert, "localhost")) != OK:
		return {"ok": false, "reason": "create_client"}
	root.multiplayer.multiplayer_peer = peer
	var member := WorldMember.new()
	member.name = WorldMember.SESSION_NODE_NAME
	member.secret = invite.secret
	member.grant_id = str(invite.id)
	member.world_id = WORLD_ID
	member.player_id = player_id
	member.player_secret = player_secret
	member.display_name = display_name
	root.add_child(member)
	var reasons: Array[String] = []
	member.join_failed.connect(func(reason: String) -> void: reasons.append(reason))
	var lost: Array[String] = []
	member.authority_lost.connect(func(reason: String) -> void: lost.append(reason))
	root.multiplayer.auth_callback = func(_id: int, data: PackedByteArray) -> void:
		root.multiplayer.send_auth(1,
			crypto.hmac_digest(HashingContext.HASH_SHA256, member.secret, data))
		root.multiplayer.complete_auth(1)
	member.connect_to("wss://127.0.0.1:%d" % port, member.secret, WORLD_ID)
	var started: bool = false
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if not started and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			started = true
			root.multiplayer.send_auth(1, member.auth_hello())
		if member.is_joined():
			return {"ok": true, "reason": "", "member": member}
		if not reasons.is_empty():
			var reason: String = reasons[0]
			# The authority's refusal is followed by a deliberate deferred close.
			# Let it finish first; closing from this side immediately would race it.
			await create_timer(0.8).timeout
			await _leave()
			return {"ok": false, "reason": reason}
		if not lost.is_empty():
			var lost_reason: String = lost[0]
			await _leave()
			return {"ok": false, "reason": lost_reason}
		await create_timer(0.05).timeout
	await _leave()
	return {"ok": false, "reason": "timeout"}


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


# ------------------------------------------------------------------- file tools

func _copy_tree(source: String, target: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(target) != OK:
		return false
	var directory := DirAccess.open(source)
	if directory == null:
		return false
	for file_name: String in directory.get_files():
		if DirAccess.copy_absolute(source.path_join(file_name),
				target.path_join(file_name)) != OK:
			return false
	for child: String in directory.get_directories():
		if not _copy_tree(source.path_join(child), target.path_join(child)):
			return false
	return true


## Every regular file under `directory`, keyed by relative path, mapped to its
## SHA-256. A tree comparison is therefore a byte-level statement.
func _hash_tree(directory: String) -> Dictionary:
	var out: Dictionary = {}
	_hash_into(directory, "", out)
	return out


func _hash_into(directory: String, prefix: String, out: Dictionary) -> void:
	var handle := DirAccess.open(directory)
	if handle == null:
		return
	for file_name: String in handle.get_files():
		out[prefix + file_name] = FileAccess.get_sha256(directory.path_join(file_name))
	for child: String in handle.get_directories():
		_hash_into(directory.path_join(child), prefix + child + "/", out)


func _same_tree(left: Dictionary, right: Dictionary) -> bool:
	if left.size() != right.size():
		return false
	for key: String in left:
		if not right.has(key) or str(right[key]) != str(left[key]):
			return false
	return true


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_buffer(bytes)
	file.close()


func _cell(snapshot: Dictionary, field_id: String, cell_id: String) -> Dictionary:
	var fields: Variant = snapshot.get("fields")
	if not fields is Dictionary:
		return {}
	var field: Variant = (fields as Dictionary).get(field_id)
	if not field is Dictionary:
		return {}
	var cells: Variant = (field as Dictionary).get("cells")
	if not cells is Dictionary:
		return {}
	var cell: Variant = (cells as Dictionary).get(cell_id)
	return cell if cell is Dictionary else {}


func _binding_has(world_dir: String) -> bool:
	var path: String = world_dir.path_join("player_bindings.json")
	if not FileAccess.file_exists(path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return false
	var state: Variant = (parsed as Dictionary).get("state")
	if not state is Dictionary:
		return false
	var players: Variant = (state as Dictionary).get("players")
	return players is Dictionary and (players as Dictionary).has(PLAYER_ID)


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
