extends SceneTree
## M13-14 kitchen authority over the real wire: one deployable
## `Game/world/world_server.gd` process and a real `WorldClient`, so the
## kitchen actions travel through authentication, join, RPC 3, the
## precondition sequence and the authority's own save instead of
## `WorldHost.execute_for_member` called directly.
##
## Covers: a member's `start` and `collect` return `ok` and the authority's
## `farm.json` kitchen document really changes (stock, made count, revision)
## while only the member's own pocket is debited; replaying the committed id
## over the network reports `duplicate` without a second basket or dish; an old
## revision is refused as `stale_kitchen` with the document unchanged; a command
## carrying `actor` or `decorations` is refused as `invalid_command`; a visitor
## code is refused as `forbidden`; and a client reconnect plus an authority
## restart both keep the committed kitchen document and still report the same
## id as a duplicate.
##
## Seed state: the fixture writes a plain `farm.json` with two greens in the
## member's own bag before the server starts, because growing a crop in a real
## authority process would need 30 wall-clock minutes. Everything after the
## seed (join, commands, persistence, restart) is the production path.
##
## No UI, art, RenderingServer frame or screenshot is used, so this runs in the
## headless rule group. One unique directory under .local/verification/ holds
## the world, logs and lock.

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const FarmState = preload("res://farm/farm_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const START: float = 1800000000.0
const COOK_DONE_OFFSET: float = 20.0
const WORLD: String = "world-kitchen-network"
const GRANT_ID: String = "server-invite"

const PLAYER_A: String = "player_00000000000000000000000000000091"
const NAME_A: String = "阿灶"
const SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMzE="
const PLAYER_V: String = "player_00000000000000000000000000000092"
const NAME_V: String = "访客"
const SECRET_V: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMzI="

const START_ID: String = "knet-start"
const COLLECT_ID: String = "knet-collect"
const STALE_ID: String = "knet-stale"
const FORGED_ACTOR_ID: String = "knet-forged-actor"
const FORGED_DECORATIONS_ID: String = "knet-forged-decorations"
const VISITOR_ID: String = "knet-visitor-start"
const RESTART_STALE_ID: String = "knet-restart-stale"

var dir: String = ""
var world_dir: String = ""
var port: int = 0
var url: String = ""
var server_pid: int = 0
var client: WorldClient
var codes: Dictionary = {}
var checks: int = 0
var failures: Array[String] = []
var _ready: bool = false
var _refusals: Array[String] = []
var _command_pending: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/kitchen-network-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	_seed_world()
	if not await _start_authority(START, "server-1.log"):
		await _finish()
		return
	codes = _join_codes()
	_expect(not str(codes.get("member", "")).is_empty(),
		"A member join code is built from the authority's material")
	_expect(not str(codes.get("visitor", "")).is_empty(),
		"The authority wrote a visitor join code for the same endpoint")
	if str(codes.get("member", "")).is_empty() or str(codes.get("visitor", "")).is_empty():
		await _finish()
		return

	await _test_member_cooks()
	await _test_visitor_forbidden()
	await _test_reconnect_keeps_kitchen()
	await _test_server_restart_keeps_kitchen()
	await _finish()


# --------------------------------------------------------- seeded starting bag

## Two mature starter crops are harvested into the member's own pocket and the
## resulting document is written before the authority opens the directory. This
## is fixture state, not a shortcut around the command path: the kitchen
## actions below all travel over the wire.
func _seed_world() -> void:
	var store := FarmStore.new(world_dir)
	var loaded: Dictionary = store.load_state()
	_expect(bool(loaded.get("ok", false)) and str(loaded.get("kind", "")) == "missing",
		"The seed directory starts empty")
	var farm := FarmState.new(START)
	var matured: Dictionary = farm.mature_all_crops(START)
	_expect(bool(matured.get("ok", false)), "The fixture matures its starter crops")
	var first: Dictionary = farm.harvest("field_03", "cell_06", START, PLAYER_A)
	var second: Dictionary = farm.harvest("field_04", "cell_06", START, PLAYER_A)
	_expect(bool(first.get("ok", false)) and bool(second.get("ok", false)),
		"The fixture harvests two greens into the member's bag")
	_expect(int(farm.bag(PLAYER_A).get("greens", 0)) == 2,
		"The seeded member pocket really holds two greens")
	var saved: Dictionary = store.save_state(farm, Decorations.new())
	_expect(bool(saved.get("ok", false)), "The seeded world is written to farm.json")


# -------------------------------------------------------------- member cooking

func _test_member_cooks() -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		SECRET_A), "The member joins the real authority over WSS")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.MEMBER,
		"The server-invite code confers the member role")
	_expect(await _wait(func() -> bool: return _bag_greens() == 2, 15000),
		"The member's own summary shows the seeded two greens")
	_expect(int(_kitchen().get("revision", -1)) == 0,
		"A fresh shared kitchen starts at revision 0")

	var start: Dictionary = _kitchen_command(START_ID, "start",
		{"recipe": "leaf_stir", "crop": "greens", "station": "stove"}, 0, START)
	var started: Dictionary = await _submit(start)
	_expect(bool(started.get("ok", false)) and not bool(started.get("duplicate", true)),
		"Starting a dish over RPC 3 is committed by the authority (reason=%s)"
			% str(started.get("reason", "")))
	_expect(await _wait_revision(1), "The authority broadcasts the new kitchen revision")
	_expect(_bag_greens() == 1, "The member's own pocket drops to one green")
	_expect(not (_kitchen().get("jobs", {}) as Dictionary).get("stove", {}).is_empty(),
		"The shared kitchen document holds the stove job")
	var start_disk: Dictionary = _disk_kitchen()
	_expect(int(start_disk.get("revision", -1)) == 1,
		"farm.json records revision 1 after the start")
	_expect(not (start_disk.get("jobs", {}) as Dictionary).get("stove", {}).is_empty(),
		"farm.json records the stove job after the start")
	_expect(_disk_bag_greens() == 1,
		"farm.json debits only the acting member's own pocket")

	var collect: Dictionary = _kitchen_command(COLLECT_ID, "collect",
		{"station": "stove"}, 1, START + COOK_DONE_OFFSET)
	var collected: Dictionary = await _submit(collect)
	_expect(bool(collected.get("ok", false)) and not bool(collected.get("duplicate", true)),
		"Collecting the finished dish over RPC 3 is committed (reason=%s)"
			% str(collected.get("reason", "")))
	_expect(await _wait_revision(2), "The authority broadcasts the collect revision")
	var after: Dictionary = _kitchen()
	_expect(int((after.get("stock", {}) as Dictionary).get("leaf_stir", -1)) == 1,
		"The shared kitchen stock holds one finished dish")
	_expect(int(((after.get("records", {}) as Dictionary).get("leaf_stir", {}) as Dictionary)
		.get("made", -1)) == 1, "The shared kitchen record counts one dish made")
	_expect(str(after.get("display", "")) == "leaf_stir",
		"The finished dish becomes the shared display")
	_expect((after.get("jobs", {}) as Dictionary).get("stove", {}).is_empty(),
		"Collecting clears the station in the shared document")
	var collect_disk: Dictionary = _disk_kitchen()
	_expect(int(collect_disk.get("revision", -1)) == 2,
		"farm.json records revision 2 after the collect")
	_expect(int((collect_disk.get("stock", {}) as Dictionary).get("leaf_stir", -1)) == 1,
		"farm.json records the finished dish")
	_expect(int(((collect_disk.get("records", {}) as Dictionary).get("leaf_stir", {})
		as Dictionary).get("made", -1)) == 1, "farm.json records the made count")

	# Replaying the committed id over the network is a duplicate, not new work.
	var kitchen_before: String = JSON.stringify(_disk_kitchen())
	var bag_before: int = _disk_bag_greens()
	var start_replay: Dictionary = await _submit(start)
	_expect(bool(start_replay.get("ok", false))
		and bool(start_replay.get("duplicate", false)),
		"Replaying the committed start id returns duplicate (reason=%s)"
			% str(start_replay.get("reason", "")))
	_expect(JSON.stringify(_disk_kitchen()) == kitchen_before,
		"A start replay leaves the kitchen document byte-identical")
	_expect(_disk_bag_greens() == bag_before,
		"A start replay does not charge a second basket")
	var collect_replay: Dictionary = await _submit(collect)
	_expect(bool(collect_replay.get("ok", false))
		and bool(collect_replay.get("duplicate", false)),
		"Replaying the committed collect id returns duplicate")
	_expect(int((_disk_kitchen().get("stock", {}) as Dictionary).get("leaf_stir", -1)) == 1,
		"A collect replay does not mint a second dish")
	_expect(int(_disk_kitchen().get("revision", -1)) == 2,
		"Replays do not advance the revision")

	# The revision is durable authority state, not a client hint.
	var stale: Dictionary = await _submit(_kitchen_command(STALE_ID, "collect",
		{"station": "stove"}, 0, START + COOK_DONE_OFFSET))
	_expect(not bool(stale.get("ok", true))
		and str(stale.get("reason", "")) == "stale_kitchen",
		"An old revision is refused as stale_kitchen over the wire (reason=%s)"
			% str(stale.get("reason", "")))
	_expect(not str(stale.get("reason_text", "")).is_empty(),
		"The stale refusal carries a player-visible reason")
	_expect(JSON.stringify(_disk_kitchen()) == kitchen_before,
		"A stale kitchen command leaves the document byte-identical")
	_expect(_disk_bag_greens() == bag_before,
		"A stale kitchen command does not touch the pocket")

	# Identity and placement state must never travel in the payload. The client
	# normally refuses these before sending; the wire path below bypasses that
	# local check so the authority's own gate is what answers.
	var actor_forged: Dictionary = _kitchen_command(FORGED_ACTOR_ID, "start",
		{"recipe": "leaf_stir", "crop": "greens", "station": "stove"}, 2, START)
	actor_forged["actor"] = PLAYER_A
	var actor_refused: Dictionary = await _submit_raw(FORGED_ACTOR_ID, actor_forged)
	_expect(str(actor_refused.get("reason", "")) == "invalid_command",
		"A command carrying actor is refused as invalid_command by the authority (reason=%s)"
			% str(actor_refused.get("reason", "")))
	var place_forged: Dictionary = _kitchen_command(FORGED_DECORATIONS_ID, "start",
		{"recipe": "leaf_stir", "crop": "greens", "station": "garden_rack"}, 2, START)
	place_forged["decorations"] = {"drying_rack": {"unlocked": true, "placed": true}}
	var place_refused: Dictionary = await _submit_raw(FORGED_DECORATIONS_ID, place_forged)
	_expect(str(place_refused.get("reason", "")) == "invalid_command",
		"A command carrying decorations is refused as invalid_command (reason=%s)"
			% str(place_refused.get("reason", "")))
	_expect(not client.submit(actor_forged),
		"The client also refuses to send the forged command at all")
	_expect(JSON.stringify(_disk_kitchen()) == kitchen_before,
		"Forged commands leave the kitchen document byte-identical")
	_expect(_disk_bag_greens() == bag_before,
		"Forged commands leave the pocket untouched")
	await _close_client()


