extends SceneTree
## M7-03 matching and settlement: price-time priority, partial fills, maker
## pricing, fixed fee burn, atomic goods/cash delivery, deterministic cancel
## and expiry races, durable trade ids, ledger eviction and restart. Headless
## and isolated; no scene, system clock or player save is touched.

const Farm = preload("res://farm/farm_state.gd")
const Market = preload("res://farm/market_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")

const START: float = 1800000000.0
const HOUR: float = 3600.0
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/matching-%d" % OS.get_process_id()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_initial_state()
	_test_price_priority_and_maker_price()
	_test_buy_price_priority()
	_test_sequence_priority_same_price()
	_test_partial_fill()
	_test_multiple_levels_and_fees()
	_test_fee_edge_and_conservation()
	_test_no_cross_and_time_guard()
	_test_cancel_match_race()
	_test_expiry_match_race()
	_test_durable_trade_ids_and_reopen()
	_test_duplicate_match_id()
	_test_merchant_participation()
	_test_snapshot_validation()
	_test_authority_equivalence()
	for failure: String in failures:
		push_error(failure)
	print("MARKET_MATCHING_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_initial_state() -> void:
	var farm: Farm = _fixture()
	var market: Dictionary = farm.market_snapshot()
	_expect(market.trades is Dictionary and market.trades.is_empty(),
		"A new market starts with an empty durable trade log")
	_expect(market.trade_sequence == 0 and farm.market_trades().is_empty(),
		"No trade sequence is consumed before the first fill")
	_expect(Market.valid(farm.economy_snapshot()),
		"The empty trade log is part of the valid market shape")
	var swapped: Dictionary = Market.initial_state()
	swapped.trades = []
	_expect(not Market.valid({"market": swapped}),
		"A trade log that is not a dictionary is rejected")
	_expect(farm.market_match(-1.0).reason == "invalid_time",
		"Matching requires finite nonnegative UTC seconds")
	var before: Dictionary = farm.snapshot()
	_expect(farm.market_match(START).count == 0 and farm.snapshot() == before,
		"An empty book matches nothing and changes no state")


func _test_price_priority_and_maker_price() -> void:
	var farm: Farm = _fixture()
	_expect(farm.market_place_order("sell-a", PLAYER_A, "sell", "greens", 10, 1,
		START + HOUR, START).ok, "A rests a 1-green sell at 10")
	_expect(farm.market_place_order("sell-b", PLAYER_B, "sell", "greens", 9, 1,
		START + HOUR, START).ok, "B rests a cheaper 1-green sell at 9")
	_expect(farm.market_place_order("buy-c", PLAYER_C, "buy", "greens", 12, 1,
		START + HOUR, START).ok, "C rests a 1-green buy at 12")
	var matched: Dictionary = farm.market_match(START)
	_expect(matched.ok and matched.count == 1 and matched.fee == 1 and matched.notional == 9,
		"One sweep crosses the book once and reports the notional and fee")
	var trade: Dictionary = farm.market_trade("trade_1")
	_expect(trade.buy_id == "buy-c" and trade.sell_id == "sell-b",
		"Price priority beats receive order: B's 9 matches before A's 10")
	_expect(trade.price == 9 and trade.buy_price == 12 and trade.sell_price == 9,
		"The earlier resting sell sets the trade price even though the buy bid higher")
	_expect(trade.quantity == 1 and trade.notional == 9 and trade.fee == 1
		and trade.buy_refund == 3 and trade.sell_credit == 8,
		"Buyer refund, seller credit and burned fee add up to the same notional")
	_expect(farm.economy_cash(PLAYER_C) == 111,
		"C pays its 12 bid less the 3 price improvement refund")
	_expect(farm.economy_cash(PLAYER_B) == 128,
		"B receives the 9 notional minus the 1 fee")
	_expect(farm.economy_cash(PLAYER_A) == 120,
		"A's untouched sell keeps its escrow and available cash")
	_expect(farm.bag(PLAYER_C).greens == 9 and farm.bag(PLAYER_B).greens == 7,
		"Delivered greens leave the seller escrow for the buyer bag")
	_expect(farm.market_order("sell-b").status == Market.STATUS_FILLED
		and farm.market_order("buy-c").status == Market.STATUS_FILLED
		and farm.market_order("sell-a").status == Market.STATUS_OPEN,
		"Only the crossed orders close; the dearer sell stays open")
	_expect(farm.economy_issued() == 359 and farm.economy_total_cash() == 359,
		"One trade burns exactly one COIN from issued and total cash")
	_expect_conserved(farm, "the first price-priority trade")

	var second: Dictionary = farm.market_place_order("buy-c2", PLAYER_C, "buy", "greens", 10, 1,
		START + HOUR, START)
	_expect(second.ok and farm.market_match(START).count == 1,
		"A second buy crosses the remaining sell")
	var trade_two: Dictionary = farm.market_trade("trade_2")
	_expect(trade_two.sell_id == "sell-a" and trade_two.price == 10
		and trade_two.buy_refund == 0 and trade_two.sell_credit == 9,
		"The maker sell sets the second trade price at its own limit")
	_expect(farm.economy_cash(PLAYER_A) == 129 and farm.economy_cash(PLAYER_C) == 101,
		"A receives 9 after the fee; C pays its exact 10 bid")
	_expect_conserved(farm, "the second trade")


func _test_buy_price_priority() -> void:
	var farm: Farm = _fixture()
	farm.market_place_order("bid-low", PLAYER_A, "buy", "greens", 9, 1, START + HOUR, START)
	farm.market_place_order("bid-high", PLAYER_B, "buy", "greens", 12, 1, START + HOUR, START)
	farm.market_place_order("ask-single", PLAYER_C, "sell", "greens", 10, 1, START + HOUR, START)
	var matched: Dictionary = farm.market_match(START)
	var trade: Dictionary = farm.market_trade("trade_1")
	_expect(matched.count == 1 and trade.buy_id == "bid-high" and trade.sell_id == "ask-single",
		"The higher bid matches before the earlier lower bid")
	_expect(trade.price == 12 and trade.buy_refund == 0 and trade.sell_credit == 11,
		"When the buy is the maker the higher bid sets the trade price")
	_expect(farm.market_order("bid-low").status == Market.STATUS_OPEN
		and farm.market_order("bid-high").status == Market.STATUS_FILLED,
		"The lower bid stays open because the single ask is exhausted")
	_expect(farm.economy_cash(PLAYER_A) == 111 and farm.economy_cash(PLAYER_B) == 108,
		"The lower bid keeps its 9 escrow; the higher bid pays its 12")
	_expect(farm.economy_cash(PLAYER_C) == 131 and farm.bag(PLAYER_B).greens == 9,
		"The seller receives 11 after the fee and delivers one basket")
	_expect_conserved(farm, "buy-side price priority")


func _test_sequence_priority_same_price() -> void:
	var farm: Farm = _fixture()
	farm.market_place_order("sell-first", PLAYER_A, "sell", "greens", 10, 1, START + HOUR, START)
	farm.market_place_order("sell-second", PLAYER_B, "sell", "greens", 10, 1, START + HOUR, START)
	farm.market_place_order("buy-last", PLAYER_C, "buy", "greens", 10, 1, START + HOUR, START)
	var matched: Dictionary = farm.market_match(START)
	_expect(matched.count == 1 and farm.market_trade("trade_1").sell_id == "sell-first",
		"At the same price the lower receive sequence trades first")
	_expect(farm.market_order("sell-first").status == Market.STATUS_FILLED
		and farm.market_order("sell-second").status == Market.STATUS_OPEN,
		"The later same-price sell stays open")
	_expect(farm.bag(PLAYER_A).greens == 7 and farm.bag(PLAYER_B).greens == 7
		and farm.bag(PLAYER_C).greens == 9,
		"Sequence priority also decides which seller's escrow is consumed")
	_expect_conserved(farm, "same-price sequence priority")

	var buy_side: Farm = _fixture()
	buy_side.market_place_order("bid-first", PLAYER_A, "buy", "greens", 10, 1,
		START + HOUR, START)
	buy_side.market_place_order("bid-second", PLAYER_B, "buy", "greens", 10, 1,
		START + HOUR, START)
	buy_side.market_place_order("ask-single", PLAYER_C, "sell", "greens", 10, 1,
		START + HOUR, START)
	buy_side.market_match(START)
	_expect(buy_side.market_trade("trade_1").buy_id == "bid-first"
		and buy_side.market_order("bid-second").status == Market.STATUS_OPEN,
		"At the same bid price the lower receive sequence matches first")
	_expect(buy_side.economy_cash(PLAYER_A) == 110
		and buy_side.economy_cash(PLAYER_B) == 110
		and buy_side.economy_cash(PLAYER_C) == 129,
		"The earlier bid pays; the later same-price bid keeps its escrow")
	_expect_conserved(buy_side, "buy-side same-price sequence priority")


func _test_partial_fill() -> void:
	var farm: Farm = _fixture()
	_expect(farm.market_place_order("sell-big", PLAYER_A, "sell", "greens", 10, 5,
		START + HOUR, START).ok, "A rests five greens")
	_expect(farm.market_place_order("buy-small", PLAYER_B, "buy", "greens", 10, 2,
		START + HOUR, START).ok, "B bids for only two")
	var matched: Dictionary = farm.market_match(START)
	_expect(matched.count == 1 and farm.market_trade("trade_1").quantity == 2,
		"The smaller side bounds a partial fill")
	var sell: Dictionary = farm.market_order("sell-big")
	_expect(sell.status == Market.STATUS_OPEN and sell.remaining == 3 and sell.filled == 2
		and sell.reserved == 3,
		"An open partially filled sell keeps only its unfilled escrow")
	var buy: Dictionary = farm.market_order("buy-small")
	_expect(buy.status == Market.STATUS_FILLED and buy.remaining == 0 and buy.filled == 2
		and buy.reserved == 0,
		"A fully filled buy releases all escrow")
	_expect(farm.bag(PLAYER_A).greens == 3 and farm.bag(PLAYER_B).greens == 10,
		"Only the filled quantity leaves escrow for the buyer")
	_expect(farm.economy_cash(PLAYER_A) == 139 and farm.economy_cash(PLAYER_B) == 100,
		"The seller receives 19 after the fee; the buyer pays its 20 bid")
	_expect_conserved(farm, "a partial fill")

	var finish: Dictionary = farm.market_place_order("buy-finish", PLAYER_C, "buy",
		"greens", 10, 5, START + HOUR, START)
	_expect(finish.ok and farm.market_match(START).count == 1,
		"A later buy consumes the unfilled remainder")
	var closed: Dictionary = farm.market_order("sell-big")
	_expect(closed.status == Market.STATUS_FILLED and closed.filled == 5
		and closed.remaining == 0 and closed.reserved == 0,
		"The partially filled sell closes only after its remainder settles")
	var open_buy: Dictionary = farm.market_order("buy-finish")
	_expect(open_buy.status == Market.STATUS_OPEN and open_buy.filled == 3
		and open_buy.remaining == 2 and open_buy.reserved == 20,
		"The incoming five-unit buy keeps its two unfilled units escrowed")
	_expect(farm.economy_cash(PLAYER_A) == 168 and farm.economy_cash(PLAYER_C) == 70,
		"Both fills credit the seller and consume the buyer escrow exactly")
	_expect(farm.bag(PLAYER_C).greens == 11, "C receives the three remaining baskets")
	_expect_conserved(farm, "finishing a partial fill")


func _test_multiple_levels_and_fees() -> void:
	var farm: Farm = _fixture()
	farm.market_place_order("level-1", PLAYER_A, "sell", "greens", 9, 2, START + HOUR, START)
	farm.market_place_order("level-2", PLAYER_B, "sell", "greens", 10, 3, START + HOUR, START)
	farm.market_place_order("level-3", PLAYER_A, "sell", "greens", 11, 2, START + HOUR, START)
	farm.market_place_order("sweep", PLAYER_C, "buy", "greens", 11, 6, START + HOUR, START)
	var matched: Dictionary = farm.market_match(START)
	_expect(matched.count == 3 and matched.fee == 3 and matched.notional == 59,
		"One sweep walks three price levels and burns one fee per fill")
	var trades: Array = farm.market_trades()
	_expect(trades.size() == 3 and trades[0].id == "trade_1" and trades[2].id == "trade_3",
		"Trade ids are durable and sequence-ordered")
	_expect(trades[0].price == 9 and trades[0].quantity == 2
		and trades[1].price == 10 and trades[1].quantity == 3
		and trades[2].price == 11 and trades[2].quantity == 1,
		"Each level trades at its own maker price and quantity")
	_expect(trades[0].sell_id == "level-1" and trades[1].sell_id == "level-2"
		and trades[2].sell_id == "level-3",
		"Bounds fill the cheapest sell first")
	_expect(trades[0].buy_refund == 4 and trades[1].buy_refund == 3
		and trades[2].buy_refund == 0,
		"Buyer escrow refunds each price improvement at every level")
	_expect(farm.economy_cash(PLAYER_C) == 61 and farm.economy_cash(PLAYER_A) == 147
		and farm.economy_cash(PLAYER_B) == 149,
		"C pays 59 net; A and B each receive their notional minus one fee")
	_expect(farm.bag(PLAYER_C).greens == 14,
		"All six bought baskets land in C's bag in the same settlement")
	_expect(farm.market_order("level-1").status == Market.STATUS_FILLED
		and farm.market_order("level-2").status == Market.STATUS_FILLED
		and farm.market_order("level-3").status == Market.STATUS_OPEN
		and farm.market_order("level-3").remaining == 1,
		"The deepest sell keeps its one unfilled basket")
	_expect(farm.economy_issued() == 357 and farm.economy_total_cash() == 357,
		"Three fills burn three COIN in total")
	_expect(_goods_total(farm, "greens") == 24,
		"Goods are conserved across bags, escrow and completed trades")
	_expect_conserved(farm, "a multi-level sweep")


func _test_fee_edge_and_conservation() -> void:
	var farm: Farm = _fixture()
	farm.market_place_order("cheap-sell", PLAYER_A, "sell", "greens", 1, 1, START + HOUR, START)
	farm.market_place_order("cheap-buy", PLAYER_B, "buy", "greens", 1, 1, START + HOUR, START)
	var matched: Dictionary = farm.market_match(START)
	_expect(matched.count == 1, "A one-COIN trade still fills")
	var trade: Dictionary = farm.market_trade("trade_1")
	_expect(trade.notional == 1 and trade.fee == 1 and trade.sell_credit == 0
		and trade.buy_refund == 0,
		"The fixed fee is capped by a one-COIN notional and leaves the seller zero")
	_expect(farm.economy_cash(PLAYER_A) == 120 and farm.economy_cash(PLAYER_B) == 119,
		"The buyer pays the one COIN and the seller receives nothing after the burn")
	_expect(farm.economy_issued() == 359 and farm.economy_total_cash() == 359,
		"The fee burn is the only money change")
	_expect(farm.bag(PLAYER_A).greens == 7 and farm.bag(PLAYER_B).greens == 9,
		"Goods still move even when the seller proceeds are zero")
	_expect_conserved(farm, "a one-COIN trade")


func _test_no_cross_and_time_guard() -> void:
	var farm: Farm = _fixture()
	farm.market_place_order("green-sell", PLAYER_A, "sell", "greens", 10, 1, START + HOUR, START)
	farm.market_place_order("radish-buy", PLAYER_B, "buy", "radish", 10, 1, START + HOUR, START)
	var before: Dictionary = farm.snapshot()
	_expect(farm.market_match(START).count == 0 and farm.snapshot() == before,
		"Different goods never cross")
	var farm_two: Farm = _fixture()
	farm_two.market_place_order("ask-10", PLAYER_A, "sell", "greens", 10, 1, START + HOUR, START)
	farm_two.market_place_order("bid-9", PLAYER_B, "buy", "greens", 9, 1, START + HOUR, START)
	var before_two: Dictionary = farm_two.snapshot()
	_expect(farm_two.market_match(START).count == 0 and farm_two.snapshot() == before_two,
		"A bid below the ask does not cross")
	_expect(farm_two.market_match(START - 1.0).count == 0
		and farm_two.snapshot() == before_two,
		"A sweep before the orders were accepted fills nothing")


func _test_cancel_match_race() -> void:
	var farm: Farm = _fixture()
	farm.market_place_order("sell-race", PLAYER_A, "sell", "greens", 10, 5, START + HOUR, START)
	farm.market_place_order("buy-race", PLAYER_B, "buy", "greens", 10, 5, START + HOUR, START)
	var base: Dictionary = farm.snapshot()

	var match_first := Farm.new()
	_expect(match_first.restore_snapshot(base), "The match-first candidate restores")
	_expect(match_first.market_match(START).count == 1, "The match-first path fills the pair")
	var late_cancel: Dictionary = match_first.market_cancel_order("cancel-race", PLAYER_A,
		"sell-race", START + 10.0)
	_expect(not late_cancel.ok and late_cancel.reason == "order_closed",
		"A cancel after a full fill cannot release escrow again")
	_expect(match_first.bag(PLAYER_A).greens == 3 and match_first.bag(PLAYER_B).greens == 13,
		"The match-first path delivers exactly one five-basket batch")
	_expect(match_first.economy_cash(PLAYER_A) == 169
		and match_first.economy_cash(PLAYER_B) == 70,
		"The match-first path moves the seller credit and buyer payment once")
	_expect_conserved(match_first, "match before cancel")

	var cancel_first := Farm.new()
	_expect(cancel_first.restore_snapshot(base), "The cancel-first candidate restores")
	var early_cancel: Dictionary = cancel_first.market_cancel_order("cancel-race", PLAYER_A,
		"sell-race", START + 10.0)
	_expect(early_cancel.ok and early_cancel.amount == 5,
		"The cancel-first path releases the full sell escrow")
	_expect(cancel_first.market_match(START).count == 0,
		"After the cancel there is no cross left to fill")
	var late_buy_cancel: Dictionary = cancel_first.market_cancel_order("cancel-buy-race",
		PLAYER_B, "buy-race", START + 20.0)
	_expect(late_buy_cancel.ok and late_buy_cancel.amount == 50,
		"The stranded buy escrow is released by its owner")
	_expect(cancel_first.bag(PLAYER_A).greens == 8
		and cancel_first.bag(PLAYER_B).greens == 8,
		"The cancel-first path returns the goods to the seller")
	_expect(cancel_first.economy_cash(PLAYER_A) == 120
		and cancel_first.economy_cash(PLAYER_B) == 120,
		"The cancel-first path returns both original balances")
	_expect(cancel_first.economy_issued() == 360,
		"No fill happened, so no fee was burned")
	_expect_conserved(cancel_first, "cancel before match")

	var partial := _fixture()
	partial.market_place_order("sell-partial", PLAYER_A, "sell", "greens", 10, 5,
		START + HOUR, START)
	partial.market_place_order("buy-partial", PLAYER_B, "buy", "greens", 10, 2,
		START + HOUR, START)
	var partial_base: Dictionary = partial.snapshot()
	var partial_match := Farm.new()
	partial_match.restore_snapshot(partial_base)
	_expect(partial_match.market_match(START).count == 1,
		"The partial race fills two of the five escrowed baskets")
	var remainder_cancel: Dictionary = partial_match.market_cancel_order("cancel-remainder",
		PLAYER_A, "sell-partial", START + 10.0)
	_expect(remainder_cancel.ok and remainder_cancel.amount == 3,
		"A cancel after a partial fill releases only the remaining three")
	_expect(partial_match.bag(PLAYER_A).greens == 6
		and partial_match.bag(PLAYER_B).greens == 10,
		"The buyer keeps the two filled baskets; the seller gets the other three back")
	_expect(partial_match.market_order("sell-partial").released == 3,
		"The released amount is the unfilled remainder, not the original five")
	_expect_conserved(partial_match, "cancel after a partial fill")


func _test_expiry_match_race() -> void:
	var farm: Farm = _fixture()
	var expiry: float = START + 100.0
	farm.market_place_order("sell-expiry", PLAYER_A, "sell", "greens", 10, 2,
		expiry, START)
	farm.market_place_order("buy-expiry", PLAYER_B, "buy", "greens", 10, 2,
		expiry + HOUR, START)
	var base: Dictionary = farm.snapshot()

	var match_before := Farm.new()
	match_before.restore_snapshot(base)
	_expect(match_before.market_match(expiry - 1.0).count == 1,
		"One second before expiry the pair still crosses")
	_expect(match_before.market_expire(expiry).expired == 0,
		"The later sweep releases nothing because both orders filled")
	_expect(match_before.economy_cash(PLAYER_A) == 139
		and match_before.economy_cash(PLAYER_B) == 100,
		"The pre-expiry fill settles both sides exactly once")
	_expect_conserved(match_before, "match before expiry")

	var expire_first := Farm.new()
	expire_first.restore_snapshot(base)
	var expired: Dictionary = expire_first.market_expire(expiry)
	_expect(expired.expired == 1 and expired.released_goods == {"greens": 2},
		"At the boundary expiry releases the still-open sell")
	_expect(expire_first.market_match(expiry).count == 0,
		"A sweep at the same boundary cannot fill an order due for expiry")
	_expect(expire_first.market_order("sell-expiry").status == Market.STATUS_EXPIRED,
		"The sell is closed by the expiry rule")
	var buy_cancel: Dictionary = expire_first.market_cancel_order("cancel-buy-expiry",
		PLAYER_B, "buy-expiry", START + 10.0)
	_expect(buy_cancel.ok and buy_cancel.amount == 20,
		"The surviving buy releases its own escrow")
	_expect(expire_first.bag(PLAYER_A).greens == 8
		and expire_first.economy_cash(PLAYER_B) == 120,
		"The expiry-first path returns goods and cash without a fill")
	_expect(expire_first.economy_issued() == 360,
		"No fill happened, so no fee was burned")
	_expect_conserved(expire_first, "expiry before match")

	var match_then_expire := Farm.new()
	var expire_then_match := Farm.new()
	match_then_expire.restore_snapshot(base)
	expire_then_match.restore_snapshot(base)
	_expect(match_then_expire.market_match(expiry).count == 0,
		"At the boundary the sell is already due and does not fill")
	_expect(match_then_expire.market_expire(expiry).expired == 1,
		"The first same-instant ordering then expires the sell")
	_expect(expire_then_match.market_expire(expiry).expired == 1,
		"The other same-instant ordering expires the sell first")
	_expect(expire_then_match.market_match(expiry).count == 0,
		"The other ordering then finds nothing to match")
	_expect(match_then_expire.snapshot() == expire_then_match.snapshot(),
		"At one UTC instant matching and expiry commute")


func _test_durable_trade_ids_and_reopen() -> void:
	var farm: Farm = _fixture()
	farm.market_place_order("sell-durable", PLAYER_A, "sell", "greens", 10, 5,
		START + HOUR, START)
	farm.market_place_order("buy-durable", PLAYER_B, "buy", "greens", 10, 2,
		START + HOUR, START)
	_expect(farm.market_match(START).count == 1, "The durable fixture makes one partial fill")
	_expect(farm.market_order("sell-durable").remaining == 3
		and farm.market_order("sell-durable").filled == 2,
		"The partial fill is durable on the sell row")

	var store := FarmStore.new(test_root.path_join("durable"))
	_expect(store.load_state().kind == "missing", "The isolated durable directory is admitted")
	_expect(store.save(farm.snapshot(), Decorations.new().snapshot()).ok,
		"The partially settled snapshot saves")
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok, "The partially settled snapshot loads")
	var reopened := Farm.new()
	_expect(reopened.restore_snapshot(loaded.farm), "The partially settled snapshot restores")
	_expect(reopened.snapshot() == farm.snapshot(),
		"Escrow, order rows, fee burn and the trade log survive the round trip")
	_expect(reopened.market_trade("trade_1").sequence == 1
		and reopened.market_trade("trade_1").at_utc == START
		and reopened.market_trade("trade_1").sequence is int,
		"A reopened trade id resolves with normalized numbers")
	_expect(reopened.market_match(START).count == 0,
		"A repeated sweep after reopening does not settle the same fill twice")
	_expect(reopened.economy_total_cash() == reopened.economy_issued(),
		"Reopening and repeating a sweep keeps cash conserved")

	var finish: Dictionary = reopened.market_place_order("buy-finish", PLAYER_C, "buy",
		"greens", 10, 5, START + HOUR, START)
	_expect(finish.ok and reopened.market_match(START).count == 1,
		"A reopened world can finish the unfilled part")
	_expect(reopened.market_trades().size() == 2,
		"The completion appends a second durable trade, not a replacement")
	_expect(reopened.market_order("sell-durable").status == Market.STATUS_FILLED,
		"The partial order closes after the reopened remainder fills")
	_expect(reopened.economy_cash(PLAYER_A) == 168
		and reopened.economy_cash(PLAYER_B) == 100
		and reopened.economy_cash(PLAYER_C) == 70,
		"Both fills credit exactly once across the restart")
	_expect_conserved(reopened, "finishing after a restart")

	# Lose the 64-entry command window. Orders and the trade log are the durable
	# records, so a retry cannot escrow or settle a second time.
	var evicted: Dictionary = reopened.snapshot()
	evicted.economy.command_results = {}
	var from_evicted := Farm.new()
	_expect(from_evicted.restore_snapshot(evicted),
		"A snapshot with an evicted command window still restores")
	var evicted_snapshot: Dictionary = from_evicted.snapshot()
	_expect(from_evicted.market_match(START).count == 0
		and from_evicted.snapshot() == evicted_snapshot,
		"An evicted command window cannot make a repeated sweep re-settle")
	_expect(from_evicted.market_place_order("sell-durable", PLAYER_A, "sell", "greens", 10, 5,
		START + HOUR, START).reason == "order_exists",
		"An evicted place id still cannot re-escrow the same order")
	_expect(from_evicted.market_place_order("buy-durable", PLAYER_B, "buy", "greens", 10, 2,
		START + HOUR, START).reason == "order_exists",
		"An evicted buy id still cannot re-escrow cash")
	_expect(from_evicted.snapshot() == evicted_snapshot,
		"All evicted retries leave the settlement snapshot untouched")
	_expect(from_evicted.market_trades().size() == 2
		and from_evicted.market_trade("trade_1").quantity == 2
		and from_evicted.market_trade("trade_2").quantity == 3,
		"The durable trade ids still resolve after the command window is gone")
	_expect_conserved(from_evicted, "evicted command window retries")

	var second_store := FarmStore.new(test_root.path_join("durable-second"))
	_expect(second_store.load_state().kind == "missing",
		"The second isolated durable directory is admitted")
	_expect(second_store.save(from_evicted.snapshot(), Decorations.new().snapshot()).ok,
		"The evicted-window snapshot saves")
	var second_loaded: Dictionary = second_store.load_state()
	var second_reopen := Farm.new()
	_expect(second_loaded.ok and second_reopen.restore_snapshot(second_loaded.farm),
		"The evicted-window snapshot restores after a second restart")
	_expect(second_reopen.snapshot() == from_evicted.snapshot()
		and second_reopen.market_match(START).count == 0,
		"A second restart still cannot repeat a completed settlement")


