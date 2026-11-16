extends SceneTree
## G17 over the real wire: the authority derives `defender_online` from the
## connection table, so the participation cap must switch between the online cap
## and the smaller offline cap as the defender disconnects and reconnects.
##
## A real `world_server.gd` process serves a fresh world over loopback WSS. The
## parent process is the attacker (PLAYER_A, the room host). The defender
## (PLAYER_B) runs in child processes of this same script because one SceneTree
## owns one SceneMultiplayer peer. Child reports and control markers live under
## the same verification directory; the parent polls a report until its JSON
## parses, never trusting mere file existence.
##
## Scenario:
##   - A opens a real account, opens the merchant, buys fourteen greens, recruits
##     a four-person unit; B opens an account, buys one green, recruits a
##     one-person unit, then consents as defender while connected;
##   - the host declares one regime with an online cap of 3, an offline cap of 2
##     and two non-overlapping windows;
##   - window 1, defender online: the four-troop engagement is clamped by the
##     online cap (loss 3) and the reply records `defender_online=true`;
##   - B's child exits; the parent waits for the authoritative roster to drop
##     PLAYER_B, then recruits a second unit;
##   - the same target is engaged again in window 2 while B is offline: the same
##     cumulative ledger now takes only the offline cap (loss 2), the reply
##     records `defender_online=false`, and both the sidecar participation row
##     (`cap=2`) and the conflicts outcome agree;
##   - a third offline attempt on the same target and window is refused by name
##     (`target_cap`) with a human-readable reason while every durable document
##     stays byte-identical;
##   - a second B child reconnects: its summary restores the authoritative cash,
##     clock and target budget, and its conflict view still shows the durable
##     offline outcome (`defender_online=false`);
##   - after the reconnect the same target accepts an online settlement again
##     (the remaining online cap admits loss 1), and the reconnected client's
##     refreshed view shows `defender_online=true`;
##   - replaying the offline-issued command id after the reconnect still returns
##     `duplicate` and rewrites no document, so the cap switch never pays twice.
##
## Everything runs under .local/verification/conflict-offline-cap-<ticks>/.

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Economy = preload("res://farm/economy_state.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")
const Participation = preload("res://conflict/participation_state.gd")
const ConflictStore = preload("res://world/conflict_store.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const TEST_SCRIPT: String = "tests/conflict_offline_cap_network_test.gd"
## One installation credential per identity: the authority binds the first proof
## it sees, and the reconnecting child must present the same one.
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const START: float = 1800000000.0
const WORLD: String = "world-conflict-offline-cap"
const PLAYER_A: String = "player_00000000000000000000000000000091"
const PLAYER_B: String = "player_00000000000000000000000000000092"
const NAME_A: String = "阿武"
const NAME_B: String = "阿守"

const ROLE_DEFENDER: String = "defender"
const ROLE_RECONNECT: String = "reconnect"

const DECLARATION_ID: String = "offline-cap-decl"
const REGIME_ID: String = "offline-cap-regime"
const A_CONSENT_ID: String = "offline-cap-a-consent"
const B_CONSENT_ID: String = "offline-cap-b-consent"
const A_OPEN: String = "offline-cap-a-open"
const B_OPEN: String = "offline-cap-b-open"
const MERCHANT_OPEN: String = "offline-cap-merchant"
const A_BUY: String = "offline-cap-a-buy"
const B_BUY: String = "offline-cap-b-buy"
const A_UNIT1: String = "offline-cap-unit-a1"
const A_UNIT2: String = "offline-cap-unit-a2"
const B_UNIT: String = "offline-cap-unit-b1"
const E1_ID: String = "offline-cap-e1"
const E2_ID: String = "offline-cap-e2"
const E3_ID: String = "offline-cap-e3"
const E4_ID: String = "offline-cap-e4"
const WINDOW_ONLINE: String = "online-window"
const WINDOW_OFFLINE: String = "offline-window"
const AREA_ID: String = "yard"

## The online cap admits 3, the offline cap only 2. Both settlements below bring
## more troops than their cap, so the cap (not the troop count, the target budget
## or the defender's wallet) is what clamps the loss.
const LOSS_CAP: int = 3
const OFFLINE_CAP: int = 2
const PEOPLE1: int = 4
const PEOPLE2: int = 2
const B_PEOPLE: int = 1
const A_GREENS: int = 14
const B_GREENS: int = 1
const GREENS_PRICE: int = 7
## The per-target, per-parcel budget the authority ships.
const TARGET_LOSS_CAP: int = 100

const B1_READY: String = "defender-ready.json"
const B1_CONSENTED: String = "defender-consented.json"
const B1_CONSENT: String = "defender-consent.go"
const B1_STOP: String = "defender-stop.go"
const B2_VIEW: String = "reconnect-view.json"
const B2_ONLINE: String = "reconnect-online.json"
const B2_REFRESH: String = "reconnect-refresh.go"
const B2_STOP: String = "reconnect-stop.go"

## Child-process role arguments.
var role: String = ""
var code_file: String = ""
var report1_path: String = ""
var report2_path: String = ""
var marker_path: String = ""
var stop_path: String = ""

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var url: String = ""
var log_path: String = ""
var checks: int = 0
var failures: Array[String] = []
var client: WorldClient
var _ready: bool = false
var _refusals: Array[String] = []
var _conflict_pending: Dictionary = {}
var _participation_pending: Dictionary = {}
var _unit_pending: Dictionary = {}
var _command_pending: Dictionary = {}
var _state_count: int = 0
var _last_farm: RefCounted = null
var _last_now_utc: float = 0.0

var _declaration: Dictionary = {}
var _effective_utc: float = 0.0
var _w1_end: float = 0.0
var _w2_start: float = 0.0
var _b1: Dictionary = {}
var _b2: Dictionary = {}


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--dir="): dir = argument.trim_prefix("--dir=")
		elif argument.begins_with("--world-dir="): world_dir = argument.trim_prefix("--world-dir=")
		elif argument.begins_with("--code-file="): code_file = argument.trim_prefix("--code-file=")
		elif argument.begins_with("--report="): report1_path = argument.trim_prefix("--report=")
		elif argument.begins_with("--report2="): report2_path = argument.trim_prefix("--report2=")
		elif argument.begins_with("--marker="): marker_path = argument.trim_prefix("--marker=")
		elif argument.begins_with("--stop="): stop_path = argument.trim_prefix("--stop=")
	if role.is_empty():
		_run.call_deferred()
	else:
		_run_child.call_deferred()


# ------------------------------------------------------------------- parent

func _run() -> void:
	dir = _repo().path_join(
		".local/verification/conflict-offline-cap-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	await _scenario()
	await _cleanup()
	_finish()


func _scenario() -> void:
	if not await _start_authority():
		return
	var member_code: String = _member_code()
	_expect(not member_code.is_empty(),
		"The member join code is built from the operator's material")
	if member_code.is_empty():
		return
	code_file = dir.path_join("join-code.txt")
	_write_text(code_file, member_code)

	await _prepare_attacker(member_code)
	if client == null or not client.joined:
		return

	if not await _start_defender(member_code):
		return
	if not await _declare_regime():
		return
	if not await _first_online_settlement():
		return

	await _take_defender_offline()
	await _recruit_second_attacker_unit()
	if not await _wait_clock(_w2_start, 40000):
		_expect(false, "The authority clock reaches the offline window")
		return
	await _second_offline_settlement()
	await _refuse_saturated_offline_attempt()

	if not await _start_reconnect(member_code):
		return
	if not await _reconnected_online_settlement():
		return
	await _replay_offline_command()


# ------------------------------------------------------------- attacker setup

func _prepare_attacker(member_code: String) -> void:
	_expect(await _open_client(member_code, PLAYER_A, NAME_A, PLAYER_SECRET_A),
		"The host joins as a named member over WSS")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.MEMBER,
		"The join reply confers the member role")
	var account: Dictionary = await _submit(FarmCommand.make_account_open(
		A_OPEN, client.world_time()))
	_expect(bool(account.get("ok", false)),
		"The host opens a real economy account")
	var merchant: Dictionary = await _submit(FarmCommand.make_market_open(
		MERCHANT_OPEN, client.world_time()))
	_expect(bool(merchant.get("ok", false)),
		"The host opens the rule merchant")
	await _buy_greens(A_BUY, A_GREENS)

	var recruited: Dictionary = await _unit(A_UNIT1, "recruit", {
		"kind": "militia", "people": PEOPLE1, "equipment": "none",
		"station": "farm_a", "command_id": A_UNIT1,
	})
	_expect(bool(recruited.get("ok", false))
			and not bool(recruited.get("duplicate", true)),
		"The host recruits the four-person militia over channels 13/14")
	_expect(_unit_people(A_UNIT1) == PEOPLE1,
		"The authoritative roster carries the four-person unit")
	var farm: Dictionary = _farm_doc()
	_expect(_cash(farm, PLAYER_A) == Economy.OPENING_GRANT - A_GREENS * GREENS_PRICE
			- PEOPLE1 * 2,
		"The host's cash after the purchase and recruit is authoritative")
	_expect(_supplies(farm, PLAYER_A) == A_GREENS - PEOPLE1,
		"The host's supplies after the recruit are authoritative")


func _buy_greens(command_id: String, quantity: int) -> void:
	var now: float = client.world_time()
	var placed: Dictionary = await _submit(FarmCommand.make_market_place(
		command_id, "buy", "greens", GREENS_PRICE, quantity, now + 3600.0, now))
	_expect(bool(placed.get("ok", false)),
		"A buy order for greens is accepted (%s)" % str(placed.get("reason", "")))
	var owner: String = str(client.player_id)
	var purchased: bool = await _wait(func() -> bool:
		return _supplies(_farm_doc(), owner) >= quantity, 30000)
	_expect(purchased, "The economy sweep delivers the merchant stock")
	await create_timer(0.4).timeout


# -------------------------------------------------------------- defender live

func _start_defender(member_code: String) -> bool:
	_b1 = {
		"ready": dir.path_join(B1_READY),
		"consented": dir.path_join(B1_CONSENTED),
		"consent": dir.path_join(B1_CONSENT),
		"stop": dir.path_join(B1_STOP),
	}
	var pid: int = _spawn_child(ROLE_DEFENDER, [
		"--report=" + str(_b1.ready), "--report2=" + str(_b1.consented),
		"--marker=" + str(_b1.consent), "--stop=" + str(_b1.stop),
	])
	_b1["pid"] = pid
	_expect(pid > 0, "The defender child process starts")
	if pid <= 0:
		return false
	var ready: Dictionary = await _wait_child_report(str(_b1.ready), pid, 45000)
	_expect(bool(ready.get("ok", false)),
		"The defender child joins, opens an account, buys and recruits (%s)"
			% str(ready.get("step", "")))
	if not bool(ready.get("ok", false)):
		return false
	_expect(int(ready.get("cash", -1)) == Economy.OPENING_GRANT
			- B_GREENS * GREENS_PRICE - B_PEOPLE * 2,
		"The defender's restored summary carries its authoritative cash (111)")
	_expect(int(ready.get("supplies", -1)) == 0,
		"The defender's restored summary carries its spent supplies (0)")
	_expect(int(ready.get("unit_people", -1)) == B_PEOPLE,
		"The defender's one-person unit is durable")
	_expect(await _wait(func() -> bool: return _roster_has(PLAYER_B), 15000),
		"The online defender appears in the authoritative roster")
	return true


func _declare_regime() -> bool:
	var declared_now: float = await _authority_now()
	_expect(declared_now > 0.0, "The participation view carries the authority clock")
	if declared_now <= 0.0:
		return false
	_declaration = _declaration_doc(declared_now)
	_effective_utc = float(_declaration.effective_utc)
	_w1_end = float((_declaration.windows[0] as Dictionary).end_utc)
	_w2_start = float((_declaration.windows[1] as Dictionary).start_utc)
	var declared: Dictionary = await _participation(REGIME_ID, "regime", {
		"declaration": _declaration, "command_id": REGIME_ID,
	})
	_expect(bool(declared.get("ok", false))
			and not bool(declared.get("duplicate", true)),
		"The host declares the caps and the two windows over channel 17 (%s)"
			% str(declared.get("reason", "")))
	if not bool(declared.get("ok", false)):
		return false
	var regime: Dictionary = _regime(_state(declared))
	_expect(int(regime.get("loss_cap", -1)) == LOSS_CAP
			and int(regime.get("offline_loss_cap", -1)) == OFFLINE_CAP,
		"The live regime carries the online and offline caps (3/2)")

	var consented: Dictionary = await _participation(A_CONSENT_ID, "declare", {
		"role": Participation.ROLE_ATTACKER, "command_id": A_CONSENT_ID,
	})
	_expect(bool(consented.get("ok", false))
			and not bool(consented.get("duplicate", true)),
		"The host consents as attacker over channel 17")

	var live: bool = await _wait_clock(_effective_utc, 15000)
	_expect(live, "The declared regime becomes effective on the authority clock")
	if not live:
		return false
	_write_text(str(_b1.consent), "consent")
	var defender: Dictionary = await _wait_child_report(
		str(_b1.consented), int(_b1.pid), 30000)
	_expect(bool(defender.get("ok", false))
			and bool(defender.get("defender", false)),
		"The connected defender consents as defender over channel 17 (%s)"
			% str(defender.get("step", "")))
	if not bool(defender.get("ok", false)):
		return false
	_expect(int(defender.get("revision", -1)) == 1,
		"The defender's consent is bound to revision 1")
	var inside: bool = await _authority_now() < _w1_end
	_expect(inside, "The online settlement is still inside the online window")
	return inside


# ------------------------------------------------------- engagement 1 (online)

func _first_online_settlement() -> bool:
	var farm_before: Dictionary = _farm_doc()
	var a_cash: int = _cash(farm_before, PLAYER_A)
	var b_cash: int = _cash(farm_before, PLAYER_B)
	var a_supplies: int = _supplies(farm_before, PLAYER_A)
	var b_supplies: int = _supplies(farm_before, PLAYER_B)
	var engaged: Dictionary = await _conflict(E1_ID, "engage",
		_battle_args(E1_ID, [A_UNIT1]))
	_expect(bool(engaged.get("ok", false))
			and not bool(engaged.get("duplicate", true)),
		"The online engagement settles over channels 19/20 (%s)"
			% str(engaged.get("reason", "")))
	if not bool(engaged.get("ok", false)):
		return false
	var view: Dictionary = _state(engaged)
	var recent: Dictionary = _recent_row(view, E1_ID)
	_expect(not recent.is_empty(),
		"The online settlement appears in the reply view")
	_expect(bool(recent.get("defender_online", false)),
		"The reply records the defender as online")
	_expect(int(recent.get("troops", 0)) == PEOPLE1,
		"The online settlement committed all four troops")
	_expect(int(recent.get("losses", 0)) == LOSS_CAP,
		"The online cap clamps the loss at 3 (got %d)"
			% int(recent.get("losses", 0)))
	_expect(str(recent.get("window_id", "")) == WINDOW_ONLINE,
		"The online settlement lands in the online window")
	_expect(int(recent.get("target_lost_after", 0)) == LOSS_CAP,
		"The reply view accumulates the target loss (3)")
	_expect(int(recent.get("target_cap", 0)) == TARGET_LOSS_CAP,
		"The reply view names the target budget (100)")
	_expect(_target_lost(view, PLAYER_B) == LOSS_CAP,
		"The target row carries the online loss")

	var farm_after: Dictionary = _farm_doc()
	_expect(_cash(farm_after, PLAYER_A) == a_cash + 1,
		"The attacker receives one coin of cash spoils")
	_expect(_cash(farm_after, PLAYER_B) == b_cash - LOSS_CAP,
		"The defender loses exactly the online-capped cash")
	_expect(_supplies(farm_after, PLAYER_A) == a_supplies - PEOPLE1,
		"The attacker pays one supply per committed troop")
	_expect(_supplies(farm_after, PLAYER_B) == b_supplies,
		"Cash-covered losses leave the defender's supplies untouched")
	_expect(_unit_people(A_UNIT1) == PEOPLE1 - LOSS_CAP,
		"The attacker unit loses the online-capped people")
	_expect(_unit_people(B_UNIT) == B_PEOPLE,
		"The unarmed defender unit is not reduced by the settlement")

	var row: Dictionary = _engagement_row(E1_ID)
	_expect(int(row.get("cap", -1)) == LOSS_CAP
			and bool(row.get("defender_online", false))
			and int(row.get("amount", 0)) == LOSS_CAP,
		"participation.json stores the online cap and the settled amount")
	_expect(str(row.get("window_id", "")) == WINDOW_ONLINE
			and int(row.get("loss_total_after", 0)) == LOSS_CAP,
		"participation.json stores the online window total")
	var outcome: Dictionary = _conflict_outcome(E1_ID)
	_expect(bool(outcome.get("defender_online", false))
			and int(outcome.get("losses", 0)) == LOSS_CAP
			and int(outcome.get("participation_cap", -1)) == LOSS_CAP,
		"conflicts.json stores the online outcome and the participation cap")
	_expect(int(outcome.get("target_cap", -1)) == TARGET_LOSS_CAP
			and int(outcome.get("target_lost_after", 0)) == LOSS_CAP,
		"conflicts.json stores the shared target budget")
	_expect(bool(_applied_row(E1_ID).get("applied", false)),
		"conflicts.json records the online command as fully applied")
	return true


# ---------------------------------------------------- defender offline window

func _take_defender_offline() -> void:
	_write_text(str(_b1.stop), "stop")
	var pid: int = int(_b1.pid)
	var exited: bool = await _wait_process_gone(pid, 20000)
	_expect(exited, "The defender child exits on the stop marker")
	if not exited:
		OS.kill(pid)
		await _wait_process_gone(pid, 5000)
	_b1["pid"] = 0
	var removed: bool = await _wait(func() -> bool:
		return not _roster_has(PLAYER_B), 15000)
	_expect(removed,
		"The authority drops the offline defender from the roster")


func _recruit_second_attacker_unit() -> void:
	var recruited: Dictionary = await _unit(A_UNIT2, "recruit", {
		"kind": "militia", "people": PEOPLE2, "equipment": "none",
		"station": "farm_a", "command_id": A_UNIT2,
	})
	_expect(bool(recruited.get("ok", false))
			and not bool(recruited.get("duplicate", true)),
		"The host recruits a second two-person unit while the defender is offline")
	_expect(_unit_people(A_UNIT2) == PEOPLE2,
		"The second unit is durable before the offline engagement")


# ------------------------------------------------------ engagement 2 (offline)

func _second_offline_settlement() -> void:
	var farm_before: Dictionary = _farm_doc()
	var a_cash: int = _cash(farm_before, PLAYER_A)
	var b_cash: int = _cash(farm_before, PLAYER_B)
	var a_supplies: int = _supplies(farm_before, PLAYER_A)
	var b_supplies: int = _supplies(farm_before, PLAYER_B)
	var engaged: Dictionary = await _conflict(E2_ID, "engage",
		_battle_args(E2_ID, [A_UNIT1, A_UNIT2]))
	_expect(bool(engaged.get("ok", false))
			and not bool(engaged.get("duplicate", true)),
		"The offline engagement settles over channels 19/20 (%s)"
			% str(engaged.get("reason", "")))
	if not bool(engaged.get("ok", false)):
		return
	var view: Dictionary = _state(engaged)
	var recent: Dictionary = _recent_row(view, E2_ID)
	_expect(not recent.is_empty(),
		"The offline settlement appears in the reply view")
	_expect(not bool(recent.get("defender_online", true)),
		"The reply records the defender as offline")
	_expect(int(recent.get("troops", 0)) == (PEOPLE1 - LOSS_CAP) + PEOPLE2,
		"The offline settlement commits the surviving troops")
	_expect(int(recent.get("losses", 0)) == OFFLINE_CAP,
		"The offline cap clamps the loss at 2, below the 3 committed troops (got %d)"
			% int(recent.get("losses", 0)))
	_expect(str(recent.get("window_id", "")) == WINDOW_OFFLINE,
		"The offline settlement lands in the offline window")
	_expect(int(recent.get("target_lost_after", 0)) == LOSS_CAP + OFFLINE_CAP,
		"The same target budget accumulates the offline loss (5)")

	var farm_after: Dictionary = _farm_doc()
	_expect(_cash(farm_after, PLAYER_A) == a_cash + 1,
		"The attacker receives one coin of cash spoils from the offline hit")
	_expect(_cash(farm_after, PLAYER_B) == b_cash - OFFLINE_CAP,
		"The defender loses exactly the offline-capped cash")
	_expect(_supplies(farm_after, PLAYER_A) == a_supplies - 3,
		"The attacker pays one supply per committed troop")
	_expect(_supplies(farm_after, PLAYER_B) == b_supplies,
		"Cash-covered losses leave the defender's supplies untouched")
	_expect(_unit_people(A_UNIT1) == 0,
		"The first unit is destroyed by the offline settlement")
	_expect(_unit_people(A_UNIT2) == 1,
		"The second unit keeps the surviving trooper after the remainder")
	_expect(_target_lost(view, PLAYER_B) == LOSS_CAP + OFFLINE_CAP,
		"The target row carries the shared total (5)")

	var row: Dictionary = _engagement_row(E2_ID)
	_expect(int(row.get("cap", -1)) == OFFLINE_CAP
			and not bool(row.get("defender_online", true))
			and int(row.get("amount", 0)) == OFFLINE_CAP,
		"participation.json stores the offline cap and the settled amount")
	_expect(str(row.get("window_id", "")) == WINDOW_OFFLINE
			and int(row.get("loss_total_after", 0)) == OFFLINE_CAP,
		"participation.json keeps a separate offline window ledger")
	var outcome: Dictionary = _conflict_outcome(E2_ID)
	_expect(not bool(outcome.get("defender_online", true))
			and int(outcome.get("losses", 0)) == OFFLINE_CAP
			and int(outcome.get("participation_cap", -1)) == OFFLINE_CAP,
		"conflicts.json stores the offline outcome and the online/offline cap switch")
	_expect(int(outcome.get("target_lost_after", 0)) == LOSS_CAP + OFFLINE_CAP,
		"conflicts.json keeps the target budget shared across windows")


func _refuse_saturated_offline_attempt() -> void:
	var farm_bytes: PackedByteArray = _bytes(world_dir.path_join("farm.json"))
	var units_bytes: PackedByteArray = _bytes(world_dir.path_join("units.json"))
	var participation_bytes: PackedByteArray = _bytes(
		world_dir.path_join("participation.json"))
	var conflict_bytes: PackedByteArray = _bytes(
		world_dir.path_join(ConflictStore.MAIN))
	var refused: Dictionary = await _conflict(E3_ID, "engage",
		_battle_args(E3_ID, [A_UNIT2]))
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "target_cap",
		"The saturated offline window is refused by name (target_cap), got %s"
			% str(refused.get("reason", "")))
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The named refusal while the defender is offline carries a reason")
	_expect(_bytes(world_dir.path_join("farm.json")) == farm_bytes
			and _bytes(world_dir.path_join("units.json")) == units_bytes
			and _bytes(world_dir.path_join("participation.json")) == participation_bytes
			and _bytes(world_dir.path_join(ConflictStore.MAIN)) == conflict_bytes,
		"The offline refusal changes no farm, unit, participation or conflict byte")
	_expect(_engagement_row(E3_ID).is_empty(),
		"The offline refusal creates no durable engagement row")
	_expect(_target_lost(_state(refused), PLAYER_B) == LOSS_CAP + OFFLINE_CAP,
		"The offline refusal leaves the target budget at 5")


