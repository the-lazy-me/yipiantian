extends SceneTree
## M13-01 extended authority chain: one real `HeadlessWorld`, one fixed seed and
## one logical clock, joining the participation, conflict, public-fund and
## public-works links that `chain_integration_test.gd` does not cover.
##
##   account grants -> sow/harvest real crops -> recruit real units (cash and
##   supplies leave the bags) -> limited participation regime -> both sides
##   consent -> one legal engagement (real cash take/spoils, unit losses,
##   destroyed conservation) -> organization + public fund (real contributions)
##   -> project open/pledge -> build paid out of the fund into `@world`.
##
## Every phase checks that the previous phase's assets landed where the rules
## say, that `total_cash == issued`, and that each cash movement has a ledger
## entry (opening grant, recruit, conflict take/spoil, fund contribution,
## project spend) while the conflict also has an authoritative outcome. The
## chain restarts and verifies the participation/conflict/unit/fund/project
## documents and balances; same command ids then replay without paying spoils or
## spending a second time. Refusal paths and one injected farm-save failure are
## asserted to leave every file byte-identical.
##
## No UI, network transport, Windows path or real wall clock is exercised.

const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const Participation = preload("res://conflict/participation_state.gd")
const ConflictSettlement = preload("res://world/conflict_settlement.gd")
const PublicFund = preload("res://world/public_fund.gd")
const PublicWorks = preload("res://world/public_works.gd")
const Economy = preload("res://farm/economy_state.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")
const Ledger = preload("res://farm/ledger_state.gd")

const SEED: int = 101507
const RULES_VERSION: int = 2
const START: float = 1800014400.0
const T_HARVEST: float = START + 7200.0
const T_EFFECTIVE: float = START + 11000.0
const WINDOW_END: float = START + 86400.0
const WORLD_ID: String = "chain-conflict-world"
const HOST: String = "chain_a"
const A: String = "chain_a"
const B: String = "chain_b"
const GREENS: String = "greens"
const ORG: String = "guild_works"
const PROJECT: String = "road_01"
const UNIT_A: String = "chain-a-unit"
const UNIT_B: String = "chain-b-unit"
const BATTLE_ID: String = "chain-battle"
const BUILD_ID: String = "chain-build"
const A_PEOPLE: int = 12
const B_PEOPLE: int = 10
## The declared limited-regime budget leaves the attacker unit alive: 12 troops
## lose 8 people and survive with 4.
const LOSS_CAP: int = 8
const OFFLINE_CAP: int = 4
const AREA: Dictionary = {
	"id": "area_a", "min_x": 0, "min_z": 0, "max_x": 5, "max_z": 5,
}
const WINDOW: Dictionary = {
	"id": "window_a", "start_utc": START, "end_utc": WINDOW_END,
}

var checks: int = 0
var failures: Array[String] = []
var test_root: String = ""
var world: RefCounted
var reopened: RefCounted
var a_cells: Array = []
var b_cells: Array = []
var battle_args: Dictionary = {}
var build_args: Dictionary = {}
var fund_id: String = ""
var org_account: String = ""


