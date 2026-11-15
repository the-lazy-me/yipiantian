extends SceneTree
## M12-02 participation authority over the real wire: RPC channels 17/18, not the
## host seam exercised by the pure rules.
##
## A real `world_server.gd` process serves a fresh world over loopback WSS with
## `--host-player=<PLAYER_A>`. Named members, a visitor and an anonymous
## connection join through `WorldClient` and drive `request_participation()`
## through the online transport:
##   - the ready line and status carry the host player, and a fresh world starts
##     `available` / `peace` / revision 0 with that host;
##   - a non-host member's `regime` is refused `not_host`; the host's identical
##     declaration is accepted, bumps the revision, carries the areas, window and
##     caps, and lands on disk;
##   - replaying the same request id is idempotent (duplicate) without touching
##     `participation.json`; a different declaration under the same id conflicts;
##   - the host consents as attacker; a second member consents as defender,
##     withdraws with the 3600 s delay, and cannot re-join while it is pending;
##   - a visitor may read but not write (`forbidden`), an anonymous connection may
##     read but has no player identity (`no_player`);
##   - an over-budget raw `participation_request` gets `payload_too_large` and the
##     connection keeps working;
##   - after a graceful stop the same directory restarts with the same
##     `--host-player` and keeps the declaration, participants and withdrawal
##     delay; the same declaration command id still replays;
##   - starting the same directory with another `--host-player` fails and never
##     overwrites the stored document.
##
## Two named members use different installation credentials (ADR-029) and join
## one at a time because `WorldClient` always creates `/root/WorldSession`.
## Everything runs under .local/verification/participation-network-<ticks>/.

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const Participation = preload("res://conflict/participation_state.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
## One installation credential per identity: the authority binds the first proof
## it sees, so two named members must not share one.
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const START: float = 1800000000.0
const WORLD: String = "world-participation-network"
const PLAYER_A: String = "player_00000000000000000000000000000071"
const PLAYER_B: String = "player_00000000000000000000000000000072"
const PLAYER_C: String = "player_00000000000000000000000000000073"
const VISITOR_ID: String = "player_00000000000000000000000000000074"
const NAME_A: String = "阿金"
const NAME_B: String = "阿木"
const VISITOR_NAME: String = "围观者"
const DECLARATION_ID: String = "decl_net"
const REGIME_ID: String = "participation-net-regime"
const A_CONSENT_ID: String = "participation-net-a-attacker"
const B_CONSENT_ID: String = "participation-net-b-defender"
const B_WITHDRAW_ID: String = "participation-net-b-withdraw"
const B_REJOIN_ID: String = "participation-net-b-rejoin"
const NOT_HOST_ID: String = "participation-net-b-not-host"
const OVER_BUDGET_BYTES: int = 50000

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var url: String = ""
var checks: int = 0
var failures: Array[String] = []
var client: WorldClient
var _ready: bool = false
var _refusals: Array[String] = []
var _participation_pending: Dictionary = {}
## The exact declaration first offered by the non-host member and then published
## by the host. The restart replays this same body under the same command id.
var _declaration: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/participation-network-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	if not await _start_authority(PLAYER_A):
		_finish()
		return
	var codes: Dictionary = _join_codes()
	_expect(not str(codes.get("member", "")).is_empty()
			and not str(codes.get("visitor", "")).is_empty(),
		"Member and visitor join codes are built from the operator's material")
	if str(codes.get("member", "")).is_empty() or str(codes.get("visitor", "")).is_empty():
		await _stop_server()
		_finish()
		return

	await _test_non_host_refusal(codes)
	await _close_client()
	await _test_host_declaration(codes)
	await _close_client()
	await _test_defender_and_withdrawal(codes)
	await _close_client()
	await _test_visitor(codes)
	await _close_client()
	await _test_anonymous(codes)
	await _close_client()

	var participation_before_stop: PackedByteArray = _bytes(_participation_path())
	_expect(not participation_before_stop.is_empty(),
		"The declaration is persisted before the restart")
	await _stop_server()
	if not await _start_authority(PLAYER_A):
		_finish()
		return
	var restart_codes: Dictionary = _join_codes()
	await _test_restart(restart_codes, participation_before_stop)
	await _close_client()
	await _stop_server()

	# A different explicit host is a durable host mismatch: the authority must
	# refuse to start and must not rewrite the stored declaration.
	var bytes_before_c: PackedByteArray = _bytes(_participation_path())
	var refused: bool = await _start_authority_expect_failure(PLAYER_C)
	_expect(refused, "Starting the same directory with another host player fails")
	_expect(_bytes(_participation_path()) == bytes_before_c,
		"A refused host start does not overwrite participation.json")
	_expect(str(_status().get("state", "")) == "stopped",
		"The refused host start leaves the previous stopped status")
	_finish()


# -------------------------------------------------------- host/regime declaration

func _test_non_host_refusal(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The second named member joins over WSS")
	if client == null or not client.joined:
		return
	# Build the one declaration both members offer: the non-host first (refused)
	# and the host second (accepted). It lives well inside the declared window so
	# the host call cannot race the authority clock. The time comes from the
	# authoritative view, not the growth clock, which can sit behind it.
	var now: float = await _authority_now()
	_declaration = _declaration_doc(DECLARATION_ID, now)
	var refused: Dictionary = await _participation(NOT_HOST_ID, "regime", {
		"declaration": _declaration, "command_id": NOT_HOST_ID,
	})
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "not_host",
		"A non-host member's regime declaration is refused as not_host")
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The not_host refusal carries a human-readable reason")
	var view: Dictionary = await _participation("participation-net-b-state", "state")
	_expect(bool(view.get("ok", false))
			and int(_regime(_state(view)).get("revision", -1)) == 0,
		"The refused declaration leaves the room at revision 0")
	_expect(_bytes(_participation_path()).is_empty(),
		"A refused declaration creates no participation document")


func _test_host_declaration(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host named member joins over WSS")
	if client == null or not client.joined:
		return
	var view: Dictionary = await _participation("participation-net-state-fresh", "state")
	_expect(bool(view.get("ok", false)), "The authority answers a participation state request")
	var fresh: Dictionary = _state(view)
	for key: String in ["available", "host", "sequence", "regime", "areas", "windows",
			"participants", "losses"]:
		_expect(fresh.has(key), "The fresh participation view carries %s" % key)
	_expect(bool(fresh.get("available", false)), "Participation is available for a hosted room")
	_expect(str(fresh.get("host", "")) == PLAYER_A, "The view names the startup host player")
	_expect(int(fresh.get("sequence", -1)) == 0, "A fresh hosted room has sequence 0")
	var fresh_regime: Dictionary = _regime(fresh)
	_expect(str(fresh_regime.get("tier", "")) == Participation.TIER_PEACE
			and int(fresh_regime.get("revision", -1)) == 0,
		"A fresh hosted room is a peace regime at revision 0")
	_expect((fresh.get("participants", []) as Array).is_empty(),
		"A fresh hosted room has no participants")

	var declared: Dictionary = await _participation(REGIME_ID, "regime", {
		"declaration": _declaration, "command_id": REGIME_ID,
	})
	_expect(bool(declared.get("ok", false)) and not bool(declared.get("duplicate", true)),
		"The host declares the limited regime over channel 17")
	var published: Dictionary = _state(declared)
	var regime: Dictionary = _regime(published)
	_expect(int(regime.get("revision", -1)) == 1, "The declaration bumps the regime revision to 1")
	_expect(str(regime.get("tier", "")) == Participation.TIER_LIMITED
			and bool(regime.get("higher_risk", false)),
		"The live regime is limited with an explicit higher-risk declaration")
	_expect(str(regime.get("declaration_id", "")) == DECLARATION_ID
			and str(regime.get("declared_by", "")) == PLAYER_A,
		"The live regime records the declaration id and its declarer")
	_expect(int(regime.get("loss_cap", -1)) == 100
			and int(regime.get("offline_loss_cap", -1)) == 20,
		"The live regime carries the declared loss caps")
	_expect(_ids(_areas(published)) == ["yard"], "The view carries the declared area")
	var area: Dictionary = _row(_areas(published), "yard")
	_expect(int(area.get("min_x", -1)) == 0 and int(area.get("min_z", -1)) == 0
			and int(area.get("max_x", -1)) == 10 and int(area.get("max_z", -1)) == 10,
		"The declared area bounds match the declaration")
	_expect(_ids(_windows(published)) == ["night"], "The view carries the declared window")
	var window: Dictionary = _row(_windows(published), "night")
	_expect(int(window.get("start_utc", -1)) == int(_declaration.get("windows", [{}])[0].start_utc)
			and int(window.get("end_utc", -1)) == int(_declaration.get("windows", [{}])[0].end_utc),
		"The declared window bounds match the declaration")

	# The declaration must be a durable document, not an in-memory view.
	var stored: Dictionary = _participation_doc()
	_expect(int(stored.get("version", -1)) == 1, "participation.json carries version 1")
	var stored_state: Dictionary = stored.get("state", {}) if stored.get("state") is Dictionary else {}
	_expect(str(stored_state.get("host", "")) == PLAYER_A
			and int(_regime(stored_state).get("revision", -1)) == 1,
		"participation.json records the host and the new revision")
	var stored_caps: Variant = stored_state.get("caps", {})
	_expect(stored_caps is Dictionary and stored_caps.has("1")
			and int((stored_caps as Dictionary)["1"].get("loss_cap", -1)) == 100
			and int((stored_caps as Dictionary)["1"].get("offline_loss_cap", -1)) == 20,
		"participation.json records the revision's caps")
	var stored_areas: Variant = stored_state.get("areas", {})
	var stored_windows: Variant = stored_state.get("windows", {})
	_expect(stored_areas is Dictionary and (stored_areas as Dictionary).has("yard")
			and stored_windows is Dictionary and (stored_windows as Dictionary).has("night"),
		"participation.json records the declared area and window")

	var bytes_before_replay: PackedByteArray = _bytes(_participation_path())
	var replay: Dictionary = await _participation(REGIME_ID, "regime", {
		"declaration": _declaration, "command_id": REGIME_ID,
	})
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the same regime request id returns duplicate (got ok=%s duplicate=%s reason=%s)"
		% [str(replay.get("ok", false)), str(replay.get("duplicate", false)),
			str(replay.get("reason", ""))])
	_expect(_bytes(_participation_path()) == bytes_before_replay,
		"A regime replay leaves participation.json byte-identical")

	var different: Dictionary = _declaration_doc("decl_net_other",
		await _authority_now())
	different["loss_cap"] = 120
	different["offline_loss_cap"] = 24
	var conflict: Dictionary = await _participation(REGIME_ID, "regime", {
		"declaration": different, "command_id": REGIME_ID,
	})
	_expect(not bool(conflict.get("ok", true))
			and str(conflict.get("reason", "")) == "command_conflict",
		"A different declaration under the same request id conflicts")
	_expect(_bytes(_participation_path()) == bytes_before_replay,
		"A regime conflict leaves participation.json byte-identical")

	# The host then consents as attacker for the live revision.
	var consented: Dictionary = await _participation(A_CONSENT_ID, "declare", {
		"role": Participation.ROLE_ATTACKER, "command_id": A_CONSENT_ID,
	})
	_expect(bool(consented.get("ok", false)) and not bool(consented.get("duplicate", true)),
		"The host consents as attacker over channel 17")
	var host_row: Dictionary = _participant(_state(consented), PLAYER_A)
	_expect(bool(host_row.get("attacker", false)) and not bool(host_row.get("defender", true)),
		"The view records the host as attacker only")
	_expect(int(host_row.get("consent_revision", -1)) == 1,
		"The host's consent is bound to revision 1")
	var consent_replay: Dictionary = await _participation(A_CONSENT_ID, "declare", {
		"role": Participation.ROLE_ATTACKER, "command_id": A_CONSENT_ID,
	})
	_expect(bool(consent_replay.get("ok", false))
			and bool(consent_replay.get("duplicate", false)),
		"Replaying the host consent request id returns duplicate (got ok=%s duplicate=%s reason=%s)"
		% [str(consent_replay.get("ok", false)), str(consent_replay.get("duplicate", false)),
			str(consent_replay.get("reason", ""))])

	# Request-side wire budget: the raw RPC is answered, not dropped.
	_participation_pending.erase("")
	var huge: String = JSON.stringify({
		"request_id": "participation-net-huge", "action": "state",
		"args": {"padding": "x".repeat(OVER_BUDGET_BYTES)},
	})
	_expect(huge.to_utf8_buffer().size() > 48 * 1024,
		"The oversized participation request really exceeds the wire budget")
	client.member.participation_request.rpc_id(1, huge)
	var over_budget: Dictionary = await _participation_key("", 15000)
	_expect(str(over_budget.get("reason", "")) == "payload_too_large",
		"An over-budget participation request gets a named refusal")
	var alive: Dictionary = await _participation("participation-net-state-after-huge", "state")
	_expect(bool(alive.get("ok", false))
			and int(_regime(_state(alive)).get("revision", -1)) == 1,
		"The connection keeps working after the over-budget refusal")


func _test_defender_and_withdrawal(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The second member rejoins to consent")
	if client == null or not client.joined:
		return
	var consented: Dictionary = await _participation(B_CONSENT_ID, "declare", {
		"role": Participation.ROLE_DEFENDER, "command_id": B_CONSENT_ID,
	})
	_expect(bool(consented.get("ok", false)) and not bool(consented.get("duplicate", true)),
		"The second member consents as defender over channel 17")
	var defender: Dictionary = _participant(_state(consented), PLAYER_B)
	_expect(bool(defender.get("defender", false)) and not bool(defender.get("attacker", true)),
		"The view records the second member as defender only")
	_expect(int(defender.get("consent_revision", -1)) == 1,
		"The defender's consent is bound to revision 1")

	var withdrawn: Dictionary = await _participation(B_WITHDRAW_ID, "withdraw", {
		"command_id": B_WITHDRAW_ID,
	})
	_expect(bool(withdrawn.get("ok", false)) and not bool(withdrawn.get("duplicate", true)),
		"The defender withdraws over channel 17")
	var pending: Dictionary = _participant(_state(withdrawn), PLAYER_B)
	_expect(float(pending.get("withdraw_utc", 0.0)) > 0.0,
		"The view records the withdrawal declaration time")
	_expect(absf(float(pending.get("withdraw_effective_utc", 0.0))
			- float(pending.get("withdraw_utc", 0.0))
			- Participation.WITHDRAWAL_DELAY_SECONDS) < 0.001,
		"The view shows the 3600 s withdrawal delay")

	var again: Dictionary = await _participation(B_REJOIN_ID, "declare", {
		"role": Participation.ROLE_DEFENDER, "command_id": B_REJOIN_ID,
	})
	_expect(not bool(again.get("ok", true))
			and str(again.get("reason", "")) == "withdrawal_pending",
		"A pending withdrawal cannot be undone by re-joining")
	_expect(not str(again.get("reason_text", "")).is_empty(),
		"The withdrawal_pending refusal carries a human-readable reason")


# ----------------------------------------------------------- permission paths

func _test_visitor(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("visitor", "")), VISITOR_ID, VISITOR_NAME,
		PLAYER_SECRET_A), "A named visitor joins with the visitor code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")
	var view: Dictionary = await _participation("visitor-state-1", "state")
	_expect(bool(view.get("ok", false)), "A visitor may read the participation view")
	_expect(int(_regime(_state(view)).get("revision", -1)) == 1,
		"The visitor sees the authoritative revision")
	var refused: Dictionary = await _participation("visitor-regime-1", "regime", {
		"declaration": _declaration_doc("decl_visitor", client.world_time()),
		"command_id": "visitor-regime-1",
	})
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "forbidden",
		"A visitor's participation write is refused as forbidden")
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The visitor refusal carries a human-readable reason")
	var after: Dictionary = await _participation("visitor-state-2", "state")
	_expect(bool(after.get("ok", false))
			and int(_regime(_state(after)).get("revision", -1)) == 1,
		"The visitor stays connected and can still read after a refused write")