# ------------------------------------------------------------- defender back

func _start_reconnect(member_code: String) -> bool:
	_b2 = {
		"view": dir.path_join(B2_VIEW),
		"online": dir.path_join(B2_ONLINE),
		"refresh": dir.path_join(B2_REFRESH),
		"stop": dir.path_join(B2_STOP),
	}
	var pid: int = _spawn_child(ROLE_RECONNECT, [
		"--report=" + str(_b2.view), "--report2=" + str(_b2.online),
		"--marker=" + str(_b2.refresh), "--stop=" + str(_b2.stop),
	])
	_b2["pid"] = pid
	_expect(pid > 0, "The reconnecting defender child process starts")
	if pid <= 0:
		return false
	var view_report: Dictionary = await _wait_child_report(
		str(_b2.view), pid, 45000)
	_expect(bool(view_report.get("ok", false)),
		"The defender rejoins and restores its summary (%s)"
			% str(view_report.get("step", "")))
	if not bool(view_report.get("ok", false)):
		return false
	_expect(str(view_report.get("role", "")) == WorldInvite.MEMBER,
		"The reconnected connection holds the member role")
	_expect(int(view_report.get("cash", -1)) == _cash(_farm_doc(), PLAYER_B),
		"The restored summary carries the authoritative defender cash")
	_expect(int(view_report.get("cash", -1)) == Economy.OPENING_GRANT
			- B_GREENS * GREENS_PRICE - B_PEOPLE * 2
			- LOSS_CAP - OFFLINE_CAP,
		"The restored summary reflects both settled losses (106)")
	_expect(float(view_report.get("now_utc", 0.0)) > 0.0,
		"The restored summary carries the world clock")
	_expect(int(view_report.get("target_lost", -1)) == LOSS_CAP + OFFLINE_CAP,
		"The reconnected view restores the shared target budget (5)")
	var offline: Dictionary = _child_recent(view_report, E2_ID)
	_expect(not bool(offline.get("defender_online", true)),
		"The reconnected view keeps the durable offline outcome flag")
	_expect(int(offline.get("losses", 0)) == OFFLINE_CAP
			and str(offline.get("window_id", "")) == WINDOW_OFFLINE,
		"The reconnected view keeps the offline loss and window")
	_expect(_child_recent(view_report, E4_ID).is_empty(),
		"No online settlement exists before the reconnect settles one")
	_expect(await _wait(func() -> bool: return _roster_has(PLAYER_B), 15000),
		"The reconnected defender is back in the authoritative roster")
	return true


