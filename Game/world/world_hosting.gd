extends RefCounted
## Starts this machine's own authority as a separate process.
##
## Godot keeps one SceneMultiplayer per tree, so the desktop client cannot host
## and play in the same process. A room therefore means: spawn the headless
## authority on a loopback/LAN port, wait for its status file, then join it like
## any other friend. Nothing here touches RPC; it only produces the process and
## the join code the host can share.
##
## The server entry point is a project script, so hosting requires an editor
## build. An exported game would need the server script in the export and is not
## supported yet; `start()` says so instead of failing later.

const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")

const STATUS_FILE: String = "server-status.json"
const INVITE_FILE: String = "invite.bin"
## A rotation keeps the replaced invitation beside it, so an operator can still
## recover the previous code by hand if a new one was never delivered.
const INVITE_PREVIOUS: String = "invite.previous.bin"
## The replacement is fully written and read back under this name before it is
## renamed over `invite.bin`; a failed rotation therefore never exposes a
## truncated invitation as the current one.
const INVITE_PENDING: String = "invite.pending.bin"
const CERT_FILE: String = "server.crt"
## Written by the authority, not assembled here: the visitor secret never reaches
## this process. The desktop only reads the finished code and shows it.
const VISITOR_CODE_FILE: String = "visitor-join-code.txt"
const STOP_FILE: String = "stop"
const SERVER_SCRIPT: String = "Game/world/world_server.gd"
## How long `rotate_invites()` waits for the restarted authority to report
## ready. The graceful-stop budget is the caller's `wait_ms`; restarting also
## loads the world and certificate, which is unrelated to how long a stop takes.
const RESTART_TIMEOUT_MS: int = 30000

var data_directory: String = ""
var world_id: String = "world"
var port: int = 0
var pid: int = 0
## Carried across a rotation so the restarted authority keeps the same host
## binding instead of silently becoming an anonymous room.
var host_player: String = ""


## Spawns the authority. Returns {ok, reason} without waiting for readiness;
## call `poll()` until it answers. `public_url` is what a friend can reach: the
## LAN address of this machine, never 0.0.0.0.
func start(directory: String, world: String, chosen_port: int,
		host_player: String = "") -> Dictionary:
	if not OS.has_feature("editor"):
		return {"ok": false, "reason": "unsupported_build"}
	if pid > 0:
		return {"ok": false, "reason": "already_running"}
	if not directory.strip_edges().is_absolute_path():
		return {"ok": false, "reason": "invalid_directory"}
	if chosen_port <= 0 or chosen_port > 65535:
		return {"ok": false, "reason": "invalid_port"}
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return {"ok": false, "reason": "directory_unwritable"}
	data_directory = directory
	world_id = world
	port = chosen_port
	self.host_player = host_player.strip_edges()
	# A previous run leaves "stopped" in the status file and may have left a stop
	# marker or an old visitor code behind; any of them would be read as this
	# room's answer before it starts.
	for leftover: String in [STATUS_FILE, STOP_FILE, VISITOR_CODE_FILE]:
		var path: String = directory.path_join(leftover)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	var game: String = ProjectSettings.globalize_path("res://").trim_suffix("/")
	var script: String = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir() \
		.path_join(SERVER_SCRIPT)
	var arguments := PackedStringArray([
		"--headless", "--path", game, "--script", script, "--",
		"--data-dir=" + directory, "--port=%d" % port, "--world=" + world_id,
		"--join-url=" + url(),
	])
	# 房主玩家是参战风险声明的唯一合法声明人。没有本机玩家身份时保持空值，
	# 服务器照常开房，但参与制度操作会返回 `no_host`，而不是虚构房主。
	if not host_player.strip_edges().is_empty():
		arguments.append("--host-player=" + host_player.strip_edges())
	pid = OS.create_process(OS.get_executable_path(), arguments, false)
	if pid <= 0:
		pid = 0
		return {"ok": false, "reason": "spawn_failed"}
	return {"ok": true, "reason": ""}


