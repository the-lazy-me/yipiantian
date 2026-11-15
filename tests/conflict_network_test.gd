extends SceneTree
## Conflict authority over the real wire: the RPC channels 19/20, not the
## WorldHost seam that `conflict_authority_test.gd` exercises directly.
##
## A real `world_server.gd` process serves a fresh world over loopback WSS with
## `--host-player`, and `WorldClient` connections drive the online transport:
##   - both named members open a real account, open the rule merchant and buy
##     supplies, then recruit their units over channels 13/14, so the engagement
##     uses the authoritative roster rather than a fixture;
##   - while the room is still the default peace regime, a real engagement is
##     refused `peace` and changes no farm or unit byte;
##   - the host declares the limited regime and consents as attacker through
##     channels 17/18, the second member joins and consents as defender;
##   - before that consent, the same engagement is refused `no_consent`;
##   - the host then engages over channels 19/20: the reply is `ok`, the target
##     budget in `state.targets` accumulates the loss, and the server's
##     `farm.json` (cash and supplies), `units.json` (people) and
##     `conflicts.json` all change;
##   - replaying the same command id returns `duplicate` with the four documents
##     byte-identical, and reusing the id with another position is a
##     `command_conflict` that changes no byte;
##   - a visitor may read but not write (`forbidden`), an anonymous member may
##     read but has no player identity (`no_player`), an authenticated but
##     unjoined connection gets no reply, and a raw request over the 48 KiB wire
##     budget gets a named `payload_too_large` refusal while the connection keeps
##     working;
##   - after a graceful stop and a restart on the same data directory the target
##     budget and conflicts document survive, and the replay is still a
##     duplicate that pays nothing twice.
##
## `server-status.json` is asserted on every platform. The `WORLD_SERVER_READY`
## / `WORLD_SERVER_STOP` log lines need a shell to capture stdout, so those
## checks run only where `/bin/sh` exists and are skipped on Windows.
##
## Everything runs under .local/verification/conflict-network-<ticks>/.