# --------------------------------------------------------------------- visitor

func _test_visitor_forbidden() -> void:
	_expect(await _open_client(str(codes.get("visitor", "")), PLAYER_V, NAME_V,
		SECRET_V), "A visitor joins over the visitor join code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")
	var before: String = JSON.stringify(_disk_kitchen())
	var refused: Dictionary = await _submit(_kitchen_command(VISITOR_ID, "start",
		{"recipe": "leaf_stir", "crop": "greens", "station": "stove"}, 2, START))
	_expect(not bool(refused.get("ok", true))
		and str(refused.get("reason", "")) == "forbidden",
		"A visitor's kitchen command is refused as forbidden (reason=%s)"
			% str(refused.get("reason", "")))
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The visitor refusal carries a player-visible reason")
	_expect(JSON.stringify(_disk_kitchen()) == before,
		"The visitor command leaves the kitchen document byte-identical")
	await _close_client()


# ------------------------------------------------------------ client reconnect

func _test_reconnect_keeps_kitchen() -> void:
	var before: String = JSON.stringify(_disk_kitchen())
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		SECRET_A), "The member rejoins after disconnecting")
	if client == null or not client.joined:
		return
	_expect(await _wait_revision(2), "The rejoined member reads revision 2")
	var kitchen: Dictionary = _kitchen()
	_expect(int((kitchen.get("stock", {}) as Dictionary).get("leaf_stir", -1)) == 1,
		"The committed dish survives the client reconnect")
	_expect(int(((kitchen.get("records", {}) as Dictionary).get("leaf_stir", {})
		as Dictionary).get("made", -1)) == 1, "The made count survives the reconnect")
	_expect(JSON.stringify(_disk_kitchen()) == before,
		"The reconnect does not rewrite the kitchen document")
	var replay: Dictionary = await _submit(_kitchen_command(START_ID, "start",
		{"recipe": "leaf_stir", "crop": "greens", "station": "stove"}, 0, START))
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"The committed start id still replays as duplicate after reconnecting (reason=%s)"
			% str(replay.get("reason", "")))
	_expect(JSON.stringify(_disk_kitchen()) == before,
		"The post-reconnect replay leaves the kitchen document byte-identical")
	await _close_client()


