extends SceneTree
## Public fund authority over the real wire: the RPC channels 15/16, not the host
## seam that `public_fund_authority_test.gd` exercises directly.
##
## A real `world_server.gd` process serves a fresh world over loopback WSS. Named
## members and a visitor/anonymous connection join through `WorldClient` and drive
## `request_fund()` through the online transport:
##   - a member creates an organization through channels 11/12, opens the derived
##     fund and gets the authoritative balance-0 view;
##   - the same member opens a real `account_open` cash account, contributes 100
##     (cash -> derived organization account, fund balance, total unchanged);
##   - replaying the same request id returns `duplicate` and moves no cash;
##   - the keeper spends 40 (organization account -> `@world`, fund spent 40);
##   - a second named member joins the organization and contributes 1, then is
##     refused a spend as a plain member (`not_keeper`); the keeper rotates to
##     them, the new keeper spends and the old keeper is refused;
##   - a visitor may read but not write (`forbidden`), an anonymous connection may
##     read but has no player identity (`no_player`);
##   - a raw `fund_request` payload over the 48 KiB wire budget gets a named
##     `payload_too_large` refusal and the connection keeps working;
##   - after a graceful stop and a restart on the same data directory, replaying
##     the contribution request id returns `duplicate` without charging twice.
##
## Everything runs under .local/verification/fund-network-<ticks>/.

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Economy = preload("res://farm/economy_state.gd")
const PublicFund = preload("res://world/public_fund.gd")
const FundStore = preload("res://world/fund_store.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
## One installation credential per identity: the authority issues the one-time
## account grant per credential, so two named members must not share one.
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const START: float = 1800000000.0
const WORLD: String = "world-fund-network"
const PLAYER_A: String = "player_00000000000000000000000000000061"
const PLAYER_B: String = "player_00000000000000000000000000000062"
const VISITOR_ID: String = "player_00000000000000000000000000000063"
const NAME_A: String = "阿金"
const NAME_B: String = "阿木"
const VISITOR_NAME: String = "围观者"
const ORG: String = "guild_fund"
const OTHER_ORG: String = "guild_fund_other"
const OVER_BUDGET_BYTES: int = 50000

const OPEN_A: String = "fund-net-open-a"
const CONTRIBUTE_A: String = "fund-net-contribute-a"
const SPEND_A: String = "fund-net-spend-a"
const CONTRIBUTE_B: String = "fund-net-contribute-b"
const SPEND_B_MEMBER: String = "fund-net-spend-b-member"
const ROTATE: String = "fund-net-rotate"
const SPEND_OLD_KEEPER: String = "fund-net-spend-old-keeper"
const SPEND_NEW_KEEPER: String = "fund-net-spend-new-keeper"

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
var _fund_pending: Dictionary = {}
var _organization_pending: Dictionary = {}
var _command_pending: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(".local/verification/fund-network-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	if not await _start_authority():
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

	await _test_leader(codes)
	await _close_client()
	await _test_second_member(codes)
	await _close_client()
	await _test_rotation(codes)
	await _close_client()
	await _test_new_keeper(codes)
	await _close_client()
	await _test_visitor(codes)
	await _close_client()
	await _test_anonymous(codes)
	await _close_client()

	# Capture the committed documents before the restart; the replay afterwards is
	# compared against these exact values.
	var farm_before: Dictionary = _farm_doc()
	var funds_before: Dictionary = _funds_doc()
	var a_cash_before: int = _cash(farm_before, PLAYER_A)
	var org_cash_before: int = _cash(farm_before, PublicFund.account_for(ORG))
	var total_before: int = _total_cash(farm_before)
	var balance_before: int = _stored_fund_balance(funds_before)
	_expect(balance_before == org_cash_before,
		"The fund balance equals the organization account before the restart")

	await _stop_server()
	if not await _start_authority():
		_finish()
		return
	var restart_codes: Dictionary = _join_codes()
	await _test_restart_replay(restart_codes, {
		"a_cash": a_cash_before,
		"org_cash": org_cash_before,
		"total": total_before,
		"balance": balance_before,
	})
	await _close_client()
	await _stop_server()
	_finish()


# ---------------------------------------------------------------- leader flow

func _test_leader(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "A named member joins over WSS")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.MEMBER,
		"The join reply confers the member role")

	var empty: Dictionary = await _fund("fund-net-state-1", "state")
	_expect(bool(empty.get("ok", false)) and str(empty.get("action", "")) == "state",
		"The authority answers a fund state request over channel 15")
	_expect(_rows(empty).is_empty(), "A fresh world has an empty fund table")

	var created: Dictionary = await _organization("fund-net-org-create", "create", {
		"org_id": ORG, "name": "河岸基金社", "command_id": "fund-net-org-create",
	})
	_expect(bool(created.get("ok", false)),
		"The member creates an organization through channels 11/12")
	var org_rows: Array = _organizations(created)
	var org_row: Dictionary = _organization_row(org_rows, ORG)
	_expect(not org_row.is_empty()
			and str((org_row.get("members", {}) as Dictionary).get(PLAYER_A, "")) == "leader",
		"The creator is the organization leader")

	var opened: Dictionary = await _fund(OPEN_A, "open", {
		"org_id": ORG, "command_id": OPEN_A,
	})
	_expect(bool(opened.get("ok", false)) and not bool(opened.get("duplicate", true)),
		"The leader opens the derived organization fund over the online channel")
	var fund_id: String = PublicFund.fund_for(ORG)
	_expect(str(opened.get("fund_id", "")) == fund_id, "The reply names the derived fund")
	var row: Dictionary = _fund_row(opened, fund_id)
	_expect(not row.is_empty(), "The open reply carries the authoritative fund view")
	_expect(str(row.get("org_id", "")) == ORG and str(row.get("keeper", "")) == PLAYER_A,
		"The authoritative fund records the organization and its keeper")
	_expect(int(row.get("balance", -1)) == 0 and int(row.get("spent", -1)) == 0,
		"A new fund starts with balance 0 and spent 0")
	var contributors: Dictionary = row.get("contributors", {}) as Dictionary
	_expect(int(contributors.get(PLAYER_A, -1)) == 0,
		"The keeper enters the contributor table with a zero total")

	# The member opens the same real economy account a player uses; the fund then
	# moves that cash, not a test seam.
	var account_opened: Dictionary = await _submit(FarmCommand.make_account_open(
		"fund-net-account-a", client.world_time()))
	_expect(bool(account_opened.get("ok", false)),
		"The member opens a real economy account through the authority")
	var farm_before: Dictionary = _farm_doc()
	_expect(_cash(farm_before, PLAYER_A) == 120,
		"The opening grant is the member's real cash (120)")
	var total_before: int = _total_cash(farm_before)
	var issued_before: int = _issued(farm_before)
	var org_account: String = PublicFund.account_for(ORG)

	var contributed: Dictionary = await _fund(CONTRIBUTE_A, "contribute", {
		"fund_id": fund_id, "amount": 100, "command_id": CONTRIBUTE_A,
	})
	_expect(bool(contributed.get("ok", false))
			and not bool(contributed.get("duplicate", true)),
		"The member contributes 100 over the online fund channel")
	var farm_after: Dictionary = _farm_doc()
	_expect(_cash(farm_after, PLAYER_A) == 20,
		"The contribution charges the connected player's real cash")
	_expect(_cash(farm_after, org_account) == 100,
		"The cash lands in the derived organization account")
	_expect(_total_cash(farm_after) == total_before,
		"Contributing preserves total cash")
	_expect(_issued(farm_after) == issued_before,
		"Contributing issues no new cash")
	var contributed_row: Dictionary = _fund_row(contributed, fund_id)
	_expect(int(contributed_row.get("balance", -1)) == 100,
		"The fund balance grows by the contribution")
	_expect(int((contributed_row.get("contributors", {}) as Dictionary)
		.get(PLAYER_A, -1)) == 100,
		"The contributor's public total grows by the contribution")
	_expect(_stored_fund_balance(_funds_doc()) == 100,
		"The contribution is written to the fund sidecar")

	var funds_before_replay: String = JSON.stringify(_funds_doc())
	var farm_before_replay: String = JSON.stringify(_farm_doc())
	var replay: Dictionary = await _fund(CONTRIBUTE_A, "contribute", {
		"fund_id": fund_id, "amount": 100, "command_id": CONTRIBUTE_A,
	})
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the same contribution request id returns duplicate")
	_expect(JSON.stringify(_farm_doc()) == farm_before_replay,
		"A contribution replay charges no cash twice")
	_expect(JSON.stringify(_funds_doc()) == funds_before_replay,
		"A contribution replay does not rewrite the fund sidecar")

	var world_before: int = _cash(farm_after, Economy.WORLD_OWNER)
	var spent: Dictionary = await _fund(SPEND_A, "spend", {
		"fund_id": fund_id, "project_id": "village_square", "amount": 40,
		"command_id": SPEND_A,
	})
	_expect(bool(spent.get("ok", false)) and not bool(spent.get("duplicate", true)),
		"The keeper spends 40 over the online fund channel")
	var farm_spent: Dictionary = _farm_doc()
	_expect(_cash(farm_spent, org_account) == 60,
		"The organization account pays the spend")
	_expect(_cash(farm_spent, Economy.WORLD_OWNER) == world_before + 40,
		"The spend lands in the public treasury")
	_expect(_total_cash(farm_spent) == total_before,
		"A spend preserves total cash")
	var spent_row: Dictionary = _fund_row(spent, fund_id)
	_expect(int(spent_row.get("balance", -1)) == 60, "The view shows the reduced balance")
	_expect(int(spent_row.get("spent", -1)) == 40, "The view shows accumulated spending")
	_expect(not spent_row.has("history"), "The public view carries no spend history")
	var stored_row: Dictionary = _stored_fund(_funds_doc())
	var history: Array = stored_row.get("history", []) as Array
	_expect(history.size() == 1 and int((history[0] as Dictionary).get("amount", -1)) == 40
			and str((history[0] as Dictionary).get("project", "")) == "village_square",
		"The stored fund records exactly one spend history row")

	# The request side of the 48 KiB wire budget: the host answers a visible
	# refusal instead of dropping the oversized RPC.
	_fund_pending.erase("")
	var huge: String = JSON.stringify({
		"request_id": "fund-net-huge", "action": "state",
		"args": {"padding": "x".repeat(OVER_BUDGET_BYTES)},
	})
	_expect(huge.to_utf8_buffer().size() > 48 * 1024,
		"The oversized fund request really exceeds the wire budget")
	client.member.fund_request.rpc_id(1, huge)
	var over_budget: Dictionary = await _fund_key("", 15000)
	_expect(str(over_budget.get("reason", "")) == "payload_too_large",
		"An over-budget fund request gets a named refusal")
	var alive: Dictionary = await _fund("fund-net-state-after-refusals", "state")
	_expect(bool(alive.get("ok", false)) and _rows(alive).size() == 1,
		"The connection keeps working after the over-budget refusal")


# --------------------------------------------------------- second member flow

func _test_second_member(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "A second named member joins over WSS")
	if client == null or not client.joined:
		return
	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	var joined: Dictionary = await _organization("fund-net-org-join-b", "join", {
		"org_id": ORG, "command_id": "fund-net-org-join-b",
	})
	_expect(bool(joined.get("ok", false)), "The second member joins the organization")
	var org_row: Dictionary = _organization_row(_organizations(joined), ORG)
	_expect(str((org_row.get("members", {}) as Dictionary).get(PLAYER_B, "")) == "member",
		"The joined member holds the plain member role")

	var account_opened: Dictionary = await _submit(FarmCommand.make_account_open(
		"fund-net-account-b", client.world_time()))
	_expect(bool(account_opened.get("ok", false)),
		"The second member opens a real economy account")
	var farm_before: Dictionary = _farm_doc()
	_expect(_cash(farm_before, PLAYER_B) == 120,
		"The second member's opening grant is 120")
	var total_before: int = _total_cash(farm_before)

	var contributed: Dictionary = await _fund(CONTRIBUTE_B, "contribute", {
		"fund_id": fund_id, "amount": 1, "command_id": CONTRIBUTE_B,
	})
	_expect(bool(contributed.get("ok", false)), "The second member contributes 1")
	var farm_after: Dictionary = _farm_doc()
	_expect(_cash(farm_after, PLAYER_B) == 119,
		"The contribution charges the second member's real cash")
	_expect(_cash(farm_after, org_account) == 61,
		"The organization account receives the second contribution")
	_expect(_total_cash(farm_after) == total_before,
		"The second contribution preserves total cash")
	var row: Dictionary = _fund_row(contributed, fund_id)
	_expect(int(row.get("balance", -1)) == 61, "The fund balance becomes 61")
	_expect(int((row.get("contributors", {}) as Dictionary).get(PLAYER_B, -1)) == 1,
		"The second member's public total is recorded")

	# A plain member is not the keeper, so the spend is refused before any budget
	# or role check can let cash out.
	var refused: Dictionary = await _fund(SPEND_B_MEMBER, "spend", {
		"fund_id": fund_id, "project_id": "public_well", "amount": 5,
		"command_id": SPEND_B_MEMBER,
	})
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "not_keeper",
		"A plain member's spend is refused as not_keeper")
	_expect(_cash(_farm_doc(), org_account) == 61,
		"A refused plain-member spend moves no cash")


