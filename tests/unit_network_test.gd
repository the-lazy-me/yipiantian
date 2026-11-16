extends SceneTree
## Unit authority over the real wire: the RPC channels 13/14, not the host seam.
##
## A real `world_server.gd` process serves a fresh world over loopback WSS. A
## `WorldClient` joins with the operator's member invitation and drives
## `request_unit()` through the online transport:
##   - `state` answers with an empty authoritative roster;
##   - `recruit` charges the member's real economy account (opened through the
##     normal `account_open` command) and the supplies in their real bag (one
##     basket from the world's mature field_03/cell_06 crop), carries the new
##     unit and authority view in the reply, and writes `units.json`;
##   - replaying the same request id returns `duplicate` without charging cash
##     or supplies twice;
##   - `disband` removes the unit from the reply view and from disk, and its
##     replay is idempotent;
##   - `upkeep` answers through the same channel (the roster is empty here);
##   - an empty request id, malformed args and an over-budget unit request all
##     get named refusals while the connection keeps working;
##   - a visitor may read but not write (`forbidden`), an anonymous member may
##     read but has no player identity (`no_player`).
##
## The reply budget is 48 KiB; filling the bounded unit view past it is not
## reachable with MAX_UNITS rows, so only the request-side budget is exercised.
## Everything runs under .local/verification.

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Economy = preload("res://farm/economy_state.gd")
const UnitState = preload("res://conflict/unit_state.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const PLAYER_SECRET: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const START: float = 1800000000.0
const WORLD: String = "world-unit-network"
const MEMBER_ID: String = "player_00000000000000000000000000000051"
const VISITOR_ID: String = "player_00000000000000000000000000000052"
const MEMBER_NAME: String = "阿青"
const VISITOR_NAME: String = "过客"
const RECRUIT_ID: String = "unit-net-recruit-1"
const DISBAND_ID: String = "unit-net-disband-1"
## field_03/cell_06 starts mature and unowned, so a member's harvest credits
## their own bag without a collaboration grant or a theft record.
const MATURE_FIELD: String = "field_03"
const MATURE_CELL: String = "cell_06"
const OVER_BUDGET_BYTES: int = 50000

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var checks: int = 0
var failures: Array[String] = []
var client: WorldClient
var _ready: bool = false
var _refusals: Array[String] = []
var _unit_pending: Dictionary = {}
var _command_pending: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(".local/verification/unit-network-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if port <= 0:
		_finish()
		return
	var url: String = "wss://127.0.0.1:%d" % port
	var args := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % START, "--run-seconds=0", "--join-url=" + url,
	])
	server_pid = OS.create_process(OS.get_executable_path(), args, false)
	_expect(server_pid > 0, "The authority process starts")
	if server_pid <= 0:
		_finish()
		return
	var running: bool = await _wait(func() -> bool:
		var status: Dictionary = _status()
		return str(status.get("state", "")) == "running" \
			and int(status.get("pid", 0)) == server_pid, 20000)
	_expect(running, "The authority reports ready")
	if not running:
		await _stop_server()
		_finish()
		return

	var invite_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		world_dir.path_join("invite.bin"))
	var pem: String = FileAccess.get_file_as_bytes(
		world_dir.path_join("server.crt")).get_string_from_ascii()
	var member_code: String = WorldJoinCode.encode(WorldInvite.make(
		"server-invite", invite_bytes, WorldInvite.MEMBER, WORLD, 0.0, false),
		url, pem, "localhost")
	_expect(member_code.begins_with(WorldJoinCode.PREFIX),
		"A member join code is built from the operator's invitation")
	var visitor_code: String = FileAccess.get_file_as_string(
		world_dir.path_join("visitor-join-code.txt")).strip_edges()
	var visitor_grant: Dictionary = WorldJoinCode.decode(visitor_code).get("grant", {})
	_expect(visitor_code.begins_with(WorldJoinCode.PREFIX)
			and str(visitor_grant.get("role", "")) == WorldInvite.VISITOR,
		"The authority published a real visitor join code")
	if member_code.is_empty() or visitor_code.is_empty():
		await _stop_server()
		_finish()
		return

	await _test_member(member_code)
	await _close_client()
	await _test_visitor(visitor_code)
	await _close_client()
	await _test_anonymous(member_code)
	await _close_client()
	await _stop_server()
	_finish()


