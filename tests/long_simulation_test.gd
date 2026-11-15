extends SceneTree
## M13-02 long-horizon rule simulation. Three independent `HeadlessWorld`
## instances (two distinct seeds plus one deterministic replay) each run 60
## logical days on a fixed seed and logical clock. Nothing reads the wall clock
## for gameplay: the replay exists so the same inputs must produce the same
## fingerprint.
##
## Each day: crop growth/harvest, daily economy sweep (offline catch-up over
## order expiry, matching, shipment arrival and loan due dates), market orders
## and matching, one shipment with arrival, bank credit/repayment/default,
## organization/fund/public-works, unit supplies and desertion, participation
## regime window rotation and legal engagements.
##
## Long-run invariants asserted every day:
##   1. total_cash == issued, issuance - burned == issued, and
##      accounts + merchant + escrow + bank == total_cash;
##   2. no negative crop/inventory/order/shipment quantity;
##   3. the same event replayed does not settle twice;
##   4. unit people stay within the rule cap and one upkeep tick pays once;
##   5. conflict target loss <= 100 and per-window participation loss <= cap;
##   6. every durable event table and in-memory result window stays within its
##      existing capacity constant;
##   7. the two configured worlds do not affect each other, and replaying one
##      world with identical input yields an identical fingerprint.
##
## No UI, network transport, Windows path or real wall-clock residency is
## exercised.

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
const Market = preload("res://farm/market_state.gd")
const Loans = preload("res://farm/loan_state.gd")
const UnitState = preload("res://conflict/unit_state.gd")

const START: float = 1800028800.0
const DAY: float = 86400.0
const HOUR: float = 3600.0
const DAYS: int = 60
const RULES_VERSION: int = 2
const GREENS: String = "greens"

const A: String = "long_a"
const B: String = "long_b"
const C: String = "long_c"
const HOST: String = A
const ORG: String = "long_works"
const PROJECT: String = "long_road"
const B_UNIT: String = "long-b-unit"
const C_UNIT: String = "long-c-unit"

const A_HARVEST: int = 3
const B_HARVEST: int = 2
const CONFLICT_LOSS_CAP: int = 4
const OFFLINE_LOSS_CAP: int = 2
const ENGAGE_DAYS: Array[int] = [5, 11, 21, 31, 41, 51]
const DECLARE_DAYS: Array[int] = [1, 11, 21, 31, 41, 51]
const BUY_DAYS: Array[int] = [12, 22, 32, 42, 52]

const AREA: Dictionary = {
	"id": "long_area", "min_x": 0, "min_z": 0, "max_x": 5, "max_z": 5,
}

## Ready default cells split by owner. `cell_06` of fields 03-06 starts with a
## decorative crop and is deliberately not used.
const A_CELLS: Array = [
	{"field": "field_01", "cell": "cell_01"}, {"field": "field_01", "cell": "cell_02"},
	{"field": "field_01", "cell": "cell_03"}, {"field": "field_01", "cell": "cell_04"},
	{"field": "field_01", "cell": "cell_05"}, {"field": "field_01", "cell": "cell_06"},
	{"field": "field_02", "cell": "cell_01"}, {"field": "field_02", "cell": "cell_02"},
	{"field": "field_02", "cell": "cell_03"}, {"field": "field_02", "cell": "cell_04"},
	{"field": "field_02", "cell": "cell_05"}, {"field": "field_02", "cell": "cell_06"},
	{"field": "field_03", "cell": "cell_01"}, {"field": "field_03", "cell": "cell_02"},
	{"field": "field_03", "cell": "cell_03"}, {"field": "field_03", "cell": "cell_04"},
	{"field": "field_04", "cell": "cell_01"}, {"field": "field_04", "cell": "cell_02"},
	{"field": "field_04", "cell": "cell_03"}, {"field": "field_04", "cell": "cell_04"},
	{"field": "field_05", "cell": "cell_01"}, {"field": "field_05", "cell": "cell_02"},
]
const B_CELLS: Array = [
	{"field": "field_03", "cell": "cell_05"}, {"field": "field_04", "cell": "cell_05"},
	{"field": "field_05", "cell": "cell_03"}, {"field": "field_05", "cell": "cell_04"},
	{"field": "field_05", "cell": "cell_05"}, {"field": "field_06", "cell": "cell_01"},
	{"field": "field_06", "cell": "cell_02"}, {"field": "field_06", "cell": "cell_03"},
	{"field": "field_06", "cell": "cell_04"}, {"field": "field_06", "cell": "cell_05"},
]
const C_CELLS: Array = [
	{"field": "field_06", "cell": "cell_07"}, {"field": "field_06", "cell": "cell_08"},
]