func _reconnected_online_settlement() -> bool:
	var farm_before: Dictionary = _farm_doc()
	var a_cash: int = _cash(farm_before, PLAYER_A)
	var b_cash: int = _cash(farm_before, PLAYER_B)
	var a_supplies: int = _supplies(farm_before, PLAYER_A)
	var engaged: Dictionary = await _conflict(E4_ID, "engage",
		_battle_args(E4_ID, [A_UNIT2]))
	_expect(bool(engaged.get("ok", false))
			and not bool(engaged.get("duplicate", true)),
		"The reconnected target accepts an online settlement again (%s)"
			% str(engaged.get("reason", "")))
	if not bool(engaged.get("ok", false)):
		return false
	var view: Dictionary = _state(engaged)
	var recent: Dictionary = _recent_row(view, E4_ID)
	_expect(not recent.is_empty(),
		"The post-reconnect settlement appears in the reply view")
	_expect(bool(recent.get("defender_online", false)),
		"The authority switches back to online semantics after the reconnect")
	_expect(int(recent.get("losses", 0)) == 1,
		"The remaining online cap admits exactly one loss (got %d)"
			% int(recent.get("losses", 0)))
	_expect(str(recent.get("window_id", "")) == WINDOW_OFFLINE,
		"The post-reconnect settlement stays in the second window")
	_expect(int(recent.get("target_lost_after", 0)) == LOSS_CAP + OFFLINE_CAP + 1,
		"The target budget reaches 6")
	var row: Dictionary = _engagement_row(E4_ID)
	_expect(int(row.get("cap", -1)) == LOSS_CAP
			and bool(row.get("defender_online", false))
			and int(row.get("amount", 0)) == 1,
		"participation.json records the online cap for the post-reconnect hit")
	_expect(int(row.get("loss_total_after", 0)) == LOSS_CAP,
		"The online cap and the offline cap share one cumulative ledger (3)")
	var outcome: Dictionary = _conflict_outcome(E4_ID)
	_expect(bool(outcome.get("defender_online", false))
			and int(outcome.get("losses", 0)) == 1
			and int(outcome.get("participation_cap", -1)) == LOSS_CAP,
		"conflicts.json records the post-reconnect online outcome")
	var farm_after: Dictionary = _farm_doc()
	_expect(_cash(farm_after, PLAYER_A) == a_cash,
		"A one-coin loss yields no cash spoils (integer half)")
	_expect(_cash(farm_after, PLAYER_B) == b_cash - 1,
		"The defender loses exactly one cash unit")
	_expect(_supplies(farm_after, PLAYER_A) == a_supplies - 1,
		"The attacker pays the final supply")
	_expect(_unit_people(A_UNIT2) == 0,
		"The last attacker unit is destroyed")

	_write_text(str(_b2.refresh), "refresh")
	var online: Dictionary = await _wait_child_report(
		str(_b2.online), int(_b2.pid), 30000)
	_expect(bool(online.get("ok", false)),
		"The reconnected client refreshes its view after the online hit (%s)"
			% str(online.get("step", "")))
	if not bool(online.get("ok", false)):
		return false
	_expect(int(online.get("cash", -1)) == _cash(_farm_doc(), PLAYER_B),
		"The refreshed summary carries the post-online cash")
	_expect(int(online.get("cash", -1)) == Economy.OPENING_GRANT
			- B_GREENS * GREENS_PRICE - B_PEOPLE * 2
			- LOSS_CAP - OFFLINE_CAP - 1,
		"The refreshed summary reflects all three losses (105)")
	var online_row: Dictionary = _child_recent(online, E4_ID)
	_expect(bool(online_row.get("defender_online", false))
			and int(online_row.get("losses", 0)) == 1,
		"The reconnected view shows the online settlement")
	_expect(int(online.get("target_lost", -1)) == LOSS_CAP + OFFLINE_CAP + 1,
		"The reconnected view shows the shared target budget (6)")
	return true