## Reads the authority's status file once it exists and builds the join code a
## friend needs. `{ok:false, reason:"pending"}` means "keep waiting". The visitor
## code is an optional extra: a room with no readable one still reports success.
func poll() -> Dictionary:
	if pid <= 0:
		return {"ok": false, "reason": "not_started"}
	var status_path: String = data_directory.path_join(STATUS_FILE)
	if not FileAccess.file_exists(status_path):
		if not OS.is_process_running(pid):
			return {"ok": false, "reason": "server_exited"}
		return {"ok": false, "reason": "pending"}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(status_path))
	var status: Dictionary = parsed if parsed is Dictionary else {}
	if str(status.get("state", "")) != "running":
		return {"ok": false, "reason": "server_" + str(status.get("state", "unknown"))}
	var invite: PackedByteArray = FileAccess.get_file_as_bytes(data_directory.path_join(INVITE_FILE))
	var certificate: String = FileAccess.get_file_as_bytes(
		data_directory.path_join(CERT_FILE)).get_string_from_ascii()
	var grant: Dictionary = WorldInvite.make("server-invite", invite,
		WorldInvite.MEMBER, world_id, 0.0, false)
	var code: String = WorldJoinCode.encode(grant, url(), certificate, "localhost")
	if code.is_empty():
		return {"ok": false, "reason": "join_code"}
	# The visitor code is optional for the room: a missing or unreadable file means
	# this room has no care-only credential to show, not that the world failed to
	# start. The member code and "enter this room" stay usable either way.
	var visitor_path: String = data_directory.path_join(VISITOR_CODE_FILE)
	var visitor_code: String = ""
	if FileAccess.file_exists(visitor_path):
		var candidate: String = FileAccess.get_file_as_string(visitor_path).strip_edges()
		var visitor: Dictionary = WorldJoinCode.decode(candidate)
		if bool(visitor.get("ok", false)) \
				and str((visitor.get("grant", {}) as Dictionary).get("role", "")) == WorldInvite.VISITOR:
			visitor_code = candidate
	return {"ok": true, "reason": "", "join_code": code, "visitor_join_code": visitor_code,
		"url": url(), "pid": pid, "world_id": world_id}


## The address this machine offers to a friend: a private LAN IPv4 when there
## is one, loopback otherwise (a room on the same machine still works).
func url() -> String:
	var address: String = "127.0.0.1"
	for candidate: String in IP.get_local_addresses():
		if candidate.contains(":"):
			continue
		if candidate.begins_with("127.") or candidate.begins_with("169.254."):
			continue
		if candidate.begins_with("192.168.") or candidate.begins_with("10.") \
				or candidate.begins_with("172.16.") or candidate.begins_with("172.17.") \
				or candidate.begins_with("172.18.") or candidate.begins_with("172.19.") \
				or candidate.begins_with("172.2") or candidate.begins_with("172.30.") \
				or candidate.begins_with("172.31."):
			address = candidate
			break
	return "wss://%s:%d" % [address, port]


## Replaces the room's invitation with a fresh one and restarts the authority on
## the same directory and port. Stopping first is deliberate: the authority
## builds its grant table from `invite.bin` at startup, so the old member and
## visitor codes must be gone before the new file can be served. Members
## connected to the old process are disconnected by that stop; that is the
## documented meaning of rotating a leaked code.
##
## The new file is written and read back before it replaces `invite.bin`, and
## the old file is moved aside to `invite.previous.bin`. If any step fails the
## previous invitation is put back and the room is restarted on it, so a named
## failure never leaves the old codes dead or a half-written file in place.
func rotate_invites(wait_ms: int = 8000) -> Dictionary:
	if pid <= 0 or data_directory.is_empty():
		return {"ok": false, "reason": "not_started"}
	if not OS.has_feature("editor"):
		return {"ok": false, "reason": "unsupported_build"}
	var invite_path: String = data_directory.path_join(INVITE_FILE)
	var previous_path: String = data_directory.path_join(INVITE_PREVIOUS)
	var pending_path: String = data_directory.path_join(INVITE_PENDING)
	if not FileAccess.file_exists(invite_path):
		return {"ok": false, "reason": "invite_missing"}
	# Build the replacement while the room is still serving: a disk failure here
	# leaves the running room and its current codes untouched.
	if not _rotate_pending_write(pending_path):
		DirAccess.remove_absolute(pending_path)
		return {"ok": false, "reason": "write_failed"}
	# The authority builds its grant table from `invite.bin` at startup, so the
	# old member and visitor codes must be gone before the new file is served.
	# Members connected to the old process are disconnected by this stop; that
	# is the documented meaning of rotating a leaked code.
	var stopped_pid: int = pid
	stop(wait_ms)
	_clear_own_leftover_lock(stopped_pid)
	# Preserve the old file, not the one we just wrote. A leftover from an
	# earlier failed attempt is replaced only after the current file moved.
	if FileAccess.file_exists(previous_path):
		DirAccess.remove_absolute(previous_path)
	if DirAccess.rename_absolute(invite_path, previous_path) != OK:
		DirAccess.remove_absolute(pending_path)
		return _rotate_restore("archive_failed", invite_path, previous_path, pending_path)
	if DirAccess.rename_absolute(pending_path, invite_path) != OK:
		return _rotate_restore("replace_failed", invite_path, previous_path, pending_path)
	# The file is now the new invitation, but the old room is stopped. Restarting
	# is what makes the rotation real; a failed restart puts the old file back so
	# the answer is never "new file, no room".
	var restarted: Dictionary = _rotate_restart()
	if not bool(restarted.get("ok", false)):
		return _rotate_restore(str(restarted.get("reason", "restart_failed")),
			invite_path, previous_path, pending_path)
	restarted["reason"] = ""
	restarted["previous"] = INVITE_PREVIOUS
	return restarted


