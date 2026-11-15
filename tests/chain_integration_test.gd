extends SceneTree
## M13-01 end-to-end authority chain. One fixed seed, one fixed logical clock,
## one traceable evidence chain across every existing gameplay link:
##
##   sow -> weather/moisture/disaster growth -> harvest into the actor's bag ->
##   farm-market sell order -> crossing fill with another account (fee burned) ->
##   declared-risk shipment (one delivered, one lost) -> bank open / borrow /
##   repay / overdue -> cadastral claim and build-permission query.
##
## Every phase asserts that the previous phase's asset landed where the rules
## say it landed, and the scripted trade sequence is fixed: no randomness and
## no wall clock. Goods and cash conservation are checked at each phase with
## the identities
##   produced + merchant grant == bags + merchant stock + sell escrow
##                                + transit + lost
##   total_cash == issued
## plus the double-entry reconcile report.
##
## Repeated command ids must replay without a second record, and the key links
## must still hold after save -> reopen.
##
## Deliberately not covered: scene/UI presentation, networking, Windows
## execution, and build enforcement by the cadastre. `FarmState.build` is not
## gated by parcels yet (ADR-023 decision 6), so the land link asserts the
## permission query only; the gap is recorded in RECORD-05.

const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Market = preload("res://farm/market_state.gd")
const Catalog = preload("res://farm/economy_catalog.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const TerritoryState = preload("res://world/territory_state.gd")

const SEED: int = 101507
const START: float = 1800014400.0
const BLOCK_SECONDS: float = 21600.0
const RULES_VERSION: int = 2
const WORLD_ID: String = "chain-world"
const A: String = "chain_a"
const B: String = "chain_b"
const GREENS: String = "greens"
const CARROT: String = "carrot"
const FARM_MARKET: String = "farm_market"
const HARBOR_MARKET: String = "harbor_market"
# The scripted shipment departures. The declared-risk roll is a pure function
# of the persisted row; these two instants give one delivery and one loss.
const T_SHIP_ONE: float = 262600.0
const T_SHIP_ONE_ARRIVE: float = 263200.0
const T_SHIP_TWO: float = 264000.0
const T_SHIP_TWO_ARRIVE: float = 264600.0
const SHIP_ONE_ROLL: int = 830
const SHIP_TWO_ROLL: int = 244
const LOSS_PERMILLE: int = 250
# Bank/loan fixture: 100 principal (5 fee) for A, 200 principal (10 fee) for B.
const LOAN_TERM: int = 604800
const T_BANK: float = 264600.0
const T_STORM: float = 669600.0
const T_STORM_END: float = 691200.0
const T_OVERDUE: float = 869400.0

var checks: int = 0
var failures: Array[String] = []
var test_root: String = ""
var world: RefCounted
var reopened: RefCounted
var produced: Dictionary = {}
var commands: Dictionary = {}


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	# The required per-process parent plus a unique child: a reused PID can never
	# inherit a previous run's save files.
	test_root = project_root.get_base_dir().path_join(
		".local/verification/chain-integration-%d/run-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(test_root)
	_run_chain()
	for failure: String in failures:
		push_error(failure)
	print("CHAIN_INTEGRATION_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run_chain() -> void:
	_boot()
	_phase_sow_and_grow()
	_phase_harvest()
	_phase_economy_open()
	_phase_trade()
	_phase_shipping()
	_phase_bank()
	_phase_storm_and_overdue()
	_phase_cadastre()
	_phase_replays()
	_phase_restart()


# ---------------------------------------------------------------------------
# Boot: one seeded world at one fixed instant.
# ---------------------------------------------------------------------------

func _boot() -> void:
	_phase("boot")
	var saved: Dictionary = NatureStore.new(test_root).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	_expect(saved.ok, "fixture: the fixed seed is persisted before the world opens")
	world = HeadlessWorld.new()
	var opened: Dictionary = world.open(test_root, START, WORLD_ID)
	_expect(bool(opened.get("ok", false)), "boot: the authority opens the world")
	_expect(str(opened.get("kind", "")) == "created", "boot: the directory starts as a fresh world")
	_expect(world.nature.get_seed() == SEED, "boot: the fresh farm adopts the persisted seed")
	_expect(str(world.world_id) == WORLD_ID, "boot: the cadastre carries the requested world id")
	_expect(is_equal_approx(world.now_utc, START), "boot: the logical clock starts at the fixed UTC")
	_expect(world.farm.field_ids().size() == 6, "boot: the default layout has six fields")
	var nature: Dictionary = world.nature_view()
	_expect(str(nature.weather.kind) == "clear", "boot: block 83334 is clear for this seed")
	_expect(is_equal_approx(float(nature.weather.start_utc), START),
		"boot: the clear block starts exactly at the fixed clock")
	_expect(is_equal_approx(float(nature.weather.end_utc), START + BLOCK_SECONDS),
		"boot: the first weather block ends six hours later")
	_expect(nature.disaster.is_empty(), "boot: no disaster covers the start instant")
	_expect(world.farm.hud_state().inventory[GREENS] == 0, "boot: the shared inventory is empty")
	_expect(world.farm.bag(A)[GREENS] == 0 and world.farm.bag(B)[GREENS] == 0,
		"boot: both player bags start empty")
	_expect(world.farm.economy_issued() == 0 and world.farm.economy_total_cash() == 0,
		"boot: no money has been issued yet")


# ---------------------------------------------------------------------------
# Link 1: sowing and weather-driven growth (normal, dry half-rate, rain).
# ---------------------------------------------------------------------------

func _phase_sow_and_grow() -> void:
	_phase("sow_grow")
	var nature: Dictionary = {}
	for index: int in range(1, 7):
		var cell_id: String = "cell_%02d" % index
		var command: Dictionary = FarmCommand.make_sow(
			"chain_sow_greens_%02d" % index, "field_01", cell_id, GREENS, START)
		commands["sow_greens_%02d" % index] = command
		_execute(command, A, "sow greens %s" % cell_id)
		var cell: Dictionary = world.farm.get_cell("field_01", cell_id)
		_expect(str(cell.crop_id) == GREENS, "sow: %s holds the sown greens" % cell_id)
		_expect(str(cell.planted_by) == A, "sow: %s is owned by A" % cell_id)
		_expect(float(cell.growth_seconds) == 0.0, "sow: %s starts at zero growth" % cell_id)
	var carrot_sow: Dictionary = FarmCommand.make_sow(
		"chain_sow_carrot_01", "field_02", "cell_01", CARROT, START)
	commands["sow_carrot_01"] = carrot_sow
	_execute(carrot_sow, A, "sow the carrot probe")
	var carrot_cell: Dictionary = world.farm.get_cell("field_02", "cell_01")
	_expect(str(carrot_cell.crop_id) == CARROT and str(carrot_cell.planted_by) == A,
		"sow: the carrot probe is owned by A")
	_expect(float(carrot_cell.moisture) == 0.5, "sow: a fresh cell starts at moisture 0.5")
	_expect(float(carrot_cell.growth_rate) == 1.0,
		"sow: a damp clear block grows at the normal rate")

	var advanced: Dictionary = world.advance_to(_at(3600.0))
	_expect(bool(advanced.get("ok", false)), "growth: the world advances one hour")
	_expect(int(advanced.get("segments", 0)) > 0, "growth: advancement segments on crop boundaries")
	carrot_cell = world.farm.get_cell("field_02", "cell_01")
	_expect(float(carrot_cell.growth_seconds) == 3600.0,
		"growth: one hour of damp clear weather adds exactly 3600 seconds")
	_expect(float(carrot_cell.moisture) == 0.5,
		"growth: the soil stays damp inside the block")
	var mature_greens: int = 0
	for index: int in range(1, 7):
		if str(world.farm.get_cell("field_01", "cell_%02d" % index).stage) == "mature":
			mature_greens += 1
	_expect(mature_greens == 6, "growth: all six greens mature inside the first block")
	_expect(str(world.farm.get_cell("field_01", "cell_01").stage) == "mature",
		"growth: the 30-minute greens reach the mature stage")

	world.advance_to(_at(7199.0))
	carrot_cell = world.farm.get_cell("field_02", "cell_01")
	_expect(float(carrot_cell.growth_seconds) == 7199.0,
		"growth: one second short of the duration the carrot has 7199 seconds")
	_expect(str(carrot_cell.stage) != "mature", "growth: the carrot is not mature at 7199 seconds")
	world.advance_to(_at(7200.0))
	carrot_cell = world.farm.get_cell("field_02", "cell_01")
	_expect(float(carrot_cell.growth_seconds) == 7200.0,
		"growth: the carrot reaches its full 7200-second duration")
	_expect(str(carrot_cell.stage) == "mature", "growth: the carrot matures at exactly 7200 seconds")

	world.advance_to(_at(21600.0))
	nature = world.nature_view()
	_expect(str(nature.weather.kind) == "cloudy", "weather: the second block is cloudy")
	_expect(float(world.farm.get_cell("field_02", "cell_01").moisture) == 0.375,
		"weather: one completed clear block drains exactly 0.125")
	_expect(str(world.farm.get_cell("field_02", "cell_01").moisture_label) == "dry",
		"weather: moisture 0.375 reads as dry")
	var hazards: Dictionary = world.disaster_view()
	_expect(not hazards.disaster.is_empty(), "disaster: the seeded drought block is visible")
	_expect(str(hazards.disaster.kind) == "drought", "disaster: the event is a drought")
	_expect(int(hazards.disaster.severity) == 3, "disaster: the fixed severity is 3")
	_expect(is_equal_approx(float(hazards.disaster.starts_utc), _at(21600.0)),
		"disaster: the drought starts on the block boundary")

	var dry_sow: Dictionary = FarmCommand.make_sow(
		"chain_sow_carrot_dry", "field_02", "cell_02", CARROT, _at(21600.0))
	commands["sow_carrot_dry"] = dry_sow
	_execute(dry_sow, A, "sow the dry-soil carrot")
	var dry_cell: Dictionary = world.farm.get_cell("field_02", "cell_02")
	_expect(float(dry_cell.moisture) == 0.375,
		"growth: the new cell inherits the dry block moisture")
	_expect(float(dry_cell.growth_rate) == 0.5, "growth: dry clear/cloudy soil halves the rate")
	_expect(str(dry_cell.stage) == "sprout", "growth: the fresh carrot is a sprout")

	world.advance_to(_at(25200.0))
	dry_cell = world.farm.get_cell("field_02", "cell_02")
	_expect(float(dry_cell.growth_seconds) == 1800.0,
		"growth: 3600 elapsed dry seconds add exactly 1800 growth seconds")
	_expect(float(dry_cell.growth_rate) == 0.5, "growth: the halved rate is still reported")
	_expect(str(dry_cell.stage) == "sprout", "growth: at 1800 of 7200 seconds the carrot is a sprout")

	world.advance_to(_at(43200.0))
	dry_cell = world.farm.get_cell("field_02", "cell_02")
	_expect(float(dry_cell.growth_seconds) == 7200.0,
		"growth: the dry carrot still reaches its duration")
	_expect(str(dry_cell.stage) == "mature", "growth: the dry carrot matures on the drought boundary")
	_expect(float(dry_cell.moisture) == 0.1875,
		"weather: the drought block removes another 0.125 after the cloudy loss")
	_expect(float(world.farm.get_cell("field_02", "cell_01").moisture) == 0.1875,
		"weather: every undisturbed cell shares the same block moisture")
	nature = world.nature_view()
	_expect(str(nature.weather.kind) == "rain", "weather: the third block is rain")
	_expect(world.disaster_view().disaster.is_empty(), "disaster: the one-block drought has ended")

	var rain_sow: Dictionary = FarmCommand.make_sow(
		"chain_sow_greens_rain", "field_02", "cell_03", GREENS, _at(43200.0))
	commands["sow_greens_rain"] = rain_sow
	_execute(rain_sow, A, "sow greens in the rain block")
	var rain_cell: Dictionary = world.farm.get_cell("field_02", "cell_03")
	_expect(float(rain_cell.moisture) == 0.1875,
		"rain: the new cell follows the same dry history")
	_expect(str(rain_cell.moisture_label) == "dry",
		"rain: the soil is dry even though it is raining")
	_expect(float(rain_cell.growth_rate) == 1.0,
		"rain: rain overrides the dry-soil penalty and grows at 1.0")

	world.advance_to(_at(44100.0))
	rain_cell = world.farm.get_cell("field_02", "cell_03")
	_expect(float(rain_cell.growth_seconds) == 900.0,
		"rain: 900 elapsed seconds add 900 full-rate growth seconds")
	_expect(str(rain_cell.stage) == "young", "rain: at 900 of 1800 seconds the greens are young")
	world.advance_to(_at(45000.0))
	rain_cell = world.farm.get_cell("field_02", "cell_03")
	_expect(float(rain_cell.growth_seconds) == 1800.0,
		"rain: the greens reach their full duration")
	_expect(str(rain_cell.stage) == "mature", "rain: the greens mature at full rate on dry soil")

	world.advance_to(_at(64800.0))
	_expect(float(world.farm.get_cell("field_02", "cell_03").moisture) == 0.4375,
		"weather: a completed rain block adds exactly 0.25")
	_expect(str(world.nature_view().weather.kind) == "rain", "weather: the fourth block is also rain")
	world.advance_to(_at(86400.0))
	_expect(float(world.farm.get_cell("field_02", "cell_03").moisture) == 0.6875,
		"weather: the second rain block reaches 0.6875")
	_expect(str(world.farm.get_cell("field_02", "cell_03").moisture_label) == "damp",
		"weather: moisture 0.6875 reads as damp, not wet")
	world.advance_to(_at(90000.0))
	_expect(is_equal_approx(world.now_utc, _at(90000.0)), "clock: the world reaches the harvest instant")


# ---------------------------------------------------------------------------
# Link 2: harvest into the actor's own bag.
# ---------------------------------------------------------------------------

func _phase_harvest() -> void:
	_phase("harvest")
	_expect(world.farm.bag(A)[GREENS] == 0, "harvest: A's bag is empty before the basket")
	for index: int in range(1, 7):
		var command: Dictionary = FarmCommand.make(
			"chain_harvest_greens_%02d" % index, "field_01", "cell_%02d" % index, _at(90000.0))
		commands["harvest_%02d" % index] = command
		var result: Dictionary = _execute(command, A, "harvest greens cell_%02d" % index)
		_expect(str(result.get("reward_crop_id", "")) == GREENS,
			"harvest: cell_%02d yields greens" % index)
		_expect(int(result.get("reward_amount", 0)) == 1,
			"harvest: cell_%02d yields one basket" % index)
		produced[GREENS] = int(produced.get(GREENS, 0)) + 1
	_expect(world.farm.bag(A)[GREENS] == 6, "harvest: all six baskets are in A's own bag")
	_expect(world.farm.snapshot().harvested[GREENS] == 6,
		"harvest: the produced counter records six greens")
	_expect(world.farm.hud_state().inventory[GREENS] == 0,
		"harvest: nothing leaked into the shared inventory")
	var emptied: int = 0
	var moisture_kept: int = 0
	for index: int in range(1, 7):
		var cell: Dictionary = world.farm.get_cell("field_01", "cell_%02d" % index)
		if str(cell.crop_id) == "":
			emptied += 1
		if float(cell.moisture) == 0.6875:
			moisture_kept += 1
	_expect(emptied == 6, "harvest: every picked cell is empty")
	_expect(moisture_kept == 6, "harvest: picking does not irrigate; the block moisture stays")
	_expect(world.farm.bag(B)[GREENS] == 0, "harvest: none of the baskets reached B")
	_check_goods("harvest complete")


# ---------------------------------------------------------------------------
# Link 3: accounts, merchant budget and the first goods grant.
# ---------------------------------------------------------------------------

func _phase_economy_open() -> void:
	_phase("accounts_merchant")
	var account_a: Dictionary = FarmCommand.make_account_open("chain_account_a", _at(90000.0))
	commands["account_a"] = account_a
	_execute(account_a, A, "open A's account")
	_expect(world.farm.economy_cash(A) == 120, "account: A receives the 120 COIN opening grant")
	_expect(bool(world.farm.economy_snapshot().accounts[A].granted),
		"account: A's one-time grant is marked used")
	var account_b: Dictionary = FarmCommand.make_account_open("chain_account_b", _at(90000.0))
	commands["account_b"] = account_b
	_execute(account_b, B, "open B's account")
	_expect(world.farm.economy_cash(B) == 120, "account: B receives the 120 COIN opening grant")
	_expect(world.farm.economy_issued() == 240, "account: the two grants issue exactly 240 COIN")
	_expect(world.farm.economy_total_cash() == 240, "account: all issued cash is in the two accounts")
	_check_cash("accounts opened")

	var open_market: Dictionary = FarmCommand.make_market_open("chain_market_open", _at(90000.0))
	commands["market_open"] = open_market
	_execute(open_market, "", "open the world merchant")
	var merchant: Dictionary = world.farm.market_merchant()
	_expect(bool(merchant.opened), "merchant: the world merchant is open")
	_expect(str(merchant.opened_by) == "chain_market_open",
		"merchant: the opening command is recorded")
	_expect(is_equal_approx(float(merchant.opened_utc), _at(90000.0)),
		"merchant: the opening time is the world clock")
	_expect(int(merchant.cash) == 260,
		"merchant: the 600 budget leaves 260 after the bid escrow")
	_expect(int(merchant.granted[GREENS]) == 20, "merchant: 20 greens were granted")
	var stocked: int = 0
	for good_id: String in Catalog.goods_ids():
		if int(merchant.goods[good_id]) == 16:
			stocked += 1
	_expect(stocked == 6, "merchant: every catalog stock is 16 after the ask escrow")
	_expect(world.farm.market_orders().size() == 12,
		"merchant: twelve rolling quote rows are resting")
	var quote_greens: Dictionary = world.farm.market_quote(GREENS)
	_expect(int(quote_greens.bid) == 5 and int(quote_greens.ask) == 7,
		"merchant: greens bid 5 / ask 7 around the base price 6")
	_expect(int(quote_greens.budget) == 260 and int(quote_greens.stock) == 16,
		"merchant: the quote reports its cash and stock")
	var funds: Dictionary = world.farm.economy_funds(Market.MERCHANT)
	_expect(int(funds.frozen) == 340, "merchant: 340 COIN is frozen in the bid quotes")
	_expect(int(funds.total) == 600, "merchant: cash plus escrow is still the 600 budget")
	_expect(world.farm.economy_issued() == 840, "merchant: the budget issues 600 COIN")
	_check_cash("merchant opened")
	_check_goods("catalog stocked")


# ---------------------------------------------------------------------------
# Link 4: farm-market order and a crossing fill with another account.
# ---------------------------------------------------------------------------

func _phase_trade() -> void:
	_phase("trade")
	_expect(world.farm.bag(A)[GREENS] == 6, "trade: the seller still owns the six harvested greens")
	var sell: Dictionary = FarmCommand.make_market_place(
		"chain_sell_greens", "sell", GREENS, 6, 2, _at(93600.0), _at(90000.0))
	commands["sell"] = sell
	_execute(sell, A, "A places a sell order")
	var sell_row: Dictionary = world.farm.market_order("chain_sell_greens")
	_expect(str(sell_row.status) == "open", "trade: the sell order rests open")
	_expect(int(sell_row.remaining) == 2 and int(sell_row.reserved) == 2,
		"trade: two units move from the bag into the order")
	_expect(world.farm.bag(A)[GREENS] == 4, "trade: A's bag drops from 6 to 4")
	_expect(world.farm.market_trades().is_empty(), "trade: no fill happens without a buyer")

	var buy: Dictionary = FarmCommand.make_market_place(
		"chain_buy_greens", "buy", GREENS, 7, 2, _at(93600.0), _at(90000.0))
	commands["buy"] = buy
	var bought: Dictionary = _execute(buy, B, "B places a crossing buy order")
	_expect(int(bought.get("market_matched", 0)) == 1, "trade: B's commit sweeps exactly one fill")
	var trades: Array = world.farm.market_trades()
	_expect(trades.size() == 1, "trade: exactly one trade row is recorded")
	var trade: Dictionary = trades[0]
	_expect(str(trade.id) == "trade_1", "trade: the trade id is trade_1")
	_expect(str(trade.good) == GREENS, "trade: the trade is for greens")
	_expect(int(trade.price) == 6, "trade: the maker price is A's ask of 6")
	_expect(int(trade.quantity) == 2, "trade: both units cross")
	_expect(int(trade.notional) == 12, "trade: notional is 2 units at 6 COIN")
	_expect(int(trade.fee) == 1, "trade: the flat 1 COIN fee is separated")
	_expect(str(trade.buy_owner) == B and str(trade.sell_owner) == A,
		"trade: the two accounts are the counterparties")
	_expect(int(trade.sell_credit) == 11, "trade: the seller receives notional minus the fee")
	_expect(int(trade.buy_refund) == 2, "trade: the buyer's price improvement is refunded")
	_expect(world.farm.economy_cash(A) == 131, "trade: A's cash rises from 120 to 131")
	_expect(world.farm.economy_cash(B) == 108, "trade: B paid 14 and was refunded 2")
	_expect(world.farm.bag(B)[GREENS] == 2, "trade: the bought greens land in B's own bag")
	_expect(str(world.farm.market_order("chain_buy_greens").status) == "filled",
		"trade: the buy order is filled")
	_expect(str(world.farm.market_order("chain_sell_greens").status) == "filled",
		"trade: the sell order is filled")
	_expect(world.farm.economy_issued() == 839, "trade: the 1 COIN fee is burned out of the issue")
	_expect(int(world.farm.economy_reconcile().burned) == 1, "trade: the ledger shows the 1 COIN burn")
	_expect(_entries_of_kind("trade").size() == 1, "trade: one double-entry trade journal row exists")
	_check_cash("trade settled")
	_check_goods("after trade")


# ---------------------------------------------------------------------------
# Link 5: declared-risk shipping, one delivery and one loss.
# ---------------------------------------------------------------------------

func _phase_shipping() -> void:
	_phase("shipping")
	_expect(world.farm.bag(A)[GREENS] == 4, "ship: A owns four greens after the sale")
	world.advance_to(_at(T_SHIP_ONE))
	_expect(is_equal_approx(world.now_utc, _at(T_SHIP_ONE)),
		"ship: the world clock reaches the first departure")
	var roll_one: int = Market.transport_loss_roll(
		1, A, GREENS, 1, FARM_MARKET, HARBOR_MARKET, _at(T_SHIP_ONE))
	_expect(roll_one == SHIP_ONE_ROLL, "ship: the fixed roll for shipment 1 is 830")
	_expect(not Market.transport_loss_expected(
		1, A, GREENS, 1, FARM_MARKET, HARBOR_MARKET, _at(T_SHIP_ONE)),
		"ship: shipment 1 is deterministically delivered")
	var ship_one: Dictionary = FarmCommand.make_market_ship(
		"chain_ship_1", FARM_MARKET, HARBOR_MARKET, GREENS, 1, _at(T_SHIP_ONE),
		Market.SHIPMENT_RISK_DECLARED)
	commands["ship1"] = ship_one
	_execute(ship_one, A, "A ships one declared-risk basket")
	var row: Dictionary = world.farm.market_shipment("chain_ship_1")
	_expect(int(row.sequence) == 1, "ship: the first shipment has sequence 1")
	_expect(str(row.risk) == Market.SHIPMENT_RISK_DECLARED, "ship: the declared risk is persisted")
	_expect(str(row.status) == Market.SHIPMENT_STATUS_TRANSIT, "ship: the shipment is in transit")
	_expect(is_equal_approx(float(row.depart_utc), _at(T_SHIP_ONE)),
		"ship: departure is the command instant")
	_expect(is_equal_approx(float(row.arrive_utc), _at(T_SHIP_ONE_ARRIVE)),
		"ship: arrival is exactly 600 seconds after departure")
	_expect(int(row.fee) == 2, "ship: the flat 2 COIN fee is recorded")
	_expect(world.farm.bag(A)[GREENS] == 3, "ship: the basket leaves A's bag for the transit row")
	_expect(_transit_units() == 1, "ship: exactly one unit is in transit")
	_expect(world.farm.economy_cash(A) == 129, "ship: the 2 COIN fee is paid by A")
	_expect(world.farm.economy_issued() == 837, "ship: the 2 COIN fee is burned out of the issue")
	_check_cash("shipment 1 in transit")
	_check_goods("shipment 1 in transit")

	var arrival: Dictionary = world.advance_to(_at(T_SHIP_ONE_ARRIVE))
	_expect(int(arrival.get("market_delivered", 0)) == 1,
		"ship: the arrival sweep delivers one shipment")
	row = world.farm.market_shipment("chain_ship_1")
	_expect(str(row.status) == Market.SHIPMENT_STATUS_DELIVERED, "ship: shipment 1 is delivered")
	_expect(world.farm.market_deliveries().size() == 1, "ship: one delivery row is written")
	var delivery: Dictionary = world.farm.market_deliveries()[0]
	_expect(str(delivery.shipment_id) == "chain_ship_1", "ship: the delivery names shipment 1")
	_expect(int(delivery.quantity) == 1, "ship: the delivery returns one unit")
	_expect(world.farm.bag(A)[GREENS] == 4, "ship: the delivered basket returns to A's bag")
	_expect(_transit_units() == 0, "ship: the transit table is empty after delivery")
	_check_cash("shipment 1 delivered")
	_check_goods("shipment 1 delivered")

	world.advance_to(_at(T_SHIP_TWO))
	var roll_two: int = Market.transport_loss_roll(
		2, A, GREENS, 1, FARM_MARKET, HARBOR_MARKET, _at(T_SHIP_TWO))
	_expect(roll_two == SHIP_TWO_ROLL, "ship: the fixed roll for shipment 2 is 244")
	_expect(Market.transport_loss_expected(
		2, A, GREENS, 1, FARM_MARKET, HARBOR_MARKET, _at(T_SHIP_TWO)),
		"ship: shipment 2 is deterministically lost")
	var ship_two: Dictionary = FarmCommand.make_market_ship(
		"chain_ship_2", FARM_MARKET, HARBOR_MARKET, GREENS, 1, _at(T_SHIP_TWO),
		Market.SHIPMENT_RISK_DECLARED)
	commands["ship2"] = ship_two
	_execute(ship_two, A, "A ships a second declared-risk basket")
	row = world.farm.market_shipment("chain_ship_2")
	_expect(int(row.sequence) == 2, "ship: the second shipment has sequence 2")
	_expect(str(row.status) == Market.SHIPMENT_STATUS_TRANSIT, "ship: the second shipment is in transit")
	_expect(world.farm.bag(A)[GREENS] == 3, "ship: the second basket also leaves A's bag")
	_expect(_transit_units() == 1, "ship: exactly one unit is in transit again")
	_check_goods("second shipment in transit")

	var arrived: Dictionary = world.advance_to(_at(T_SHIP_TWO_ARRIVE))
	_expect(int(arrived.get("market_lost", 0)) == 1,
		"ship: the arrival sweep writes exactly one loss")
	row = world.farm.market_shipment("chain_ship_2")
	_expect(str(row.status) == Market.SHIPMENT_STATUS_LOST, "ship: shipment 2 is lost")
	_expect(world.farm.market_deliveries().size() == 1,
		"ship: no delivery row is added for the lost basket")
	var events: Array = world.farm.market_losses()
	_expect(events.size() == 1, "ship: one durable loss event exists")
	var event: Dictionary = events[0]
	_expect(str(event.id) == "loss_1", "ship: the loss id is loss_1")
	_expect(str(event.kind) == "transport_loss", "ship: the event kind is transport_loss")
	_expect(str(event.victim) == A, "ship: the victim is A")
	_expect(str(event.shipment_id) == "chain_ship_2", "ship: the loss names shipment 2")
	_expect(str(event.good) == GREENS, "ship: the lost good is greens")
	_expect(int(event.quantity) == 1, "ship: one unit was lost")
	_expect(int(event.unit_value) == 6, "ship: the loss is valued at the greens base price")
	_expect(int(event.value) == 6, "ship: the loss value is unit price times quantity")
	_expect(is_equal_approx(float(event.at_utc), _at(T_SHIP_TWO_ARRIVE)),
		"ship: the loss is stamped at the arrival instant")
	_expect(is_equal_approx(float(event.cause_start_utc), _at(T_SHIP_TWO))
		and is_equal_approx(float(event.cause_end_utc), _at(T_SHIP_TWO_ARRIVE)),
		"ship: the event stamps the declared-risk window")
	_expect(world.farm.bag(A)[GREENS] == 3, "ship: the lost basket is not credited anywhere")
	_expect(_transit_units() == 0, "ship: the transit table is empty after the loss")
	_check_cash("shipment 2 lost")
	_check_goods("shipment 2 lost")


# ---------------------------------------------------------------------------
# Link 6: bank capital, one repaid loan and one overdue loan.
# ---------------------------------------------------------------------------

func _phase_bank() -> void:
	_phase("bank_loans")
	var bank_open: Dictionary = FarmCommand.make_bank_open("chain_bank_open", _at(T_BANK))
	commands["bank_open"] = bank_open
	_execute(bank_open, "", "open the rule bank")
	var bank: Dictionary = world.farm.economy_bank()
	_expect(bool(bank.opened), "bank: the rule bank is open")
	_expect(int(bank.capital) == 2000, "bank: the one-time capital is 2000 COIN")
	_expect(int(bank.cash) == 2000, "bank: opening credits the full capital")
	_expect(world.farm.economy_issued() == 2835, "bank: the capital issues 2000 COIN")
	_check_cash("bank opened")

	var borrow_a: Dictionary = FarmCommand.make_loan_borrow(
		"chain_borrow_a", 100, LOAN_TERM, _at(T_BANK))
	commands["borrow_a"] = borrow_a
	_execute(borrow_a, A, "A borrows 100 COIN")
	var loan_a: Dictionary = world.farm.economy_loan("chain_borrow_a")
	_expect(str(loan_a.borrower) == A, "loan: the contract names A")
	_expect(int(loan_a.principal) == 100, "loan: the principal is 100")
	_expect(int(loan_a.fee) == 5, "loan: 5% of 100 is a 5 COIN fee")
	_expect(str(loan_a.status) == "open", "loan: A's contract is open")
	_expect(is_equal_approx(float(loan_a.due_utc), _at(T_BANK) + LOAN_TERM),
		"loan: the due date is exactly one term after borrowing")
	_expect(world.farm.economy_cash(A) == 227, "loan: A's cash rises by the principal")
	_expect(int(world.farm.economy_bank().cash) == 1900, "loan: the bank cash falls by the principal")
	_check_cash("A borrowed")

	var repay_a: Dictionary = FarmCommand.make_loan_repay(
		"chain_repay_a", "chain_borrow_a", _at(T_BANK))
	commands["repay_a"] = repay_a
	_execute(repay_a, A, "A repays in full")
	loan_a = world.farm.economy_loan("chain_borrow_a")
	_expect(str(loan_a.status) == "repaid", "loan: A's contract is repaid")
	_expect(int(loan_a.paid) == 105, "loan: principal plus fee is repaid")
	_expect(world.farm.economy_cash(A) == 122, "loan: A's cash returns to 122 after repayment")
	_expect(int(world.farm.economy_bank().cash) == 2005, "loan: the bank keeps principal and fee")
	_check_cash("A repaid")

	var borrow_b: Dictionary = FarmCommand.make_loan_borrow(
		"chain_borrow_b", 200, LOAN_TERM, _at(T_BANK))
	commands["borrow_b"] = borrow_b
	_execute(borrow_b, B, "B borrows 200 COIN")
	_expect(world.farm.economy_cash(B) == 308, "loan: B's cash rises by 200")
	_expect(int(world.farm.economy_bank().cash) == 1805, "loan: the bank cash falls by 200")
	_expect(str(world.farm.economy_loan("chain_borrow_b").status) == "open",
		"loan: B's contract is open")
	_check_cash("B borrowed")


# ---------------------------------------------------------------------------
# Link 7: seeded storm block, then B's contract goes overdue.
# ---------------------------------------------------------------------------

func _phase_storm_and_overdue() -> void:
	_phase("storm_overdue")
	world.advance_to(_at(T_STORM))
	_expect(str(world.nature_view().weather.kind) == "cloudy", "weather: the storm block is cloudy")
	var hazard: Dictionary = world.disaster_view().disaster
	_expect(not hazard.is_empty(), "disaster: the seeded storm block is visible")
	_expect(str(hazard.kind) == "storm", "disaster: the event is a storm")
	_expect(int(hazard.severity) == 1, "disaster: the fixed storm severity is 1")
	_expect(str(world.farm.economy_loan("chain_borrow_b").status) == "open",
		"loan: B's contract is still open before its due date")

	world.advance_to(_at(T_STORM_END))
	_expect(float(world.farm.get_cell("field_02", "cell_03").moisture) == 0.8125,
		"weather: the storm block adds 0.25 after the cloudy loss")
	_expect(str(world.farm.get_cell("field_02", "cell_03").moisture_label) == "wet",
		"weather: moisture 0.8125 reads as wet")

	var settled: Dictionary = world.advance_to(_at(T_OVERDUE))
	_expect(int(settled.get("loans_settled", 0)) == 1,
		"loan: the due sweep marks exactly one contract overdue")
	var loan_b: Dictionary = world.farm.economy_loan("chain_borrow_b")
	_expect(str(loan_b.status) == "overdue", "loan: B's contract is overdue")
	_expect(is_equal_approx(float(loan_b.due_utc), _at(T_OVERDUE)),
		"loan: the overdue boundary is the recorded due date")
	_expect(int(world.farm.economy_bank().cash) == 1805,
		"bank: marking overdue moves no cash")
	var bank: Dictionary = world.farm.economy_bank()
	_expect(int(bank.cash) == int(bank.capital) - 200 + 5,
		"bank: cash equals capital minus outstanding principal plus collected fees")
	var reserve: Dictionary = world.farm.economy_reserve_statement()
	_expect(int(reserve.loans_asset) == 200, "bank: the outstanding loan asset is 200")
	_expect(int(reserve.loans_overdue) == 1, "bank: the reserve report sees one overdue contract")
	_expect(int(reserve.loans_repaid) == 1, "bank: the reserve report sees one repaid contract")
	_check_cash("B overdue")
	_check_goods("after the overdue sweep")
	_expect(int(world.farm.economy_reconcile().burned) == 5,
		"cash: the trade and two shipping fees burned 5 COIN in total")
	_expect(world.farm.market_orders().size() == 14,
		"market: rolling quote rows are reused, not appended")
	_expect(_entries_of_kind("shipping_fee").size() == 2,
		"ledger: both shipping fees have a journal row")
	_expect(_entries_of_kind("loan_issue").size() == 2, "ledger: both loans have an issue row")
	_expect(_entries_of_kind("loan_repay").size() == 1, "ledger: the repayment has one row")
	_expect(_entries_of_kind("bank_open").size() == 1, "ledger: the bank capital has one row")
	_expect(_entries_of_kind("merchant_budget").size() == 1, "ledger: the merchant budget has one row")
	_expect(_entries_of_kind("open_account").size() == 2, "ledger: both accounts have an opening row")


# ---------------------------------------------------------------------------
# Link 8: cadastral claim, transfer and build-permission query.
# ---------------------------------------------------------------------------

func _phase_cadastre() -> void:
	_phase("cadastre")
	var view: Dictionary = world.territory_view()
	_expect(view.parcels.size() == 6, "land: the default cadastre has six parcels")
	var unclaimed: int = 0
	for parcel: Dictionary in view.parcels.values():
		if str(parcel.status) == "unclaimed":
			unclaimed += 1
	_expect(unclaimed == 6, "land: every parcel starts unclaimed")
	_expect(not TerritoryState.may_build(view, "parcel_01", A),
		"land: unclaimed ground is not buildable")
	_expect(TerritoryState.may_trespass(view, "parcel_01", A),
		"land: unclaimed ground is passable")

	var claim_a: Dictionary = world.claim_territory("parcel_01", A, "chain_claim_p1")
	_expect(bool(claim_a.get("ok", false)), "land: A claims parcel_01")
	_expect(not bool(claim_a.get("duplicate", true)), "land: the claim is a new land action")
	_expect(str(claim_a.get("owner", "")) == A and str(claim_a.get("status", "")) == "claimed",
		"land: the result names A as the claimed owner")
	view = world.territory_view()
	_expect(str(view.parcels["parcel_01"].owner) == A, "land: parcel_01 persists A as owner")
	_expect(is_equal_approx(float(view.parcels["parcel_01"].claimed_utc), _at(T_OVERDUE)),
		"land: the claim is stamped with the authority clock")
	_expect(str(view.parcels["parcel_01"].claim_id) == "chain_claim_p1",
		"land: parcel_01 records the claiming command")
	_expect(TerritoryState.may_build(view, "parcel_01", A), "land: the owner may build")
	_expect(not TerritoryState.may_build(view, "parcel_01", B),
		"land: another player may not build on the claim")
	_expect(TerritoryState.may_trespass(view, "parcel_01", A), "land: the owner may cross")
	_expect(not TerritoryState.may_trespass(view, "parcel_01", B),
		"land: another player may not cross the claim")
	_expect(not TerritoryState.may_build(view, "parcel_02", A),
		"land: the neighbouring unclaimed parcel stays unbuildable")
	_expect(TerritoryState.may_trespass(view, "parcel_02", A),
		"land: the neighbouring unclaimed parcel stays passable")

	var claim_b: Dictionary = world.claim_territory("parcel_02", B, "chain_claim_p2")
	_expect(bool(claim_b.get("ok", false)) and str(claim_b.get("owner", "")) == B,
		"land: B claims parcel_02")
	view = world.territory_view()
	_expect(TerritoryState.may_build(view, "parcel_02", B), "land: B may build on parcel_02")
	_expect(not TerritoryState.may_build(view, "parcel_02", A),
		"land: A may not build on B's parcel")
	_expect(not TerritoryState.may_trespass(view, "parcel_02", A),
		"land: A may not cross B's parcel")

	var transfer: Dictionary = world.transfer_territory("parcel_02", B, A, "chain_transfer_p2")
	_expect(bool(transfer.get("ok", false)), "land: B transfers parcel_02 to A")
	_expect(str(transfer.get("owner", "")) == A, "land: the transfer result names A")
	_expect(str(world.territory_view().parcels["parcel_02"].claim_id) == "chain_transfer_p2",
		"land: parcel_02 records the transferring command")
	_expect(TerritoryState.may_build(world.territory_view(), "parcel_02", A),
		"land: A may build after the transfer")
	_expect(not TerritoryState.may_build(world.territory_view(), "parcel_02", B),
		"land: B may not build after the transfer")


# ---------------------------------------------------------------------------
# Link 9: repeated command ids add no second record.
# ---------------------------------------------------------------------------

func _phase_replays() -> void:
	_phase("replays")
	var before: Dictionary = _comparable(world.farm.snapshot())
	var counts: Dictionary = _record_counts()
	_replay(commands["sow_greens_01"], A, "sow replay", before)
	_replay(commands["harvest_01"], A, "harvest replay", before)
	_replay(commands["buy"], B, "trade replay", before)
	_replay(commands["ship2"], A, "lost-shipment replay", before)
	_replay(commands["borrow_b"], B, "borrow replay", before)
	_replay(commands["repay_a"], A, "repay replay", before)
	_expect(_record_counts() == counts,
		"replay: no trade, shipment, delivery, loss, loan, order or ledger row was added")
	var land_before: Dictionary = world.territory_view()
	var claimed_again: Dictionary = world.claim_territory("parcel_01", A, "chain_claim_p1")
	_expect(bool(claimed_again.get("duplicate", false)), "land replay: the claim reports duplicate")
	_expect(str(claimed_again.get("owner", "")) == A, "land replay: the original owner is replayed")
	_expect(world.territory_view() == land_before, "land replay: the cadastre is unchanged")


# ---------------------------------------------------------------------------
# Link 10: save -> reopen keeps every key link.
# ---------------------------------------------------------------------------

func _phase_restart() -> void:
	_phase("restart")
	var live: Dictionary = _comparable(world.farm.snapshot())
	var saved: Dictionary = world.save()
	_expect(bool(saved.get("ok", false)), "restart: farm, nature and cadastre save together")
	reopened = HeadlessWorld.new()
	var opened: Dictionary = reopened.open(test_root, world.now_utc, WORLD_ID)
	_expect(bool(opened.get("ok", false)), "restart: the same directory reopens")
	_expect(str(opened.get("kind", "")) == "loaded", "restart: the save is loaded, not recreated")
	_expect(_comparable(reopened.farm.snapshot()) == live,
		"restart: the restored farm snapshot is identical")
	_expect(reopened.decorations.snapshot() == world.decorations.snapshot(),
		"restart: the decoration snapshot is identical")
	_expect(reopened.nature.get_seed() == SEED, "restart: the nature seed survives")
	_expect(is_equal_approx(reopened.now_utc, world.now_utc), "restart: the world clock is restored")
	_expect(reopened.farm.bag(A)[GREENS] == 3 and reopened.farm.bag(B)[GREENS] == 2,
		"restart: both bags survive")
	_expect(reopened.farm.economy_cash(A) == 122 and reopened.farm.economy_cash(B) == 308,
		"restart: both cash balances survive")
	_expect(reopened.farm.market_trades().size() == 1, "restart: the trade row survives")
	_expect(str(reopened.farm.market_shipment("chain_ship_1").status) == "delivered",
		"restart: the delivered shipment survives")
	_expect(str(reopened.farm.market_shipment("chain_ship_2").status) == "lost",
		"restart: the lost shipment survives")
	_expect(reopened.farm.market_losses().size() == 1, "restart: the loss event survives")
	_expect(str(reopened.farm.economy_loan("chain_borrow_a").status) == "repaid",
		"restart: the repaid loan survives")
	_expect(str(reopened.farm.economy_loan("chain_borrow_b").status) == "overdue",
		"restart: the overdue loan survives")
	_expect(int(reopened.farm.market_merchant().cash) == 260, "restart: merchant cash survives")
	_expect(int(reopened.farm.economy_bank().cash) == 1805, "restart: bank cash survives")
	_expect(str(reopened.territory_view().parcels["parcel_01"].owner) == A,
		"restart: the cadastral claim survives")
	_expect(str(reopened.territory_view().parcels["parcel_02"].owner) == A,
		"restart: the transferred parcel survives")
	_expect(bool(reopened.farm.economy_reconcile().ok), "restart: the restored ledger reconciles")
	_expect(reopened.farm.economy_total_cash() == reopened.farm.economy_issued(),
		"restart: cash conservation still holds")

	# The bounded command window was restored too, so a retry is still a replay
	# instead of a second harvest.
	var after_open: Dictionary = _comparable(reopened.farm.snapshot())
	var replay: Dictionary = reopened.execute(commands["harvest_01"], A)
	_expect(str(replay.get("stage", "")) == "duplicate",
		"restart: a committed id replays after reopening")
	_expect(_comparable(reopened.farm.snapshot()) == after_open,
		"restart: the post-restart replay changes nothing")

	# Finish the conservation evidence on the restored authority.
	world = reopened
	_check_cash("after restart")
	_check_goods("after restart")


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

func _phase(name: String) -> void:
	print("PHASE " + name)


func _at(relative_seconds: float) -> float:
	return START + relative_seconds


func _execute(command: Dictionary, actor: String, label: String) -> Dictionary:
	var result: Dictionary = world.execute(command, actor)
	_expect(bool(result.get("ok", false)), label + ": accepted")
	_expect(str(result.get("stage", "")) == "committed", label + ": committed as new work")
	_expect(not bool(result.get("duplicate", true)), label + ": is not a duplicate")
	return result


func _replay(command: Dictionary, actor: String, label: String, before: Dictionary) -> void:
	var result: Dictionary = world.execute(command, actor)
	_expect(str(result.get("stage", "")) == "duplicate", label + ": reports a duplicate")
	_expect(bool(result.get("duplicate", false)), label + ": sets the duplicate flag")
	_expect(bool(result.get("ok", false)), label + ": replays the original outcome")
	_expect(_comparable(world.farm.snapshot()) == before, label + ": leaves the state unchanged")


func _record_counts() -> Dictionary:
	return {
		"trades": world.farm.market_trades().size(),
		"shipments": world.farm.market_shipments().size(),
		"deliveries": world.farm.market_deliveries().size(),
		"losses": world.farm.market_losses().size(),
		"loans": world.farm.economy_loans().size(),
		"orders": world.farm.market_orders().size(),
		"ledger": world.farm.economy_ledger_entries().size(),
		"issued": world.farm.economy_issued(),
		"sequence": world.farm.event_sequence(),
		"commands": world.farm.committed_command_count(),
	}


func _transit_units() -> int:
	var total: int = 0
	for shipment: Dictionary in world.farm.market_shipments():
		if str(shipment.status) == "in_transit":
			total += int(shipment.quantity)
	return total


func _entries_of_kind(kind: String) -> Array:
	var result: Array = []
	for entry: Dictionary in world.farm.economy_ledger_entries():
		if str(entry.kind) == kind:
			result.append(entry)
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


func _check_goods(label: String) -> void:
	var census: Dictionary = _goods_census()
	for good_id: String in Catalog.goods_ids():
		var left: int = int(census.produced.get(good_id, 0)) + int(census.granted.get(good_id, 0))
		var right: int = int(census.bags.get(good_id, 0)) + int(census.merchant.get(good_id, 0)) \
			+ int(census.sell_escrow.get(good_id, 0)) + int(census.transit.get(good_id, 0)) \
			+ int(census.lost.get(good_id, 0))
		_expect(left == right,
			"goods[%s]: %s produced+granted=%d == held=%d" % [label, good_id, left, right])
	var left_total: int = int(census.produced_total) + int(census.granted_total)
	var right_total: int = int(census.bags_total) + int(census.merchant_total) \
		+ int(census.sell_escrow_total) + int(census.transit_total) + int(census.lost_total)
	_expect(left_total == right_total,
		"goods[%s]: the catalog-wide total is conserved (%d)" % [label, left_total])


func _goods_census() -> Dictionary:
	var ids: Array[String] = Catalog.goods_ids()
	var bags: Dictionary = {}
	var merchant: Dictionary = {}
	var sell_escrow: Dictionary = {}
	var transit: Dictionary = {}
	var lost: Dictionary = {}
	var granted: Dictionary = {}
	var produced: Dictionary = {}
	for good_id: String in ids:
		bags[good_id] = 0
		merchant[good_id] = 0
		sell_escrow[good_id] = 0
		transit[good_id] = 0
		lost[good_id] = 0
		granted[good_id] = 0
		produced[good_id] = 0
	var snapshot: Dictionary = world.farm.snapshot()
	var merchant_row: Dictionary = world.farm.market_merchant()
	var granted_row: Dictionary = merchant_row.get("granted", {})
	var goods_row: Dictionary = merchant_row.get("goods", {})
	for good_id: String in ids:
		produced[good_id] = int(snapshot.harvested.get(good_id, 0))
		bags[good_id] = int(world.farm.economy_goods(A)[good_id]) \
			+ int(world.farm.economy_goods(B)[good_id]) \
			+ int(world.farm.economy_goods("@world")[good_id])
		merchant[good_id] = int(goods_row.get(good_id, 0))
		granted[good_id] = int(granted_row.get(good_id, 0))
	for order: Dictionary in world.farm.market_orders():
		if str(order.status) == "open" and str(order.side) == "sell":
			var good_id: String = str(order.good)
			if sell_escrow.has(good_id):
				sell_escrow[good_id] = int(sell_escrow[good_id]) + int(order.remaining)
	for shipment: Dictionary in world.farm.market_shipments():
		if str(shipment.status) == "in_transit":
			var good_id: String = str(shipment.good)
			if transit.has(good_id):
				transit[good_id] = int(transit[good_id]) + int(shipment.quantity)
	for event: Dictionary in world.farm.market_losses():
		var good_id: String = str(event.good)
		if lost.has(good_id):
			lost[good_id] = int(lost[good_id]) + int(event.quantity)
	return {
		"bags": bags, "merchant": merchant, "sell_escrow": sell_escrow,
		"transit": transit, "lost": lost, "granted": granted, "produced": produced,
		"bags_total": _sum(ids, bags), "merchant_total": _sum(ids, merchant),
		"sell_escrow_total": _sum(ids, sell_escrow), "transit_total": _sum(ids, transit),
		"lost_total": _sum(ids, lost), "granted_total": _sum(ids, granted),
		"produced_total": _sum(ids, produced),
	}


static func _sum(ids: Array[String], values: Dictionary) -> int:
	var total: int = 0
	for good_id: String in ids:
		total += int(values.get(good_id, 0))
	return total


static func _comparable(snapshot: Dictionary) -> Dictionary:
	# The command ledger is commit-boundary state; its replay behavior is
	# asserted by the replay fixtures instead of the round-trip comparison.
	var copy: Dictionary = snapshot.duplicate(true)
	copy.erase("transaction")
	return copy


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS " + message)
	else:
		failures.append(message)
		print("FAIL " + message)