func _test_duplicate_match_id() -> void:
	var farm: Farm = _fixture()
	farm.market_place_order("dup-sell", PLAYER_A, "sell", "greens", 10, 2, START + HOUR, START)
	farm.market_place_order("dup-buy", PLAYER_B, "buy", "greens", 10, 2, START + HOUR, START)
	var first: Dictionary = farm.market_match(START, "match-1")
	_expect(first.ok and not first.duplicate and first.count == 1,
		"A command-bound sweep records its accepted fill count")
	var settled: Dictionary = farm.snapshot()
	var retry: Dictionary = farm.market_match(START, "match-1")
	_expect(retry.ok and retry.duplicate and retry.count == 1 and farm.snapshot() == settled,
		"The same match id and UTC time replays without a second settlement")
	var conflict: Dictionary = farm.market_match(START + 1.0, "match-1")
	_expect(not conflict.ok and conflict.reason == "command_conflict"
		and conflict.duplicate and farm.snapshot() == settled,
		"The same match id at another time is a conflict with no state change")
	var sweep: Dictionary = farm.market_match(START)
	_expect(sweep.ok and not sweep.duplicate and sweep.count == 0
		and farm.snapshot() == settled,
		"An id-less sweep stays a state-driven no-op")
	_expect(farm.market_match(START, "x".repeat(Market.MAX_COMMAND_ID_LENGTH + 1)).reason
		== "invalid_command", "An overlong match id is refused")
	_expect(farm.snapshot() == settled, "The invalid match id changes nothing")

	var evicted: Dictionary = settled.duplicate(true)
	evicted.economy.command_results = {}
	var reopened := Farm.new()
	_expect(reopened.restore_snapshot(evicted),
		"A snapshot with an evicted match id restores")
	var after_eviction: Dictionary = reopened.market_match(START, "match-1")
	_expect(after_eviction.ok and not after_eviction.duplicate and after_eviction.count == 0,
		"After eviction the same match id finds no crossing and settles nothing")
	_expect(reopened.economy_cash(PLAYER_A) == 139
		and reopened.economy_cash(PLAYER_B) == 100
		and reopened.market_trades().size() == 1,
		"The evicted retry still leaves one fill, one seller credit and one buyer payment")
	_expect_conserved(reopened, "a duplicate match id after eviction")