# ---------------------------------------------------------------- member flow

func _test_member(code: String) -> void:
	_expect(await _open_client(code, MEMBER_ID, MEMBER_NAME), "A named member joins over WSS")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.MEMBER,
		"The join reply confers the member role from the spent grant")

	var empty: Dictionary = await _unit("unit-state-1", "state")
	_expect(bool(empty.get("ok", false)) and str(empty.get("action", "")) == "state",
		"The authority answers a unit state request over channel 13")
	_expect(_rows(empty).is_empty(), "A fresh world has an empty unit roster")

	# Fund the member through the same account command a player uses; no test
	# seam touches the farm document.
	var opened: Dictionary = await _submit(FarmCommand.make_account_open(
		"unit-net-open", client.world_time()))
	_expect(bool(opened.get("ok", false)),
		"The member opens a real economy account through the authority")
	var harvested: Dictionary = await _submit(FarmCommand.make(
		"unit-net-harvest", MATURE_FIELD, MATURE_CELL, client.world_time() + 1.0))
	_expect(bool(harvested.get("ok", false))
			and str(harvested.get("reward_crop_id", "")) == "greens"
			and int(harvested.get("reward_amount", 0)) == 1,
		"Harvesting the mature crop credits one real basket to this member")
	var farm_before: Dictionary = _farm_doc()
	_expect(_cash(farm_before, MEMBER_ID) == 120,
		"The opening grant is the member's real cash (120)")
	_expect(_good(farm_before, MEMBER_ID, "greens") == 1,
		"The harvested basket is in the member's authoritative bag")

	var created: Dictionary = await _unit(RECRUIT_ID, "recruit", {
		"kind": "militia", "people": 1, "equipment": "none",
		"station": "farm_a", "command_id": RECRUIT_ID,
	})
	_expect(bool(created.get("ok", false)) and not bool(created.get("duplicate", true)),
		"A member recruits through the online unit channel")
	_expect(str(created.get("action", "")) == "recruit"
			and str(created.get("unit_id", "")) == RECRUIT_ID,
		"The reply names the new unit")
	var row: Dictionary = _row(created, RECRUIT_ID)
	_expect(not row.is_empty(), "The reply carries the authority's unit view")
	_expect(str(row.get("owner", "")) == MEMBER_ID
			and str(row.get("kind", "")) == "militia"
			and int(row.get("people", 0)) == 1
			and str(row.get("equipment", "")) == "none"
			and str(row.get("station", "")) == "farm_a"
			and int(row.get("unfed_days", -1)) == 0,
		"The authority view records owner, kind, people, equipment and station")
	var stored: Dictionary = _units_doc()
	_expect(_stored_row(stored, RECRUIT_ID).size() > 0,
		"units.json on disk carries the recruited unit")
	_expect(str(_stored_row(stored, RECRUIT_ID).get("owner", "")) == MEMBER_ID,
		"The stored unit belongs to the joined player, not the payload")

	var farm_after: Dictionary = _farm_doc()
	_expect(_cash(farm_after, MEMBER_ID) == 118, "Recruitment charges real cash (2)")
	_expect(_good(farm_after, MEMBER_ID, "greens") == 0,
		"Recruitment deducts the real supply basket")
	_expect(_cash(farm_after, Economy.WORLD_OWNER) == 2,
		"The cash cost lands in the @world account")
	_expect(_issued(farm_after) == 120 and _total_cash(farm_after) == 120,
		"Recruitment issues no cash and preserves conservation")

	var units_before: PackedByteArray = _bytes(world_dir.path_join("units.json"))
	var replay: Dictionary = await _unit(RECRUIT_ID, "recruit", {
		"kind": "militia", "people": 1, "equipment": "none",
		"station": "farm_a", "command_id": RECRUIT_ID,
	})
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the same request id returns duplicate")
	_expect(_row(replay, RECRUIT_ID).size() > 0,
		"The replay still carries the roster")
	var farm_replayed: Dictionary = _farm_doc()
	_expect(_cash(farm_replayed, MEMBER_ID) == 118
			and _good(farm_replayed, MEMBER_ID, "greens") == 0
			and _cash(farm_replayed, Economy.WORLD_OWNER) == 2,
		"A replay does not charge cash or supplies twice")
	_expect(_bytes(world_dir.path_join("units.json")) == units_before,
		"A replay does not rewrite units.json")

	var disbanded: Dictionary = await _unit(DISBAND_ID, "disband", {
		"unit_id": RECRUIT_ID, "command_id": DISBAND_ID,
	})
	_expect(bool(disbanded.get("ok", false)) and not bool(disbanded.get("duplicate", true)),
		"The owner disbands through the online unit channel")
	_expect(_rows(disbanded).is_empty(), "The disbanded unit leaves the reply view")
	_expect(_stored_row(_units_doc(), RECRUIT_ID).is_empty(),
		"The disbanded unit leaves units.json")
	var units_disbanded: PackedByteArray = _bytes(world_dir.path_join("units.json"))
	var disband_replay: Dictionary = await _unit(DISBAND_ID, "disband", {
		"unit_id": RECRUIT_ID, "command_id": DISBAND_ID,
	})
	_expect(bool(disband_replay.get("ok", false))
			and bool(disband_replay.get("duplicate", false))
			and _rows(disband_replay).is_empty(),
		"Replaying the disband is idempotent")
	_expect(_bytes(world_dir.path_join("units.json")) == units_disbanded,
		"A disband replay does not rewrite units.json")

	var upkeep: Dictionary = await _unit("unit-net-upkeep-1", "upkeep")
	_expect(bool(upkeep.get("ok", false)) and str(upkeep.get("action", "")) == "upkeep",
		"The upkeep sweep answers through the same online channel")
	_expect(_rows(upkeep).is_empty(), "The upkeep reply carries the authoritative roster")
	var upkeep_state: Dictionary = _units_doc()
	_expect(float(upkeep_state.get("last_upkeep_utc", -1.0)) >= START,
		"The upkeep sweep is persisted in units.json")

	# Wages travel on the same channel. No whole day has passed since the
	# recruit inside this run, so the authority answers the settled-this-tick
	# shape without charging anything.
	var wage: Dictionary = await _unit("unit-net-wage-1", "wage")
	_expect(bool(wage.get("ok", false)) and str(wage.get("action", "")) == "wage",
		"The wage sweep answers through the same online channel")
	_expect(str(wage.get("status", "")) == UnitState.STATUS_SETTLED_THIS_TICK,
		"A same-tick wage sweep settles nothing")
	_expect(int(wage.get("required", -1)) == 0 and int(wage.get("paid", -1)) == 0
		and int(wage.get("unpaid", -1)) == 0,
		"The wage reply carries the settlement totals")

	# Illegal correlation and malformed args are refused by name, and neither
	# poisons the session.
	_unit_pending.erase("")
	_expect(client.request_unit("", "state"),
		"An empty request id still reaches the authority")
	var invalid_id: Dictionary = await _unit_key("", 15000)
	_expect(not bool(invalid_id.get("ok", true))
			and str(invalid_id.get("reason", "")) == "invalid_request",
		"An empty request id is refused by name")

	var bad_args: Dictionary = await _unit("unit-net-bad-args", "recruit", {
		"kind": "militia", "people": "ten", "equipment": "none",
		"station": "farm_a", "command_id": "unit-net-bad-args",
	})
	_expect(not bool(bad_args.get("ok", true))
			and str(bad_args.get("reason", "")) == UnitState.REASON_INVALID_PEOPLE,
		"Malformed recruit args are refused by name")

	# The request side of the 48 KiB wire budget: the host answers a visible
	# refusal instead of dropping the oversized RPC.
	_unit_pending.erase("")
	var huge: String = JSON.stringify({
		"request_id": "unit-net-huge", "action": "state",
		"args": {"padding": "x".repeat(OVER_BUDGET_BYTES)},
	})
	_expect(huge.to_utf8_buffer().size() > 48 * 1024,
		"The oversized unit request really exceeds the wire budget")
	client.member.unit_request.rpc_id(1, huge)
	var over_budget: Dictionary = await _unit_key("", 15000)
	_expect(str(over_budget.get("reason", "")) == "payload_too_large",
		"An over-budget unit request gets a named refusal")

	var alive: Dictionary = await _unit("unit-state-after-refusals", "state")
	_expect(bool(alive.get("ok", false)) and _rows(alive).is_empty(),
		"The connection keeps working after every refusal")