func _replay_offline_command() -> void:
	var farm_bytes: PackedByteArray = _bytes(world_dir.path_join("farm.json"))
	var units_bytes: PackedByteArray = _bytes(world_dir.path_join("units.json"))
	var participation_bytes: PackedByteArray = _bytes(
		world_dir.path_join("participation.json"))
	var conflict_bytes: PackedByteArray = _bytes(
		world_dir.path_join(ConflictStore.MAIN))
	var replay: Dictionary = await _conflict(E2_ID, "engage",
		_battle_args(E2_ID, [A_UNIT1, A_UNIT2]))
	_expect(bool(replay.get("ok", false))
			and bool(replay.get("duplicate", false)),
		"Replaying the offline-issued command after the reconnect returns duplicate")
	_expect(_bytes(world_dir.path_join("farm.json")) == farm_bytes
			and _bytes(world_dir.path_join("units.json")) == units_bytes
			and _bytes(world_dir.path_join("participation.json")) == participation_bytes
			and _bytes(world_dir.path_join(ConflictStore.MAIN)) == conflict_bytes,
		"The reconnect replay rewrites no document")
	var view: Dictionary = _state(replay)
	_expect(_target_lost(view, PLAYER_B) == LOSS_CAP + OFFLINE_CAP + 1,
		"The reconnect replay does not settle the offline hit a second time")
	var recent: Array = view.get("recent", []) if view.get("recent") is Array else []
	_expect(recent.size() == 3,
		"The replay view still carries exactly three settled commands (got %d)"
			% recent.size())
	var offline: Dictionary = _recent_row(view, E2_ID)
	_expect(not bool(offline.get("defender_online", true)),
		"The durable offline outcome keeps its online flag after the reconnect")
	_expect(_cash(_farm_doc(), PLAYER_A) == 12
			and _cash(_farm_doc(), PLAYER_B) == 105
			and _supplies(_farm_doc(), PLAYER_A) == 0,
		"The replay pays and takes nothing twice")