func _test_merchant_participation() -> void:
	var farm: Farm = _fixture()
	var opened: Dictionary = farm.market_open_merchant("merchant-open", START)
	_expect(opened.ok and farm.market_merchant().cash == Market.MERCHANT_BUDGET,
		"The merchant joins with its explicit budget")
	_expect(farm.economy_issued() == 960,
		"The merchant budget is the second explicit issuance")
	farm.market_place_order("sell-to-merchant", PLAYER_A, "sell", "greens", 4, 5,
		START + HOUR, START)
	farm.market_place_order("merchant-buy", Market.MERCHANT, "buy", "greens", 4, 5,
		START + HOUR, START)
	var matched: Dictionary = farm.market_match(START)
	_expect(matched.count == 1 and farm.market_trade("trade_1").price == 4,
		"The merchant bid matches the player ask at the maker price")
	_expect(farm.market_merchant().cash == 580
		and farm.market_merchant().goods.greens == 5,
		"The merchant pays from escrow and receives the goods")
	_expect(farm.economy_cash(PLAYER_A) == 139,
		"The player seller receives 19 after the fee")
	_expect_conserved(farm, "a merchant buy")

	farm.market_place_order("merchant-sell", Market.MERCHANT, "sell", "greens", 7, 5,
		START + HOUR, START)
	farm.market_place_order("buy-from-merchant", PLAYER_C, "buy", "greens", 7, 5,
		START + HOUR, START)
	_expect(farm.market_match(START).count == 1,
		"The merchant's newly acquired stock can now be sold")
	_expect(farm.market_trade("trade_2").price == 7
		and farm.market_trade("trade_2").sell_owner == Market.MERCHANT,
		"The merchant's resting ask sets the second trade price")
	_expect(farm.market_merchant().cash == 614
		and farm.market_merchant().goods.greens == 0,
		"The merchant receives 34 after the fee and holds no greens")
	_expect(farm.economy_cash(PLAYER_C) == 85,
		"The buyer pays its exact seven-COIN bid")
	_expect(farm.economy_issued() == 958 and farm.economy_total_cash() == 958,
		"Two merchant trades burn two COIN")
	_expect_conserved(farm, "a merchant sell")

	var seller_without_open: Farm = _fixture()
	var raw: Dictionary = seller_without_open.snapshot()
	# A player that never opened an account also never received the opening
	# grant, so the issued total drops with the account; this is a valid state,
	# not a conserved one with a missing account.
	raw.economy.accounts.erase(PLAYER_A)
	raw.economy.issued = int(raw.economy.issued) - Economy.OPENING_GRANT
	var removed := Farm.new()
	_expect(removed.restore_snapshot(raw), "A snapshot can omit an unopened cash account")
	_expect(removed.market_place_order("sell-unopened", PLAYER_A, "sell", "greens", 10, 1,
		START + HOUR, START).ok, "Selling does not require an opened cash account")
	removed.market_place_order("buy-unopened", PLAYER_B, "buy", "greens", 10, 1,
		START + HOUR, START)
	removed.market_match(START)
	_expect(removed.economy_snapshot().accounts[PLAYER_A].cash == 9
		and removed.economy_snapshot().accounts[PLAYER_A].granted == false,
		"Selling without an account creates a proceeds-only account without issuance")
	_expect_conserved(removed, "seller proceeds before opening")
	var opened_later: Dictionary = removed.economy_open_account("open-later", PLAYER_A, START)
	_expect(opened_later.ok and removed.economy_cash(PLAYER_A) == 129
		and removed.economy_snapshot().accounts[PLAYER_A].granted == true,
		"Opening after receiving proceeds still grants the one-time amount exactly once")
	_expect(not removed.economy_open_account("open-again", PLAYER_A, START).ok,
		"A second opening is still refused after the late grant")
	_expect_conserved(removed, "the late opening grant")


