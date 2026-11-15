extends SceneTree
## Public works authority over the real wire: the RPC channels 21/22, not the
## WorldHost seam that `public_works_authority_test.gd` exercises directly.
##
## A real `world_server.gd` process serves a fresh world over loopback WSS with a
## `--host-player`, and `WorldClient` connections drive
## `request_public_works()` through the online transport:
##   - the host player joins as a named member and reads an empty project table;
##   - the host creates an organization, opens its fund, opens a real economy
##     account and contributes 120, then opens projects and pledges/releases;
##   - the keeper builds a funded road with the organization fund: the fund
##     balance drops by the fixed catalog cost, `@world` receives it, the project
##     is built, the sidecars and fund history record the spend;
##   - the same build command id replays as `duplicate` with no second payment,
##     and the same id with another project is a `command_conflict`;
##   - open/pledge/release and the built project survive a stop and restart on the
##     same data directory; the build replay after restart is still a duplicate
##     and the changed-parameter retry is still a conflict, with no cash moved;
##   - a visitor may read the project view but not write (`forbidden`), an
##     anonymous member may read but has no player identity (`no_player`), an
##     authenticated but unjoined connection gets no reply at all, and a
##     read-only authority still reads but refuses writes (`read_only`);
##   - a raw request over the 48 KiB wire budget gets a named `payload_too_large`
##     refusal and the connection keeps working.
##
## `server-status.json` is asserted on every platform. The `WORLD_SERVER_READY` /
## `WORLD_SERVER_STOP` log lines need a shell to capture stdout, so those checks
## run only where `/bin/sh` exists and are skipped on Windows.
##
## Everything runs under .local/verification/public-works-network-<ticks>/.

