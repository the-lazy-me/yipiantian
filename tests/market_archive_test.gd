extends SceneTree
## M7-09 market archive: bounded order and shipment tables stay usable in a
## long-lived world by evicting only closed/delivered evidence, counters record
## the loss, and trades/deliveries may still point at an evicted row. Headless
## and isolated; no scene, system clock or player save is touched.

const Farm = preload("res://farm/farm_state.gd")
const Market = preload("res://farm/market_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const Catalog = preload("res://farm/economy_catalog.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const V27Importer = preload("res://farm/v27_importer.gd")

const START: float = 1800000000.0
const HOUR: float = 3600.0
const ARRIVE: float = START + Market.DELIVERY_SECONDS
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const PLAYER_D: String = "player_00000000000000000000000000000004"
const PLAYER_E: String = "player_00000000000000000000000000000005"

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/market-archive-%d" % OS.get_process_id()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_shape_and_legacy()
	_test_order_archive_fills_and_evicts()
	_test_merchant_and_open_rows_survive()
	_test_trade_after_order_archive()
	_test_shipment_archive_and_delivery_link()
	_test_delivery_archive()
	_test_loss_archive()
	_test_all_in_transit_limit()
	_test_conservation_and_ledger()
	for failure: String in failures:
		push_error(failure)
	print("MARKET_ARCHIVE_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_shape_and_legacy() -> void:
	var farm := Farm.new(START)
	var market: Dictionary = farm.market_snapshot()
	_expect(int(market.archived_orders) == 0 and int(market.archived_shipments) == 0 \
		and int(market.archived_deliveries) == 0,
		"A new market starts with zero archive counters")
	_expect(market.has("archived_orders") and market.has("archived_shipments") \
		and market.has("archived_deliveries"),
		"All three archive counters are part of the canonical market shape")
	_expect(FarmStore.VERSION == 27,
		"Archiving does not change the farm format version")
	_expect("economy" in V27Importer.KNOWN_FARM_KEYS \
		and not ("archived_orders" in V27Importer.KNOWN_FARM_KEYS) \
		and not ("archived_shipments" in V27Importer.KNOWN_FARM_KEYS),
		"Archive counters stay inside the known economy key")

	var placed: Farm = _fixture(2)
	placed.market_place_order("legacy-order", PLAYER_A, "sell", "greens", 10, 1,
		START + HOUR, START)
	var legacy: Dictionary = placed.snapshot()
	for key: String in Market.ARCHIVE_KEYS:
		legacy.economy.market.erase(key)
	_expect(Market.valid(legacy.economy),
		"A market without archive counters is still valid")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(legacy),
		"An old market without archive counters restores")
	_expect(restored.market_snapshot().archived_orders == 0
		and restored.market_snapshot().archived_shipments == 0
		and restored.market_snapshot().archived_deliveries == 0,
		"A missing archive counter restores as zero")
	_expect(restored.market_order("legacy-order").reserved == 1,
		"Restoring an old market keeps its orders unchanged")

	var half: Dictionary = placed.snapshot()
	half.economy.market.erase("archived_shipments")
	_expect(not Farm.new().restore_snapshot(half),
		"A partially present archive counter set is rejected, not defaulted")


func _test_order_archive_fills_and_evicts() -> void:
	var farm: Farm = _fixture(2)
	for index: int in range(Market.MAX_ORDERS):
		var order_id: String = "fill-%03d" % index
		var placed: Dictionary = farm.market_place_order(order_id, PLAYER_A, "sell",
			"greens", 10, 1, START + HOUR, START)
		_expect(bool(placed.ok), "Closed order %d fits below the table cap" % index)
		var cancelled: Dictionary = farm.market_cancel_order("cancel-%03d" % index,
			PLAYER_A, order_id, START)
		_expect(bool(cancelled.ok), "Closed order %d cancels and returns its basket" % index)
	_expect(farm.market_orders().size() == Market.MAX_ORDERS,
		"The 256 closed rows fill the table")
	_expect(int(farm.market_snapshot().archived_orders) == 0,
		"Filling the table does not archive anything yet")

	var placed_new: Dictionary = farm.market_place_order("fill-new", PLAYER_A, "sell",
		"greens", 10, 1, START + HOUR, START)
	_expect(bool(placed_new.ok),
		"A new order is accepted after the table filled with closed rows")
	_expect(farm.market_orders().size() == Market.MAX_ORDERS,
		"Archiving one row keeps the table at its bound")
	_expect(int(farm.market_snapshot().archived_orders) == 1,
		"One eviction advances the archive counter by one")
	_expect(farm.market_order("fill-000").is_empty(),
		"The earliest closed row is the one evicted")
	_expect(not farm.market_order("fill-001").is_empty()
		and not farm.market_order("fill-new").is_empty(),
		"Later closed rows and the new order survive")
	_expect(_goods_total(farm, "greens") == 2,
		"Archiving a closed sell order moves no goods")

	var accepted: Dictionary = farm.snapshot()
	var after_failure: Dictionary = farm.market_place_order("fill-new", PLAYER_A, "sell",
		"greens", 10, 1, START + HOUR, START)
	_expect(after_failure.duplicate and farm.snapshot() == accepted,
		"The retained new row still replays its own id")
	_expect(farm.market_expire(START + 2.0 * HOUR).ok
		and int(farm.market_snapshot().archived_orders) == 1,
		"Sweeps do not change the archive counter")


func _test_merchant_and_open_rows_survive() -> void:
	var farm: Farm = _fixture(2)
	_expect(farm.market_open_merchant("archive-merchant", START).ok,
		"The archive fixture opens the merchant")
	_expect(farm.market_order(Market.merchant_quote_id("greens", "buy")).is_empty() == false,
		"The merchant quote rows exist before expiry")
	# Expire every rolling quote so the closed merchant rows have the earliest
	# sequences in the table and would win an unfiltered earliest-closed eviction.
	var expired: Dictionary = farm.market_expire(START + Market.MERCHANT_QUOTE_SECONDS)
	_expect(expired.expired == Catalog.goods_ids().size() * 2,
		"Every rolling merchant quote expires at its boundary")
	for index: int in range(Market.MAX_ORDERS - Catalog.goods_ids().size() * 2):
		var order_id: String = "mfill-%03d" % index
		_expect(farm.market_place_order(order_id, PLAYER_A, "sell", "greens", 10, 1,
			START + HOUR, START).ok, "Merchant-table filler %d is accepted" % index)
		_expect(farm.market_cancel_order("mcancel-%03d" % index, PLAYER_A, order_id,
			START).ok, "Merchant-table filler %d cancels" % index)
	_expect(farm.market_orders().size() == Market.MAX_ORDERS,
		"Merchant quote rows plus closed player rows fill the table")

	var first: Dictionary = farm.market_place_order("m-new", PLAYER_A, "sell",
		"greens", 10, 1, START + HOUR, START)
	_expect(first.ok and int(farm.market_snapshot().archived_orders) == 1,
		"A place over the filled table archives one row")
	for good_id: String in Catalog.goods_ids():
		for side: String in ["buy", "sell"]:
			var quote_id: String = Market.merchant_quote_id(good_id, side)
			_expect(not farm.market_order(quote_id).is_empty(),
				"A closed merchant quote row is never evicted: " + quote_id)
	_expect(farm.market_order("mfill-000").is_empty(),
		"The earliest closed player row is evicted instead of a merchant row")
	_expect(not farm.market_order("m-new").is_empty(),
		"The newly placed open row is present")

	var second: Dictionary = farm.market_place_order("m-new-2", PLAYER_A, "sell",
		"greens", 10, 1, START + HOUR, START)
	_expect(second.ok and int(farm.market_snapshot().archived_orders) == 2,
		"A second place archives the next closed player row")
	_expect(not farm.market_order("m-new").is_empty(),
		"An open player row is never evicted")
	_expect(farm.market_order("mfill-001").is_empty(),
		"Only the earliest closed player row goes")
	_expect(_goods_total(farm, "greens") == 2 + Market.MERCHANT_GRANT_PER_GOOD,
		"Merchant and open row protection keeps goods conserved")

	var raw: Dictionary = _raw_data(300, 0)
	var all_open: bool = true
	for index: int in range(Market.MAX_ORDERS):
		var placed: Dictionary = Market.place(raw, "open-%03d" % index, PLAYER_A, "sell",
			"greens", 10, 1, START + HOUR, START)
		all_open = all_open and bool(placed.ok)
	_expect(all_open, "256 open orders fit")
	_expect(str(Market.place(raw, "open-over", PLAYER_A, "sell", "greens", 10, 1,
		START + HOUR, START).reason) == "order_limit",
		"A table of only open rows still returns order_limit")
	_expect(int(raw.economy.market.archived_orders) == 0,
		"A refused order archives nothing")


func _test_trade_after_order_archive() -> void:
	var farm: Farm = _fixture(2)
	_expect(farm.market_place_order("trade-sell", PLAYER_A, "sell", "greens", 10, 2,
		START + HOUR, START).ok, "The trade fixture rests two greens")
	_expect(farm.market_place_order("trade-buy", PLAYER_B, "buy", "greens", 30, 2,
		START + HOUR, START).ok, "The trade fixture places a crossing bid")
	var matched: Dictionary = farm.market_match(START)
	_expect(matched.ok and matched.count == 1, "The crossing pair trades once")
	var trade: Dictionary = farm.market_trade("trade_1")
	_expect(trade.price == 10 and trade.buy_price == 30 and trade.sell_price == 10
		and trade.buy_id == "trade-buy" and trade.sell_id == "trade-sell",
		"The maker price and both order ids are durable evidence")
	for index: int in range(Market.MAX_ORDERS - 2):
		var order_id: String = "afill-%03d" % index
		_expect(farm.market_place_order(order_id, PLAYER_B, "sell", "greens", 10, 1,
			START + HOUR, START).ok, "Trade filler %d is accepted" % index)
		_expect(farm.market_cancel_order("acancel-%03d" % index, PLAYER_B, order_id,
			START).ok, "Trade filler %d cancels" % index)
	_expect(farm.market_orders().size() == Market.MAX_ORDERS,
		"The two trade rows plus 254 closed fillers fill the table")

	var first: Dictionary = farm.market_place_order("arch-one", PLAYER_B, "sell",
		"greens", 10, 1, START + HOUR, START)
	_expect(first.ok and int(farm.market_snapshot().archived_orders) == 1,
		"The first archive removes the earliest trade order row")
	_expect(farm.market_order("trade-sell").is_empty()
		and not farm.market_order("trade-buy").is_empty(),
		"The sell row is gone while the buy row remains")
	var once: Dictionary = farm.snapshot()
	_expect(Market.valid(once.economy),
		"A trade pointing at one archived order row is still valid")
	var reload_once := Farm.new()
	_expect(reload_once.restore_snapshot(once),
		"A trade with one archived order row reloads")
	_expect(reload_once.market_trade("trade_1").price == 10,
		"The reloaded trade keeps its maker price")

	var second: Dictionary = farm.market_place_order("arch-two", PLAYER_B, "sell",
		"greens", 10, 1, START + HOUR, START)
	_expect(second.ok and int(farm.market_snapshot().archived_orders) == 2,
		"The second archive removes the other trade order row")
	_expect(farm.market_order("trade-buy").is_empty(),
		"Both order rows referenced by the trade are now gone")
	var twice: Dictionary = farm.snapshot()
	_expect(Market.valid(twice.economy),
		"A trade pointing at two archived order rows is still valid")
	var reload_twice := Farm.new()
	_expect(reload_twice.restore_snapshot(twice)
		and reload_twice.market_trade("trade_1").buy_owner == PLAYER_B
		and reload_twice.market_trade("trade_1").sell_owner == PLAYER_A,
		"The evidence row carries owner and good semantics through the reload")

	var reuse: Dictionary = farm.market_place_order("trade-sell", PLAYER_A, "sell",
		"greens", 10, 1, START + HOUR, START)
	_expect(not reuse.ok and str(reuse.reason) == "order_exists",
		"An archived order id still named by a retained trade cannot be reused")
	var evicted: Dictionary = farm.snapshot()
	evicted.economy.command_results = {}
	var no_window := Farm.new()
	_expect(no_window.restore_snapshot(evicted),
		"The trade archive snapshot restores without the command window")
	_expect(not no_window.market_place_order("trade-sell", PLAYER_A, "sell",
		"greens", 10, 1, START + HOUR, START).ok,
		"Evicting the command window does not free an id still named by a trade")

	var tampered: Dictionary = twice.duplicate(true)
	tampered.economy.market.trades["trade_1"].price = 20
	_expect(not Farm.new().restore_snapshot(tampered),
		"A trade price that is neither limit is rejected after archiving")
	var out_of_range: Dictionary = twice.duplicate(true)
	out_of_range.economy.market.trades["trade_1"].sell_price = 25
	_expect(not Farm.new().restore_snapshot(out_of_range),
		"A tampered sell limit that crosses the trade price is rejected")
	var bad_owner: Dictionary = once.duplicate(true)
	bad_owner.economy.market.trades["trade_1"].buy_owner = PLAYER_A
	_expect(not Farm.new().restore_snapshot(bad_owner),
		"A present order row is still cross-checked against the trade owner")


func _test_shipment_archive_and_delivery_link() -> void:
	var farm: Farm = _funded_shipment_fixture(2)
	var delivered_cycles: int = Market.MAX_SHIPMENTS - 1
	for index: int in range(delivered_cycles):
		var at: float = START + float(index) * 1000.0
		var ship_id: String = "ship-%03d" % index
		_expect(farm.market_ship(ship_id, PLAYER_A, Market.LOCATION_FARM,
			Market.LOCATION_HARBOR, "greens", 1, at).ok,
			"Shipment %d enters transit" % index)
		_expect(farm.market_deliver(at + Market.DELIVERY_SECONDS).count == 1,
			"Shipment %d delivers" % index)
	_expect(farm.market_shipments().size() == Market.MAX_SHIPMENTS - 1,
		"Delivered rows accumulate below the table bound")
	_expect(farm.market_deliveries().size() == Market.MAX_SHIPMENTS - 1,
		"Each delivery wrote one durable event")

	var hold_at: float = START + float(delivered_cycles) * 1000.0
	_expect(farm.market_ship("transit-hold", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 1, hold_at).ok,
		"An in-transit row fills the last shipment slot")
	_expect(farm.market_shipments().size() == Market.MAX_SHIPMENTS,
		"The shipment table is now full")
	var archived_at: float = hold_at + 1.0
	var continued: Dictionary = farm.market_ship("ship-arch", PLAYER_A,
		Market.LOCATION_FARM, Market.LOCATION_HARBOR, "greens", 1, archived_at)
	_expect(continued.ok,
		"A new shipment is accepted after the table filled with delivered rows")
	_expect(farm.market_shipments().size() == Market.MAX_SHIPMENTS,
		"Archiving one shipment keeps the table at its bound")
	_expect(int(farm.market_snapshot().archived_shipments) == 1,
		"One shipment eviction advances the archive counter by one")
	_expect(farm.market_shipment("ship-000").is_empty(),
		"The earliest delivered shipment is evicted")
	_expect(not farm.market_shipment("ship-001").is_empty(),
		"Later delivered rows survive")
	_expect(farm.market_shipment("transit-hold").status == Market.SHIPMENT_STATUS_TRANSIT
		and farm.market_shipment("ship-arch").status == Market.SHIPMENT_STATUS_TRANSIT,
		"In-transit rows are never evicted")
	_expect(farm.market_delivery("delivery_1").shipment_id == "ship-000",
		"The delivery event for the archived shipment is still durable")

	var snapshot: Dictionary = farm.snapshot()
	_expect(Market.valid(snapshot.economy),
		"A delivery pointing at an archived shipment is still valid")
	var reopened := Farm.new()
	_expect(reopened.restore_snapshot(snapshot),
		"A delivery pointing at an archived shipment reloads")
	_expect(reopened.market_delivery("delivery_1").quantity == 1
		and reopened.market_delivery("delivery_1").owner == PLAYER_A
		and reopened.market_delivery("delivery_1").destination == Market.LOCATION_HARBOR,
		"The archived shipment's delivery keeps its own evidence fields")
	_expect(reopened.market_ship("ship-000", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 1, archived_at).reason == "shipment_exists",
		"An archived shipment id still named by its delivery cannot be reused")

	var bad_quantity: Dictionary = snapshot.duplicate(true)
	bad_quantity.economy.market.deliveries["delivery_2"].quantity = 2
	_expect(not Farm.new().restore_snapshot(bad_quantity),
		"A present delivery row is still cross-checked against its shipment quantity")
	var bad_shipment: Dictionary = snapshot.duplicate(true)
	bad_shipment.economy.market.shipments["ship-001"].quantity = 2
	_expect(not Farm.new().restore_snapshot(bad_shipment),
		"A present delivered shipment is still cross-checked against its delivery")
	var bad_route: Dictionary = snapshot.duplicate(true)
	# The archived shipment has no row to compare against, but the delivery row
	# still validates its own route: making both ends the same is rejected.
	bad_route.economy.market.deliveries["delivery_1"].origin = Market.LOCATION_HARBOR
	_expect(not Farm.new().restore_snapshot(bad_route),
		"An archived shipment's delivery still validates its own route")


func _test_delivery_archive() -> void:
	var farm: Farm = _funded_shipment_fixture(2)
	for index: int in range(Market.MAX_DELIVERIES):
		var at: float = START + float(index) * 1000.0
		_expect(farm.market_ship("dship-%03d" % index, PLAYER_A, Market.LOCATION_FARM,
			Market.LOCATION_HARBOR, "greens", 1, at).ok,
			"Delivery-archive shipment %d enters transit" % index)
		_expect(farm.market_deliver(at + Market.DELIVERY_SECONDS).count == 1,
			"Delivery-archive shipment %d delivers" % index)
	_expect(farm.market_deliveries().size() == Market.MAX_DELIVERIES,
		"The delivery table is full")
	_expect(int(farm.market_snapshot().archived_deliveries) == 0,
		"Filling the delivery table does not archive anything yet")
	var cash_before: int = farm.economy_cash(PLAYER_A)
	var goods_before: int = _goods_total(farm, "greens")

	# Shipping over the full shipment table evicts the oldest delivered row;
	# delivering over the full delivery table then evicts the oldest event.
	var at_next: float = START + float(Market.MAX_DELIVERIES) * 1000.0
	_expect(farm.market_ship("dship-arch", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 1, at_next).ok,
		"A shipment is accepted when both tables are full")
	_expect(farm.market_shipment("dship-000").is_empty(),
		"The oldest delivered shipment row is evicted")
	var delivered: Dictionary = farm.market_deliver(at_next + Market.DELIVERY_SECONDS)
	_expect(delivered.ok and delivered.count == 1,
		"A delivery is accepted after the delivery table filled")
	_expect(farm.market_deliveries().size() == Market.MAX_DELIVERIES,
		"Archiving one event keeps the delivery table at its bound")
	_expect(int(farm.market_snapshot().archived_deliveries) == 1,
		"One delivery eviction advances the archive counter by one")
	_expect(farm.market_delivery("delivery_1").is_empty(),
		"The delivery with the earliest sequence is evicted")
	_expect(not farm.market_delivery("delivery_2").is_empty(),
		"Later delivery rows survive")
	_expect(farm.market_delivery("delivery_257").shipment_id == "dship-arch"
		and farm.market_delivery("delivery_257").owner == PLAYER_A
		and farm.market_delivery("delivery_257").quantity == 1,
		"The new delivery event is written with its own durable fields")
	_expect(_goods_total(farm, "greens") == goods_before,
		"Delivery archiving moves no goods")
	# One fee was burned for the new shipment, so issued and total cash both fall
	# by exactly SHIPMENT_FEE from the pre-archive amount.
	_expect(farm.economy_cash(PLAYER_A) == cash_before - Market.SHIPMENT_FEE
		and farm.economy_issued() == cash_before - Market.SHIPMENT_FEE
		and farm.economy_total_cash() == farm.economy_issued(),
		"Delivery archiving leaves cash at the net issued total")
	_expect(farm.economy_reconcile().ok,
		"The ledger reconciles after delivery archiving")

	var snapshot: Dictionary = farm.snapshot()
	_expect(Market.valid(snapshot.economy),
		"A market with an archived delivery event is still valid")
	var reopened := Farm.new()
	_expect(reopened.restore_snapshot(snapshot),
		"A market with an archived delivery event reloads")
	_expect(reopened.market_delivery("delivery_257").shipment_id == "dship-arch",
		"The retained delivery event resolves after the reload")

	var forged: Dictionary = snapshot.duplicate(true)
	forged.economy.market.deliveries.erase("delivery_2")
	forged.economy.market.deliveries.erase("delivery_3")
	_expect(not Farm.new().restore_snapshot(forged),
		"More missing delivery events than archived_deliveries is rejected")
	var consistent: Dictionary = snapshot.duplicate(true)
	consistent.economy.market.deliveries.erase("delivery_2")
	consistent.economy.market.archived_deliveries = 2
	_expect(Farm.new().restore_snapshot(consistent),
		"A delivered shipment whose event was archived is still accepted")
	# Two delivered rows pointing at the same archived delivery id must not slip
	# through: distinct ids stay under `archived_deliveries` while one evicted
	# receipt would appear to settle two shipments.
	var shared: Dictionary = consistent.duplicate(true)
	var present_deliveries: Array[String] = []
	for shipment_id: Variant in shared.economy.market.shipments:
		var row: Dictionary = shared.economy.market.shipments[shipment_id]
		if str(row.status) == Market.SHIPMENT_STATUS_DELIVERED \
				and shared.economy.market.deliveries.has(str(row.delivery_id)):
			present_deliveries.append(str(shipment_id))
	_expect(present_deliveries.size() >= 2,
		"The shared-receipt fixture has two delivered rows with live events")
	if present_deliveries.size() >= 2:
		var first_row: Dictionary = shared.economy.market.shipments[present_deliveries[0]]
		var second_row: Dictionary = shared.economy.market.shipments[present_deliveries[1]]
		shared.economy.market.deliveries.erase(str(first_row.delivery_id))
		shared.economy.market.deliveries.erase(str(second_row.delivery_id))
		shared.economy.market.archived_deliveries = \
			int(shared.economy.market.archived_deliveries) + 2
		second_row.delivery_id = str(first_row.delivery_id)
		_expect(not Farm.new().restore_snapshot(shared),
			"Two delivered rows sharing one archived delivery event are rejected")

	# The archived delivery no longer reserves its shipment id: the shipment row
	# is gone and no retained delivery names it. The command id still cannot post
	# a second ledger event, so the next refusal is the journal's duplicate id,
	# not `shipment_exists`. This is the known reuse boundary.
	var reused: Dictionary = farm.market_ship("dship-000", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 1, at_next + 10.0)
	_expect(not reused.ok and str(reused.reason) == "duplicate_event",
		"An archived delivery no longer reserves the shipment id; the ledger still does")


## M8-03a loss evidence is bounded by the same rule as the other durable logs:
## only terminal loss rows are evicted, the `archived` count keeps the holes
## exact, and a lost shipment id stays reserved while its event is present.
func _test_loss_archive() -> void:
	var farm := Farm.new(START)
	var economy: Dictionary = farm.economy_snapshot()
	economy.accounts[PLAYER_A] = {"cash": 100000, "granted": false}
	economy.issued = 100000
	var data: Dictionary = {"economy": economy, "bags": {PLAYER_A: {"greens": 5000}}}
	var cycles: int = 0
	while int(data.economy.losses.sequence) <= Market.MAX_LOSSES and cycles < 20:
		for index: int in range(Market.MAX_SHIPMENTS):
			_expect(Market.ship(data, "loss-%d-%03d" % [cycles, index], PLAYER_A,
				Market.LOCATION_FARM, Market.LOCATION_HARBOR, "greens", 1, START,
				Market.SHIPMENT_RISK_DECLARED).ok,
				"Loss-archive cycle %d ships %d" % [cycles, index])
		_expect(Market.deliver(data, ARRIVE).ok,
			"Loss-archive cycle %d settles arrivals" % cycles)
		cycles += 1
	_expect(cycles < 20 and int(data.economy.losses.sequence) > Market.MAX_LOSSES,
		"The loss-archive fixture generated more losses than the table bound")
	_expect(data.economy.losses.events.size() == Market.MAX_LOSSES,
		"The loss table stays at its 256-row bound")
	_expect(int(data.economy.losses.archived) > 0 \
		and int(data.economy.losses.archived) \
			+ data.economy.losses.events.size() == int(data.economy.losses.sequence),
		"The archive counter exactly accounts for every evicted loss")
	_expect(data.economy.losses.events.get("loss_1") == null,
		"The earliest loss event is archived first")
	_expect(Market.valid_losses(data.economy),
		"The bounded loss table validates with its archived holes")
	_expect(Economy.total_cash(data.economy) == Economy.issued(data.economy),
		"Loss archiving keeps cash equal to net issued")
	_expect(int(data.economy.market.archived_shipments) > 0,
		"Terminal shipment rows (delivered or lost) are archived")

	var forged_count: Dictionary = data.economy.duplicate(true)
	forged_count.losses.events.erase(forged_count.losses.events.keys()[0])
	_expect(not Market.valid_losses(forged_count),
		"A missing loss event the archive counter does not explain is rejected")
	var forged_archive: Dictionary = data.economy.duplicate(true)
	forged_archive.losses.archived = int(forged_archive.losses.archived) + 1
	_expect(not Market.valid_losses(forged_archive),
		"An inflated archive counter is rejected")
	var forged_sequence: Dictionary = data.economy.duplicate(true)
	forged_sequence.losses.sequence = int(forged_sequence.losses.sequence) - 1
	_expect(not Market.valid_losses(forged_sequence),
		"A loss sequence behind its rows is rejected")

	var single: Dictionary = _raw_data(2000, 100000)
	_expect(Market.ship(single, "single-loss", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 2, START,
		Market.SHIPMENT_RISK_DECLARED).ok, "The single-loss fixture ships two greens")
	_expect(Market.deliver(single, ARRIVE).lost == 1,
		"The single-loss fixture produces the declared loss")
	_expect(Market.valid_losses(single.economy), "The single-loss table validates")
	var hidden: Dictionary = single.economy.duplicate(true)
	hidden.losses.events = {}
	hidden.losses.archived = 0
	_expect(not Market.valid_losses(hidden),
		"A lost shipment with no event and no archive count is rejected")
	var moved_value: Dictionary = single.economy.duplicate(true)
	moved_value.losses.events["loss_1"].value = 1
	_expect(not Market.valid_losses(moved_value),
		"A loss value that does not equal unit value times quantity is rejected")
	var wrong_unit: Dictionary = single.economy.duplicate(true)
	wrong_unit.losses.events["loss_1"].unit_value = 1
	wrong_unit.losses.events["loss_1"].value = 2
	_expect(not Market.valid_losses(wrong_unit),
		"A loss unit value off the catalog reference price is rejected")
	var wrong_window: Dictionary = single.economy.duplicate(true)
	wrong_window.losses.events["loss_1"].cause_end_utc = ARRIVE + 1.0
	_expect(not Market.valid_losses(wrong_window),
		"A loss window that does not match the shipment window is rejected")
	var lost_with_delivery: Dictionary = single.economy.duplicate(true)
	lost_with_delivery.market.shipments["single-loss"].delivery_id = "delivery_1"
	_expect(not Market.valid(lost_with_delivery),
		"A lost shipment claiming a delivery id is rejected")
	var safe_lost: Dictionary = single.economy.duplicate(true)
	safe_lost.market.shipments["single-loss"].risk = Market.SHIPMENT_RISK_SAFE
	_expect(not Market.valid(safe_lost),
		"A safe shipment cannot reach the terminal lost state")


func _test_all_in_transit_limit() -> void:
	var data: Dictionary = _raw_data(300, 1000)
	var all_in_transit: bool = true
	for index: int in range(Market.MAX_SHIPMENTS):
		var shipped: Dictionary = Market.ship(data, "raw-ship-%03d" % index, PLAYER_A,
			Market.LOCATION_FARM, Market.LOCATION_HARBOR, "greens", 1, START)
		all_in_transit = all_in_transit and bool(shipped.ok)
	_expect(all_in_transit, "256 in-transit shipments fill the table")
	_expect(int(data.economy.market.archived_shipments) == 0,
		"Filling with in-transit rows archives nothing")
	_expect(str(Market.ship(data, "raw-ship-over", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 1, START).reason) == "shipment_limit",
		"A table of only in-transit rows still returns shipment_limit")
	_expect(int(data.economy.market.archived_shipments) == 0,
		"A refused shipment archives nothing")


func _test_conservation_and_ledger() -> void:
	var orders: Farm = _fixture(2)
	for index: int in range(Market.MAX_ORDERS + 1):
		var order_id: String = "cons-%03d" % index
		orders.market_place_order(order_id, PLAYER_A, "sell", "greens", 10, 1,
			START + HOUR, START)
		orders.market_cancel_order("consc-%03d" % index, PLAYER_A, order_id, START)
	var order_market: Dictionary = orders.market_snapshot()
	_expect(int(order_market.archived_orders) == 1,
		"The conservation fixture archived one order row")
	_expect(orders.economy_total_cash() == orders.economy_issued()
		and orders.economy_issued() == Economy.OPENING_GRANT * 2,
		"Order archiving leaves cash at the issued total")
	_expect(orders.economy_reconcile().ok,
		"The ledger reconciles after order archiving")
	_expect(_goods_total(orders, "greens") == 2,
		"Order archiving leaves the two baskets conserved")

	var shipments: Farm = _funded_shipment_fixture(2)
	for index: int in range(Market.MAX_SHIPMENTS):
		var at: float = START + float(index) * 1000.0
		shipments.market_ship("cship-%03d" % index, PLAYER_A, Market.LOCATION_FARM,
			Market.LOCATION_HARBOR, "greens", 1, at)
		shipments.market_deliver(at + Market.DELIVERY_SECONDS)
	shipments.market_ship("cship-arch", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 1, START + 500000.0)
	_expect(int(shipments.market_snapshot().archived_shipments) == 1,
		"The shipment conservation fixture archived one delivered row")
	_expect(shipments.economy_total_cash() == shipments.economy_issued(),
		"Shipment archiving leaves cash equal to net issued")
	_expect(shipments.economy_reconcile().ok,
		"The ledger reconciles after shipment archiving")
	_expect(_goods_total(shipments, "greens") == 2,
		"Shipment archiving leaves every basket and in-transit unit conserved")
	_expect(shipments.market_delivery("delivery_1").shipment_id == "cship-000",
		"The archived shipment remains traceable through its delivery")


## Two greens on real cells, A and B with the standard opening grant.
func _fixture(greens: int) -> Farm:
	var farm := Farm.new(START)
	var cells: Array[String] = ["cell_01", "cell_02", "cell_03", "cell_04"]
	for index: int in range(greens):
		farm.sow("field_01", cells[index], "greens", START, PLAYER_A)
	farm.mature_all_crops(START)
	for index: int in range(greens):
		farm.harvest("field_01", cells[index], START, PLAYER_A)
	farm.economy_open_account("open-a", PLAYER_A, START)
	farm.economy_open_account("open-b", PLAYER_B, START)
	return farm


## A has enough cash for every shipment fee: four more opening grants are paid
## into A, so the fixture still uses the real issuance and ledger paths.
func _funded_shipment_fixture(greens: int) -> Farm:
	var farm: Farm = _fixture(greens)
	var donors: Array[String] = [PLAYER_B, PLAYER_C, PLAYER_D, PLAYER_E]
	for index: int in range(donors.size()):
		var donor: String = donors[index]
		if donor != PLAYER_B:
			farm.economy_open_account("fund-open-%d" % index, donor, START)
		_expect(farm.economy_pay("fund-pay-%d" % index, donor, PLAYER_A,
			Economy.OPENING_GRANT, START).ok, "Funding donor %d pays A" % index)
	_expect(farm.economy_cash(PLAYER_A) == Economy.OPENING_GRANT * 5,
		"A holds five opening grants for the fee fixture")
	return farm


## Raw rule-level data: skip snapshot validation only for table-bound checks
## that would otherwise need hundreds of real baskets and grants.
func _raw_data(goods: int, cash: int) -> Dictionary:
	var farm := Farm.new(START)
	var economy: Dictionary = farm.economy_snapshot()
	economy.accounts[PLAYER_A] = {"cash": cash, "granted": false}
	economy.issued = cash
	return {"economy": economy, "bags": {PLAYER_A: {"greens": goods}}}


func _goods_total(farm: Farm, good_id: String) -> int:
	var total: int = int(farm.bag(PLAYER_A).get(good_id, 0)) \
		+ int(farm.bag(PLAYER_B).get(good_id, 0))
	if farm.market_merchant().get("goods") is Dictionary:
		total += int(farm.market_merchant().goods.get(good_id, 0))
	for order: Dictionary in farm.market_orders():
		if str(order.side) == "sell" and str(order.good) == good_id \
				and str(order.status) == Market.STATUS_OPEN:
			total += int(order.reserved)
	for shipment: Dictionary in farm.market_shipments():
		if str(shipment.good) == good_id \
				and str(shipment.status) == Market.SHIPMENT_STATUS_TRANSIT:
			total += int(shipment.quantity)
	return total


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