func _test_snapshot_validation() -> void:
	var farm: Farm = _fixture()
	farm.market_place_order("valid-sell", PLAYER_A, "sell", "greens", 10, 2,
		START + HOUR, START)
	farm.market_place_order("valid-buy", PLAYER_B, "buy", "greens", 10, 1,
		START + HOUR, START)
	farm.market_match(START)
	farm.market_place_order("open-sell", PLAYER_C, "sell", "greens", 10, 1,
		START + HOUR, START)
	var original: Dictionary = farm.snapshot()
	var json_value: Dictionary = JSON.parse_string(JSON.stringify(original))
	var restored := Farm.new()
	_expect(restored.restore_snapshot(json_value), "A JSON market with a trade log restores")
	_expect(restored.market_snapshot().trade_sequence is int
		and restored.market_trade("trade_1").sequence is int
		and restored.market_trade("trade_1").price is int
		and restored.market_trade("trade_1").at_utc is float,
		"JSON numbers normalize back to integer trade counts and float times")

	# M7-02 wrote a market with orders but no trade log. It must still load, with
	# the settled orders exactly as written and an empty log.
	var legacy: Dictionary = original.duplicate(true)
	legacy.economy.market.erase("trades")
	legacy.economy.market.erase("trade_sequence")
	var legacy_restored := Farm.new()
	_expect(legacy_restored.restore_snapshot(legacy),
		"An M7-02 market without a trade log restores")
	_expect(legacy_restored.market_snapshot().trade_sequence == 0
		and legacy_restored.market_trades().is_empty()
		and legacy_restored.market_order("valid-sell").filled == 1,
		"A missing trade log becomes empty without touching the orders")

	var corruptions: Array[Dictionary] = []
	var candidate: Dictionary = original.duplicate(true)
	candidate.economy.market.trades["trade_1"].extra = true
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.trades["trade_1"].price = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.trades["trade_1"].notional += 1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.trades["trade_1"].fee = 100
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.trades["trade_1"].sell_credit += 1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.trades["trade_1"].buy_refund += 1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.trades["trade_1"].buy_price = 9
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.trades["trade_1"].buy_owner = "bad id"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.trades["trade_1"].id = "trade_999"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.trades["trade_1"].sequence = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.trades["trade_1"].buy_id = candidate.economy.market.trades["trade_1"].sell_id
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.trades["trade_1"].at_utc = -1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.trade_sequence = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.trades = []
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.erase("trades")
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.extra = true
	corruptions.append(candidate)
	for broken: Dictionary in corruptions:
		_expect(not farm.restore_snapshot(broken) and farm.snapshot() == original,
			"Malformed matching state is rejected without changing the live farm")


