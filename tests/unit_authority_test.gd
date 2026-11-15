extends SceneTree
## M12-01 unit authority wiring: the pure recruitment/upkeep rules are loaded,
## persisted and executed through the authoritative world.
##
## Covers: the unit sidecar round trip and strict key set, real cash and pocket
## supplies charged on recruit (cash lands in `@world` with `total_cash ==
## issued`), idempotent replay by command id, insufficient-asset refusals that
## leave every document untouched, owner-only disband, visitor/anonymous/
## read-only refusals, a roster that survives an authority restart, upkeep
## desertion and capability loss, write-time copy, and corrupt/unsupported/
## foreign documents that stop the authority instead of being overwritten.
##
## No battle, movement, UI or Windows path is exercised here.

const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const UnitState = preload("res://conflict/unit_state.gd")
const UnitStore = preload("res://world/unit_store.gd")
const Economy = preload("res://farm/economy_state.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")

const START: float = 1800000000.0
const DAY: float = 86400.0
const WORLD: String = "world-units-authority"
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const PEER_A: int = 31
const PEER_B: int = 32
const PEER_C: int = 33
const PEER_VISITOR: int = 34
const PEER_ANONYMOUS: int = 35

var checks: int = 0
var failures: Array[String] = []
var root_dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = _repo().path_join(
		".local/verification/unit-authority-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)
	_test_store_roundtrip_and_default()
	_test_recruit_charges_real_assets()
	_test_idempotency_and_conflict()
	_test_paid_retry_with_missing_roster()
	_test_insufficient_assets()
	_test_disband_and_permissions()
	_test_restart_and_view()
	_test_upkeep_desertion_and_capability()
	_test_write_time_copy()
	_test_corrupt_unsupported_and_foreign()
	for failure: String in failures:
		push_error(failure)
	print("UNIT_AUTHORITY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_store_roundtrip_and_default() -> void:
	var store := UnitStore.new(root_dir.path_join("store"))
	_expect(UnitStore.MAX_BYTES == 65536, "The unit sidecar budget is 64 KiB")
	var missing: Dictionary = store.load_state(WORLD)
	_expect(missing.ok and missing.kind == "missing",
		"A world without a unit document gets an empty roster")
	_expect(UnitState.valid(missing.state), "The missing-document roster is valid")
	_expect(str(missing.state.world_id) == WORLD,
		"The default roster carries the requested world id")

	var empty_saved: Dictionary = store.save_state(missing.state)
	_expect(empty_saved.ok and empty_saved.kind == "saved",
		"A valid empty roster is written atomically")
	var loaded: Dictionary = store.load_state(WORLD)
	_expect(loaded.ok and loaded.kind == "loaded", "The written roster reloads")
	_expect(loaded.state.units == missing.state.units
		and loaded.state.commands == missing.state.commands
		and str(loaded.state.world_id) == WORLD,
		"A stored roster round trips with the same roster and world")

	var unknown_key: Dictionary = missing.state.duplicate(true)
	unknown_key["extra"] = true
	_expect(not store.save_state(unknown_key).ok,
		"An unknown top-level key is refused before it reaches the file")
	_expect(not store.save_state({"units": []}).ok,
		"A malformed roster is refused")


func _test_recruit_charges_real_assets() -> void:
	var host: WorldHost = _open_host(root_dir.path_join("recruit"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_seed_actor(host, PLAYER_A, {"greens": 6, "spinach": 6})
	var issued_before: int = host.world.farm.economy_issued()
	var cash_before: int = host.world.farm.economy_cash(PLAYER_A)
	var world_before: int = host.world.farm.economy_cash(Economy.WORLD_OWNER)
	var total_before: int = host.world.farm.economy_total_cash()

	# `owner` is a payload field; the connection identity must win.
	var args: Dictionary = {
		"kind": "militia", "people": 10, "equipment": "none",
		"station": "farm_a", "command_id": "unit-a-1", "owner": PLAYER_B,
	}
	var created: Dictionary = host.unit_for_member(PEER_A, "recruit", args)
	_expect(created.ok and created.action == "recruit", "A member recruits through the authority")
	_expect(not created.duplicate, "The first recruit is not a replay")
	_expect(str(created.get("unit_id", "")) == "unit-a-1", "The reply names the new unit")

	var row: Dictionary = _row(created.state, "unit-a-1")
	_expect(not row.is_empty(), "The authoritative reply carries the new unit")
	_expect(str(row.get("owner", "")) == PLAYER_A,
		"The unit belongs to the joined player, not the payload owner")
	_expect(int(row.get("people", 0)) == 10, "The unit records its people")
	_expect(str(row.get("kind", "")) == "militia", "The unit records its kind")
	_expect(str(row.get("equipment", "")) == "none", "The unit records its equipment")
	_expect(str(row.get("station", "")) == "farm_a", "The unit records its station")
	_expect(int(row.get("unfed_days", -1)) == 0, "A new unit is fed")
	_expect(not row.has("commands"), "The view carries no command records")

	# militia 10 people at 2 cash each and 1 supply each.
	var cash_after: int = host.world.farm.economy_cash(PLAYER_A)
	var world_after: int = host.world.farm.economy_cash(Economy.WORLD_OWNER)
	_expect(cash_after == cash_before - 20, "The actor pays the real cash cost")
	_expect(world_after == world_before + 20, "The cash cost lands in the @world account")
	_expect(host.world.farm.economy_total_cash() == total_before,
		"Moving cash to @world preserves total cash")
	_expect(host.world.farm.economy_issued() == issued_before,
		"Recruitment issues no new cash")
	_expect(host.world.farm.economy_total_cash() == host.world.farm.economy_issued(),
		"total_cash still equals issued after recruitment")

	var bag: Dictionary = host.world.farm.bag(PLAYER_A)
	_expect(int(bag.get("greens", -1)) == 0,
		"Supplies are deducted in catalog order: greens first")
	_expect(int(bag.get("spinach", -1)) == 2,
		"Only the remaining supply requirement leaves the next good")
	_expect(host.world.farm.economy_goods(PLAYER_A).size() == EconomyCatalog.goods_ids().size(),
		"The authority still exposes the whole economy catalog")

	var stored: Dictionary = _stored(host)
	_expect(stored.ok and stored.kind == "loaded",
		"The accepted recruit is written to the unit sidecar immediately")
	_expect(UnitState.valid(stored.state), "The committed roster is valid")
	_expect(str(stored.state.units["unit-a-1"].owner) == PLAYER_A,
		"The stored unit belongs to the actor")

	var state_view: Dictionary = host.unit_for_member(PEER_A, "state", {})
	_expect(state_view.ok and _row(state_view.state, "unit-a-1").size() > 0,
		"A member can read the authoritative unit view")


func _test_idempotency_and_conflict() -> void:
	var host: WorldHost = _open_host(root_dir.path_join("idempotent"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_seed_actor(host, PLAYER_A, {"greens": 20, "spinach": 20})
	var args: Dictionary = {
		"kind": "militia", "people": 10, "equipment": "none",
		"station": "farm_a", "command_id": "unit-idem-1",
	}
	expect_ok(host.unit_for_member(PEER_A, "recruit", args), "The recruit is accepted")
	var cash_after: int = host.world.farm.economy_cash(PLAYER_A)
	var goods_after: Dictionary = host.world.farm.bag(PLAYER_A)
	var units_after: String = JSON.stringify(host.world.units)

	var replay: Dictionary = host.unit_for_member(PEER_A, "recruit", args)
	_expect(replay.ok and replay.duplicate,
		"Retrying the same command id replays the first result")
	_expect(host.world.farm.economy_cash(PLAYER_A) == cash_after,
		"A replay does not charge cash twice")
	_expect(host.world.farm.bag(PLAYER_A) == goods_after,
		"A replay does not deduct supplies twice")
	_expect(JSON.stringify(host.world.units) == units_after,
		"A replay does not change the roster")

	var conflict: Dictionary = host.unit_for_member(PEER_A, "recruit", {
		"kind": "guard", "people": 10, "equipment": "none",
		"station": "farm_a", "command_id": "unit-idem-1",
	})
	_expect(conflict.reason == "command_conflict",
		"Reusing a command id with a different payload is a conflict")
	_expect(host.world.farm.economy_cash(PLAYER_A) == cash_after,
		"A conflict does not charge cash")


func _test_paid_retry_with_missing_roster() -> void:
	# Simulates "farm commit succeeded, unit save failed": the farm already holds
	# the payment and the reduced pocket, but the roster is still empty. The
	# ledger payment marker is the only evidence and must complete the unit
	# without charging again.
	var host: WorldHost = _open_host(root_dir.path_join("paid-retry"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_seed_actor(host, PLAYER_A, {"greens": 20})
	var args: Dictionary = {
		"kind": "militia", "people": 10, "equipment": "none",
		"station": "farm_a", "command_id": "unit-paid-retry",
	}
	expect_ok(host.unit_for_member(PEER_A, "recruit", args),
		"The recruit commits the farm side first")
	var cash_paid: int = host.world.farm.economy_cash(PLAYER_A)
	var goods_paid: Dictionary = host.world.farm.bag(PLAYER_A)
	DirAccess.remove_absolute(host.world.directory.path_join(UnitStore.MAIN))
	host.world.units = UnitState.initial_state(WORLD)
	_expect(host.unit_for_member(PEER_A, "state", {}).state.units.is_empty(),
		"The roster is empty before the recovery retry")
	var recovered: Dictionary = host.unit_for_member(PEER_A, "recruit", args)
	_expect(recovered.ok, "The paid retry rebuilds the missing unit from the ledger marker")
	_expect(host.world.farm.economy_cash(PLAYER_A) == cash_paid,
		"The paid retry charges no cash a second time")
	_expect(host.world.farm.bag(PLAYER_A) == goods_paid,
		"The paid retry deducts no supplies a second time")
	_expect(host.world.units.units.has("unit-paid-retry"),
		"The recovered unit is written to the roster")
	_expect(_stored(host).kind == "loaded",
		"The recovered unit reaches the sidecar")


func _test_insufficient_assets() -> void:
	var host: WorldHost = _open_host(root_dir.path_join("insufficient"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_join(host, PEER_C, PLAYER_C, WorldInvite.MEMBER)
	# B has no economy account at all; C has an account but no supplies.
	_seed_actor(host, PLAYER_C, {})

	var units_before: String = JSON.stringify(host.world.units)
	var farm_before: String = JSON.stringify(host.world.farm.snapshot())
	var no_cash: Dictionary = host.unit_for_member(PEER_B, "recruit", {
		"kind": "militia", "people": 10, "equipment": "none",
		"station": "farm_b", "command_id": "unit-no-cash",
	})
	_expect(no_cash.reason == "insufficient_cash",
		"A member without cash cannot recruit")
	_expect(JSON.stringify(host.world.units) == units_before,
		"A cash refusal does not change the roster")
	_expect(JSON.stringify(host.world.farm.snapshot()) == farm_before,
		"A cash refusal does not change the farm")

	var no_supply: Dictionary = host.unit_for_member(PEER_C, "recruit", {
		"kind": "militia", "people": 10, "equipment": "none",
		"station": "farm_c", "command_id": "unit-no-supply",
	})
	_expect(no_supply.reason == "insufficient_supply",
		"A member without supplies cannot recruit even with cash")
	_expect(JSON.stringify(host.world.units) == units_before,
		"A supply refusal does not change the roster")
	_expect(JSON.stringify(host.world.farm.snapshot()) == farm_before,
		"A supply refusal does not change the farm")
	_expect(host.world.farm.economy_total_cash() == host.world.farm.economy_issued(),
		"Refusals preserve cash conservation")
	_expect(_stored(host).kind == "missing",
		"Refused recruits write no unit document")


func _test_disband_and_permissions() -> void:
	var host: WorldHost = _open_host(root_dir.path_join("permissions"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_join(host, PEER_VISITOR, PLAYER_C, WorldInvite.VISITOR)
	_join(host, PEER_ANONYMOUS, "", WorldInvite.MEMBER)
	_seed_actor(host, PLAYER_A, {"greens": 20})
	_seed_actor(host, PLAYER_B, {"greens": 20})
	expect_ok(host.unit_for_member(PEER_A, "recruit", {
		"kind": "militia", "people": 5, "equipment": "none",
		"station": "farm_a", "command_id": "unit-disband-1",
	}), "The owner recruits a unit for the disband checks")

	_expect(host.unit_for_member(PEER_B, "disband", {
		"unit_id": "unit-disband-1", "command_id": "disband-by-b",
	}).reason == "not_owner", "A non-owner cannot disband the unit")
	_expect(host.unit_for_member(PEER_B, "disband", {
		"unit_id": "missing-unit", "command_id": "disband-missing",
	}).reason == "unknown_unit", "Disbanding an unknown unit is refused")

	var disbanded: Dictionary = host.unit_for_member(PEER_A, "disband", {
		"unit_id": "unit-disband-1", "command_id": "disband-by-a",
	})
	_expect(disbanded.ok, "The owner disbands the unit")
	_expect(_row(disbanded.state, "unit-disband-1").is_empty(),
		"The disbanded unit leaves the view")
	_expect(not host.world.units.units.has("unit-disband-1"),
		"The disbanded unit leaves the live roster")
	_expect(host.unit_for_member(PEER_A, "disband", {
		"unit_id": "unit-disband-1", "command_id": "disband-by-a",
	}).duplicate, "Retrying a disband command replays its first result")

	_expect(host.unit_for_member(PEER_VISITOR, "recruit", {
		"kind": "militia", "people": 5, "equipment": "none",
		"station": "visitor", "command_id": "unit-visitor",
	}).reason == "forbidden", "A visitor cannot recruit")
	_expect(host.unit_for_member(PEER_VISITOR, "state", {}).ok,
		"A visitor may still read the unit view")
	_expect(host.unit_for_member(PEER_ANONYMOUS, "recruit", {
		"kind": "militia", "people": 5, "equipment": "none",
		"station": "anonymous", "command_id": "unit-anonymous",
	}).reason == "no_player", "An anonymous member has no player identity to act as")
	_expect(host.unit_for_member(99, "state", {}).reason == "not_a_member",
		"A connection outside the roster is refused")
	_expect(host.unit_for_member(PEER_A, "march", {}).reason == "unknown_action",
		"An unknown unit action is refused")
	_expect(host.unit_for_member(PEER_A, "recruit", {
		"kind": "militia", "people": 5, "equipment": "none",
		"station": "farm_a", "command_id": "",
	}).reason == "invalid_command", "An empty command id is refused on recruit")

	host.read_only = true
	_expect(host.unit_for_member(PEER_A, "recruit", {
		"kind": "militia", "people": 5, "equipment": "none",
		"station": "farm_a", "command_id": "unit-read-only",
	}).reason == "read_only", "A retiring authority refuses unit writes")
	_expect(host.unit_for_member(PEER_A, "state", {}).ok,
		"A retiring authority still answers unit reads")
	host.read_only = false


func _test_restart_and_view() -> void:
	var directory: String = root_dir.path_join("restart")
	var host: WorldHost = _open_host(directory, START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_seed_actor(host, PLAYER_A, {"greens": 20})
	expect_ok(host.unit_for_member(PEER_A, "recruit", {
		"kind": "guard", "people": 6, "equipment": "basic",
		"station": "tower", "command_id": "unit-restart-1",
	}), "The unit is recruited before the restart")

	var reopened: WorldHost = _open_host(directory, START + 100.0)
	_join(reopened, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	var view: Dictionary = reopened.unit_for_member(PEER_A, "state", {})
	var row: Dictionary = _row(view.state, "unit-restart-1")
	_expect(view.ok and not row.is_empty(), "The unit exists after an authority restart")
	_expect(str(row.get("owner", "")) == PLAYER_A
		and str(row.get("kind", "")) == "guard"
		and int(row.get("people", 0)) == 6
		and str(row.get("equipment", "")) == "basic"
		and str(row.get("station", "")) == "tower",
		"Owner, kind, people, equipment and station survive the restart")
	_expect(int(reopened.world.units.commands.size()) == 1,
		"The durable recruit record also survives the restart")
	_expect(reopened.world.farm.economy_cash(Economy.WORLD_OWNER) > 0,
		"The @world payment survives the restart")


func _test_upkeep_desertion_and_capability() -> void:
	var host: WorldHost = _open_host(root_dir.path_join("upkeep"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	# A: exactly the recruit cost plus five extra supplies, so upkeep is short.
	# B: recruit cost plus a full day of supplies, so B stays fed.
	_seed_actor(host, PLAYER_A, {"greens": 10, "spinach": 5})
	_seed_actor(host, PLAYER_B, {"greens": 20})
	expect_ok(host.unit_for_member(PEER_A, "recruit", {
		"kind": "militia", "people": 10, "equipment": "none",
		"station": "farm_a", "command_id": "unit-up-a",
	}), "A recruits a militia for the upkeep checks")
	expect_ok(host.unit_for_member(PEER_B, "recruit", {
		"kind": "militia", "people": 10, "equipment": "none",
		"station": "farm_b", "command_id": "unit-up-b",
	}), "B recruits a militia for the upkeep checks")
	# A has five supplies left; B has ten.
	_expect(int(host.world.farm.bag(PLAYER_A).get("spinach", 0)) == 5,
		"A holds only the five extra supplies before upkeep")
	_expect(int(host.world.farm.bag(PLAYER_B).get("greens", 0)) == 10,
		"B holds a full day of supplies before upkeep")

	var power_a_before: Dictionary = UnitState.capability(host.world.units, "unit-up-a")
	var power_b_before: Dictionary = UnitState.capability(host.world.units, "unit-up-b")
	var cash_before: int = host.world.farm.economy_total_cash()
	_advance_authority(host, START + DAY)

	var settled: Dictionary = host.unit_for_member(PEER_A, "upkeep", {})
	_expect(settled.ok and settled.action == "upkeep", "A member triggers the upkeep sweep")
	_expect(str(settled.get("status", "")) == UnitState.STATUS_SHORTFALL,
		"A supplies shortage reports a shortfall")
	_expect(int(settled.get("consumed", -1)) == 15,
		"Upkeep consumes A's five and B's ten supplies")
	_expect(int(settled.get("deserters", -1)) == 5,
		"Only the unfed half of A's unit deserts")
	var affected: Array = settled.get("affected", [])
	_expect(affected.size() == 1 and str(affected[0].get("unit_id", "")) == "unit-up-a",
		"The shortfall names the affected unit")
	_expect(int(affected[0].get("unfed_days", 0)) == 1,
		"The affected unit accumulates one unfed day")
	_expect(int(host.world.farm.bag(PLAYER_A).get("spinach", -1)) == 0,
		"A's remaining supplies are deducted")
	_expect(int(host.world.farm.bag(PLAYER_B).get("greens", -1)) == 0,
		"B's supplies are deducted for B's own unit")
	_expect(host.world.farm.bag(PLAYER_B).has("spinach"),
		"Upkeep does not invent goods in another owner's pocket")
	_expect(host.world.farm.economy_total_cash() == cash_before,
		"Upkeep changes no cash")

	var a_row: Dictionary = _row(settled.state, "unit-up-a")
	var b_row: Dictionary = _row(settled.state, "unit-up-b")
	_expect(int(a_row.get("people", 0)) == 5 and int(a_row.get("unfed_days", -1)) == 1,
		"A's unit shrinks and records the unfed day")
	_expect(int(b_row.get("people", 0)) == 10 and int(b_row.get("unfed_days", -1)) == 0,
		"B's fully supplied unit is unchanged")
	var power_a_after: Dictionary = UnitState.capability(host.world.units, "unit-up-a")
	var power_b_after: Dictionary = UnitState.capability(host.world.units, "unit-up-b")
	_expect(int(power_a_after.power) < int(power_a_before.power),
		"A's capability drops after the shortfall")
	_expect(int(power_b_after.power) == int(power_b_before.power),
		"B's capability is unchanged while fed")

	var goods_after: Dictionary = host.world.farm.bag(PLAYER_B)
	var same_tick: Dictionary = host.unit_for_member(PEER_A, "upkeep", {})
	_expect(same_tick.ok and same_tick.status == UnitState.STATUS_SETTLED_THIS_TICK,
		"Repeating upkeep at the same authority tick settles nothing")
	_expect(int(same_tick.get("consumed", -1)) == 0 and int(same_tick.get("deserters", -1)) == 0,
		"A same-tick replay consumes no supplies and loses no people")
	_expect(host.world.farm.bag(PLAYER_B) == goods_after,
		"A same-tick replay deducts no supplies")
	_expect(UnitState.valid(_stored(host).state),
		"The committed upkeep roster is valid")


func _test_write_time_copy() -> void:
	var host: WorldHost = _open_host(root_dir.path_join("copy"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_seed_actor(host, PLAYER_A, {"greens": 2})
	var units_before: Dictionary = host.world.units.duplicate(true)
	var farm_before: String = JSON.stringify(host.world.farm.snapshot())
	var refused: Dictionary = host.unit_for_member(PEER_A, "recruit", {
		"kind": "militia", "people": 10, "equipment": "none",
		"station": "farm_a", "command_id": "unit-copy-1",
	})
	_expect(refused.reason == "insufficient_supply",
		"An insufficient recruit is refused while the candidate is still private")
	_expect(host.world.units == units_before,
		"A refused recruit does not mutate the live roster")
	_expect(JSON.stringify(host.world.farm.snapshot()) == farm_before,
		"A refused recruit does not mutate the live farm")
	_expect(host.unit_for_member(PEER_A, "recruit", {
		"kind": "militia", "people": 1, "equipment": "none",
		"station": "", "command_id": "unit-copy-empty-station",
	}).reason == "invalid_station", "An empty station is refused")
	_expect(host.world.units == units_before,
		"An invalid station does not mutate the live roster")


func _test_corrupt_unsupported_and_foreign() -> void:
	var corrupt_dir: String = root_dir.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	var corrupt_path: String = corrupt_dir.path_join(UnitStore.MAIN)
	_write(corrupt_path, JSON.stringify({"version": UnitStore.VERSION,
		"state": {"world_id": WORLD}}))
	var before: String = FileAccess.get_file_as_string(corrupt_path)
	var corrupt_host := WorldHost.new()
	root.add_child(corrupt_host)
	var corrupt_open: Dictionary = corrupt_host.configure(corrupt_dir, START, WORLD)
	_expect(not corrupt_open.ok and str(corrupt_open.reason) == "load_units_corrupt",
		"A corrupt unit document stops the authority")
	_expect(FileAccess.get_file_as_string(corrupt_path) == before,
		"A corrupt unit document is not overwritten by an empty roster")

	var unsupported_dir: String = root_dir.path_join("unsupported")
	DirAccess.make_dir_recursive_absolute(unsupported_dir)
	_write(unsupported_dir.path_join(UnitStore.MAIN),
		JSON.stringify({"version": UnitStore.VERSION + 1, "state": {}}))
	var unsupported_host := WorldHost.new()
	root.add_child(unsupported_host)
	_expect(str(unsupported_host.configure(unsupported_dir, START, WORLD).get("reason", ""))
		== "load_units_unsupported",
		"An unsupported unit document version is refused")

	var foreign_dir: String = root_dir.path_join("foreign")
	DirAccess.make_dir_recursive_absolute(foreign_dir)
	_write(foreign_dir.path_join(UnitStore.MAIN),
		JSON.stringify({"version": UnitStore.VERSION,
			"state": UnitState.initial_state("another-world")}))
	var foreign_host := WorldHost.new()
	root.add_child(foreign_host)
	_expect(str(foreign_host.configure(foreign_dir, START, WORLD).get("reason", ""))
		== "load_units_world_mismatch",
		"A roster for another world is refused instead of relabelled")

	var direct := HeadlessWorld.new()
	var direct_missing: Dictionary = direct.open(root_dir.path_join("direct"), START)
	_expect(bool(direct_missing.get("ok", false)) and UnitState.valid(direct.units),
		"A direct headless world starts with an empty, valid roster")
	_expect((direct.units_view().get("units", []) as Array).is_empty(),
		"A world that never recruited has an empty unit view")


func _open_host(save_directory: String, now: float) -> WorldHost:
	var host := WorldHost.new()
	root.add_child(host)
	var opened: Dictionary = host.configure(save_directory, now, WORLD)
	_expect(bool(opened.get("ok", false)),
		"The authority opens %s" % save_directory.get_file())
	return host


func _join(host: WorldHost, peer: int, player_id: String, role: String) -> void:
	# join() is the production path; this test sets the same fields directly so
	# the authority surface is exercised without a transport.
	host._members[peer] = role
	if not player_id.is_empty():
		host._players[peer] = {"id": player_id, "name": player_id}


## Test seam: `authority_now_utc()` is the monotonic session clock. Moving its
## baseline forward simulates the next strategic tick without waiting in real
## time or touching the system clock.
func _advance_authority(host: WorldHost, at_utc: float) -> void:
	host.world._session_start_utc = at_utc
	host.world._session_started_ms = Time.get_ticks_msec()


## Opens the actor's real economy account (the one-time grant) and plants the
## supplied goods in their authoritative bag. This uses the same public
## FarmState surface the game uses; it does not add a test-only storage path.
func _seed_actor(host: WorldHost, player_id: String,
		goods: Dictionary) -> void:
	expect_ok(host.world.farm.economy_open_account("seed-account-" + player_id,
		player_id, START), "%s has a real cash account" % player_id)
	var data: Dictionary = host.world.farm.snapshot()
	var bags_value: Variant = data.get("bags")
	var bags: Dictionary = bags_value if bags_value is Dictionary else {}
	var pocket: Dictionary = {}
	for good_id: String in goods:
		pocket[good_id] = int(goods[good_id])
	bags[player_id] = pocket
	data["bags"] = bags
	var candidate: RefCounted = host.world.farm.copy()
	_expect(candidate.restore_snapshot(data), "%s has a valid seeded farm" % player_id)
	host.world.farm.accept(candidate)
	_expect(host.world.farm.economy_total_cash() == host.world.farm.economy_issued(),
		"Seeding keeps cash conservation")


func _stored(host: WorldHost) -> Dictionary:
	return UnitStore.new(host.world.directory).load_state(WORLD)


func _row(view: Variant, unit_id: String) -> Dictionary:
	if not view is Dictionary:
		return {}
	var rows: Variant = (view as Dictionary).get("units")
	if not rows is Array:
		return {}
	for value: Variant in rows:
		if value is Dictionary and str((value as Dictionary).get("id", "")) == unit_id:
			return value
	return {}


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + message)
	print(("PASS " if condition else "FAIL ") + message)


func expect_ok(result: Dictionary, message: String) -> void:
	_expect(bool(result.get("ok", false)), message)