const WorldClient = preload("res://world/world_client.gd")
const WorldMember = preload("res://world/world_member.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Economy = preload("res://farm/economy_state.gd")
const PublicFund = preload("res://world/public_fund.gd")
const PublicWorks = preload("res://world/public_works.gd")
const FundStore = preload("res://world/fund_store.gd")
const PublicWorksStore = preload("res://world/public_works_store.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
## One installation credential per identity: the authority issues the one-time
## account grant per credential, so two named members must not share one.
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const START: float = 1800000000.0
const WORLD: String = "world-public-works-network"
const PLAYER_A: String = "player_00000000000000000000000000000071"
const VISITOR_ID: String = "player_00000000000000000000000000000073"
const NAME_A: String = "阿岸"
const VISITOR_NAME: String = "路人"
const ORG: String = "guild_works_net"
const OVER_BUDGET_BYTES: int = 50000

const ORG_CREATE: String = "pw-net-org-create"
const FUND_OPEN: String = "pw-net-fund-open"
const FUND_CONTRIBUTE: String = "pw-net-fund-contribute"
const ACCOUNT_OPEN: String = "pw-net-account-open"
const OPEN_ROAD: String = "pw-net-open-road"
const OPEN_ROAD_TWO: String = "pw-net-open-road-two"
const OPEN_WELL: String = "pw-net-open-well"
const PLEDGE_ROAD: String = "pw-net-pledge-road"
const PLEDGE_ROAD_TWO: String = "pw-net-pledge-road-two"
const PLEDGE_WELL: String = "pw-net-pledge-well"
const RELEASE_WELL: String = "pw-net-release-well"
const BUILD_ROAD: String = "pw-net-build-road"

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var url: String = ""
var log_path: String = ""
var log_captured: bool = false
var checks: int = 0
var failures: Array[String] = []
var client: WorldClient
var _ready: bool = false
var _refusals: Array[String] = []
var _works_pending: Dictionary = {}
var _fund_pending: Dictionary = {}
var _organization_pending: Dictionary = {}
var _command_pending: Dictionary = {}


## A session that completes the invite handshake but never sends `join`, so the
## authority has no roster entry for it and must drop its project RPC silently.
class UnjoinedSession extends "res://world/world_member.gd":
	var sent_hello: bool = false

	func _on_session_ready() -> void:
		pass

	func _process(_delta: float) -> void:
		if sent_hello:
			return
		var peer: MultiplayerPeer = multiplayer.multiplayer_peer
		if peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			sent_hello = true
			multiplayer.send_auth(1, auth_hello())


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/public-works-network-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	if not await _start_authority("created"):
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

	await _test_member_flow(codes)
	await _close_client()
	await _test_visitor(codes)
	await _close_client()
	await _test_anonymous(codes)
	await _close_client()
	await _test_unjoined(codes)
	await _test_restart_and_read_only(codes)
	_finish()


# ---------------------------------------------------------------- member flow

func _test_member_flow(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host player joins as a named member over WSS")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.MEMBER,
		"The join reply confers the member role")

	var empty: Dictionary = await _works("pw-net-state-1", "state")
	_expect(bool(empty.get("ok", false)) and str(empty.get("action", "")) == "state",
		"The authority answers a project state request over channel 21")
	_expect(_rows(empty).is_empty(), "A fresh world has an empty project table")

	var created: Dictionary = await _organization(ORG_CREATE, "create", {
		"org_id": ORG, "name": "河岸工程", "command_id": ORG_CREATE,
	})
	_expect(bool(created.get("ok", false)),
		"The host creates the organization through channels 11/12")

	var account_opened: Dictionary = await _submit(FarmCommand.make_account_open(
		ACCOUNT_OPEN, client.world_time()))
	_expect(bool(account_opened.get("ok", false)),
		"The host opens a real economy account through the authority")
	_expect(_cash(_farm_doc(), PLAYER_A) == 120,
		"The opening grant is the host's real cash (120)")

	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	var fund_opened: Dictionary = await _fund(FUND_OPEN, "open", {
		"org_id": ORG, "command_id": FUND_OPEN,
	})
	_expect(bool(fund_opened.get("ok", false)),
		"The host opens the derived organization fund over channel 15")
	var contributed: Dictionary = await _fund(FUND_CONTRIBUTE, "contribute", {
		"fund_id": fund_id, "amount": 120, "command_id": FUND_CONTRIBUTE,
	})
	_expect(bool(contributed.get("ok", false)),
		"The host contributes 120 to the organization fund")
	var contributed_row: Dictionary = _fund_row(contributed, fund_id)
	_expect(int(contributed_row.get("balance", -1)) == 120,
		"The fund balance grows to 120")
	_expect(_cash(_farm_doc(), PLAYER_A) == 0
			and _cash(_farm_doc(), org_account) == 120,
		"Contributing moves real cash from the player to the organization account")

	var road: Dictionary = await _works(OPEN_ROAD, "open", {
		"project_id": "road_01", "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"command_id": OPEN_ROAD,
	})
	_expect(bool(road.get("ok", false)) and str(road.get("project_id", "")) == "road_01",
		"The member opens a road project over channel 21")
	var road_row: Dictionary = _project_row(road, "road_01")
	_expect(not road_row.is_empty()
			and str(road_row.get("kind", "")) == PublicWorks.KIND_ROAD_SEGMENT
			and int(road_row.get("pledged", -1)) == 0
			and int(road_row.get("funded", -1)) == 0
			and str(road_row.get("status", "")) == PublicWorks.STATUS_UNBUILT,
		"The reply carries the authoritative unbuilt project row")

	var road_two: Dictionary = await _works(OPEN_ROAD_TWO, "open", {
		"project_id": "road_02", "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"command_id": OPEN_ROAD_TWO,
	})
	_expect(bool(road_two.get("ok", false)),
		"A second same-cost project is opened for the conflict probe")
	var well: Dictionary = await _works(OPEN_WELL, "open", {
		"project_id": "well_01", "kind": PublicWorks.KIND_PUBLIC_WELL,
		"command_id": OPEN_WELL,
	})
	_expect(bool(well.get("ok", false)),
		"A well project is opened to persist pledge and release")

	var pledged: Dictionary = await _works(PLEDGE_ROAD, "pledge", {
		"project_id": "road_01", "amount": 120, "command_id": PLEDGE_ROAD,
	})
	_expect(bool(pledged.get("ok", false)), "The road is pledged to its fixed cost")
	road_row = _project_row(pledged, "road_01")
	_expect(int(road_row.get("pledged", -1)) == 120
			and int(road_row.get("funded", -1)) == 120
			and str(road_row.get("status", "")) == PublicWorks.STATUS_FUNDED,
		"A full pledge marks the road funded")

	var well_pledged: Dictionary = await _works(PLEDGE_WELL, "pledge", {
		"project_id": "well_01", "amount": 100, "command_id": PLEDGE_WELL,
	})
	_expect(bool(well_pledged.get("ok", false)), "The well is partially pledged")
	var well_released: Dictionary = await _works(RELEASE_WELL, "release", {
		"project_id": "well_01", "amount": 40, "command_id": RELEASE_WELL,
	})
	_expect(bool(well_released.get("ok", false)), "Part of the well pledge is released")
	var well_row: Dictionary = _project_row(well_released, "well_01")
	_expect(int(well_row.get("pledged", -1)) == 60
			and int(well_row.get("funded", -1)) == 60
			and str(well_row.get("status", "")) == PublicWorks.STATUS_UNBUILT,
		"Pledge minus release leaves 60 pledged and unbuilt")

	var road_two_pledged: Dictionary = await _works(PLEDGE_ROAD_TWO, "pledge", {
		"project_id": "road_02", "amount": 120, "command_id": PLEDGE_ROAD_TWO,
	})
	_expect(bool(road_two_pledged.get("ok", false)),
		"The second road reaches its fixed cost")

	var farm_before: Dictionary = _farm_doc()
	var org_before: int = _cash(farm_before, org_account)
	var world_before: int = _cash(farm_before, Economy.WORLD_OWNER)
	var total_before: int = _total_cash(farm_before)
	var cost: int = PublicWorks.cost_of(PublicWorks.KIND_ROAD_SEGMENT)
	_expect(org_before == 120 and cost == 120,
		"The organization account holds exactly the road's fixed cost")

	var built: Dictionary = await _works(BUILD_ROAD, "build", {
		"project_id": "road_01", "fund_id": fund_id, "command_id": BUILD_ROAD,
	})
	_expect(bool(built.get("ok", false)) and not bool(built.get("duplicate", true)),
		"The keeper builds the funded road with the organization fund")
	_expect(str(built.get("action", "")) == "build"
			and str(built.get("project_id", "")) == "road_01",
		"The build reply names the action and project")
	var built_row: Dictionary = _project_row(built, "road_01")
	_expect(str(built_row.get("status", "")) == PublicWorks.STATUS_BUILT
			and float(built_row.get("built_utc", 0.0)) > 0.0,
		"The authoritative project view reports the road built")

	var farm_after: Dictionary = _farm_doc()
	_expect(_cash(farm_after, org_account) == org_before - cost,
		"The organization account pays exactly the fixed cost")
	_expect(_cash(farm_after, Economy.WORLD_OWNER) == world_before + cost,
		"The fixed cost lands in the public treasury")
	_expect(_total_cash(farm_after) == total_before,
		"A build preserves total cash")

	var fund_view: Dictionary = await _fund("pw-net-fund-state-1", "state")
	var fund_after_row: Dictionary = _fund_row(fund_view, fund_id)
	_expect(int(fund_after_row.get("balance", -1)) == 0
			and int(fund_after_row.get("spent", -1)) == cost,
		"The fund view shows the reduced balance and the fixed cost spent")

	var stored_works: Dictionary = _works_doc()
	var stored_road: Dictionary = _stored_project(stored_works, "road_01")
	_expect(str(stored_road.get("status", "")) == PublicWorks.STATUS_BUILT,
		"The built project is written to the project sidecar")
	var history: Array = _fund_history(_funds_doc(), fund_id)
	_expect(history.size() == 1
			and str((history[0] as Dictionary).get("kind", ""))
				== PublicFund.HISTORY_KIND_SPEND
			and int((history[0] as Dictionary).get("amount", -1)) == cost
			and str((history[0] as Dictionary).get("project", "")) == "road_01",
		"The fund history records exactly one spend for the road")

	var works_bytes: PackedByteArray = _bytes(
		world_dir.path_join(PublicWorksStore.MAIN))
	var funds_bytes: PackedByteArray = _bytes(world_dir.path_join(FundStore.MAIN))
	var farm_text: String = JSON.stringify(_farm_doc())
	var replay: Dictionary = await _works(BUILD_ROAD, "build", {
		"project_id": "road_01", "fund_id": fund_id, "command_id": BUILD_ROAD,
	})
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the same build command id returns duplicate")
	_expect(_bytes(world_dir.path_join(PublicWorksStore.MAIN)) == works_bytes
			and _bytes(world_dir.path_join(FundStore.MAIN)) == funds_bytes,
		"A build replay rewrites neither sidecar")
	_expect(JSON.stringify(_farm_doc()) == farm_text,
		"A build replay moves no cash")

	var conflict: Dictionary = await _works(BUILD_ROAD, "build", {
		"project_id": "road_02", "fund_id": fund_id, "command_id": BUILD_ROAD,
	})
	_expect(not bool(conflict.get("ok", true))
			and str(conflict.get("reason", "")) == "command_conflict",
		"Reusing the build command id for another project conflicts")
	_expect(_bytes(world_dir.path_join(PublicWorksStore.MAIN)) == works_bytes
			and _bytes(world_dir.path_join(FundStore.MAIN)) == funds_bytes
			and JSON.stringify(_farm_doc()) == farm_text,
		"A build command conflict changes no document and moves no cash")

	# The request side of the 48 KiB wire budget: the host answers a visible
	# refusal instead of dropping the oversized RPC.
	_works_pending.erase("")
	var huge: String = JSON.stringify({
		"request_id": "pw-net-huge", "action": "state",
		"args": {"padding": "x".repeat(OVER_BUDGET_BYTES)},
	})
	_expect(huge.to_utf8_buffer().size() > 48 * 1024,
		"The oversized project request really exceeds the wire budget")
	client.member.public_works_request.rpc_id(1, huge)
	var over_budget: Dictionary = await _works_key("", 15000)
	_expect(str(over_budget.get("reason", "")) == "payload_too_large",
		"An over-budget project request gets a named refusal")
	var alive: Dictionary = await _works("pw-net-state-after-refusals", "state")
	_expect(bool(alive.get("ok", false)) and _rows(alive).size() == 3,
		"The connection keeps working after the over-budget refusal")


# ----------------------------------------------------------- permission paths

func _test_visitor(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("visitor", "")), VISITOR_ID, VISITOR_NAME,
		PLAYER_SECRET_A), "A named visitor joins with the visitor code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")
	var view: Dictionary = await _works("pw-net-visitor-state-1", "state")
	_expect(bool(view.get("ok", false)), "A visitor may read the project view")
	_expect(_rows(view).size() == 3, "The visitor sees the authoritative project table")
	var road: Dictionary = _project_row(view, "road_01")
	_expect(str(road.get("status", "")) == PublicWorks.STATUS_BUILT,
		"The visitor sees the built project")
	var refused: Dictionary = await _works("pw-net-visitor-open", "open", {
		"project_id": "visitor_well", "kind": PublicWorks.KIND_PUBLIC_WELL,
		"command_id": "pw-net-visitor-open",
	})
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "forbidden",
		"A visitor's project write is refused as forbidden")
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The visitor refusal carries a human-readable reason")
	var after: Dictionary = await _works("pw-net-visitor-state-2", "state")
	_expect(bool(after.get("ok", false)) and _rows(after).size() == 3,
		"The visitor stays connected and can still read after a refused write")