# ------------------------------------------------------------ authority restart

func _test_server_restart_keeps_kitchen() -> void:
	var before: String = JSON.stringify(_disk_kitchen())
	await _stop_server()
	if not await _start_authority(START, "server-2.log"):
		return
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		SECRET_A), "The member joins the restarted authority")
	if client == null or not client.joined:
		return
	_expect(await _wait_revision(2), "The restarted authority serves revision 2")
	_expect(int((_kitchen().get("stock", {}) as Dictionary).get("leaf_stir", -1)) == 1,
		"The finished dish survives the authority restart")
	_expect(JSON.stringify(_disk_kitchen()) == before,
		"The restart loads farm.json without rewriting the kitchen document")
	var replay: Dictionary = await _submit(_kitchen_command(COLLECT_ID, "collect",
		{"station": "stove"}, 1, START + COOK_DONE_OFFSET))
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"The committed collect id still replays as duplicate after the restart (reason=%s)"
			% str(replay.get("reason", "")))
	_expect(JSON.stringify(_disk_kitchen()) == before,
		"The post-restart replay leaves the kitchen document byte-identical")
	var stale: Dictionary = await _submit(_kitchen_command(RESTART_STALE_ID, "collect",
		{"station": "stove"}, 0, START + COOK_DONE_OFFSET))
	_expect(str(stale.get("reason", "")) == "stale_kitchen",
		"The restarted authority still refuses the old revision as stale_kitchen")
	await _close_client()