# ----------------------------------------------------------- permission paths

func _test_visitor(code: String) -> void:
	_expect(await _open_client(code, VISITOR_ID, VISITOR_NAME),
		"A named visitor joins with the visitor code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")
	var view: Dictionary = await _unit("visitor-state-1", "state")
	_expect(bool(view.get("ok", false)), "A visitor may read the unit view")
	_expect(_rows(view).is_empty(), "The visitor sees the authoritative roster")
	var refused: Dictionary = await _unit("visitor-recruit-1", "recruit", {
		"kind": "militia", "people": 1, "equipment": "none",
		"station": "visitor", "command_id": "visitor-recruit-1",
	})
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "forbidden",
		"A visitor's unit write is refused as forbidden")
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The visitor refusal carries a human-readable reason")
	var after: Dictionary = await _unit("visitor-state-2", "state")
	_expect(bool(after.get("ok", false)),
		"The visitor stays connected after a refused write")


func _test_anonymous(code: String) -> void:
	_expect(await _open_client(code, "", ""), "An anonymous connection joins")
	if client == null or not client.joined:
		return
	var view: Dictionary = await _unit("anonymous-state-1", "state")
	_expect(bool(view.get("ok", false)), "An anonymous member may read the unit view")
	var refused: Dictionary = await _unit("anonymous-recruit-1", "recruit", {
		"kind": "militia", "people": 1, "equipment": "none",
		"station": "anonymous", "command_id": "anonymous-recruit-1",
	})
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "no_player",
		"An anonymous write is refused for lack of a player identity")
	var after: Dictionary = await _unit("anonymous-state-2", "state")
	_expect(bool(after.get("ok", false)),
		"The anonymous member stays connected after a refused write")