## Spawns the authority again on the same port with the directory's current
## invitation and waits for its first ready answer. Leaves `pid` set to the new
## process, or zero after a failed start.
func _rotate_restart() -> Dictionary:
	var started: Dictionary = start(data_directory, world_id, port, host_player)
	if not bool(started.get("ok", false)):
		return {"ok": false, "reason": str(started.get("reason", "spawn_failed"))}
	var deadline: int = Time.get_ticks_msec() + RESTART_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		var answer: Dictionary = poll()
		if bool(answer.get("ok", false)):
			return answer
		var reason: String = str(answer.get("reason", ""))
		if not reason.is_empty() and reason != "pending":
			stop(3000)
			return {"ok": false, "reason": reason}
		OS.delay_msec(100)
	# A room that never answered is not running: stop it before reporting.
	stop(3000)
	return {"ok": false, "reason": "timeout"}


## Restores the invitation the room had before the rotation and brings the
## authority back on it. When even that restart fails the room stays stopped;
## the caller sees the named reason and the same files an operator would.
func _rotate_restore(reason: String, invite_path: String, previous_path: String,
		pending_path: String) -> Dictionary:
	DirAccess.remove_absolute(pending_path)
	if FileAccess.file_exists(previous_path):
		DirAccess.remove_absolute(invite_path)
		if DirAccess.rename_absolute(previous_path, invite_path) != OK:
			reason = reason + "_rollback_failed"
	var recovered: Dictionary = _rotate_restart()
	if not bool(recovered.get("ok", false)):
		return {"ok": false, "reason": reason + "_restart_failed"}
	return {"ok": false, "reason": reason}


## Writes a fresh 32-byte invitation to the pending name and reads it back. A
## short or mismatched read is a failed write, not a new code.
func _rotate_pending_write(pending_path: String) -> bool:
	var secret: PackedByteArray = Crypto.new().generate_random_bytes(32)
	var file := FileAccess.open(pending_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(secret)
	file.close()
	return FileAccess.get_file_as_bytes(pending_path) == secret


## The stopped authority removes its own lock during a graceful stop. A kill can
## leave a fresh lock behind, and the restarted authority would then refuse its
## own directory as `data_dir_locked`. Only a lock naming the process this room
## just stopped is cleared; another live authority's lock is left alone.
func _clear_own_leftover_lock(stopped_pid: int) -> void:
	if stopped_pid <= 0:
		return
	var lock_path: String = data_directory.path_join("authority.lock")
	if not DirAccess.dir_exists_absolute(lock_path):
		return
	var owner_path: String = lock_path.path_join("owner")
	if not FileAccess.file_exists(owner_path):
		return
	if FileAccess.get_file_as_string(owner_path).strip_edges() != str(stopped_pid):
		return
	DirAccess.remove_absolute(owner_path)
	DirAccess.remove_absolute(lock_path)


func is_running() -> bool:
	return pid > 0 and OS.is_process_running(pid)


## Asks the authority to stop through its control file and, if it does not exit
## in time, terminates the process. The world is committed per command, so a
## kill cannot leave a half-written farm.
func stop(wait_ms: int = 8000) -> void:
	if pid <= 0:
		return
	var marker := FileAccess.open(data_directory.path_join(STOP_FILE), FileAccess.WRITE)
	if marker != null:
		marker.store_string("stop")
		marker.close()
	var deadline: int = Time.get_ticks_msec() + wait_ms
	while Time.get_ticks_msec() < deadline and OS.is_process_running(pid):
		OS.delay_msec(50)
	if OS.is_process_running(pid):
		OS.kill(pid)
	pid = 0