# ------------------------------------------------------------------ children

func _run_child() -> void:
	match role:
		ROLE_DEFENDER: await _child_defender()
		ROLE_RECONNECT: await _child_reconnect()
		_:
			_child_fail(report1_path, "role", role)


func _child_defender() -> void:
	var code: String = _read_text(code_file).strip_edges()
	if code.is_empty():
		_child_fail(report1_path, "code", "empty")
		return
	if not await _open_client(code, PLAYER_B, NAME_B, PLAYER_SECRET_B):
		_child_fail(report1_path, "join", ",".join(PackedStringArray(_refusals)))
		return
	var account: Dictionary = await _submit(FarmCommand.make_account_open(
		B_OPEN, client.world_time()))
	if not bool(account.get("ok", false)):
		_child_fail(report1_path, "account", str(account.get("reason", "")))
		return
	var now: float = client.world_time()
	var placed: Dictionary = await _submit(FarmCommand.make_market_place(
		B_BUY, "buy", "greens", GREENS_PRICE, B_GREENS, now + 3600.0, now))
	if not bool(placed.get("ok", false)):
		_child_fail(report1_path, "buy", str(placed.get("reason", "")))
		return
	var filled: bool = await _wait(func() -> bool:
		return _supplies(_farm_doc(), PLAYER_B) >= B_GREENS, 30000)
	if not filled:
		_child_fail(report1_path, "buy_fill", "timeout")
		return
	var recruited: Dictionary = await _unit(B_UNIT, "recruit", {
		"kind": "militia", "people": B_PEOPLE, "equipment": "none",
		"station": "farm_a", "command_id": B_UNIT,
	})
	if not bool(recruited.get("ok", false)):
		_child_fail(report1_path, "recruit", str(recruited.get("reason", "")))
		return
	if not await _refresh_summary():
		_child_fail(report1_path, "summary", "timeout")
		return
	_write_report(report1_path, {
		"ok": true, "step": "ready",
		"cash": _farm_cash(_last_farm, PLAYER_B),
		"supplies": _farm_supplies(_last_farm, PLAYER_B),
		"unit_people": _unit_people(B_UNIT),
		"now_utc": _last_now_utc,
	})
	if not await _wait_file(marker_path, 45000):
		_child_fail(report2_path, "consent_wait", "timeout")
		return
	var consent: Dictionary = await _participation(B_CONSENT_ID, "declare", {
		"role": Participation.ROLE_DEFENDER, "command_id": B_CONSENT_ID,
	})
	var row: Dictionary = _participant(_state(consent), PLAYER_B)
	if not bool(consent.get("ok", false)) or not bool(row.get("defender", false)):
		_child_fail(report2_path, "consent", str(consent.get("reason", "")))
		return
	_write_report(report2_path, {
		"ok": true, "step": "consented",
		"defender": true, "revision": int(row.get("consent_revision", -1)),
	})
	await _wait_file(stop_path, 120000)
	_child_exit()