# ------------------------------------------------------------------- helpers

func _open_client(code: String, player_id: String, display_name: String) -> bool:
	_ready = false
	_refusals.clear()
	_unit_pending.clear()
	_command_pending.clear()
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
			_now: float) -> void:
		_ready = true)
	client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
	client.lost.connect(func(reason: String) -> void: _refusals.append(reason))
	client.unit_result.connect(_on_unit_result)
	client.committed.connect(_on_committed)
	var secret: PackedByteArray = Marshalls.base64_to_raw(PLAYER_SECRET) \
		if not player_id.is_empty() else PackedByteArray()
	if not client.start(code, player_id, display_name, secret):
		return false
	var arrived: bool = await _wait(func() -> bool:
		return (_ready and client.joined) or not _refusals.is_empty(), 20000)
	if not arrived or not _ready or not client.joined:
		_expect(false, "The client joins: refusals=%s" % str(_refusals))
		return false
	return true


func _close_client() -> void:
	if client != null:
		if is_instance_valid(client):
			client.close()
			client.queue_free()
		client = null
	_unit_pending.clear()
	_command_pending.clear()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout


func _on_unit_result(request_id: String, payload: Dictionary) -> void:
	_unit_pending[request_id] = payload


func _on_committed(request_id: String, payload: Dictionary) -> void:
	_command_pending[request_id] = payload