var checks: int = 0
var failures: Array[String] = []
var base_root: String = ""


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	base_root = project_root.get_base_dir().path_join(
		".local/verification/long-simulation-%d-%d"
		% [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(base_root)
	var started_ms: int = Time.get_ticks_msec()
	_run()
	var elapsed_ms: int = Time.get_ticks_msec() - started_ms
	for failure: String in failures:
		push_error(failure)
	print("ELAPSED_MS=%d" % elapsed_ms)
	print("LONG_SIMULATION_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run() -> void:
	var alpha_cfg: Dictionary = {
		"name": "alpha", "seed": 42001, "world_id": "long-alpha",
		"sell_price": 5, "buy_price": 7, "ship_day": 7, "fund_day": 16,
	}
	var beta_cfg: Dictionary = {
		"name": "beta", "seed": 42002, "world_id": "long-beta",
		"sell_price": 4, "buy_price": 8, "ship_day": 17, "fund_day": 26,
	}
	var replay_cfg: Dictionary = alpha_cfg.duplicate(true)
	replay_cfg["name"] = "alpha_replay"

	var alpha: Dictionary = _simulate(alpha_cfg)
	var alpha_fingerprint: String = str(alpha.fingerprint)
	var alpha_digest: String = _dir_digest(str(alpha.dir))

	var beta: Dictionary = _simulate(beta_cfg)

	# World isolation: beta runs in its own directory and its own live objects;
	# alpha's in-memory state and files must be byte-identical afterwards.
	var alpha_after: String = _world_fingerprint(alpha.world)
	_expect(alpha_after == alpha_fingerprint,
		"isolation: beta must not change alpha's live state")
	_expect(_dir_digest(str(alpha.dir)) == alpha_digest,
		"isolation: beta must not change alpha's files")
	_expect(str(beta.fingerprint) != alpha_fingerprint,
		"isolation: the two configured worlds must not be indistinguishable")

	# Determinism: the same seed, schedule and logical clock must replay the
	# same fingerprint in an independent directory.
	var replay: Dictionary = _simulate(replay_cfg)
	_expect(str(replay.fingerprint) == alpha_fingerprint,
		"determinism: replaying alpha must yield the same fingerprint")
	_expect(int(replay.issued) == int(alpha.issued)
		and int(replay.total) == int(alpha.total),
		"determinism: replaying alpha must keep issued and total cash")
	print("DETERMINISM alpha=%s replay=%s equal=%s" % [
		alpha_fingerprint, str(replay.fingerprint),
		str(str(replay.fingerprint) == alpha_fingerprint)])
	print("ISOLATION alpha=%s beta=%s alpha_unchanged=%s" % [
		alpha_fingerprint, str(beta.fingerprint), str(alpha_after == alpha_fingerprint)])


# ---------------------------------------------------------------------------
# One world.
# ---------------------------------------------------------------------------

func _simulate(cfg: Dictionary) -> Dictionary:
	var name: String = str(cfg.name)
	var dir: String = base_root.path_join("world-" + name)
	DirAccess.make_dir_recursive_absolute(dir)
	var seeded: Dictionary = NatureStore.new(dir).save_state(
		{"seed": int(cfg.seed), "rules_version": RULES_VERSION})
	_expect(bool(seeded.ok), "%s: the fixed seed is persisted before the world opens" % name)
	var world = HeadlessWorld.new()
	var opened: Dictionary = world.open(dir, START, str(cfg.world_id), HOST)
	_expect(bool(opened.get("ok", false)),
		"%s: the authority opens the world (reason=%s)" % [name, str(opened.get("reason", ""))])
	_expect(str(opened.get("kind", "")) == "created", "%s: the directory starts fresh" % name)
	_expect(world.nature.get_seed() == int(cfg.seed), "%s: the persisted seed is adopted" % name)

	# Move the logical clock one day past the session start before any
	# authority-stamped command. `authority_now_utc` is then always the logical
	# clock, never the monotonic session clock, so timestamps are reproducible.
	var warm: Dictionary = world.advance_to(START + DAY)
	_expect(bool(warm.get("ok", false)), "%s: the logical clock reaches day 1" % name)

	var ctx: Dictionary = {
		"world": world, "cfg": cfg, "name": name, "dir": dir,
		"sow_index": {A: 0, B: 0, C: 0},
		"engagements": 0, "deliveries": 0,
		"replay_market": {},
	}
	_boot(world, cfg, ctx)
	for day: int in range(1, DAYS + 1):
		_day(world, cfg, ctx, day)
		_check_day(world, cfg, ctx, day)
		if day < DAYS:
			var advanced: Dictionary = world.advance_to(START + float(day + 1) * DAY)
			_expect(bool(advanced.get("ok", false)),
				"%s day %d: advance to the next day" % [name, day])
			if day >= 3:
				_expect(int(advanced.get("market_expired", 0)) >= 1,
					"%s day %d: yesterday's resting buy expires exactly once" % [name, day])
	_final_checks(world, cfg, ctx)

	var fingerprint: String = _world_fingerprint(world)
	var issued: int = world.farm.economy_issued()
	var total: int = world.farm.economy_total_cash()
	var events: int = _event_count(world)
	print("MEASURE world=%s days=%d cash_issued=%d final_total=%d events=%d fingerprint=%s" % [
		name, DAYS, issued, total, events, fingerprint])
	var reconcile: Dictionary = world.farm.economy_reconcile()
	print("DETAIL world=%s trades=%d engagements=%d conflict_loss=%d deliveries=%d losses=%d built=%d ledger=%d issuance=%d burned=%d" % [
		name, world.farm.market_trades().size(),
		(world.participation.get("engagements", {}) as Dictionary).size(),
		_participation_loss_total(world),
		world.farm.market_deliveries().size(), world.farm.market_losses().size(),
		_built_count(world), world.farm.economy_ledger_entries().size(),
		int(reconcile.get("issuance", -1)), int(reconcile.get("burned", -1))])
	return {
		"name": name, "dir": dir, "world": world, "fingerprint": fingerprint,
		"issued": issued, "total": total, "events": events,
	}


func _boot(world, cfg: Dictionary, ctx: Dictionary) -> void:
	var now: float = world.now_utc
	for owner: String in [A, B, C]:
		_execute(world, FarmCommand.make_account_open("open-" + owner, now), owner,
			"%s: %s opens an account" % [ctx.name, owner])
		_expect(world.farm.economy_cash(owner) == 120,
			"%s: %s receives the 120 COIN opening grant" % [ctx.name, owner])
	_execute(world, FarmCommand.make_bank_open("bank-open", now), A,
		"%s: the bank opens" % ctx.name)
	_execute(world, FarmCommand.make_market_open("market-open", now), A,
		"%s: the merchant opens" % ctx.name)
	_execute(world, FarmCommand.make_loan_borrow("loan-a", 300, 604800, now), A,
		"%s: A borrows 300 for 7 days" % ctx.name)
	_check_cash(world, ctx.name, "boot")
	# First limited regime and both consents. The first engagement is on day 5,
	# once A has harvested enough supplies for the recruit and march.
	_declare_and_consent(world, cfg, ctx, 1)


func _day(world, cfg: Dictionary, ctx: Dictionary, day: int) -> void:
	var now: float = world.now_utc
	var name: String = ctx.name

	# Crops: harvest what matured, then sow the next slice for tomorrow.
	_harvest(world, A, A_CELLS, A_HARVEST, day, ctx)
	_sow(world, A, A_CELLS, A_HARVEST, day, ctx)
	_harvest(world, B, B_CELLS, B_HARVEST, day, ctx)
	_sow(world, B, B_CELLS, B_HARVEST, day, ctx)
	if day <= 3:
		_harvest(world, C, C_CELLS, 1, day, ctx)
		_sow(world, C, C_CELLS, 1, day, ctx)

	# Market orders: two sells, one non-crossing resting buy that must expire,
	# and a periodic real buy.
	if day >= 2:
		var sell_a: Dictionary = FarmCommand.make_market_place(
			"sell-a-%02d" % day, Market.SIDE_SELL, GREENS, int(cfg.sell_price), 1,
			now + DAY, now)
		_execute(world, sell_a, A, "%s day %d: A rests a sell" % [name, day])
		# Replay the same committed event once: it must not trade or burn twice.
		if day == 5:
			var cash_before: int = world.farm.economy_cash(A)
			var replay: Dictionary = world.execute(sell_a, A)
			_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
				"%s day 5: the replayed market event is a duplicate" % name)
			_expect(world.farm.economy_cash(A) == cash_before,
				"%s day 5: the replayed market event moves no cash" % name)
		var sell_b: Dictionary = FarmCommand.make_market_place(
			"sell-b-%02d" % day, Market.SIDE_SELL, GREENS, int(cfg.sell_price), 1,
			now + DAY, now)
		_execute(world, sell_b, B, "%s day %d: B rests a sell" % [name, day])
		var rest: Dictionary = FarmCommand.make_market_place(
			"rest-b-%02d" % day, Market.SIDE_BUY, GREENS, 1, 1, now + DAY, now)
		_execute(world, rest, B, "%s day %d: B rests a non-crossing buy" % [name, day])
	if day in BUY_DAYS:
		var buy: Dictionary = FarmCommand.make_market_place(
			"buy-b-%02d" % day, Market.SIDE_BUY, GREENS, int(cfg.buy_price), 1,
			now + DAY, now)
		_execute(world, buy, B, "%s day %d: B buys from the merchant ask" % [name, day])

	if day == 2:
		_execute(world, FarmCommand.make_loan_borrow("loan-b", 100, 604800, now), B,
			"%s day 2: B borrows 100 for 7 days" % name)
	if day == 6:
		_execute(world, FarmCommand.make_loan_repay("repay-b", "loan-b", now), B,
			"%s day 6: B repays the loan plus fee" % name)

	if day == 3:
		var recruit_b: Dictionary = world.execute_unit("recruit", B, {
			"kind": "militia", "people": 1, "equipment": "none",
			"station": "farm_b", "command_id": B_UNIT,
		}, B_UNIT)
		_ok(recruit_b, "%s day 3: B recruits a one-person guard" % name)
		var recruit_c: Dictionary = world.execute_unit("recruit", C, {
			"kind": "militia", "people": 1, "equipment": "none",
			"station": "farm_c", "command_id": C_UNIT,
		}, C_UNIT)
		_ok(recruit_c, "%s day 3: C recruits a one-person militia" % name)

	# One strategic upkeep tick. The second call at the same logical second must
	# be a no-op and must not deduct supplies twice.
	if day >= 2:
		var supplies_before: int = _total_supplies(world)
		var upkeep: Dictionary = world.execute_unit("upkeep", A, {}, "upkeep-%02d" % day)
		_ok(upkeep, "%s day %d: strategic upkeep settles" % [name, day])
		var supplies_after_first: int = _total_supplies(world)
		var second: Dictionary = world.execute_unit("upkeep", A, {}, "upkeep-again-%02d" % day)
		_ok(second, "%s day %d: the same-tick upkeep repeat is accepted" % [name, day])
		_expect(bool(second.get("settled_this_tick", false)),
			"%s day %d: the second upkeep reports settled_this_tick" % [name, day])
		_expect(int(second.get("consumed", -1)) == 0,
			"%s day %d: the second upkeep consumes nothing" % [name, day])
		_expect(_total_supplies(world) == supplies_after_first,
			"%s day %d: the repeated upkeep does not deduct supplies twice" % [name, day])
		_expect(supplies_after_first <= supplies_before,
			"%s day %d: upkeep never adds supplies" % [name, day])
		if day == 4:
			_expect(int(upkeep.get("deserters", 0)) == 1,
				"%s day 4: the unfed one-person unit deserts once" % name)
			_expect(_unit_row(world, C_UNIT).is_empty(),
				"%s day 4: the deserted unit leaves the roster" % name)

	# Participation window rotation and one legal engagement per window.
	if day != 1 and day in DECLARE_DAYS:
		_declare_and_consent(world, cfg, ctx, day)
	if day in ENGAGE_DAYS:
		_engage(world, cfg, ctx, day)

	if day == int(cfg.fund_day):
		_build_public_works(world, cfg, ctx, day)

	# Shipment after all boundary-stamped commands; the six-hour advance proves
	# arrival is a real deadline settlement, not a same-instant shortcut.
	if day == int(cfg.ship_day):
		_ship_and_deliver(world, cfg, ctx, day)


# ---------------------------------------------------------------------------
# Participation, conflict, finance, public works.
# ---------------------------------------------------------------------------

func _declare_and_consent(world, cfg: Dictionary, ctx: Dictionary, day: int) -> void:
	var window_start: float = world.now_utc
	var window_end: float = window_start + 10.0 * DAY
	var declaration: Dictionary = {
		"tier": Participation.TIER_LIMITED,
		"declaration_id": "declaration-%02d" % day,
		"effective_utc": window_start,
		"higher_risk": true,
		"areas": [AREA.duplicate(true)],
		"windows": [{
			"id": "window-%02d" % day,
			"start_utc": window_start,
			"end_utc": window_end,
		}],
		"loss_cap": CONFLICT_LOSS_CAP,
		"offline_loss_cap": OFFLINE_LOSS_CAP,
	}
	var regime: Dictionary = world.execute_participation("regime", HOST,
		{"declaration": declaration}, "regime-%02d" % day)
	_ok(regime, "%s day %d: the host rotates the limited regime" % [ctx.name, day])
	var consent_a: Dictionary = world.execute_participation("declare", A,
		{"role": Participation.ROLE_ATTACKER}, "consent-a-%02d" % day)
	_ok(consent_a, "%s day %d: A consents as attacker" % [ctx.name, day])
	var consent_b: Dictionary = world.execute_participation("declare", B,
		{"role": Participation.ROLE_DEFENDER}, "consent-b-%02d" % day)
	_ok(consent_b, "%s day %d: B consents as defender" % [ctx.name, day])
	var view: Dictionary = world.participation_view()
	_expect(str(view.regime.window_ids[0]) == "window-%02d" % day,
		"%s day %d: the live regime names the rotated window" % [ctx.name, day])
	_expect(Participation.valid(world.participation),
		"%s day %d: the participation document stays valid" % [ctx.name, day])


func _engage(world, cfg: Dictionary, ctx: Dictionary, day: int) -> void:
	var name: String = ctx.name
	var unit_id: String = "a-unit-%02d" % day
	var recruit: Dictionary = world.execute_unit("recruit", A, {
		"kind": "militia", "people": CONFLICT_LOSS_CAP, "equipment": "none",
		"station": "farm_a", "command_id": unit_id,
	}, unit_id)
	if not _ok(recruit, "%s day %d: A recruits %d militia" % [
			name, day, CONFLICT_LOSS_CAP]):
		return
	var battle_id: String = "battle-%02d" % day
	var args: Dictionary = {
		"command_id": battle_id, "defender": B,
		"attacker_units": [unit_id], "defender_units": [B_UNIT],
		"x": 2, "z": 2,
	}
	var assets_before: int = _assets(world, A) + _assets(world, B)
	var cash_a_before: int = world.farm.economy_cash(A)
	var cash_b_before: int = world.farm.economy_cash(B)
	var result: Dictionary = world.execute_conflict("engage", A, args, battle_id, true)
	if not _ok(result, "%s day %d: the limited engagement settles" % [name, day]):
		return
	var outcome: Dictionary = result.get("outcome", {})
	var losses: int = int(outcome.get("losses", 0))
	_expect(losses > 0 and losses <= CONFLICT_LOSS_CAP,
		"%s day %d: losses fit the participation cap (got %d)" % [name, day, losses])
	_expect(int(outcome.get("target_lost_after", 0)) <= int(outcome.get("target_cap", 0)),
		"%s day %d: the target stays within its fixed 100 loss cap" % [name, day])
	_expect(int(outcome.get("target_cap", 0)) == 100,
		"%s day %d: the authority target cap is the fixed 100" % [name, day])
	_expect(str(outcome.get("window_id", "")) == "window-%02d" % _window_day(day),
		"%s day %d: the settlement uses the live rotated window" % [name, day])
	var view: Dictionary = world.participation_view()
	for row: Dictionary in view.get("losses", []):
		_expect(int(row.get("amount", 0)) <= int(view.regime.loss_cap),
			"%s day %d: the window loss total stays within the declared cap" % [name, day])
	var assets_after: int = _assets(world, A) + _assets(world, B)
	_expect(assets_before - assets_after == int(outcome.get("destroyed", -1)),
		"%s day %d: A+B assets decrease by exactly destroyed" % [name, day])

	# Immediate replay of the same durable engagement.
	var cash_after: int = world.farm.economy_cash(A) + world.farm.economy_cash(B)
	var replay: Dictionary = world.execute_conflict("engage", A, args, battle_id, true)
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"%s day %d: the replayed engagement is a duplicate" % [name, day])
	_expect(world.farm.economy_cash(A) + world.farm.economy_cash(B) == cash_after,
		"%s day %d: the replayed engagement pays no second spoils" % [name, day])
	_expect(world.farm.economy_cash(A) >= cash_a_before - 1000000
		and world.farm.economy_cash(B) >= cash_b_before - 1000000,
		"%s day %d: conflict cash stays in bounds" % [name, day])
	ctx.engagements = int(ctx.engagements) + 1

	# The attacker unit may be removed by the loss or survive; either way no
	# stale unit is left consuming supplies in later days.
	if not _unit_row(world, unit_id).is_empty():
		var disband: Dictionary = world.execute_unit("disband", A,
			{"unit_id": unit_id}, "disband-%02d" % day)
		_ok(disband, "%s day %d: the surviving attacker unit disbands" % [name, day])


func _window_day(day: int) -> int:
	var owner_day: int = 1
	for rotation: int in DECLARE_DAYS:
		if rotation <= day:
			owner_day = rotation
	return owner_day


func _build_public_works(world, cfg: Dictionary, ctx: Dictionary, day: int) -> void:
	var name: String = ctx.name
	var created: Dictionary = world.execute_organization("create", A,
		{"org_id": ORG, "name": "Long Works"}, "org-create")
	_ok(created, "%s day %d: A creates the organization" % [name, day])
	var joined: Dictionary = world.execute_organization("join", B,
		{"org_id": ORG}, "org-join-b")
	_ok(joined, "%s day %d: B joins the organization" % [name, day])
	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	_ok(world.execute_fund("open", A, {"org_id": ORG}, "fund-open"),
		"%s day %d: the organization fund opens" % [name, day])
	_ok(world.execute_fund("contribute", A,
		{"fund_id": fund_id, "amount": 60}, "fund-contribute-a"),
		"%s day %d: A contributes 60 real COIN" % [name, day])
	_ok(world.execute_fund("contribute", B,
		{"fund_id": fund_id, "amount": 60}, "fund-contribute-b"),
		"%s day %d: B contributes 60 real COIN" % [name, day])
	_expect(world.farm.economy_cash(org_account) == 120,
		"%s day %d: the organization account holds both contributions" % [name, day])
	_ok(world.execute_public_works("open", A, {
		"project_id": PROJECT, "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"parcel_id": "parcel_long",
	}, "pw-open"), "%s day %d: the road project is registered" % [name, day])
	_ok(world.execute_public_works("pledge", A,
		{"project_id": PROJECT, "amount": 120}, "pw-pledge"),
		"%s day %d: the project is pledged to its fixed cost" % [name, day])
	_ok(world.execute_public_works("build", A,
		{"project_id": PROJECT, "fund_id": fund_id}, "pw-build"),
		"%s day %d: the keeper builds the funded road" % [name, day])
	_expect(world.farm.economy_cash(org_account) == 0,
		"%s day %d: the build spends the fund exactly once" % [name, day])
	var project: Dictionary = _project(world.public_works_view(), PROJECT)
	_expect(str(project.get("status", "")) == PublicWorks.STATUS_BUILT,
		"%s day %d: the public project is built" % [name, day])
	_expect(PublicWorks.valid(world.public_works),
		"%s day %d: the public-works document stays valid" % [name, day])


func _ship_and_deliver(world, cfg: Dictionary, ctx: Dictionary, day: int) -> void:
	var name: String = ctx.name
	var shipment_id: String = "ship-%02d" % day
	var shipped: Dictionary = world.execute(FarmCommand.make_market_ship(
		shipment_id, Market.LOCATION_FARM, Market.LOCATION_HARBOR, GREENS, 1,
		world.now_utc), A)
	if not _ok(shipped, "%s day %d: A ships one green" % [name, day]):
		return
	var before: int = world.farm.market_deliveries().size()
	var advanced: Dictionary = world.advance_to(world.now_utc + 6.0 * HOUR)
	_ok(advanced, "%s day %d: the world advances to the arrival deadline" % [name, day])
	_expect(int(advanced.get("market_delivered", 0)) == 1,
		"%s day %d: exactly one shipment arrives" % [name, day])
	_expect(world.farm.market_deliveries().size() == before + 1,
		"%s day %d: exactly one delivery event is recorded" % [name, day])
	_expect(str(world.farm.market_shipment(shipment_id).status)
		== Market.SHIPMENT_STATUS_DELIVERED,
		"%s day %d: the shipment is terminal and delivered" % [name, day])
	ctx.deliveries = int(ctx.deliveries) + 1


# ---------------------------------------------------------------------------
# Crop helpers.
# ---------------------------------------------------------------------------

## Crop work uses the same FarmState rule entry points the authority calls.
## It deliberately skips the per-cell command/save wrapper: a 60-day, three-world
## run made every cell a full v27 save and pushed the fixture past its time
## budget. The next authority command persists the whole live farm, and every
## cash/order/shipment/unit/conflict/regime step still goes through the world
## authority. The M13-01 chain fixtures cover per-command crop commits.
func _harvest(world, actor: String, cells: Array, limit: int, day: int,
		ctx: Dictionary) -> void:
	var count: int = 0
	for plan: Dictionary in cells:
		if count >= limit:
			break
		var field: String = str(plan.field)
		var cell_id: String = str(plan.cell)
		var cell: Dictionary = world.farm.get_cell(field, cell_id)
		if str(cell.stage) != "mature" or str(cell.planted_by) != actor:
			continue
		var result: Dictionary = world.farm.harvest(field, cell_id, world.now_utc, actor)
		_expect(bool(result.get("ok", false)),
			"%s day %d: %s harvests %s/%s (reason=%s)" % [
				ctx.name, day, actor, field, cell_id, str(result.get("reason", ""))])
		count += 1


func _sow(world, actor: String, cells: Array, count: int, day: int,
		ctx: Dictionary) -> void:
	var indexes: Dictionary = ctx.sow_index
	var cursor: int = int(indexes.get(actor, 0))
	for offset: int in range(count):
		var plan: Dictionary = cells[(cursor + offset) % cells.size()]
		var field: String = str(plan.field)
		var cell_id: String = str(plan.cell)
		var result: Dictionary = world.farm.sow(field, cell_id, GREENS, world.now_utc, actor)
		_expect(bool(result.get("ok", false)),
			"%s day %d: %s sows %s/%s (reason=%s)" % [
				ctx.name, day, actor, field, cell_id, str(result.get("reason", ""))])
	indexes[actor] = (cursor + count) % cells.size()


# ---------------------------------------------------------------------------
# Daily invariants.
# ---------------------------------------------------------------------------

func _check_day(world, cfg: Dictionary, ctx: Dictionary, day: int) -> void:
	var name: String = ctx.name
	var economy: Dictionary = world.farm.economy_snapshot()
	var issued: int = int(economy.issued)
	var total: int = world.farm.economy_total_cash()
	var reconcile: Dictionary = world.farm.economy_reconcile()

	_expect(issued >= 0 and total == issued,
		"%s day %d: total cash equals issued (%d vs %d)" % [name, day, total, issued])
	_expect(bool(reconcile.get("ok", false)),
		"%s day %d: the ledger reconciles (reason=%s)" % [
			name, day, str(reconcile.get("reason", ""))])
	_expect(int(reconcile.get("issuance", -1)) - int(reconcile.get("burned", -1)) == issued,
		"%s day %d: issuance minus burned explains the net issue" % [name, day])
	_expect(int(reconcile.get("accounts", -1)) + int(reconcile.get("merchant", -1))
		+ int(reconcile.get("escrow", -1)) + int(reconcile.get("bank", -1)) == total,
		"%s day %d: accounts + merchant + escrow + bank equals total" % [name, day])
	_expect(Loans.outstanding_principal(economy) >= 0
		and Loans.collected_fees(economy) >= 0,
		"%s day %d: loan principal and fees are nonnegative" % [name, day])
	_expect(Economy.bank_cash(economy)
		== Economy.BANK_CAPITAL - Loans.outstanding_principal(economy)
		+ Loans.collected_fees(economy),
		"%s day %d: bank.cash == capital - outstanding + fees" % [name, day])

	var accounts_ok: bool = true
	for owner: Variant in economy.accounts:
		if int((economy.accounts[owner] as Dictionary).get("cash", 0)) < 0:
			accounts_ok = false
	_expect(accounts_ok, "%s day %d: every account cash is nonnegative" % [name, day])
	var snapshot: Dictionary = world.farm.snapshot()
	var stock_ok: bool = true
	for good_id: Variant in snapshot.inventory:
		if int(snapshot.inventory[good_id]) < 0:
			stock_ok = false
	for good_id: Variant in snapshot.harvested:
		if int(snapshot.harvested[good_id]) < 0:
			stock_ok = false
	_expect(stock_ok, "%s day %d: inventory and produced counters are nonnegative" % [name, day])

	var orders_ok: bool = true
	for order: Dictionary in world.farm.market_orders():
		if int(order.get("remaining", 0)) < 0 or int(order.get("reserved", 0)) < 0 \
				or int(order.get("released", 0)) < 0 or int(order.get("price", 0)) < 0 \
				or int(order.get("quantity", 0)) < 0:
			orders_ok = false
	_expect(orders_ok, "%s day %d: every order quantity is nonnegative" % [name, day])
	var merchant: Dictionary = world.farm.market_merchant()
	var merchant_ok: bool = int(merchant.get("cash", 0)) >= 0
	if merchant.get("goods") is Dictionary:
		for good_id: Variant in merchant.goods:
			if int(merchant.goods[good_id]) < 0:
				merchant_ok = false
	_expect(merchant_ok, "%s day %d: merchant cash and stock are nonnegative" % [name, day])
	var trades_ok: bool = true
	for trade: Dictionary in world.farm.market_trades():
		if int(trade.get("quantity", 0)) <= 0 or int(trade.get("fee", 0)) < 0:
			trades_ok = false
	_expect(trades_ok, "%s day %d: every trade quantity is positive" % [name, day])
	var shipments_ok: bool = true
	for shipment: Dictionary in world.farm.market_shipments():
		if int(shipment.get("quantity", 0)) <= 0:
			shipments_ok = false
	_expect(shipments_ok, "%s day %d: every shipment quantity is positive" % [name, day])
	var deliveries_ok: bool = true
	for delivery: Dictionary in world.farm.market_deliveries():
		if int(delivery.get("quantity", 0)) < 0:
			deliveries_ok = false
	for loss: Dictionary in world.farm.market_losses():
		if int(loss.get("quantity", 0)) < 0:
			deliveries_ok = false
	_expect(deliveries_ok, "%s day %d: delivery and loss quantities are nonnegative" % [name, day])

	# Unit sizes and the roster cap.
	var roster: Array = world.units_view().units
	_expect(roster.size() <= UnitState.MAX_UNITS,
		"%s day %d: the roster stays within MAX_UNITS" % [name, day])
	var units_ok: bool = true
	for unit: Dictionary in roster:
		var people: int = int(unit.get("people", 0))
		var unfed: int = int(unit.get("unfed_days", 0))
		if people <= 0 or people > UnitState.MAX_PEOPLE_PER_UNIT \
				or unfed < 0 or unfed > UnitState.MAX_UNFED_DAYS:
			units_ok = false
	_expect(units_ok, "%s day %d: unit people and unfed days stay in bounds" % [name, day])

	# Bounded event tables and in-memory result windows.
	_expect(world.farm.economy_ledger_entries().size() <= Ledger.MAX_ENTRIES,
		"%s day %d: ledger entries stay within MAX_ENTRIES" % [name, day])
	_expect(world.farm.market_orders().size() <= Market.MAX_ORDERS,
		"%s day %d: market orders stay within MAX_ORDERS" % [name, day])
	_expect(world.farm.market_trades().size() <= Market.MAX_TRADES,
		"%s day %d: market trades stay within MAX_TRADES" % [name, day])
	_expect(world.farm.market_shipments().size() <= Market.MAX_SHIPMENTS,
		"%s day %d: shipments stay within MAX_SHIPMENTS" % [name, day])
	_expect(world.farm.market_deliveries().size() <= Market.MAX_DELIVERIES,
		"%s day %d: deliveries stay within MAX_DELIVERIES" % [name, day])
	_expect(world.farm.market_losses().size() <= Market.MAX_LOSSES,
		"%s day %d: losses stay within MAX_LOSSES" % [name, day])
	_expect(world.farm.committed_command_count() <= 64,
		"%s day %d: committed command results stay bounded" % [name, day])
	_expect((world.participation.get("engagements", {}) as Dictionary).size()
		<= Participation.MAX_ENGAGEMENTS,
		"%s day %d: participation engagements stay within MAX_ENGAGEMENTS" % [name, day])
	_expect((world.participation.get("command_results", {}) as Dictionary).size()
		<= Participation.MAX_COMMAND_RESULTS,
		"%s day %d: participation results stay within MAX_COMMAND_RESULTS" % [name, day])
	_expect((world.conflicts.get("consumed", {}) as Dictionary).size()
		<= ConflictSettlement.MAX_CONSUMED,
		"%s day %d: conflict outcomes stay within MAX_CONSUMED" % [name, day])
	_expect((world.conflicts.get("targets", {}) as Dictionary).size()
		<= ConflictSettlement.MAX_TARGETS,
		"%s day %d: conflict targets stay within MAX_TARGETS" % [name, day])
	_expect(world._conflict_applied.size() <= ConflictSettlement.MAX_CONSUMED,
		"%s day %d: the conflict applied map stays bounded" % [name, day])
	_expect((world.units.get("commands", {}) as Dictionary).size() <= UnitState.MAX_COMMANDS,
		"%s day %d: unit command records stay within MAX_COMMANDS" % [name, day])
	_expect(world._organization_results.size() <= 64,
		"%s day %d: organization result window is bounded" % [name, day])
	_expect(world._fund_results.size() <= 64,
		"%s day %d: fund result window is bounded" % [name, day])
	_expect(world._public_works_results.size() <= 64,
		"%s day %d: public-works result window is bounded" % [name, day])
	for fund_id: Variant in (world.funds.get("funds", {}) as Dictionary):
		var fund: Dictionary = world.funds.funds[fund_id]
		if fund.get("history") is Array:
			_expect((fund.history as Array).size() <= PublicFund.MAX_HISTORY,
				"%s day %d: fund history stays within MAX_HISTORY" % [name, day])

	if day >= 8:
		_expect(str(world.farm.economy_loan("loan-a").status) == Loans.STATUS_OVERDUE,
			"%s day %d: A's 7-day loan is overdue" % [name, day])
	if day >= 6:
		_expect(str(world.farm.economy_loan("loan-b").status) == Loans.STATUS_REPAID,
			"%s day %d: B's loan is repaid" % [name, day])

	# Structural validators at a few checkpoints, not every day. The conflict
	# context has no live participation copy until the first engagement, so its
	# first validation is day 5.
	if day in [5, 15, 30, 45, 60]:
		_expect(Economy.valid(economy), "%s day %d: the economy document is valid" % [name, day])
		_expect(Participation.valid(world.participation),
			"%s day %d: participation is valid" % [name, day])
		_expect(ConflictSettlement.valid_context(world.conflicts),
			"%s day %d: the conflict context is valid" % [name, day])
		_expect(UnitState.valid(world.units), "%s day %d: the unit document is valid" % [name, day])
		_expect(PublicWorks.valid(world.public_works),
			"%s day %d: the public-works document is valid" % [name, day])

	# Repeated same-instant settlement must not settle any deadline twice.
	var cash_before: int = world.farm.economy_total_cash()
	var first: Dictionary = world.settle_economy_now(world.now_utc)
	_ok(first, "%s day %d: the explicit economy sweep runs" % [name, day])
	var second: Dictionary = world.settle_economy_now(world.now_utc)
	_ok(second, "%s day %d: the repeated economy sweep is accepted" % [name, day])
	_expect(not bool(second.get("changed", true)),
		"%s day %d: the repeated sweep settles no new work" % [name, day])
	_expect(world.farm.economy_total_cash() == cash_before,
		"%s day %d: the repeated sweep moves no cash" % [name, day])


func _final_checks(world, cfg: Dictionary, ctx: Dictionary) -> void:
	var name: String = ctx.name
	var reconcile: Dictionary = world.farm.economy_reconcile()
	_expect(bool(reconcile.get("ok", false)), "%s final: the ledger reconciles" % name)
	_expect(world.farm.economy_total_cash() == world.farm.economy_issued(),
		"%s final: total cash equals issued after %d days" % [name, DAYS])
	_expect(int(ctx.engagements) == ENGAGE_DAYS.size(),
		"%s final: every scheduled legal engagement settled (%d)" % [name, int(ctx.engagements)])
	_expect(int(ctx.deliveries) == 1, "%s final: exactly one shipment was delivered" % name)
	_expect(int(world.farm.market_trades().size()) > 0,
		"%s final: the market matched real trades" % name)
	_expect(world.farm.market_orders().size() > 0,
		"%s final: market orders exercised matching and expiry" % name)
	var project: Dictionary = _project(world.public_works_view(), PROJECT)
	_expect(str(project.get("status", "")) == PublicWorks.STATUS_BUILT,
		"%s final: the public project is still built" % name)
	_expect(str(world.farm.economy_loan("loan-a").status) == Loans.STATUS_OVERDUE,
		"%s final: the overdue bank loan exercised the due-date path" % name)
	_expect(UnitState.valid(world.units), "%s final: the unit document is valid" % name)
	_expect(Participation.valid(world.participation),
		"%s final: the participation document is valid" % name)
	_expect(ConflictSettlement.valid_context(world.conflicts),
		"%s final: the conflict context is valid" % name)
	_expect(Economy.valid(world.farm.economy_snapshot()),
		"%s final: the economy document is valid" % name)


# ---------------------------------------------------------------------------
# Shared helpers.
# ---------------------------------------------------------------------------

func _execute(world, command: Dictionary, actor: String, label: String) -> Dictionary:
	var result: Dictionary = world.execute(command, actor)
	_expect(bool(result.get("ok", false)),
		"%s: expected ok, got reason=%s" % [label, str(result.get("reason", ""))])
	_expect(str(result.get("stage", "")) == "committed",
		"%s: expected committed, got stage=%s" % [label, str(result.get("stage", ""))])
	return result


func _ok(result: Dictionary, label: String) -> bool:
	var good: bool = bool(result.get("ok", false))
	_expect(good, "%s: expected ok, got reason=%s" % [label, str(result.get("reason", ""))])
	return good


func _check_cash(world, name: String, label: String) -> void:
	var economy: Dictionary = world.farm.economy_snapshot()
	var reconcile: Dictionary = world.farm.economy_reconcile()
	_expect(world.farm.economy_total_cash() == world.farm.economy_issued(),
		"%s[%s]: total cash equals issued" % [name, label])
	_expect(bool(reconcile.get("ok", false)), "%s[%s]: ledger reconciles" % [name, label])
	_expect(int(reconcile.get("accounts", -1)) + int(reconcile.get("merchant", -1))
		+ int(reconcile.get("escrow", -1)) + int(reconcile.get("bank", -1))
		== int(economy.issued),
		"%s[%s]: all cash holders sum to issued" % [name, label])


func _total_supplies(world) -> int:
	return _supplies(world, A) + _supplies(world, B) + _supplies(world, C)


func _supplies(world, owner: String) -> int:
	var goods: Dictionary = world.farm.economy_goods(owner)
	var total: int = 0
	for good_id: String in EconomyCatalog.goods_ids():
		total += int(goods.get(good_id, 0))
	return total


func _assets(world, owner: String) -> int:
	return world.farm.economy_cash(owner) + _supplies(world, owner)


func _unit_row(world, unit_id: String) -> Dictionary:
	for row: Dictionary in world.units_view().units:
		if str(row.get("id", "")) == unit_id:
			return row
	return {}


func _project(view: Dictionary, project_id: String) -> Dictionary:
	for row: Dictionary in view.get("projects", []):
		if str(row.get("project_id", "")) == project_id:
			return row
	return {}


func _event_count(world) -> int:
	var count: int = world.farm.economy_ledger_entries().size()
	count += world.farm.market_trades().size()
	count += world.farm.market_deliveries().size()
	count += world.farm.market_losses().size()
	count += (world.participation.get("engagements", {}) as Dictionary).size()
	count += _built_count(world)
	return count


func _participation_loss_total(world) -> int:
	var total: int = 0
	for row: Dictionary in world.participation_view().get("losses", []):
		total += int(row.get("amount", 0))
	return total


func _built_count(world) -> int:
	var count: int = 0
	var projects: Dictionary = world.public_works.get("projects", {})
	for project_id: Variant in projects:
		if str((projects[project_id] as Dictionary).get("status", "")) \
				== PublicWorks.STATUS_BUILT:
			count += 1
	return count


## Fingerprint over every durable document and the logical clock. Directory
## names, wall time and session-only maps are deliberately excluded, so the
## same inputs must reproduce the same string.
func _world_fingerprint(world) -> String:
	var document: Dictionary = {
		"now_utc": world.now_utc,
		"farm": world.farm.snapshot(),
		"nature": world.nature.snapshot(),
		"territory": world.territory,
		"participation": world.participation,
		"conflicts": world.conflicts,
		"units": world.units,
		"funds": world.funds,
		"organizations": world.organizations,
		"public_works": world.public_works,
		"residents": world.residents,
	}
	return JSON.stringify(document).sha256_text().substr(0, 16)


func _dir_digest(directory: String) -> String:
	var names: Array[String] = []
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while not name.is_empty():
		if not dir.current_is_dir():
			names.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	names.sort()
	var payload: String = ""
	for file_name: String in names:
		payload += file_name + "\n" + FileAccess.get_file_as_string(
			directory.path_join(file_name)) + "\n"
	return payload.sha256_text()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