# ------------------------------------------------------------------- authority

func _start_authority(now: float, log_name: String) -> bool:
	if port <= 0:
		port = _free_port()
		url = "wss://127.0.0.1:%d" % port
		_expect(port > 0, "A free loopback port is available")
		if port <= 0:
			return false
	server_pid = _spawn_server(now, log_name)
	_expect(server_pid > 0, "The authority process starts (%s)" % log_name)
	if server_pid <= 0:
		return false
	var running: bool = await _wait(func() -> bool:
		var status: Dictionary = _status()
		return str(status.get("state", "")) == "running" \
			and int(status.get("pid", 0)) == server_pid, 25000)
	_expect(running, "The authority reports ready (%s)" % log_name)
	if not running:
		return false
	_expect(_status().get("world_id", "") == WORLD,
		"The status file names the world this fixture serves")
	return true


func _spawn_server(now: float, log_name: String) -> int:
	var arguments := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % now, "--run-seconds=0", "--join-url=" + url,
		"--host-player=" + PLAYER_A,
	])
	if OS.get_name() == "Windows":
		return OS.create_process(OS.get_executable_path(), arguments, false)
	var pieces: PackedStringArray = []
	pieces.append(_shell_quote(OS.get_executable_path()))
	for argument: String in arguments:
		pieces.append(_shell_quote(argument))
	var command: String = "exec " + " ".join(pieces) + " > " \
		+ _shell_quote(dir.path_join(log_name)) + " 2>&1"
	return OS.create_process("/bin/sh", PackedStringArray(["-c", command]), false)