func _test_anonymous(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), "", "", ""),
		"An anonymous connection joins")
	if client == null or not client.joined:
		return
	var view: Dictionary = await _participation("anonymous-state-1", "state")
	_expect(bool(view.get("ok", false)), "An anonymous member may read the participation view")
	_expect(int(_regime(_state(view)).get("revision", -1)) == 1,
		"The anonymous member sees the authoritative revision")
	var refused: Dictionary = await _participation("anonymous-declare-1", "declare", {
		"role": Participation.ROLE_ATTACKER, "command_id": "anonymous-declare-1",
	})
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "no_player",
		"An anonymous participation write is refused for lack of a player identity")
	var after: Dictionary = await _participation("anonymous-state-2", "state")
	_expect(bool(after.get("ok", false))
			and int(_regime(_state(after)).get("revision", -1)) == 1,
		"The anonymous member stays connected and can still read after a refusal")


# --------------------------------------------------------------------- restart

func _test_restart(codes: Dictionary, bytes_before_stop: PackedByteArray) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host rejoins the restarted authority")
	if client == null or not client.joined:
		return
	var view: Dictionary = await _participation("restart-state-1", "state")
	_expect(bool(view.get("ok", false)), "The restarted authority answers a state request")
	var state: Dictionary = _state(view)
	var regime: Dictionary = _regime(state)
	_expect(str(regime.get("tier", "")) == Participation.TIER_LIMITED
			and int(regime.get("revision", -1)) == 1
			and str(regime.get("declaration_id", "")) == DECLARATION_ID,
		"The declaration survives the authority restart")
	_expect(_ids(_areas(state)) == ["yard"] and _ids(_windows(state)) == ["night"],
		"The declared scope survives the restart")
	var attacker: Dictionary = _participant(state, PLAYER_A)
	_expect(bool(attacker.get("attacker", false))
			and int(attacker.get("consent_revision", -1)) == 1,
		"The host's attacker consent survives the restart")
	var defender: Dictionary = _participant(state, PLAYER_B)
	_expect(bool(defender.get("defender", false))
			and float(defender.get("withdraw_utc", 0.0)) > 0.0,
		"The defender and the withdrawal declaration survive the restart")
	_expect(absf(float(defender.get("withdraw_effective_utc", 0.0))
			- float(defender.get("withdraw_utc", 0.0))
			- Participation.WITHDRAWAL_DELAY_SECONDS) < 0.001,
		"The withdrawal delay survives the restart")
	_expect(_bytes(_participation_path()) == bytes_before_stop,
		"The restart loads the document without rewriting it")

	var replay: Dictionary = await _participation(REGIME_ID, "regime", {
		"declaration": _declaration, "command_id": REGIME_ID,
	})
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"The same declaration command id still replays after the restart (got ok=%s duplicate=%s reason=%s)"
		% [str(replay.get("ok", false)), str(replay.get("duplicate", false)),
			str(replay.get("reason", ""))])
	_expect(_bytes(_participation_path()) == bytes_before_stop,
		"The restart replay leaves participation.json byte-identical")


