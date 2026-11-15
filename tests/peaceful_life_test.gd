extends SceneTree
## M13-05 peaceful-life acceptance fixture. One fixed seed, one fixed logical
## clock, one new temporary world directory, and no network, no model, no
## conflict: a single player sows, grows, harvests, cooks and shares a meal,
## sells at the local market against a second local account (no socket), opens
## a bank account, borrows and repays, claims a homestead parcel by building on
## it, and restarts the directory.
##
## What this proves, independently of tests/chain_integration_test.gd:
##   - the whole life chain runs on HeadlessWorld alone;
##   - no network module, socket peer or AI/model module is loaded or cached;
##   - residents stay disabled and produce no actions;
##   - the world stays at peace: no participation document, no conflict
##     document, no engagements, no units;
##   - every committed step returned ok, and the restart keeps bag, cash,
##     building, resting order, kitchen document and ledger consistent.
##
## Kitchen and dish-sharing have no authority command entry: they exist as the
## real `FarmState.kitchen_action` rule reached by the local scene. This
## fixture calls the same rule on a candidate and persists it through the same
## `FarmStore` boundary `Game/scenes/main.gd` uses, then accepts the candidate.
## That gap is recorded as "rule reachable, authority entry missing" in
## docs/2.0/milestones/M13/RECORD-13-peaceful-life.md.

const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const Catalog = preload("res://farm/economy_catalog.gd")
const TerritoryState = preload("res://world/territory_state.gd")

const SEED: int = 101507
const RULES_VERSION: int = 2
const START: float = 1800014400.0
const WORLD_ID: String = "peaceful-life-world"
const A: String = "peace_a"
const B: String = "peace_b"
const GREENS: String = "greens"
const T_HARVEST: float = START + 7200.0
const T_KITCHEN_DONE: float = T_HARVEST + 20.0
const T_BANK: float = T_HARVEST + 30.0
const T_BUILD_DONE: float = T_BANK + 601.0
const LOAN_PRINCIPAL: int = 100
const LOAN_TERM: int = 604800
const ORDER_EXPIRY_SECONDS: float = 86400.0
const OPENING_GRANT: int = 120

## Modules whose presence in this process would falsify "offline, no model".
## `ResourceLoader.has_cached` turns true as soon as a script is loaded, so a
## future `preload` from the authority closure fails these checks instead of
## being silently carried along.
const FORBIDDEN_RESOURCES: Array[String] = [
	"res://world/world_client.gd",
	"res://world/world_host.gd",
	"res://world/world_server.gd",
	"res://world/world_member.gd",
	"res://ai/model_scheduler.gd",
	"res://ai/llama_cpp_backend.gd",
	"res://ai/model_task.gd",
]
## Path fragments that must not appear anywhere in the transitive preload
## closure of the authority. Comments may mention these names; only a real
## preload path fails the check.
const FORBIDDEN_PATH_FRAGMENTS: Array[String] = [
	"/ai/", "world_client", "world_host", "world_server", "world_member",
]