func _test_anonymous(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), "", "", ""),
		"An anonymous connection joins")
	if client == null or not client.joined:
		return
	var view: Dictionary = await _works("pw-net-anonymous-state-1", "state")
	_expect(bool(view.get("ok", false)), "An anonymous member may read the project view")
	_expect(_rows(view).size() == 3, "The anonymous member sees the authoritative table")
	var refused: Dictionary = await _works("pw-net-anonymous-open", "open", {
		"project_id": "anonymous_well", "kind": PublicWorks.KIND_PUBLIC_WELL,
		"command_id": "pw-net-anonymous-open",
	})
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "no_player",
		"An anonymous project write is refused for lack of a player identity")
	var after: Dictionary = await _works("pw-net-anonymous-state-2", "state")
	_expect(bool(after.get("ok", false)) and _rows(after).size() == 3,
		"The anonymous member stays connected after a refusal")


## A connection that authenticated but never joined is not in the roster. The
## server drops its project RPC without an answer (it must not act as a member,
## and must not leak whether the request was accepted).
func _test_unjoined(codes: Dictionary) -> void:
	await _close_client()
	var parsed: Dictionary = WorldJoinCode.decode(str(codes.get("member", "")))
	_expect(bool(parsed.get("ok", false)),
		"The member join code decodes for the unjoined probe")
	if not bool(parsed.get("ok", false)):
		return
	var grant: Dictionary = parsed.get("grant", {}) as Dictionary
	var secret: PackedByteArray = grant.get("secret", PackedByteArray())
	var certificate := X509Certificate.new()
	if certificate.load_from_string(str(parsed.get("certificate", ""))) != OK:
		_expect(false, "The join code carries a loadable certificate")
		return
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client(str(parsed.get("url", "")),
			TLSOptions.client(certificate, str(parsed.get("server_name", "localhost")))) != OK:
		_expect(false, "The unjoined probe creates a WebSocket client")
		return
	root.multiplayer.multiplayer_peer = peer
	var replies: Array = []
	var losses: Array[String] = []
	var session := UnjoinedSession.new()
	session.name = WorldMember.SESSION_NODE_NAME
	session.grant_id = str(grant.get("id", ""))
	session.public_works_result.connect(func(request_id: String, payload: Dictionary) -> void:
		replies.append({"request_id": request_id, "payload": payload}))
	session.authority_lost.connect(func(reason: String) -> void:
		losses.append(reason))
	root.add_child(session)
	root.multiplayer.auth_callback = func(_id: int, data: PackedByteArray) -> void:
		root.multiplayer.send_auth(1, Crypto.new().hmac_digest(
			HashingContext.HASH_SHA256, secret, data))
		root.multiplayer.complete_auth(1)
	session.connect_to(str(parsed.get("url", "")), secret, WORLD)
	var connected: bool = await _wait(func() -> bool:
		return peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED, 15000)
	_expect(connected, "A session can connect and authenticate without joining")
	if not connected:
		await _close_unjoined(peer, session)
		return
	# Give the challenge/response a moment before sending the unauthenticated RPC;
	# the probe must not join on its own.
	await create_timer(0.8).timeout
	_expect(not session.is_joined(), "The probe never joins the world")
	session.public_works_request.rpc_id(1, JSON.stringify({
		"request_id": "pw-net-unjoined", "action": "open",
		"args": {"project_id": "intruder_well", "kind": PublicWorks.KIND_PUBLIC_WELL,
			"command_id": "pw-net-unjoined"},
	}))
	var replied: bool = await _wait(func() -> bool: return not replies.is_empty(), 1500)
	_expect(not replied,
		"An unjoined connection's project write gets no authority reply")
	_expect(losses.is_empty(),
		"The unjoined connection stayed authenticated and was not refused")
	await _close_unjoined(peer, session)


