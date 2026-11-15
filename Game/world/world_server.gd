extends SceneTree
## M4-05 deployable headless authority.
##
## Starts a shared world from a save directory, serves it over WSS, advances the
## world's own clock to each crop event, and writes a status file an operator or
## container health check can read. No scene, DisplayServer, GPU or audio is
## loaded.
##
## Usage:
##   godot --headless --path Game --script res://world/world_server.gd -- \
##     --data-dir=/srv/farm/world --port=7777 --world=world-alpha \
##     --invite-file=/srv/farm/invite.bin --key-file=/srv/farm/world.key \
##     --cert-file=/srv/farm/server.crt --run-seconds=0 \
##     --join-url=wss://192.168.1.20:7777
##
## Everything except --data-dir has a default: port 7777, world id "world",
## generation 1, and key/cert/invite created under the data directory on first
## run. First-run material is printed once so the operator can share the invite
## and pin the certificate fingerprint; the invite is never printed again.
## With --join-url the first run also prints one join code carrying the endpoint,
## the certificate and the invitation, so a friend pastes one value instead of
## three.
##
## Shutdown: --run-seconds=0 runs until killed. Commits are atomic per command
## (see M3-03), so a SIGKILL cannot leave a half-written world; a graceful stop
## additionally reports a final status line.

const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")

const DEFAULT_PORT: int = 7777
const TICK_SECONDS: float = 0.25
## Economy deadlines (order expiry, arrival, loan due) are independent of crop
## stages, so the authority sweeps them on their own cadence instead of waiting
## for the next growth or weather event.
const ECONOMY_TICK_SECONDS: float = 1.0
const STATUS_NAME: String = "server-status.json"
const KEY_NAME: String = "world.key"
const CERT_NAME: String = "server.crt"
const INVITE_NAME: String = "invite.bin"
## Operator control files inside the data directory.
const STOP_MARKER: String = "stop"
const READ_ONLY_MARKER: String = "read-only"
## A directory belongs to one running authority. Creating the directory is atomic,
## so two starts cannot both believe they own the world. Godot's
## `OS.is_process_running` only answers for child processes, so liveness is a
## heartbeat instead: the owner file is rewritten every few seconds and a lock
## whose heartbeat is older than LOCK_STALE_SECONDS is a crash leftover.
const LOCK_DIR_NAME: String = "authority.lock"
const LOCK_OWNER_NAME: String = "owner"
const LOCK_BEAT_SECONDS: float = 5.0
const LOCK_STALE_SECONDS: int = 30
const COMMON_NAME: String = "localhost"