var checks: int = 0
var failures: Array[String] = []
var test_root: String = ""
var world: RefCounted
var reopened: RefCounted
var produced: Dictionary = {}
var steps: Array[String] = []


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	test_root = project_root.get_base_dir().path_join(
		".local/verification/peaceful-life-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(test_root)
	_run_life()
	for failure: String in failures:
		push_error(failure)
	print("PEACEFUL_LIFE steps=%d checks=%d failures=%d"
		% [steps.size(), checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run_life() -> void:
	_assert_offline_environment("startup")
	_boot()
	_phase_sow_and_grow()
	_phase_harvest()
	_phase_accounts_and_market()
	_phase_meal()
	_phase_bank()
	_phase_homestead()
	_phase_resting_order()
	_phase_restart()
	_assert_offline_environment("end")


# ---------------------------------------------------------------------------
# Environment: this process has no socket peer, no autoload, no network/AI
# script loaded, and the authority's preload closure never reaches them.
# ---------------------------------------------------------------------------

func _assert_offline_environment(label: String) -> void:
	var peer: Variant = get_multiplayer().multiplayer_peer
	_expect(peer is OfflineMultiplayerPeer,
		"offline[%s]: the SceneTree peer is OfflineMultiplayerPeer" % label)
	_expect(get_root().get_child_count() == 0,
		"offline[%s]: the scene root has no instantiated nodes" % label)
	var autoloads: Variant = ProjectSettings.get_setting("autoload", {})
	_expect(autoloads is Dictionary and (autoloads as Dictionary).is_empty(),
		"offline[%s]: the project declares no autoload" % label)
	for path: String in FORBIDDEN_RESOURCES:
		_expect(not ResourceLoader.has_cached(path),
			"offline[%s]: %s is not loaded" % [label, path])
	# Negative control for the loader probe: the authority script is preloaded
	# by this fixture, so a probe that cannot see a known-loaded script would
	# also miss a forbidden one. This check fails if `has_cached` goes blind.
	_expect(ResourceLoader.has_cached("res://world/headless_world.gd"),
		"offline[%s]: the loader probe sees the script this fixture preloads" % label)
	var closure: Dictionary = {}
	_collect_preloads("res://world/headless_world.gd", closure)
	var offenders: Array[String] = []
	for path: String in closure:
		if _forbidden(path):
			offenders.append(path)
	_expect(closure.size() >= 40,
		"offline[%s]: the authority preload closure was actually walked (%d)"
			% [label, closure.size()])
	_expect(offenders.is_empty(),
		"offline[%s]: the authority closure contains no network/AI module %s"
			% [label, str(offenders)])
	# Negative control for the closure probe: a synthetic script that preloads a
	# network module must be caught, so an empty result means "nothing grew",
	# not "the scanner is looking at nothing". The planted file is removed.
	var planted: String = test_root.path_join("planted_closure.gd")
	var file := FileAccess.open(planted, FileAccess.WRITE)
	_expect(file != null, "offline[%s]: the control script can be written" % label)
	if file != null:
		file.store_string("extends RefCounted\npreload(\"res://world/world_host.gd\")\n")
		file.close()
		var control: Dictionary = {}
		_collect_preloads(planted, control)
		var caught: int = 0
		for path: String in control:
			if _forbidden(path):
				caught += 1
		_expect(caught == 1,
			"offline[%s]: the closure probe catches a planted network preload" % label)
		DirAccess.remove_absolute(planted)
	# The fixture's own script constants are preloads too: none may be a
	# network, conflict-transport or model module.
	var own: Dictionary = (get_script() as Script).get_script_constant_map()
	var own_offenders: Array[String] = []
	for key: Variant in own:
		var value: Variant = own[key]
		if value is Script and _forbidden(str((value as Script).resource_path)):
			own_offenders.append(str((value as Script).resource_path))
	_expect(own_offenders.is_empty(),
		"offline[%s]: the fixture preloads no network/AI module %s"
			% [label, str(own_offenders)])


func _collect_preloads(path: String, seen: Dictionary) -> void:
	if seen.has(path):
		return
	seen[path] = true
	var text: String = FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	var pattern := RegEx.new()
	pattern.compile("preload\\(\"(res://[^\"]+)\"\\)")
	for match_result: RegExMatch in pattern.search_all(text):
		var child: String = ProjectSettings.globalize_path(match_result.get_string(1))
		_collect_preloads(child, seen)


func _forbidden(path: String) -> bool:
	for fragment: String in FORBIDDEN_PATH_FRAGMENTS:
		if path.contains(fragment):
			return true
	return false


# ---------------------------------------------------------------------------
# Boot: one seeded world at one fixed instant, no host, no residents.
# ---------------------------------------------------------------------------

func _boot() -> void:
	_phase("boot")
	var saved: Dictionary = NatureStore.new(test_root).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	_expect(bool(saved.get("ok", false)), "fixture: the fixed seed is persisted before the world opens")
	world = HeadlessWorld.new()
	var opened: Dictionary = world.open(test_root, START, WORLD_ID)
	_step("open", opened)
	_expect(bool(opened.get("ok", false)), "boot: the authority opens the world")
	_expect(str(opened.get("kind", "")) == "created", "boot: the directory starts as a fresh world")
	_expect(world.nature.get_seed() == SEED, "boot: the fresh farm adopts the fixed seed")
	_expect(str(world.world_id) == WORLD_ID, "boot: the cadastre carries the requested world id")
	_expect(is_equal_approx(world.now_utc, START), "boot: the logical clock starts at the fixed UTC")
	_expect(world.residents_enabled == false, "boot: resident autonomy is off by default")
	_expect(not bool(world.residents_view().available), "boot: the resident view reports disabled")
	var residents: Dictionary = world.settle_residents(START)
	_step("settle_residents", residents)
	_expect(bool(residents.get("ok", false)) and str(residents.get("reason", "")) == "disabled",
		"boot: the resident sweep returns disabled")
	_expect(not bool(residents.get("changed", true)),
		"boot: the disabled resident sweep changes nothing")
	_expect((residents.get("intents", []) as Array).is_empty(),
		"boot: no resident intent is produced")
	_expect(world.participation_view().available == false,
		"boot: a hostless room declares no participation regime")
	_expect(_conflict_rows(world) == 0, "boot: no conflict is recorded")
	_expect(world.units_view().units.is_empty(), "boot: the unit roster is empty")


# ---------------------------------------------------------------------------
# Sow, weather growth, harvest into A's own bag.
# ---------------------------------------------------------------------------

func _phase_sow_and_grow() -> void:
	_phase("sow_grow")
	for index: int in range(1, 7):
		var sow: Dictionary = FarmCommand.make_sow(
			"peace_sow_%02d" % index, "field_01", "cell_%02d" % index, GREENS, START)
		var result: Dictionary = _execute(sow, A, "sow cell_%02d" % index)
		_expect(str(world.farm.get_cell("field_01", "cell_%02d" % index).crop_id) == GREENS,
			"sow: cell_%02d holds greens" % index)
		_expect(str(result.get("stage", "")) == "committed", "sow: cell_%02d committed" % index)
	var advanced: Dictionary = world.advance_to(T_HARVEST)
	_step("advance_harvest", advanced)
	_expect(bool(advanced.get("ok", false)), "growth: the world advances to the fixed harvest instant")
	var mature: int = 0
	for index: int in range(1, 7):
		if str(world.farm.get_cell("field_01", "cell_%02d" % index).stage) == "mature":
			mature += 1
	_expect(mature == 6, "growth: all six greens are mature after two hours")
	_expect(is_equal_approx(world.now_utc, T_HARVEST), "growth: the clock is at the harvest instant")


func _phase_harvest() -> void:
	_phase("harvest")
	for index: int in range(1, 7):
		var harvest: Dictionary = FarmCommand.make(
			"peace_harvest_%02d" % index, "field_01", "cell_%02d" % index, T_HARVEST)
		var result: Dictionary = _execute(harvest, A, "harvest cell_%02d" % index)
		_expect(str(result.get("reward_crop_id", "")) == GREENS,
			"harvest: cell_%02d yields greens" % index)
		_expect(int(result.get("reward_amount", 0)) == 1,
			"harvest: cell_%02d yields one basket" % index)
		produced[GREENS] = int(produced.get(GREENS, 0)) + 1
	_expect(world.farm.bag(A)[GREENS] == 6, "harvest: six baskets are in A's own bag")
	_expect(world.farm.economy_goods("@world")[GREENS] == 0,
		"harvest: nothing leaked into the shared world pocket")
	_expect(int(world.farm.snapshot().harvested[GREENS]) == 6,
		"harvest: the produced counter records six greens")
	_check_goods("harvest complete")


# ---------------------------------------------------------------------------
# Two local accounts, the rule merchant, one crossing fill. No socket.
# ---------------------------------------------------------------------------

func _phase_accounts_and_market() -> void:
	_phase("accounts_market")
	_execute(FarmCommand.make_account_open("peace_account_a", T_HARVEST), A,
		"open A's account")
	_execute(FarmCommand.make_account_open("peace_account_b", T_HARVEST), B,
		"open B's account")
	_expect(world.farm.economy_cash(A) == OPENING_GRANT, "account: A holds the opening grant")
	_expect(world.farm.economy_cash(B) == OPENING_GRANT, "account: B holds the opening grant")
	_execute(FarmCommand.make_market_open("peace_market_open", T_HARVEST), "",
		"open the local rule merchant")
	_expect(world.farm.market_merchant().opened, "market: the local merchant is open")
	_expect(world.farm.market_quote(GREENS).bid == 5,
		"market: the merchant bids 5 for greens")
	_check_cash("accounts and merchant")

	var sell: Dictionary = FarmCommand.make_market_place(
		"peace_sell_greens", "sell", GREENS, 6, 2,
		T_HARVEST + ORDER_EXPIRY_SECONDS, T_HARVEST)
	_execute(sell, A, "A rests a sell order for two greens")
	_expect(int(world.farm.market_order("peace_sell_greens").remaining) == 2,
		"market: the sell order carries two units")
	_expect(world.farm.bag(A)[GREENS] == 4, "market: the two escrowed baskets leave A's bag")
	_check_goods("sell order resting")

	var buy: Dictionary = FarmCommand.make_market_place(
		"peace_buy_greens", "buy", GREENS, 6, 2,
		T_HARVEST + ORDER_EXPIRY_SECONDS, T_HARVEST)
	var bought: Dictionary = _execute(buy, B, "B buys two greens locally")
	_expect(int(bought.get("market_matched", 0)) == 1,
		"market: B's commit sweeps exactly one fill")
	_expect(world.farm.market_trades().size() == 1, "market: one trade row is recorded")
	_expect(str(world.farm.market_trades()[0].sell_owner) == A
		and str(world.farm.market_trades()[0].buy_owner) == B,
		"market: the trade is A to B with no merchant counterparty")
	_expect(world.farm.bag(B)[GREENS] == 2, "market: both bought baskets land in B's bag")
	_expect(world.farm.economy_cash(A) == OPENING_GRANT + 11,
		"market: A receives 12 minus the 1 COIN fee")
	_expect(world.farm.economy_cash(B) == OPENING_GRANT - 12,
		"market: B pays exactly the 12 COIN notional")
	_expect(int(world.farm.economy_reconcile().burned) == 1,
		"market: the 1 COIN trade fee is burned")
	_check_cash("local trade settled")
	_check_goods("after local trade")


# ---------------------------------------------------------------------------
# Cook one basket and share the dish. Real kitchen rule, same persistence path
# as the local scene; there is no authority command for it (recorded gap).
# ---------------------------------------------------------------------------

func _phase_meal() -> void:
	_phase("meal")
	world.farm.pantry_owner = A
	var before: Dictionary = world.farm.snapshot()
	var revision: int = int(before.kitchen.revision)
	var cooked: Dictionary = _kitchen_persisted(
		"start", {"recipe": "leaf_stir", "crop": GREENS}, revision)
	_step("kitchen_start", cooked)
	_expect(bool(cooked.get("ok", false)), "meal: the kitchen starts the greens dish")
	_expect(world.farm.bag(A)[GREENS] == 3,
		"meal: cooking consumes exactly one basket from A's bag")
	_expect(str(world.farm.get_cell("field_01", "cell_01").crop_id) == "",
		"meal: the kitchen does not touch the fields")

	var advanced: Dictionary = world.advance_to(T_KITCHEN_DONE)
	_step("advance_kitchen", advanced)
	_expect(bool(advanced.get("ok", false)), "meal: the logical clock reaches the cooking finish")
	revision = int(world.farm.snapshot().kitchen.revision)
	var collected: Dictionary = _kitchen_persisted("collect", {"station": "stove"}, revision)
	_step("kitchen_collect", collected)
	_expect(bool(collected.get("ok", false)), "meal: the finished dish is collected")
	_expect(int(world.farm.snapshot().kitchen.stock.leaf_stir) == 1,
		"meal: one dish is in the kitchen stock")
	_expect(int(world.farm.snapshot().kitchen.records.leaf_stir.made) == 1,
		"meal: the dish is recorded as made")

	revision = int(world.farm.snapshot().kitchen.revision)
	var shared: Dictionary = _kitchen_persisted(
		"share", {"recipe": "leaf_stir", "neighbor": "willow"}, revision)
	_step("kitchen_share", shared)
	_expect(bool(shared.get("ok", false)), "meal: the dish is shared with the neighbour")
	_expect(int(world.farm.snapshot().kitchen.stock.leaf_stir) == 0,
		"meal: sharing consumes the last dish")
	_expect(int(world.farm.snapshot().kitchen.records.leaf_stir.shared) == 1,
		"meal: the shared dish is recorded")
	_check_goods("meal cooked and shared")


# ---------------------------------------------------------------------------
# Bank: open, borrow, repay in full.
# ---------------------------------------------------------------------------

func _phase_bank() -> void:
	_phase("bank")
	var advanced: Dictionary = world.advance_to(T_BANK)
	_expect(bool(advanced.get("ok", false)), "bank: the clock reaches the bank instant")
	_execute(FarmCommand.make_bank_open("peace_bank_open", T_BANK), "",
		"open the rule bank")
	_expect(world.farm.economy_bank().opened, "bank: the rule bank is open")
	_expect(int(world.farm.economy_bank().capital) == 2000,
		"bank: the one-time capital is 2000 COIN")
	_check_cash("bank opened")

	var borrowed: Dictionary = _execute(FarmCommand.make_loan_borrow(
		"peace_borrow", LOAN_PRINCIPAL, LOAN_TERM, T_BANK), A, "A borrows 100 COIN")
	_expect(str(borrowed.get("stage", "")) == "committed", "bank: the loan commits")
	_expect(world.farm.economy_cash(A) == OPENING_GRANT + 11 + LOAN_PRINCIPAL,
		"bank: A's cash rises by the principal")
	_expect(str(world.farm.economy_loan("peace_borrow").status) == "open",
		"bank: the contract is open")
	_check_cash("loan issued")

	_execute(FarmCommand.make_loan_repay("peace_repay", "peace_borrow", T_BANK), A,
		"repay the loan in full")
	_expect(str(world.farm.economy_loan("peace_borrow").status) == "repaid",
		"bank: the contract is repaid")
	_expect(int(world.farm.economy_loan("peace_borrow").paid) == LOAN_PRINCIPAL + 5,
		"bank: principal plus the 5 COIN fee is repaid")
	_expect(world.farm.economy_cash(A) == OPENING_GRANT + 11 - 5,
		"bank: A's cash returns to the pre-loan balance minus the 5 COIN fee")
	_check_cash("loan repaid")


# ---------------------------------------------------------------------------
# Homestead: the build gate claims the parcel, the build timeline finishes.
# ---------------------------------------------------------------------------

func _phase_homestead() -> void:
	_phase("homestead")
	var view: Dictionary = world.territory_view()
	_expect(str(view.parcels["parcel_01"].status) == "unclaimed",
		"land: yard_a's parcel starts unclaimed")
	_expect(not TerritoryState.may_build(view, "parcel_01", A),
		"land: unclaimed ground is not buildable before the claim")
	var built: Dictionary = _execute(FarmCommand.make_build(
		"peace_build_home", "yard_a", "cottage", T_BANK), A, "build a cottage on yard_a")
	_expect(str(built.get("stage", "")) == "committed", "land: the build commits")
	view = world.territory_view()
	_expect(str(view.parcels["parcel_01"].owner) == A,
		"land: the first build claims the parcel for A")
	_expect(str(view.parcels["parcel_01"].status) == "claimed",
		"land: the parcel is claimed")
	_expect(TerritoryState.may_build(view, "parcel_01", A),
		"land: A may build on the claimed parcel")
	_expect(not TerritoryState.may_build(view, "parcel_01", B),
		"land: B may not build on A's parcel")
	_expect(str(world.farm.building_state("yard_a", T_BANK)) == "building",
		"house: the cottage is under construction")
	var advanced: Dictionary = world.advance_to(T_BUILD_DONE)
	_step("advance_build", advanced)
	_expect(bool(advanced.get("ok", false)), "house: the clock reaches the finish")
	_expect(str(world.farm.building_state("yard_a", T_BUILD_DONE)) == "done",
		"house: the cottage is finished")
	var building: Dictionary = world.farm.buildings_at(T_BUILD_DONE)["yard_a"]
	_expect(str(building.owner) == A, "house: A owns the finished cottage")
	_expect(str(building.blueprint) == "cottage", "house: the blueprint is the cottage")
	_check_cash("homestead built")
	_check_goods("homestead built")


# ---------------------------------------------------------------------------
# One resting sell order that must survive the restart.
# ---------------------------------------------------------------------------

func _phase_resting_order() -> void:
	_phase("resting_order")
	var sell: Dictionary = FarmCommand.make_market_place(
		"peace_rest_greens", "sell", GREENS, 9, 2,
		T_BUILD_DONE + ORDER_EXPIRY_SECONDS, T_BUILD_DONE)
	_execute(sell, A, "A rests two greens above the merchant ask")
	var row: Dictionary = world.farm.market_order("peace_rest_greens")
	_expect(str(row.status) == "open", "orders: the resting sell stays open")
	_expect(int(row.remaining) == 2, "orders: both units are still escrowed")
	_expect(world.farm.bag(A)[GREENS] == 1,
		"orders: the escrowed baskets leave A's bag")
	_check_cash("resting order placed")
	_check_goods("resting order placed")
	_assert_offline_environment("before restart")


# ---------------------------------------------------------------------------
# Save, close, reopen the same directory, and assert the whole life survives.
# ---------------------------------------------------------------------------

func _phase_restart() -> void:
	_phase("restart")
	var live: Dictionary = world.farm.snapshot()
	var saved: Dictionary = world.save()
	_step("save", saved)
	_expect(bool(saved.get("ok", false)), "restart: the world saves")
	var live_cash: int = world.farm.economy_total_cash()
	var live_issued: int = world.farm.economy_issued()
	var live_ledger_entries: int = world.farm.economy_ledger_entries().size()
	_expect(live_cash == live_issued, "restart: cash is conserved before the restart")

	reopened = HeadlessWorld.new()
	var opened: Dictionary = reopened.open(test_root, T_BUILD_DONE, WORLD_ID)
	_step("reopen", opened)
	_expect(bool(opened.get("ok", false)), "restart: the same directory reopens")
	_expect(str(opened.get("kind", "")) == "loaded", "restart: the save is loaded, not recreated")
	_expect(is_equal_approx(reopened.now_utc, T_BUILD_DONE), "restart: the clock is restored")
	_expect(reopened.nature.get_seed() == SEED, "restart: the fixed seed survives")

	_expect(reopened.farm.bag(A)[GREENS] == 1, "restart: A's remaining greens survive")
	_expect(reopened.farm.bag(B)[GREENS] == 2, "restart: B's bought greens survive")
	_expect(reopened.farm.economy_cash(A) == 126, "restart: A's cash survives")
	_expect(reopened.farm.economy_cash(B) == 108, "restart: B's cash survives")
	_expect(int(reopened.farm.economy_bank().cash) == 2005,
		"restart: the bank balance survives")
	_expect(str(reopened.farm.economy_loan("peace_borrow").status) == "repaid",
		"restart: the repaid loan survives")
	_expect(reopened.farm.market_trades().size() == 1, "restart: the local trade survives")
	_expect(str(reopened.farm.market_order("peace_rest_greens").status) == "open",
		"restart: the resting sell order survives")
	_expect(int(reopened.farm.market_order("peace_rest_greens").remaining) == 2,
		"restart: both resting units survive")
	_expect(str(reopened.farm.building_state("yard_a", T_BUILD_DONE)) == "done",
		"restart: the finished cottage survives")
	_expect(str(reopened.farm.buildings_at(T_BUILD_DONE)["yard_a"].owner) == A,
		"restart: the cottage owner survives")
	_expect(str(reopened.territory_view().parcels["parcel_01"].owner) == A,
		"restart: the claimed parcel survives")
	_expect(int(reopened.farm.snapshot().kitchen.records.leaf_stir.made) == 1
		and int(reopened.farm.snapshot().kitchen.records.leaf_stir.shared) == 1,
		"restart: the cooked and shared dish survives")
	_expect(FarmCommand.has_committed(reopened.farm, "peace_rest_greens"),
		"restart: the resting order command is still replay-safe")

	_expect(reopened.farm.snapshot().harvested == live.harvested,
		"restart: the produced counter is identical")
	_expect(reopened.farm.snapshot().bags == live.bags,
		"restart: the bag document is identical")
	_expect(reopened.farm.snapshot().buildings == live.buildings,
		"restart: the building document is identical")
	_expect(reopened.decorations.snapshot() == world.decorations.snapshot(),
		"restart: the decoration document is identical")
	_expect(reopened.farm.economy_ledger_entries().size() == live_ledger_entries,
		"restart: the ledger entry count is identical")

	_check_cash_on(reopened, "after restart")
	_check_goods_on(reopened, "after restart")
	var reconcile: Dictionary = reopened.farm.economy_reconcile()
	_expect(bool(reconcile.ok), "restart: the double-entry ledger reconciles")
	_expect(int(reconcile.total_cash) == int(reconcile.issued),
		"restart: reconcile total cash equals issued")
	_expect(int(reconcile.issuance) - int(reconcile.burned) == int(reconcile.issued),
		"restart: issuance minus burns equals the net issue")
	_expect(int(reconcile.accounts) + int(reconcile.merchant) + int(reconcile.escrow)
		+ int(reconcile.bank) == int(reconcile.total_cash),
		"restart: accounts + merchant + escrow + bank equals total cash")

	_expect(reopened.residents_enabled == false, "restart: residents stay disabled")
	_expect(not bool(reopened.residents_view().available), "restart: residents report disabled")
	_expect(reopened.participation_view().available == false,
		"restart: no participation regime exists")
	_expect(_conflict_rows(reopened) == 0, "restart: no conflict is recorded")
	_expect(reopened.participation.is_empty(),
		"restart: the participation document stays the hostless empty table")
	_expect((reopened.conflicts.get("consumed", {}) as Dictionary).is_empty(),
		"restart: the conflict context holds no consumed engagement")
	_expect(reopened.units_view().units.is_empty(), "restart: no unit was ever recruited")
	var accounts: Dictionary = reopened.farm.economy_snapshot().accounts
	var npc_accounts: int = 0
	for owner: Variant in accounts:
		if str(owner).begins_with("npc_"):
			npc_accounts += 1
	_expect(npc_accounts == 0, "restart: no resident ever opened an account")
	_expect(not reopened.residents_enabled, "restart: the resident flag is still off")
	for filename: String in ["participation.json", "conflicts.json", "units.json",
			"residents.json", "npc_residents.json", "organizations.json",
			"public_funds.json", "public_works.json"]:
		_expect(not FileAccess.file_exists(test_root.path_join(filename)),
			"restart: %s was never written" % filename)
	for filename: String in ["farm.json", "nature.json", "territory.json"]:
		_expect(FileAccess.file_exists(test_root.path_join(filename)),
			"restart: %s exists" % filename)


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

func _phase(name: String) -> void:
	print("PHASE " + name)


func _execute(command: Dictionary, actor: String, label: String) -> Dictionary:
	var result: Dictionary = world.execute(command, actor)
	_step(label + " [" + str(command.get("id", "")) + "]", result)
	_expect(bool(result.get("ok", false)), label + ": accepted (reason=" + str(result.get("reason", "")) + ")")
	_expect(str(result.get("stage", "")) == "committed", label + ": committed as new work")
	_expect(not bool(result.get("duplicate", true)), label + ": is not a duplicate")
	return result


## Runs one real kitchen action on a candidate and persists it through the same
## store boundary the local scene uses. Returns ok/reason only.
func _kitchen_persisted(action: String, request: Dictionary, revision: int) -> Dictionary:
	var candidate: RefCounted = world.farm.copy()
	var result: Dictionary = candidate.kitchen_action(
		action, request, revision, world.now_utc, world.decorations.snapshot())
	if not bool(result.get("ok", false)):
		return {"ok": false, "reason": str(result.get("reason", ""))}
	var decorations := Decorations.new()
	if not decorations.restore_snapshot(world.decorations.snapshot()):
		return {"ok": false, "reason": "restore_decorations"}
	var snapshot: Dictionary = candidate.snapshot()
	decorations.unlock(snapshot.harvested, snapshot.kitchen)
	var saved: Dictionary = world.store.save_state(candidate, decorations)
	if not bool(saved.get("ok", false)):
		return {"ok": false, "reason": "save_" + str(saved.get("kind", ""))}
	world.farm.accept(candidate)
	world.decorations = decorations
	return {"ok": true, "reason": ""}


func _step(label: String, result: Dictionary) -> void:
	var line: String = "%s ok=%s reason=%s" % [
		label, str(bool(result.get("ok", false))), str(result.get("reason", ""))]
	if result.has("stage"):
		line += " stage=" + str(result.get("stage", ""))
	steps.append(line)
	print("STEP " + line)


func _conflict_rows(authority: RefCounted) -> int:
	var view: Dictionary = authority.conflicts_view()
	var rows: int = int(view.get("sequence", 0))
	rows += (view.get("targets", []) as Array).size()
	rows += (view.get("recent", []) as Array).size()
	return rows


func _check_cash(label: String) -> void:
	_check_cash_on(world, label)


func _check_cash_on(authority: RefCounted, label: String) -> void:
	var issued: int = authority.farm.economy_issued()
	var total: int = authority.farm.economy_total_cash()
	var reconcile: Dictionary = authority.farm.economy_reconcile()
	_expect(total == issued, "cash[%s]: total cash (%d) equals issued (%d)"
		% [label, total, issued])
	_expect(bool(reconcile.get("ok", false)),
		"cash[%s]: the double-entry ledger reconciles" % label)
	_expect(int(reconcile.get("total_cash", -1)) == total,
		"cash[%s]: the reconcile total matches the authority" % label)
	_expect(int(reconcile.get("issued", -1)) == issued,
		"cash[%s]: the reconcile issued matches the authority" % label)
	_expect(int(reconcile.get("accounts", 0)) + int(reconcile.get("merchant", 0))
		+ int(reconcile.get("escrow", 0)) + int(reconcile.get("bank", 0)) == total,
		"cash[%s]: accounts + merchant + escrow + bank equals total" % label)


func _check_goods(label: String) -> void:
	_check_goods_on(world, label)


func _check_goods_on(authority: RefCounted, label: String) -> void:
	var census: Dictionary = _goods_census(authority)
	for good_id: String in census.ids:
		var left: int = int(census.produced[good_id]) + int(census.granted[good_id])
		var right: int = int(census.bags[good_id]) + int(census.merchant[good_id]) \
			+ int(census.sell_escrow[good_id]) + int(census.transit[good_id]) \
			+ int(census.lost[good_id]) + int(census.kitchen[good_id])
		_expect(left == right,
			"goods[%s]: %s produced+granted=%d == held+consumed=%d"
			% [label, good_id, left, right])
	_expect(int(census.produced_total) + int(census.granted_total)
		== int(census.bags_total) + int(census.merchant_total) + int(census.sell_escrow_total)
		+ int(census.transit_total) + int(census.lost_total) + int(census.kitchen_total),
		"goods[%s]: the catalog-wide total is conserved" % label)


## Endpoint census. `kitchen` is derived from the authoritative kitchen
## document: every made dish consumed one crop, and every non-empty station
## holds one crop in progress. It is not caller bookkeeping.
func _goods_census(authority: RefCounted) -> Dictionary:
	var ids: Array[String] = []
	ids.assign(Catalog.goods_ids())
	var bags: Dictionary = {}
	var merchant: Dictionary = {}
	var sell_escrow: Dictionary = {}
	var transit: Dictionary = {}
	var lost: Dictionary = {}
	var granted: Dictionary = {}
	var produced: Dictionary = {}
	var kitchen_by_crop: Dictionary = {}
	for good_id: String in ids:
		bags[good_id] = 0
		merchant[good_id] = 0
		sell_escrow[good_id] = 0
		transit[good_id] = 0
		lost[good_id] = 0
		granted[good_id] = 0
		produced[good_id] = 0
		kitchen_by_crop[good_id] = 0
	var snapshot: Dictionary = authority.farm.snapshot()
	var merchant_row: Dictionary = authority.farm.market_merchant()
	for good_id: String in ids:
		produced[good_id] = int(snapshot.harvested.get(good_id, 0))
		granted[good_id] = int((merchant_row.get("granted", {}) as Dictionary).get(good_id, 0))
		merchant[good_id] = int((merchant_row.get("goods", {}) as Dictionary).get(good_id, 0))
	# Every stored pocket is enumerated, not a hard-coded owner list, so a new
	# bag owner in the authority could not hide goods from the identity.
	for owner: Variant in snapshot.bags:
		var pocket: Dictionary = snapshot.bags[owner]
		for good_id: String in ids:
			bags[good_id] = int(bags[good_id]) + int(pocket.get(good_id, 0))
	for good_id: String in ids:
		bags[good_id] = int(bags[good_id]) + int(snapshot.inventory.get(good_id, 0))
	for order: Dictionary in authority.farm.market_orders():
		if str(order.status) == "open" and str(order.side) == "sell":
			var order_good: String = str(order.good)
			if sell_escrow.has(order_good):
				sell_escrow[order_good] = int(sell_escrow[order_good]) + int(order.remaining)
	for shipment: Dictionary in authority.farm.market_shipments():
		if str(shipment.status) == "in_transit" and transit.has(str(shipment.good)):
			transit[str(shipment.good)] = int(transit[str(shipment.good)]) + int(shipment.quantity)
	for event: Dictionary in authority.farm.market_losses():
		if lost.has(str(event.good)):
			lost[str(event.good)] = int(lost[str(event.good)]) + int(event.quantity)
	var kitchen: Dictionary = snapshot.kitchen
	for recipe: Variant in kitchen.records:
		var record: Dictionary = kitchen.records[recipe]
		var consumed: int = int(record.made)
		# The dish recipe's crop is the recorded last_crop for completed jobs.
		var crop: String = str(record.last_crop)
		if consumed > 0 and kitchen_by_crop.has(crop):
			kitchen_by_crop[crop] = int(kitchen_by_crop[crop]) + consumed
	for station: Variant in kitchen.jobs:
		var job: Dictionary = kitchen.jobs[station]
		if job.is_empty():
			continue
		var crop_id: String = str(job.crop)
		if kitchen_by_crop.has(crop_id):
			kitchen_by_crop[crop_id] = int(kitchen_by_crop[crop_id]) + 1
	return {
		"ids": ids, "bags": bags, "merchant": merchant, "sell_escrow": sell_escrow,
		"transit": transit, "lost": lost, "granted": granted, "produced": produced,
		"kitchen": kitchen_by_crop,
		"bags_total": _sum(ids, bags), "merchant_total": _sum(ids, merchant),
		"sell_escrow_total": _sum(ids, sell_escrow),
		"transit_total": _sum(ids, transit), "lost_total": _sum(ids, lost),
		"granted_total": _sum(ids, granted), "produced_total": _sum(ids, produced),
		"kitchen_total": _sum(ids, kitchen_by_crop),
	}


static func _sum(ids: Array[String], values: Dictionary) -> int:
	var total: int = 0
	for good_id: String in ids:
		total += int(values.get(good_id, 0))
	return total


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS " + message)
	else:
		failures.append(message)
		print("FAIL " + message)