## Simulates an I/O failure on the farm document without touching the file.
class FailingFarmStore extends "res://farm/farm_store.gd":
	func save_state(_farm, _decorations) -> Dictionary:
		return {"ok": false, "kind": "io"}


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	# Required per-process parent plus a unique child so a reused PID can never
	# inherit a previous run's saves.
	test_root = project_root.get_base_dir().path_join(
		".local/verification/chain-conflict-integration-%d/run-%d"
		% [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(test_root)
	_run_chain()
	for failure: String in failures:
		push_error(failure)
	print("CHAIN_CONFLICT_INTEGRATION_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run_chain() -> void:
	_boot()
	_phase_accounts_harvest_recruit()
	_phase_participation()
	_phase_engagement()
	_phase_public_works()
	_phase_traceability()
	_phase_restart()
	_phase_refusals()


# ---------------------------------------------------------------------------
# Boot: fixed seed, fresh world, host identity, empty economy.
# ---------------------------------------------------------------------------

func _boot() -> void:
	_phase("boot")
	var saved: Dictionary = NatureStore.new(test_root).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	_expect(bool(saved.ok), "fixture: the fixed seed is persisted before the world opens")
	world = HeadlessWorld.new()
	var opened: Dictionary = world.open(test_root, START, WORLD_ID, HOST)
	_expect(bool(opened.get("ok", false)), "boot: the authority opens the world")
	_expect(str(opened.get("kind", "")) == "created", "boot: the directory starts as a fresh world")
	_expect(world.nature.get_seed() == SEED, "boot: the fresh farm adopts the persisted seed")
	_expect(str(world.world_id) == WORLD_ID, "boot: the cadastre carries the requested world id")
	_expect(is_equal_approx(world.now_utc, START), "boot: the logical clock starts at the fixed UTC")
	_expect(world.farm.field_ids().size() == 6, "boot: the default layout has six fields")
	_expect(not world.participation.is_empty(), "boot: the hosted room has a participation document")
	_expect(Participation.valid(world.participation), "boot: the default participation document is valid")
	_expect(str(world.participation.get("host", "")) == HOST, "boot: the room host is the fixed player")
	_expect(str(world.participation_view().regime.tier) == Participation.TIER_PEACE,
		"boot: the room starts in peace")
	_expect(world.farm.economy_issued() == 0 and world.farm.economy_total_cash() == 0,
		"boot: no money has been issued yet")
	_expect(world.units_view().units.is_empty(), "boot: the unit roster starts empty")

	build_plan()


func build_plan() -> void:
	# 34 of the ready default cells: A owns 24, B owns 10. `cell_06` in fields
	# 03-06 starts with a decorative crop and field_06's upper cells start rough,
	# so the plan deliberately avoids them. This exactly funds the recruitment
	# supply bill plus A's attack cost.
	for field_index: int in [1, 2]:
		for cell_index: int in range(1, 7):
			a_cells.append({"field": "field_%02d" % field_index, "cell": "cell_%02d" % cell_index})
	for field_index: int in [3, 4]:
		for cell_index: int in range(1, 6):
			a_cells.append({"field": "field_%02d" % field_index, "cell": "cell_%02d" % cell_index})
	for cell_index: int in [1, 2]:
		a_cells.append({"field": "field_05", "cell": "cell_%02d" % cell_index})
	for cell_index: int in [3, 4, 5]:
		b_cells.append({"field": "field_05", "cell": "cell_%02d" % cell_index})
	for cell_index: int in range(1, 6):
		b_cells.append({"field": "field_06", "cell": "cell_%02d" % cell_index})
	for cell_index: int in [7, 8]:
		b_cells.append({"field": "field_06", "cell": "cell_%02d" % cell_index})


# ---------------------------------------------------------------------------
# Link 1: real accounts, real crops, real recruits.
# ---------------------------------------------------------------------------

func _phase_accounts_harvest_recruit() -> void:
	_phase("accounts_harvest_recruit")
	var account_a: Dictionary = FarmCommand.make_account_open("chain-account-a", START)
	_execute(account_a, A, "A opens a real account")
	_expect(world.farm.economy_cash(A) == 120, "account: A receives the 120 COIN opening grant")
	var account_b: Dictionary = FarmCommand.make_account_open("chain-account-b", START)
	_execute(account_b, B, "B opens a real account")
	_expect(world.farm.economy_cash(B) == 120, "account: B receives the 120 COIN opening grant")
	_expect(world.farm.economy_issued() == 240, "account: the two grants issue exactly 240 COIN")
	_expect(world.farm.economy_total_cash() == 240, "account: all issued cash is in the two accounts")
	_check_cash("accounts opened")

	var sow_index: int = 0
	for plan: Dictionary in a_cells:
		sow_index += 1
		var command: Dictionary = FarmCommand.make_sow(
			"chain-sow-a-%02d" % sow_index, plan.field, plan.cell, GREENS, START)
		_execute(command, A, "A sows %s/%s" % [plan.field, plan.cell])
		var cell: Dictionary = world.farm.get_cell(plan.field, plan.cell)
		_expect(str(cell.crop_id) == GREENS and str(cell.planted_by) == A,
			"sow: A owns the crop in %s/%s" % [plan.field, plan.cell])
	sow_index = 0
	for plan: Dictionary in b_cells:
		sow_index += 1
		var command: Dictionary = FarmCommand.make_sow(
			"chain-sow-b-%02d" % sow_index, plan.field, plan.cell, GREENS, START)
		_execute(command, B, "B sows %s/%s" % [plan.field, plan.cell])
		var cell: Dictionary = world.farm.get_cell(plan.field, plan.cell)
		_expect(str(cell.crop_id) == GREENS and str(cell.planted_by) == B,
			"sow: B owns the crop in %s/%s" % [plan.field, plan.cell])

	var advanced: Dictionary = world.advance_to(T_HARVEST)
	_expect(bool(advanced.get("ok", false)), "growth: the world advances two hours")
	_expect(int(advanced.get("segments", 0)) > 0, "growth: advancement stops on growth boundaries")
	var mature: int = 0
	for plan: Dictionary in a_cells + b_cells:
		if str(world.farm.get_cell(plan.field, plan.cell).stage) == "mature":
			mature += 1
	_expect(mature == a_cells.size() + b_cells.size(),
		"growth: all %d greens mature" % (a_cells.size() + b_cells.size()))

	var harvest_index: int = 0
	for plan: Dictionary in a_cells:
		harvest_index += 1
		var command: Dictionary = FarmCommand.make(
			"chain-harvest-a-%02d" % harvest_index, plan.field, plan.cell, T_HARVEST)
		var result: Dictionary = _execute(command, A, "A harvests %s/%s" % [plan.field, plan.cell])
		_expect(str(result.get("reward_crop_id", "")) == GREENS
			and int(result.get("reward_amount", 0)) == 1,
			"harvest: A receives one greens basket")
	harvest_index = 0
	for plan: Dictionary in b_cells:
		harvest_index += 1
		var command: Dictionary = FarmCommand.make(
			"chain-harvest-b-%02d" % harvest_index, plan.field, plan.cell, T_HARVEST)
		var result: Dictionary = _execute(command, B, "B harvests %s/%s" % [plan.field, plan.cell])
		_expect(str(result.get("reward_crop_id", "")) == GREENS
			and int(result.get("reward_amount", 0)) == 1,
			"harvest: B receives one greens basket")

	_expect(_goods_of(A, GREENS) == a_cells.size(),
		"harvest: A's own bag holds %d greens" % a_cells.size())
	_expect(_goods_of(B, GREENS) == b_cells.size(),
		"harvest: B's own bag holds %d greens" % b_cells.size())
	_expect(int(world.farm.snapshot().harvested.get(GREENS, 0))
		== a_cells.size() + b_cells.size(),
		"harvest: the produced counter records every basket")
	_expect(_supplies(A) + _supplies(B) == a_cells.size() + b_cells.size(),
		"harvest: the world holds exactly the harvested supplies")

	var recruit_a: Dictionary = world.execute_unit("recruit", A, {
		"kind": "militia", "people": A_PEOPLE, "equipment": "none",
		"station": "farm_a", "command_id": UNIT_A,
	}, UNIT_A)
	_expect(bool(recruit_a.get("ok", false)), "recruit: A's militia is accepted")
	_expect(str(recruit_a.get("unit_id", "")) == UNIT_A, "recruit: the unit id is the command id")
	var recruit_b: Dictionary = world.execute_unit("recruit", B, {
		"kind": "militia", "people": B_PEOPLE, "equipment": "none",
		"station": "farm_b", "command_id": UNIT_B,
	}, UNIT_B)
	_expect(bool(recruit_b.get("ok", false)), "recruit: B's militia is accepted")

	_expect(world.farm.economy_cash(A) == 96, "recruit: A paid 24 COIN (12 x 2)")
	_expect(world.farm.economy_cash(B) == 100, "recruit: B paid 20 COIN (10 x 2)")
	_expect(world.farm.economy_cash(Economy.WORLD_OWNER) == 44,
		"recruit: both payments landed in the public treasury")
	_expect(_supplies(A) == 24 - A_PEOPLE, "recruit: A's bag keeps 12 supplies for the march")
	_expect(_supplies(B) == 0, "recruit: B's bag is emptied by the recruitment")
	_expect(_unit_people(UNIT_A) == A_PEOPLE, "recruit: A's unit has 12 people")
	_expect(_unit_people(UNIT_B) == B_PEOPLE, "recruit: B's unit has 10 people")
	_expect(world.units_view().units.size() == 2, "recruit: the roster holds both units")
	var unit_command_a: Dictionary = world.units["commands"][UNIT_A]
	var unit_command_b: Dictionary = world.units["commands"][UNIT_B]
	_expect(int(unit_command_a["result"]["cost"]["cash"]) == 24
		and int(unit_command_a["result"]["cost"]["supplies"]) == A_PEOPLE,
		"recruit: A's unit record traces the 24 COIN and 12 supply cost")
	_expect(int(unit_command_b["result"]["cost"]["cash"]) == 20
		and int(unit_command_b["result"]["cost"]["supplies"]) == B_PEOPLE,
		"recruit: B's unit record traces the 20 COIN and 10 supply cost")
	_check_cash("units recruited")
	_check_goods("units recruited", a_cells.size() + b_cells.size() - 22)


# ---------------------------------------------------------------------------
# Link 2: limited regime, consents, and one legal engagement.
# ---------------------------------------------------------------------------

func _phase_participation() -> void:
	_phase("participation")
	var declaration: Dictionary = {
		"tier": Participation.TIER_LIMITED,
		"declaration_id": "chain-declaration",
		"effective_utc": T_EFFECTIVE,
		"higher_risk": true,
		"areas": [AREA.duplicate(true)],
		"windows": [WINDOW.duplicate(true)],
		"loss_cap": LOSS_CAP,
		"offline_loss_cap": OFFLINE_CAP,
	}
	var regime: Dictionary = world.execute_participation("regime", HOST,
		{"declaration": declaration}, "chain-regime")
	_expect(bool(regime.get("ok", false)), "regime: the host declares a limited regime")
	_expect(not bool(regime.get("duplicate", true)), "regime: the declaration is new work")
	var view: Dictionary = world.participation_view()
	_expect(str(view.regime.tier) == Participation.TIER_LIMITED, "regime: the view is limited")
	_expect(str(view.regime.declaration_id) == "chain-declaration",
		"regime: the declaration id is durable")
	_expect(str(view.regime.declared_by) == HOST, "regime: the host is the declarer")
	_expect(bool(view.regime.higher_risk), "regime: the declaration is explicitly higher risk")
	_expect(int(view.regime.loss_cap) == LOSS_CAP
		and int(view.regime.offline_loss_cap) == OFFLINE_CAP,
		"regime: both loss budgets are recorded")
	_expect(view.areas.size() == 1 and view.windows.size() == 1,
		"regime: one area and one window are live")
	_expect(Participation.valid(world.participation), "regime: the written document stays valid")

	var advanced: Dictionary = world.advance_to(T_EFFECTIVE)
	_expect(bool(advanced.get("ok", false)), "regime: the world reaches the effective instant")
	_expect(is_equal_approx(world.authority_now_utc(), T_EFFECTIVE),
		"regime: the authority clock is the effective instant")

	var consent_a: Dictionary = world.execute_participation("declare", A,
		{"role": Participation.ROLE_ATTACKER}, "chain-consent-a")
	_expect(bool(consent_a.get("ok", false)), "consent: A registers as attacker")
	var consent_b: Dictionary = world.execute_participation("declare", B,
		{"role": Participation.ROLE_DEFENDER}, "chain-consent-b")
	_expect(bool(consent_b.get("ok", false)), "consent: B registers as defender")
	view = world.participation_view()
	_expect(_participant(view, A).get("attacker", false)
		and not _participant(view, A).get("defender", true),
		"consent: A's durable role is attacker")
	_expect(_participant(view, B).get("defender", false)
		and not _participant(view, B).get("attacker", true),
		"consent: B's durable role is defender")
	_expect(int(_participant(view, A).get("consent_revision", 0)) == 1,
		"consent: A's consent names the live revision")


func _phase_engagement() -> void:
	_phase("engagement")
	var outside_args: Dictionary = _battle_args("chain-battle-outside", [UNIT_A], [UNIT_B], 50, 50)
	var before: Dictionary = _files(test_root)
	var outside: Dictionary = world.execute_conflict("engage", A, outside_args, "chain-battle-outside", true)
	_expect(not bool(outside.get("ok", false)) \
		and str(outside.get("reason", "")) == "invalid_participation",
		"engage: a point outside the declared area is refused (invalid_participation)")
	_expect(_files(test_root) == before, "engage: the area refusal changes no file")
	var wrong_owner_args: Dictionary = _battle_args("chain-battle-wrong-owner", [UNIT_B], [UNIT_A], 2, 2)
	var wrong_owner: Dictionary = world.execute_conflict("engage", A, wrong_owner_args,
		"chain-battle-wrong-owner", true)
	_expect(str(wrong_owner.get("reason", "")) == "not_owner",
		"engage: an attacker cannot send another player's unit")
	_expect(_files(test_root) == before, "engage: the ownership refusal changes no file")

	battle_args = _battle_args(BATTLE_ID, [UNIT_A], [UNIT_B], 2, 2)
	var cash_before_a: int = world.farm.economy_cash(A)
	var cash_before_b: int = world.farm.economy_cash(B)
	var supplies_before_a: int = _supplies(A)
	var supplies_before_b: int = _supplies(B)
	var combined_before: int = cash_before_a + supplies_before_a + cash_before_b + supplies_before_b
	var result: Dictionary = world.execute_conflict("engage", A, battle_args, BATTLE_ID, true)
	_expect(bool(result.get("ok", false)), "engage: the consented limited engagement commits")
	_expect(not bool(result.get("duplicate", true)), "engage: the engagement is new work")
	var outcome: Dictionary = result.get("outcome", {})
	_expect(str(outcome.get("window_id", "")) == "window_a",
		"engage: the settlement uses the declared window")
	_expect(int(outcome.get("troops", 0)) == A_PEOPLE,
		"engage: the troops are A's real unit people")
	_expect(int(outcome.get("losses", 0)) == LOSS_CAP,
		"engage: losses stop at the declared loss budget")
	_expect(int(outcome.get("supply_cost", 0)) == A_PEOPLE,
		"engage: the attacker pays one supply per troop")
	_expect(int(outcome.get("taken_cash", 0)) == LOSS_CAP,
		"engage: the defender's cash is taken first")
	_expect(int(outcome.get("taken_supplies", 0)) == 0,
		"engage: no supplies are taken while the defender still has cash")
	_expect(int(outcome.get("spoils_cash", 0)) == LOSS_CAP / 2,
		"engage: half of the taken cash is looted")
	_expect(int(outcome.get("spoils_supplies", 0)) == 0,
		"engage: no supply spoils are created from zero supply losses")
	_expect(int(outcome.get("destroyed", 0)) == 16,
		"engage: destroyed is supply cost plus losses minus spoils")
	_expect(int(outcome.get("target_lost_after", 0)) == LOSS_CAP,
		"engage: the per-target budget records the loss")
	_expect(int(outcome.get("target_cap", 0)) == 100,
		"engage: the per-target budget uses the authority constant")

	_expect(world.farm.economy_cash(A) == cash_before_a + LOSS_CAP / 2,
		"engage: A receives the cash spoils")
	_expect(world.farm.economy_cash(B) == cash_before_b - LOSS_CAP,
		"engage: B loses the taken cash")
	_expect(_supplies(A) == supplies_before_a - A_PEOPLE,
		"engage: A's bag pays the attack supply cost")
	_expect(_supplies(B) == supplies_before_b,
		"engage: B's supplies are untouched by a cash-only settlement")
	_expect(_unit_people(UNIT_A) == A_PEOPLE - LOSS_CAP,
		"engage: A's unit loses people and survives with 4")
	_expect(_unit_people(UNIT_B) == B_PEOPLE, "engage: B's defender unit is not reduced")
	var combined_after: int = world.farm.economy_cash(A) + _supplies(A) \
		+ world.farm.economy_cash(B) + _supplies(B)
	_expect(combined_before - combined_after == int(outcome.get("destroyed", -1)),
		"engage: the combined farm assets decrease by exactly destroyed")

	var view: Dictionary = world.participation_view()
	_expect(_loss_amount(view, B) == LOSS_CAP,
		"engage: the participation document records the durable loss")
	var conflicts: Dictionary = world.conflicts_view()
	_expect(int(_target_lost(conflicts, B)) == LOSS_CAP,
		"engage: the conflict document records the target budget")
	_expect((conflicts.recent as Array).size() == 1,
		"engage: one durable outcome is visible")
	_expect(ConflictSettlement.valid_context(world.conflicts),
		"engage: the written conflict context stays valid")
	_check_cash("engagement settled")
	_check_goods("engagement settled", 0)


# ---------------------------------------------------------------------------
# Link 3: organization, public fund, project pledge and real build spend.
# ---------------------------------------------------------------------------

func _phase_public_works() -> void:
	_phase("public_works")
	var created: Dictionary = world.execute_organization("create", A,
		{"org_id": ORG, "name": "河岸工程"}, "chain-org-create")
	_expect(bool(created.get("ok", false)), "org: A creates the organization")
	var joined: Dictionary = world.execute_organization("join", B,
		{"org_id": ORG}, "chain-org-join-b")
	_expect(bool(joined.get("ok", false)), "org: B joins the organization")
	_expect(str(world.organizations_view().organizations[0].members.get(A, "")) == "leader",
		"org: A is the leader")
	_expect(str(world.organizations_view().organizations[0].members.get(B, "")) == "member",
		"org: B is a plain member")

	fund_id = PublicFund.fund_for(ORG)
	org_account = PublicFund.account_for(ORG)
	var opened: Dictionary = world.execute_fund("open", A, {"org_id": ORG}, "chain-fund-open")
	_expect(bool(opened.get("ok", false)), "fund: A opens the organization fund")
	_expect(str(opened.get("fund_id", "")) == fund_id, "fund: the fund id is derived from the org")
	var fund: Dictionary = _fund(world.funds_view(), fund_id)
	_expect(int(fund.get("balance", -1)) == 0 and int(fund.get("spent", -1)) == 0,
		"fund: the new fund is empty")
	_expect(str(fund.get("keeper", "")) == A, "fund: A is the first keeper")

	var contribute_a: Dictionary = world.execute_fund("contribute", A,
		{"fund_id": fund_id, "amount": 60}, "chain-contribute-a")
	_expect(bool(contribute_a.get("ok", false)), "fund: A contributes 60 real COIN")
	_expect(world.farm.economy_cash(A) == 40, "fund: A's cash fell from 100 to 40")
	_expect(world.farm.economy_cash(org_account) == 60, "fund: the organization account holds 60")
	var contribute_b: Dictionary = world.execute_fund("contribute", B,
		{"fund_id": fund_id, "amount": 60}, "chain-contribute-b")
	_expect(bool(contribute_b.get("ok", false)), "fund: B contributes 60 real COIN")
	_expect(world.farm.economy_cash(B) == 32, "fund: B's cash fell from 92 to 32")
	_expect(world.farm.economy_cash(org_account) == 120,
		"fund: the organization account holds the full 120")
	_expect(int(_fund(world.funds_view(), fund_id).balance) == 120,
		"fund: the fund balance equals the real account cash")
	_check_cash("fund contributed")

	var project_open: Dictionary = world.execute_public_works("open", A, {
		"project_id": PROJECT, "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"parcel_id": "parcel_01",
	}, "chain-pw-open")
	_expect(bool(project_open.get("ok", false)), "works: the road project is registered")
	var project: Dictionary = _project(world.public_works_view(), PROJECT)
	_expect(str(project.get("status", "")) == PublicWorks.STATUS_UNBUILT
		and int(project.get("funded", -1)) == 0,
		"works: the new project is unbuilt and unfunded")
	var pledge: Dictionary = world.execute_public_works("pledge", A,
		{"project_id": PROJECT, "amount": 120}, "chain-pw-pledge")
	_expect(bool(pledge.get("ok", false)), "works: the project is pledged to its fixed cost")
	project = _project(world.public_works_view(), PROJECT)
	_expect(str(project.get("status", "")) == PublicWorks.STATUS_FUNDED
		and int(project.get("funded", -1)) == 120 and int(project.get("pledged", -1)) == 120,
		"works: the pledge reaches the 120 COIN catalog cost")
	_check_cash("project pledged")

	build_args = {"project_id": PROJECT, "fund_id": fund_id}
	var built: Dictionary = world.execute_public_works("build", A, build_args, BUILD_ID)
	_expect(bool(built.get("ok", false)), "works: the keeper builds the funded road")
	_expect(not bool(built.get("duplicate", true)), "works: the build is new work")
	_expect(world.farm.economy_cash(org_account) == 0,
		"works: the organization account pays exactly the catalog cost")
	_expect(world.farm.economy_cash(Economy.WORLD_OWNER) == 168,
		"works: the fixed cost lands in the public treasury")
	_expect(world.farm.economy_cash(A) == 40 and world.farm.economy_cash(B) == 32,
		"works: the member balances are unchanged by the build itself")
	project = _project(world.public_works_view(), PROJECT)
	_expect(str(project.get("status", "")) == PublicWorks.STATUS_BUILT,
		"works: the project is built")
	_expect(int(project.get("funded", -1)) == 120 and int(project.get("pledged", -1)) == 120,
		"works: the built project keeps its funded and pledged totals")
	_expect(float(project.get("built_utc", 0.0)) == T_EFFECTIVE,
		"works: built_utc is the authoritative spend instant")
	fund = _fund(world.funds_view(), fund_id)
	_expect(int(fund.get("balance", -1)) == 0 and int(fund.get("spent", -1)) == 120,
		"works: the fund records the 120 COIN spend")
	var history: Array = world.funds["funds"][fund_id].history
	_expect(history.size() == 1 and str(history[0].project) == PROJECT
		and int(history[0].amount) == 120,
		"works: exactly one fund history row names the project and cost")
	_expect(PublicWorks.valid(world.public_works), "works: the project document stays valid")
	_check_cash("project built")


# ---------------------------------------------------------------------------
# Link 4: every cash movement is a ledger entry or an authoritative outcome.
# ---------------------------------------------------------------------------

func _phase_traceability() -> void:
	_phase("traceability")
	_expect(world.farm.economy_issued() == 240,
		"trace: the only issuance is the two 120 COIN opening grants")
	_expect(world.farm.economy_total_cash() == 240, "trace: total cash equals issued")
	var entries: Array = world.farm.economy_ledger_entries()
	_expect(entries.size() == 9,
		"trace: nine ledger entries cover grants, recruits, conflict and works")
	_expect(_entries_of_kind(Ledger.KIND_OPEN_ACCOUNT).size() == 2,
		"trace: two opening grants have journal rows")
	_expect(_entry_amount("chain-account-a") == 120
		and _entry_amount("chain-account-b") == 120,
		"trace: both opening grants are traceable by command id")
	_expect(_entry_amount("unit_pay_" + UNIT_A) == 24
		and _entry_amount("unit_pay_" + UNIT_B) == 20,
		"trace: both recruit payments are traceable by unit command id")
	_expect(_entry_amount("conflict_take_" + BATTLE_ID) == LOSS_CAP,
		"trace: the defender cash take is a ledger entry")
	_expect(_entry_amount("conflict_spoil_" + BATTLE_ID) == LOSS_CAP / 2,
		"trace: the attacker cash spoils are a ledger entry")
	_expect(_entry_amount("fund_pay_chain-contribute-a") == 60
		and _entry_amount("fund_pay_chain-contribute-b") == 60,
		"trace: both fund contributions are ledger entries")
	_expect(_entry_amount("fund_spend_pw_spend_" + BUILD_ID) == 120,
		"trace: the public-works spend is a ledger entry")
	var reconcile: Dictionary = world.farm.economy_reconcile()
	_expect(bool(reconcile.ok), "trace: the double-entry ledger reconciles")
	_expect(int(reconcile.issuance) == 240 and int(reconcile.burned) == 0,
		"trace: issuance minus burns equals the net issue")
	_expect(int(reconcile.accounts) + int(reconcile.merchant) + int(reconcile.escrow)
		+ int(reconcile.bank) == 240,
		"trace: every cash holder sums to the issued total")
	_expect(world.farm.economy_cash(Economy.WORLD_OWNER) == 168,
		"trace: the public treasury holds the recruit, conflict and build residue")
	_expect(world.farm.economy_goods(Economy.WORLD_OWNER)[GREENS] == 0,
		"trace: the treasury holds no goods from this chain")
	_check_cash("chain complete")
	_check_goods("chain complete", 0)


# ---------------------------------------------------------------------------
# Link 5: restart keeps every document and balance; durable replays pay nothing.
# ---------------------------------------------------------------------------

func _phase_restart() -> void:
	_phase("restart")
	var live_cash: Dictionary = _cash_row()
	var saved: Dictionary = world.save()
	_expect(bool(saved.get("ok", false)), "restart: farm, nature and cadastre save together")
	reopened = HeadlessWorld.new()
	var opened: Dictionary = reopened.open(test_root, world.now_utc, WORLD_ID, HOST)
	_expect(bool(opened.get("ok", false)), "restart: the same directory reopens")
	_expect(str(opened.get("kind", "")) == "loaded", "restart: the save is loaded, not recreated")
	_expect(Participation.valid(reopened.participation),
		"restart: the participation document survives and stays valid")
	_expect(ConflictSettlement.valid_context(reopened.conflicts),
		"restart: the conflict context survives and stays valid")
	_expect(PublicWorks.valid(reopened.public_works),
		"restart: the public-works document survives and stays valid")
	_expect(reopened.nature.get_seed() == SEED, "restart: the nature seed survives")

	var participants: Dictionary = reopened.participation_view()
	_expect(str(participants.host) == HOST, "restart: the room host survives")
	_expect(str(participants.regime.tier) == Participation.TIER_LIMITED,
		"restart: the limited regime survives")
	_expect(int(participants.regime.loss_cap) == LOSS_CAP,
		"restart: the declared loss budget survives")
	_expect(_participant(participants, A).get("attacker", false)
		and _participant(participants, B).get("defender", false),
		"restart: both consents survive")
	_expect(_loss_amount(participants, B) == LOSS_CAP,
		"restart: the durable participation loss survives")

	var conflicts: Dictionary = reopened.conflicts_view()
	_expect(int(_target_lost(conflicts, B)) == LOSS_CAP,
		"restart: the target budget survives")
	_expect((conflicts.recent as Array).size() == 1,
		"restart: the settled outcome survives")
	_expect(str((conflicts.recent as Array)[0].command_id) == BATTLE_ID,
		"restart: the outcome names the original command id")

	_expect(_unit_people(UNIT_A) == A_PEOPLE - LOSS_CAP,
		"restart: the reduced attacker unit survives")
	_expect(_unit_people(UNIT_B) == B_PEOPLE, "restart: the defender unit survives")
	var fund: Dictionary = _fund(reopened.funds_view(), fund_id)
	_expect(int(fund.get("balance", -1)) == 0 and int(fund.get("spent", -1)) == 120,
		"restart: the fund balance and spend survive")
	_expect(int(fund.get("contributors", {}).get(A, -1)) == 60
		and int(fund.get("contributors", {}).get(B, -1)) == 60,
		"restart: both member contribution totals survive")
	var project: Dictionary = _project(reopened.public_works_view(), PROJECT)
	_expect(str(project.get("status", "")) == PublicWorks.STATUS_BUILT,
		"restart: the built project survives")
	_expect(float(project.get("built_utc", 0.0)) == T_EFFECTIVE,
		"restart: the authoritative build instant survives")
	_expect(_cash_row() == live_cash, "restart: every cash balance survives")
	_expect(reopened.farm.economy_total_cash() == reopened.farm.economy_issued(),
		"restart: cash conservation still holds")
	_expect(bool(reopened.farm.economy_reconcile().ok),
		"restart: the restored ledger reconciles")

	# Durable duplicate: the in-memory public-works/conflict result windows are
	# gone, so these replays must use the persisted markers.
	var files_before: Dictionary = _files(test_root)
	var cash_before: Dictionary = _cash_row()
	var replay: Dictionary = reopened.execute_conflict("engage", A, battle_args, BATTLE_ID, true)
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"restart: the same engagement id replays as a duplicate")
	_expect(not bool(replay.get("recovered", true)),
		"restart: the duplicate is not a crash recovery")
	_expect(int(int(replay.get("outcome", {}).get("spoils_cash", -1))) == LOSS_CAP / 2,
		"restart: the replay reports the original spoils outcome")
	_expect(_files(test_root) == files_before,
		"restart: the engagement replay changes no document")
	_expect(_cash_row() == cash_before,
		"restart: the engagement replay pays no second spoils or supply cost")
	_expect(_unit_people(UNIT_A) == A_PEOPLE - LOSS_CAP,
		"restart: the engagement replay does not reduce the unit again")

	var build_replay: Dictionary = reopened.execute_public_works("build", A, build_args, BUILD_ID)
	_expect(bool(build_replay.get("ok", false)) and bool(build_replay.get("duplicate", false)),
		"restart: the same build id replays as a duplicate")
	_expect(_files(test_root) == files_before,
		"restart: the build replay changes no document")
	_expect(_cash_row() == cash_before,
		"restart: the build replay spends no second time")
	_expect(reopened.funds["funds"][fund_id].history.size() == 1,
		"restart: the build replay adds no second fund history row")
	_expect(int(_fund(reopened.funds_view(), fund_id).spent) == 120,
		"restart: the fund still records exactly one 120 COIN spend")
	_check_cash("after restart")


# ---------------------------------------------------------------------------
# Link 6: refusals and an injected I/O failure never half-commit.
# ---------------------------------------------------------------------------

func _phase_refusals() -> void:
	_phase("refusals")
	var before: Dictionary = _files(test_root)
	var cash_before: Dictionary = _cash_row()

	var outside: Dictionary = reopened.execute_conflict("engage", A,
		_battle_args("chain-battle-outside-2", [UNIT_A], [UNIT_B], 50, 50),
		"chain-battle-outside-2", true)
	_expect(str(outside.get("reason", "")) == "insufficient_supply",
		"refusal: an unfed attacker is refused before any settlement (insufficient_supply)")
	_expect(_files(test_root) == before, "refusal: the unfed-attacker path changes no file")
	_expect(_cash_row() == cash_before, "refusal: the unfed-attacker path moves no cash")

	var wrong_owner: Dictionary = reopened.execute_conflict("engage", A,
		_battle_args("chain-battle-wrong-owner-2", [UNIT_B], [UNIT_A], 2, 2),
		"chain-battle-wrong-owner-2", true)
	_expect(str(wrong_owner.get("reason", "")) == "not_owner",
		"refusal: a foreign unit is refused")
	_expect(_files(test_root) == before, "refusal: the ownership path changes no file")

	var again: Dictionary = reopened.execute_public_works("build", A, build_args, "chain-build-again")
	_expect(str(again.get("reason", "")) == "already_built",
		"refusal: a built project cannot be built again")
	_expect(_files(test_root) == before, "refusal: the already-built path changes no file")
	_expect(_cash_row() == cash_before, "refusal: the already-built path moves no cash")

	# Injected farm write failure: the candidate payment is computed but the
	# farm document save fails, so no live state or file may change.
	var real_store = reopened.store
	reopened.store = FailingFarmStore.new(test_root)
	var failed: Dictionary = reopened.execute_fund("contribute", A,
		{"fund_id": fund_id, "amount": 10}, "chain-contribute-fail")
	_expect(not bool(failed.get("ok", true)) and str(failed.get("reason", "")) == "save_io",
		"refusal: an injected farm write failure is reported as save_io")
	_expect(_files(test_root) == before,
		"refusal: the failed save leaves every file byte-identical")
	_expect(_cash_row() == cash_before, "refusal: the failed save moves no cash")
	_expect(int(_fund(reopened.funds_view(), fund_id).balance) == 0,
		"refusal: the failed save leaves the fund balance untouched")
	reopened.store = real_store
	_expect(_files(test_root) == before, "refusal: restoring the store changes no file")
	_check_cash("after refusals")


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

func _phase(name: String) -> void:
	print("PHASE " + name)


func _execute(command: Dictionary, actor: String, label: String) -> Dictionary:
	var result: Dictionary = world.execute(command, actor)
	_expect(bool(result.get("ok", false)), label + ": accepted")
	_expect(str(result.get("stage", "")) == "committed", label + ": committed as new work")
	_expect(not bool(result.get("duplicate", true)), label + ": is not a duplicate")
	return result


func _battle_args(command_id: String, attacker_units: Array, defender_units: Array,
		x: int = 2, z: int = 2) -> Dictionary:
	return {
		"command_id": command_id,
		"defender": B,
		"attacker_units": attacker_units,
		"defender_units": defender_units,
		"x": x, "z": z,
	}


func _unit_people(unit_id: String) -> int:
	for row: Dictionary in world.units_view().units:
		if str(row.id) == unit_id:
			return int(row.people)
	return 0


func _goods_of(owner: String, good_id: String) -> int:
	return int(world.farm.economy_goods(owner).get(good_id, 0))


func _supplies(owner: String) -> int:
	var goods: Dictionary = world.farm.economy_goods(owner)
	var total: int = 0
	for good_id: String in EconomyCatalog.goods_ids():
		total += int(goods.get(good_id, 0))
	return total


func _participant(view: Dictionary, player: String) -> Dictionary:
	for row: Dictionary in view.get("participants", []):
		if str(row.get("participant", "")) == player:
			return row
	return {}


func _loss_amount(view: Dictionary, target: String) -> int:
	for row: Dictionary in view.get("losses", []):
		if str(row.get("target", "")) == target:
			return int(row.get("amount", 0))
	return 0


static func _target_lost(view: Dictionary, target: String) -> int:
	for row: Dictionary in view.get("targets", []):
		if str(row.get("target", "")) == target:
			return int(row.get("lost", 0))
	return 0


func _fund(view: Dictionary, id: String) -> Dictionary:
	for row: Dictionary in view.get("funds", []):
		if str(row.get("fund_id", "")) == id:
			return row
	return {}


func _project(view: Dictionary, id: String) -> Dictionary:
	for row: Dictionary in view.get("projects", []):
		if str(row.get("project_id", "")) == id:
			return row
	return {}


func _entries_of_kind(kind: String) -> Array:
	var result: Array = []
	for entry: Dictionary in world.farm.economy_ledger_entries():
		if str(entry.get("kind", "")) == kind:
			result.append(entry)
	return result


func _entry_amount(event_id: String) -> int:
	for entry: Dictionary in world.farm.economy_ledger_entries():
		if str(entry.get("event_id", "")) == event_id:
			return int(entry.get("debit", 0))
	return -1


func _cash_row() -> Dictionary:
	return {
		"A": world.farm.economy_cash(A),
		"B": world.farm.economy_cash(B),
		"world": world.farm.economy_cash(Economy.WORLD_OWNER),
		"total": world.farm.economy_total_cash(),
		"issued": world.farm.economy_issued(),
	}


func _files(directory: String) -> Dictionary:
	var result: Dictionary = {}
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		return result
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while not name.is_empty():
		if not dir.current_is_dir():
			result[name] = FileAccess.get_file_as_string(directory.path_join(name))
		name = dir.get_next()
	dir.list_dir_end()
	return result


func _check_cash(label: String) -> void:
	var issued: int = world.farm.economy_issued()
	var total: int = world.farm.economy_total_cash()
	var reconcile: Dictionary = world.farm.economy_reconcile()
	_expect(total == issued, "cash[%s]: total cash equals issued" % label)
	_expect(bool(reconcile.ok), "cash[%s]: the double-entry ledger reconciles" % label)
	_expect(int(reconcile.total_cash) == total,
		"cash[%s]: the reconcile total matches the authority" % label)
	_expect(int(reconcile.issued) == issued,
		"cash[%s]: the reconcile issued matches the authority" % label)
	_expect(int(reconcile.issuance) - int(reconcile.burned) == issued,
		"cash[%s]: issuance minus burns equals the net issue" % label)
	_expect(int(reconcile.accounts) + int(reconcile.merchant) + int(reconcile.escrow)
		+ int(reconcile.bank) == total,
		"cash[%s]: accounts + merchant + escrow + bank equals the total" % label)


## Goods census across the actors that exist in this chain. Harvested baskets
## enter the owners' bags and are consumed by recruitment and the attack cost;
## nothing should remain at the end (`expected_remaining` is 0 after the battle).
func _check_goods(label: String, expected_remaining: int) -> void:
	var remaining: int = _supplies(A) + _supplies(B)
	_expect(remaining == expected_remaining,
		"goods[%s]: bags hold the expected %d supplies" % [label, expected_remaining])
	_expect(int(world.farm.snapshot().harvested.get(GREENS, 0))
		== a_cells.size() + b_cells.size(),
		"goods[%s]: the produced counter is unchanged" % label)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS " + message)
	else:
		failures.append(message)
		print("FAIL " + message)
