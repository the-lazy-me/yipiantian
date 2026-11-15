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
const CERT_FILE: String = "server.crt"
## Written by the authority, not assembled here: the visitor secret never reaches
## this process. The desktop only reads the finished code and shows it.
const VISITOR_CODE_FILE: String = "visitor-join-code.txt"
const STOP_FILE: String = "stop"
const SERVER_SCRIPT: String = "Game/world/world_server.gd"

var data_directory: String = ""
var world_id: String = "world"
var port: int = 0
var pid: int = 0


## Spawns the authority. Returns {ok, reason} without waiting for readiness;
## call `poll()` until it answers. `public_url` is what a friend can reach: the
## LAN address of this machine, never 0.0.0.0.
func start(directory: String, world: String, chosen_port: int) -> Dictionary:
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
