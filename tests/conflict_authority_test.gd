extends SceneTree
## M12-03 conflict authority wiring: the pure settlement and unit-loss bridge are
## executed through the authoritative world with real farm assets, persisted
## conflict context, idempotent retries/recovery and the RPC-facing permission
## gate.
##
## Covers: hostless/peace refusals, real cash/supplies/unit losses and loot,
## cash conservation, the per-target budget, duplicate replay that changes no
## byte, changed-payload conflicts, visitor/anonymous/read-only refusals, restart
## persistence, write-time copy, and two crash seams (intent saved but farm not
## applied; farm applied but unit/participation not) that must never charge twice.
##
## No UI, transport, projection or Windows path is exercised here.

const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const UnitState = preload("res://conflict/unit_state.gd")
const UnitConflict = preload("res://conflict/unit_conflict.gd")
const ConflictSettlement = preload("res://world/conflict_settlement.gd")
const ConflictStore = preload("res://world/conflict_store.gd")
const Participation = preload("res://conflict/participation_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")

const START: float = 1800000000.0
const WORLD: String = "world-conflict-authority"
const OTHER_WORLD: String = "world-conflict-other"
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const PEER_A: int = 61
const PEER_B: int = 62
const PEER_C: int = 63
const PEER_VISITOR: int = 64
const PEER_ANONYMOUS: int = 65

const A_UNIT: String = "unit-a-1"
const B_UNIT: String = "unit-b-1"
const BATTLE_ID: String = "conflict-1"
const A_PEOPLE: int = 20
const B_PEOPLE: int = 10

const AREA_A: Dictionary = {
	"id": "area_a", "min_x": 0, "min_z": 0, "max_x": 5, "max_z": 5,
}
const WINDOW_A: Dictionary = {
	"id": "window_a", "start_utc": START - 60.0, "end_utc": START + 3600.0,
}

var checks: int = 0
var failures: Array[String] = []
var root_dir: String = ""


## 模拟农场保存失败：冲突意图已经落盘，但真实资产一个字节都没动。
class FailingFarmStore extends "res://farm/farm_store.gd":
	func save_state(_farm, _decorations) -> Dictionary:
		return {"ok": false, "kind": "io"}


