extends SceneTree
## M7-05 supply/demand experiment. Headless and isolated: no scene, system
## clock or player save is touched, and the live rules are only called through
## their public FarmState/Market/Economy entry points.
##
## The scenarios below are synthetic. Producers grow real greens on real cells;
## "resident demand" is a buy order plus an explicit harness step that removes
## the purchased basket from the consumer's bag, because this slice has no
## player-bag eat route (the kitchen consumes the shared inventory). Limit
## prices are scenario inputs, not price discovery: the rules execute orders,
## they do not infer a market-clearing price.
##
## Every scenario checks the two hard invariants (total_cash == issued and
## pockets + sell escrow + in transit + consumed == produced) and the loop
## cases check that repeating a round trip never increases a player's cash.

const Farm = preload("res://farm/farm_state.gd")
const Market = preload("res://farm/market_state.gd")

const START: float = 1800000000.0
const HOUR: float = 3600.0
const EXPIRY: float = START + 6.0 * HOUR
const PLAYER_A: String = "player_supply_demand_0001"
const PLAYER_B: String = "player_supply_demand_0002"
const PLAYER_C: String = "player_supply_demand_0003"
const PLAYER_D: String = "player_supply_demand_0004"
const PLAYER_E: String = "player_supply_demand_0005"
const MERCHANT: String = "@merchant"