func _unit(request_id: String, action: String, args: Dictionary = {}) -> Dictionary:
	_unit_pending.erase(request_id)
	if client == null or not client.request_unit(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	return await _unit_key(request_id, 15000)


func _unit_key(request_id: String, timeout_ms: int) -> Dictionary:
	var arrived: bool = await _wait(func() -> bool:
		return _unit_pending.has(request_id), timeout_ms)
	if not arrived:
		_expect(false, "A unit reply arrives for request %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _unit_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


func _submit(command: Dictionary) -> Dictionary:
	var request_id: String = str(command.get("id", ""))
	_command_pending.erase(request_id)
	if client == null:
		return {"ok": false, "reason": "not_sent"}
	if not client.submit(command):
		return {"ok": false, "reason": "not_sent"}
	var arrived: bool = await _wait(func() -> bool:
		return _command_pending.has(request_id), 15000)
	if not arrived:
		_expect(false, "A command reply arrives for %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _command_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


func _rows(reply: Dictionary) -> Array:
	var state_value: Variant = reply.get("state")
	if not state_value is Dictionary:
		return []
	var rows: Variant = (state_value as Dictionary).get("units")
	return rows if rows is Array else []


func _row(reply: Dictionary, unit_id: String) -> Dictionary:
	for value: Variant in _rows(reply):
		if value is Dictionary and str((value as Dictionary).get("id", "")) == unit_id:
			return value
	return {}


func _stored_row(state: Dictionary, unit_id: String) -> Dictionary:
	var units_value: Variant = state.get("units")
	if not units_value is Dictionary:
		return {}
	var value: Variant = (units_value as Dictionary).get(unit_id)
	return value if value is Dictionary else {}


func _farm_doc() -> Dictionary:
	var saved: Dictionary = _read_json(world_dir.path_join("farm.json"))
	var farm: Variant = saved.get("farm")
	return farm if farm is Dictionary else {}


func _units_doc() -> Dictionary:
	var saved: Dictionary = _read_json(world_dir.path_join("units.json"))
	var state: Variant = saved.get("state")
	return state if state is Dictionary else {}


func _cash(farm: Dictionary, owner: String) -> int:
	var economy: Variant = farm.get("economy")
	if not economy is Dictionary:
		return -1
	var accounts: Variant = (economy as Dictionary).get("accounts")
	if not accounts is Dictionary:
		return -1
	var account: Variant = (accounts as Dictionary).get(owner)
	return int((account as Dictionary).get("cash", -1)) if account is Dictionary else 0


func _good(farm: Dictionary, owner: String, good_id: String) -> int:
	var bags: Variant = farm.get("bags")
	if not bags is Dictionary:
		return -1
	var pocket: Variant = (bags as Dictionary).get(owner)
	return int((pocket as Dictionary).get(good_id, 0)) if pocket is Dictionary else 0


func _issued(farm: Dictionary) -> int:
	var economy: Variant = farm.get("economy")
	var value: Variant = (economy as Dictionary).get("issued", -1) if economy is Dictionary else -1
	return int(value)


func _total_cash(farm: Dictionary) -> int:
	var economy: Variant = farm.get("economy")
	if not economy is Dictionary:
		return -1
	var accounts: Variant = (economy as Dictionary).get("accounts")
	if not accounts is Dictionary:
		return -1
	var total: int = 0
	for owner: Variant in (accounts as Dictionary).keys():
		var account: Variant = (accounts as Dictionary)[owner]
		if account is Dictionary:
			total += int((account as Dictionary).get("cash", 0))
	return total


func _status() -> Dictionary:
	return _read_json(world_dir.path_join("server-status.json"))


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()


func _stop_server() -> void:
	if server_pid <= 0:
		return
	var marker := FileAccess.open(world_dir.path_join("stop"), FileAccess.WRITE)
	if marker != null:
		marker.store_string("stop")
		marker.close()
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline and OS.is_process_running(server_pid):
		await create_timer(0.05).timeout
	var stopped: bool = not OS.is_process_running(server_pid)
	_expect(stopped, "The authority process shuts down cleanly")
	_expect(str(_status().get("state", "")) == "stopped",
		"The shutdown is recorded in the status file")
	if not stopped:
		OS.kill(server_pid)
	server_pid = 0


func _wait(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


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


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("UNIT_NETWORK_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