const WorldClient = preload("res://world/world_client.gd")
const WorldMember = preload("res://world/world_member.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Economy = preload("res://farm/economy_state.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")
const Participation = preload("res://conflict/participation_state.gd")
const ConflictSettlement = preload("res://world/conflict_settlement.gd")
const ConflictStore = preload("res://world/conflict_store.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
## One installation credential per identity: the authority binds the first proof
## it sees, so two named members must not share one.
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const START: float = 1800000000.0
const WORLD: String = "world-conflict-network"
const PLAYER_A: String = "player_00000000000000000000000000000081"
const PLAYER_B: String = "player_00000000000000000000000000000082"
const VISITOR_ID: String = "player_00000000000000000000000000000083"
const NAME_A: String = "阿武"
const NAME_B: String = "阿守"
const VISITOR_NAME: String = "旁观者"
const OVER_BUDGET_BYTES: int = 50000

const DECLARATION_ID: String = "decl_net_conflict"
const REGIME_ID: String = "conflict-net-regime"
const A_CONSENT_ID: String = "conflict-net-a-attacker"
const B_CONSENT_ID: String = "conflict-net-b-defender"
const A_UNIT: String = "conflict-net-unit-a"
const B_UNIT: String = "conflict-net-unit-b"
const BATTLE_ID: String = "conflict-net-battle"
const A_OPEN: String = "conflict-net-a-open"
const B_OPEN: String = "conflict-net-b-open"
const MERCHANT_OPEN: String = "conflict-net-merchant-open"
const A_BUY: String = "conflict-net-a-buy"
const B_BUY: String = "conflict-net-b-buy"
## Recruit four militia each: the engagement below spends the attacker's four
## troops while the declared offline cap keeps the loss at three, so one soldier
## survives in `units.json`. The defenders' cash absorbs the whole loss.
const PEOPLE: int = 4
const LOSS_CAP: int = 3
const SUPPLIES_TO_BUY: int = 8
## The merchant ask is one coin above the catalog reference price.
const GREENS_PRICE: int = 7

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
var _conflict_pending: Dictionary = {}
var _participation_pending: Dictionary = {}
var _unit_pending: Dictionary = {}
var _command_pending: Dictionary = {}
## The declaration body the host publishes. The restart replays the engagement,
## not the declaration, so this only needs to outlive the declaration step.
var _declaration: Dictionary = {}
var _effective_utc: float = 0.0


## A session that completes the invite handshake but never sends `join`, so the
## authority has no roster entry for it and must drop its conflict RPC silently.
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
		".local/verification/conflict-network-%d" % Time.get_ticks_usec())
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

	await _prepare_roster(codes)
	await _test_peace_declaration_and_consents(codes)
	await _test_engagement(codes)
	await _test_visitor(codes)
	await _test_anonymous(codes)
	await _test_unjoined(codes)
	await _test_restart(codes)
	_finish()


# ------------------------------------------------------------- roster fixture

## Buy supplies through the real rule merchant, then recruit through channels
## 13/14. The merchant quote restocks a few units at a time, so wait until the
## buyer's bag actually holds the goods before recruiting.
func _prepare_roster(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host joins as a named member over WSS")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.MEMBER,
		"The join reply confers the member role")
	var account: Dictionary = await _submit(FarmCommand.make_account_open(
		A_OPEN, client.world_time()))
	_expect(bool(account.get("ok", false)),
		"The host opens a real economy account through the authority")
	_expect(_cash(_farm_doc(), PLAYER_A) == Economy.OPENING_GRANT,
		"The opening grant is the host's real cash (120)")

	var merchant: Dictionary = await _submit(FarmCommand.make_market_open(
		MERCHANT_OPEN, client.world_time()))
	_expect(bool(merchant.get("ok", false)),
		"The host opens the rule merchant through the authority")
	await _buy_supplies(A_BUY)
	_expect(_supplies(_farm_doc(), PLAYER_A) >= SUPPLIES_TO_BUY,
		"The host's bought greens become real supplies in farm.json")

	var recruited: Dictionary = await _unit(A_UNIT, "recruit", {
		"kind": "militia", "people": PEOPLE, "equipment": "none",
		"station": "farm_a", "command_id": A_UNIT,
	})
	_expect(bool(recruited.get("ok", false)) and not bool(recruited.get("duplicate", true)),
		"The host recruits a real militia unit over channels 13/14")
	await _close_client()

	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The second named member joins over WSS")
	if client == null or not client.joined:
		return
	var b_account: Dictionary = await _submit(FarmCommand.make_account_open(
		B_OPEN, client.world_time()))
	_expect(bool(b_account.get("ok", false)),
		"The second member opens a real economy account")
	await _buy_supplies(B_BUY)
	_expect(_supplies(_farm_doc(), PLAYER_B) >= SUPPLIES_TO_BUY,
		"The second member's bought greens become real supplies")
	var b_recruited: Dictionary = await _unit(B_UNIT, "recruit", {
		"kind": "militia", "people": PEOPLE, "equipment": "none",
		"station": "farm_a", "command_id": B_UNIT,
	})
	_expect(bool(b_recruited.get("ok", false))
			and not bool(b_recruited.get("duplicate", true)),
		"The second member recruits a real militia unit")
	_expect(_unit_people(A_UNIT) == PEOPLE and _unit_people(B_UNIT) == PEOPLE,
		"The authoritative units.json carries both four-person units")
	await _close_client()


func _buy_supplies(command_id: String) -> void:
	var now: float = client.world_time()
	var placed: Dictionary = await _submit(FarmCommand.make_market_place(
		command_id, "buy", "greens", GREENS_PRICE, SUPPLIES_TO_BUY,
		now + 3600.0, now))
	_expect(bool(placed.get("ok", false)),
		"The member places a real buy order for greens (%s)"
			% str(placed.get("reason", "")))
	var owner: String = str(client.player_id)
	var purchased: bool = await _wait(func() -> bool:
		return _supplies(_farm_doc(), owner) >= SUPPLIES_TO_BUY, 20000)
	_expect(purchased,
		"The authority's economy sweep delivers the merchant stock to the bag")
	# The sweep that filled the order broadcasts a summary; give that reply a
	# moment so the next command carries the current sequence.
	await create_timer(0.4).timeout


# ------------------------------------------------- peace, declaration, consent

func _test_peace_declaration_and_consents(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host rejoins for the peace probe")
	if client == null or not client.joined:
		return
	var farm_before: PackedByteArray = _bytes(world_dir.path_join("farm.json"))
	var units_before: PackedByteArray = _bytes(world_dir.path_join("units.json"))
	var peace: Dictionary = await _conflict("conflict-net-peace", "engage",
		_battle_args(BATTLE_ID))
	_expect(not bool(peace.get("ok", true))
			and str(peace.get("reason", "")) == "peace",
		"The default peace regime refuses a real engagement")
	_expect(not str(peace.get("reason_text", "")).is_empty(),
		"The peace refusal carries a human-readable reason")
	_expect(_bytes(world_dir.path_join("farm.json")) == farm_before
			and _bytes(world_dir.path_join("units.json")) == units_before,
		"A peace refusal changes no farm or unit byte")
	_expect(not FileAccess.file_exists(world_dir.path_join(ConflictStore.MAIN)),
		"A peace refusal creates no conflicts.json")

	# The declaration is built from the authority's own clock; the effective
	# instant sits just ahead of it so the engagement below is in force.
	var now: float = await _authority_now()
	_expect(now > 0.0, "The participation view carries the authority clock")
	_declaration = _declaration_doc(now)
	_effective_utc = float(_declaration.effective_utc)
	var declared: Dictionary = await _participation(REGIME_ID, "regime", {
		"declaration": _declaration, "command_id": REGIME_ID,
	})
	_expect(bool(declared.get("ok", false)) and not bool(declared.get("duplicate", true)),
		"The host declares the limited regime over channel 17")
	var regime: Dictionary = _regime(_state(declared))
	_expect(str(regime.get("tier", "")) == Participation.TIER_LIMITED
			and int(regime.get("revision", -1)) == 1,
		"The live regime is limited at revision 1")
	_expect(str(regime.get("declared_by", "")) == PLAYER_A
			and str(regime.get("declaration_id", "")) == DECLARATION_ID,
		"The live regime records the host and the declaration id")

	var consented: Dictionary = await _participation(A_CONSENT_ID, "declare", {
		"role": Participation.ROLE_ATTACKER, "command_id": A_CONSENT_ID,
	})
	_expect(bool(consented.get("ok", false)) and not bool(consented.get("duplicate", true)),
		"The host consents as attacker over channel 17")
	var host_row: Dictionary = _participant(_state(consented), PLAYER_A)
	_expect(bool(host_row.get("attacker", false))
			and int(host_row.get("consent_revision", -1)) == 1,
		"The host's consent is bound to revision 1")

	# The regime cannot take effect before its declared instant; wait on the
	# authority clock instead of racing it.
	var live: bool = false
	var live_deadline: int = Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < live_deadline:
		if await _authority_now() >= _effective_utc:
			live = true
			break
		await create_timer(0.25).timeout
	_expect(live, "The declared regime becomes effective on the authority clock")

	var farm_after_decl: PackedByteArray = _bytes(world_dir.path_join("farm.json"))
	var units_after_decl: PackedByteArray = _bytes(world_dir.path_join("units.json"))
	var no_consent: Dictionary = await _conflict("conflict-net-no-consent", "engage",
		_battle_args(BATTLE_ID))
	_expect(not bool(no_consent.get("ok", true))
			and str(no_consent.get("reason", "")) == "no_consent",
		"A target that never consented is refused as no_consent")
	_expect(not str(no_consent.get("reason_text", "")).is_empty(),
		"The no-consent refusal carries a human-readable reason")
	_expect(_bytes(world_dir.path_join("farm.json")) == farm_after_decl
			and _bytes(world_dir.path_join("units.json")) == units_after_decl,
		"A no-consent refusal changes no farm or unit byte")
	_expect(not FileAccess.file_exists(world_dir.path_join(ConflictStore.MAIN)),
		"A no-consent refusal creates no conflicts.json")
	await _close_client()

	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The second member rejoins to consent")
	if client == null or not client.joined:
		return
	var defender_consent: Dictionary = await _participation(B_CONSENT_ID, "declare", {
		"role": Participation.ROLE_DEFENDER, "command_id": B_CONSENT_ID,
	})
	_expect(bool(defender_consent.get("ok", false))
			and not bool(defender_consent.get("duplicate", true)),
		"The second member consents as defender over channel 17")
	var defender_row: Dictionary = _participant(_state(defender_consent), PLAYER_B)
	_expect(bool(defender_row.get("defender", false))
			and int(defender_row.get("consent_revision", -1)) == 1,
		"The defender's consent is bound to revision 1")
	await _close_client()


# ---------------------------------------------------------------- engagement

func _test_engagement(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host rejoins to engage")
	if client == null or not client.joined:
		return
	var args: Dictionary = _battle_args(BATTLE_ID)
	var farm_before: Dictionary = _farm_doc()
	var a_cash_before: int = _cash(farm_before, PLAYER_A)
	var b_cash_before: int = _cash(farm_before, PLAYER_B)
	var a_supplies_before: int = _supplies(farm_before, PLAYER_A)
	var b_supplies_before: int = _supplies(farm_before, PLAYER_B)
	_expect(a_cash_before > 0 and b_cash_before > 0
			and a_supplies_before >= PEOPLE and b_supplies_before > 0,
		"The roster fixture leaves both members real cash and supplies")

	var engaged: Dictionary = await _conflict(BATTLE_ID, "engage", args)
	_expect(bool(engaged.get("ok", false)) and not bool(engaged.get("duplicate", true)),
		"The consented engagement is settled over channels 19/20 (%s)"
			% str(engaged.get("reason", "")))
	_expect(str(engaged.get("action", "")) == "engage",
		"The engagement reply names the action")
	var view: Dictionary = _state(engaged)
	_expect(_target_lost(view, PLAYER_B) == LOSS_CAP,
		"The reply view accumulates the target loss (got %d)"
			% _target_lost(view, PLAYER_B))
	var recent: Array = view.get("recent", []) if view.get("recent") is Array else []
	_expect(recent.size() == 1
			and str((recent[0] as Dictionary).get("command_id", "")) == BATTLE_ID,
		"The reply view carries the settled command in its recent results")

	var farm_after: Dictionary = _farm_doc()
	_expect(_cash(farm_after, PLAYER_A) == a_cash_before + 1,
		"The attacker receives the cash spoils from the defender")
	_expect(_cash(farm_after, PLAYER_B) == b_cash_before - LOSS_CAP,
		"The defender loses exactly the settled cash amount")
	_expect(_supplies(farm_after, PLAYER_A) == a_supplies_before - PEOPLE,
		"The attacker pays one supply per troop in farm.json")
	_expect(_supplies(farm_after, PLAYER_B) == b_supplies_before,
		"Cash-covered losses leave the defender's supplies untouched")
	_expect(_unit_people(A_UNIT) == PEOPLE - LOSS_CAP,
		"The attacker unit loses people in units.json")
	_expect(_unit_people(B_UNIT) == PEOPLE,
		"The defender unit is not reduced by the settlement")
	_expect(FileAccess.file_exists(world_dir.path_join(ConflictStore.MAIN)),
		"The settled engagement writes conflicts.json")

	var stored_target: int = _stored_target_lost(PLAYER_B)
	_expect(stored_target == LOSS_CAP,
		"conflicts.json stores the target budget loss (got %d)" % stored_target)
	var applied: Dictionary = _applied_row(BATTLE_ID)
	_expect(bool(applied.get("applied", false)),
		"conflicts.json records the command as fully applied")

	var farm_bytes: PackedByteArray = _bytes(world_dir.path_join("farm.json"))
	var units_bytes: PackedByteArray = _bytes(world_dir.path_join("units.json"))
	var participation_bytes: PackedByteArray = _bytes(
		world_dir.path_join("participation.json"))
	var conflict_bytes: PackedByteArray = _bytes(
		world_dir.path_join(ConflictStore.MAIN))

	var replay: Dictionary = await _conflict(BATTLE_ID, "engage", args)
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the same engagement command id returns duplicate")
	_expect(_bytes(world_dir.path_join("farm.json")) == farm_bytes
			and _bytes(world_dir.path_join("units.json")) == units_bytes
			and _bytes(world_dir.path_join("participation.json")) == participation_bytes
			and _bytes(world_dir.path_join(ConflictStore.MAIN)) == conflict_bytes,
		"A duplicate replay leaves the four documents byte-identical")
	_expect(_cash(_farm_doc(), PLAYER_A) == a_cash_before + 1
			and _cash(_farm_doc(), PLAYER_B) == b_cash_before - LOSS_CAP,
		"A duplicate replay pays and takes nothing twice")

	var moved: Dictionary = _battle_args(BATTLE_ID)
	moved["x"] = 3
	var conflict: Dictionary = await _conflict(BATTLE_ID, "engage", moved)
	_expect(not bool(conflict.get("ok", true))
			and str(conflict.get("reason", "")) == "command_conflict",
		"Reusing the engagement command id for another position conflicts")
	_expect(_bytes(world_dir.path_join("farm.json")) == farm_bytes
			and _bytes(world_dir.path_join("units.json")) == units_bytes
			and _bytes(world_dir.path_join("participation.json")) == participation_bytes
			and _bytes(world_dir.path_join(ConflictStore.MAIN)) == conflict_bytes,
		"A command conflict leaves the four documents byte-identical")

	# The request side of the 48 KiB wire budget: the host answers a visible
	# refusal instead of dropping the oversized RPC.
	_conflict_pending.erase("")
	var huge: String = JSON.stringify({
		"request_id": "conflict-net-huge", "action": "state",
		"args": {"padding": "x".repeat(OVER_BUDGET_BYTES)},
	})
	_expect(huge.to_utf8_buffer().size() > 48 * 1024,
		"The oversized conflict request really exceeds the wire budget")
	client.member.conflict_request.rpc_id(1, huge)
	var over_budget: Dictionary = await _conflict_key("", 15000)
	_expect(str(over_budget.get("reason", "")) == "payload_too_large",
		"An over-budget conflict request gets a named refusal")
	var alive: Dictionary = await _conflict("conflict-net-state-after-huge", "state")
	_expect(bool(alive.get("ok", false))
			and _target_lost(_state(alive), PLAYER_B) == LOSS_CAP,
		"The connection keeps working after the over-budget refusal")


# ----------------------------------------------------------- permission paths

func _test_visitor(codes: Dictionary) -> void:
	await _close_client()
	_expect(await _open_client(str(codes.get("visitor", "")), VISITOR_ID, VISITOR_NAME,
		PLAYER_SECRET_A), "A named visitor joins with the visitor code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")
	var view: Dictionary = await _conflict("conflict-net-visitor-state", "state")
	_expect(bool(view.get("ok", false)),
		"A visitor may read the conflict view")
	_expect(_target_lost(_state(view), PLAYER_B) == LOSS_CAP,
		"The visitor sees the authoritative target budget")
	var refused: Dictionary = await _conflict("conflict-net-visitor-engage", "engage",
		_battle_args("conflict-net-visitor-battle"))
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "forbidden",
		"A visitor's engagement is refused as forbidden")
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The visitor refusal carries a human-readable reason")
	var after: Dictionary = await _conflict("conflict-net-visitor-state-2", "state")
	_expect(bool(after.get("ok", false))
			and _target_lost(_state(after), PLAYER_B) == LOSS_CAP,
		"The visitor stays connected and can still read after a refused write")


func _test_anonymous(codes: Dictionary) -> void:
	await _close_client()
	_expect(await _open_client(str(codes.get("member", "")), "", "", ""),
		"An anonymous connection joins")
	if client == null or not client.joined:
		return
	var view: Dictionary = await _conflict("conflict-net-anonymous-state", "state")
	_expect(bool(view.get("ok", false)),
		"An anonymous member may read the conflict view")
	var refused: Dictionary = await _conflict("conflict-net-anonymous-engage", "engage",
		_battle_args("conflict-net-anonymous-battle"))
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "no_player",
		"An anonymous engagement is refused for lack of a player identity")
	var after: Dictionary = await _conflict("conflict-net-anonymous-state-2", "state")
	_expect(bool(after.get("ok", false)),
		"The anonymous member stays connected after a refusal")
	await _close_client()


## A connection that authenticated but never joined is not in the roster. The
## server drops its conflict RPC without an answer.
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
	session.conflict_result.connect(func(request_id: String, payload: Dictionary) -> void:
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
	# Give the challenge/response a moment before sending the unauthenticated
	# RPC; the probe must not join on its own.
	await create_timer(0.8).timeout
	_expect(not session.is_joined(), "The probe never joins the world")
	session.conflict_request.rpc_id(1, JSON.stringify({
		"request_id": "conflict-net-unjoined", "action": "engage",
		"args": _battle_args("conflict-net-unjoined-battle"),
	}))
	var replied: bool = await _wait(func() -> bool: return not replies.is_empty(), 1500)
	_expect(not replied,
		"An unjoined connection's engagement gets no authority reply")
	_expect(losses.is_empty(),
		"The unjoined connection stayed authenticated and was not refused")
	await _close_unjoined(peer, session)


# -------------------------------------------------------------------- restart

func _test_restart(codes: Dictionary) -> void:
	var farm_bytes: PackedByteArray = _bytes(world_dir.path_join("farm.json"))
	var units_bytes: PackedByteArray = _bytes(world_dir.path_join("units.json"))
	var participation_bytes: PackedByteArray = _bytes(
		world_dir.path_join("participation.json"))
	var conflict_bytes: PackedByteArray = _bytes(
		world_dir.path_join(ConflictStore.MAIN))
	_expect(not conflict_bytes.is_empty(),
		"The settled conflict document is persisted before the restart")

	await _stop_server()
	if not await _start_authority("loaded"):
		_finish()
		return
	codes = _join_codes()
	_expect(not str(codes.get("member", "")).is_empty(),
		"The restarted authority publishes a usable member code")
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host rejoins the restarted authority")
	if client == null or not client.joined:
		return

	var view: Dictionary = await _conflict("conflict-net-restart-state", "state")
	_expect(bool(view.get("ok", false)),
		"The restarted authority answers a conflict state request")
	_expect(_target_lost(_state(view), PLAYER_B) == LOSS_CAP,
		"The target budget survives the restart")
	var recent: Array = _state(view).get("recent", []) \
		if _state(view).get("recent") is Array else []
	_expect(recent.size() == 1
			and str((recent[0] as Dictionary).get("command_id", "")) == BATTLE_ID,
		"The settled engagement survives the restart")
	_expect(FileAccess.file_exists(world_dir.path_join(ConflictStore.MAIN)),
		"conflicts.json still exists after the restart")
	_expect(_unit_people(A_UNIT) == PEOPLE - LOSS_CAP,
		"The reduced unit roster survives the restart")

	var replay: Dictionary = await _conflict(BATTLE_ID, "engage", _battle_args(BATTLE_ID))
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the engagement after the restart still returns duplicate")
	_expect(_bytes(world_dir.path_join("farm.json")) == farm_bytes
			and _bytes(world_dir.path_join("units.json")) == units_bytes
			and _bytes(world_dir.path_join("participation.json")) == participation_bytes
			and _bytes(world_dir.path_join(ConflictStore.MAIN)) == conflict_bytes,
		"The restart replay pays nothing twice and rewrites no document")

	await _close_client()
	await _stop_server()


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
	_expect(str(status.get("host_player", "")) == PLAYER_A,
		"The status file records the startup host player")
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
	_conflict_pending.clear()
	_participation_pending.clear()
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
	client.conflict_result.connect(_on_conflict_result)
	client.participation_result.connect(_on_participation_result)
	client.unit_result.connect(_on_unit_result)
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
	_conflict_pending.clear()
	_participation_pending.clear()
	_unit_pending.clear()
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


func _on_conflict_result(request_id: String, payload: Dictionary) -> void:
	_conflict_pending[request_id] = payload


func _on_participation_result(request_id: String, payload: Dictionary) -> void:
	_participation_pending[request_id] = payload


func _on_unit_result(request_id: String, payload: Dictionary) -> void:
	_unit_pending[request_id] = payload


func _on_committed(request_id: String, payload: Dictionary) -> void:
	_command_pending[request_id] = payload


func _conflict(request_id: String, action: String, args: Dictionary = {}) -> Dictionary:
	_conflict_pending.erase(request_id)
	if client == null or not client.request_conflict(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	return await _conflict_key(request_id, 15000)


func _conflict_key(request_id: String, timeout_ms: int) -> Dictionary:
	var arrived: bool = await _wait(func() -> bool:
		return _conflict_pending.has(request_id), timeout_ms)
	if not arrived:
		_expect(false, "A conflict reply arrives for request %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _conflict_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


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


func _unit(request_id: String, action: String, args: Dictionary = {}) -> Dictionary:
	_unit_pending.erase(request_id)
	if client == null or not client.request_unit(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	var arrived: bool = await _wait(func() -> bool:
		return _unit_pending.has(request_id), 15000)
	if not arrived:
		_expect(false, "A unit reply arrives for request %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _unit_pending.get(request_id, {})
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


# ------------------------------------------------------------------ fixtures

func _declaration_doc(now: float) -> Dictionary:
	return {
		"tier": Participation.TIER_LIMITED,
		"declaration_id": DECLARATION_ID,
		"effective_utc": now + 1.0,
		"higher_risk": true,
		"areas": [{"id": "yard", "min_x": 0, "min_z": 0, "max_x": 10, "max_z": 10}],
		"windows": [{"id": "night", "start_utc": now - 60.0,
			"end_utc": now + 86400.0}],
		"loss_cap": LOSS_CAP,
		"offline_loss_cap": LOSS_CAP,
	}


func _battle_args(command_id: String) -> Dictionary:
	return {
		"command_id": command_id,
		"defender": PLAYER_B,
		"attacker_units": [A_UNIT],
		"defender_units": [B_UNIT],
		"x": 2, "z": 2,
	}


func _state(reply: Dictionary) -> Dictionary:
	var value: Variant = reply.get("state")
	return value if value is Dictionary else {}


func _regime(state: Dictionary) -> Dictionary:
	var value: Variant = state.get("regime")
	return value if value is Dictionary else {}


func _participant(state: Dictionary, player_id: String) -> Dictionary:
	var rows: Variant = state.get("participants")
	if not rows is Array:
		return {}
	for value: Variant in rows:
		if value is Dictionary \
				and str((value as Dictionary).get("participant", "")) == player_id:
			return value
	return {}


## The server's own clock, as carried by the participation view.
func _authority_now() -> float:
	var reply: Dictionary = await _participation(
		"conflict-net-clock-%d" % Time.get_ticks_usec(), "state")
	return float(_state(reply).get("now_utc", 0.0))


# ------------------------------------------------------------- state readers

func _farm_doc() -> Dictionary:
	var saved: Dictionary = _read_json(world_dir.path_join("farm.json"))
	var farm: Variant = saved.get("farm")
	return farm if farm is Dictionary else {}


func _units_doc() -> Dictionary:
	var saved: Dictionary = _read_json(world_dir.path_join("units.json"))
	var state: Variant = saved.get("state")
	return state if state is Dictionary else {}


func _unit_people(unit_id: String) -> int:
	var rows_value: Variant = _units_doc().get("units")
	if not rows_value is Dictionary:
		return 0
	var row_value: Variant = (rows_value as Dictionary).get(unit_id)
	if not row_value is Dictionary:
		return 0
	return int((row_value as Dictionary).get("people", 0))


func _conflicts_doc() -> Dictionary:
	return _read_json(world_dir.path_join(ConflictStore.MAIN))


func _stored_target_lost(target: String) -> int:
	var state_value: Variant = _conflicts_doc().get("state")
	if not state_value is Dictionary:
		return -1
	var targets_value: Variant = (state_value as Dictionary).get("targets")
	if not targets_value is Dictionary:
		return -1
	var total: int = 0
	for key: Variant in (targets_value as Dictionary):
		var row_value: Variant = (targets_value as Dictionary)[key]
		if row_value is Dictionary \
				and str((row_value as Dictionary).get("target", "")) == target:
			total += int((row_value as Dictionary).get("lost", 0))
	return total


func _applied_row(command_id: String) -> Dictionary:
	var applied_value: Variant = _conflicts_doc().get("applied")
	if not applied_value is Dictionary:
		return {}
	var row_value: Variant = (applied_value as Dictionary).get(command_id)
	return row_value if row_value is Dictionary else {}


func _target_lost(view: Dictionary, target: String) -> int:
	var rows: Variant = view.get("targets", [])
	if not rows is Array:
		return -1
	for value: Variant in rows:
		if value is Dictionary \
				and str((value as Dictionary).get("target", "")) == target:
			return int((value as Dictionary).get("lost", 0))
	return -1


func _cash(farm: Dictionary, owner: String) -> int:
	var economy: Variant = farm.get("economy")
	if not economy is Dictionary:
		return -1
	var accounts: Variant = (economy as Dictionary).get("accounts")
	if not accounts is Dictionary:
		return -1
	var account: Variant = (accounts as Dictionary).get(owner)
	return int((account as Dictionary).get("cash", -1)) if account is Dictionary else 0


func _supplies(farm: Dictionary, owner: String) -> int:
	var bags: Variant = farm.get("bags")
	if not bags is Dictionary:
		return 0
	var pocket: Variant = (bags as Dictionary).get(owner)
	if not pocket is Dictionary:
		return 0
	var total: int = 0
	for good_id: String in EconomyCatalog.goods_ids():
		total += int((pocket as Dictionary).get(good_id, 0))
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
	var status: Dictionary = _status()
	_expect(str(status.get("state", "")) == "stopped",
		"The shutdown is recorded in the status file")
	_expect(str(status.get("save", "")) == "saved",
		"The status file records the saved stop outcome")
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
	print("CONFLICT_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