var options: Dictionary = {}
var started_ms: int = 0
var status_path: String = ""
var control_dir: String = ""
var opened_kind: String = ""
var cert_fingerprint: String = ""
var _lock_dir: String = ""
var _lock_owned: bool = false
var _lock_beat_ms: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	options = _options()
	var data_directory: String = str(options.get("data-dir", "")).strip_edges()
	if data_directory.is_empty():
		_report({"ok": false, "reason": "missing_data_dir"})
		quit(2)
		return
	data_directory = ProjectSettings.globalize_path(data_directory).simplify_path()
	if not data_directory.is_absolute_path():
		_report({"ok": false, "reason": "relative_data_dir"})
		quit(2)
		# quit() only ends the frame; without this return the start would fall
		# through, create the directory relative to the cwd and write material.
		return
	if DirAccess.make_dir_recursive_absolute(data_directory) != OK:
		_report({"ok": false, "reason": "data_dir_unwritable"})
		quit(2)
		return
	status_path = data_directory.path_join(STATUS_NAME)
	control_dir = data_directory

	# Validate everything that can fail before touching operator control files: a
	# failed start must not clear a stop/read-only marker that belongs to the
	# directory's real deployment state.
	var port: int = _int_option("port", DEFAULT_PORT, 0, 65535)
	var run_seconds: float = _float_option("run-seconds", 0.0)
	if port <= 0 or run_seconds < 0.0:
		_report({"ok": false, "reason": "invalid_option"})
		quit(2)
		return
	var locked: Dictionary = _acquire_lock(data_directory)
	if not locked.ok:
		_report({"ok": false, "reason": str(locked.reason)})
		quit(2)
		return
	var material: Dictionary = _material(data_directory)
	if not material.ok:
		_abort({"ok": false, "reason": str(material.reason)})
		return

	var now: float = _float_option("now-utc", float(Time.get_unix_time_from_system()))
	started_ms = Time.get_ticks_msec()
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_server(port, "0.0.0.0", TLSOptions.server(material.key, material.cert)) != OK:
		_abort({"ok": false, "reason": "listen_failed", "port": port})
		return
	root.multiplayer.multiplayer_peer = peer
	var host := WorldHost.new()
	host.name = WorldHost.SESSION_NODE_NAME
	root.add_child(host)
	var world_id: String = str(options.get("world", "world"))
	var opened: Dictionary = host.configure(data_directory, now, world_id,
		_int_option("generation", 1, 1, 1 << 30))
	if not opened.ok:
		_abort({"ok": false, "reason": "world_open", "detail": str(opened.get("reason", ""))})
		return
	var granted: Dictionary = host.add_grant(_default_grant(material.invite, world_id))
	if not granted.ok:
		_abort({"ok": false, "reason": "grant", "detail": str(granted.get("reason", ""))})
		return

	# Only a stale stop marker is cleared, and only after this run is real. A
	# read-only marker is durable deployment state: it survives restarts until an
	# operator explicitly deletes it, so a retired directory cannot come back
	# writable by accident.
	var stale_stop: String = control_dir.path_join(STOP_MARKER)
	if FileAccess.file_exists(stale_stop):
		DirAccess.remove_absolute(stale_stop)
	var read_only: bool = FileAccess.file_exists(control_dir.path_join(READ_ONLY_MARKER))
	if read_only:
		host.read_only = true

	opened_kind = str(opened.get("kind", ""))
	cert_fingerprint = str(material.fingerprint)
	host.command_committed.connect(func(_peer_id: int, _payload: String) -> void:
		_write_status(host, port, "running"))

	var ready: Dictionary = {
		"ok": true, "state": "running", "port": port,
		"world_id": host.world_id, "run_generation": host.run_generation,
		"rules_version": WorldHost.RULES_VERSION, "protocol_version": WorldHost.PROTOCOL_VERSION,
		"data_dir": data_directory, "opened": str(opened.get("kind", "")),
		"cert_fingerprint": material.fingerprint,
		"engine": Engine.get_version_info().string,
	}
	if material.created_invite:
		# Only a freshly generated invite is shown; afterwards it is a secret on
		# disk that the operator copies out of band. The code form carries the
		# world, role and expiry so a recipient does not have to be told them.
		ready["invite_code"] = WorldInvite.encode(_default_grant(material.invite, world_id))
		ready["invite_created"] = true
		var join_url: String = str(options.get("join-url", "")).strip_edges()
		if not join_url.is_empty():
			# The endpoint has to be the address a friend can reach, which the
			# server cannot know (it binds 0.0.0.0); the operator supplies it.
			ready["join_code"] = WorldJoinCode.encode(_default_grant(material.invite, world_id),
				join_url, _pem(str(options.get("cert-file", data_directory.path_join(CERT_NAME)))),
				str(options.get("server-name", COMMON_NAME)))
	print("WORLD_SERVER_READY " + JSON.stringify(ready))
	_write_status(host, port, "running")

	var advanced_since_save: bool = false
	var economy_checked: float = -INF
	var last_economy_error: String = ""
	while true:
		if run_seconds > 0.0 and _elapsed() >= run_seconds:
			break
		# Operator controls are plain files so a deploy script works the same on
		# every supported platform; Windows has no portable stop signal.
		if FileAccess.file_exists(control_dir.path_join(STOP_MARKER)):
			break
		if not read_only and FileAccess.file_exists(control_dir.path_join(READ_ONLY_MARKER)):
			# Retiring this authority stops writes before anything is copied, so
			# the snapshot an operator takes cannot change under them.
			host.read_only = true
			read_only = true
			_write_status(host, port, "running")
		# The authority's own time is monotonic from the start instant, so a
		# wall-clock step during the run cannot move the world backwards.
		var world_now: float = now + _elapsed()
		# Economic deadlines do not produce growth events, so an idle world would
		# otherwise never expire an order or deliver an arrival until someone
		# acted. The sweep saves only when it changed something.
		if not read_only and host.world != null and world_now - economy_checked >= ECONOMY_TICK_SECONDS:
			economy_checked = world_now
			var settled: Dictionary = host.world.settle_economy_now(world_now)
			if not settled.ok:
				var reason: String = str(settled.get("reason", "unknown"))
				# One line per distinct failure, not one per second.
				if reason != last_economy_error:
					print("WORLD_SERVER_ECONOMY_ERROR " + JSON.stringify({"reason": reason}))
					last_economy_error = reason
		var next: float = host.world.next_event_utc() if host.world != null else INF
		if not read_only and is_finite(next) and next <= world_now:
			if host.world.advance_to(world_now).ok:
				advanced_since_save = true
		if not read_only and advanced_since_save:
			# Persist growth so a restart resumes from the same stage instead of
			# replaying segments from an old baseline.
			if host.world.save().ok:
				advanced_since_save = false
		_beat_lock()
		await create_timer(TICK_SECONDS).timeout

	# A retired authority must not write at exit either. The state an operator
	# copies is the last snapshot taken before the marker, and the succeeding
	# authority continues from exactly that file.
	var saved: Dictionary
	if read_only:
		saved = {"ok": true, "kind": "read_only_skipped"}
	elif host.world != null:
		saved = host.world.save()
	else:
		saved = {"ok": false, "kind": "not_open"}
	var stopped: Dictionary = {
		"ok": saved.ok, "state": "stopped", "port": port,
		"world_id": host.world_id, "run_generation": host.run_generation,
		"save": str(saved.get("kind", "")), "sequence": host.world.farm.event_sequence() if host.world.farm != null else 0,
		"elapsed_seconds": snappedf(_elapsed(), 0.001),
	}
	print("WORLD_SERVER_STOP " + JSON.stringify(stopped))
	_write_status(host, port, "stopped", saved.ok, str(saved.get("kind", "")))
	_release_lock()
	quit(0 if saved.ok else 1)