# ------------------------------------------------------------------- authority

func _start_authority(host_player: String) -> bool:
	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if port <= 0:
		return false
	url = "wss://127.0.0.1:%d" % port
	server_pid = _spawn_server(host_player, "server.log")
	_expect(server_pid > 0, "The authority process starts")
	if server_pid <= 0:
		return false
	var running: bool = await _wait(func() -> bool:
		var status: Dictionary = _status()
		return str(status.get("state", "")) == "running" \
			and int(status.get("pid", 0)) == server_pid, 20000)
	_expect(running, "The authority reports ready")
	if not running:
		return false
	if OS.get_name() != "Windows":
		# The ready line is captured through /bin/sh; Windows has no equivalent
		# redirect here, so the status file below is the only startup evidence.
		var ready: Dictionary = _server_line("server.log", "WORLD_SERVER_READY ")
		_expect(str(ready.get("state", "")) == "running",
			"The ready line reports the running state")
		_expect(str(ready.get("host_player", "")) == host_player,
			"The ready line records the host player")
	var status: Dictionary = _status()
	_expect(str(status.get("host_player", "")) == host_player,
		"The status file records the host player (got %s)"
		% str(status.get("host_player", "<missing>")))
	return true


## Starts the same directory with another explicit host and expects the authority
## to refuse before it ever reports ready. The process must terminate on its own;
## a live process is killed only after the assertion so the run can finish.
func _start_authority_expect_failure(host_player: String) -> bool:
	var chosen_port: int = _free_port()
	_expect(chosen_port > 0, "A free loopback port is available for the refused start")
	if chosen_port <= 0:
		return false
	port = chosen_port
	url = "wss://127.0.0.1:%d" % port
	server_pid = _spawn_server(host_player, "server-refused.log")
	_expect(server_pid > 0, "The refused authority process starts")
	if server_pid <= 0:
		return false
	var exited: bool = await _wait(func() -> bool:
		return not OS.is_process_running(server_pid), 15000)
	_expect(exited, "The refused authority exits instead of serving the wrong host")
	if not exited:
		OS.kill(server_pid)
		server_pid = 0
		return false
	if OS.get_name() != "Windows":
		var error: Dictionary = _server_line("server-refused.log", "WORLD_SERVER_ERROR ")
		_expect(str(error.get("reason", "")) == "world_open"
				and str(error.get("detail", "")).contains("host_mismatch"),
			"The refused start names the durable participation host mismatch")
	server_pid = 0
	return true