# ------------------------------------------------------- restart persistence

func _test_restart_and_read_only(codes: Dictionary) -> void:
	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	var farm_before: Dictionary = _farm_doc()
	var works_before: Dictionary = _works_doc()
	var funds_before: Dictionary = _funds_doc()
	var org_before: int = _cash(farm_before, org_account)
	var world_before: int = _cash(farm_before, Economy.WORLD_OWNER)
	var total_before: int = _total_cash(farm_before)
	var balance_before: int = _stored_fund_balance(funds_before)
	var built_utc_before: float = float(
		_stored_project(works_before, "road_01").get("built_utc", -1.0))
	var history_before: Array = _fund_history(funds_before, fund_id)
	_expect(balance_before == 0 and history_before.size() == 1,
		"The committed fund state is ready for the restart")

	await _stop_server()
	if not await _start_authority("loaded"):
		_finish()
		return
	# The restart may listen on another free port, and a join code carries the
	# endpoint, so the operator material is rebuilt for the new run.
	codes = _join_codes()
	_expect(not str(codes.get("member", "")).is_empty(),
		"The restarted authority publishes a usable member code")
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The member rejoins the restarted authority")
	if client == null or not client.joined:
		return

	var view: Dictionary = await _works("pw-net-restart-state", "state")
	_expect(bool(view.get("ok", false)), "The restarted authority answers project state")
	var road: Dictionary = _project_row(view, "road_01")
	_expect(str(road.get("status", "")) == PublicWorks.STATUS_BUILT
			and float(road.get("built_utc", 0.0)) == built_utc_before,
		"The built project and its build time survive the restart")
	var well: Dictionary = _project_row(view, "well_01")
	_expect(not well.is_empty()
			and int(well.get("pledged", -1)) == 60
			and int(well.get("funded", -1)) == 60
			and str(well.get("status", "")) == PublicWorks.STATUS_UNBUILT,
		"The open/pledge/release record survives the restart")
	var road_two: Dictionary = _project_row(view, "road_02")
	_expect(not road_two.is_empty()
			and int(road_two.get("pledged", -1)) == 120
			and str(road_two.get("status", "")) == PublicWorks.STATUS_FUNDED,
		"The second funded project survives the restart")

	var farm_after: Dictionary = _farm_doc()
	_expect(_cash(farm_after, org_account) == org_before
			and _cash(farm_after, Economy.WORLD_OWNER) == world_before
			and _total_cash(farm_after) == total_before,
		"The organization, treasury and total cash survive the restart")
	var funds_after: Dictionary = _funds_doc()
	_expect(_stored_fund_balance(funds_after) == balance_before,
		"The fund balance survives the restart")
	var history_after: Array = _fund_history(funds_after, fund_id)
	_expect(history_after.size() == 1
			and int((history_after[0] as Dictionary).get("amount", -1)) == 120,
		"The fund spend history survives the restart")

	var works_bytes: PackedByteArray = _bytes(
		world_dir.path_join(PublicWorksStore.MAIN))
	var funds_bytes: PackedByteArray = _bytes(world_dir.path_join(FundStore.MAIN))
	var farm_text: String = JSON.stringify(_farm_doc())
	var replay: Dictionary = await _works(BUILD_ROAD, "build", {
		"project_id": "road_01", "fund_id": fund_id, "command_id": BUILD_ROAD,
	})
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the build after the restart still returns duplicate")
	_expect(_bytes(world_dir.path_join(PublicWorksStore.MAIN)) == works_bytes
			and _bytes(world_dir.path_join(FundStore.MAIN)) == funds_bytes
			and JSON.stringify(_farm_doc()) == farm_text,
		"The restart replay moves no cash and rewrites no document")

	var conflict: Dictionary = await _works(BUILD_ROAD, "build", {
		"project_id": "road_02", "fund_id": fund_id, "command_id": BUILD_ROAD,
	})
	_expect(not bool(conflict.get("ok", true))
			and str(conflict.get("reason", "")) == "command_conflict",
		"A restart replay with another project conflicts")
	_expect(_bytes(world_dir.path_join(PublicWorksStore.MAIN)) == works_bytes
			and _bytes(world_dir.path_join(FundStore.MAIN)) == funds_bytes
			and JSON.stringify(_farm_doc()) == farm_text,
		"The restart conflict moves no cash and rewrites no document")

	# A retiring authority refuses writes but still answers reads. This runs last
	# because the marker stays until an operator removes it.
	var marker := FileAccess.open(world_dir.path_join("read-only"), FileAccess.WRITE)
	if marker != null:
		marker.store_string("1")
		marker.close()
	var read_only: bool = await _wait(func() -> bool:
		return bool(_status().get("read_only", false)), 10000)
	_expect(read_only, "The retirement marker turns the authority read-only")
	var refused: Dictionary = await _works("pw-net-read-only-open", "open", {
		"project_id": "read_only_well", "kind": PublicWorks.KIND_PUBLIC_WELL,
		"command_id": "pw-net-read-only-open",
	})
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "read_only",
		"A read-only authority refuses project writes")
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The read-only refusal carries a human-readable reason")
	var still: Dictionary = await _works("pw-net-read-only-state", "state")
	_expect(bool(still.get("ok", false)) and _rows(still).size() == 3,
		"A read-only authority still answers project reads")
	_expect(not (_works_doc().get("projects", {}) as Dictionary).has("read_only_well"),
		"The refused read-only write reaches no document")

	await _close_client()
	await _stop_server("read_only_skipped")