## Reports a failure and releases the directory before quitting, so a start that
## failed after taking the lock does not leave the next run blocked.
func _abort(payload: Dictionary) -> void:
	_release_lock()
	_report(payload)
	quit(2)


## Takes the data directory's single-authority lock. `make_dir` is the atomic
## step: exactly one concurrent start can create it. A lock whose heartbeat is
## old is a leftover from a killed authority and is reclaimed.
func _acquire_lock(directory: String) -> Dictionary:
	var path: String = directory.path_join(LOCK_DIR_NAME)
	if DirAccess.dir_exists_absolute(path):
		if _lock_is_fresh(path):
			return {"ok": false, "reason": "data_dir_locked"}
		if not _remove_lock(path):
			return {"ok": false, "reason": "data_dir_locked"}
	if DirAccess.make_dir_absolute(path) != OK:
		return {"ok": false, "reason": "data_dir_locked"}
	var file := FileAccess.open(path.path_join(LOCK_OWNER_NAME), FileAccess.WRITE)
	if file == null:
		DirAccess.remove_absolute(path)
		return {"ok": false, "reason": "data_dir_locked"}
	file.store_string(str(OS.get_process_id()))
	file.close()
	_lock_dir = path
	_lock_owned = true
	_lock_beat_ms = Time.get_ticks_msec()
	return {"ok": true, "reason": ""}


func _lock_is_fresh(path: String) -> bool:
	var owner: String = path.path_join(LOCK_OWNER_NAME)
	if not FileAccess.file_exists(owner):
		return false
	var modified: int = int(FileAccess.get_modified_time(owner))
	var now: int = int(Time.get_unix_time_from_system())
	return now - modified <= LOCK_STALE_SECONDS


func _remove_lock(path: String) -> bool:
	var owner: String = path.path_join(LOCK_OWNER_NAME)
	if FileAccess.file_exists(owner) and DirAccess.remove_absolute(owner) != OK:
		return false
	# A lock directory with a stale owner but a live second file is removed only
	# when its owner file is gone; leaving a directory we cannot clear would block
	# every later start.
	var listing: PackedStringArray = DirAccess.get_files_at(path)
	for entry: String in listing:
		DirAccess.remove_absolute(path.path_join(entry))
	return DirAccess.remove_absolute(path) == OK


## Keeps a live authority's lock fresh so another start is refused rather than
## reclaiming a lock whose process is still serving. No disk write per tick.
func _beat_lock() -> void:
	if not _lock_owned:
		return
	var now: int = Time.get_ticks_msec()
	if now - _lock_beat_ms < int(LOCK_BEAT_SECONDS * 1000.0):
		return
	_lock_beat_ms = now
	# Opening the owner file for write updates its mtime, which is the heartbeat.
	var file := FileAccess.open(_lock_dir.path_join(LOCK_OWNER_NAME), FileAccess.WRITE)
	if file != null:
		file.store_string(str(OS.get_process_id()))
		file.close()


func _release_lock() -> void:
	if not _lock_owned:
		return
	DirAccess.remove_absolute(_lock_dir.path_join(LOCK_OWNER_NAME))
	DirAccess.remove_absolute(_lock_dir)
	_lock_owned = false