func _spawn_server(host_player: String, log_name: String) -> int:
	var arguments := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % START, "--run-seconds=0", "--join-url=" + url,
		"--host-player=" + host_player,
	])
	# The ready line is the other half of the startup contract, so redirect the
	# authority's stdout into the run directory instead of only polling status.
	if OS.get_name() == "Windows":
		return OS.create_process(OS.get_executable_path(), arguments, false)
	var pieces: PackedStringArray = []
	pieces.append(_shell_quote(OS.get_executable_path()))
	for argument: String in arguments:
		pieces.append(_shell_quote(argument))
	var command: String = "exec " + " ".join(pieces) + " > " \
		+ _shell_quote(dir.path_join(log_name)) + " 2>&1"
	return OS.create_process("/bin/sh", PackedStringArray(["-c", command]), false)


func _shell_quote(value: String) -> String:
	return "'" + value.replace("'", "'\\''") + "'"


func _server_line(log_name: String, prefix: String) -> Dictionary:
	var path: String = dir.path_join(log_name)
	if not FileAccess.file_exists(path):
		return {}
	for line: String in FileAccess.get_file_as_string(path).split("\n"):
		if line.begins_with(prefix):
			var parsed: Variant = JSON.parse_string(line.substr(prefix.length()))
			return parsed if parsed is Dictionary else {}
	return {}


