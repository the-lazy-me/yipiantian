extends SceneTree
## M12-05 non-participation experience. Direct `HeadlessWorld` rules, no
## transport, no UI and no scenes.
##
## The slice measures what a peaceful farmer/caravan, a weak organization and an
## attacker actually experience:
## - a peace room refuses every engagement and leaves all four rule documents
##   byte-identical;
## - a limited room still refuses a farmer who never consented;
## - a consented offline defender loses at most `offline_loss_cap`, the cumulative
##   per-target loss stops at the 100 authority cap, and resource conservation
##   matches the settlement equation;
## - a withdrawal is delayed: before the effective time the target is still
##   attackable, at/after it the authority refuses with `no_consent`;
## - a weak organization's account, public fund and public works documents never
##   participate in the settlement; only the target player's own cash/supplies
##   change;
## - an attacker without expedition supplies is refused before any write;
## - homestead parcels and farm buildings are never transferred by an engagement.
##
## Every fixture uses real accounts, real recruited units and real documents.
## Products live under `.local/`; nothing here writes to `Game/` or the network.

const HeadlessWorld = preload("res://world/headless_world.gd")
const Participation = preload("res://conflict/participation_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")
const PublicFund = preload("res://world/public_fund.gd")
const PublicWorks = preload("res://world/public_works.gd")

const START: float = 1800000000.0
const WORLD: String = "world-non-participation"
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"

const A_UNIT: String = "nonpart-a-1"
const A_UNIT_2: String = "nonpart-a-2"
const B_UNIT: String = "nonpart-b-1"
const C_UNIT: String = "nonpart-c-1"

const ORG: String = "coop_weak"
const PROJECT: String = "well_01"

const AREA_A: Dictionary = {
	"id": "area_a", "min_x": 0, "min_z": 0, "max_x": 5, "max_z": 5,
}