## 模拟单位文档保存失败：农场已经提交，单位与参与文档仍未写。
class FailingUnitStore extends "res://world/unit_store.gd":
	func save_state(_state) -> Dictionary:
		return {"ok": false, "kind": "io"}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = _repo().path_join(
		".local/verification/conflict-authority-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)
	_test_store_and_hostless()
	_test_store_refusals()
	_test_peace_refusal()
	_test_successful_engagement()
	_test_duplicate_and_changed_payload()
	_test_target_budget()
	_test_named_refusals_and_permissions()
	_test_restart()
	_test_recovery_farm_not_applied()
	_test_recovery_farm_applied()
	_test_recovery_no_cash_multi_units()
	for failure: String in failures:
		push_error(failure)
	print("CONFLICT_AUTHORITY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_store_and_hostless() -> void:
	var store := ConflictStore.new(_dir("store"))
	_expect(ConflictStore.MAX_BYTES == 1048576, "The conflict sidecar budget is 1 MiB")
	var missing: Dictionary = store.load_state(WORLD)
	_expect(bool(missing.ok) and str(missing.kind) == "missing",
		"A world without a conflict document gets an empty context")
	_expect(str(missing.state.world_id) == WORLD,
		"The empty context carries the requested world id")
	_expect((missing.state.resources as Dictionary).is_empty() \
		and (missing.state.targets as Dictionary).is_empty() \
		and (missing.state.consumed as Dictionary).is_empty(),
		"The empty context has no resources, targets or consumed rows")
	_expect(not ConflictSettlement.valid_context(missing.state),
		"The empty context is not valid until participation is supplied")
	_expect(not store.save_state(missing.state, {}).ok,
		"An empty context without participation cannot be saved")

	var world := HeadlessWorld.new()
	var opened: Dictionary = world.open(_dir("hostless"), START, WORLD, "")
	_expect(bool(opened.get("ok", false)), "A hostless room still opens")
	_expect(world.participation.is_empty(),
		"A hostless room has no participation document")
	var engage: Dictionary = world.execute_conflict("engage", PLAYER_A, {}, "hostless-1", true)
	_expect(not bool(engage.ok) and str(engage.reason) == "no_host",
		"A hostless room refuses an engagement with no_host")
	_expect(not FileAccess.file_exists(
		_dir("hostless").path_join("conflicts.json")),
		"A hostless refusal never creates conflicts.json")
	var direct := HeadlessWorld.new()
	_expect(not direct.execute_conflict("engage", PLAYER_A, {}, "x", true).ok,
		"An unopened world refuses an engagement")


func _test_store_refusals() -> void:
	var directory: String = _dir("store-refusals")
	DirAccess.make_dir_recursive_absolute(directory)
	_write(directory.path_join("conflicts.json"), "{not json")
	var corrupt: HeadlessWorld = HeadlessWorld.new()
	var corrupt_open: Dictionary = corrupt.open(directory, START, WORLD, PLAYER_A)
	_expect(not bool(corrupt_open.get("ok", false)) \
		and str(corrupt_open.get("reason", "")) == "load_conflicts_corrupt",
		"A corrupt conflict document stops the authority")

	var unsupported_dir: String = _dir("store-unsupported")
	DirAccess.make_dir_recursive_absolute(unsupported_dir)
	_write(unsupported_dir.path_join("conflicts.json"),
		JSON.stringify({"version": 2, "state": {}, "applied": {}}))
	var unsupported: HeadlessWorld = HeadlessWorld.new()
	var unsupported_open: Dictionary = unsupported.open(unsupported_dir, START, WORLD, PLAYER_A)
	_expect(not bool(unsupported_open.get("ok", false)) \
		and str(unsupported_open.get("reason", "")) == "load_conflicts_unsupported",
		"An unsupported conflict version stops the authority")

	var foreign_dir: String = _dir("store-foreign")
	var foreign_store := ConflictStore.new(foreign_dir)
	var foreign_state: Dictionary = ConflictStore.initial_state(OTHER_WORLD)
	foreign_state["participation"] = Participation.initial_state(OTHER_WORLD, PLAYER_A)
	_expect(bool(foreign_store.save_state(foreign_state, {}).ok),
		"A valid foreign-world context is written")
	var foreign: HeadlessWorld = HeadlessWorld.new()
	var foreign_open: Dictionary = foreign.open(foreign_dir, START, WORLD, PLAYER_A)
	_expect(not bool(foreign_open.get("ok", false)) \
		and str(foreign_open.get("reason", "")) == "load_conflicts_world_mismatch",
		"A conflict document from another world stops the authority")
	_expect(str(foreign_store.load_state(WORLD).kind) == "world_mismatch",
		"The store names the world mismatch instead of overwriting it")


func _test_peace_refusal() -> void:
	var host: WorldHost = _open_host("peace")
	_join_all(host)
	var prepared: Dictionary = _prepare_units(host, 50, 20)
	var before: Dictionary = _files(host)
	var cash_before: int = host.world.farm.economy_cash(PLAYER_A) \
		+ host.world.farm.economy_cash(PLAYER_B) + host.world.farm.economy_cash(Economy.WORLD_OWNER)
	var refused: Dictionary = _engage(host, PEER_A, _battle_args(BATTLE_ID,
		[A_UNIT], [B_UNIT]))
	_expect(not bool(refused.ok) and str(refused.reason) == "peace",
		"A peace room refuses an engagement with peace")
	_expect(_files(host) == before,
		"A peace refusal leaves farm, units, participation and conflicts byte-identical")
	_expect(host.world.farm.economy_cash(PLAYER_A) \
		+ host.world.farm.economy_cash(PLAYER_B) \
		+ host.world.farm.economy_cash(Economy.WORLD_OWNER) == cash_before,
		"A peace refusal moves no cash")
	_expect(prepared.ok, "The peace fixture has both units")


func _test_successful_engagement() -> void:
	var host: WorldHost = _prepare_battle("success")
	var a_cash_before: int = host.world.farm.economy_cash(PLAYER_A)
	var b_cash_before: int = host.world.farm.economy_cash(PLAYER_B)
	var a_supplies_before: int = _supplies(host, PLAYER_A)
	var b_supplies_before: int = _supplies(host, PLAYER_B)
	var issued_before: int = host.world.farm.economy_issued()

	var result: Dictionary = _engage(host, PEER_A, _battle_args(BATTLE_ID,
		[A_UNIT], [B_UNIT]))
	_expect(bool(result.ok) and not bool(result.duplicate),
		"A consented limited engagement is settled by the authority")
	var outcome: Dictionary = result.get("outcome", {})
	_expect(int(outcome.get("troops", 0)) == A_PEOPLE,
		"The settlement troops are the attacker's real unit people")
	_expect(int(outcome.get("losses", 0)) == 14,
		"Losses stop at the defender's available resources")
	_expect(int(outcome.get("taken_cash", 0)) == 4,
		"Cash is taken before supplies")
	_expect(int(outcome.get("taken_supplies", 0)) == 10,
		"The remaining loss is taken from supplies")
	_expect(int(outcome.get("spoils_cash", 0)) == 2,
		"Half of the taken cash is looted")
	_expect(int(outcome.get("spoils_supplies", 0)) == 5,
		"Half of the taken supplies is looted")
	_expect(int(outcome.get("supply_cost", 0)) == A_PEOPLE,
		"The attacker pays one supply per troop")
	_expect(int(outcome.get("destroyed", 0)) == 27,
		"The outcome records the destroyed amount")
	_expect(int(outcome.get("target_lost_after", 0)) == 14,
		"The target budget records the loss")
	_expect(int(outcome.get("target_cap", 0)) == 100,
		"The target budget uses the authority constant")

	_expect(host.world.farm.economy_total_cash() == issued_before,
		"Conflict cash transfers preserve total issuance")
	_expect(host.world.farm.economy_total_cash() == host.world.farm.economy_issued(),
		"total_cash still equals issued after the engagement")
	_expect(host.world.farm.economy_cash(PLAYER_A) == a_cash_before + 2,
		"The attacker receives the cash spoils")
	_expect(host.world.farm.economy_cash(PLAYER_B) == b_cash_before - 4,
		"The defender loses the taken cash")
	_expect(_supplies(host, PLAYER_A) == a_supplies_before - A_PEOPLE + 5,
		"The attacker pays the supply cost and receives the supply spoils")
	_expect(_supplies(host, PLAYER_B) == b_supplies_before - 10,
		"The defender loses the taken supplies")
	_expect(_unit_people(host, A_UNIT) == 6,
		"The attacker unit loses people according to the outcome")
	_expect(_unit_people(host, B_UNIT) == B_PEOPLE,
		"The defender unit is not reduced by the settlement")

	var losses: Array = host.world.participation_view().get("losses", [])
	_expect(_loss_amount(losses, PLAYER_B) == 14,
		"The participation document records the durable engagement loss")
	var view: Dictionary = result.get("state", {})
	_expect(_target_lost(view, PLAYER_B) == 14, "The reply view carries the target budget")
	_expect(_recent_count(view) == 1, "The reply view carries one recent outcome")
	var row: Dictionary = _recent_row(view)
	_expect(not row.is_empty() and not row.has("payload") and not row.has("freeze"),
		"The recent result summary never exposes consumed payload or freeze rows")

	var stored: Dictionary = ConflictStore.new(host.world.directory).load_state(WORLD)
	_expect(bool(stored.ok) and str(stored.kind) == "loaded",
		"The conflict context is written and reloads")
	_expect(ConflictSettlement.valid_context(stored.state),
		"The stored conflict context passes the strict rule validator")
	_expect(bool((stored.applied.get(BATTLE_ID, {}) as Dictionary).get("applied", false)),
		"The stored applied marker is true after a complete commitment")
	_expect(_unit_file_people(host, A_UNIT) == 6,
		"The reduced unit document is persisted")
	_expect(float(host.world.participation["losses"][PLAYER_B + "|window_a"].amount) == 14.0,
		"The live participation document keeps the loss row")


func _test_duplicate_and_changed_payload() -> void:
	var host: WorldHost = _prepare_battle("duplicate")
	var args: Dictionary = _battle_args(BATTLE_ID, [A_UNIT], [B_UNIT])
	_expect(bool(_engage(host, PEER_A, args).ok), "The first battle commits")
	var before: Dictionary = _files(host)
	var a_cash: int = host.world.farm.economy_cash(PLAYER_A)
	var b_cash: int = host.world.farm.economy_cash(PLAYER_B)
	var a_supplies: int = _supplies(host, PLAYER_A)
	var b_supplies: int = _supplies(host, PLAYER_B)
	var losses_before: Array = host.world.participation_view().get("losses", []).duplicate(true)
	var c0: Dictionary = host.world.conflicts.duplicate(true)

	var replay: Dictionary = _engage(host, PEER_A, args)
	_expect(bool(replay.ok) and bool(replay.duplicate) and not bool(replay.recovered),
		"The same command id and payload replays as a duplicate")
	_expect(_files(host) == before,
		"A duplicate replay leaves all four documents byte-identical")
	_expect(host.world.farm.economy_cash(PLAYER_A) == a_cash \
		and host.world.farm.economy_cash(PLAYER_B) == b_cash \
		and _supplies(host, PLAYER_A) == a_supplies \
		and _supplies(host, PLAYER_B) == b_supplies,
		"A duplicate replay moves no cash or supplies")
	_expect(host.world.participation_view().get("losses", []) == losses_before,
		"A duplicate replay does not advance participation losses")
	_expect(host.world.conflicts == c0, "A duplicate replay does not advance the context")

	var moved: Dictionary = _battle_args(BATTLE_ID, [A_UNIT], [B_UNIT])
	moved["x"] = 3
	var position_conflict: Dictionary = _engage(host, PEER_A, moved)
	_expect(not bool(position_conflict.ok) \
		and str(position_conflict.reason) == "command_conflict",
		"Reusing a command id with another position is a command_conflict")
	_expect(_files(host) == before,
		"A position conflict leaves every document byte-identical")

	var changed_units: Dictionary = _battle_args(BATTLE_ID, [A_UNIT, "unit-z"], [B_UNIT])
	_expect(str(_engage(host, PEER_A, changed_units).reason) == "command_conflict",
		"Reusing a command id with another unit list is a command_conflict")
	var changed_target: Dictionary = _battle_args(BATTLE_ID, [A_UNIT], [B_UNIT], 2, 2,
		"parcel_other")
	_expect(str(_engage(host, PEER_A, changed_target).reason) == "command_conflict",
		"Reusing a command id with another target parcel is a command_conflict")
	var changed_defender: Dictionary = _battle_args(BATTLE_ID, [A_UNIT], [B_UNIT])
	changed_defender["defender"] = PLAYER_C
	_expect(str(_engage(host, PEER_A, changed_defender).reason) == "command_conflict",
		"Reusing a command id with another defender is a command_conflict")
	_expect(_files(host) == before,
		"All changed-payload conflicts leave every document byte-identical")


func _test_target_budget() -> void:
	var host: WorldHost = _open_host("target-cap")
	_join_all(host)
	_setup_war(host, "cap")
	_open_account(host, PLAYER_A)
	_open_account(host, PLAYER_B)
	_seed_actor(host, PLAYER_A, {"greens": 500})
	_seed_actor(host, PLAYER_B, {"greens": 1000})
	expect_ok(host.world.farm.economy_pay("cap-fund-a", PLAYER_B, PLAYER_A, 100, START),
		"B funds A's two large units")
	_recruit(host, PLAYER_A, "cap-a-1", 50)
	_recruit(host, PLAYER_A, "cap-a-2", 50)
	_recruit(host, PLAYER_A, "cap-a-3", 10)
	_recruit(host, PLAYER_B, "cap-b-1", 10)
	expect_ok(host.world.save(), "The target-cap fixture is persisted")

	var first: Dictionary = _engage(host, PEER_A,
		_battle_args("cap-battle-1", ["cap-a-1"], ["cap-b-1"]))
	_expect(bool(first.ok) and int(first.outcome.target_lost_after) == 50,
		"The first raid records 50 target loss")
	var second: Dictionary = _engage(host, PEER_A,
		_battle_args("cap-battle-2", ["cap-a-2"], ["cap-b-1"]))
	_expect(bool(second.ok) and int(second.outcome.target_lost_after) == 100,
		"The second raid reaches the 100 target cap")
	_expect(_target_lost(host.world.conflicts_view(), PLAYER_B) == 100,
		"The target budget table shows the full cap")

	var before: Dictionary = _files(host)
	var a_supplies: int = _supplies(host, PLAYER_A)
	var b_supplies: int = _supplies(host, PLAYER_B)
	var third: Dictionary = _engage(host, PEER_A,
		_battle_args("cap-battle-3", ["cap-a-3"], ["cap-b-1"]))
	_expect(not bool(third.ok) and str(third.reason) == "target_cap",
		"A third raid is refused by the target budget")
	_expect(_files(host) == before,
		"A target-cap refusal changes no document")
	_expect(_supplies(host, PLAYER_A) == a_supplies \
		and _supplies(host, PLAYER_B) == b_supplies,
		"A target-cap refusal charges no supply cost")
	_expect(_unit_people(host, "cap-a-3") == 10,
		"A target-cap refusal leaves the unspent unit intact")


func _test_named_refusals_and_permissions() -> void:
	# Insufficient defender assets.
	var shortage: WorldHost = _open_host("shortage")
	_join_all(shortage)
	_setup_war(shortage, "shortage")
	_open_account(shortage, PLAYER_A)
	_open_account(shortage, PLAYER_B)
	_seed_actor(shortage, PLAYER_A, {"greens": 50})
	_seed_actor(shortage, PLAYER_B, {"greens": 10})
	_recruit(shortage, PLAYER_A, A_UNIT, 10)
	_recruit(shortage, PLAYER_B, B_UNIT, 10)
	expect_ok(shortage.world.farm.economy_pay("shortage-drain", PLAYER_B,
		Economy.WORLD_OWNER, 100, START), "The defender's remaining cash is moved away")
	expect_ok(shortage.world.save(), "The shortage fixture is persisted")
	var before: Dictionary = _files(shortage)
	var shortage_result: Dictionary = _engage(shortage, PEER_A,
		_battle_args("shortage-battle", [A_UNIT], [B_UNIT]))
	_expect(not bool(shortage_result.ok) \
		and str(shortage_result.reason) == "insufficient_resources",
		"A defender with no cash or supplies is a named refusal")
	_expect(_files(shortage) == before,
		"An insufficient-resource refusal changes no document")
	_expect(str(_engage(shortage, PEER_A,
		_battle_args("empty-attacker", [], [B_UNIT])).reason) == "empty_units",
		"An empty attacker unit list is refused")
	_expect(str(_engage(shortage, PEER_A,
		_battle_args("empty-defender", [A_UNIT], [])).reason) == "empty_units",
		"An empty defender unit list is refused")
	_expect(str(_engage(shortage, PEER_A,
		_battle_args("dupe-unit", [A_UNIT, A_UNIT], [B_UNIT])).reason) == "duplicate_unit",
		"A duplicate attacker unit id is refused")
	_expect(str(_engage(shortage, PEER_A,
		_battle_args("wrong-owner-a", [B_UNIT], [B_UNIT])).reason) == "duplicate_unit",
		"The same id on both sides is refused before ownership")
	_expect(str(_engage(shortage, PEER_A,
		_battle_args("wrong-owner-b", [A_UNIT], [A_UNIT])).reason) == "duplicate_unit",
		"The same id on both sides is refused for the defender list too")
	_expect(str(_engage(shortage, PEER_A,
		_battle_args("wrong-owner-c", [B_UNIT], ["unit-none"])).reason) == "not_owner",
		"An attacker cannot send another player's unit")
	_expect(str(_engage(shortage, PEER_A,
		_battle_args("wrong-owner-d", [A_UNIT], [A_UNIT + "x"])).reason) == "unknown_unit",
		"A defender unit id must exist")
	_expect(str(_engage(shortage, PEER_A, _battle_args("same-player",
		[A_UNIT], [B_UNIT], 2, 2, null, PLAYER_A)).reason) == "same_player",
		"Attacking yourself is refused")
	_expect(str(_engage(shortage, PEER_A, _battle_args("bad-defender",
		[A_UNIT], [B_UNIT], 2, 2, null, "bad id!")).reason) == "invalid_defender",
		"An invalid defender id is refused")
	_expect(str(_engage(shortage, PEER_A, _battle_args("bad-x",
		[A_UNIT], [B_UNIT], -1)).reason) == "invalid_position",
		"A negative coordinate is refused")
	_expect(str(_engage(shortage, PEER_A, _battle_args("bad-x-2",
		[A_UNIT], [B_UNIT], 5000)).reason) == "invalid_position",
		"A coordinate beyond the cadastre bound is refused")
	var bad_parcel: Dictionary = _battle_args("bad-parcel", [A_UNIT], [B_UNIT])
	bad_parcel["target_parcel"] = 7
	_expect(str(_engage(shortage, PEER_A, bad_parcel).reason) == "invalid_target",
		"A non-string target parcel is refused")
	_expect(_files(shortage) == before,
		"All shape refusals leave every document byte-identical")

	# No defender consent looks like an unknown target to the participation rules.
	var unilateral: WorldHost = _open_host("unilateral")
	_join_all(unilateral)
	_setup_war(unilateral, "unilateral", false)
	_open_account(unilateral, PLAYER_A)
	_open_account(unilateral, PLAYER_B)
	_seed_actor(unilateral, PLAYER_A, {"greens": 50})
	_seed_actor(unilateral, PLAYER_B, {"greens": 50})
	_recruit(unilateral, PLAYER_A, A_UNIT, 10)
	_recruit(unilateral, PLAYER_B, B_UNIT, 10)
	expect_ok(unilateral.world.save(), "The unilateral fixture is persisted")
	var unilateral_before: Dictionary = _files(unilateral)
	_expect(str(_engage(unilateral, PEER_A,
		_battle_args("no-consent", [A_UNIT], [B_UNIT])).reason) == "no_consent",
		"A target that never consented is refused")
	_expect(_files(unilateral) == unilateral_before,
		"A no-consent refusal changes no document")

	# Permission gates. Reads stay open; writes need a named member.
	var permissions: WorldHost = _prepare_battle("permissions")
	var read: Dictionary = permissions.conflict_for_member(PEER_VISITOR, "state", {})
	_expect(bool(read.ok) and read.has("state"),
		"A visitor can read the conflict view")
	var visitor_write: Dictionary = permissions.conflict_for_member(PEER_VISITOR, "engage",
		_battle_args("visitor-battle", [A_UNIT], [B_UNIT]))
	_expect(not bool(visitor_write.ok) and str(visitor_write.reason) == "forbidden",
		"A visitor cannot engage")
	var anonymous_write: Dictionary = permissions.conflict_for_member(PEER_ANONYMOUS,
		"engage", _battle_args("anon-battle", [A_UNIT], [B_UNIT]))
	_expect(not bool(anonymous_write.ok) and str(anonymous_write.reason) == "no_player",
		"An anonymous member cannot engage")
	permissions.read_only = true
	var read_only: Dictionary = permissions.conflict_for_member(PEER_A, "engage",
		_battle_args("readonly-battle", [A_UNIT], [B_UNIT]))
	_expect(not bool(read_only.ok) and str(read_only.reason) == "read_only",
		"A read-only authority refuses engagements")
	permissions.read_only = false
	var unknown: Dictionary = permissions.conflict_for_member(PEER_A, "march", {})
	_expect(not bool(unknown.ok) and str(unknown.reason) == "unknown_action",
		"An unknown conflict action is refused")
	var not_member: Dictionary = permissions.conflict_for_member(999, "state", {})
	_expect(not bool(not_member.ok) and str(not_member.reason) == "not_a_member",
		"A connection that never joined is refused")


func _test_restart() -> void:
	var directory: String = _dir("restart")
	var host: WorldHost = _prepare_battle_at(directory)
	var args: Dictionary = _battle_args(BATTLE_ID, [A_UNIT], [B_UNIT])
	_expect(bool(_engage(host, PEER_A, args).ok), "The battle commits before restart")
	var files_before: Dictionary = _files(host)
	var a_cash: int = host.world.farm.economy_cash(PLAYER_A)
	var b_cash: int = host.world.farm.economy_cash(PLAYER_B)
	var a_supplies: int = _supplies(host, PLAYER_A)
	var b_supplies: int = _supplies(host, PLAYER_B)

	var reopened := WorldHost.new()
	root.add_child(reopened)
	var opened: Dictionary = reopened.configure(directory, START, WORLD, 1, PLAYER_A)
	_expect(bool(opened.get("ok", false)), "The authority reopens on the same directory")
	_join_all(reopened)
	reopened.world._session_started_ms = 0
	_expect(ConflictSettlement.valid_context(reopened.world.conflicts),
		"The conflict context survives the restart")
	_expect(reopened.world._conflict_applied.has(BATTLE_ID),
		"The applied marker survives the restart")
	_expect(_target_lost(reopened.world.conflicts_view(), PLAYER_B) == 14,
		"The target budget survives the restart")
	_expect(_loss_amount(reopened.world.participation_view().get("losses", []),
		PLAYER_B) == 14, "The participation losses survive the restart")
	_expect(_unit_people(reopened, A_UNIT) == 6, "The reduced unit survives the restart")
	_expect(reopened.world.farm.economy_cash(PLAYER_A) == a_cash \
		and reopened.world.farm.economy_cash(PLAYER_B) == b_cash \
		and _supplies(reopened, PLAYER_A) == a_supplies \
		and _supplies(reopened, PLAYER_B) == b_supplies,
		"Cash and supplies survive the restart")

	var replay: Dictionary = reopened.world.execute_conflict("engage", PLAYER_A,
		args, BATTLE_ID, true)
	_expect(bool(replay.ok) and bool(replay.duplicate),
		"A restart retry of the same command is a duplicate")
	_expect(_files(reopened) == files_before,
		"A restart duplicate does not pay the spoils or charge assets a second time")
	_expect(reopened.world.farm.economy_cash(PLAYER_A) == a_cash \
		and _supplies(reopened, PLAYER_A) == a_supplies,
		"The attacker assets are unchanged by the restart retry")


func _test_recovery_farm_not_applied() -> void:
	var host: WorldHost = _prepare_battle("recovery-farm")
	var real_store = host.world.store
	host.world.store = FailingFarmStore.new(host.world.directory)
	var farm_before: String = _text(host.world.directory.path_join("farm.json"))
	var args: Dictionary = _battle_args(BATTLE_ID, [A_UNIT], [B_UNIT])
	var failed: Dictionary = _engage(host, PEER_A, args)
	_expect(not bool(failed.ok) and str(failed.reason) == "save_io",
		"A farm write failure is reported without committing assets")
	_expect(_text(host.world.directory.path_join("farm.json")) == farm_before,
		"A farm write failure leaves the farm file byte-identical")
	_expect(FileAccess.file_exists(host.world.directory.path_join("conflicts.json")),
		"The failed attempt still persisted the conflict intent")
	var stored_intent: Dictionary = ConflictStore.new(host.world.directory).load_state(WORLD)
	_expect(bool(stored_intent.ok) \
		and not bool((stored_intent.applied.get(BATTLE_ID, {}) as Dictionary).get(
			"applied", true)),
		"The persisted intent is marked applied=false")
	_expect(_unit_people(host, A_UNIT) == A_PEOPLE,
		"The failed attempt did not reduce the unit")

	host.world.store = real_store
	var recovered: Dictionary = _engage(host, PEER_A, args)
	_expect(bool(recovered.ok) and bool(recovered.duplicate) and bool(recovered.recovered),
		"Retrying after the farm failure completes the missing steps")
	_expect(host.world.farm.economy_total_cash() == host.world.farm.economy_issued(),
		"The recovered commitment keeps cash conservation")
	_expect(host.world.farm.economy_cash(PLAYER_A) == 82,
		"The recovered commitment pays the spoils exactly once")
	_expect(host.world.farm.economy_cash(PLAYER_B) == 0,
		"The recovered commitment takes the defender cash exactly once")
	_expect(_supplies(host, PLAYER_A) == 165 and _supplies(host, PLAYER_B) == 0,
		"The recovered commitment applies supply cost and spoils exactly once")
	_expect(_unit_people(host, A_UNIT) == 6,
		"The recovered commitment maps the unit loss exactly once")
	_expect(_loss_amount(host.world.participation_view().get("losses", []),
		PLAYER_B) == 14, "The recovered commitment writes the participation loss")
	var stored: Dictionary = ConflictStore.new(host.world.directory).load_state(WORLD)
	_expect(bool((stored.applied.get(BATTLE_ID, {}) as Dictionary).get("applied", false)),
		"The recovered commitment marks the command applied")

	var assets: Dictionary = _files(host)
	var replay: Dictionary = _engage(host, PEER_A, args)
	_expect(bool(replay.ok) and bool(replay.duplicate) and not bool(replay.recovered),
		"After recovery the same command is an ordinary duplicate")
	_expect(_files(host) == assets,
		"A post-recovery duplicate changes no byte")


func _test_recovery_farm_applied() -> void:
	var host: WorldHost = _prepare_battle("recovery-units")
	var real_units = host.world.units_store
	host.world.units_store = FailingUnitStore.new(host.world.directory)
	var args: Dictionary = _battle_args(BATTLE_ID, [A_UNIT], [B_UNIT])
	var failed: Dictionary = _engage(host, PEER_A, args)
	_expect(not bool(failed.ok) and str(failed.reason) == "save_units_io",
		"A unit write failure is reported after the farm commitment")
	_expect(host.world.farm.economy_total_cash() == host.world.farm.economy_issued(),
		"The partially committed farm keeps cash conservation")
	_expect(host.world.farm.economy_cash(PLAYER_A) == 82
		and host.world.farm.economy_cash(PLAYER_B) == 0,
		"The farm side already holds the single cash transfer")
	var farm_after_failure: String = _text(host.world.directory.path_join("farm.json"))
	var units_after_failure: String = _text(host.world.directory.path_join("units.json"))
	_expect(_unit_people(host, A_UNIT) == A_PEOPLE,
		"The failed attempt did not write the unit document")
	_expect(not _participation_has_item(host.world.participation, BATTLE_ID),
		"The failed attempt did not write the participation engagement")

	host.world.units_store = real_units
	var recovered: Dictionary = _engage(host, PEER_A, args)
	_expect(bool(recovered.ok) and bool(recovered.duplicate) and bool(recovered.recovered),
		"Retrying after the unit failure detects the completed farm work")
	_expect(_text(host.world.directory.path_join("farm.json")) == farm_after_failure,
		"The recovery does not charge or pay cash a second time")
	_expect(host.world.farm.economy_cash(PLAYER_A) == 82
		and host.world.farm.economy_cash(PLAYER_B) == 0
		and _supplies(host, PLAYER_A) == 165 and _supplies(host, PLAYER_B) == 0,
		"The recovered assets match a single application")
	_expect(_text(host.world.directory.path_join("units.json")) != units_after_failure,
		"The recovery writes the missing unit document")
	_expect(_unit_people(host, A_UNIT) == 6, "The recovery applies the unit loss once")
	_expect(_participation_has_item(host.world.participation, BATTLE_ID),
		"The recovery writes the missing participation engagement")
	var stored: Dictionary = ConflictStore.new(host.world.directory).load_state(WORLD)
	_expect(bool((stored.applied.get(BATTLE_ID, {}) as Dictionary).get("applied", false)),
		"The recovered command is marked applied")

	var assets: Dictionary = _files(host)
	var replay: Dictionary = _engage(host, PEER_A, args)
	_expect(bool(replay.ok) and bool(replay.duplicate) and not bool(replay.recovered),
		"A further retry is an ordinary duplicate")
	_expect(_files(host) == assets, "The ordinary duplicate changes no byte")


## 防守方现金为 0 时没有现金分录，农场是否已提交只能靠物资判定；同一批进攻
## 单位里还有分不到战损的未变化单位。恢复必须补齐而不是误判 stale，也不能
## 二次扣出征消耗。
func _test_recovery_no_cash_multi_units() -> void:
	var host: WorldHost = _open_host("recovery-no-cash")
	_join_all(host)
	_setup_war(host, "no-cash")
	_open_account(host, PLAYER_A)
	_open_account(host, PLAYER_B)
	_seed_actor(host, PLAYER_A, {"greens": 300})
	expect_ok(host.world.farm.economy_pay("no-cash-fund", PLAYER_B, PLAYER_A, 100, START),
		"The defender funds the attacker once")
	_seed_actor(host, PLAYER_B, {"greens": 20})
	_recruit(host, PLAYER_A, "nc-a-1", 2)
	_recruit(host, PLAYER_A, "nc-a-2", 2)
	_recruit(host, PLAYER_A, "nc-a-3", 100)
	_recruit(host, PLAYER_B, "nc-b-1", 10)
	_expect(host.world.farm.economy_cash(PLAYER_B) == 0,
		"The defender has no cash, so the settlement takes supplies only")
	_expect(_supplies(host, PLAYER_B) == 10, "The defender has ten supplies to lose")
	expect_ok(host.world.save(), "The no-cash fixture is persisted")

	var real_store = host.world.store
	host.world.store = FailingFarmStore.new(host.world.directory)
	var farm_before: String = _text(host.world.directory.path_join("farm.json"))
	var args: Dictionary = _battle_args("no-cash-battle",
		["nc-a-1", "nc-a-2", "nc-a-3"], ["nc-b-1"])
	var failed: Dictionary = _engage(host, PEER_A, args)
	_expect(not bool(failed.ok) and str(failed.reason) == "save_io",
		"The no-cash attempt reports the farm write failure")
	_expect(_text(host.world.directory.path_join("farm.json")) == farm_before,
		"The no-cash failure leaves the farm untouched")
	_expect(_supplies(host, PLAYER_A) == 196 and _supplies(host, PLAYER_B) == 10,
		"The no-cash failure charges neither supply cost nor losses")
	_expect(_unit_people(host, "nc-a-1") == 2 and _unit_people(host, "nc-a-3") == 100,
		"The no-cash failure does not reduce any unit")

	host.world.store = real_store
	var recovered: Dictionary = _engage(host, PEER_A, args)
	_expect(bool(recovered.ok) and bool(recovered.duplicate) and bool(recovered.recovered),
		"A no-cash intent with an unchanged unit in the plan still recovers")
	var outcome: Dictionary = recovered.get("outcome", {})
	_expect(int(outcome.get("taken_cash", 0)) == 0 \
		and int(outcome.get("taken_supplies", 0)) == 10,
		"The no-cash outcome takes only the defender's supplies")
	_expect(host.world.farm.economy_cash(PLAYER_A) == 12,
		"The recovered battle pays no cash spoils")
	_expect(host.world.farm.economy_cash(PLAYER_B) == 0,
		"The recovered battle takes no defender cash")
	_expect(_supplies(host, PLAYER_A) == 97 and _supplies(host, PLAYER_B) == 0,
		"The recovered battle applies cost and supply spoils exactly once")
	_expect(host.world.farm.economy_total_cash() == host.world.farm.economy_issued(),
		"The no-cash recovered commitment keeps cash conservation")
	_expect(_unit_people(host, "nc-a-1") == 1 \
		and _unit_people(host, "nc-a-2") == 2 \
		and _unit_people(host, "nc-a-3") == 91,
		"The proportional loss leaves the zero-share unit unchanged")
	_expect(_loss_amount(host.world.participation_view().get("losses", []),
		PLAYER_B) == 10, "The no-cash recovery records the participation loss once")
	var stored: Dictionary = ConflictStore.new(host.world.directory).load_state(WORLD)
	_expect(bool((stored.applied.get("no-cash-battle", {}) as Dictionary).get(
		"applied", false)), "The no-cash recovered command is marked applied")
	var assets: Dictionary = _files(host)
	_expect(bool(_engage(host, PEER_A, args).duplicate) and _files(host) == assets,
		"A further no-cash retry is a duplicate that changes no byte")


# --- fixtures -------------------------------------------------------------
## A full battle fixture: A (host) attacks B. Both recruit real units, B's cash
## is drained to four coins so the settlement takes both cash and supplies.
func _prepare_battle(name: String) -> WorldHost:
	return _prepare_battle_at(_dir(name))


func _prepare_battle_at(directory: String) -> WorldHost:
	var host: WorldHost = _open_host_at(directory)
	_join_all(host)
	_setup_war(host, "battle")
	_open_account(host, PLAYER_A)
	_open_account(host, PLAYER_B)
	_seed_actor(host, PLAYER_A, {"greens": 200})
	_seed_actor(host, PLAYER_B, {"greens": 20})
	_recruit(host, PLAYER_A, A_UNIT, A_PEOPLE)
	_recruit(host, PLAYER_B, B_UNIT, B_PEOPLE)
	expect_ok(host.world.farm.economy_pay("battle-drain-b", PLAYER_B,
		Economy.WORLD_OWNER, 96, START), "The defender keeps four coins")
	expect_ok(host.world.save(), "The battle fixture is persisted")
	return host


## Lightweight unit fixture for the peace refusal.
func _prepare_units(host: WorldHost, a_people: int, b_people: int) -> Dictionary:
	_open_account(host, PLAYER_A)
	_open_account(host, PLAYER_B)
	_seed_actor(host, PLAYER_A, {"greens": 100})
	_seed_actor(host, PLAYER_B, {"greens": 100})
	var a: Dictionary = _recruit(host, PLAYER_A, A_UNIT, a_people)
	var b: Dictionary = _recruit(host, PLAYER_B, B_UNIT, b_people)
	expect_ok(host.world.save(), "The peace fixture is persisted")
	return {"ok": bool(a.ok) and bool(b.ok)}


func _open_host(name: String) -> WorldHost:
	return _open_host_at(_dir(name))


func _open_host_at(directory: String) -> WorldHost:
	var host := WorldHost.new()
	root.add_child(host)
	var opened: Dictionary = host.configure(directory, START, WORLD, 1, PLAYER_A)
	_expect(bool(opened.get("ok", false)),
		"The authority opens %s (%s)" % [
			directory.get_file(), str(opened.get("reason", ""))])
	host.world._session_started_ms = 0
	return host


func _join_all(host: WorldHost) -> void:
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_join(host, PEER_C, PLAYER_C, WorldInvite.MEMBER)
	_join(host, PEER_VISITOR, PLAYER_C, WorldInvite.VISITOR)
	_join(host, PEER_ANONYMOUS, "", WorldInvite.MEMBER)


func _join(host: WorldHost, peer: int, player_id: String, role: String) -> void:
	host._members[peer] = role
	if not player_id.is_empty():
		host._players[peer] = {"id": player_id, "name": player_id}


func _setup_war(host: WorldHost, prefix: String, defender_consent: bool = true) -> void:
	var declaration: Dictionary = {
		"tier": Participation.TIER_LIMITED,
		"declaration_id": prefix + "-decl",
		"effective_utc": START,
		"higher_risk": true,
		"areas": [AREA_A],
		"windows": [WINDOW_A],
		"loss_cap": 500,
		"offline_loss_cap": 100,
	}
	expect_ok(host.world.execute_participation("regime", PLAYER_A,
		{"declaration": declaration}, prefix + "-regime"),
		"The host declares a limited regime")
	expect_ok(host.world.execute_participation("declare", PLAYER_A,
		{"role": "attacker"}, prefix + "-consent-a"),
		"The attacker consents")
	if defender_consent:
		expect_ok(host.world.execute_participation("declare", PLAYER_B,
			{"role": "defender"}, prefix + "-consent-b"),
			"The defender consents")


func _open_account(host: WorldHost, player: String) -> void:
	if host.world.farm.economy_granted(player):
		return
	expect_ok(host.world.farm.economy_open_account("seed-account-" + player, player, START),
		"%s has a real cash account" % player)


func _seed_actor(host: WorldHost, player: String, goods: Dictionary) -> void:
	_open_account(host, player)
	var data: Dictionary = host.world.farm.snapshot()
	var bags_value: Variant = data.get("bags")
	var bags: Dictionary = bags_value if bags_value is Dictionary else {}
	var pocket: Dictionary = {}
	for good_id: String in goods:
		pocket[good_id] = int(goods[good_id])
	bags[player] = pocket
	data["bags"] = bags
	var candidate: RefCounted = host.world.farm.copy()
	_expect(candidate.restore_snapshot(data), "%s has a valid seeded farm" % player)
	host.world.farm.accept(candidate)


func _recruit(host: WorldHost, player: String, unit_id: String, people: int) -> Dictionary:
	var result: Dictionary = host.world.execute_unit("recruit", player, {
		"kind": "militia", "people": people, "equipment": "none",
		"station": "farm_a", "command_id": unit_id,
	}, unit_id)
	_expect(bool(result.get("ok", false)),
		"Recruit %s (%s)" % [unit_id, str(result.get("reason", ""))])
	return result


func _battle_args(command_id: String, attacker_units: Array, defender_units: Array,
		x: int = 2, z: int = 2, parcel: Variant = null,
		defender: String = PLAYER_B) -> Dictionary:
	var args: Dictionary = {
		"command_id": command_id,
		"defender": defender,
		"attacker_units": attacker_units,
		"defender_units": defender_units,
		"x": x, "z": z,
	}
	if parcel != null:
		args["target_parcel"] = str(parcel)
	return args


func _engage(host: WorldHost, peer: int, args: Dictionary) -> Dictionary:
	return host.conflict_for_member(peer, "engage", args)


func _unit_people(host: WorldHost, unit_id: String) -> int:
	var value: Variant = host.world.units.get("units", {})
	if value is Dictionary and (value as Dictionary).has(unit_id):
		return int((value as Dictionary)[unit_id].get("people", 0))
	return 0


func _unit_file_people(host: WorldHost, unit_id: String) -> int:
	var stored: Dictionary = host.world.units_store.load_state(WORLD).get("state", {})
	var value: Variant = stored.get("units", {})
	if value is Dictionary and (value as Dictionary).has(unit_id):
		return int((value as Dictionary)[unit_id].get("people", 0))
	return 0


func _supplies(host: WorldHost, player: String) -> int:
	var goods: Dictionary = host.world.farm.economy_goods(player)
	var total: int = 0
	for good_id: String in EconomyCatalog.goods_ids():
		total += int(goods.get(good_id, 0))
	return total


static func _loss_amount(rows: Array, target: String) -> int:
	for value: Variant in rows:
		if value is Dictionary and str((value as Dictionary).get("target", "")) == target:
			return int((value as Dictionary).get("amount", 0))
	return 0


static func _target_lost(view: Dictionary, target: String) -> int:
	var rows: Variant = view.get("targets", [])
	if not rows is Array:
		return 0
	for value: Variant in rows:
		if value is Dictionary and str((value as Dictionary).get("target", "")) == target:
			return int((value as Dictionary).get("lost", 0))
	return 0


static func _recent_count(view: Dictionary) -> int:
	var rows: Variant = view.get("recent", [])
	return (rows as Array).size() if rows is Array else 0


static func _recent_row(view: Dictionary) -> Dictionary:
	var rows: Variant = view.get("recent", [])
	if rows is Array and not (rows as Array).is_empty():
		var first: Variant = (rows as Array)[0]
		return first if first is Dictionary else {}
	return {}


static func _participation_has_item(document: Dictionary, command_id: String) -> bool:
	var engagements: Variant = document.get("engagements", {})
	return engagements is Dictionary and (engagements as Dictionary).has(command_id)


func _files(host: WorldHost) -> Dictionary:
	var directory: String = host.world.directory
	return {
		"farm": _text(directory.path_join("farm.json")),
		"units": _text(directory.path_join("units.json")),
		"participation": _text(directory.path_join("participation.json")),
		"conflicts": _text(directory.path_join("conflicts.json")),
	}


func _dir(name: String) -> String:
	return root_dir.path_join(name)


func _text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func expect_ok(result: Dictionary, message: String) -> void:
	_expect(bool(result.get("ok", false)), message)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + message)
	print(("PASS " if condition else "FAIL ") + message)