func _child_reconnect() -> void:
	var code: String = _read_text(code_file).strip_edges()
	if code.is_empty():
		_child_fail(report1_path, "code", "empty")
		return
	if not await _open_client(code, PLAYER_B, NAME_B, PLAYER_SECRET_B):
		_child_fail(report1_path, "join", ",".join(PackedStringArray(_refusals)))
		return
	if not await _refresh_summary():
		_child_fail(report1_path, "summary", "timeout")
		return
	var pre: Dictionary = await _conflict("offline-cap-b2-view", "state")
	if not bool(pre.get("ok", false)):
		_child_fail(report1_path, "view", str(pre.get("reason", "")))
		return
	_write_report(report1_path, {
		"ok": true, "step": "view",
		"role": str(client.member.role),
		"cash": _farm_cash(_last_farm, PLAYER_B),
		"supplies": _farm_supplies(_last_farm, PLAYER_B),
		"now_utc": _last_now_utc,
		"target_lost": _target_lost(_state(pre), PLAYER_B),
		"recent": _child_view_rows(_state(pre)),
	})
	if not await _wait_file(marker_path, 90000):
		_child_fail(report2_path, "refresh_wait", "timeout")
		return
	var post: Dictionary = await _conflict("offline-cap-b2-online", "state")
	if not bool(post.get("ok", false)):
		_child_fail(report2_path, "online_view", str(post.get("reason", "")))
		return
	if not await _refresh_summary():
		_child_fail(report2_path, "online_summary", "timeout")
		return
	_write_report(report2_path, {
		"ok": true, "step": "online",
		"cash": _farm_cash(_last_farm, PLAYER_B),
		"now_utc": _last_now_utc,
		"target_lost": _target_lost(_state(post), PLAYER_B),
		"recent": _child_view_rows(_state(post)),
	})
	await _wait_file(stop_path, 120000)
	_child_exit()