# -------------------------------------------------------------- rotation flow

func _test_rotation(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The leader reconnects to rotate the keeper")
	if client == null or not client.joined:
		return
	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	var org_cash_before: int = _cash(_farm_doc(), org_account)
	var total_before: int = _total_cash(_farm_doc())

	# The new keeper also needs a current role that may spend, so the leader
	# appoints them officer before the rotation.
	var appointed: Dictionary = await _organization("fund-net-appoint-b", "appoint", {
		"org_id": ORG, "player_id": PLAYER_B, "role": "officer",
		"command_id": "fund-net-appoint-b",
	})
	_expect(bool(appointed.get("ok", false)),
		"The leader appoints the second member officer")

	var rotated: Dictionary = await _fund(ROTATE, "rotate", {
		"fund_id": fund_id, "new_keeper": PLAYER_B, "command_id": ROTATE,
	})
	_expect(bool(rotated.get("ok", false)) and not bool(rotated.get("duplicate", true)),
		"The keeper rotates to an organization member who contributed")
	var row: Dictionary = _fund_row(rotated, fund_id)
	_expect(str(row.get("keeper", "")) == PLAYER_B, "The new keeper is recorded")
	_expect(int(row.get("balance", -1)) == 61 and int(row.get("spent", -1)) == 40,
		"Rotation changes neither balance nor spending")
	_expect(_cash(_farm_doc(), org_account) == org_cash_before
			and _total_cash(_farm_doc()) == total_before,
		"Rotation moves no cash")

	var old_keeper: Dictionary = await _fund(SPEND_OLD_KEEPER, "spend", {
		"fund_id": fund_id, "project_id": "public_well", "amount": 5,
		"command_id": SPEND_OLD_KEEPER,
	})
	_expect(not bool(old_keeper.get("ok", true))
			and str(old_keeper.get("reason", "")) == "not_keeper",
		"The former keeper can no longer spend")
	_expect(_cash(_farm_doc(), org_account) == org_cash_before,
		"A refused former-keeper spend moves no cash")


func _test_new_keeper(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The new keeper reconnects")
	if client == null or not client.joined:
		return
	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	var world_before: int = _cash(_farm_doc(), Economy.WORLD_OWNER)
	var total_before: int = _total_cash(_farm_doc())
	var spent: Dictionary = await _fund(SPEND_NEW_KEEPER, "spend", {
		"fund_id": fund_id, "project_id": "village_square", "amount": 10,
		"command_id": SPEND_NEW_KEEPER,
	})
	_expect(bool(spent.get("ok", false)), "The new keeper spends through the online channel")
	_expect(_cash(_farm_doc(), org_account) == 51,
		"The organization account pays the new keeper's spend")
	_expect(_cash(_farm_doc(), Economy.WORLD_OWNER) == world_before + 10,
		"The new keeper's spend lands in the public treasury")
	_expect(_total_cash(_farm_doc()) == total_before,
		"The new keeper's spend preserves total cash")
	var row: Dictionary = _fund_row(spent, fund_id)
	_expect(int(row.get("balance", -1)) == 51 and int(row.get("spent", -1)) == 50,
		"The fund view records the final balance and accumulated spending")


# ----------------------------------------------------------- permission paths

func _test_visitor(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("visitor", "")), VISITOR_ID, VISITOR_NAME,
		PLAYER_SECRET_A), "A named visitor joins with the visitor code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")
	var view: Dictionary = await _fund("visitor-state-1", "state")
	_expect(bool(view.get("ok", false)), "A visitor may read the fund view")
	_expect(_rows(view).size() == 1, "The visitor sees the authoritative fund table")
	var refused: Dictionary = await _fund("visitor-open-1", "open", {
		"org_id": ORG, "command_id": "visitor-open-1",
	})
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "forbidden",
		"A visitor's fund write is refused as forbidden")
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The visitor refusal carries a human-readable reason")
	var after: Dictionary = await _fund("visitor-state-2", "state")
	_expect(bool(after.get("ok", false)) and _rows(after).size() == 1,
		"The visitor stays connected and can still read after a refused write")