var checks: int = 0
var failures: Array[String] = []
var root_dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = _repo().path_join(
		".local/verification/non-participation-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)
	_test_peace_room()
	_test_limited_room_without_consent()
	_test_offline_raid_cap_and_conservation()
	_test_repeated_raids_stop_at_target_cap()
	_test_withdrawal_delay()
	_test_weak_organization()
	_test_attacker_without_supplies()
	_test_homestead_and_buildings_untouched()
	for failure: String in failures:
		push_error(failure)
	print("NON_PARTICIPATION_EXPERIENCE_TEST checks=%d failures=%d" % [
		checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


## 1. Peace room: a farmer and a caravan are never legal targets. Every refusal
## must leave farm/units/participation/conflicts byte-identical.
func _test_peace_room() -> void:
	var world: HeadlessWorld = _open("peace")
	_declare_peace(world)
	_seed_actor(world, PLAYER_A, {"greens": 100})
	_seed_actor(world, PLAYER_B, {"greens": 60})
	_seed_actor(world, PLAYER_C, {"greens": 40})
	_recruit(world, PLAYER_A, A_UNIT, 10)
	_recruit(world, PLAYER_B, B_UNIT, 5)   # farmer
	_recruit(world, PLAYER_C, C_UNIT, 3)   # caravan
	expect_ok(world.save(), "The peace fixture is persisted")
	var before: Dictionary = _files(world)
	var stocks_before: Dictionary = _stocks(world, [PLAYER_A, PLAYER_B, PLAYER_C])

	var farmer: Dictionary = _engage(world, "peace-farmer", PLAYER_A, PLAYER_B,
		[A_UNIT], [B_UNIT], true)
	_expect(not bool(farmer.get("ok", false)) and str(farmer.get("reason", "")) == "peace",
		"A peace room refuses an attack on a non-participating farmer with peace")
	var caravan: Dictionary = _engage(world, "peace-caravan", PLAYER_A, PLAYER_C,
		[A_UNIT], [C_UNIT], true)
	_expect(not bool(caravan.get("ok", false)) and str(caravan.get("reason", "")) == "peace",
		"A peace room refuses an attack on a caravan with peace")
	_expect(_files(world) == before,
		"A peace refusal leaves farm, units, participation and conflicts byte-identical")
	_expect(_stocks(world, [PLAYER_A, PLAYER_B, PLAYER_C]) == stocks_before,
		"A peace refusal moves no cash or supplies")


## 2. Limited room with an explicit attacker consent but no defender consent:
## the farmer keeps a veto.
func _test_limited_room_without_consent() -> void:
	var world: HeadlessWorld = _open("no-consent")
	_setup_war(world, "nc", false, 500, 100, START + 3600.0)
	_seed_actor(world, PLAYER_A, {"greens": 100})
	_seed_actor(world, PLAYER_B, {"greens": 50})
	_recruit(world, PLAYER_A, A_UNIT, 10)
	_recruit(world, PLAYER_B, B_UNIT, 5)
	expect_ok(world.save(), "The no-consent fixture is persisted")
	var before: Dictionary = _files(world)
	var stocks_before: Dictionary = _stocks(world, [PLAYER_A, PLAYER_B])

	var refused: Dictionary = _engage(world, "no-consent-raid", PLAYER_A, PLAYER_B,
		[A_UNIT], [B_UNIT], true)
	_expect(not bool(refused.get("ok", false))
			and str(refused.get("reason", "")) == "no_consent",
		"A limited room refuses a farmer who never consented with no_consent")
	_expect(_files(world) == before,
		"A no-consent refusal changes no rule document")
	_expect(_stocks(world, [PLAYER_A, PLAYER_B]) == stocks_before,
		"A no-consent refusal changes no asset")


## 3. Consented, offline defender. The offline cap (20) binds before the target
## cap (100); measure the real settlement and prove conservation.
func _test_offline_raid_cap_and_conservation() -> void:
	var world: HeadlessWorld = _open("offline-cap")
	_setup_war(world, "off", true, 500, 20, START + 3600.0)
	_seed_actor(world, PLAYER_A, {"greens": 200})
	_seed_actor(world, PLAYER_B, {"greens": 100})
	_recruit(world, PLAYER_A, A_UNIT, 50)
	_recruit(world, PLAYER_B, B_UNIT, 10)
	expect_ok(world.farm.economy_pay("off-drain-b", PLAYER_B,
		Economy.WORLD_OWNER, 96, START), "The defender keeps four coins")
	expect_ok(world.save(), "The offline-cap fixture is persisted")

	var a_cash_before: int = world.farm.economy_cash(PLAYER_A)
	var b_cash_before: int = world.farm.economy_cash(PLAYER_B)
	var a_supplies_before: int = _supplies(world, PLAYER_A)
	var b_supplies_before: int = _supplies(world, PLAYER_B)

	var result: Dictionary = _engage(world, "offline-raid", PLAYER_A, PLAYER_B,
		[A_UNIT], [B_UNIT], false)
	_expect(bool(result.get("ok", false)), "A consented offline target is still attackable")
	if not bool(result.get("ok", false)):
		print("MEASURE offline_raid refused reason=%s" % str(result.get("reason", "")))
		return
	var outcome: Dictionary = result.get("outcome", {})
	var losses: int = int(outcome.get("losses", 0))
	var taken_cash: int = int(outcome.get("taken_cash", 0))
	var taken_supplies: int = int(outcome.get("taken_supplies", 0))
	var supply_cost: int = int(outcome.get("supply_cost", 0))
	var spoils: int = int(outcome.get("spoils", 0))
	var spoils_cash: int = int(outcome.get("spoils_cash", 0))
	var spoils_supplies: int = int(outcome.get("spoils_supplies", 0))
	var destroyed: int = int(outcome.get("destroyed", 0))
	var target_lost_after: int = int(outcome.get("target_lost_after", 0))

	_expect(losses == 20, "The offline cap limits one raid to 20 resources")
	_expect(losses <= 20, "A single raid never exceeds offline_loss_cap")
	_expect(target_lost_after == 20 and target_lost_after <= 100,
		"Cumulative target loss stays at or below the 100 target cap")
	_expect(taken_cash + taken_supplies == losses,
		"The defender loss is exactly the taken cash plus taken supplies")
	_expect(spoils == spoils_cash + spoils_supplies,
		"The reported spoils are the sum of the cash and supply spoils")
	_expect(destroyed == supply_cost + losses - spoils,
		"destroyed equals supply_cost + losses - spoils")
	_expect(_supplies(world, PLAYER_A) \
			== a_supplies_before - supply_cost + spoils_supplies \
			and world.farm.economy_cash(PLAYER_A) == a_cash_before + spoils_cash,
		"The attacker pays the supply cost and receives the spoils exactly once")
	_expect(_supplies(world, PLAYER_B) == b_supplies_before - taken_supplies \
			and world.farm.economy_cash(PLAYER_B) == b_cash_before - taken_cash,
		"The defender loses exactly the taken cash and supplies")
	var decrease: int = (a_cash_before + a_supplies_before + b_cash_before
		+ b_supplies_before) - (world.farm.economy_cash(PLAYER_A)
		+ _supplies(world, PLAYER_A) + world.farm.economy_cash(PLAYER_B)
		+ _supplies(world, PLAYER_B))
	_expect(decrease == destroyed,
		"The combined cash+supplies decrease of both sides equals destroyed")
	_expect(world.farm.economy_total_cash() == world.farm.economy_issued(),
		"Conflict cash transfers preserve issuance")
	_expect(_loss_amount(world.participation_view().get("losses", []), PLAYER_B) == losses,
		"The participation document records the durable offline loss")

	print("MEASURE offline_raid troops=%d offline_cap=20 target_lost_after=%d "
		% [int(outcome.get("troops", 0)), target_lost_after]
		+ "losses=%d taken_cash=%d taken_supplies=%d supply_cost=%d spoils=%d "
		% [losses, taken_cash, taken_supplies, supply_cost, spoils]
		+ "spoils_cash=%d spoils_supplies=%d destroyed=%d "
		% [spoils_cash, spoils_supplies, destroyed]
		+ "defender_cash=%d->%d defender_supplies=%d->%d "
		% [b_cash_before, world.farm.economy_cash(PLAYER_B),
			b_supplies_before, _supplies(world, PLAYER_B)]
		+ "attacker_cash=%d->%d attacker_supplies=%d->%d "
		% [a_cash_before, world.farm.economy_cash(PLAYER_A),
			a_supplies_before, _supplies(world, PLAYER_A)]
		+ "recovery_cost=%d attacker_net=%d"
		% [taken_cash + taken_supplies, spoils - supply_cost])


## 4. Repeated raids on the same target: 50 + 50 reaches the fixed 100 target
## cap; a third raid is refused by `target_cap` and changes nothing.
func _test_repeated_raids_stop_at_target_cap() -> void:
	var world: HeadlessWorld = _open("target-cap")
	_setup_war(world, "cap", true, 500, 500, START + 3600.0)
	_seed_actor(world, PLAYER_A, {"greens": 300})
	_seed_actor(world, PLAYER_B, {"greens": 200})
	_recruit(world, PLAYER_B, B_UNIT, 10)
	expect_ok(world.farm.economy_pay("cap-fund-a", PLAYER_B, PLAYER_A, 100, START),
		"The defender funds the attacker once")
	_recruit(world, PLAYER_A, "cap-a-1", 50)
	_recruit(world, PLAYER_A, "cap-a-2", 50)
	_recruit(world, PLAYER_A, "cap-a-3", 10)
	expect_ok(world.save(), "The target-cap fixture is persisted")

	var first: Dictionary = _engage(world, "cap-raid-1", PLAYER_A, PLAYER_B,
		["cap-a-1"], [B_UNIT], false)
	var second: Dictionary = _engage(world, "cap-raid-2", PLAYER_A, PLAYER_B,
		["cap-a-2"], [B_UNIT], false)
	_expect(bool(first.get("ok", false)) and int(first.outcome.target_lost_after) == 50,
		"The first raid records 50 target loss")
	_expect(bool(second.get("ok", false)) and int(second.outcome.target_lost_after) == 100,
		"The second raid reaches the 100 target cap")
	_expect(_target_lost(world.conflicts_view(), PLAYER_B) == 100,
		"The target view shows the full cap")

	var before: Dictionary = _files(world)
	var a_supplies: int = _supplies(world, PLAYER_A)
	var b_supplies: int = _supplies(world, PLAYER_B)
	var third: Dictionary = _engage(world, "cap-raid-3", PLAYER_A, PLAYER_B,
		["cap-a-3"], [B_UNIT], false)
	_expect(not bool(third.get("ok", false))
			and str(third.get("reason", "")) == "target_cap",
		"A third raid on a capped target is refused with target_cap")
	_expect(_files(world) == before,
		"A target-cap refusal changes no rule document")
	_expect(_supplies(world, PLAYER_A) == a_supplies \
			and _supplies(world, PLAYER_B) == b_supplies,
		"A target-cap refusal charges no supply cost or loss")
	_expect(_unit_people(world, "cap-a-3") == 10,
		"A target-cap refusal leaves the unspent unit intact")

	print("MEASURE repeated target=%s raid1_loss=%d raid2_loss=%d target_lost_after=%d "
		% [PLAYER_B, int(first.outcome.losses), int(second.outcome.losses),
			_target_lost(world.conflicts_view(), PLAYER_B)]
		+ "third_reason=%s assets_unchanged=%s"
		% [str(third.get("reason", "")), str(_files(world) == before)])


## 5. A withdrawal is a delay, not an instant exit. Record the authority's real
## behavior before and at/after the effective time instead of assuming it.
func _test_withdrawal_delay() -> void:
	var window_end: float = START + 7200.0
	var world: HeadlessWorld = _open("withdraw-delay")
	_setup_war(world, "wd", true, 500, 100, window_end)
	_seed_actor(world, PLAYER_A, {"greens": 100})
	_seed_actor(world, PLAYER_B, {"greens": 100})
	_recruit(world, PLAYER_A, A_UNIT, 10)
	_recruit(world, PLAYER_A, A_UNIT_2, 10)
	_recruit(world, PLAYER_B, B_UNIT, 5)
	expect_ok(world.save(), "The withdrawal fixture is persisted")

	var withdrawn: Dictionary = world.execute_participation("withdraw", PLAYER_B, {},
		"wd-withdraw-b")
	_expect(bool(withdrawn.get("ok", false)), "The defender's withdrawal notice is accepted")
	var effective: float = _withdraw_effective(world, PLAYER_B)
	_expect(effective > 0.0, "The participation view exposes the effective time")
	var now_before: float = world.authority_now_utc()
	var remaining: float = minf(window_end, effective) - now_before
	_expect(remaining > 0.0 and now_before < effective,
		"The withdrawal is still inside its delay window")

	var before: Dictionary = _files(world)
	var stocks_before: Dictionary = _stocks(world, [PLAYER_A, PLAYER_B])
	var during: Dictionary = _engage(world, "wd-during", PLAYER_A, PLAYER_B,
		[A_UNIT], [B_UNIT], true)
	_expect(bool(during.get("ok", false)),
		"During the withdrawal delay the defender is still attackable")
	var during_loss: int = int((during.get("outcome", {}) as Dictionary).get("losses", 0))

	# Move the authoritative clock to just after the effective time; the declared
	# window still contains it, so a refusal here can only come from the withdrawal.
	world.now_utc = effective + 1.0
	world._session_started_ms = 0
	var before_after: Dictionary = _files(world)
	var stocks_after: Dictionary = _stocks(world, [PLAYER_A, PLAYER_B])
	var later: Dictionary = _engage(world, "wd-after", PLAYER_A, PLAYER_B,
		[A_UNIT_2], [B_UNIT], true)
	_expect(not bool(later.get("ok", false))
			and str(later.get("reason", "")) == "no_consent",
		"At/after the effective time an attack on the withdrawn defender is refused")
	_expect(_files(world) == before_after,
		"The post-withdrawal refusal changes no rule document")
	_expect(_stocks(world, [PLAYER_A, PLAYER_B]) == stocks_after,
		"The post-withdrawal refusal changes no asset")
	_expect(_files(world) != before or during_loss > 0,
		"The in-delay engagement was a real settlement, not a silent refusal")

	print("MEASURE withdraw defender=%s delay_seconds=%d remaining_window_seconds=%.0f "
		% [PLAYER_B, int(Participation.WITHDRAWAL_DELAY_SECONDS), remaining]
		+ "during_ok=%s during_loss=%d after_ok=%s after_reason=%s "
		% [str(bool(during.get("ok", false))), during_loss,
			str(bool(later.get("ok", false))), str(later.get("reason", ""))]
		+ "stocks_unchanged_after=%s"
		% str(_stocks(world, [PLAYER_A, PLAYER_B]) == stocks_after))


## 6. A weak organization: its account, public fund and public works document are
## never part of the settlement; only the targeted player's own assets move.
func _test_weak_organization() -> void:
	var world: HeadlessWorld = _open("weak-org")
	_setup_war(world, "org", true, 500, 100, START + 3600.0)
	_seed_actor(world, PLAYER_A, {"greens": 100})
	_seed_actor(world, PLAYER_B, {"greens": 50})
	_seed_actor(world, PLAYER_C, {"greens": 40})
	_recruit(world, PLAYER_A, A_UNIT, 10)
	_recruit(world, PLAYER_B, B_UNIT, 5)

	expect_ok(world.execute_organization("create", PLAYER_B, {
		"org_id": ORG, "name": "河岸合作社", "command_id": "org-create",
	}, "org-create"), "The weak organization is created by the target")
	var fund_id: String = PublicFund.fund_for(ORG)
	expect_ok(world.execute_fund("open", PLAYER_B, {
		"org_id": ORG, "command_id": "org-fund-open",
	}, "org-fund-open"), "The target opens the organization fund")
	expect_ok(world.execute_fund("contribute", PLAYER_B, {
		"fund_id": fund_id, "amount": 30, "command_id": "org-fund-pay",
	}, "org-fund-pay"), "The target contributes real cash to the fund")
	expect_ok(world.execute_public_works("open", PLAYER_B, {
		"project_id": PROJECT, "kind": PublicWorks.KIND_PUBLIC_WELL,
		"parcel_id": "", "command_id": "org-pw-open",
	}, "org-pw-open"), "A public works document exists for the organization")
	expect_ok(world.save(), "The weak-organization fixture is persisted")

	var org_account: String = PublicFund.account_for(ORG)
	var org_cash_before: int = world.farm.economy_cash(org_account)
	var fund_balance_before: int = _fund_balance(world, fund_id)
	var works_before: String = _text(world.directory.path_join("public_works.json"))
	var b_cash_before: int = world.farm.economy_cash(PLAYER_B)
	var b_supplies_before: int = _supplies(world, PLAYER_B)
	var c_stocks_before: Dictionary = _stocks(world, [PLAYER_C])
	_expect(org_cash_before == 30, "The organization account really holds 30 cash")
	_expect(fund_balance_before == org_cash_before,
		"The fund balance equals the organization account cash")

	var result: Dictionary = _engage(world, "org-raid", PLAYER_A, PLAYER_B,
		[A_UNIT], [B_UNIT], true)
	_expect(bool(result.get("ok", false)), "The organization member is attackable")
	if not bool(result.get("ok", false)):
		print("MEASURE weak_org refused reason=%s" % str(result.get("reason", "")))
		return
	var outcome: Dictionary = result.get("outcome", {})
	var taken_cash: int = int(outcome.get("taken_cash", 0))
	var taken_supplies: int = int(outcome.get("taken_supplies", 0))

	_expect(world.farm.economy_cash(org_account) == org_cash_before,
		"The organization account cash is not frozen or transferred")
	_expect(_fund_balance(world, fund_id) == fund_balance_before,
		"The public fund balance is unchanged")
	_expect(_text(world.directory.path_join("public_works.json")) == works_before,
		"The public works document is byte-identical")
	_expect(world.farm.economy_cash(PLAYER_B) == b_cash_before - taken_cash \
			and _supplies(world, PLAYER_B) == b_supplies_before - taken_supplies,
		"Only the target player's own cash and supplies settle")
	_expect(_stocks(world, [PLAYER_C]) == c_stocks_before,
		"An uninvolved third player's cash and supplies are unchanged")
	_expect(world.farm.economy_total_cash() == world.farm.economy_issued(),
		"The organization battle keeps cash conservation")

	print("MEASURE weak_org org=%s org_account_cash=%d->%d fund_balance=%d->%d "
		% [ORG, org_cash_before, world.farm.economy_cash(org_account),
			fund_balance_before, _fund_balance(world, fund_id)]
		+ "public_works_unchanged=%s target_cash=%d->%d target_supplies=%d->%d "
		% [str(_text(world.directory.path_join("public_works.json")) == works_before),
			b_cash_before, world.farm.economy_cash(PLAYER_B),
			b_supplies_before, _supplies(world, PLAYER_B)]
		+ "taken_cash=%d taken_supplies=%d uninvolved_unchanged=%s"
		% [taken_cash, taken_supplies, str(_stocks(world, [PLAYER_C]) == c_stocks_before)])


## 7. An attacker with units but no expedition supplies. The authority must
## refuse before touching any asset.
func _test_attacker_without_supplies() -> void:
	var world: HeadlessWorld = _open("no-supply")
	_setup_war(world, "sup", true, 500, 100, START + 3600.0)
	# Recruiting consumes 1 supply per militia, so seed exactly the recruitment
	# cost and leave the attacker with zero expedition supplies.
	_seed_actor(world, PLAYER_A, {"greens": 10})
	_seed_actor(world, PLAYER_B, {"greens": 50})
	_recruit(world, PLAYER_A, A_UNIT, 10)
	_recruit(world, PLAYER_B, B_UNIT, 5)
	_expect(_supplies(world, PLAYER_A) == 0,
		"The attacker has no supplies left after recruiting")
	expect_ok(world.save(), "The no-supply fixture is persisted")

	var before: Dictionary = _files(world)
	var stocks_before: Dictionary = _stocks(world, [PLAYER_A, PLAYER_B])
	var result: Dictionary = _engage(world, "no-supply-raid", PLAYER_A, PLAYER_B,
		[A_UNIT], [B_UNIT], true)
	var reason: String = str(result.get("reason", ""))
	_expect(not bool(result.get("ok", false)) and reason == "insufficient_supply",
		"An unsupplied attacker is refused with insufficient_supply")
	_expect(_files(world) == before,
		"The supply refusal changes no rule document")
	_expect(_stocks(world, [PLAYER_A, PLAYER_B]) == stocks_before,
		"The supply refusal changes no asset")

	print("MEASURE supply refused_reason=%s files_unchanged=%s assets_unchanged=%s"
		% [reason, str(_files(world) == before),
			str(_stocks(world, [PLAYER_A, PLAYER_B]) == stocks_before)])


## 8. Homestead/building ownership is not a conflict resource. The authority may
## freeze cash/supplies only; land and buildings keep their owner.
func _test_homestead_and_buildings_untouched() -> void:
	var world: HeadlessWorld = _open("homestead")
	_setup_war(world, "home", true, 500, 100, START + 3600.0)
	_seed_actor(world, PLAYER_A, {"greens": 100})
	_seed_actor(world, PLAYER_B, {"greens": 50})
	_recruit(world, PLAYER_A, A_UNIT, 10)
	_recruit(world, PLAYER_B, B_UNIT, 5)
	expect_ok(world.claim_territory("parcel_01", PLAYER_B, "home-claim"),
		"The defender claims a homestead parcel")
	expect_ok(world.farm.build("yard_a", "cottage", START, PLAYER_B),
		"The defender builds a cottage on the homestead")
	expect_ok(world.save(), "The homestead fixture is persisted")

	var territory_before: String = _text(world.directory.path_join("territory.json"))
	var buildings_before: Dictionary = _buildings(world)
	var stable_before: Dictionary = _stable_farm(world)
	_expect(_parcel_owner(world, "parcel_01") == PLAYER_B,
		"The parcel starts owned by the defender")
	_expect(str((buildings_before.get("yard_a", {}) as Dictionary).get("owner", "")) \
			== PLAYER_B, "The cottage starts owned by the defender")

	var result: Dictionary = _engage(world, "home-raid", PLAYER_A, PLAYER_B,
		[A_UNIT], [B_UNIT], true)
	_expect(bool(result.get("ok", false)), "The homestead owner is attackable")
	if not bool(result.get("ok", false)):
		print("MEASURE homestead refused reason=%s" % str(result.get("reason", "")))
		return

	_expect(_text(world.directory.path_join("territory.json")) == territory_before,
		"The territory document is byte-identical after the engagement")
	_expect(_parcel_owner(world, "parcel_01") == PLAYER_B,
		"The homestead parcel is not transferred")
	_expect(_buildings(world) == buildings_before,
		"The farm buildings table is unchanged")
	_expect(str((_buildings(world).get("yard_a", {}) as Dictionary).get("owner", "")) \
			== PLAYER_B, "The cottage keeps its owner")
	# Full farm snapshot minus the only two fields the settlement may touch
	# (economy ledger and goods bags): fields, layout, buildings, animals and all
	# other state must be identical.
	_expect(_stable_farm(world) == stable_before,
		"The farm snapshot without economy/bags is unchanged, so no land or building moved")

	print("MEASURE homestead parcel_owner=%s building_owner=%s territory_unchanged=%s "
		% [_parcel_owner(world, "parcel_01"),
			str((_buildings(world).get("yard_a", {}) as Dictionary).get("owner", "")),
			str(_text(world.directory.path_join("territory.json")) == territory_before)]
		+ "farm_unchanged_except_economy_and_bags=%s"
		% str(_stable_farm(world) == stable_before))


# --- fixtures -------------------------------------------------------------

func _open(name: String) -> HeadlessWorld:
	var directory: String = _dir(name)
	DirAccess.make_dir_recursive_absolute(directory)
	var world: HeadlessWorld = HeadlessWorld.new()
	var opened: Dictionary = world.open(directory, START, WORLD, PLAYER_A)
	_expect(bool(opened.get("ok", false)),
		"The authority opens %s (%s)" % [name, str(opened.get("reason", ""))])
	# Freeze the authority clock at START so fixture timestamps are deterministic.
	world._session_started_ms = 0
	return world


func _declare_peace(world: HeadlessWorld) -> void:
	var declaration: Dictionary = {
		"tier": Participation.TIER_PEACE,
		"declaration_id": "peace-1",
		"effective_utc": START,
		"higher_risk": false,
		"areas": [],
		"windows": [],
		"loss_cap": 0,
		"offline_loss_cap": 0,
	}
	expect_ok(world.execute_participation("regime", PLAYER_A,
		{"declaration": declaration}, "peace-regime"),
		"The host explicitly declares the peace regime")


func _setup_war(world: HeadlessWorld, prefix: String, defender_consent: bool,
		loss_cap: int, offline_cap: int, window_end: float) -> void:
	var declaration: Dictionary = {
		"tier": Participation.TIER_LIMITED,
		"declaration_id": prefix + "-decl",
		"effective_utc": START,
		"higher_risk": true,
		"areas": [AREA_A],
		"windows": [{
			"id": "window_a", "start_utc": START - 60.0, "end_utc": window_end,
		}],
		"loss_cap": loss_cap,
		"offline_loss_cap": offline_cap,
	}
	expect_ok(world.execute_participation("regime", PLAYER_A,
		{"declaration": declaration}, prefix + "-regime"),
		"The host declares a limited regime (%s)" % prefix)
	expect_ok(world.execute_participation("declare", PLAYER_A,
		{"role": "attacker"}, prefix + "-consent-a"),
		"The attacker consents (%s)" % prefix)
	if defender_consent:
		expect_ok(world.execute_participation("declare", PLAYER_B,
			{"role": "defender"}, prefix + "-consent-b"),
			"The defender consents (%s)" % prefix)


func _seed_actor(world: HeadlessWorld, player: String, goods: Dictionary) -> void:
	if not world.farm.economy_granted(player):
		expect_ok(world.farm.economy_open_account("seed-account-" + player, player, START),
			"%s has a real cash account" % player)
	var data: Dictionary = world.farm.snapshot()
	var bags_value: Variant = data.get("bags")
	var bags: Dictionary = bags_value if bags_value is Dictionary else {}
	var pocket: Dictionary = {}
	for good_id: String in goods:
		pocket[good_id] = int(goods[good_id])
	bags[player] = pocket
	data["bags"] = bags
	var candidate: RefCounted = world.farm.copy()
	_expect(candidate.restore_snapshot(data), "%s has a valid seeded farm" % player)
	world.farm.accept(candidate)


func _recruit(world: HeadlessWorld, player: String, unit_id: String, people: int) -> void:
	var result: Dictionary = world.execute_unit("recruit", player, {
		"kind": "militia", "people": people, "equipment": "none",
		"station": "farm_a", "command_id": unit_id,
	}, unit_id)
	expect_ok(result, "Recruit %s for %s (%s)" % [
		unit_id, player, str(result.get("reason", ""))])


func _engage(world: HeadlessWorld, command_id: String, attacker: String,
		defender: String, attacker_units: Array, defender_units: Array,
		defender_online: bool, x: int = 2, z: int = 2) -> Dictionary:
	return world.execute_conflict("engage", attacker, {
		"command_id": command_id,
		"defender": defender,
		"attacker_units": attacker_units,
		"defender_units": defender_units,
		"x": x, "z": z,
	}, command_id, defender_online)


# --- observations ---------------------------------------------------------

func _supplies(world: HeadlessWorld, player: String) -> int:
	var goods: Dictionary = world.farm.economy_goods(player)
	var total: int = 0
	for good_id: String in EconomyCatalog.goods_ids():
		total += int(goods.get(good_id, 0))
	return total


func _stocks(world: HeadlessWorld, players: Array) -> Dictionary:
	var rows: Dictionary = {}
	for value: Variant in players:
		var player: String = str(value)
		rows[player] = {
			"cash": world.farm.economy_cash(player),
			"supplies": _supplies(world, player),
		}
	return rows


func _unit_people(world: HeadlessWorld, unit_id: String) -> int:
	var value: Variant = world.units.get("units", {})
	if value is Dictionary and (value as Dictionary).has(unit_id):
		return int((value as Dictionary)[unit_id].get("people", 0))
	return 0


func _target_lost(view: Dictionary, target: String) -> int:
	var rows: Variant = view.get("targets", [])
	if not rows is Array:
		return 0
	for value: Variant in rows:
		if value is Dictionary and str((value as Dictionary).get("target", "")) == target:
			return int((value as Dictionary).get("lost", 0))
	return 0


static func _loss_amount(rows: Array, target: String) -> int:
	for value: Variant in rows:
		if value is Dictionary and str((value as Dictionary).get("target", "")) == target:
			return int((value as Dictionary).get("amount", 0))
	return 0


func _withdraw_effective(world: HeadlessWorld, player: String) -> float:
	var rows: Variant = world.participation_view().get("participants", [])
	if rows is Array:
		for value: Variant in rows:
			if value is Dictionary \
					and str((value as Dictionary).get("participant", "")) == player:
				return float((value as Dictionary).get("withdraw_effective_utc", 0.0))
	return 0.0


func _fund_balance(world: HeadlessWorld, fund_id: String) -> int:
	var rows: Variant = world.funds_view().get("funds", [])
	if rows is Array:
		for value: Variant in rows:
			if value is Dictionary \
					and str((value as Dictionary).get("fund_id", "")) == fund_id:
				return int((value as Dictionary).get("balance", -1))
	return -1


func _parcel_owner(world: HeadlessWorld, parcel_id: String) -> String:
	var parcels: Variant = world.territory_view().get("parcels", {})
	if parcels is Dictionary and (parcels as Dictionary).has(parcel_id):
		return str(((parcels as Dictionary)[parcel_id] as Dictionary).get("owner", ""))
	return ""


func _buildings(world: HeadlessWorld) -> Dictionary:
	var value: Variant = world.farm.snapshot().get("buildings", {})
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}


## Everything the settlement is not allowed to touch. `economy` carries the cash
## ledger and `bags` carries the goods pockets; those are the rule's freeze path.
func _stable_farm(world: HeadlessWorld) -> Dictionary:
	var data: Dictionary = world.farm.snapshot()
	data.erase("economy")
	data.erase("bags")
	return data


func _files(world: HeadlessWorld) -> Dictionary:
	var directory: String = world.directory
	return {
		"farm": _text(directory.path_join("farm.json")),
		"units": _text(directory.path_join("units.json")),
		"participation": _text(directory.path_join("participation.json")),
		"conflicts": _text(directory.path_join("conflicts.json")),
		"territory": _text(directory.path_join("territory.json")),
		"public_funds": _text(directory.path_join("public_funds.json")),
		"public_works": _text(directory.path_join("public_works.json")),
	}


func _dir(name: String) -> String:
	return root_dir.path_join(name)


func _text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func expect_ok(result: Dictionary, message: String) -> void:
	_expect(bool(result.get("ok", false)),
		message + ("" if bool(result.get("ok", false))
			else " (reason: %s)" % str(result.get("reason", ""))))


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + message)
	print(("PASS " if condition else "FAIL ") + message)