func _child_fail(path: String, step: String, reason: String) -> void:
	_write_report(path, {"ok": false, "step": step, "reason": reason})
	push_error("conflict offline cap child failed: %s %s" % [step, reason])
	_child_exit(1)


func _child_exit(exit_code: int = 0) -> void:
	if client != null:
		if is_instance_valid(client):
			client.close()
			client.queue_free()
		client = null
	await process_frame
	await create_timer(0.2).timeout
	quit(exit_code)


func _refresh_summary() -> bool:
	if client == null or not client.joined:
		return false
	var before: int = _state_count
	client.request_summary()
	return await _wait(func() -> bool: return _state_count > before, 15000)


# ------------------------------------------------------------------- helpers

func _start_authority() -> bool:
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
	server_pid = _launch(args, log_path)
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
	_expect(str(status.get("opened", "")) == "created",
		"The status file records a freshly created world")
	_expect(str(status.get("host_player", "")) == PLAYER_A,
		"The status file records the startup host player")
	return true


func _member_code() -> String:
	var invite_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		world_dir.path_join("invite.bin"))
	var pem: String = FileAccess.get_file_as_bytes(
		world_dir.path_join("server.crt")).get_string_from_ascii()
	return WorldJoinCode.encode(WorldInvite.make(
		"server-invite", invite_bytes, WorldInvite.MEMBER, WORLD, 0.0, false),
		url, pem, "localhost")


func _spawn_child(child_role: String, extra: Array[String]) -> int:
	var args: Array[String] = [
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(TEST_SCRIPT), "--",
		"--role=" + child_role, "--dir=" + dir, "--world-dir=" + world_dir,
		"--code-file=" + code_file,
	]
	args.append_array(extra)
	var child_log: String = dir.path_join("%s-%d.log" % [
		child_role, Time.get_ticks_usec()])
	return _launch(args, child_log)


## Spawns Godot directly, or through `exec` in a shell where one exists so the
## child's stderr is captured in a log and the shell PID becomes the child PID.
func _launch(args: Array[String], output_path: String) -> int:
	if OS.get_name() != "Windows":
		var command: String = "exec " + _shell_quote(OS.get_executable_path())
		for argument: String in args:
			command += " " + _shell_quote(argument)
		command += " > " + _shell_quote(output_path) + " 2>&1"
		return OS.create_process("/bin/sh", PackedStringArray(["-c", command]), false)
	return OS.create_process(OS.get_executable_path(),
		PackedStringArray(args), false)


func _open_client(code: String, player_id: String, display_name: String,
		secret_text: String) -> bool:
	_ready = false
	_refusals.clear()
	_conflict_pending.clear()
	_participation_pending.clear()
	_unit_pending.clear()
	_command_pending.clear()
	_state_count = 0
	_last_farm = null
	_last_now_utc = 0.0
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(farm: RefCounted, _decorations: RefCounted,
			now_utc: float) -> void:
		_ready = true
		_state_count += 1
		_last_farm = farm
		_last_now_utc = now_utc)
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
	var arrived: bool = await _wait(func() -> bool:
		return _conflict_pending.has(request_id), 15000)
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
	var arrived: bool = await _wait(func() -> bool:
		return _participation_pending.has(request_id), 15000)
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
		"areas": [{"id": AREA_ID, "min_x": 0, "min_z": 0, "max_x": 10, "max_z": 10}],
		"windows": [
			{"id": WINDOW_ONLINE, "start_utc": now - 120.0, "end_utc": now + 15.0},
			{"id": WINDOW_OFFLINE, "start_utc": now + 16.0,
				"end_utc": now + 3600.0},
		],
		"loss_cap": LOSS_CAP,
		"offline_loss_cap": OFFLINE_CAP,
	}