# ------------------------------------------------------------------- helpers

func _start_authority(expected_open: String) -> bool:
	port = _free_port()
	_expect(port > 0, "A free loopback port is available for the authority")
	if port <= 0:
		return false
	url = "wss://127.0.0.1:%d" % port
	var args: Array[String] = [
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % START, "--run-seconds=0", "--join-url=" + url,
		"--host-player=" + PLAYER_A,
	]
	log_path = world_dir.path_join("server-%d.log" % Time.get_ticks_usec())
	log_captured = OS.get_name() != "Windows"
	if log_captured:
		# `exec` keeps the shell's PID as the server's PID, so the status file's
		# pid and OS.is_process_running still identify the authority itself.
		var command: String = "exec " + _shell_quote(OS.get_executable_path())
		for argument: String in args:
			command += " " + _shell_quote(argument)
		command += " > " + _shell_quote(log_path) + " 2>&1"
		server_pid = OS.create_process("/bin/sh", PackedStringArray(["-c", command]), false)
	else:
		server_pid = OS.create_process(OS.get_executable_path(),
			PackedStringArray(args), false)
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
	var status: Dictionary = _status()
	_expect(str(status.get("world_id", "")) == WORLD,
		"The status file names the world the authority serves")
	_expect(int(status.get("port", 0)) == port,
		"The status file records the listening port")
	_expect(str(status.get("opened", "")) == expected_open,
		"The status file records that the world was %s" % expected_open)
	await _assert_start_log()
	return true