func _test_anonymous(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), "", "", ""),
		"An anonymous connection joins")
	if client == null or not client.joined:
		return
	var view: Dictionary = await _fund("anonymous-state-1", "state")
	_expect(bool(view.get("ok", false)), "An anonymous member may read the fund view")
	_expect(_rows(view).size() == 1, "The anonymous member sees the authoritative table")
	var refused: Dictionary = await _fund("anonymous-open-1", "open", {
		"org_id": OTHER_ORG, "command_id": "anonymous-open-1",
	})
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "no_player",
		"An anonymous fund write is refused for lack of a player identity")
	var after: Dictionary = await _fund("anonymous-state-2", "state")
	_expect(bool(after.get("ok", false)) and _rows(after).size() == 1,
		"The anonymous member stays connected and can still read after a refusal")


# -------------------------------------------------------------- restart replay

func _test_restart_replay(codes: Dictionary, before: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The member rejoins the restarted authority")
	if client == null or not client.joined:
		return
	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	var view: Dictionary = await _fund("restart-state-1", "state")
	var row: Dictionary = _fund_row(view, fund_id)
	_expect(bool(view.get("ok", false)) and not row.is_empty(),
		"The fund survives the authority restart")
	_expect(str(row.get("keeper", "")) == PLAYER_B,
		"The rotated keeper survives the restart")
	_expect(int(row.get("balance", -1)) == int(before.get("balance", -1)),
		"The fund balance survives the restart")
	_expect(_cash(_farm_doc(), org_account) == int(before.get("org_cash", -1)),
		"The organization account cash survives the restart")

	var replay: Dictionary = await _fund(CONTRIBUTE_A, "contribute", {
		"fund_id": fund_id, "amount": 100, "command_id": CONTRIBUTE_A,
	})
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the contribution after restart returns duplicate")
	var farm_after: Dictionary = _farm_doc()
	_expect(_cash(farm_after, PLAYER_A) == int(before.get("a_cash", -1)),
		"The restart replay charges no cash a second time")
	_expect(_cash(farm_after, org_account) == int(before.get("org_cash", -1)),
		"The restart replay does not credit the organization again")
	_expect(_total_cash(farm_after) == int(before.get("total", -1)),
		"The restart replay preserves total cash")
	_expect(_stored_fund_balance(_funds_doc()) == int(before.get("balance", -1)),
		"The restart replay does not change the fund balance")

	var conflict: Dictionary = await _fund(CONTRIBUTE_A, "contribute", {
		"fund_id": fund_id, "amount": 90, "command_id": CONTRIBUTE_A,
	})
	_expect(not bool(conflict.get("ok", true))
			and str(conflict.get("reason", "")) == "command_conflict",
		"A restart replay with another amount conflicts")
	_expect(_cash(_farm_doc(), org_account) == int(before.get("org_cash", -1)),
		"The restart conflict moves no cash")


# ------------------------------------------------------------------- helpers

func _start_authority() -> bool:
	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if port <= 0:
		return false
	url = "wss://127.0.0.1:%d" % port
	var args := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % START, "--run-seconds=0", "--join-url=" + url,
	])
	server_pid = OS.create_process(OS.get_executable_path(), args, false)
	_expect(server_pid > 0, "The authority process starts")
	if server_pid <= 0:
		return false
	var running: bool = await _wait(func() -> bool:
		var status: Dictionary = _status()
		return str(status.get("state", "")) == "running" \
			and int(status.get("pid", 0)) == server_pid, 20000)
	_expect(running, "The authority reports ready")
	return running


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
	_fund_pending.clear()
	_organization_pending.clear()
	_command_pending.clear()
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
			_now: float) -> void:
		_ready = true)
	client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
	client.lost.connect(func(reason: String) -> void: _refusals.append(reason))
	client.fund_result.connect(_on_fund_result)
	client.organization_result.connect(_on_organization_result)
	client.committed.connect(_on_committed)
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
	_fund_pending.clear()
	_organization_pending.clear()
	_command_pending.clear()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout


func _on_fund_result(request_id: String, payload: Dictionary) -> void:
	_fund_pending[request_id] = payload


func _on_organization_result(request_id: String, payload: Dictionary) -> void:
	_organization_pending[request_id] = payload


func _on_committed(request_id: String, payload: Dictionary) -> void:
	_command_pending[request_id] = payload


func _fund(request_id: String, action: String, args: Dictionary = {}) -> Dictionary:
	_fund_pending.erase(request_id)
	if client == null or not client.request_fund(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	return await _fund_key(request_id, 15000)


func _fund_key(request_id: String, timeout_ms: int) -> Dictionary:
	var arrived: bool = await _wait(func() -> bool:
		return _fund_pending.has(request_id), timeout_ms)
	if not arrived:
		_expect(false, "A fund reply arrives for request %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _fund_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


func _organization(request_id: String, action: String,
		args: Dictionary = {}) -> Dictionary:
	_organization_pending.erase(request_id)
	if client == null or not client.request_organization(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	var arrived: bool = await _wait(func() -> bool:
		return _organization_pending.has(request_id), 15000)
	if not arrived:
		_expect(false, "An organization reply arrives for request %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _organization_pending.get(request_id, {})
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
	var rows: Variant = (state_value as Dictionary).get("funds")
	return rows if rows is Array else []


func _fund_row(reply: Dictionary, fund_id: String) -> Dictionary:
	for value: Variant in _rows(reply):
		if value is Dictionary and str((value as Dictionary).get("fund_id", "")) == fund_id:
			return value
	return {}


func _organizations(reply: Dictionary) -> Array:
	var state_value: Variant = reply.get("state")
	if not state_value is Dictionary:
		return []
	var rows: Variant = (state_value as Dictionary).get("organizations")
	return rows if rows is Array else []


func _organization_row(rows: Array, org_id: String) -> Dictionary:
	for value: Variant in rows:
		if value is Dictionary and str((value as Dictionary).get("id", "")) == org_id:
			return value
	return {}


func _farm_doc() -> Dictionary:
	var saved: Dictionary = _read_json(world_dir.path_join("farm.json"))
	var farm: Variant = saved.get("farm")
	return farm if farm is Dictionary else {}


func _funds_doc() -> Dictionary:
	var saved: Dictionary = _read_json(world_dir.path_join(FundStore.MAIN))
	var state: Variant = saved.get("state")
	return state if state is Dictionary else {}


func _stored_fund(state: Dictionary) -> Dictionary:
	var funds_value: Variant = state.get("funds")
	if not funds_value is Dictionary:
		return {}
	var value: Variant = (funds_value as Dictionary).get(PublicFund.fund_for(ORG))
	return value if value is Dictionary else {}


func _stored_fund_balance(state: Dictionary) -> int:
	var row: Dictionary = _stored_fund(state)
	return int(row.get("balance", -1)) if not row.is_empty() else -1


func _cash(farm: Dictionary, owner: String) -> int:
	var economy: Variant = farm.get("economy")
	if not economy is Dictionary:
		return -1
	var accounts: Variant = (economy as Dictionary).get("accounts")
	if not accounts is Dictionary:
		return -1
	var account: Variant = (accounts as Dictionary).get(owner)
	return int((account as Dictionary).get("cash", -1)) if account is Dictionary else 0


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
	print("FUND_NETWORK_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