func _test_authority_equivalence() -> void:
	var authority: Farm = _fixture()
	var base: Dictionary = authority.snapshot()
	var local := Farm.new()
	_expect(local.restore_snapshot(base), "The local replay starts from the same snapshot")
	var commands: Array[Dictionary] = [
		{"kind": "place", "id": "eq-sell-1", "owner": PLAYER_A, "side": "sell",
			"good": "greens", "price": 9, "quantity": 2, "expires": START + HOUR},
		{"kind": "place", "id": "eq-sell-2", "owner": PLAYER_B, "side": "sell",
			"good": "greens", "price": 10, "quantity": 3, "expires": START + HOUR},
		{"kind": "place", "id": "eq-buy", "owner": PLAYER_C, "side": "buy",
			"good": "greens", "price": 10, "quantity": 4, "expires": START + HOUR},
	]
	for entry: Dictionary in commands:
		_expect(_apply_place(authority, entry).ok, "Authority accepts " + str(entry.id))
		_expect(_apply_place(local, entry).ok, "Local copy accepts " + str(entry.id))
	var authority_match: Dictionary = authority.market_match(START)
	var local_match: Dictionary = local.market_match(START)
	_expect(authority_match.count == 2 and local_match.count == 2,
		"Both copies cross the same two prices")
	_expect(authority.snapshot() == local.snapshot(),
		"The same orders and UTC time produce the same settled snapshot")
	var after: Dictionary = authority.snapshot()
	_expect(authority.market_match(START).count == 0 and authority.snapshot() == after,
		"A repeated sweep is a deterministic no-op")
	_expect(authority.market_trade("trade_1").quantity == 2
		and authority.market_trade("trade_2").quantity == 2,
		"The sweep stops when the incoming buy is exhausted")
	_expect_conserved(authority, "the equivalence run")