## Loads key, certificate and invite from the data directory, creating and
## persisting whatever is missing on the first run.
func _material(data_directory: String) -> Dictionary:
	var key := CryptoKey.new()
	var cert := X509Certificate.new()
	var key_path: String = str(options.get("key-file", data_directory.path_join(KEY_NAME)))
	var cert_path: String = str(options.get("cert-file", data_directory.path_join(CERT_NAME)))
	var created_certificate: bool = false
	var have_material: bool = FileAccess.file_exists(key_path) and FileAccess.file_exists(cert_path)
	if not have_material or key.load(key_path) != OK or cert.load(cert_path) != OK:
		var crypto := Crypto.new()
		key = crypto.generate_rsa(2048)
		cert = crypto.generate_self_signed_certificate(key, "CN=%s,O=farm,C=CN" % COMMON_NAME)
		if key == null or cert == null:
			return {"ok": false, "reason": "generate_certificate"}
		if key.save(key_path) != OK or cert.save(cert_path) != OK:
			return {"ok": false, "reason": "write_certificate"}
		created_certificate = true
	var invite := PackedByteArray()
	var invite_path: String = str(options.get("invite-file", data_directory.path_join(INVITE_NAME)))
	var created_invite: bool = false
	var invite_file := FileAccess.open(invite_path, FileAccess.READ)
	if invite_file != null:
		invite = invite_file.get_buffer(invite_file.get_length())
		invite_file.close()
	if invite.size() != 32:
		invite = Crypto.new().generate_random_bytes(32)
		var written := FileAccess.open(invite_path, FileAccess.WRITE)
		if written == null:
			return {"ok": false, "reason": "write_invite"}
		written.store_buffer(invite)
		written.close()
		created_invite = true
	return {"ok": true, "key": key, "cert": cert, "invite": invite,
		"created_invite": created_invite, "created_certificate": created_certificate,
		"fingerprint": _fingerprint(cert_path)}


## The entry grants one long-lived member invitation. An operator can replace the
## invite file to rotate it, and adding short-lived or read-only grants is a UI
## concern on top of WorldHost.add_grant().
func _default_grant(secret: PackedByteArray, world_id: String) -> Dictionary:
	return WorldInvite.make("server-invite", secret, WorldInvite.MEMBER, world_id, 0.0, false)


## SHA-256 over the certificate's DER bytes, as colon-separated hex.
## Godot exposes no fingerprint accessor, so the PEM body is decoded here.
## The file is read as bytes: converting it through X509Certificate.save_to_string()
## pulls the DER tail through a text decoder that rejects embedded NULs.
func _pem(cert_path: String) -> String:
	return FileAccess.get_file_as_bytes(cert_path).get_string_from_ascii()


func _fingerprint(cert_path: String) -> String:
	var pem: String = _pem(cert_path)
	var body: PackedStringArray = PackedStringArray()
	for line: String in pem.split("\n"):
		var trimmed: String = line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("-----"):
			continue
		body.append(trimmed)
	var der: PackedByteArray = Marshalls.base64_to_raw("".join(body))
	if der.is_empty():
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update(der)
	var parts: PackedStringArray = PackedStringArray()
	for byte: int in context.finish():
		parts.append("%02X" % byte)
	return ":".join(parts)


func _write_status(host: WorldHost, port: int, state: String, saved: bool = false,
		save_kind: String = "") -> void:
	if status_path.is_empty() or host == null or not is_instance_valid(host):
		return
	var summary: Dictionary = host.world.summary() if host.world != null and host.world.farm != null else {}
	var payload: Dictionary = {
		"state": state, "port": port, "pid": OS.get_process_id(),
		"world_id": host.world_id, "run_generation": host.run_generation,
		"opened": opened_kind, "cert_fingerprint": cert_fingerprint,
		"saved": saved, "save": save_kind,
		"read_only": host.read_only, "members": host.member_count(),
		"sequence": int(summary.get("committed_sequence", 0)),
		"world_now_utc": summary.get("now_utc"),
		"elapsed_seconds": snappedf(_elapsed(), 0.001),
	}
	var file := FileAccess.open(status_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload))
		file.close()


func _elapsed() -> float:
	return float(Time.get_ticks_msec() - started_ms) / 1000.0


func _options() -> Dictionary:
	var parsed: Dictionary = {}
	for argument: String in OS.get_cmdline_user_args():
		if not argument.begins_with("--"):
			continue
		var body: String = argument.trim_prefix("--")
		var split: int = body.find("=")
		if split <= 0:
			parsed[body] = ""
		else:
			parsed[body.substr(0, split)] = body.substr(split + 1)
	return parsed


func _int_option(name: String, fallback: int, minimum: int, maximum: int) -> int:
	if not options.has(name):
		return fallback
	var text: String = str(options[name])
	if not text.is_valid_int():
		return -1
	return clampi(int(text), minimum, maximum)


func _float_option(name: String, fallback: float) -> float:
	if not options.has(name):
		return fallback
	var text: String = str(options[name])
	if not text.is_valid_float():
		return -1.0
	return float(text)


func _report(payload: Dictionary) -> void:
	print("WORLD_SERVER_ERROR " + JSON.stringify(payload))
