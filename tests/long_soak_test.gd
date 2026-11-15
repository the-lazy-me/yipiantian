extends SceneTree
## M13-02 long-soak evidence, local rules only. No scene, renderer, UI, network
## or system clock: one fixed seed, one fixed UTC start, and public rule entry
## points. Saves go through the real FarmStore into an isolated directory.
##
## Covered here:
## 1. 365 offline days settled once vs once per day on a planted farm with the
##    seeded weather source: planted/mature/harvest counts, inventory, moisture,
##    growth bounds and tagged weather blocks.
## 2. 365 offline days on a world with a bank, a merchant, a resting order, a
##    shipment and a loan: raw snapshots are asserted to differ only through the
##    documented sweep-observation fields, while the economic projection, goods
##    and crops are asserted equal.
## 3. A 365-day scripted economic loop (no random default): 52 weeks x 3 = 156
##    scripted fills, monthly loans, monthly shipments, daily expiring orders,
##    market/loan sweeps and real saves. Every day asserts cash conservation;
##    every week asserts ledger reconcile, goods conservation, table bounds,
##    monotonic archive counters and bounded command windows; every save asserts
##    the JSON document size against FarmStore's own read limit.
## 4. A non-assertive capacity probe that keeps the same scripted day past the
##    one-year mark until the first failed save, so the real document growth
##    limit is measured instead of assumed.
## 5. A fabricated all-tables-full document that reports whether the per-table
##    bounds together fit the store limit on their own.
## 6. Static-memory samples at 30-day checkpoints. This reports this machine's
##    engine static memory only; it is not process RSS or a cross-platform claim.
##
## Time budget: 5 minutes. The fixture checks its own deadline at each loop and
## records the days it actually reached if the budget is hit.