var checks: int = 0
var failures: Array[String] = []
var rows: Array[String] = []
var test_root: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/supply-demand-%d" % OS.get_process_id()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_scenario_normal()
	_scenario_poor_harvest()
	_scenario_hoarding()
	_scenario_no_counterparty()
	_scenario_merchant_spread()
	_scenario_freight()
	_scenario_player_round_trip()
	_scenario_self_sufficiency()
	_scenario_order_cap()
	_scenario_repeated_cycles()
	var log_path: String = test_root.path_join("rows.txt")
	var file: FileAccess = FileAccess.open(log_path, FileAccess.WRITE)
	if file != null:
		for row: String in rows:
			file.store_line(row)
		file.close()
	for failure: String in failures:
		push_error(failure)
	print("MARKET_SUPPLY_DEMAND_TEST checks=%d failures=%d root=%s" % [
		checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


## 1. Normal production and trade. Three producers harvest eight greens each;
## two residents each buy twelve at the producers' ask. Every basket is sold and
## consumed, and the four 1 COIN fees are the only cash destroyed.
func _scenario_normal() -> void:
	var farm := Farm.new(START)
	for owner: String in [PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D, PLAYER_E]:
		_open(farm, owner, START)
	var produced: int = _grow(farm, "field_01", _cells(1, 8), "greens", PLAYER_A, START)
	produced += _grow(farm, "field_02", _cells(1, 8), "greens", PLAYER_B, START)
	produced += _grow(farm, "field_01", _cells(9, 16), "greens", PLAYER_C, START)
	_expect(produced == 24, "Normal production yields 24 greens")
	var start: Dictionary = _balances(farm, [PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D, PLAYER_E])
	_place(farm, "normal-sell-a", PLAYER_A, "sell", "greens", 6, 8, START)
	_place(farm, "normal-sell-b", PLAYER_B, "sell", "greens", 6, 8, START)
	_place(farm, "normal-sell-c", PLAYER_C, "sell", "greens", 6, 8, START)
	_place(farm, "normal-buy-d", PLAYER_D, "buy", "greens", 6, 12, START)
	_place(farm, "normal-buy-e", PLAYER_E, "buy", "greens", 6, 12, START)
	var matched: Dictionary = _match(farm, START, 4, "normal")
	_expect(int(matched.notional) == 144, "Normal trades clear 24 greens at 6 COIN")
	_expect(_fees(farm) == 4, "Normal trading burns four 1 COIN fees")
	_consume(farm, PLAYER_D, "greens", 12)
	_consume(farm, PLAYER_E, "greens", 12)
	_expect_cash(farm, "normal")
	_expect_goods(farm, "greens", produced, 24, "normal")
	_expect_trade_accounting(farm, "normal")
	_expect(farm.economy_issued() == 596 and farm.economy_total_cash() == 596,
		"Normal trading leaves 600 - 4 = 596 COIN")
	_expect(_goods_total(farm, "greens") == 0, "Every normal-harvest basket was sold and consumed")
	_record_balances("normal", start, farm, [PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D, PLAYER_E])
	_row("SCENARIO normal good=greens rounds=1 produced=24 consumed=24 volume=24 trades=4 " \
		+ "price=6 fees=4 shipping=0 issued=596 total_cash=596 pockets_end=0 escrow_end=0 " \
		+ "transit_end=0 zero_cost_loop=no negative_balance=no")


## 2. Poor harvest. The same demand meets only six baskets: three, two and one.
## The buy order is rationed and keeps four units escrowed; expiry returns the
## escrow without a fee. A second pass has sellers ask 8 while the buyer bids 6,
## so no trade clears at all.
func _scenario_poor_harvest() -> void:
	var farm := Farm.new(START)
	for owner: String in [PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D]:
		_open(farm, owner, START)
	var produced: int = _grow(farm, "field_01", _cells(1, 3), "greens", PLAYER_A, START)
	produced += _grow(farm, "field_02", _cells(1, 2), "greens", PLAYER_B, START)
	produced += _grow(farm, "field_01", _cells(9, 9), "greens", PLAYER_C, START)
	_expect(produced == 6, "The poor-harvest fixture yields six greens")
	var start: Dictionary = _balances(farm, [PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D])
	_place(farm, "poor-sell-a", PLAYER_A, "sell", "greens", 6, 3, START)
	_place(farm, "poor-sell-b", PLAYER_B, "sell", "greens", 6, 2, START)
	_place(farm, "poor-sell-c", PLAYER_C, "sell", "greens", 6, 1, START)
	_place(farm, "poor-buy-d", PLAYER_D, "buy", "greens", 6, 10, START)
	var matched: Dictionary = _match(farm, START, 3, "poor harvest")
	_expect(int(matched.notional) == 36, "Six scarce greens clear at 6 COIN")
	_expect(_fees(farm) == 3, "Three rationed fills burn three fees")
	_consume(farm, PLAYER_D, "greens", 6)
	var rationed: Dictionary = farm.market_order("poor-buy-d")
	_expect(str(rationed.status) == Market.STATUS_OPEN and int(rationed.remaining) == 4 \
		and int(rationed.reserved) == 24,
		"Unmet demand stays open with four units and 24 COIN escrowed")
	_expect_cash(farm, "poor harvest")
	_expect_goods(farm, "greens", produced, 6, "poor harvest")
	_expect_trade_accounting(farm, "poor harvest")
	_expect(farm.economy_issued() == 477, "Poor harvest burns 480 - 3 = 477 COIN")
	_expect(farm.economy_cash(PLAYER_D) == 60, "The rationed buyer still holds 60 COIN plus 24 escrow")
	var expired: Dictionary = farm.market_expire(EXPIRY)
	_expect(int(expired.expired) == 1 and int(expired.released_cash) == 24,
		"Expiry returns the unfilled 24 COIN without a fee")
	_expect(farm.economy_cash(PLAYER_D) == 84 and farm.economy_issued() == 477,
		"Expiry moves escrow back to available cash and never issues")
	_expect_cash(farm, "poor harvest expiry")
	_record_balances("poor_harvest", start, farm, [PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D])
	_row("SCENARIO poor_harvest good=greens rounds=1 produced=6 consumed=6 volume=6 trades=3 " \
		+ "price=6 fees=3 shipping=0 issued=477 total_cash=477 unmet=4 escrow_cash_end=0 " \
		+ "pockets_end=0 zero_cost_loop=no negative_balance=no")

	# The same scarcity with an ask above the buyer's limit: no fill at all.
	var high := Farm.new(START)
	for owner: String in [PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D]:
		_open(high, owner, START)
	var high_produced: int = _grow(high, "field_01", _cells(1, 3), "greens", PLAYER_A, START)
	high_produced += _grow(high, "field_02", _cells(1, 2), "greens", PLAYER_B, START)
	high_produced += _grow(high, "field_01", _cells(9, 9), "greens", PLAYER_C, START)
	_place(high, "high-sell-a", PLAYER_A, "sell", "greens", 8, 3, START)
	_place(high, "high-sell-b", PLAYER_B, "sell", "greens", 8, 2, START)
	_place(high, "high-sell-c", PLAYER_C, "sell", "greens", 8, 1, START)
	_place(high, "high-buy-d", PLAYER_D, "buy", "greens", 6, 6, START)
	_match(high, START, 0, "scarcity no fill")
	_expect(_fees(high) == 0, "A price gap burns no fee because nothing trades")
	_expect_cash(high, "scarcity no fill")
	_expect_goods(high, "greens", high_produced, 0, "scarcity no fill")
	_expect(int(high.market_order("high-buy-d").remaining) == 6,
		"The above-limit buy order stays open")
	_row("SCENARIO scarcity_no_fill good=greens rounds=1 produced=6 consumed=0 volume=0 " \
		+ "trades=0 ask=8 bid=6 price_gap=2 fees=0 shipping=0 issued=480 total_cash=480 " \
		+ "unmet=6 zero_cost_loop=no negative_balance=no")


## 3. Hoarding. One player spends the whole opening grant to take every sell
## order, then asks 12 while the only other buyer bids 10. The supply is locked
## in a sell order and cannot reach the consumer; no second fill occurs.
func _scenario_hoarding() -> void:
	var farm := Farm.new(START)
	for owner: String in [PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D]:
		_open(farm, owner, START)
	var produced: int = _grow(farm, "field_01", _cells(1, 8), "greens", PLAYER_A, START)
	produced += _grow(farm, "field_02", _cells(1, 8), "greens", PLAYER_B, START)
	produced += _grow(farm, "field_01", _cells(9, 16), "greens", PLAYER_C, START)
	_expect(produced == 24, "The hoarding fixture produces 24 greens")
	var start: Dictionary = _balances(farm, [PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D])
	_place(farm, "hoard-buy-a", PLAYER_A, "buy", "greens", 8, 15, START)
	_place(farm, "hoard-sell-b", PLAYER_B, "sell", "greens", 6, 7, START)
	_place(farm, "hoard-sell-c", PLAYER_C, "sell", "greens", 6, 8, START)
	var matched: Dictionary = _match(farm, START, 2, "hoarding")
	_expect(int(matched.notional) == 120 and int(matched.fee) == 2,
		"The hoarder spends 120 COIN on 15 greens")
	_expect(farm.economy_cash(PLAYER_A) == 0 and _bag_amount(farm, PLAYER_A, "greens") == 23,
		"The hoarder holds 23 greens with no available cash")
	_place(farm, "hoard-sell-a", PLAYER_A, "sell", "greens", 12, 23, START)
	_place(farm, "hoard-buy-d", PLAYER_D, "buy", "greens", 10, 10, START)
	_match(farm, START, 0, "hoarding resale")
	_expect(farm.economy_cash(PLAYER_A) == 0,
		"The hoarder cannot realize the resale at 12 while the buyer bids 10")
	_expect(int(farm.market_order("hoard-buy-d").remaining) == 10,
		"The consumer's demand stays unmet")
	_expect(int(farm.market_order("hoard-sell-a").reserved) == 23,
		"All 23 greens are escrowed in the unsold sell order")
	_expect_cash(farm, "hoarding")
	_expect_goods(farm, "greens", produced, 0, "hoarding")
	_expect_trade_accounting(farm, "hoarding")
	_expect(farm.economy_issued() == 478, "Hoarding burns only the two first-fill fees")
	_record_balances("hoarding", start, farm, [PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D])
	_row("SCENARIO hoarding good=greens rounds=1 produced=24 consumed=0 volume=15 trades=2 " \
		+ "price=8 fees=2 shipping=0 issued=478 total_cash=478 hoarder_cash=0 " \
		+ "hoarder_goods=23 locked_supply=23 resale_volume=0 zero_cost_loop=no negative_balance=no")
	var released: Dictionary = farm.market_expire(EXPIRY)
	_expect(int(released.expired) == 2 and int(released.released_cash) == 100,
		"Expiry releases the consumer's 100 COIN")
	_expect(_bag_amount(farm, PLAYER_A, "greens") == 23
		and _bag_amount(farm, PLAYER_B, "greens") == 1,
		"Expiry returns the hoarded greens and keeps the unsold basket")
	_expect_cash(farm, "hoarding expiry")


## 4. No counterparty. Buy-only and sell-only books never fill, so no fee is
## burned and expiry is the only thing that returns the escrow.
func _scenario_no_counterparty() -> void:
	var bids := Farm.new(START)
	_open(bids, PLAYER_D, START)
	_place(bids, "bids-buy-d", PLAYER_D, "buy", "greens", 6, 10, START)
	_match(bids, START, 0, "buy-only book")
	_expect(_fees(bids) == 0, "A buy-only book burns no fee")
	_expect(bids.economy_cash(PLAYER_D) == 60 and int(bids.market_order("bids-buy-d").reserved) == 60,
		"The buy-only escrow holds 60 COIN")
	var bid_expiry: Dictionary = bids.market_expire(EXPIRY)
	_expect(int(bid_expiry.expired) == 1 and bids.economy_cash(PLAYER_D) == 120,
		"Expiry returns the buy-only escrow in full")
	_expect_cash(bids, "buy-only")
	_row("SCENARIO buy_only good=greens produced=0 consumed=0 volume=0 trades=0 fees=0 " \
		+ "issued=120 total_cash=120 escrow_cash_start=60 escrow_cash_end=0 negative_balance=no")

	var asks := Farm.new(START)
	_open(asks, PLAYER_A, START)
	_open(asks, PLAYER_B, START)
	var produced: int = _grow(asks, "field_01", _cells(1, 8), "greens", PLAYER_A, START)
	produced += _grow(asks, "field_02", _cells(1, 8), "greens", PLAYER_B, START)
	_place(asks, "asks-sell-a", PLAYER_A, "sell", "greens", 6, 8, START)
	_place(asks, "asks-sell-b", PLAYER_B, "sell", "greens", 6, 8, START)
	_match(asks, START, 0, "sell-only book")
	_expect(_fees(asks) == 0, "A sell-only book burns no fee")
	_expect(_goods_total(asks, "greens") == 16
		and int(asks.market_order("asks-sell-a").reserved) == 8,
		"The sell-only escrow holds all 16 greens")
	var ask_expiry: Dictionary = asks.market_expire(EXPIRY)
	_expect(int(ask_expiry.expired) == 2 and int(ask_expiry.released_goods.get("greens", 0)) == 16,
		"Expiry returns all 16 greens to their owners")
	_expect_goods(asks, "greens", produced, 0, "sell-only expiry")
	_expect_cash(asks, "sell-only")
	_row("SCENARIO sell_only good=greens produced=16 consumed=0 volume=0 trades=0 fees=0 " \
		+ "issued=240 total_cash=240 escrow_goods_start=16 escrow_goods_end=0 negative_balance=no")

	var idle := Farm.new(START)
	var idle_produced: int = _grow(idle, "field_01", _cells(1, 4), "greens", PLAYER_A, START)
	var before: Dictionary = idle.snapshot()
	var idle_match: Dictionary = idle.market_match(START)
	var idle_expire: Dictionary = idle.market_expire(EXPIRY)
	var idle_deliver: Dictionary = idle.market_deliver(EXPIRY)
	_expect(int(idle_match.count) == 0 and int(idle_expire.expired) == 0 and int(idle_deliver.count) == 0,
		"An empty market has no trade, expiry or delivery work")
	_expect(idle.snapshot() == before,
		"Empty sweeps change nothing, so farming is independent of the market")
	_expect(idle.economy_issued() == 0 and _bag_amount(idle, PLAYER_A, "greens") == idle_produced,
		"No market means no cash and the harvest stays in the bag")
	_row("SCENARIO no_orders good=greens produced=4 consumed=0 volume=0 trades=0 fees=0 " \
		+ "issued=0 total_cash=0 pockets_end=4 negative_balance=no")


## 5a. Merchant bid/ask round trip. The rolling merchant quotes are bid 5 and
## ask 7 (base 6 +/- 1), so a producer receives 19 for four greens while a
## consumer pays 28. The 9 COIN gap is the merchant's 7 COIN gross spread plus
## the two burned fees. Reopening the same rows every sweep adds no order rows.
func _scenario_merchant_spread() -> void:
	var farm := Farm.new(START)
	_open(farm, PLAYER_A, START)
	_open(farm, PLAYER_D, START)
	var opened: Dictionary = farm.market_open_merchant("merchant-open", START)
	_expect(bool(opened.ok) and int(opened.amount) == 600,
		"The merchant starts with one 600 COIN budget")
	var produced: int = _grow(farm, "field_01", _cells(1, 16), "greens", PLAYER_A, START)
	produced += _grow(farm, "field_02", _cells(1, 4), "greens", PLAYER_A, START)
	_expect(produced == 20, "The merchant-spread fixture produces twenty greens")
	var quote: Dictionary = farm.market_quote("greens")
	_expect(int(quote.bid) == 5 and int(quote.ask) == 7,
		"The greens quote is bid 5 / ask 7 from the 6 COIN reference price")
	_expect(int(quote.buy_capacity) == 52 and int(quote.sell_capacity) == 16,
		"The open merchant can buy 52 with free cash and sell its 16 free greens")
	var start: Dictionary = _balances(farm, [PLAYER_A, PLAYER_D])
	var first_sell: Dictionary = _place(farm, "merchant-player-sell", PLAYER_A, "sell",
		"greens", 5, 4, START)
	_expect(bool(first_sell.ok), "A producer sells four greens into the standing bid")
	_match(farm, START, 1, "merchant buys")
	_expect(farm.economy_cash(PLAYER_A) == 139 and _merchant_credit(farm) == 580,
		"The merchant spends 20 of cash-plus-escrow and the seller nets 19")
	var first_buy: Dictionary = _place(farm, "merchant-player-buy", PLAYER_D, "buy",
		"greens", 7, 4, START)
	_expect(bool(first_buy.ok), "A consumer buys four greens from the standing ask")
	_match(farm, START, 1, "merchant sells")
	_expect(farm.economy_cash(PLAYER_D) == 92 and _merchant_credit(farm) == 607,
		"The buyer pays 28; the merchant keeps 27 before the burned fee")
	_consume(farm, PLAYER_D, "greens", 4)
	var player_before: int = farm.economy_cash(PLAYER_A)
	var buyer_before: int = farm.economy_cash(PLAYER_D)
	var merchant_before_cycles: int = _merchant_credit(farm)
	var issued_before: int = farm.economy_issued()
	for index: int in range(3):
		_place(farm, "merchant-buy-loop-%d" % index, PLAYER_A, "sell", "greens", 5, 4, START)
		_match(farm, START, 1, "merchant round-trip sell %d" % index)
		_place(farm, "merchant-ask-loop-%d" % index, PLAYER_D, "buy", "greens", 7, 4, START)
		_match(farm, START, 1, "merchant round-trip buy %d" % index)
		_consume(farm, PLAYER_D, "greens", 4)
	var player_after: int = farm.economy_cash(PLAYER_A)
	var buyer_after: int = farm.economy_cash(PLAYER_D)
	var merchant_after: int = _merchant_credit(farm)
	var issued_after: int = farm.economy_issued()
	_expect(player_after - player_before == 57,
		"Three producer cycles add 19 COIN each")
	_expect(buyer_after - buyer_before == -84,
		"Three consumer cycles spend 28 COIN each")
	_expect(merchant_after - merchant_before_cycles == 21,
		"The merchant captures 7 COIN per round trip")
	_expect(issued_after - issued_before == -6,
		"Each round trip burns two fees, so six COIN leave the money supply")
	_expect((player_after - player_before) + (buyer_after - buyer_before)
		+ (merchant_after - merchant_before_cycles) == -6,
		"Producer gain plus consumer loss plus merchant gain equals the burned fees")
	_expect(player_after + buyer_after == 204 and merchant_after == 628,
		"Players keep 204 COIN and the merchant holds 288 cash plus 340 escrow")
	_expect(farm.market_orders().size() == 12 + 8,
		"Twelve rolling quote rows plus eight closed player orders, no duplicates")
	_expect_cash(farm, "merchant spread")
	_expect_goods(farm, "greens", produced, 16, "merchant spread")
	_expect_trade_accounting(farm, "merchant spread")
	_record_balances("merchant_spread", start, farm, [PLAYER_A, PLAYER_D])
	_row("SCENARIO merchant_spread good=greens produced=20 consumed=16 volume=32 trades=8 " \
		+ "clearing_bid=5 clearing_ask=7 fees=8 shipping=0 merchant_start=600 merchant_end=628 " \
		+ "player_start=120 player_end=196 buyer_start=120 buyer_end=8 issued=832 total_cash=832 " \
		+ "zero_cost_loop=no negative_balance=no")


## 5b. Freight. The two markets share one order book, so shipping cannot buy at
## a low price in one place and sell at a high price in the other. A one-unit
## round trip restores the goods and loses both 2 COIN fees.
func _scenario_freight() -> void:
	var farm := Farm.new(START)
	_open(farm, PLAYER_A, START)
	_open(farm, PLAYER_D, START)
	var produced: int = _grow(farm, "field_01", _cells(1, 8), "greens", PLAYER_A, START)
	var start: Dictionary = _balances(farm, [PLAYER_A, PLAYER_D])
	var shipped: Dictionary = farm.market_ship("freight-a", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 4, START)
	_expect(bool(shipped.ok) and int(shipped.fee) == 2
		and float(shipped.arrive_utc) == START + Market.DELIVERY_SECONDS,
		"Shipping four greens burns 2 COIN and arrives after 600 seconds")
	_expect(farm.economy_cash(PLAYER_A) == 118 and _goods_total(farm, "greens") == 8,
		"The freight fee leaves cash but not goods")
	_expect(farm.market_place_order("freight-sell", PLAYER_A, "sell", "greens", 6, 5,
		EXPIRY, START).reason == "insufficient_goods",
		"In-transit goods cannot be sold before they arrive")
	_expect(int(farm.market_deliver(START + Market.DELIVERY_SECONDS - 1.0).count) == 0,
		"Arrival one second early delivers nothing")
	_expect(int(farm.market_deliver(START + Market.DELIVERY_SECONDS).count) == 1,
		"Arrival at 600 seconds delivers the shipment")
	_expect(_bag_amount(farm, PLAYER_A, "greens") == 8,
		"Delivered goods return to the owner's bag")
	var delivered_at: float = START + Market.DELIVERY_SECONDS
	_place(farm, "freight-sell-now", PLAYER_A, "sell", "greens", 6, 8, delivered_at)
	_place(farm, "freight-buy-d", PLAYER_D, "buy", "greens", 6, 8, delivered_at)
	_match(farm, delivered_at, 1, "freight sale")
	_consume(farm, PLAYER_D, "greens", 8)
	_expect(farm.economy_cash(PLAYER_A) == 165,
		"The shipped seller ends at 120 - 2 freight + 47 trade proceeds")
	_expect_cash(farm, "freight")
	_expect_goods(farm, "greens", produced, 8, "freight")
	_expect(Market.route(Market.LOCATION_FARM, Market.LOCATION_HARBOR).fee
		== Market.route(Market.LOCATION_HARBOR, Market.LOCATION_FARM).fee,
		"The route is symmetric, so freight cannot price direction")
	_expect(farm.market_routes().size() == 2 and farm.market_quote("greens").has("bid"),
		"One global quote and one order book serve both market ids")
	_record_balances("freight", start, farm, [PLAYER_A, PLAYER_D])
	_row("SCENARIO freight good=greens produced=8 consumed=8 volume=8 trades=1 " \
		+ "price=6 fees=1 shipping=2 issued=237 total_cash=237 transit_end=0 " \
		+ "zero_cost_loop=no negative_balance=no")

	var loop := Farm.new(START)
	_open(loop, PLAYER_A, START)
	_grow(loop, "field_01", _cells(1, 8), "greens", PLAYER_A, START)
	var before: int = loop.economy_cash(PLAYER_A)
	loop.market_ship("freight-loop-out", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 1, START)
	loop.market_deliver(START + Market.DELIVERY_SECONDS)
	loop.market_ship("freight-loop-back", PLAYER_A, Market.LOCATION_HARBOR,
		Market.LOCATION_FARM, "greens", 1, START + Market.DELIVERY_SECONDS)
	loop.market_deliver(START + 2.0 * Market.DELIVERY_SECONDS)
	_expect(loop.economy_cash(PLAYER_A) == before - 4 and _bag_amount(loop, PLAYER_A, "greens") == 8,
		"A one-unit round trip restores the goods and loses both 2 COIN fees")
	_expect_cash(loop, "freight loop")
	_row("SCENARIO freight_loop good=greens quantity=1 out_fee=2 back_fee=2 profit=-4 " \
		+ "goods_delta=0 issued_delta=-4 zero_cost_loop=no negative_balance=no")


## 5c. Player-to-player round trip. Each full cycle costs each side one fee and
## burns two; a self-trade moves the goods back to the same owner and still
## burns one fee.
func _scenario_player_round_trip() -> void:
	var farm := Farm.new(START)
	_open(farm, PLAYER_A, START)
	_open(farm, PLAYER_B, START)
	var produced: int = _grow(farm, "field_01", _cells(1, 8), "greens", PLAYER_A, START)
	produced += _grow(farm, "field_02", _cells(1, 8), "greens", PLAYER_B, START)
	var start: Dictionary = _balances(farm, [PLAYER_A, PLAYER_B])
	for index: int in range(3):
		_place(farm, "round-a-sell-%d" % index, PLAYER_A, "sell", "greens", 6, 1, START)
		_place(farm, "round-b-buy-%d" % index, PLAYER_B, "buy", "greens", 6, 1, START)
		_match(farm, START, 1, "A-to-B round %d" % index)
		_place(farm, "round-b-sell-%d" % index, PLAYER_B, "sell", "greens", 6, 1, START)
		_place(farm, "round-a-buy-%d" % index, PLAYER_A, "buy", "greens", 6, 1, START)
		_match(farm, START, 1, "B-to-A round %d" % index)
	_expect(farm.economy_cash(PLAYER_A) == 117 and farm.economy_cash(PLAYER_B) == 117,
		"Each player loses one fee per full cycle")
	_expect(farm.economy_issued() == 234,
		"Six player-to-player trades burn six COIN")
	_expect_cash(farm, "player round trip")
	_expect_goods(farm, "greens", produced, 0, "player round trip")
	_expect_trade_accounting(farm, "player round trip")
	_record_balances("player_round_trip", start, farm, [PLAYER_A, PLAYER_B])
	_row("SCENARIO player_round_trip good=greens produced=16 consumed=0 volume=6 trades=6 " \
		+ "price=6 fees=6 shipping=0 player_a_start=120 player_a_end=117 " \
		+ "player_b_start=120 player_b_end=117 issued=234 total_cash=234 " \
		+ "zero_cost_loop=no negative_balance=no")

	var self_trade := Farm.new(START)
	_open(self_trade, PLAYER_A, START)
	_grow(self_trade, "field_01", _cells(1, 1), "greens", PLAYER_A, START)
	_place(self_trade, "self-sell", PLAYER_A, "sell", "greens", 6, 1, START)
	_place(self_trade, "self-buy", PLAYER_A, "buy", "greens", 6, 1, START)
	_match(self_trade, START, 1, "self-trade")
	_expect(self_trade.economy_cash(PLAYER_A) == 119
		and _bag_amount(self_trade, PLAYER_A, "greens") == 1,
		"A self-trade restores the goods and loses one fee")
	_expect_cash(self_trade, "self-trade")
	_row("SCENARIO self_trade good=greens produced=1 consumed=0 volume=1 trades=1 " \
		+ "price=6 fees=1 shipping=0 cash_delta=-1 goods_delta=0 issued=119 total_cash=119 " \
		+ "zero_cost_loop=no negative_balance=no")


## 6. Market off and self-sufficiency. Farming, harvesting and the kitchen's eat
## route work with no merchant, no orders, no cash and no AI process. The
## kitchen consumes the shared inventory, not a player bag; this is the existing
## eat route and the reason the experiment models resident consumption outside
## the market rules.
func _scenario_self_sufficiency() -> void:
	var farm := Farm.new(START)
	var produced: int = _grow(farm, "field_01", _cells(1, 8), "greens", PLAYER_A, START)
	_expect(produced == 8 and _bag_amount(farm, PLAYER_A, "greens") == 8,
		"A player with no account still grows and keeps eight greens")
	_expect(farm.economy_issued() == 0 and farm.economy_total_cash() == 0,
		"No market participation means no issued or held cash")
	_expect(farm.market_orders().is_empty() and not bool(farm.market_merchant().opened),
		"No merchant or order appears without an explicit command")
	var before: Dictionary = farm.snapshot()
	_expect(int(farm.market_match(START).count) == 0
		and int(farm.market_expire(EXPIRY).expired) == 0
		and int(farm.market_deliver(EXPIRY).count) == 0,
		"Market sweeps have no work when the market was never opened")
	_expect(farm.snapshot() == before,
		"Farming is unchanged by empty market sweeps")
	_expect_cash(farm, "self-sufficiency")
	_expect_goods(farm, "greens", produced, 0, "self-sufficiency")
	_row("SCENARIO market_off good=greens produced=8 consumed=0 volume=0 trades=0 fees=0 " \
		+ "issued=0 total_cash=0 pockets_end=8 merchant=closed orders=0 " \
		+ "zero_cost_loop=no negative_balance=no")

	var kitchen := Farm.new(START)
	_expect(bool(kitchen.sow("field_01", "cell_01", "greens", START, "").ok),
		"Anonymous work grows food for the shared kitchen")
	kitchen.mature_all_crops(START)
	_expect(bool(kitchen.harvest("field_01", "cell_01", START, "").ok),
		"Anonymous harvest feeds the shared inventory")
	_expect(int(kitchen.snapshot().inventory["greens"]) == 1,
		"The kitchen has one green with no market involved")
	var revision: int = int(kitchen.snapshot().kitchen.revision)
	var started: Dictionary = kitchen.kitchen_action("start",
		{"recipe": "leaf_stir", "crop": "greens"}, revision, START)
	_expect(bool(started.ok), "The eat route starts without cash or orders")
	revision = int(kitchen.snapshot().kitchen.revision)
	var collected: Dictionary = kitchen.kitchen_action("collect", {"station": "stove"},
		revision, START + 20.0)
	_expect(bool(collected.ok), "The meal completes after its clock, not after a market command")
	_expect(int(kitchen.snapshot().kitchen.stock["leaf_stir"]) == 1
		and int(kitchen.snapshot().inventory["greens"]) == 0,
		"The kitchen consumes the green and keeps one dish")
	_expect(kitchen.economy_issued() == 0 and kitchen.economy_total_cash() == 0,
		"Eating without the market never touches cash")
	_row("SCENARIO self_sufficient_meal good=greens produced=1 consumed=1 meals=1 " \
		+ "issued=0 total_cash=0 market_commands=0 zero_cost_loop=no negative_balance=no")


## 7. Order-table capacity. Closed rows are archival evidence, so a long-lived
## world does not stay at the 256-row bound forever: the earliest closed row is
## evicted and the new order is accepted. A table of open rows still returns
## `order_limit` because their escrow is live (covered by the archive test).
func _scenario_order_cap() -> void:
	var farm := Farm.new(START)
	_open(farm, PLAYER_A, START)
	var pairs: int = Market.MAX_ORDERS
	for index: int in range(pairs):
		var placed: Dictionary = farm.market_place_order("cap-place-%03d" % index, PLAYER_A,
			"buy", "greens", 1, 1, EXPIRY, START)
		_expect(bool(placed.ok), "Order %d fits below the 256-order cap" % index)
		var cancelled: Dictionary = farm.market_cancel_order("cap-cancel-%03d" % index,
			PLAYER_A, "cap-place-%03d" % index, START)
		_expect(bool(cancelled.ok), "Order %d cancels and returns its escrow" % index)
	_expect(farm.market_orders().size() == Market.MAX_ORDERS,
		"Closed orders remain in the table and fill the 256 slots")
	var accepted: Dictionary = farm.market_place_order("cap-over", PLAYER_A, "buy", "greens",
		1, 1, EXPIRY, START)
	_expect(bool(accepted.ok) and int(farm.market_snapshot().archived_orders) == 1,
		"The 257th lifetime order archives the earliest closed row and is accepted")
	_expect(farm.market_order("cap-place-000").is_empty()
		and farm.market_order("cap-over").status == Market.STATUS_OPEN,
		"The earliest closed row is evicted and the new order is open")
	_expect(farm.economy_cash(PLAYER_A) == 119 and farm.economy_issued() == 120,
		"Archiving returns no cash and issues none")
	_expect_cash(farm, "order archive")
	_row("SCENARIO order_cap good=greens lifetime_orders=257 closed_orders=256 " \
		+ "next_order=accepted archived_orders=1 cash=119 issued=120 total_cash=120 fees=0 " \
		+ "zero_cost_loop=no negative_balance=no")


## 8. Repeated cycles with a one-time grant. A resident can buy 12 units, then
## 8, then nothing: there is no recurring income in the current rules, so
## synthetic periodic demand stops when the opening grant is spent. Producers
## keep their unsold baskets; no fee is charged without a fill.
func _scenario_repeated_cycles() -> void:
	var farm := Farm.new(START)
	for owner: String in [PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D]:
		_open(farm, owner, START)
	var produced: int = 0
	var consumed: int = 0
	var volume: int = 0
	var fees: int = 0
	for round_index: int in range(3):
		var now: float = START + float(round_index) * HOUR
		produced += _grow(farm, "field_01", _cells(1, 8), "greens", PLAYER_A, now)
		produced += _grow(farm, "field_02", _cells(1, 8), "greens", PLAYER_B, now)
		produced += _grow(farm, "field_01", _cells(9, 16), "greens", PLAYER_C, now)
		_place(farm, "cycle-sell-a-%d" % round_index, PLAYER_A, "sell", "greens", 6, 8, now)
		_place(farm, "cycle-sell-b-%d" % round_index, PLAYER_B, "sell", "greens", 6, 8, now)
		_place(farm, "cycle-sell-c-%d" % round_index, PLAYER_C, "sell", "greens", 6, 8, now)
		var demand: int = 12 if round_index == 0 else (8 if round_index == 1 else 0)
		if demand > 0:
			_place(farm, "cycle-buy-d-%d" % round_index, PLAYER_D, "buy", "greens", 6, demand, now)
		var round_trades: int = 2 if round_index == 0 else (1 if round_index == 1 else 0)
		var matched: Dictionary = _match(farm, now, round_trades, "cycle %d" % round_index)
		volume += demand
		consumed += demand
		fees += int(matched.fee)
		if demand > 0:
			_consume(farm, PLAYER_D, "greens", demand)
		var expired: Dictionary = farm.market_expire(now + 6.0 * HOUR)
		_expect_cash(farm, "cycle %d" % round_index)
		_row("CYCLE round=%d produced_total=%d consumed_total=%d volume_total=%d " \
			% [round_index, produced, consumed, volume]
			+ "fees_total=%d demand=%d buyer_cash=%d expired=%d" % [
				fees, demand, farm.economy_cash(PLAYER_D), int(expired.expired)])
	var no_funds: Dictionary = farm.market_place_order("cycle-buy-over", PLAYER_D, "buy",
		"greens", 6, 12, START + 9.0 * HOUR, START + 3.0 * HOUR)
	_expect(not bool(no_funds.ok) and str(no_funds.reason) == "insufficient_cash",
		"After the one-time grant is spent, the resident cannot keep buying")
	_expect(farm.economy_cash(PLAYER_D) == 0,
		"The resident's cash reaches zero and never goes negative")
	_expect(produced == 72 and consumed == 20 and volume == 20,
		"Three production cycles produce 72 but only 20 units find synthetic demand")
	_expect(_fees(farm) == fees, "Cycle fees match the run total")
	_expect_cash(farm, "repeated cycles")
	_expect_goods(farm, "greens", produced, consumed, "repeated cycles")
	_expect_trade_accounting(farm, "repeated cycles")
	_row("SCENARIO repeated_cycles good=greens rounds=3 produced=72 consumed=20 volume=20 " \
		+ "trades=3 fees=3 shipping=0 issued=477 total_cash=477 buyer_cash_end=0 " \
		+ "unsold=52 demand_stopped=opening_grant_spent zero_cost_loop=no negative_balance=no")


func _open(farm: Farm, owner: String, now: float) -> void:
	var result: Dictionary = farm.economy_open_account("open-" + owner, owner, now)
	_expect(bool(result.ok) and int(result.amount) == 120,
		"Opening the account grants the one-time 120 COIN: " + owner)


func _grow(farm: Farm, field_id: String, cells: Array[String], good_id: String,
		actor: String, now: float) -> int:
	for cell_id: String in cells:
		var sown: Dictionary = farm.sow(field_id, cell_id, good_id, now, actor)
		_expect(bool(sown.ok), "Sowing %s on %s/%s" % [good_id, field_id, cell_id])
	farm.mature_all_crops(now)
	var produced: int = 0
	for cell_id: String in cells:
		var harvested: Dictionary = farm.harvest(field_id, cell_id, now, actor)
		if bool(harvested.ok):
			produced += 1
		else:
			_expect(false, "Harvesting %s/%s: %s" % [field_id, cell_id, str(harvested.reason)])
	return produced


func _place(farm: Farm, order_id: String, owner: String, side: String, good_id: String,
		price: int, quantity: int, now: float) -> Dictionary:
	var result: Dictionary = farm.market_place_order(order_id, owner, side, good_id, price,
		quantity, now + 6.0 * HOUR, now)
	_expect(bool(result.ok), "Placing %s %s %s @%d x%d: %s" % [
		owner, side, good_id, price, quantity, str(result.reason)])
	return result


func _match(farm: Farm, now: float, expected_count: int, label: String) -> Dictionary:
	var result: Dictionary = farm.market_match(now)
	_expect(bool(result.ok) and int(result.count) == expected_count,
		"%s: expected %d trades, got %d (%s)" % [
			label, expected_count, int(result.get("count", 0)), str(result.get("reason", ""))])
	return result


func _consume(farm: Farm, owner: String, good_id: String, quantity: int) -> void:
	# The experiment's synthetic consumption step. There is no player-bag eat
	# route in this slice, so the harness removes the purchased baskets from the
	# bag after settlement and counts them as consumed. No game rule is bypassed:
	# the snapshot is re-admitted through the public restore boundary.
	var snapshot: Dictionary = farm.snapshot()
	var bags: Dictionary = snapshot.bags
	var bag: Dictionary = bags.get(owner, {})
	_expect(int(bag.get(good_id, 0)) >= quantity,
		"Consumer %s has %d %s to consume" % [owner, quantity, good_id])
	bag[good_id] = int(bag.get(good_id, 0)) - quantity
	bags[owner] = bag
	snapshot.bags = bags
	_expect(farm.restore_snapshot(snapshot),
		"The synthetic consumption snapshot is valid and restores")


func _bag_amount(farm: Farm, owner: String, good_id: String) -> int:
	return int(farm.bag(owner).get(good_id, 0))


func _balances(farm: Farm, owners: Array) -> Dictionary:
	var result: Dictionary = {}
	for owner: String in owners:
		result[owner] = farm.economy_cash(owner)
	return result


func _record_balances(label: String, start: Dictionary, farm: Farm, owners: Array) -> void:
	for owner: String in owners:
		var first: int = int(start.get(owner, 0))
		var last: int = farm.economy_cash(owner)
		_row("BALANCE %s owner=%s start=%d end=%d delta=%d" % [
			label, owner, first, last, last - first])


func _fees(farm: Farm) -> int:
	var total: int = 0
	for trade: Dictionary in farm.market_trades():
		total += int(trade.fee)
	return total


func _merchant_credit(farm: Farm) -> int:
	return int(farm.market_merchant().get("cash", 0)) \
		+ int(farm.economy_funds(MERCHANT).get("frozen", 0))


func _goods_total(farm: Farm, good_id: String) -> int:
	var snapshot: Dictionary = farm.snapshot()
	var total: int = 0
	for stored: Variant in snapshot.bags.values():
		if stored is Dictionary:
			total += int(stored.get(good_id, 0))
	var merchant: Dictionary = farm.market_merchant()
	if merchant.get("goods") is Dictionary:
		total += int(merchant.goods.get(good_id, 0))
	for order: Dictionary in farm.market_orders():
		if str(order.get("side", "")) == "sell" and str(order.get("good", "")) == good_id \
				and str(order.get("status", "")) == Market.STATUS_OPEN:
			total += int(order.get("reserved", 0))
	for shipment: Dictionary in farm.market_shipments():
		if str(shipment.get("status", "")) == Market.SHIPMENT_STATUS_TRANSIT:
			total += int(shipment.get("quantity", 0))
	return total


func _expect_cash(farm: Farm, label: String) -> void:
	var total: int = farm.economy_total_cash()
	var issued: int = farm.economy_issued()
	_expect(total == issued, "%s: total_cash %d != issued %d" % [label, total, issued])
	_expect(issued >= 0, "%s: issued is nonnegative" % label)
	var snapshot: Dictionary = farm.snapshot()
	var economy: Dictionary = snapshot.economy
	for owner: Variant in economy.accounts:
		_expect(int(economy.accounts[owner].cash) >= 0,
			"%s: account %s is nonnegative" % [label, str(owner)])
	_expect(int(farm.market_merchant().get("cash", 0)) >= 0,
		"%s: merchant cash is nonnegative" % label)
	_expect(Market.valid(economy), "%s: economy stays structurally valid" % label)


func _expect_goods(farm: Farm, good_id: String, produced: int, consumed: int,
		label: String) -> void:
	var total: int = _goods_total(farm, good_id)
	# The merchant's one-time stock grant is real production for this identity:
	# produced + granted == pockets + merchant stock + sell escrow + transit +
	# consumed.
	var granted: int = int(Market.merchant_granted(farm.economy_snapshot()).get(good_id, 0))
	_expect(total == produced + granted - consumed,
		"%s: pockets+merchant+escrow+transit %d != produced %d + granted %d - consumed %d" % [
			label, total, produced, granted, consumed])
	_expect(total >= 0, "%s: goods never become negative" % label)


func _expect_trade_accounting(farm: Farm, label: String) -> void:
	for trade: Dictionary in farm.market_trades():
		var price: int = int(trade.price)
		var quantity: int = int(trade.quantity)
		var notional: int = int(trade.notional)
		var fee: int = int(trade.fee)
		_expect(notional == price * quantity,
			"%s: trade notional is price x quantity" % label)
		_expect(fee == mini(Market.TRADE_FEE, notional),
			"%s: trade fee is the fixed 1 COIN (capped by notional)" % label)
		_expect(int(trade.sell_credit) + fee == notional,
			"%s: seller credit plus burned fee equals notional" % label)
		_expect(int(trade.buy_refund) == (int(trade.buy_price) - price) * quantity,
			"%s: buyer receives exactly the limit-minus-fill refund" % label)
		_expect(price >= int(trade.sell_price) and price <= int(trade.buy_price),
			"%s: the fill price sits inside both limits" % label)


func _cells(first: int, last: int) -> Array[String]:
	var result: Array[String] = []
	for index: int in range(first, last + 1):
		result.append("cell_%02d" % index)
	return result


func _row(line: String) -> void:
	rows.append(line)
	print(line)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