func _join_codes() -> Dictionary:
	var invite_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		world_dir.path_join("invite.bin"))
	var pem: String = FileAccess.get_file_as_bytes(
		world_dir.path_join("server.crt")).get_string_from_ascii()
	var member_code: String = WorldJoinCode.encode(WorldInvite.make(
		"server-invite", invite_bytes, WorldInvite.MEMBER, WORLD, 0.0, false),
		url, pem, "localhost")
	var visitor_code: String = FileAccess.get_file_as_string(
		world_dir.path_join("visitor-join-code.txt")).strip_edges()
	return {"member": member_code, "visitor": visitor_code}


func _open_client(code: String, player_id: String, display_name: String,
		secret_text: String) -> bool:
	_ready = false
	_refusals.clear()
	_participation_pending.clear()
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
			_now: float) -> void:
		_ready = true)
	client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
	client.lost.connect(func(reason: String) -> void: _refusals.append(reason))
	client.participation_result.connect(_on_participation_result)
	var secret: PackedByteArray = Marshalls.base64_to_raw(secret_text) \
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
	_participation_pending.clear()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout


func _on_participation_result(request_id: String, payload: Dictionary) -> void:
	_participation_pending[request_id] = payload


func _participation(request_id: String, action: String,
		args: Dictionary = {}) -> Dictionary:
	_participation_pending.erase(request_id)
	if client == null or not client.request_participation(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	return await _participation_key(request_id, 15000)


func _participation_key(request_id: String, timeout_ms: int) -> Dictionary:
	var arrived: bool = await _wait(func() -> bool:
		return _participation_pending.has(request_id), timeout_ms)
	if not arrived:
		_expect(false, "A participation reply arrives for request %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _participation_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


# ------------------------------------------------------------------- fixtures

## Times are built from the client's authoritative clock, never hard-coded. The
## effective instant sits ahead of the authority so the declaration cannot race
## the server's own `declared_utc`.
func _declaration_doc(declaration_id: String, now: float) -> Dictionary:
	return {
		"tier": Participation.TIER_LIMITED,
		"declaration_id": declaration_id,
		"effective_utc": now + 60.0,
		"higher_risk": true,
		"areas": [{"id": "yard", "min_x": 0, "min_z": 0, "max_x": 10, "max_z": 10}],
		"windows": [{"id": "night", "start_utc": now - 60.0,
			"end_utc": now + 86400.0}],
		"loss_cap": 100,
		"offline_loss_cap": 20,
	}


func _state(reply: Dictionary) -> Dictionary:
	var value: Variant = reply.get("state")
	return value if value is Dictionary else {}


## The server's own clock, as carried by the participation view. The growth
## clock (`WorldClient.world_time()`) only advances with farm work and must not
## be used to build declaration times.
func _authority_now() -> float:
	var reply: Dictionary = await _participation(
		"participation-clock-%d" % Time.get_ticks_usec(), "state")
	var now: float = float(_state(reply).get("now_utc", 0.0))
	_expect(now > 0.0, "The participation view carries the authority clock")
	return now


func _regime(state: Dictionary) -> Dictionary:
	var value: Variant = state.get("regime")
	return value if value is Dictionary else {}


func _areas(state: Dictionary) -> Array:
	var value: Variant = state.get("areas")
	return value if value is Array else []


func _windows(state: Dictionary) -> Array:
	var value: Variant = state.get("windows")
	return value if value is Array else []


func _row(rows: Array, id: String) -> Dictionary:
	for value: Variant in rows:
		if value is Dictionary and str((value as Dictionary).get("id", "")) == id:
			return value
	return {}


func _ids(rows: Array) -> Array:
	var ids: Array = []
	for value: Variant in rows:
		if value is Dictionary:
			ids.append(str((value as Dictionary).get("id", "")))
	return ids


func _participant(state: Dictionary, player_id: String) -> Dictionary:
	var rows: Variant = state.get("participants")
	if not rows is Array:
		return {}
	for value: Variant in rows:
		if value is Dictionary and str((value as Dictionary).get("participant", "")) == player_id:
			return value
	return {}


func _participation_path() -> String:
	return world_dir.path_join("participation.json")


func _participation_doc() -> Dictionary:
	return _read_json(_participation_path())


func _status() -> Dictionary:
	return _read_json(world_dir.path_join("server-status.json"))


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) \
		if FileAccess.file_exists(path) else PackedByteArray()


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
	print("PARTICIPATION_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
