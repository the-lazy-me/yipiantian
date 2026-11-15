extends SceneTree
## M7-07 merchant liquidity. Headless and isolated: no scene, system clock or
## player save is touched, and only the public FarmState/Market/Economy rules
## are driven. The merchant is a real counterparty: a one-time stock grant plus
## one rolling bid and ask per catalog good, reopened on the same durable rows.
##
## Every scenario checks `total_cash == issued` and the goods identity
## produced + merchant grant == pockets + merchant stock + sell escrow + transit.

const Farm = preload("res://farm/farm_state.gd")
const Market = preload("res://farm/market_state.gd")
const Catalog = preload("res://farm/economy_catalog.gd")

const START: float = 1800000000.0
const HOUR: float = 3600.0
const PLAYER_A: String = "player_merchant_liquidity_0001"
const PLAYER_B: String = "player_merchant_liquidity_0002"
const PLAYER_C: String = "player_merchant_liquidity_0003"
const PLAYER_D: String = "player_merchant_liquidity_0004"
const MERCHANT: String = "@merchant"

var checks: int = 0
var failures: Array[String] = []
var test_root: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/merchant-liquidity-%d" % OS.get_process_id()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_grant_and_rolling_quotes()
	_test_player_trades()
	_test_repeat_open_and_reopen()
	_test_cash_exhaustion_and_recovery()
	_test_stock_exhaustion_and_recovery()
	_test_determinism_and_references()
	_test_legacy_market()
	_test_opened_legacy_grant()
	_test_sweep_persists_reopened_quotes()
	for failure: String in failures:
		push_error(failure)
	print("MERCHANT_LIQUIDITY_TEST checks=%d failures=%d root=%s" % [
		checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


## 1. Opening grants exactly 20 units per good and posts the 12 rolling rows.
func _test_grant_and_rolling_quotes() -> void:
	var farm := Farm.new(START)
	_open(farm, PLAYER_A, START)
	_expect(bool(farm.market_open_merchant("open-merchant", START).ok),
		"The merchant opens once")
	var economy: Dictionary = farm.economy_snapshot()
	var merchant: Dictionary = farm.market_merchant()
	var granted: Dictionary = Market.merchant_granted(economy)
	var bid_escrow: int = 0
	for good_id: String in Catalog.goods_ids():
		var base: int = Catalog.base_price(good_id)
		var bid_price: int = maxi(1, base - 1)
		var ask_price: int = base + 1
		_expect(int(granted.get(good_id, 0)) == Market.MERCHANT_GRANT_PER_GOOD,
			"The one-time grant records 20 %s" % good_id)
		_expect(int(merchant.goods.get(good_id, 0)) == 16,
			"Four units of %s are escrowed in the ask" % good_id)
		var bid: Dictionary = farm.market_order(Market.merchant_quote_id(good_id, Market.SIDE_BUY))
		var ask: Dictionary = farm.market_order(Market.merchant_quote_id(good_id, Market.SIDE_SELL))
		_expect(not bid.is_empty() and str(bid.owner) == MERCHANT
			and str(bid.side) == Market.SIDE_BUY and str(bid.good) == good_id
			and str(bid.status) == Market.STATUS_OPEN,
			"%s has one open merchant bid row" % good_id)
		_expect(int(bid.price) == bid_price and int(bid.quantity) == 4
			and int(bid.remaining) == 4 and int(bid.reserved) == bid_price * 4,
			"The %s bid is base-1 with four units escrowed" % good_id)
		_expect(not ask.is_empty() and str(ask.owner) == MERCHANT
			and str(ask.side) == Market.SIDE_SELL and str(ask.good) == good_id
			and str(ask.status) == Market.STATUS_OPEN,
			"%s has one open merchant ask row" % good_id)
		_expect(int(ask.price) == ask_price and int(ask.quantity) == 4
			and int(ask.remaining) == 4 and int(ask.reserved) == 4,
			"The %s ask is base+1 with four units escrowed" % good_id)
		bid_escrow += bid_price * 4
	_expect(bid_escrow == 340, "The six rolling bids escrow 340 COIN")
	_expect(int(merchant.cash) == 600 - bid_escrow,
		"Merchant free cash is the budget minus the bid escrow")
	_expect(farm.economy_funds(MERCHANT).frozen == bid_escrow,
		"The funds view reports the merchant's escrow")
	_expect(_merchant_row_count(farm) == 12 and farm.market_orders().size() == 12,
		"Six bids and six asks are the only merchant rows")
	_expect(farm.economy_total_cash() == farm.economy_issued(),
		"Granting goods does not change the cash identity")
	_expect(Market.valid(economy), "The opened market validates")

	# A second opening id is refused and changes neither grant nor rows.
	var accepted: Dictionary = farm.snapshot()
	var second: Dictionary = farm.market_open_merchant("open-merchant-2", START)
	_expect(not bool(second.ok) and str(second.reason) == "already_opened"
		and farm.snapshot() == accepted,
		"A second opening is refused without granting or quoting again")
	var still_granted: Dictionary = Market.merchant_granted(farm.economy_snapshot())
	for good_id: String in Catalog.goods_ids():
		_expect(int(still_granted[good_id]) == Market.MERCHANT_GRANT_PER_GOOD,
			"The %s grant is one-time" % good_id)
	_expect(_merchant_row_count(farm) == 12, "The second opening adds no row")


## 2. A player sells into the bid and a player buys from the ask.
func _test_player_trades() -> void:
	var farm := Farm.new(START)
	_open(farm, PLAYER_A, START)
	_open(farm, PLAYER_D, START)
	_expect(bool(farm.market_open_merchant("open-merchant", START).ok),
		"The merchant opens for player trades")
	var produced: Dictionary = {}
	produced["greens"] = _grow(farm, "field_01", _cells(1, 8), "greens", PLAYER_A, START)
	_expect(int(produced.greens) == 8, "The fixture produces eight greens")

	var sell: Dictionary = farm.market_place_order("sell-to-merchant", PLAYER_A, "sell",
		"greens", 5, 4, START + HOUR, START)
	_expect(bool(sell.ok), "A places a sell order into the merchant bid")
	var first: Dictionary = farm.market_match(START)
	_expect(first.ok and int(first.count) == 1, "The merchant bid fills four greens")
	var trade_one: Dictionary = farm.market_trade("trade_1")
	_expect(str(trade_one.buy_owner) == MERCHANT and str(trade_one.sell_owner) == PLAYER_A
		and int(trade_one.price) == 5 and int(trade_one.quantity) == 4
		and str(trade_one.buy_id) == Market.merchant_quote_id("greens", Market.SIDE_BUY),
		"The first trade is against the stable merchant bid at the bid price")
	_expect(farm.economy_cash(PLAYER_A) == 139,
		"The seller receives 19 after the fee")
	_expect(int(farm.market_merchant().cash) == 260
		and int(farm.market_merchant().goods.greens) == 20,
		"The merchant pays from escrow and receives four greens")

	var buy: Dictionary = farm.market_place_order("buy-from-merchant", PLAYER_D, "buy",
		"greens", 7, 4, START + HOUR, START)
	_expect(bool(buy.ok), "A consumer buys from the merchant ask")
	var second: Dictionary = farm.market_match(START)
	_expect(second.ok and int(second.count) == 1, "The merchant ask fills four greens")
	var trade_two: Dictionary = farm.market_trade("trade_2")
	_expect(str(trade_two.sell_owner) == MERCHANT and str(trade_two.buy_owner) == PLAYER_D
		and int(trade_two.price) == 7 and int(trade_two.quantity) == 4
		and str(trade_two.sell_id) == Market.merchant_quote_id("greens", Market.SIDE_SELL),
		"The second trade is against the stable merchant ask at the ask price")
	_expect(farm.economy_cash(PLAYER_D) == 92,
		"The buyer pays 28 and receives four greens")
	_expect(int(farm.market_merchant().cash) == 267
		and int(farm.market_merchant().goods.greens) == 20,
		"The merchant earns 27 and its granted stock returns to 20")
	_expect(_bag(farm, PLAYER_A, "greens") == 4 and _bag(farm, PLAYER_D, "greens") == 4,
		"Both players hold the settled baskets")
	_expect_conservation(farm, produced, "player trades")
	_expect(Market.valid(farm.economy_snapshot()),
		"Trades against merchant rows keep the market snapshot valid")


## 3. Repeated scans and cycles reuse the same 12 rows.
func _test_repeat_open_and_reopen() -> void:
	var farm := Farm.new(START)
	_open(farm, PLAYER_A, START)
	_open(farm, PLAYER_D, START)
	_expect(bool(farm.market_open_merchant("open-merchant", START).ok),
		"The repeat fixture opens the merchant")
	var produced: Dictionary = {}
	produced["greens"] = _grow(farm, "field_01", _cells(1, 16), "greens", PLAYER_A, START)
	var opened: Dictionary = farm.snapshot()
	var opened_market: Dictionary = farm.market_snapshot()
	_expect(int(farm.market_match(START).count) == 0 and farm.snapshot() == opened,
		"A sweep with no crossing orders changes nothing")
	_expect(int(farm.market_match(START, "settle-noop").count) == 0
		and farm.market_snapshot() == opened_market,
		"A command-bound no-fill sweep leaves the rolling rows untouched")
	_expect(_merchant_row_count(farm) == 12, "The repeated sweeps add no merchant row")

	for index: int in range(3):
		_place(farm, "cycle-sell-%d" % index, PLAYER_A, "sell", "greens", 5, 4, START)
		_expect(int(farm.market_match(START).count) == 1,
			"Cycle %d sells into the merchant bid" % index)
		_place(farm, "cycle-buy-%d" % index, PLAYER_D, "buy", "greens", 7, 4, START)
		_expect(int(farm.market_match(START).count) == 1,
			"Cycle %d buys from the merchant ask" % index)
		_expect(_merchant_row_count(farm) == 12,
			"Cycle %d keeps the merchant at 12 rows" % index)
	_expect(farm.market_orders().size() == 12 + 6,
		"Three cycles add six closed player rows and no merchant duplicate")
	_expect_conservation(farm, produced, "repeated cycles")


## 4. The buy side stops when free cash cannot fund a four-unit bid and
## recovers after an ask fill returns cash.
func _test_cash_exhaustion_and_recovery() -> void:
	var farm := Farm.new(START)
	_open(farm, PLAYER_A, START)
	_open(farm, PLAYER_D, START)
	_expect(bool(farm.market_open_merchant("open-merchant", START).ok),
		"The cash fixture opens the merchant")
	var produced: Dictionary = {}
	produced["carrot"] = _grow(farm, "field_01", _cells(1, 16), "carrot", PLAYER_A, START)
	_expect(int(produced.carrot) == 16, "The cash fixture grows sixteen carrots")
	var bid_id: String = Market.merchant_quote_id("carrot", Market.SIDE_BUY)
	var ask_id: String = Market.merchant_quote_id("carrot", Market.SIDE_SELL)
	_expect(int(farm.market_order(bid_id).price) == 23
		and int(farm.market_order(ask_id).price) == 25,
		"Carrot quotes are bid 23 / ask 25")
	_expect(int(farm.market_merchant().cash) == 260,
		"Carrot bid escrow is already part of the 340 COIN frozen total")

	# Three full bid cycles take 92 COIN each from free cash: 260 -> 168 -> 76.
	for index: int in range(3):
		_place(farm, "cash-sell-%d" % index, PLAYER_A, "sell", "carrot", 23, 4, START)
		_expect(int(farm.market_match(START).count) == 1,
			"Carrot bid cycle %d fills" % index)
	_expect(int(farm.market_merchant().cash) == 76,
		"Three carrot bid cycles leave 76 free COIN")
	_expect(int(farm.market_quote("carrot").buy_capacity) == 3,
		"The remaining 76 COIN cannot fund the fixed four-unit bid")
	_place(farm, "cash-sell-over", PLAYER_A, "sell", "carrot", 23, 4, START)
	_expect(int(farm.market_match(START).count) == 0,
		"The buy side does not replenish without four units of cash")
	_expect(str(farm.market_order(bid_id).status) != Market.STATUS_OPEN,
		"The exhausted carrot bid stays closed")
	_expect(_merchant_row_count(farm) == 12, "Exhaustion does not add a row")
	# Remove the unmatched player ask so the recovery buy cannot trade with it.
	var cancelled_over: Dictionary = farm.market_cancel_order("cash-cancel-over", PLAYER_A,
		"cash-sell-over", START + 1.0)
	_expect(bool(cancelled_over.ok), "The unmatched carrot ask is cancelled")

	# An ask fill returns cash; the next sweep reopens the same bid id.
	_place(farm, "cash-recover-buy", PLAYER_D, "buy", "carrot", 25, 4, START)
	_expect(int(farm.market_match(START).count) == 1,
		"The merchant ask fills and returns 99 COIN")
	_expect(int(farm.market_merchant().cash) == 175,
		"The ask fill raises merchant free cash above one bid")
	_expect(int(farm.market_match(START, "cash-recover").count) == 0,
		"The next sweeping scan only maintains quotes")
	var reopened: Dictionary = farm.market_order(bid_id)
	_expect(str(reopened.status) == Market.STATUS_OPEN
		and int(reopened.reserved) == 23 * 4
		and int(reopened.sequence) > 0,
		"The same carrot bid id reopens with a refreshed escrow")
	_expect(int(farm.market_merchant().cash) == 175 - 23 * 4,
		"Reopening the bid takes 92 COIN of free cash")
	_expect(_merchant_row_count(farm) == 12, "Recovery reuses the twelve rows")
	_expect_conservation(farm, produced, "cash exhaustion")


## 5. The sell side stops when stock cannot fund a four-unit ask and recovers
## after a bid fill returns stock.
func _test_stock_exhaustion_and_recovery() -> void:
	var farm := Farm.new(START)
	_open(farm, PLAYER_A, START)
	_open(farm, PLAYER_D, START)
	_open(farm, PLAYER_C, START)
	_expect(bool(farm.market_open_merchant("open-merchant", START).ok),
		"The stock fixture opens the merchant")
	var produced: Dictionary = {}
	produced["greens"] = _grow(farm, "field_01", _cells(1, 8), "greens", PLAYER_A, START)
	_expect(int(produced.greens) == 8, "The stock fixture grows eight greens")
	var ask_id: String = Market.merchant_quote_id("greens", Market.SIDE_SELL)
	var bid_id: String = Market.merchant_quote_id("greens", Market.SIDE_BUY)

	# The grant sells 20 units in five four-unit fills: D buys four cycles and C
	# buys the last one, because each opening player only holds 120 COIN.
	for index: int in range(4):
		_place(farm, "stock-buy-d-%d" % index, PLAYER_D, "buy", "greens", 7, 4, START)
		_expect(int(farm.market_match(START).count) == 1,
			"Green ask cycle %d fills" % index)
	_place(farm, "stock-buy-c", PLAYER_C, "buy", "greens", 7, 4, START)
	_expect(int(farm.market_match(START).count) == 1,
		"The fifth green ask cycle fills")
	_expect(int(farm.market_merchant().goods.greens) == 0,
		"The merchant has no free greens left")
	_place(farm, "stock-buy-over", PLAYER_C, "buy", "greens", 7, 4, START)
	_expect(int(farm.market_match(START).count) == 0,
		"The sell side does not replenish without four units of stock")
	_expect(str(farm.market_order(ask_id).status) != Market.STATUS_OPEN,
		"The exhausted green ask stays closed")
	_expect(_merchant_row_count(farm) == 12, "Stock exhaustion does not add a row")
	# Remove the unmatched buy so the recovery sell can only hit the merchant bid.
	var cancelled_buy: Dictionary = farm.market_cancel_order("stock-cancel-over", PLAYER_C,
		"stock-buy-over", START + 1.0)
	_expect(bool(cancelled_buy.ok), "The unmatched green buy is cancelled")

	# A bid fill returns four greens; the same ask id reopens.
	_place(farm, "stock-recover-sell", PLAYER_A, "sell", "greens", 5, 4, START)
	_expect(int(farm.market_match(START).count) == 1,
		"The merchant bid buys four greens back")
	_expect(int(farm.market_match(START, "stock-recover").count) == 0,
		"The next sweeping scan only maintains quotes")
	var reopened: Dictionary = farm.market_order(ask_id)
	_expect(str(reopened.status) == Market.STATUS_OPEN
		and int(reopened.reserved) == 4,
		"The same green ask id reopens with four escrowed units")
	_expect(int(farm.market_merchant().goods.greens) == 0,
		"The reopened ask escrows the four returned greens")
	_expect(_merchant_row_count(farm) == 12, "Stock recovery reuses the twelve rows")
	_expect_conservation(farm, produced, "stock exhaustion")


## 6. Two copies of one snapshot produce the same scan, and trade references
## still validate after merchant fills.
func _test_determinism_and_references() -> void:
	var source := Farm.new(START)
	_open(source, PLAYER_A, START)
	_open(source, PLAYER_D, START)
	_expect(bool(source.market_open_merchant("open-merchant", START).ok),
		"The determinism fixture opens the merchant")
	var produced: Dictionary = {}
	produced["greens"] = _grow(source, "field_01", _cells(1, 8), "greens", PLAYER_A, START)
	_place(source, "det-sell", PLAYER_A, "sell", "greens", 5, 4, START)
	_place(source, "det-buy", PLAYER_D, "buy", "greens", 7, 4, START)
	var base: Dictionary = source.snapshot()

	var first := Farm.new()
	var second := Farm.new()
	_expect(first.restore_snapshot(base) and second.restore_snapshot(base),
		"Two copies restore the same pre-scan snapshot")
	var first_result: Dictionary = first.market_match(START)
	var second_result: Dictionary = second.market_match(START)
	_expect(first_result.count == second_result.count,
		"Two identical scans settle the same number of trades")
	_expect(first.snapshot() == second.snapshot(),
		"Two identical scans produce byte-identical snapshots")
	_expect(Market.valid(first.economy_snapshot()),
		"The scanned market passes strict validation")
	_expect(first.restore_snapshot(first.snapshot()),
		"The settled snapshot restores through the public boundary")
	for trade: Dictionary in first.market_trades():
		var buy: Dictionary = first.market_order(str(trade.buy_id))
		var sell: Dictionary = first.market_order(str(trade.sell_id))
		_expect(not buy.is_empty() and not sell.is_empty()
			and str(buy.owner) == str(trade.buy_owner)
			and str(sell.owner) == str(trade.sell_owner),
			"Every trade still points at its two durable order rows")
	_expect_conservation(first, produced, "determinism")


## 7. A market document written before `granted` and the rolling rows loads,
## validates, and can open the merchant normally afterwards.
func _test_legacy_market() -> void:
	var farm := Farm.new(START)
	_open(farm, PLAYER_A, START)
	var legacy: Dictionary = farm.snapshot()
	legacy.economy.market.merchant.erase("granted")
	_expect(legacy.economy.market.orders.is_empty(),
		"The legacy fixture has no merchant rows")
	var granted_before: Dictionary = Market.merchant_granted(legacy.economy)
	for good_id: String in Catalog.goods_ids():
		_expect(int(granted_before[good_id]) == 0,
			"A legacy market reads the missing %s grant as zero" % good_id)
	var restored := Farm.new()
	_expect(restored.restore_snapshot(legacy),
		"A legacy market without granted restores and validates")
	_expect(Market.valid(restored.economy_snapshot()),
		"The restored legacy market is structurally valid")
	var opened: Dictionary = restored.market_open_merchant("legacy-open", START)
	_expect(bool(opened.ok), "The legacy market opens the merchant normally")
	var granted_after: Dictionary = Market.merchant_granted(restored.economy_snapshot())
	var bid_total: int = 0
	for good_id: String in Catalog.goods_ids():
		_expect(int(granted_after[good_id]) == Market.MERCHANT_GRANT_PER_GOOD,
			"Opening grants 20 %s on the legacy market" % good_id)
		bid_total += int(restored.market_order(
			Market.merchant_quote_id(good_id, Market.SIDE_BUY)).reserved)
	_expect(_merchant_row_count(restored) == 12, "Opening adds the twelve rolling rows")
	_expect(int(restored.market_merchant().cash) == 600 - bid_total,
		"The rolling bids take their escrow from the opened budget")
	_expect(restored.economy_total_cash() == restored.economy_issued(),
		"The legacy open still conserves cash")


## 8. A world opened before the stock rule carries no `granted` field. The
## helper grants exactly once; the field itself stops a second grant.
func _test_opened_legacy_grant() -> void:
	var goods: Dictionary = {}
	for good_id: String in Catalog.goods_ids():
		goods[good_id] = 0
	var merchant: Dictionary = {
		"opened": true, "opened_by": "legacy-open", "opened_utc": START,
		"cash": 600, "goods": goods,
	}
	_expect(Market.grant_merchant_stock(merchant),
		"An opened merchant without a grant record is granted once")
	var granted: Dictionary = Market.merchant_granted({"market": {"merchant": merchant}})
	for good_id: String in Catalog.goods_ids():
		_expect(int(granted[good_id]) == Market.MERCHANT_GRANT_PER_GOOD,
			"The legacy grant records 20 %s" % good_id)
		_expect(int(merchant.goods[good_id]) == Market.MERCHANT_GRANT_PER_GOOD,
			"The legacy grant stocks 20 %s" % good_id)
	_expect(not Market.grant_merchant_stock(merchant),
		"A second grant call is refused by the durable marker")
	_expect(int(merchant.goods.get("greens", 0)) == Market.MERCHANT_GRANT_PER_GOOD,
		"The refused second grant adds no stock")


## 9. A sweep that only reopens due quotes reports `changed` and commits, so
## the refreshed rows survive the call instead of living in a discarded
## candidate; the row count stays at twelve.
func _test_sweep_persists_reopened_quotes() -> void:
	var farm := Farm.new(START)
	_open(farm, PLAYER_A, START)
	_expect(bool(farm.market_open_merchant("open-merchant", START).ok),
		"The merchant opens for the sweep case")
	var swept: Dictionary = farm.market_match(START + Market.MERCHANT_QUOTE_SECONDS)
	_expect(bool(swept.ok) and bool(swept.get("changed", false)),
		"A sweep at the quote expiry reports a change")
	_expect(_merchant_row_count(farm) == 12,
		"The reopened sweep keeps exactly twelve merchant rows")
	_expect(int(farm.market_merchant().goods.get("greens", 0)) == 16,
		"The committed sweep keeps four units escrowed in the ask")


func _open(farm: Farm, owner: String, now: float) -> void:
	var result: Dictionary = farm.economy_open_account("open-" + owner, owner, now)
	_expect(bool(result.ok) and int(result.amount) == 120,
		"Opening the account grants 120 COIN: " + owner)


func _grow(farm: Farm, field_id: String, cells: Array[String], crop_id: String,
		actor: String, now: float) -> int:
	for cell_id: String in cells:
		var sown: Dictionary = farm.sow(field_id, cell_id, crop_id, now, actor)
		_expect(bool(sown.ok), "Sowing %s on %s/%s: %s" % [
			crop_id, field_id, cell_id, str(sown.get("reason", ""))])
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


func _bag(farm: Farm, owner: String, good_id: String) -> int:
	return int(farm.bag(owner).get(good_id, 0))


func _merchant_row_count(farm: Farm) -> int:
	var count: int = 0
	for good_id: String in Catalog.goods_ids():
		for side: String in Market.SIDES:
			if not farm.market_order(Market.merchant_quote_id(good_id, side)).is_empty():
				count += 1
	return count


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
		if str(order.get("side", "")) == Market.SIDE_SELL \
				and str(order.get("good", "")) == good_id \
				and str(order.get("status", "")) == Market.STATUS_OPEN:
			total += int(order.get("reserved", 0))
	for shipment: Dictionary in farm.market_shipments():
		if str(shipment.get("status", "")) == Market.SHIPMENT_STATUS_TRANSIT:
			total += int(shipment.get("quantity", 0))
	return total


## produced + merchant grant == pockets + merchant stock + sell escrow +
## in transit. Consumption is zero in this fixture.
func _expect_conservation(farm: Farm, produced: Dictionary, label: String) -> void:
	var economy: Dictionary = farm.economy_snapshot()
	var granted: Dictionary = Market.merchant_granted(economy)
	for good_id: String in Catalog.goods_ids():
		var output: int = int(produced.get(good_id, 0))
		var total: int = _goods_total(farm, good_id)
		_expect(total == output + int(granted[good_id]),
			"%s: %s goods %d != produced %d + granted %d" % [
				label, good_id, total, output, int(granted[good_id])])
		_expect(total >= 0, "%s: %s goods never become negative" % [label, good_id])
	_expect(farm.economy_total_cash() == farm.economy_issued(),
		"%s: total_cash %d != issued %d" % [
			label, farm.economy_total_cash(), farm.economy_issued()])
	_expect(farm.economy_issued() >= 0, "%s: issued is nonnegative" % label)
	_expect(int(farm.market_merchant().cash) >= 0, "%s: merchant cash is nonnegative" % label)
	_expect(Market.valid(economy), "%s: economy stays structurally valid" % label)


func _cells(first: int, last: int) -> Array[String]:
	var result: Array[String] = []
	for index: int in range(first, last + 1):
		result.append("cell_%02d" % index)
	return result


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