func _battle_args(command_id: String, attacker_units: Array) -> Dictionary:
	return {
		"command_id": command_id,
		"defender": PLAYER_B,
		"attacker_units": attacker_units,
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


func _recent_row(view: Dictionary, command_id: String) -> Dictionary:
	var rows: Variant = view.get("recent")
	if not rows is Array:
		return {}
	for value: Variant in rows:
		if value is Dictionary \
				and str((value as Dictionary).get("command_id", "")) == command_id:
			return value
	return {}


func _child_view_rows(view: Dictionary) -> Array:
	var rows: Array = []
	var source: Variant = view.get("recent")
	if not source is Array:
		return rows
	for value: Variant in source:
		if not value is Dictionary:
			continue
		rows.append({
			"command_id": str((value as Dictionary).get("command_id", "")),
			"defender_online": bool((value as Dictionary).get("defender_online", false)),
			"losses": int((value as Dictionary).get("losses", 0)),
			"window_id": str((value as Dictionary).get("window_id", "")),
			"target_lost_after": int((value as Dictionary).get("target_lost_after", 0)),
		})
	return rows


func _child_recent(report: Dictionary, command_id: String) -> Dictionary:
	var rows: Variant = report.get("recent")
	if not rows is Array:
		return {}
	for value: Variant in rows:
		if value is Dictionary \
				and str((value as Dictionary).get("command_id", "")) == command_id:
			return value
	return {}


func _authority_now() -> float:
	var reply: Dictionary = await _participation(
		"offline-cap-clock-%d" % Time.get_ticks_usec(), "state")
	return float(_state(reply).get("now_utc", 0.0))


## Polls the authority clock without exhausting the per-peer command bucket:
## one token per second is exactly the refill rate.
func _wait_clock(target_utc: float, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if await _authority_now() >= target_utc:
			return true
		await create_timer(1.0).timeout
	return await _authority_now() >= target_utc


func _roster_has(player_id: String) -> bool:
	if client == null or client.member == null or not is_instance_valid(client.member):
		return false
	for row: Dictionary in client.member.roster:
		if str(row.get("player_id", "")) == player_id:
			return true
	return false


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


func _participation_doc() -> Dictionary:
	var saved: Dictionary = _read_json(world_dir.path_join("participation.json"))
	var state: Variant = saved.get("state")
	return state if state is Dictionary else {}


func _engagement_row(command_id: String) -> Dictionary:
	var rows_value: Variant = _participation_doc().get("engagements")
	if not rows_value is Dictionary:
		return {}
	var row_value: Variant = (rows_value as Dictionary).get(command_id)
	return row_value if row_value is Dictionary else {}


func _conflicts_doc() -> Dictionary:
	return _read_json(world_dir.path_join(ConflictStore.MAIN))


func _conflict_outcome(command_id: String) -> Dictionary:
	var state_value: Variant = _conflicts_doc().get("state")
	if not state_value is Dictionary:
		return {}
	var consumed_value: Variant = (state_value as Dictionary).get("consumed")
	if not consumed_value is Dictionary:
		return {}
	var entry_value: Variant = (consumed_value as Dictionary).get(command_id)
	if not entry_value is Dictionary:
		return {}
	var outcome_value: Variant = (entry_value as Dictionary).get("outcome")
	return outcome_value if outcome_value is Dictionary else {}


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


func _farm_cash(farm: RefCounted, owner: String) -> int:
	return farm.economy_cash(owner) if farm != null else -1


func _farm_supplies(farm: RefCounted, owner: String) -> int:
	if farm == null:
		return -1
	var goods: Variant = farm.economy_goods(owner)
	if not goods is Dictionary:
		return 0
	var total: int = 0
	for good_id: Variant in goods:
		total += int((goods as Dictionary)[good_id])
	return total


func _status() -> Dictionary:
	return _read_json(world_dir.path_join("server-status.json"))


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text: String = FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _read_text(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


## A report is staged and renamed into place, so a reader can still observe an
## empty or partial file during the rename on some filesystems; the parent polls
## until the JSON parses.
func _write_report(path: String, payload: Dictionary) -> void:
	var staged: String = path + ".tmp"
	_write_text(staged, JSON.stringify(payload))
	DirAccess.rename_absolute(staged, path)


func _bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) \
		if FileAccess.file_exists(path) else PackedByteArray()


# ------------------------------------------------------------------ lifecycle

func _cleanup() -> void:
	await _close_client()
	if int(_b2.get("pid", 0)) > 0:
		await _stop_child(int(_b2.pid), str(_b2.stop))
	if int(_b1.get("pid", 0)) > 0:
		await _stop_child(int(_b1.pid), str(_b1.stop))
	await _stop_server()


func _stop_child(pid: int, path: String) -> void:
	_write_text(path, "stop")
	if await _wait_process_gone(pid, 8000):
		return
	OS.kill(pid)
	await _wait_process_gone(pid, 5000)


func _stop_server() -> void:
	if server_pid <= 0:
		return
	_write_text(world_dir.path_join("stop"), "stop")
	var stopped: bool = await _wait_process_gone(server_pid, 20000)
	_expect(stopped, "The authority process shuts down cleanly")
	var status: Dictionary = _status()
	_expect(str(status.get("state", "")) == "stopped",
		"The shutdown is recorded in the status file")
	_expect(str(status.get("save", "")) == "saved",
		"The status file records the saved stop outcome")
	if not stopped:
		OS.kill(server_pid)
	server_pid = 0


func _wait_process_gone(pid: int, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline and OS.is_process_running(pid):
		await create_timer(0.05).timeout
	return not OS.is_process_running(pid)


func _wait_child_report(path: String, pid: int, timeout_ms: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var document: Dictionary = _read_json(path)
		if not document.is_empty():
			return document
		if pid > 0 and not OS.is_process_running(pid):
			await create_timer(0.15).timeout
			return _read_json(path)
		await create_timer(0.05).timeout
	return _read_json(path)


func _wait_file(path: String, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(path):
			return true
		await create_timer(0.05).timeout
	return FileAccess.file_exists(path)


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
	print("CONFLICT_OFFLINE_CAP_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