func _stop_server() -> void:
	if server_pid <= 0:
		return
	var running_before: bool = OS.is_process_running(server_pid)
	var marker := FileAccess.open(world_dir.path_join("stop"), FileAccess.WRITE)
	if marker != null:
		marker.store_string("stop")
		marker.close()
	var deadline: int = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline and OS.is_process_running(server_pid):
		await create_timer(0.05).timeout
	var stopped: bool = not OS.is_process_running(server_pid)
	if running_before:
		_expect(stopped, "The authority process shuts down cleanly")
		_expect(str(_status().get("state", "")) == "stopped",
			"The shutdown is recorded in the status file")
	if not stopped:
		OS.kill(server_pid)
	server_pid = 0


func _join_codes() -> Dictionary:
	var invite_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		world_dir.path_join("invite.bin"))
	var pem: String = FileAccess.get_file_as_bytes(
		world_dir.path_join("server.crt")).get_string_from_ascii()
	var member_code: String = WorldJoinCode.encode(WorldInvite.make(
		GRANT_ID, invite_bytes, WorldInvite.MEMBER, WORLD, 0.0, false),
		url, pem, "localhost")
	var visitor_code: String = FileAccess.get_file_as_string(
		world_dir.path_join("visitor-join-code.txt")).strip_edges()
	return {"member": member_code, "visitor": visitor_code}


func _open_client(code: String, player_id: String, display_name: String,
		secret_text: String) -> bool:
	# A reconnect is a new connection: the authority frees the old peer's player
	# id when it observes the disconnect. Retry that one transient refusal
	# instead of treating a socket-close race as a failed fixture.
	for attempt: int in 3:
		_ready = false
		_refusals.clear()
		_command_pending.clear()
		client = WorldClient.new()
		client.name = "WorldClient"
		root.add_child(client)
		client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
				_now: float) -> void:
			_ready = true)
		client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
		client.lost.connect(func(reason: String) -> void: _refusals.append(reason))
		client.committed.connect(_on_committed)
		var secret: PackedByteArray = Marshalls.base64_to_raw(secret_text)
		if not client.start(code, player_id, display_name, secret):
			_expect(false, "The client accepts its join code")
			return false
		var arrived: bool = await _wait(func() -> bool:
			return (_ready and client.joined) or not _refusals.is_empty(), 20000)
		if arrived and _ready and client.joined:
			return true
		var reason: String = str(_refusals[0]) if not _refusals.is_empty() else ""
		await _close_client()
		if reason != "player_id_in_use" or attempt == 2:
			_expect(false, "The client joins: refusals=%s" % str(_refusals))
			return false
		await create_timer(1.0).timeout
	return false