func _assert_start_log() -> void:
	if not log_captured:
		return
	var appeared: bool = await _wait(func() -> bool:
		return _read_text(log_path).contains("WORLD_SERVER_READY"), 3000)
	_expect(appeared, "The authority log reports readiness")
	var text: String = _read_text(log_path)
	_expect(not text.contains("WORLD_SERVER_ERROR"),
		"The authority log has no server error line")
	_expect(not text.contains("SCRIPT ERROR"),
		"The authority log has no script error")
	var ready: Dictionary = _line_payload(text, "WORLD_SERVER_READY")
	_expect(str(ready.get("host_player", "")) == PLAYER_A,
		"The readiness line names the host player from the start option")


func _assert_stop_log() -> void:
	if not log_captured:
		return
	var appeared: bool = await _wait(func() -> bool:
		return _read_text(log_path).contains("WORLD_SERVER_STOP"), 3000)
	_expect(appeared, "The authority log reports a graceful stop")
	_expect(not _read_text(log_path).contains("SCRIPT ERROR"),
		"The stopped authority log has no script error")


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
	_works_pending.clear()
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
	client.public_works_result.connect(_on_public_works_result)
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
	_works_pending.clear()
	_fund_pending.clear()
	_organization_pending.clear()
	_command_pending.clear()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout


func _close_unjoined(peer: WebSocketMultiplayerPeer, session: Node) -> void:
	if is_instance_valid(session):
		session.queue_free()
	if peer != null:
		peer.close()
		if root.multiplayer.multiplayer_peer == peer:
			root.multiplayer.multiplayer_peer = null
	await process_frame
	await create_timer(0.2).timeout


func _on_public_works_result(request_id: String, payload: Dictionary) -> void:
	_works_pending[request_id] = payload


func _on_fund_result(request_id: String, payload: Dictionary) -> void:
	_fund_pending[request_id] = payload


func _on_organization_result(request_id: String, payload: Dictionary) -> void:
	_organization_pending[request_id] = payload


func _on_committed(request_id: String, payload: Dictionary) -> void:
	_command_pending[request_id] = payload


func _works(request_id: String, action: String, args: Dictionary = {}) -> Dictionary:
	_works_pending.erase(request_id)
	if client == null or not client.request_public_works(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	return await _works_key(request_id, 15000)


func _works_key(request_id: String, timeout_ms: int) -> Dictionary:
	var arrived: bool = await _wait(func() -> bool:
		return _works_pending.has(request_id), timeout_ms)
	if not arrived:
		_expect(false, "A project reply arrives for request %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _works_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


func _fund(request_id: String, action: String, args: Dictionary = {}) -> Dictionary:
	_fund_pending.erase(request_id)
	if client == null or not client.request_fund(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	var arrived: bool = await _wait(func() -> bool:
		return _fund_pending.has(request_id), 15000)
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
	if client == null or not client.submit(command):
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
	var rows: Variant = (state_value as Dictionary).get("projects")
	return rows if rows is Array else []


func _project_row(reply: Dictionary, project_id: String) -> Dictionary:
	for value: Variant in _rows(reply):
		if value is Dictionary \
				and str((value as Dictionary).get("project_id", "")) == project_id:
			return value
	return {}


func _fund_row(reply: Dictionary, fund_id: String) -> Dictionary:
	var state_value: Variant = reply.get("state")
	if not state_value is Dictionary:
		return {}
	var rows: Variant = (state_value as Dictionary).get("funds")
	if not rows is Array:
		return {}
	for value: Variant in rows:
		if value is Dictionary and str((value as Dictionary).get("fund_id", "")) == fund_id:
			return value
	return {}


func _farm_doc() -> Dictionary:
	var saved: Dictionary = _read_json(world_dir.path_join("farm.json"))
	var farm: Variant = saved.get("farm")
	return farm if farm is Dictionary else {}


func _works_doc() -> Dictionary:
	var saved: Dictionary = _read_json(world_dir.path_join(PublicWorksStore.MAIN))
	var state: Variant = saved.get("state")
	return state if state is Dictionary else {}


func _funds_doc() -> Dictionary:
	var saved: Dictionary = _read_json(world_dir.path_join(FundStore.MAIN))
	var state: Variant = saved.get("state")
	return state if state is Dictionary else {}


func _stored_project(state: Dictionary, project_id: String) -> Dictionary:
	var projects_value: Variant = state.get("projects")
	if not projects_value is Dictionary:
		return {}
	var value: Variant = (projects_value as Dictionary).get(project_id)
	return value if value is Dictionary else {}


func _stored_fund(state: Dictionary, fund_id: String) -> Dictionary:
	var funds_value: Variant = state.get("funds")
	if not funds_value is Dictionary:
		return {}
	var value: Variant = (funds_value as Dictionary).get(fund_id)
	return value if value is Dictionary else {}


func _stored_fund_balance(state: Dictionary) -> int:
	var row: Dictionary = _stored_fund(state, PublicFund.fund_for(ORG))
	return int(row.get("balance", -1)) if not row.is_empty() else -1


func _fund_history(state: Dictionary, fund_id: String) -> Array:
	var row: Dictionary = _stored_fund(state, fund_id)
	var history: Variant = row.get("history")
	return history if history is Array else []


func _cash(farm: Dictionary, owner: String) -> int:
	var economy: Variant = farm.get("economy")
	if not economy is Dictionary:
		return -1
	var accounts: Variant = (economy as Dictionary).get("accounts")
	if not accounts is Dictionary:
		return -1
	var account: Variant = (accounts as Dictionary).get(owner)
	return int((account as Dictionary).get("cash", -1)) if account is Dictionary else 0


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


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func _bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) \
		if FileAccess.file_exists(path) else PackedByteArray()


func _line_payload(text: String, tag: String) -> Dictionary:
	for line: String in text.split("\n"):
		var trimmed: String = line.strip_edges()
		if not trimmed.begins_with(tag + " "):
			continue
		var parsed: Variant = JSON.parse_string(trimmed.trim_prefix(tag + " "))
		if parsed is Dictionary:
			return parsed
	return {}


func _stop_server(expected_save: String = "saved") -> void:
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
	var status: Dictionary = _status()
	_expect(str(status.get("state", "")) == "stopped",
		"The shutdown is recorded in the status file")
	_expect(str(status.get("save", "")) == expected_save,
		"The status file records the %s save outcome" % expected_save)
	if not stopped:
		OS.kill(server_pid)
	await _assert_stop_log()
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


func _shell_quote(text: String) -> String:
	return "'" + text.replace("'", "'\\''") + "'"


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("PUBLIC_WORKS_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
