extends SceneTree
## M4-04: stop-write boundary and handover between two authorities.
##
## Phase 1: a live host accepts one command from a real member client, then is
##          put into read-only mode. A further command from that same, already
##          connected member must be refused with read_only and must not reach
##          the store.
## Phase 2: snapshot the retired state, sign a migration descriptor for
##          generation 2, start a successor from that snapshot, and have the
##          client verify the descriptor before joining the new authority.
##
## Roles: --role=host runs an authority in its own process (SceneMultiplayer is
## per SceneTree). The parent acts as the member client in this process.

const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const Identity = preload("res://world/world_identity.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Farm = preload("res://farm/farm_state.gd")
const Decorations = preload("res://farm/decoration_state.gd")

const START: float = 1800000000.0
const TIMEOUT: float = 20.0
const HOST_LIFETIME: float = 120.0

var role: String = "parent"
var dir: String = ""
var port: int = 0
var cn: String = "localhost"
var world: String = ""
var folder: String = ""
var name: String = "host"
var generation: int = 1

var crypto := Crypto.new()
var host: WorldHost
var member: WorldMember
var checks: int = 0
var failures: Array[String] = []
var replies: Dictionary = {}
var join_reason: String = ""
var lost: String = ""


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--dir="): dir = argument.trim_prefix("--dir=")
		elif argument.begins_with("--port="): port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--world="): world = argument.trim_prefix("--world=")
		elif argument.begins_with("--folder="): folder = argument.trim_prefix("--folder=")
		elif argument.begins_with("--name="): name = argument.trim_prefix("--name=")
		elif argument.begins_with("--generation="): generation = argument.trim_prefix("--generation=").to_int()
	_run.call_deferred()


func _run() -> void:
	if role == "host":
		await _run_host()
		return
	await _run_parent()


# ------------------------------------------------------------------ parent

func _run_parent() -> void:
	dir = _repo().path_join(".local/verification/m4-move-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	world = "world-move"
	var key: CryptoKey = crypto.generate_rsa(2048)
	var cert: X509Certificate = crypto.generate_self_signed_certificate(
		key, "CN=localhost,O=farm,C=CN")
	_expect(key != null and cert != null, "World key and server certificate are generated")
	_expect(key.save(dir.path_join("world.key")) == OK and cert.save(dir.path_join("server.crt")) == OK,
		"World key and certificate are written for the hosts")
	var invite: PackedByteArray = crypto.generate_random_bytes(32)
	var file := FileAccess.open(dir.path_join("invite.bin"), FileAccess.WRITE)
	_expect(file != null, "Invite secret is written")
	if file != null:
		file.store_buffer(invite)
		file.close()
	if not failures.is_empty():
		_finish()
		return

	# Phase 1: live authority, generation 1.
	port = _free_port()
	var first: int = _spawn("primary", dir.path_join("world"), 1)
	_expect(first > 0, "The first authority starts")
	if not await _wait_file(dir.path_join("primary.ready"), 25000):
		_expect(false, "The first authority reports ready")
		_finish()
		return
	_expect(await _connect(port, invite), "A member joins the first authority")
	var accepted: Dictionary = await _submit("move-sow",
		FarmCommand.make_sow("move-sow", "field_01", "cell_01", "greens", START))
	_expect(bool(accepted.get("ok", false)), "The first authority accepts a sow")
	_expect(int(accepted.get("sequence", 0)) == 1, "The first authority committed one event")

	# Retire it while the member is still connected. The flag reaches the host
	# through a file, so wait for the host to report the mode took effect before
	# asserting on what a retired authority does.
	_write(dir.path_join("primary.readonly"), "1")
	_expect(await _wait_file(dir.path_join("primary.retired"), 15000),
		"The retired authority reports that read-only mode took effect")
	var retired: Dictionary = await _submit("move-after-retire",
		FarmCommand.make_water("move-after-retire", "field_01", "cell_01", START + 1))
	_expect(not bool(retired.get("ok", false)), "A retired authority refuses an existing member's command")
	_expect(str(retired.get("reason", "")) == "read_only", "The refusal names read-only mode")
	_expect(int(retired.get("sequence", -1)) == 1, "The refused command did not advance the sequence")
	_disconnect_member()
	_write(dir.path_join("primary.stop"), "1")
	_expect(await _wait_file(dir.path_join("primary.done"), 25000), "The first authority stops cleanly")

	var retired_disk: Dictionary = FarmStore.new(dir.path_join("world")).load_state()
	_expect(retired_disk.ok, "The retired world reloads from disk")
	if not retired_disk.ok:
		_finish()
		return
	_expect(int(retired_disk.farm.transaction.sequence) == 1,
		"The retired authority never wrote the refused command")

	# Phase 2: sign the move, start the successor from the retired snapshot.
	var snapshot: Dictionary = retired_disk.farm
	DirAccess.make_dir_recursive_absolute(dir.path_join("world2"))
	var moved := Farm.new()
	_expect(moved.restore_snapshot(snapshot), "The retired snapshot restores for the successor")
	var store2 := FarmStore.new(dir.path_join("world2"))
	_expect(store2.load_state().ok, "A fresh store opens for the successor")
	_expect(store2.save_state(moved, Decorations.new()).ok,
		"The moved snapshot is written through the versioned store")
	port = _free_port()
	var descriptor: Dictionary = Identity.sign(
		world, 2, 1, int(snapshot.transaction.sequence), snapshot,
		["wss://127.0.0.1:%d" % port], START, START + 86400.0, key)
	_expect(not descriptor.is_empty(), "A migration descriptor is signed for generation 2")
	var verified: Dictionary = Identity.verify(descriptor, key, world, 1, START)
	_expect(verified.ok, "The client accepts the move with the world key it already trusts")
	_expect((verified.endpoints as Array).has("wss://127.0.0.1:%d" % port),
		"The descriptor names the successor's address")
	# The client may only follow a generation it has not already accepted.
	_expect(Identity.verify(descriptor, key, world, 2, START).reason == "stale_generation",
		"A client that already saw generation 2 refuses this descriptor")

	var second: int = _spawn("successor", dir.path_join("world2"), 2)
	_expect(second > 0, "The successor authority starts")
	if not await _wait_file(dir.path_join("successor.ready"), 25000):
		_expect(false, "The successor reports ready")
		_finish()
		return
	_expect(await _connect(port, invite), "The client joins the successor as a new peer")
	var after_move: Dictionary = await _submit("move-sow-2",
		FarmCommand.make_sow("move-sow-2", "field_01", "cell_02", "greens", START + 2))
	_expect(bool(after_move.get("ok", false)), "The successor accepts work after the move")
	_expect(int(after_move.get("sequence", 0)) == 2, "The successor continued from the moved sequence")
	# Replaying the pre-move id must not mint a second reward on the successor.
	var replay: Dictionary = await _submit("move-sow",
		FarmCommand.make_sow("move-sow", "field_01", "cell_01", "greens", START))
	_expect(bool(replay.get("duplicate", false)), "The moved world replays the pre-move command id")
	_expect(int(replay.get("sequence", -1)) == 2, "The replay did not advance the moved sequence")
	_disconnect_member()
	_write(dir.path_join("successor.stop"), "1")
	_expect(await _wait_file(dir.path_join("successor.done"), 25000), "The successor stops cleanly")

	var moved_disk: Dictionary = FarmStore.new(dir.path_join("world2")).load_state()
	_expect(moved_disk.ok, "The moved world reloads from disk")
	if moved_disk.ok:
		_expect(int(moved_disk.farm.transaction.sequence) == 2,
			"The moved world holds exactly the two committed events")
		_expect(int(moved_disk.farm.inventory.greens) == 0,
			"Sowing two cells did not mint an inventory reward")
	_finish()


# ------------------------------------------------------------ member client

func _connect(port_value: int, invite: PackedByteArray) -> bool:
	var cert := X509Certificate.new()
	if cert.load_from_string(FileAccess.get_file_as_string(dir.path_join("server.crt"))) != OK:
		return false
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client("wss://127.0.0.1:%d" % port_value, TLSOptions.client(cert, cn)) != OK:
		return false
	root.multiplayer.multiplayer_peer = peer
	member = WorldMember.new()
	member.name = WorldMember.SESSION_NODE_NAME
	member.secret = invite
	member.world_id = world
	root.add_child(member)
	root.multiplayer.auth_callback = _member_auth
	member.join_failed.connect(func(reason: String) -> void: join_reason = reason)
	member.authority_lost.connect(func(reason: String) -> void: lost = reason)
	member.reply_received.connect(func(request_id: String, payload: Dictionary) -> void:
		replies[request_id] = payload)
	member.connect_to("wss://127.0.0.1:%d" % port_value, invite, world)
	var started: bool = false
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if not started and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			started = true
			root.multiplayer.send_auth(1, "start".to_utf8_buffer())
		if member.is_joined():
			return true
		if not join_reason.is_empty() or not lost.is_empty():
			return false
		await create_timer(0.05).timeout
	return false


func _member_auth(_id: int, data: PackedByteArray) -> void:
	root.multiplayer.send_auth(1,
		crypto.hmac_digest(HashingContext.HASH_SHA256, member.secret, data))
	root.multiplayer.complete_auth(1)


func _submit(request_id: String, command: Dictionary) -> Dictionary:
	replies.erase(request_id)
	var sent: Dictionary = member.submit_command(command)
	if not bool(sent.get("ok", false)):
		return sent
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if replies.has(request_id):
			return replies[request_id] as Dictionary
		await create_timer(0.05).timeout
	return {"ok": false, "reason": "no_reply"}


func _disconnect_member() -> void:
	if member != null and is_instance_valid(member):
		member.queue_free()
		member = null
	member = null
	if root.multiplayer.multiplayer_peer != null:
		root.multiplayer.multiplayer_peer.close()
		root.multiplayer.multiplayer_peer = null
	await create_timer(0.3).timeout


# -------------------------------------------------------------------- host

func _run_host() -> void:
	var key := CryptoKey.new()
	var cert := X509Certificate.new()
	if key.load(dir.path_join("world.key")) != OK or cert.load(dir.path_join("server.crt")) != OK:
		_write(dir.path_join(name + ".failed"), "certificate")
		quit(1)
		return
	var invite := FileAccess.open(dir.path_join("invite.bin"), FileAccess.READ)
	var secret: PackedByteArray = invite.get_buffer(invite.get_length()) if invite != null else PackedByteArray()
	if invite != null:
		invite.close()
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_server(port, "127.0.0.1", TLSOptions.server(key, cert)) != OK:
		_write(dir.path_join(name + ".failed"), "listen")
		quit(1)
		return
	root.multiplayer.multiplayer_peer = peer
	host = WorldHost.new()
	host.name = WorldHost.SESSION_NODE_NAME
	root.add_child(host)
	var opened: Dictionary = host.configure(folder, START, secret, world, generation)
	if not opened.ok:
		_write(dir.path_join(name + ".failed"), "open_" + str(opened.reason))
		quit(1)
		return
	_write(dir.path_join(name + ".ready"), "ready")
	var deadline: int = Time.get_ticks_msec() + int(HOST_LIFETIME * 1000.0)
	var reported_retired: bool = false
	while Time.get_ticks_msec() < deadline:
		if not reported_retired and FileAccess.file_exists(dir.path_join(name + ".readonly")):
			host.read_only = true
			reported_retired = true
			_write(dir.path_join(name + ".retired"), "1")
		if FileAccess.file_exists(dir.path_join(name + ".stop")):
			break
		await create_timer(0.05).timeout
	_write(dir.path_join(name + ".done"), "done")
	quit(0)


# ------------------------------------------------------------------ shared

func _spawn(name: String, folder_path: String, gen: int) -> int:
	var args := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join("tests/m4_move_test.gd"),
		"--", "--role=host", "--dir=" + dir, "--port=%d" % port,
		"--world=" + world, "--generation=%d" % gen,
		"--folder=" + folder_path, "--name=" + name,
	])
	return OS.create_process(_exe(), args, false)


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
	print("M4_MOVE_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)


func _wait_file(path: String, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(path):
			return true
		await create_timer(0.05).timeout
	return FileAccess.file_exists(path)


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