func _close_client() -> void:
	if client != null:
		if is_instance_valid(client):
			client.close()
			client.queue_free()
		client = null
	_command_pending.clear()
	await process_frame
	await process_frame
	await create_timer(0.3).timeout


# ------------------------------------------------------------------- commands

func _kitchen_command(id: String, action: String, request: Dictionary,
		revision: int, at_utc: float) -> Dictionary:
	return FarmCommand.make_kitchen(id, action, request, revision, at_utc)


func _submit(command: Dictionary) -> Dictionary:
	var request_id: String = str(command.get("id", ""))
	_command_pending.erase(request_id)
	if client == null or not client.submit(command):
		_expect(false, "The command %s is sent" % request_id)
		return {"ok": false, "reason": "not_sent"}
	return await _reply(request_id)


## Sends a payload straight on the member's RPC 3 channel, skipping the client's
## own `FarmCommand.valid` check, so a forged command reaches the authority.
func _submit_raw(request_id: String, command: Dictionary) -> Dictionary:
	if client == null or client.member == null:
		_expect(false, "The forged command %s is sent" % request_id)
		return {"ok": false, "reason": "not_sent"}
	_command_pending.erase(request_id)
	client.member.submit.rpc_id(1, JSON.stringify({
		"request_id": request_id, "command": command,
		"based_on_sequence": int(client.member.last_sequence),
	}))
	return await _reply(request_id)


func _reply(request_id: String) -> Dictionary:
	var arrived: bool = await _wait(func() -> bool:
		return _command_pending.has(request_id), 20000)
	if not arrived:
		_expect(false, "A reply arrives for %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _command_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


# -------------------------------------------------------------------- fixtures

func _kitchen() -> Dictionary:
	if client == null or client.member == null:
		return {}
	var snapshot: Variant = client.member.snapshot
	if not snapshot is Dictionary:
		return {}
	var farm: Variant = (snapshot as Dictionary).get("farm")
	if not farm is Dictionary:
		return {}
	var kitchen: Variant = (farm as Dictionary).get("kitchen")
	return kitchen if kitchen is Dictionary else {}


func _bag_greens() -> int:
	if client == null or client.member == null:
		return -1
	var snapshot: Variant = client.member.snapshot
	if not snapshot is Dictionary:
		return -1
	var farm: Variant = (snapshot as Dictionary).get("farm")
	if not farm is Dictionary:
		return -1
	return _greens_in((farm as Dictionary).get("bags"))


func _disk_kitchen() -> Dictionary:
	var farm: Dictionary = _disk_farm()
	var kitchen: Variant = farm.get("kitchen")
	return kitchen if kitchen is Dictionary else {}


func _disk_bag_greens() -> int:
	return _greens_in(_disk_farm().get("bags"))


func _disk_farm() -> Dictionary:
	var path: String = world_dir.path_join("farm.json")
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return {}
	var farm: Variant = (parsed as Dictionary).get("farm")
	return farm if farm is Dictionary else {}


func _greens_in(bags_value: Variant) -> int:
	if not bags_value is Dictionary:
		return -1
	var own: Variant = (bags_value as Dictionary).get(PLAYER_A)
	if not own is Dictionary:
		return -1
	return int((own as Dictionary).get("greens", -1))


func _wait_revision(revision: int) -> bool:
	return await _wait(func() -> bool:
		return int(_kitchen().get("revision", -1)) == revision, 15000)


func _on_committed(request_id: String, payload: Dictionary) -> void:
	_command_pending[request_id] = payload


func _status() -> Dictionary:
	return _read_json(world_dir.path_join("server-status.json"))


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _wait(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _shell_quote(value: String) -> String:
	return "'" + value.replace("'", "'\\''") + "'"


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


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


## Every exit path reaches here: the client is closed and the authority process
## is stopped, so a headless run never leaves a background server behind.
func _finish() -> void:
	await _close_client()
	await _stop_server()
	for failure: String in failures:
		push_error(failure)
	print("KITCHEN_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