func _apply_place(farm: Farm, entry: Dictionary) -> Dictionary:
	return farm.market_place_order(str(entry.id), str(entry.owner), str(entry.side),
		str(entry.good), entry.price, entry.quantity, float(entry.expires), START)


func _fixture() -> Farm:
	# Three players each start with eight greens grown on real cells and 120
	# COIN, so every order below has a real source and the goods invariant can
	# be checked against 24 baskets.
	var farm := Farm.new(START)
	_grow(farm, "field_01", ["cell_01", "cell_02", "cell_03", "cell_04",
		"cell_05", "cell_06", "cell_07", "cell_08"], PLAYER_A)
	_grow(farm, "field_02", ["cell_01", "cell_02", "cell_03", "cell_04",
		"cell_05", "cell_06", "cell_07", "cell_08"], PLAYER_B)
	_grow(farm, "field_01", ["cell_09", "cell_10", "cell_11", "cell_12",
		"cell_13", "cell_14", "cell_15", "cell_16"], PLAYER_C)
	farm.economy_open_account("open-a", PLAYER_A, START)
	farm.economy_open_account("open-b", PLAYER_B, START)
	farm.economy_open_account("open-c", PLAYER_C, START)
	return farm


func _grow(farm: Farm, field_id: String, cells: Array, actor: String) -> void:
	for cell_id: String in cells:
		farm.sow(field_id, cell_id, "greens", START, actor)
	farm.mature_all_crops(START)
	for cell_id: String in cells:
		farm.harvest(field_id, cell_id, START, actor)


func _goods_total(farm: Farm, good_id: String) -> int:
	var total: int = farm.bag(PLAYER_A).get(good_id, 0) \
		+ farm.bag(PLAYER_B).get(good_id, 0) + farm.bag(PLAYER_C).get(good_id, 0)
	if farm.market_merchant().get("goods") is Dictionary:
		total += int(farm.market_merchant().goods.get(good_id, 0))
	for order: Dictionary in farm.market_orders():
		if str(order.side) == "sell" and str(order.good) == good_id \
				and str(order.status) == Market.STATUS_OPEN:
			total += int(order.reserved)
	return total


func _expect_conserved(farm: Farm, label: String) -> void:
	_expect(farm.economy_total_cash() == farm.economy_issued(),
		"Total cash equals net issued after " + label)
	_expect(farm.economy_issued() >= 0,
		"Issued cash never goes negative after " + label)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