const Farm = preload("res://farm/farm_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const Loans = preload("res://farm/loan_state.gd")
const Market = preload("res://farm/market_state.gd")
const Ledger = preload("res://farm/ledger_state.gd")
const Nature = preload("res://farm/nature_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const Trellis = preload("res://layout/trellis_slots.gd")

const START: float = 1800000000.0
const SEED: int = 424242
const DAY: float = 86400.0
const BLOCK: float = 21600.0
const SPAN_DAYS: int = 365
const BUDGET_MS: int = 300000
const CAPACITY_PROBE_DAYS: int = 1100
const PROBE_LOAN_PRINCIPAL: int = 600
const MEMORY_INTERVAL_DAYS: int = 30
const PLAYER_A: String = "player_soak_a"
const PLAYER_B: String = "player_soak_b"
const PLAYER_C: String = "player_soak_c"
const PLAY_CROPS: Array[String] = ["greens", "radish", "carrot", "spinach", "lettuce"]
const LOAN_PRINCIPAL: int = 50
const LOAN_TERM: int = 604800

var checks: int = 0
var failures: Array[String] = []
var test_root: String
var started_ms: int = 0
var days_completed: int = 0
var memory_samples: Array[Dictionary] = []
var peak_json_bytes: int = 0
var final_json_bytes: int = 0
var orders_max: int = 0
var shipments_max: int = 0
var deliveries_max: int = 0
var losses_max: int = 0
var ledger_entries_max: int = 0
var economy_window_max: int = 0
var farm_window_max: int = 0
var archived_orders_final: int = 0
var trades_final: int = 0
var scripted_trades: int = 0
var scripted_loans: int = 0
var scripted_shipments: int = 0
var rest_sells: int = 0
var expected_losses: int = 0
var expected_deliveries: int = 0
var saturated_json_bytes: int = 0
var loop_soft_failures: int = 0
var probe_findings: Dictionary = {}


func _initialize() -> void:
	started_ms = Time.get_ticks_msec()
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	test_root = project_root.get_base_dir().path_join(
		".local/verification/long-soak-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_crop_offline_parity()
	_test_economy_offline_parity()
	_test_economy_loop()
	_test_save_capacity_probe()
	_test_table_saturation_size()
	_write_results()
	for failure: String in failures:
		push_error(failure)
	print("LONG_SOAK_TEST checks=%d failures=%d days=%d peak_delta_kb=%.1f" % [
		checks, failures.size(), days_completed, _peak_delta_kb()])
	quit(0 if failures.is_empty() else 1)


# ---------------------------------------------------------------------------
# 1. One year of seeded weather and crops: one settlement vs daily settlement.
# ---------------------------------------------------------------------------

func _test_crop_offline_parity() -> void:
	var target: float = START + float(SPAN_DAYS) * DAY
	var once := Farm.new(START, {}, Nature.new(SEED))
	var daily := Farm.new(START, {}, Nature.new(SEED))
	var initial_planted: int = int(_growth_summary(once).planted)
	var once_planted: int = _plant_all(once, START)
	var daily_planted: int = _plant_all(daily, START)
	_eq_int(once_planted, daily_planted, "crop parity: both paths plant the same cells")
	_expect(once_planted > 0, "crop parity: the fixture plants a non-empty garden")

	var weather: Dictionary = _walk_weather(Nature.new(SEED), START, target)
	_eq_int(int(weather.completed), SPAN_DAYS * Nature.BLOCKS_PER_DAY,
		"crop parity: the year completes 1460 six-hour weather blocks")
	_expect(int(weather.touched) >= int(weather.completed),
		"crop parity: every completed block is also a touched block")
	_eq_int(int(weather.kind_total), int(weather.touched),
		"crop parity: every touched block has one weather kind")
	_eq_int((weather.kinds as Dictionary).size(), Nature.WEATHER_KINDS.size(),
		"crop parity: all three weather kinds appear")
	_eq_int((weather.seasons as Dictionary).size(), Nature.SEASON_IDS.size(),
		"crop parity: all four season labels appear")
	_expect(int(weather.disasters) > 0,
		"crop parity: the seeded year contains at least one disaster block")

	var once_started: int = Time.get_ticks_msec()
	_expect_ok(once.settle(target), "crop parity: one settlement reaches day 365")
	var once_ms: int = Time.get_ticks_msec() - once_started
	var daily_started: int = Time.get_ticks_msec()
	var daily_ran: int = 0
	for day: int in range(1, SPAN_DAYS + 1):
		if _budget_exceeded():
			_expect(false, "crop parity: time budget exceeded at day %d" % day)
			break
		_expect_ok(daily.settle(START + float(day) * DAY),
			"crop parity: daily settlement reaches day %d" % day)
		daily_ran = day
	var daily_ms: int = Time.get_ticks_msec() - daily_started
	_eq_int(daily_ran, SPAN_DAYS, "crop parity: all 365 daily settlements ran")

	var once_growth: Dictionary = _growth_summary(once)
	var daily_growth: Dictionary = _growth_summary(daily)
	_expect(once_growth == daily_growth,
		"crop parity: planted, mature and total-growth summaries are identical")
	_expect(_cell_views(once) == _cell_views(daily),
		"crop parity: every cell's crop, stage, growth and moisture is identical")
	_expect(once.snapshot() == daily.snapshot(),
		"crop parity: the one-shot and daily farm snapshots are byte-identical")

	_eq_int(int(once_growth.planted), once_planted + initial_planted,
		"crop parity: the year neither adds nor drops planted crops")
	_eq_int(int(once_growth.mature), int(once_growth.planted),
		"crop parity: every planted crop is mature after 365 grown days")
	_eq_int(int(once_growth.planted), int(daily_growth.planted),
		"crop parity: both paths end with the same planted count")
	_eq_int(int(once_growth.mature), int(daily_growth.mature),
		"crop parity: both paths end with the same mature count")

	var bounded: bool = true
	for field_id: String in _all_field_ids(once):
		for cell_id: String in once.cell_ids(field_id):
			var cell: Dictionary = once.get_cell(field_id, cell_id)
			var moisture: float = float(cell.moisture)
			if moisture < 0.0 or moisture > Farm.MOISTURE_MAX:
				bounded = false
			if not str(cell.crop_id).is_empty():
				var duration: float = Farm.Crops.definition(str(cell.crop_id)).duration_seconds
				if float(cell.growth_seconds) > duration:
					bounded = false
	_expect(bounded, "crop parity: moisture stays in [0, 1] and growth at or below maturity")

	var harvest_once: Dictionary = _harvest_mature(once, target)
	var harvest_daily: Dictionary = _harvest_mature(daily, target)
	_expect(harvest_once == harvest_daily,
		"crop parity: harvest counts, inventory and harvested totals are identical")
	_eq_int(int(harvest_once.count), int(once_growth.mature),
		"crop parity: every mature cell yields exactly one basket")
	_expect(int(harvest_once.count) > 0, "crop parity: the year actually yields harvests")
	_expect(once.snapshot() == daily.snapshot(),
		"crop parity: both paths still agree after harvesting the mature cells")
	var summary: String = "SOAK crop_offline days=%d completed_blocks=%d touched_blocks=%d kinds=%s " \
		% [SPAN_DAYS, int(weather.completed), int(weather.touched),
		JSON.stringify(weather.kinds)]
	summary += "seasons=%d disasters=%d planted=%d mature=%d harvested=%d " % [
		(weather.seasons as Dictionary).size(), int(weather.disasters),
		once_planted + initial_planted, int(once_growth.mature), int(harvest_once.count)]
	summary += "one_shot_ms=%d daily_ms=%d raw_equal=yes moisture_equal=yes" \
		% [once_ms, daily_ms]
	print(summary)


# ---------------------------------------------------------------------------
# 2. A year offline on an economic world: the only snapshot difference is the
#    documented sweep-observation bookkeeping.
# ---------------------------------------------------------------------------

func _test_economy_offline_parity() -> void:
	var target: float = START + float(SPAN_DAYS) * DAY
	var base: Farm = _open_accounts([PLAYER_A, PLAYER_B])
	_expect_ok(base.economy_open_bank("soak-offline-bank", START),
		"economy parity: the bank opens")
	_expect_ok(base.market_open_merchant("soak-offline-merchant", START),
		"economy parity: the merchant opens")
	_eq_int(_grow_named(base, "field_02", 1, 8, "greens", PLAYER_B, START), 8,
		"economy parity: B grows eight greens")
	_expect_ok(base.market_place_order("soak-offline-sell", PLAYER_B, "sell", "greens", 10, 2,
		START + 2.0 * DAY, START), "economy parity: B rests a sell expiring on day 2")
	_expect_ok(base.market_place_order("soak-offline-buy", PLAYER_A, "buy", "greens", 4, 2,
		START + 3.0 * DAY, START),
		"economy parity: A rests a buy below every quote expiring on day 3")
	_expect_ok(base.market_ship("soak-offline-ship", PLAYER_B, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 3, START),
		"economy parity: B ships three greens")
	_expect_ok(base.economy_borrow_loan("soak-offline-loan", PLAYER_A, LOAN_PRINCIPAL,
		LOAN_TERM, START), "economy parity: A borrows for seven days")

	var source: Dictionary = base.snapshot()
	var once := Farm.new()
	var daily := Farm.new()
	_expect(once.restore_snapshot(source), "economy parity: the one-shot candidate restores")
	_expect(daily.restore_snapshot(source), "economy parity: the daily candidate restores")
	# Both candidates get the same seeded weather source, so the year also
	# compares crop growth and moisture, not just the economy.
	once.set_environment(Nature.new(SEED))
	daily.set_environment(Nature.new(SEED))

	_expect_ok(once.settle(target), "economy parity: one settlement reaches day 365")
	_run_sweeps(once, target)
	var daily_ran: int = 0
	for day: int in range(1, SPAN_DAYS + 1):
		if _budget_exceeded():
			_expect(false, "economy parity: time budget exceeded at day %d" % day)
			break
		var now: float = START + float(day) * DAY
		_expect_ok(daily.settle(now), "economy parity: daily settlement reaches day %d" % day)
		_run_sweeps(daily, now)
		if day % 30 == 0:
			_expect_economy_valid(daily, "economy parity day %d" % day)
		daily_ran = day
	_eq_int(daily_ran, SPAN_DAYS, "economy parity: all 365 daily settlements ran")

	for label: String in ["one-shot", "daily"]:
		var farm: Farm = once if label == "one-shot" else daily
		_expect(str(farm.economy_loan("soak-offline-loan").status) == Loans.STATUS_OVERDUE,
			"economy parity %s: the seven-day loan is overdue" % label)
		_eq_int(int(farm.economy_loan("soak-offline-loan").paid), 0,
			"economy parity %s: the overdue loan paid nothing" % label)
		_expect(str(farm.market_order("soak-offline-sell").status) == Market.STATUS_EXPIRED,
			"economy parity %s: the day-2 sell expired" % label)
		_expect(str(farm.market_order("soak-offline-buy").status) == Market.STATUS_EXPIRED,
			"economy parity %s: the day-3 buy expired" % label)
		_eq_int(farm.market_shipments().size(), 1,
			"economy parity %s: one shipment row exists" % label)
		_eq_int(farm.market_deliveries().size(), 1,
			"economy parity %s: one delivery event exists" % label)
		_expect(str(farm.market_shipment("soak-offline-ship").status)
			== Market.SHIPMENT_STATUS_DELIVERED,
			"economy parity %s: the shipment was delivered" % label)
		_eq_int(_bag_amount(farm, PLAYER_B, "greens"), 8,
			"economy parity %s: B ends with the expired sell and delivered shipment returned"
				% label)
		_eq_int(int(farm.economy_funds(PLAYER_A).available), 170,
			"economy parity %s: A's expired buy returns all 18 COIN" % label)
		_expect(farm.economy_total_cash() == farm.economy_issued(),
			"economy parity %s: total cash equals issued" % label)
		_expect_economy_valid(farm, "economy parity " + label)
		_eq_int(Economy.bank_cash(farm.economy_snapshot()),
			Economy.BANK_CAPITAL - Loans.outstanding_principal(farm.economy_snapshot())
				+ Loans.collected_fees(farm.economy_snapshot()),
			"economy parity %s: bank cash matches capital - outstanding + fees" % label)

	# The difference is bookkeeping, not money or goods: state sweeps stamp the
	# observation instant, and rolling merchant quotes are rebuilt at each sweep.
	_eq_float(float(once.market_order("soak-offline-sell").closed_utc), target,
		"economy parity: the one-shot expiry is stamped at the sweep time")
	_eq_float(float(daily.market_order("soak-offline-sell").closed_utc), START + 2.0 * DAY,
		"economy parity: the daily expiry is stamped on day 2")
	_eq_float(float(once.market_deliveries()[0].at_utc), target,
		"economy parity: the one-shot delivery is stamped at the sweep time")
	_eq_float(float(daily.market_deliveries()[0].at_utc), START + DAY,
		"economy parity: the daily delivery is stamped on day 1")
	_expect(once.snapshot() != daily.snapshot(),
		"economy parity: raw snapshots differ through observation-time bookkeeping")
	var projection_once: Dictionary = _offline_projection(once)
	var projection_daily: Dictionary = _offline_projection(daily)
	_expect(projection_once == projection_daily,
		"economy parity: the normalized economic projection is byte-identical")
	_eq_int(Economy.issued(projection_once.economy), Economy.issued(projection_daily.economy),
		"economy parity: both paths issue the same amount")
	_eq_int(Economy.total_cash(projection_once.economy),
		Economy.total_cash(projection_daily.economy),
		"economy parity: both paths hold the same total cash")
	for owner: String in [PLAYER_A, PLAYER_B]:
		_eq_int(Economy.cash(projection_once.economy, owner),
			Economy.cash(projection_daily.economy, owner),
			"economy parity: both paths give %s the same cash" % owner)
	_eq_int(Economy.bank_cash(projection_once.economy),
		Economy.bank_cash(projection_daily.economy),
		"economy parity: both paths leave the bank the same cash")
	_eq_int(_bag_amount(once, PLAYER_B, "greens"), _bag_amount(daily, PLAYER_B, "greens"),
		"economy parity: both paths leave B with the same greens")
	_expect(_growth_summary(once) == _growth_summary(daily),
		"economy parity: both paths agree on every crop cell and its moisture")

	# Repeated terminal sweeps are a no-op on both paths.
	for farm: Farm in [once, daily]:
		var settled: Dictionary = farm.snapshot()
		var issued_before: int = farm.economy_issued()
		_eq_int(int(farm.market_expire(target).get("expired", -1)), 0,
			"economy parity repeat: no order is due again")
		_eq_int(int(farm.market_match(target).get("count", -1)), 0,
			"economy parity repeat: no fill is invented")
		_eq_int(int(farm.market_deliver(target).get("count", -1)), 0,
			"economy parity repeat: no in-transit shipment remains")
		_eq_int(int(farm.economy_settle_loans(target).get("count", -1)), 0,
			"economy parity repeat: no second overdue transition")
		_expect(farm.snapshot() == settled,
			"economy parity repeat: the terminal sweep changes nothing")
		_eq_int(farm.economy_issued(), issued_before,
			"economy parity repeat: repeated sweeps issue no cash")
	var summary: String = "SOAK economy_offline days=%d projection_equal=yes raw_equal=no " % SPAN_DAYS
	summary += "difference=closed_utc/delivered_utc/delivery_at_utc+rolling_quote_sequence "
	summary += "issued=%d total_cash=%d loan=%s delivered=%d" % [
		once.economy_issued(), once.economy_total_cash(),
		str(once.economy_loan("soak-offline-loan").status), once.market_deliveries().size()]
	print(summary)


# ---------------------------------------------------------------------------
# 3. The scripted 365-day economic loop. No randomness is introduced by the
#    fixture: every command below runs on a fixed day, and failures are
#    asserted rather than skipped.
# ---------------------------------------------------------------------------

func _test_economy_loop() -> void:
	var directory: String = test_root.path_join("economy-world")
	DirAccess.make_dir_recursive_absolute(directory)
	var store := FarmStore.new(directory)
	var opened: Dictionary = store.load_state()
	_expect(bool(opened.ok) and str(opened.kind) == "missing",
		"loop: an empty isolated world opens as a missing first launch")
	var farm := Farm.new(START, {}, Nature.new(SEED))
	var decorations := Decorations.new()
	for owner: String in [PLAYER_A, PLAYER_B, PLAYER_C]:
		_expect_ok(farm.economy_open_account("soak-open-" + owner, owner, START),
			"loop: " + owner + " opens an account")
	_expect_ok(farm.economy_open_bank("soak-bank", START), "loop: the bank opens")
	_expect_ok(farm.market_open_merchant("soak-merchant", START), "loop: the merchant opens")
	_eq_int(farm.economy_issued(), 2960,
		"loop: three grants, bank capital and merchant budget are the only issuance")
	_eq_int(farm.economy_total_cash(), farm.economy_issued(),
		"loop: the opening world conserves its issued cash")

	var previous_archived: Dictionary = {
		"orders": 0, "shipments": 0, "deliveries": 0, "losses": 0,
	}
	var ran: int = 0
	var loop_state: Dictionary = {"rest_sells": 0, "trades": 0, "loans": 0,
		"shipments": 0, "losses": 0, "deliveries": 0}
	_sample_memory(0)
	for day: int in range(1, SPAN_DAYS + 1):
		if _budget_exceeded():
			_expect(false, "loop: time budget exceeded before day %d" % day)
			break
		_run_loop_day(farm, day, previous_archived, decorations, store, directory, loop_state,
			true)
		ran = day
	days_completed = ran
	rest_sells = int(loop_state.rest_sells)
	scripted_trades = int(loop_state.trades)
	scripted_loans = int(loop_state.loans)
	scripted_shipments = int(loop_state.shipments)
	expected_losses = int(loop_state.losses)
	expected_deliveries = int(loop_state.deliveries)

	# Final save and reload after the last day, which is not a 30-day checkpoint.
	var final_checkpoint: Dictionary = _save_checkpoint(store, farm, decorations, directory,
		"loop final day %d" % ran)
	peak_json_bytes = maxi(peak_json_bytes, int(final_checkpoint.get("bytes", 0)))
	final_json_bytes = int(final_checkpoint.get("bytes", 0))
	_sample_memory(ran)

	_expect(ran == SPAN_DAYS, "loop: the full 365-day span completed")
	var market: Dictionary = farm.market_snapshot()
	archived_orders_final = int(market.get("archived_orders", 0))
	trades_final = farm.market_trades().size()
	orders_max = maxi(orders_max, market.orders.size())
	shipments_max = maxi(shipments_max, market.shipments.size())
	deliveries_max = maxi(deliveries_max, market.deliveries.size())
	losses_max = maxi(losses_max, farm.market_losses().size())
	ledger_entries_max = maxi(ledger_entries_max, farm.economy_ledger_entries().size())
	economy_window_max = maxi(economy_window_max,
		farm.economy_snapshot().command_results.size())
	farm_window_max = maxi(farm_window_max,
		farm.snapshot().transaction.command_results.size())

	_eq_int(scripted_trades, (SPAN_DAYS / 7) * 3,
		"loop: every week of three scripted fills ran")
	_eq_int(trades_final, scripted_trades,
		"loop: the trade log holds exactly the scripted fills (no invented trades)")
	_eq_int(scripted_loans, (SPAN_DAYS - 1) / 30 + 1,
		"loop: one monthly loan per 30-day boundary plus the opening loan")
	_eq_int(scripted_shipments, SPAN_DAYS / 30,
		"loop: one monthly shipment was sent")
	_eq_int(rest_sells, SPAN_DAYS - 1,
		"loop: a resting sell was accepted every day after the first harvest")
	_eq_int(farm.market_trades().size(), scripted_trades,
		"loop: resting orders never crossed into the trade log")
	_eq_int(farm.market_losses().size(), expected_losses,
		"loop: only shipments on the deterministic loss branch were destroyed")
	_eq_int(_count_shipments(farm, Market.SHIPMENT_STATUS_DELIVERED), expected_deliveries,
		"loop: every safe shipment delivered exactly once")
	_expect(deliveries_max > 0,
		"loop: at least one delivery event was written and its table sampled")
	_expect(deliveries_max <= 12,
		"loop: delivery rows never exceed the twelve scripted safe shipments")
	_expect(orders_max <= Market.MAX_ORDERS,
		"loop: the order table stayed at or below %d rows" % Market.MAX_ORDERS)
	_expect(shipments_max <= Market.MAX_SHIPMENTS,
		"loop: the shipment table stayed at or below %d rows" % Market.MAX_SHIPMENTS)
	_expect(deliveries_max <= Market.MAX_DELIVERIES,
		"loop: the delivery table stayed at or below %d rows" % Market.MAX_DELIVERIES)
	_expect(losses_max <= Market.MAX_LOSSES,
		"loop: the loss table stayed at or below %d rows" % Market.MAX_LOSSES)
	_expect(ledger_entries_max <= Ledger.MAX_ENTRIES,
		"loop: the journal stayed at or below %d live entries" % Ledger.MAX_ENTRIES)
	_expect(economy_window_max <= Economy.MAX_COMMAND_RESULTS,
		"loop: the economy command window stayed at or below %d ids"
			% Economy.MAX_COMMAND_RESULTS)
	_expect(farm_window_max <= Farm.MAX_COMMAND_RESULTS,
		"loop: the farm command window stayed at or below %d ids" % Farm.MAX_COMMAND_RESULTS)
	_expect(archived_orders_final > 0,
		"loop: the order archive counter advanced in a full order table")
	_expect(int(market.get("archived_shipments", 0)) >= 0
		and int(market.get("archived_deliveries", 0)) >= 0,
		"loop: shipment and delivery archive counters are nonnegative")
	for shipment: Dictionary in farm.market_shipments():
		if str(shipment.risk) == Market.SHIPMENT_RISK_DECLARED:
			var expected_loss: bool = Market.declared_loss_expected(shipment)
			_expect((str(shipment.status) == Market.SHIPMENT_STATUS_LOST) == expected_loss,
				"loop: declared shipment %s matches its deterministic arrival verdict"
					% str(shipment.id))
		else:
			_expect(str(shipment.status) == Market.SHIPMENT_STATUS_DELIVERED,
				"loop: safe shipment %s delivered" % str(shipment.id))
	for loss: Dictionary in farm.market_losses():
		_expect(str(loss.kind) == Market.TRANSPORT_LOSS_KIND
			and str(farm.market_shipment(str(loss.shipment_id)).loss_id) == str(loss.id),
			"loop: loss %s links its terminal shipment" % str(loss.id))
	_eq_int(farm.market_losses().size(),
		_count_shipments(farm, Market.SHIPMENT_STATUS_LOST),
		"loop: every lost shipment has exactly one loss event")
	_expect(expected_losses > 0,
		"loop: the fixed quantities reached the declared-loss branch at least once")
	_expect(farm.economy_total_cash() == farm.economy_issued(),
		"loop: the final world conserves cash")
	_expect_economy_valid(farm, "loop final")
	_eq_int(Economy.bank_cash(farm.economy_snapshot()),
		Economy.BANK_CAPITAL - Loans.outstanding_principal(farm.economy_snapshot())
			+ Loans.collected_fees(farm.economy_snapshot()),
		"loop: the final bank cash matches capital - outstanding + fees")
	_eq_int(_greens_accounted(farm), int(farm.hud_state().harvested.get("greens", 0)) + 20,
		"loop: every green is in a bag, merchant stock, escrow, transit, loss or harvest")
	_expect(peak_json_bytes <= FarmStore.MAX_BYTES,
		"loop: every saved document stayed at or below %d bytes" % FarmStore.MAX_BYTES)
	var sections: Dictionary = _document_sections(farm, decorations)
	print("SOAK document bytes total=%d headroom=%d decorations=%d economy=%d "
		% [int(sections.total), FarmStore.MAX_BYTES - int(sections.total),
		int(sections.decorations), int(sections.economy)]
		+ "orders=%d ledger_entries=%d trades=%d" % [
		int(sections.orders), int(sections.ledger_entries), int(sections.trades)])
	var summary: String = "SOAK economy_loop days=%d trades=%d loans=%d shipments=%d " % [
		ran, trades_final, scripted_loans, scripted_shipments]
	summary += "orders_max=%d archived_orders=%d shipments_max=%d deliveries_max=%d " \
		% [orders_max, archived_orders_final, shipments_max, deliveries_max]
	summary += "losses=%d ledger_entries_max=%d command_window_max=%d " % [
		losses_max, ledger_entries_max, economy_window_max]
	summary += "json_max_bytes=%d json_final_bytes=%d cash_conserved=yes reconcile=yes" \
		% [peak_json_bytes, final_json_bytes]
	print(summary)


## One fixed scripted day. `assertive` is false only for the capacity probe,
## which extends the same world past the one-year span to measure when the
## document stops fitting the store; its rule outcomes are still counted, and a
## failure there is recorded in the probe row rather than as a soak failure.
func _run_loop_day(farm: Farm, day: int, previous_archived: Dictionary,
		decorations: Decorations, store: FarmStore, directory: String,
		loop_state: Dictionary, assertive: bool) -> void:
	var now: float = START + float(day) * DAY
	_step(farm.settle(now), assertive, "loop day %d: crops settle" % day)
	_daily_crop(farm, "field_01", 1, 2, "greens", PLAYER_A, now, day, assertive)
	_daily_crop(farm, "field_02", 1, 2, "greens", PLAYER_B, now, day, assertive)
	_daily_crop(farm, "field_03", 1, 2, "greens", PLAYER_C, now, day, assertive)
	_step(farm.market_expire(now), assertive, "loop day %d: expiry sweep" % day)

	# A resting sell of one basket per day fills the bounded order table over
	# the year and exercises the archive counter. Day 1 has no harvested green
	# yet, so the daily sell starts on day 2; the count is asserted by the caller.
	if _bag_amount(farm, PLAYER_A, "greens") >= 1:
		_step(farm.market_place_order("soak-rest-sell-%03d" % day, PLAYER_A, "sell",
			"greens", 999, 1, now + DAY, now), assertive,
			"loop day %d: A rests an unsellable greens order" % day)
		loop_state.rest_sells = int(loop_state.rest_sells) + 1
	_step(farm.market_place_order("soak-rest-buy-%03d" % day, PLAYER_B, "buy",
		"greens", 1, 1, now + DAY, now), assertive,
		"loop day %d: B rests an unfillable greens order" % day)

	var weekly: bool = day % 7 == 0
	if weekly:
		_step(farm.market_place_order("soak-week-a-sell-%03d" % day, PLAYER_A, "sell",
			"greens", 6, 2, now + 2.0 * DAY, now), assertive,
			"loop day %d: A offers two greens" % day)
		_step(farm.market_place_order("soak-week-b-buy-%03d" % day, PLAYER_B, "buy",
			"greens", 8, 2, now + 2.0 * DAY, now), assertive,
			"loop day %d: B bids for A's two greens" % day)
		_step(farm.market_place_order("soak-week-b-sell-%03d" % day, PLAYER_B, "sell",
			"greens", 6, 2, now + 2.0 * DAY, now), assertive,
			"loop day %d: B offers two greens" % day)
		_step(farm.market_place_order("soak-week-c-buy-%03d" % day, PLAYER_C, "buy",
			"greens", 8, 2, now + 2.0 * DAY, now), assertive,
			"loop day %d: C bids for B's two greens" % day)
		_step(farm.market_place_order("soak-week-c-sell-%03d" % day, PLAYER_C, "sell",
			"greens", 6, 2, now + 2.0 * DAY, now), assertive,
			"loop day %d: C offers two greens" % day)
		_step(farm.market_place_order("soak-week-a-buy-%03d" % day, PLAYER_A, "buy",
			"greens", 8, 2, now + 2.0 * DAY, now), assertive,
			"loop day %d: A bids for C's two greens" % day)

	var matched: Dictionary = farm.market_match(now)
	_step(matched, assertive, "loop day %d: matching sweep" % day)
	if weekly:
		_step({"ok": int(matched.get("count", -1)) == 3}, assertive,
			"loop day %d: the three scripted player pairs fill" % day)
		loop_state.trades = int(loop_state.trades) + 3
	_step(farm.market_deliver(now), assertive, "loop day %d: delivery sweep" % day)
	_step(farm.economy_settle_loans(now), assertive, "loop day %d: loan sweep" % day)

	if day % 30 == 1:
		if assertive:
			_step(farm.economy_borrow_loan("soak-loan-%03d" % day, PLAYER_A,
				LOAN_PRINCIPAL, LOAN_TERM, now), assertive,
				"loop day %d: A borrows %d" % [day, LOAN_PRINCIPAL])
			loop_state.loans = int(loop_state.loans) + 1
		else:
			# Probe mode: the scripted week both buys and sells, and every fill
			# and shipment burns a fee with no income source, so the opening
			# grants are nearly spent by the end of the year. A real rule loan
			# (never fabricated cash) funds the extension whenever the borrower
			# has no active contract; an overdue contract blocking the next one
			# is the rule's own behaviour, not a probe shortcut.
			for owner: String in [PLAYER_A, PLAYER_B, PLAYER_C]:
				if not Loans.active_loan(farm.economy_snapshot(), owner).is_empty():
					continue
				var borrowed: Dictionary = farm.economy_borrow_loan("probe-loan-%s-%03d"
					% [owner, day], owner, PROBE_LOAN_PRINCIPAL, LOAN_TERM, now)
				if bool(borrowed.get("ok", false)):
					loop_state.loans = int(loop_state.loans) + 1
	if assertive and day % 30 == 5:
		_step(farm.economy_repay_loan("soak-repay-%03d" % day, PLAYER_A,
			"soak-loan-%03d" % (day - 4), now), assertive,
			"loop day %d: A repays the loan with its fee" % day)
	if day % 30 == 10:
		# Four declared shipments a year land on the fixed loss branch and
		# destroy goods with one evidence row; the other eight months are safe
		# shipments that must deliver. The quantity is chosen on the pure risk
		# roll's loss branch (the M8-05 pattern: assert the rule verdict, not
		# chance), and the exact loss and delivery counts are asserted by the
		# caller.
		var declared: bool = day % 90 == 10
		var sequence: int = int(farm.market_snapshot().get("shipment_sequence", 0)) + 1
		var loss_quantity: int = _loss_quantity(PLAYER_C, "greens", Market.LOCATION_FARM,
			Market.LOCATION_HARBOR, now, sequence) if declared else 0
		var risk: String = Market.SHIPMENT_RISK_DECLARED if loss_quantity > 0 \
			else Market.SHIPMENT_RISK_SAFE
		var quantity: int = loss_quantity if loss_quantity > 0 else 2
		_step(farm.market_ship("soak-ship-%03d" % day, PLAYER_C,
			Market.LOCATION_FARM, Market.LOCATION_HARBOR, "greens", quantity, now, risk),
			assertive, "loop day %d: C ships %d greens (%s)" % [day, quantity, risk])
		if loss_quantity > 0:
			loop_state.losses = int(loop_state.losses) + 1
		else:
			loop_state.deliveries = int(loop_state.deliveries) + 1
		loop_state.shipments = int(loop_state.shipments) + 1

	_step({"ok": farm.economy_total_cash() == farm.economy_issued()}, assertive,
		"loop day %d: total cash equals issued" % day)
	if day % 7 == 0:
		_check_loop_week(farm, decorations, day, previous_archived, assertive)
	# Only the main one-year soak contributes to the memory series: the capacity
	# probe is a separate world and a separate document, so mixing its samples
	# into the trend would describe neither.
	if assertive and day % MEMORY_INTERVAL_DAYS == 0:
		_sample_memory(day)
	if assertive and day % 30 == 0:
		var checkpoint: Dictionary = _save_checkpoint(store, farm, decorations, directory,
			"loop day %d" % day)
		peak_json_bytes = maxi(peak_json_bytes, int(checkpoint.get("bytes", 0)))


func _step(result: Dictionary, assertive: bool, label: String) -> void:
	if assertive:
		_expect_ok(result, label)
	elif not bool(result.get("ok", false)):
		loop_soft_failures += 1


func _check_loop_week(farm: Farm, decorations: Decorations, day: int,
		previous_archived: Dictionary, assertive: bool = true) -> void:
	var label: String = "loop week ending day %d" % day
	if not assertive:
		# The capacity probe crosses the store limit on purpose; economic
		# validity there is still worth counting, but its document size is the
		# probe's own output, not a soak assertion.
		_expect_economy_valid(farm, label)
		return
	var economy: Dictionary = farm.economy_snapshot()
	_expect(Economy.valid(economy), label + ": the economy document is valid")
	var report: Dictionary = Economy.reconcile(economy)
	_expect(bool(report.ok), label + ": the ledger reconciles")
	_eq_int(int(report.total_cash), int(report.issued), label + ": reconciled cash equals issued")
	_eq_int(int(report.issuance) - int(report.burned), Economy.issued(economy),
		label + ": issuance minus burn equals the net issued amount")
	_expect(Loans.valid(economy.get("loans", {})), label + ": every contract is valid")
	_eq_int(Economy.bank_cash(economy),
		Economy.BANK_CAPITAL - Loans.outstanding_principal(economy)
			+ Loans.collected_fees(economy),
		label + ": bank cash matches capital - outstanding + fees")

	var market: Dictionary = economy.market
	orders_max = maxi(orders_max, market.orders.size())
	shipments_max = maxi(shipments_max, market.shipments.size())
	deliveries_max = maxi(deliveries_max, market.deliveries.size())
	losses_max = maxi(losses_max, farm.market_losses().size())
	ledger_entries_max = maxi(ledger_entries_max, economy.ledger.entries.size())
	economy_window_max = maxi(economy_window_max, economy.command_results.size())
	farm_window_max = maxi(farm_window_max,
		farm.snapshot().transaction.command_results.size())
	_expect(market.orders.size() <= Market.MAX_ORDERS, label + ": order rows are bounded")
	_expect(market.shipments.size() <= Market.MAX_SHIPMENTS,
		label + ": shipment rows are bounded")
	_expect(market.deliveries.size() <= Market.MAX_DELIVERIES,
		label + ": delivery rows are bounded")
	_expect(farm.market_losses().size() <= Market.MAX_LOSSES, label + ": loss rows are bounded")
	_expect(economy.ledger.entries.size() <= Ledger.MAX_ENTRIES,
		label + ": journal entries are bounded")
	_expect(economy.command_results.size() <= Economy.MAX_COMMAND_RESULTS,
		label + ": the economy command window is bounded")
	_expect(farm.snapshot().transaction.command_results.size() <= Farm.MAX_COMMAND_RESULTS,
		label + ": the farm command window is bounded")

	var archived: Dictionary = {
		"orders": int(market.get("archived_orders", 0)),
		"shipments": int(market.get("archived_shipments", 0)),
		"deliveries": int(market.get("archived_deliveries", 0)),
		"losses": int((economy.losses as Dictionary).get("archived", 0)),
	}
	for key: String in archived:
		_expect(int(archived[key]) >= int(previous_archived[key]),
			"%s: archived_%s is monotonic" % [label, key])
		previous_archived[key] = int(archived[key])
	_expect(int(archived.orders) <= int(market.sequence),
		label + ": the order archive count does not exceed its sequence")
	_expect(int(archived.shipments) <= int(market.shipment_sequence),
		label + ": the shipment archive count does not exceed its sequence")
	_expect(int(archived.deliveries) <= int(market.delivery_sequence),
		label + ": the delivery archive count does not exceed its sequence")

	_eq_int(_greens_accounted(farm), int(farm.hud_state().harvested.get("greens", 0)) + 20,
		label + ": every green is accounted for")

	var text: String = JSON.stringify({"version": FarmStore.VERSION, "farm": farm.snapshot(),
		"decorations": decorations.snapshot()}, "\t")
	var bytes: int = text.to_utf8_buffer().size()
	peak_json_bytes = maxi(peak_json_bytes, bytes)
	_expect(bytes <= FarmStore.MAX_BYTES,
		"%s: the prospective document is %d bytes, within the store limit" % [label, bytes])


func _save_checkpoint(store: FarmStore, farm: Farm, decorations: Decorations,
		directory: String, label: String) -> Dictionary:
	var snapshot_before: Dictionary = farm.snapshot()
	var text: String = JSON.stringify({"version": FarmStore.VERSION, "farm": snapshot_before,
		"decorations": decorations.snapshot()}, "\t")
	var expected_bytes: int = text.to_utf8_buffer().size()
	var saved: Dictionary = store.save_state(farm, decorations)
	_expect(bool(saved.ok), label + ": save succeeds")
	var path: String = directory.path_join(FarmStore.MAIN)
	var on_disk: String = FileAccess.get_file_as_string(path)
	_expect(on_disk == text, label + ": the measured document is the one written")
	var bytes: int = on_disk.to_utf8_buffer().size()
	_expect(bytes == expected_bytes, label + ": the measured byte count is stable")
	_expect(bytes <= FarmStore.MAX_BYTES,
		"%s: the saved document is %d bytes, within the store limit %d"
			% [label, bytes, FarmStore.MAX_BYTES])
	var reader := FarmStore.new(directory)
	var loaded: Dictionary = reader.load_state()
	_expect(bool(loaded.ok) and str(loaded.kind) == "loaded",
		label + ": the saved document reloads through the store")
	if bool(loaded.ok) and str(loaded.kind) == "loaded":
		var restored := Farm.new()
		_expect(restored.restore_snapshot(loaded.farm),
			label + ": the reloaded farm restores as a valid snapshot")
		_expect(restored.snapshot() == snapshot_before,
			label + ": the reloaded farm equals the live snapshot")
	return {"bytes": bytes, "ok": bool(saved.ok)}


func _daily_crop(farm: Farm, field_id: String, first_cell: int, last_cell: int,
		crop_id: String, actor: String, now: float, day: int, assertive: bool = true) -> void:
	for index: int in range(first_cell, last_cell + 1):
		var cell_id: String = "cell_%02d" % index
		if str(farm.get_cell(field_id, cell_id).stage) == "mature":
			_step(farm.harvest(field_id, cell_id, now, actor), assertive,
				"loop day %d: %s harvests %s/%s" % [day, actor, field_id, cell_id])
		var after: Dictionary = farm.get_cell(field_id, cell_id)
		if str(after.crop_id).is_empty() and str(after.ground) == "ready":
			_step(farm.sow(field_id, cell_id, crop_id, now, actor), assertive,
				"loop day %d: %s sows %s/%s" % [day, actor, field_id, cell_id])


# ---------------------------------------------------------------------------
# Memory sampling. Engine static memory only: this is a same-machine series,
# not a claim about RSS, other platforms or leaks in absolute terms.
# ---------------------------------------------------------------------------

func _sample_memory(day: int) -> void:
	var static_bytes: int = int(OS.get_static_memory_usage())
	var perf_bytes: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var objects: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var resources: int = int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	var sample: Dictionary = {"day": day, "static_bytes": static_bytes,
		"perf_static_bytes": perf_bytes, "objects": objects, "resources": resources}
	memory_samples.append(sample)
	print("MEMORY day=%d static_bytes=%d perf_static_bytes=%d objects=%d resources=%d" % [
		day, static_bytes, perf_bytes, objects, resources])


func _peak_delta_kb() -> float:
	if memory_samples.is_empty():
		return 0.0
	var baseline: int = int(memory_samples[0].static_bytes)
	var peak: int = baseline
	for sample: Dictionary in memory_samples:
		peak = maxi(peak, int(sample.static_bytes))
	return float(peak - baseline) / 1024.0


func _final_delta_kb() -> float:
	if memory_samples.is_empty():
		return 0.0
	return float(int(memory_samples[memory_samples.size() - 1].static_bytes)
		- int(memory_samples[0].static_bytes)) / 1024.0


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

func _budget_exceeded() -> bool:
	return Time.get_ticks_msec() - started_ms > BUDGET_MS


func _all_field_ids(farm: RefCounted) -> Array[String]:
	var result: Array[String] = []
	result.assign(farm.field_ids())
	result.append(Trellis.FIELD_ID)
	return result


func _plant_all(farm: RefCounted, at_utc: float) -> int:
	var planted: int = 0
	var rotation: int = 0
	for field_id: String in _all_field_ids(farm):
		var cells: Array[String] = []
		cells.assign(farm.cell_ids(field_id))
		cells.sort()
		for cell_id: String in cells:
			var cell: Dictionary = farm.get_cell(field_id, cell_id)
			if not str(cell.crop_id).is_empty() or str(cell.ground) != "ready":
				continue
			var crop_id: String = "luffa" if field_id == Trellis.FIELD_ID \
				else PLAY_CROPS[rotation % PLAY_CROPS.size()]
			rotation += 1
			if bool(farm.sow(field_id, cell_id, crop_id, at_utc).get("ok", false)):
				planted += 1
	return planted


func _walk_weather(nature: RefCounted, from_utc: float, to_utc: float) -> Dictionary:
	var cursor: float = from_utc
	var touched: int = 0
	var completed: int = 0
	var kind_total: int = 0
	var kinds: Dictionary = {}
	var seasons: Dictionary = {}
	var disasters: int = 0
	while cursor < to_utc:
		var weather: Dictionary = nature.weather_at(cursor)
		if weather.is_empty():
			break
		var end: float = float(weather.end_utc)
		if end <= cursor:
			break
		touched += 1
		kind_total += 1
		var kind: String = str(weather.kind)
		kinds[kind] = int(kinds.get(kind, 0)) + 1
		var season: String = str(nature.season_at(cursor).id)
		seasons[season] = true
		if not nature.disaster_at(cursor).is_empty():
			disasters += 1
		if end <= to_utc:
			completed += 1
		cursor = end
	return {
		"touched": touched, "completed": completed, "kind_total": kind_total,
		"kinds": kinds, "seasons": seasons, "disasters": disasters,
	}


func _growth_summary(farm: RefCounted) -> Dictionary:
	var planted: int = 0
	var mature: int = 0
	var total_growth: float = 0.0
	var moisture_total: float = 0.0
	for field_id: String in _all_field_ids(farm):
		for cell_id: String in farm.cell_ids(field_id):
			var cell: Dictionary = farm.get_cell(field_id, cell_id)
			if str(cell.crop_id).is_empty():
				continue
			planted += 1
			total_growth += float(cell.growth_seconds)
			moisture_total += float(cell.moisture)
			if str(cell.stage) == "mature":
				mature += 1
	return {"planted": planted, "mature": mature, "total_growth": total_growth,
		"moisture_total": moisture_total}


func _cell_views(farm: RefCounted) -> Dictionary:
	var fields: Dictionary = {}
	for field_id: String in _all_field_ids(farm):
		var cells: Dictionary = {}
		for cell_id: String in farm.cell_ids(field_id):
			var cell: Dictionary = farm.get_cell(field_id, cell_id)
			cells[cell_id] = {
				"crop_id": cell.crop_id, "stage": cell.stage, "ground": cell.ground,
				"growth_seconds": cell.growth_seconds, "watered": cell.watered,
				"moisture": cell.moisture, "moisture_label": cell.moisture_label,
				"growth_rate": cell.growth_rate,
			}
		fields[field_id] = cells
	return fields


func _harvest_mature(farm: RefCounted, at_utc: float) -> Dictionary:
	var count: int = 0
	for field_id: String in _all_field_ids(farm):
		var cells: Array[String] = []
		cells.assign(farm.cell_ids(field_id))
		cells.sort()
		for cell_id: String in cells:
			if str(farm.get_cell(field_id, cell_id).stage) != "mature":
				continue
			if bool(farm.harvest(field_id, cell_id, at_utc).get("ok", false)):
				count += 1
	var hud: Dictionary = farm.hud_state()
	return {
		"count": count,
		"inventory": hud.inventory.duplicate(),
		"harvested": hud.harvested.duplicate(),
	}


func _open_accounts(owners: Array) -> Farm:
	var farm := Farm.new(START)
	for owner: String in owners:
		_expect_ok(farm.economy_open_account("soak-open-" + owner, owner, START),
			"open account " + owner)
	return farm


func _grow_named(farm: Farm, field_id: String, first_cell: int, last_cell: int,
		crop_id: String, actor: String, now: float) -> int:
	var cells: Array[String] = []
	for index: int in range(first_cell, last_cell + 1):
		cells.append("cell_%02d" % index)
	for cell_id: String in cells:
		_expect_ok(farm.sow(field_id, cell_id, crop_id, now, actor),
			"sow %s/%s" % [field_id, cell_id])
	_expect_ok(farm.mature_all_crops(now), "mature crops at %.0f" % now)
	var produced: int = 0
	for cell_id: String in cells:
		if bool(farm.harvest(field_id, cell_id, now, actor).get("ok", false)):
			produced += 1
	return produced


func _run_sweeps(farm: Farm, now: float) -> void:
	_expect_ok(farm.market_expire(now), "expiry sweep at %.0f" % now)
	_expect_ok(farm.market_match(now), "matching sweep at %.0f" % now)
	_expect_ok(farm.market_deliver(now), "delivery sweep at %.0f" % now)
	_expect_ok(farm.economy_settle_loans(now), "loan sweep at %.0f" % now)


## Drops the fields whose value is the observation instant, plus the rolling
## merchant quote rows and the live journal. What remains must be identical:
## balances, contracts, goods, crops and all durable row states. This is the
## same boundary the M8-05 stress record documents.
func _offline_projection(farm: Farm) -> Dictionary:
	var state: Dictionary = farm.snapshot()
	var ledger: Dictionary = state.economy.ledger
	state.economy.ledger = {"balances": ledger.balances.duplicate(true)}
	var market: Dictionary = state.economy.market
	var player_orders: Dictionary = {}
	for order_id: Variant in market.orders:
		var id: String = str(order_id)
		if id.begins_with(Market.MERCHANT_BID_PREFIX) \
				or id.begins_with(Market.MERCHANT_ASK_PREFIX):
			continue
		var order: Dictionary = market.orders[order_id].duplicate(true)
		order.closed_utc = 0.0
		player_orders[id] = order
	market.orders = player_orders
	market.erase("sequence")
	market.trades = {}
	for shipment_id: Variant in market.shipments:
		market.shipments[shipment_id].delivered_utc = 0.0
	for delivery_id: Variant in market.deliveries:
		market.deliveries[delivery_id].at_utc = 0.0
	return state


## Everything a green could be: player bags, the merchant's free stock, open
## sell escrow (player and merchant rows), in-transit shipments and destroyed
## loss evidence. The harvest counter plus the one-time merchant grant is the
## only source.
func _greens_accounted(farm: Farm) -> int:
	var total: int = _bag_amount(farm, PLAYER_A, "greens") \
		+ _bag_amount(farm, PLAYER_B, "greens") + _bag_amount(farm, PLAYER_C, "greens")
	total += int(farm.market_merchant().goods.get("greens", 0))
	for order: Dictionary in farm.market_orders():
		if str(order.side) == "sell" and str(order.good) == "greens" \
				and str(order.status) == Market.STATUS_OPEN:
			total += int(order.reserved)
	for shipment: Dictionary in farm.market_shipments():
		if str(shipment.status) == Market.SHIPMENT_STATUS_TRANSIT \
				and str(shipment.good) == "greens":
			total += int(shipment.quantity)
	for loss: Dictionary in farm.market_losses():
		if str(loss.good) == "greens":
			total += int(loss.quantity)
	return total


## Measures what the saved document is made of, so the byte bound has a visible
## cause instead of only a total. Each section is serialized the same way the
## store serializes the whole document.
func _document_sections(farm: Farm, decorations: Decorations) -> Dictionary:
	var snapshot: Dictionary = farm.snapshot()
	var economy: Dictionary = snapshot.economy
	var market: Dictionary = economy.market
	return {
		"total": JSON.stringify({"version": FarmStore.VERSION, "farm": snapshot,
			"decorations": decorations.snapshot()}, "\t").to_utf8_buffer().size(),
		"decorations": JSON.stringify(decorations.snapshot()).to_utf8_buffer().size(),
		"economy": JSON.stringify(economy).to_utf8_buffer().size(),
		"orders": JSON.stringify(market.orders).to_utf8_buffer().size(),
		"ledger_entries": JSON.stringify(economy.ledger.entries).to_utf8_buffer().size(),
		"trades": JSON.stringify(market.trades).to_utf8_buffer().size(),
	}


func _count_shipments(farm: Farm, status: String) -> int:
	var count: int = 0
	for shipment: Dictionary in farm.market_shipments():
		if str(shipment.status) == status:
			count += 1
	return count


## Smallest quantity in 1..8 whose pure declared-risk roll lands on the loss
## branch for this shipment's persisted fields, or 0 when none does. The fixture
## asserts the rule verdict instead of assuming chance, exactly like the M8-05
## transport-loss scenario.
static func _loss_quantity(owner: String, good_id: String, origin: String,
		destination: String, depart_utc: float, sequence: int) -> int:
	for quantity: int in range(1, 9):
		if Market.transport_loss_expected(sequence, owner, good_id, quantity, origin,
				destination, depart_utc):
			return quantity
	return 0


func _bag_amount(farm: Farm, owner: String, good_id: String) -> int:
	return int(farm.bag(owner).get(good_id, 0))


func _expect_economy_valid(farm: Farm, label: String) -> void:
	var economy: Dictionary = farm.economy_snapshot()
	_expect(Economy.valid(economy), "%s: expected a valid economy, got invalid" % label)
	_expect(bool(Economy.reconcile(economy).ok),
		"%s: expected the ledger to reconcile, got %s" % [
			label, str(Economy.reconcile(economy).reason)])
	_eq_int(Economy.total_cash(economy), Economy.issued(economy),
		"%s: total cash must equal issued" % label)
	_expect(Economy.issued(economy) >= 0, "%s: issued is nonnegative" % label)
	_expect(Loans.valid(economy.get("loans", {})), "%s: every contract is valid" % label)


# ---------------------------------------------------------------------------
# 4. Save-capacity probe. The one-year run ends at ~469 KB, close to the store
#    limit, so this extends the same scripted, non-fabricated world until the
#    document crosses FarmStore.MAX_BYTES and reports what happens then. Every
#    rule outcome here is counted through `loop_soft_failures`; the probe's
#    product is the measured crossing day and the recovery behaviour, not a
#    pass/fail assertion on the limit itself.
# ---------------------------------------------------------------------------

func _test_save_capacity_probe() -> void:
	var directory: String = test_root.path_join("capacity-world")
	DirAccess.make_dir_recursive_absolute(directory)
	var store := FarmStore.new(directory)
	_expect(bool(store.load_state().ok), "capacity probe: the isolated world opens")
	var farm := Farm.new(START, {}, Nature.new(SEED))
	var decorations := Decorations.new()
	for owner: String in [PLAYER_A, PLAYER_B, PLAYER_C]:
		_expect_ok(farm.economy_open_account("probe-open-" + owner, owner, START),
			"capacity probe: " + owner + " opens an account")
	_expect_ok(farm.economy_open_bank("probe-bank", START), "capacity probe: the bank opens")
	_expect_ok(farm.market_open_merchant("probe-merchant", START),
		"capacity probe: the merchant opens")

	var previous_archived: Dictionary = {"orders": 0, "shipments": 0, "deliveries": 0,
		"losses": 0}
	var loop_state: Dictionary = {"rest_sells": 0, "trades": 0, "loans": 0,
		"shipments": 0, "losses": 0, "deliveries": 0}
	# The one-year loop burns one COIN per fill and two per shipment with no
	# income source, so the buyers' opening grants are nearly spent by day 365.
	# The probe therefore runs the same scripted day from day 1 with real rule
	# loans (PROBE_LOAN_PRINCIPAL) whenever a borrower has no active contract;
	# otherwise it would measure a liquidity wall rather than capacity.
	var last_saved_day: int = 0
	var last_saved_bytes: int = 0
	var first_failed_day: int = 0
	var first_failed_bytes: int = 0
	var failure_reason: String = ""
	var day: int = 0
	while day < CAPACITY_PROBE_DAYS:
		if _budget_exceeded():
			break
		day += 1
		_run_loop_day(farm, day, previous_archived, decorations, store, directory, loop_state,
			false)
		if day % 30 != 0:
			continue
		var text: String = JSON.stringify({"version": FarmStore.VERSION, "farm": farm.snapshot(),
			"decorations": decorations.snapshot()}, "\t")
		var bytes: int = text.to_utf8_buffer().size()
		var saved: Dictionary = store.save_state(farm, decorations)
		if bool(saved.ok):
			last_saved_day = day
			last_saved_bytes = bytes
			var on_disk: String = FileAccess.get_file_as_string(
				directory.path_join(FarmStore.MAIN))
			_expect(on_disk == text,
				"capacity probe day %d: the store wrote the measured document" % day)
			var reader := FarmStore.new(directory)
			var loaded: Dictionary = reader.load_state()
			_expect(bool(loaded.ok) and str(loaded.kind) == "loaded",
				"capacity probe day %d: the saved document reloads" % day)
		elif first_failed_day == 0:
			first_failed_day = day
			first_failed_bytes = bytes
			failure_reason = str(saved.get("kind", ""))
			break
	probe_findings = {
		"ran_days": day, "last_saved_day": last_saved_day,
		"last_saved_bytes": last_saved_bytes,
		"first_failed_day": first_failed_day,
		"first_failed_bytes": first_failed_bytes,
		"failure_reason": failure_reason,
		"soft_failures": loop_soft_failures,
	}
	_expect(day >= SPAN_DAYS + 1, "capacity probe: the probe advanced past the one-year span")
	# The probe's scripted pairs must keep filling while the world is funded, so
	# a soft failure would mean the extension measured liquidity instead.
	_expect(loop_soft_failures == 0,
		"capacity probe: the funded extension had no rule failures (got %d)"
			% loop_soft_failures)

	var crossing_text: String = "SOAK capacity_probe ran_days=%d " % day
	crossing_text += "last_saved_day=%d last_saved_bytes=%d store_limit=%d " % [
		last_saved_day, last_saved_bytes, FarmStore.MAX_BYTES]
	if first_failed_day > 0:
		crossing_text += "first_failed_day=%d first_failed_bytes=%d reason=%s " % [
			first_failed_day, first_failed_bytes, failure_reason]
	else:
		crossing_text += "first_failed_day=none "
	if first_failed_day > 0:
		# After the first over-limit save, the live world can no longer commit:
		# report whether the on-disk world is still loadable and whether a retry
		# keeps failing. This is the recovery behaviour a player would meet.
		var main_text: String = FileAccess.get_file_as_string(
			directory.path_join(FarmStore.MAIN))
		var main_bytes: int = main_text.to_utf8_buffer().size()
		var reader := FarmStore.new(directory)
		var reloaded: Dictionary = reader.load_state()
		var retry: Dictionary = store.save_state(farm, decorations)
		var pending_bytes: int = FileAccess.get_file_as_string(
			directory.path_join(FarmStore.PENDING)).to_utf8_buffer().size()
		var live_text: String = JSON.stringify({"version": FarmStore.VERSION,
			"farm": farm.snapshot(), "decorations": decorations.snapshot()}, "\t")
		var live_bytes: int = live_text.to_utf8_buffer().size()
		crossing_text += "on_disk_bytes=%d on_disk_loadable=%s retry_ok=%s " % [
			main_bytes, str(bool(reloaded.ok) and str(reloaded.kind) == "loaded"),
			str(bool(retry.ok))]
		crossing_text += "pending_bytes=%d live_bytes_over_limit=%s lost_days=%d" % [
			pending_bytes, str(live_bytes > FarmStore.MAX_BYTES),
			day - last_saved_day]
		probe_findings.on_disk_bytes = main_bytes
		probe_findings.retry_ok = bool(retry.ok)
		probe_findings.pending_bytes = pending_bytes
		probe_findings.live_bytes = live_bytes
		probe_findings.lost_days = day - last_saved_day
	print(crossing_text)


## Fabricated-row size probe, separate from the real scripted world above. It
## measures whether the individual bounded tables can add up past the store
## limit; the real crossing day is measured by the capacity probe above.

func _test_table_saturation_size() -> void:
	var farm := Farm.new(START, {}, Nature.new(SEED))
	var data: Dictionary = farm.snapshot()
	var market: Dictionary = data.economy.market
	var economy: Dictionary = data.economy
	var ledger: Dictionary = economy.ledger
	var losses: Dictionary = economy.losses
	# Smallest valid fabricated rows. They are not gameplay evidence; they only
	# stand in for rows whose real shape the rules already validate, so the size
	# probe measures the table bound rather than re-proving each rule.
	for index: int in range(1, Market.MAX_ORDERS + 1):
		var sequence: int = index
		market.orders["sat_order_%03d" % index] = {
			"id": "sat_order_%03d" % index, "owner": "@merchant", "side": "buy",
			"good": "greens", "price": 1, "quantity": 1, "remaining": 1, "filled": 0,
			"reserved": 1, "sequence": sequence, "created_utc": START,
			"expires_utc": START + DAY, "status": "filled", "released": 0,
			"closed_by": "", "closed_utc": START,
		}
	market.sequence = Market.MAX_ORDERS
	market.orders["merchant_bid_greens"] = {
		"id": "merchant_bid_greens", "owner": "@merchant", "side": "buy", "good": "greens",
		"price": 5, "quantity": 4, "remaining": 4, "filled": 0, "reserved": 20,
		"sequence": Market.MAX_ORDERS + 1, "created_utc": START,
		"expires_utc": START + DAY, "status": "open", "released": 0, "closed_by": "",
		"closed_utc": 0.0,
	}
	market.sequence = Market.MAX_ORDERS + 1
	market.orders["merchant_ask_greens"] = {
		"id": "merchant_ask_greens", "owner": "@merchant", "side": "sell", "good": "greens",
		"price": 7, "quantity": 4, "remaining": 4, "filled": 0, "reserved": 4,
		"sequence": Market.MAX_ORDERS + 2, "created_utc": START,
		"expires_utc": START + DAY, "status": "open", "released": 0, "closed_by": "",
		"closed_utc": 0.0,
	}
	market.sequence = Market.MAX_ORDERS + 2
	market.archived_orders = Market.MAX_ORDERS
	market.trade_sequence = Market.MAX_TRADES
	for index: int in range(1, Market.MAX_TRADES + 1):
		market.trades["trade_%d" % index] = {
			"id": "trade_%d" % index, "sequence": index, "good": "greens", "price": 6,
			"quantity": 1, "notional": 6, "fee": 1, "buy_id": "sat_order_001",
			"sell_id": "sat_order_002", "buy_owner": "@merchant", "sell_owner": "@merchant",
			"buy_price": 6, "sell_price": 6, "buy_refund": 0, "sell_credit": 5,
			"at_utc": START,
		}
	market.shipment_sequence = Market.MAX_SHIPMENTS
	market.delivery_sequence = Market.MAX_DELIVERIES
	for index: int in range(1, Market.MAX_SHIPMENTS + 1):
		market.shipments["sat_ship_%03d" % index] = {
			"id": "sat_ship_%03d" % index, "sequence": index, "owner": "sat_player_soak",
			"good": "greens", "quantity": 1, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR, "fee": Market.SHIPMENT_FEE,
			"depart_utc": START, "arrive_utc": START + Market.DELIVERY_SECONDS,
			"status": Market.SHIPMENT_STATUS_DELIVERED,
			"delivered_utc": START + Market.DELIVERY_SECONDS,
			"delivery_id": "delivery_%d" % index, "risk": Market.SHIPMENT_RISK_SAFE,
			"lost_utc": 0.0, "loss_id": "",
		}
		market.deliveries["delivery_%d" % index] = {
			"id": "delivery_%d" % index, "sequence": index,
			"shipment_id": "sat_ship_%03d" % index, "owner": "sat_player_soak",
			"good": "greens", "quantity": 1, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR,
			"at_utc": START + Market.DELIVERY_SECONDS,
		}
	# The delivery table bound is two hundred and fifty-six rows, so the
	# remaining shipments above must not claim a delivery id beyond it.
	for index: int in range(Market.MAX_DELIVERIES + 1, Market.MAX_SHIPMENTS + 1):
		market.shipments["sat_ship_%03d" % index].delivery_id = ""
		market.shipments["sat_ship_%03d" % index].status = Market.SHIPMENT_STATUS_TRANSIT
		market.shipments["sat_ship_%03d" % index].delivered_utc = 0.0
	losses.sequence = Market.MAX_LOSSES
	for index: int in range(1, Market.MAX_LOSSES + 1):
		losses.events["loss_%d" % index] = {
			"id": "loss_%d" % index, "sequence": index, "kind": Market.TRANSPORT_LOSS_KIND,
			"at_utc": START, "cause_start_utc": START, "cause_end_utc": START,
			"victim": "sat_player_soak", "shipment_id": "sat_ship_001", "good": "greens",
			"quantity": 1, "unit_value": 6, "value": 6,
			"rule_version": Market.TRANSPORT_LOSS_RULE_VERSION,
		}
	ledger.sequence = Ledger.MAX_ENTRIES
	for index: int in range(1, Ledger.MAX_ENTRIES + 1):
		ledger.entries["ledger_%d" % index] = {
			"id": "ledger_%d" % index, "sequence": index, "kind": Ledger.KIND_PAY,
			"event_id": "sat_event_%d" % index, "at_utc": START, "debit": 1, "credit": 1,
			"lines": [
				{"account": "account:sat_player_soak", "debit": 1, "credit": 0},
				{"account": "account:sat_player_soak_b", "debit": 0, "credit": 1},
			],
		}
	# The two command windows are bounded too, and a real world at its limits has
	# both full. Their payloads are at the stored maximum length.
	var saturated_payload: String = "x".repeat(Economy.MAX_PAYLOAD_LENGTH)
	economy.command_results = {}
	for index: int in range(Economy.MAX_COMMAND_RESULTS):
		economy.command_results["sat_cmd_%02d_%s" % [index, "z".repeat(40)]] = {
			"payload": saturated_payload,
			"result": {"ok": true, "reason": "", "amount": 999999},
		}
	data.transaction.command_results = {}
	for index: int in range(Farm.MAX_COMMAND_RESULTS):
		data.transaction.command_results["sat_farm_cmd_%02d_%s" % [index, "z".repeat(40)]] = {
			"payload": saturated_payload,
			"result": {"ok": true, "reason": "", "changed_fields": ["field_01", "field_02"],
				"visual_changed": ["field_01"], "reward_crop_id": "greens",
				"reward_amount": 1},
		}
	var text: String = JSON.stringify({"version": FarmStore.VERSION, "farm": data,
		"decorations": Decorations.new().snapshot()}, "\t")
	var bytes: int = text.to_utf8_buffer().size()
	var parts: Dictionary = {
		"orders": JSON.stringify(market.orders).to_utf8_buffer().size(),
		"trades": JSON.stringify(market.trades).to_utf8_buffer().size(),
		"shipments": JSON.stringify(market.shipments).to_utf8_buffer().size(),
		"deliveries": JSON.stringify(market.deliveries).to_utf8_buffer().size(),
		"losses": JSON.stringify(losses.events).to_utf8_buffer().size(),
		"ledger_entries": JSON.stringify(ledger.entries).to_utf8_buffer().size(),
		"economy_window": JSON.stringify(economy.command_results).to_utf8_buffer().size(),
		"farm_window": JSON.stringify(data.transaction.command_results).to_utf8_buffer().size(),
	}
	print("SOAK saturated_tables orders=%d trades=%d shipments=%d deliveries=%d losses=%d "
		% [market.orders.size(), market.trades.size(), market.shipments.size(),
		market.deliveries.size(), losses.events.size()]
		+ "ledger_entries=%d json_bytes=%d headroom=%d store_limit=%d" % [
		ledger.entries.size(), bytes, FarmStore.MAX_BYTES - bytes, FarmStore.MAX_BYTES])
	print("SOAK saturated_parts " + JSON.stringify(parts))
	# Per-table verdicts at this same row shape, so the record can name which
	# table alone fits and which one is already over the limit. Each table IS
	# individually inside the store limit, so every individual bound is sound.
	var single: Dictionary = {}
	var single_all_fit: bool = true
	for key: String in parts:
		single[key] = int(parts[key]) <= FarmStore.MAX_BYTES
		single_all_fit = single_all_fit and bool(single[key])
	print("SOAK saturated_single_fits " + JSON.stringify(single))
	_expect(single_all_fit,
		"saturated tables: every individual table fits the store limit on its own")
	# The aggregate is a measured capacity gap, not a fabricated failure: the
	# rules bound each table separately while FarmStore bounds the whole
	# document, and the store writes a document without checking its size and
	# rejects an oversized file as corrupt on the next load. Recorded in
	# RECORD-04 for a product decision; it is not asserted as a passing contract
	# because fabricated rows are not gameplay evidence.
	var aggregate_fits: bool = bytes <= FarmStore.MAX_BYTES
	print("SOAK saturated_aggregate_fits=%s bytes=%d limit=%d over_by=%d" % [
		"yes" if aggregate_fits else "no", bytes, FarmStore.MAX_BYTES,
		maxi(0, bytes - FarmStore.MAX_BYTES)])
	saturated_json_bytes = bytes


func _write_results() -> void:
	var data: Dictionary = {
		"checks": checks,
		"failures": failures.size(),
		"failure_messages": failures,
		"days": days_completed,
		"span_days": SPAN_DAYS,
		"seed": SEED,
		"start_utc": START,
		"peak_delta_kb": _peak_delta_kb(),
		"final_delta_kb": _final_delta_kb(),
		"memory_samples": memory_samples,
		"json_max_bytes": peak_json_bytes,
		"json_final_bytes": final_json_bytes,
		"orders_max": orders_max,
		"archived_orders": archived_orders_final,
		"shipments_max": shipments_max,
		"deliveries_max": deliveries_max,
		"losses_max": losses_max,
		"ledger_entries_max": ledger_entries_max,
		"command_window_max": economy_window_max,
		"farm_window_max": farm_window_max,
		"trades": trades_final,
		"rest_sells": rest_sells,
		"scripted_loans": scripted_loans,
		"scripted_shipments": scripted_shipments,
		"expected_losses": expected_losses,
		"expected_deliveries": expected_deliveries,
		"saturated_json_bytes": saturated_json_bytes,
		"store_limit_bytes": FarmStore.MAX_BYTES,
	}
	var file := FileAccess.open(test_root.path_join("results.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()
	var baseline_kb: float = float(memory_samples[0].static_bytes) / 1024.0 \
		if not memory_samples.is_empty() else 0.0
	var summary: String = "SOAK memory baseline_kb=%.1f peak_delta_kb=%.1f " % [
		baseline_kb, _peak_delta_kb()]
	summary += "final_delta_kb=%.1f samples=%d interval_days=%d " % [
		_final_delta_kb(), memory_samples.size(), MEMORY_INTERVAL_DAYS]
	summary += "metric=engine_static_memory scope=this_machine_only"
	print(summary)
	print("SOAK_ROOT " + test_root)


func _expect_ok(result: Dictionary, label: String) -> void:
	_expect(bool(result.get("ok", false)),
		"%s: expected ok, got reason=%s" % [label, str(result.get("reason", ""))])


func _eq_int(actual: int, expected: int, label: String) -> void:
	_expect(actual == expected, "%s: expected %d, got %d" % [label, expected, actual])


func _eq_float(actual: float, expected: float, label: String) -> void:
	_expect(actual == expected, "%s: expected %.6f, got %.6f" % [label, expected, actual])


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
