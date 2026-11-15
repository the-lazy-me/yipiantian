extends SceneTree
## M7-02 market orders: quotes, limit orders, escrowed reservations, cancel,
## deterministic expiry, merchant budget, replay and restart. Headless and
## isolated; no scene, system clock or player save is touched.

const Farm = preload("res://farm/farm_state.gd")
const Market = preload("res://farm/market_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const Catalog = preload("res://farm/economy_catalog.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const V27Importer = preload("res://farm/v27_importer.gd")

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
		"../.local/verification/market-orders-%d" % OS.get_process_id()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_initial_state_and_quotes()
	_test_place_validation()
	_test_sell_reservation()
	_test_buy_reservation()
	_test_cancel()
	_test_expiry()
	_test_cancel_expiry_race()
	_test_merchant()
	_test_reopen_and_eviction()
	_test_snapshot_validation()
	_test_authority_equivalence()
	for failure: String in failures:
		push_error(failure)
	print("MARKET_ORDERS_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_initial_state_and_quotes() -> void:
	var farm := Farm.new(START)
	var economy: Dictionary = farm.economy_snapshot()
	_expect(economy.market == Market.initial_state(),
		"A new farm starts with the empty market shape")
	_expect(farm.market_snapshot().merchant.cash == 0
		and farm.market_snapshot().merchant.opened == false,
		"The merchant starts closed with no budget")
	_expect(farm.market_snapshot().orders.is_empty() and farm.market_snapshot().sequence == 0,
		"No orders and no receive sequence before the first order")
	_expect("economy" in V27Importer.KNOWN_FARM_KEYS and not ("market" in V27Importer.KNOWN_FARM_KEYS),
		"The market stays inside the known economy key; no farm top-level key was added")
	var quotes: Dictionary = farm.market_quotes()
	_expect(quotes.size() == Catalog.goods_ids().size(), "Every catalog good has a quote")
	_expect(quotes.greens.bid == 4 and quotes.greens.ask == 7,
		"Greens quote is bid 4 / ask 7 from the reference price 6")
	_expect(quotes.carrot.bid == 19 and quotes.carrot.ask == 30,
		"Carrot quote is bid 19 / ask 30 from the reference price 24")
	_expect(quotes.radish.bid == 14 and quotes.radish.ask == 22,
		"Radish quote is bid 14 / ask 22 from the reference price 18")
	_expect(quotes.greens.buy_capacity == 0 and quotes.greens.sell_capacity == 0,
		"A closed merchant can neither buy nor sell")
	_expect(farm.market_quote("luffa").is_empty() and farm.market_quote("not_a_good").is_empty(),
		"Goods outside the six-good catalog have no quote")
	_expect(Market.valid_owner(PLAYER_A) and Market.valid_owner(Market.MERCHANT)
		and not Market.valid_owner("@world") and not Market.valid_owner("bad id"),
		"Players and the merchant are distinct owners; the public world id is not a market owner")
	var old: Dictionary = farm.snapshot()
	old.economy.erase("market")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(old), "An M7-01 economy without a market still restores")
	_expect(restored.market_snapshot() == Market.initial_state(),
		"A missing market restores empty and issues no merchant budget")
	_expect(restored.economy_issued() == 0 and restored.economy_total_cash() == 0,
		"Restoring an old economy still issues no money")


func _test_place_validation() -> void:
	var farm: Farm = _fixture_farm()
	var before: Dictionary = farm.snapshot()
	var cases: Array[Dictionary] = [
		{"id": "", "owner": PLAYER_A, "side": "sell", "good": "greens", "price": 10, "quantity": 1,
			"expires": START + HOUR, "now": START, "reason": "invalid_command", "label": "empty command id"},
		{"id": "x".repeat(Market.MAX_COMMAND_ID_LENGTH + 1), "owner": PLAYER_A, "side": "sell",
			"good": "greens", "price": 10, "quantity": 1, "expires": START + HOUR, "now": START,
			"reason": "invalid_command", "label": "overlong command id"},
		{"id": "bad-owner", "owner": "bad id", "side": "sell", "good": "greens", "price": 10,
			"quantity": 1, "expires": START + HOUR, "now": START,
			"reason": "invalid_owner", "label": "malformed owner"},
		{"id": "world-owner", "owner": "@world", "side": "sell", "good": "greens", "price": 10,
			"quantity": 1, "expires": START + HOUR, "now": START,
			"reason": "invalid_owner", "label": "public inventory owner"},
		{"id": "bad-side", "owner": PLAYER_A, "side": "hold", "good": "greens", "price": 10,
			"quantity": 1, "expires": START + HOUR, "now": START,
			"reason": "invalid_side", "label": "unknown side"},
		{"id": "luffa-good", "owner": PLAYER_A, "side": "sell", "good": "luffa", "price": 10,
			"quantity": 1, "expires": START + HOUR, "now": START,
			"reason": "invalid_good", "label": "unpriced crop"},
		{"id": "unknown-good", "owner": PLAYER_A, "side": "buy", "good": "not_a_good", "price": 10,
			"quantity": 1, "expires": START + HOUR, "now": START,
			"reason": "invalid_good", "label": "unknown good"},
		{"id": "neg-price", "owner": PLAYER_A, "side": "sell", "good": "greens", "price": -1,
			"quantity": 1, "expires": START + HOUR, "now": START,
			"reason": "invalid_price", "label": "negative price"},
		{"id": "zero-price", "owner": PLAYER_A, "side": "sell", "good": "greens", "price": 0,
			"quantity": 1, "expires": START + HOUR, "now": START,
			"reason": "invalid_price", "label": "zero price"},
		{"id": "fractional-price", "owner": PLAYER_A, "side": "sell", "good": "greens", "price": 1.5,
			"quantity": 1, "expires": START + HOUR, "now": START,
			"reason": "invalid_price", "label": "fractional price"},
		{"id": "text-price", "owner": PLAYER_A, "side": "sell", "good": "greens", "price": "6",
			"quantity": 1, "expires": START + HOUR, "now": START,
			"reason": "invalid_price", "label": "text price"},
		{"id": "huge-price", "owner": PLAYER_A, "side": "sell", "good": "greens",
			"price": Market.MAX_PRICE + 1, "quantity": 1, "expires": START + HOUR, "now": START,
			"reason": "invalid_price", "label": "price above the bound"},
		{"id": "neg-quantity", "owner": PLAYER_A, "side": "sell", "good": "greens", "price": 10,
			"quantity": -1, "expires": START + HOUR, "now": START,
			"reason": "invalid_quantity", "label": "negative quantity"},
		{"id": "zero-quantity", "owner": PLAYER_A, "side": "sell", "good": "greens", "price": 10,
			"quantity": 0, "expires": START + HOUR, "now": START,
			"reason": "invalid_quantity", "label": "zero quantity"},
		{"id": "fractional-quantity", "owner": PLAYER_A, "side": "sell", "good": "greens",
			"price": 10, "quantity": 1.5, "expires": START + HOUR, "now": START,
			"reason": "invalid_quantity", "label": "fractional quantity"},
		{"id": "text-quantity", "owner": PLAYER_A, "side": "sell", "good": "greens", "price": 10,
			"quantity": "1", "expires": START + HOUR, "now": START,
			"reason": "invalid_quantity", "label": "text quantity"},
		{"id": "huge-quantity", "owner": PLAYER_A, "side": "sell", "good": "greens", "price": 10,
			"quantity": Market.MAX_QUANTITY + 1, "expires": START + HOUR, "now": START,
			"reason": "invalid_quantity", "label": "quantity above the bound"},
		{"id": "same-expiry", "owner": PLAYER_A, "side": "sell", "good": "greens", "price": 10,
			"quantity": 1, "expires": START, "now": START,
			"reason": "invalid_expiry", "label": "expiry equal to creation"},
		{"id": "past-expiry", "owner": PLAYER_A, "side": "sell", "good": "greens", "price": 10,
			"quantity": 1, "expires": START - 1.0, "now": START,
			"reason": "invalid_expiry", "label": "expiry before creation"},
		{"id": "negative-now", "owner": PLAYER_A, "side": "sell", "good": "greens", "price": 10,
			"quantity": 1, "expires": START + HOUR, "now": -1.0,
			"reason": "invalid_expiry", "label": "negative command time"},
	]
	for entry: Dictionary in cases:
		var result: Dictionary = farm.market_place_order(entry.id, entry.owner, entry.side,
			entry.good, entry.price, entry.quantity, entry.expires, entry.now)
		_expect(not result.ok and result.reason == entry.reason,
			"Market refuses " + str(entry.label) + " with " + str(entry.reason))
		_expect(farm.snapshot() == before,
			"A refused order leaves the whole snapshot untouched: " + str(entry.label))
	var no_account := Farm.new(START)
	var missing: Dictionary = no_account.market_place_order("buy-no-account", PLAYER_A, "buy",
		"carrot", 30, 1, START + HOUR, START)
	_expect(not missing.ok and missing.reason == "unknown_account",
		"A buy order needs an opened cash account")
	# Integral JSON-style floats are accepted and normalized to integers, matching
	# the existing economy ledger convention.
	var integral: Dictionary = farm.market_place_order("integral", PLAYER_A, "sell", "greens",
		10.0, 1.0, START + HOUR, START)
	_expect(integral.ok and farm.market_order("integral").price is int
		and farm.market_order("integral").price == 10
		and farm.market_order("integral").quantity is int
		and farm.market_order("integral").quantity == 1,
		"Integral numbers are normalized to integer price and quantity")
	_expect(farm.economy_snapshot().sequence == 2 + 1,
		"The accepted order advances the economy sequence once; refusals did not")


func _test_sell_reservation() -> void:
	var farm: Farm = _fixture_farm()
	_expect(farm.bag(PLAYER_A).greens == 2, "The fixture gives player A two baskets of greens")
	var opened: int = farm.economy_snapshot().sequence
	var placed: Dictionary = farm.market_place_order("sell-1", PLAYER_A, "sell", "greens", 10, 2,
		START + HOUR, START)
	_expect(placed.ok and not placed.duplicate and placed.status == Market.STATUS_OPEN,
		"A funded sell order is accepted")
	_expect(placed.order_id == "sell-1" and placed.owner == PLAYER_A and placed.side == "sell"
		and placed.good == "greens" and placed.price == 10 and placed.quantity == 2,
		"The result carries the order identity and terms")
	_expect(placed.remaining == 2 and placed.reserved == 2 and placed.amount == 2
		and placed.sequence == 1, "The full quantity is reserved and receives sequence 1")
	var order: Dictionary = farm.market_order("sell-1")
	_expect(order.filled == 0 and order.remaining == 2 and order.released == 0
		and order.closed_by == "" and order.closed_utc == 0.0,
		"A new order is fully unfilled and unclosed")
	_expect(order.created_utc == START and order.expires_utc == START + HOUR,
		"The caller's UTC creation and expiry are stored unchanged")
	_expect(farm.bag(PLAYER_A).greens == 0 and farm.economy_goods(PLAYER_A).greens == 0,
		"Reserved greens leave the available bag immediately")
	_expect(farm.market_orders().size() == 1, "The market holds exactly one order")
	_expect(farm.economy_snapshot().sequence == opened + 1,
		"An accepted order advances the economy sequence once")
	var snapshot: Dictionary = farm.snapshot()
	_expect(snapshot.bags[PLAYER_A].greens == 0
		and snapshot.economy.market.orders["sell-1"].reserved == 2,
		"The reduced bag and the reservation live in the same farm snapshot")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(snapshot)
		and restored.market_order("sell-1").reserved == 2
		and restored.bag(PLAYER_A).greens == 0,
		"Restoring the snapshot preserves the escrow exactly")
	var accepted: Dictionary = farm.snapshot()
	var over: Dictionary = farm.market_place_order("sell-over", PLAYER_A, "sell", "greens", 10, 1,
		START + HOUR, START)
	_expect(not over.ok and over.reason == "insufficient_goods",
		"A sell order cannot reserve more than the available bag")
	_expect(farm.snapshot() == accepted, "The refused over-reservation changes nothing")
	var gift: Dictionary = farm.gift(PLAYER_A, PLAYER_B, "greens", 1)
	_expect(not gift.ok and gift.reason == "insufficient",
		"Escrowed goods cannot be gifted away from under the sell order")
	var replay: Dictionary = farm.market_place_order("sell-1", PLAYER_A, "sell", "greens", 10, 2,
		START + HOUR, START)
	_expect(replay.ok and replay.duplicate and farm.snapshot() == accepted,
		"A retried sell order id replays without a second reservation")
	var conflict: Dictionary = farm.market_place_order("sell-1", PLAYER_A, "sell", "greens", 10, 1,
		START + HOUR, START)
	_expect(not conflict.ok and conflict.reason == "command_conflict"
		and farm.snapshot() == accepted, "The same order id with different terms is a conflict")


func _test_buy_reservation() -> void:
	var farm: Farm = _fixture_farm()
	_expect(farm.economy_cash(PLAYER_A) == Economy.OPENING_GRANT,
		"The fixture opens player A with the standard grant")
	var opened: int = farm.economy_snapshot().sequence
	var placed: Dictionary = farm.market_place_order("buy-1", PLAYER_A, "buy", "carrot", 30, 3,
		START + HOUR, START)
	_expect(placed.ok and placed.reserved == 90 and placed.amount == 90
		and placed.remaining == 3, "A buy order reserves price times quantity")
	_expect(farm.economy_cash(PLAYER_A) == 30 and farm.economy_issued() == 240,
		"Reserved cash leaves the available balance without changing issued money")
	_expect(farm.economy_total_cash() == 240,
		"Reserved cash stays inside the issued total after leaving the available balance")
	var order: Dictionary = farm.market_order("buy-1")
	_expect(order.reserved == 90 and order.side == "buy" and order.price == 30,
		"The buy order row carries the reserved cash")
	var accepted: Dictionary = farm.snapshot()
	var over: Dictionary = farm.market_place_order("buy-over", PLAYER_A, "buy", "carrot", 30, 2,
		START + HOUR, START)
	_expect(not over.ok and over.reason == "insufficient_cash",
		"A buy order cannot reserve more than the remaining balance")
	_expect(farm.snapshot() == accepted, "The refused over-reservation changes nothing")
	var exact: Dictionary = farm.market_place_order("buy-exact", PLAYER_A, "buy", "carrot", 30, 1,
		START + HOUR, START)
	_expect(exact.ok and farm.economy_cash(PLAYER_A) == 0,
		"An order using exactly the remaining balance is accepted")
	_expect(not farm.market_place_order("buy-empty", PLAYER_A, "buy", "carrot", 30, 1,
		START + HOUR, START).ok, "No order can reserve cash after the balance reaches zero")
	_expect(farm.economy_snapshot().sequence == opened + 2,
		"Only the two accepted buy orders advanced the sequence")
	var cash: int = farm.economy_cash(PLAYER_A)
	var reserved: int = 0
	for entry: Dictionary in farm.market_orders():
		if entry.owner == PLAYER_A and entry.side == "buy":
			reserved += int(entry.reserved)
	_expect(cash + reserved == Economy.OPENING_GRANT,
		"Available cash plus buy escrow equals the original balance")
	_expect(farm.economy_total_cash() == farm.economy_issued(),
		"Escrow does not create or destroy issued cash")


func _test_cancel() -> void:
	var farm: Farm = _fixture_farm()
	var placed: Dictionary = farm.market_place_order("cancel-sell", PLAYER_A, "sell", "greens", 10, 2,
		START + HOUR, START)
	_expect(placed.ok, "The cancel fixture places a sell order")
	var accepted: Dictionary = farm.snapshot()
	var foreign: Dictionary = farm.market_cancel_order("cancel-foreign", PLAYER_B, "cancel-sell",
		START + 10)
	_expect(not foreign.ok and foreign.reason == "not_owner"
		and farm.snapshot() == accepted, "Another player cannot cancel A's order")
	var unknown: Dictionary = farm.market_cancel_order("cancel-unknown", PLAYER_A, "no-such-order",
		START + 10)
	_expect(not unknown.ok and unknown.reason == "unknown_order"
		and farm.snapshot() == accepted, "A missing order is refused")
	_expect(not farm.market_cancel_order("cancel-bad-owner", "bad id", "cancel-sell", START + 10).ok
		and farm.snapshot() == accepted, "A malformed owner cannot cancel")
	_expect(not farm.market_cancel_order("cancel-bad-order", PLAYER_A, "", START + 10).ok
		and farm.snapshot() == accepted, "An empty order id cannot cancel")
	_expect(not farm.market_cancel_order("cancel-backdated", PLAYER_A, "cancel-sell", START - 1.0).ok
		and farm.snapshot() == accepted, "A cancel before creation is refused")
	var cancelled: Dictionary = farm.market_cancel_order("cancel-1", PLAYER_A, "cancel-sell",
		START + 10)
	_expect(cancelled.ok and not cancelled.duplicate and cancelled.amount == 2
		and cancelled.status == Market.STATUS_CANCELLED,
		"The owner cancels the open order and releases the full reservation")
	_expect(farm.bag(PLAYER_A).greens == 2, "Cancelling a sell order returns the goods")
	var order: Dictionary = farm.market_order("cancel-sell")
	_expect(order.status == Market.STATUS_CANCELLED and order.remaining == 2
		and order.reserved == 0 and order.released == 2 and order.closed_by == "cancel-1"
		and order.closed_utc == START + 10,
		"The closed order records its release and closing command")
	var after: Dictionary = farm.snapshot()
	var replay: Dictionary = farm.market_cancel_order("cancel-1", PLAYER_A, "cancel-sell", START + 10)
	_expect(replay.ok and replay.duplicate and replay.amount == 2 and farm.snapshot() == after,
		"Replaying the same cancel id returns the release without releasing again")
	var conflict: Dictionary = farm.market_cancel_order("cancel-1", PLAYER_A, "cancel-sell", START + 11)
	_expect(not conflict.ok and conflict.reason == "command_conflict"
		and farm.snapshot() == after, "The same cancel id at another time is a conflict")
	var second: Dictionary = farm.market_cancel_order("cancel-2", PLAYER_A, "cancel-sell", START + 12)
	_expect(not second.ok and second.reason == "order_closed" and farm.snapshot() == after,
		"A second cancel with a new id cannot release twice")

	var buy: Dictionary = farm.market_place_order("cancel-buy", PLAYER_A, "buy", "carrot", 30, 2,
		START + HOUR, START)
	_expect(buy.ok and farm.economy_cash(PLAYER_A) == 60, "A buy order reserves 60 cash")
	var cash_cancel: Dictionary = farm.market_cancel_order("cancel-buy-cmd", PLAYER_A, "cancel-buy",
		START + 20)
	_expect(cash_cancel.ok and cash_cancel.amount == 60 and farm.economy_cash(PLAYER_A) == 120,
		"Cancelling a buy order returns the reserved cash")
	_expect(farm.economy_total_cash() == 240 and farm.economy_issued() == 240,
		"Cancel conserves issued and total cash")


func _test_expiry() -> void:
	var farm: Farm = _fixture_farm()
	var expires: float = START + 100.0
	_expect(farm.market_place_order("expire-sell", PLAYER_A, "sell", "greens", 10, 1, expires, START).ok,
		"The expiry fixture places a sell order")
	var before: Dictionary = farm.snapshot()
	var early: Dictionary = farm.market_expire(expires - 1.0)
	_expect(early.ok and early.expired == 0 and farm.snapshot() == before,
		"One second before the UTC boundary releases nothing")
	var at: Dictionary = farm.market_expire(expires)
	_expect(at.ok and at.expired == 1 and at.released_goods == {"greens": 1},
		"At the exact UTC boundary the order expires and reports the return")
	_expect(farm.bag(PLAYER_A).greens == 2, "Expiry releases the reserved goods")
	var order: Dictionary = farm.market_order("expire-sell")
	_expect(order.status == Market.STATUS_EXPIRED and order.remaining == 1
		and order.reserved == 0 and order.released == 1 and order.closed_by == ""
		and order.closed_utc == expires,
		"The expired order carries its release and boundary time")
	var after: Dictionary = farm.snapshot()
	var again: Dictionary = farm.market_expire(expires)
	_expect(again.ok and again.expired == 0 and farm.snapshot() == after,
		"Replaying the expiry sweep releases nothing twice")
	_expect(not farm.market_cancel_order("late-cancel", PLAYER_A, "expire-sell", expires).ok
		and farm.snapshot() == after, "An expired order can no longer be cancelled")

	var cash_farm: Farm = _fixture_farm()
	_expect(cash_farm.market_place_order("expire-buy", PLAYER_A, "buy", "carrot", 30, 1,
		expires, START).ok, "A buy order is placed for the cash expiry check")
	_expect(cash_farm.economy_cash(PLAYER_A) == 90, "The buy order reserved 30 cash")
	var cash_at: Dictionary = cash_farm.market_expire(expires)
	_expect(cash_at.expired == 1 and cash_at.released_cash == 30
		and cash_farm.economy_cash(PLAYER_A) == 120,
		"Expiry returns reserved cash to the account")
	_expect(cash_farm.market_order("expire-buy").status == Market.STATUS_EXPIRED,
		"The expired buy order is closed")
	_expect(cash_farm.economy_total_cash() == 240 and cash_farm.economy_issued() == 240,
		"Expiry conserves issued and total cash")


func _test_cancel_expiry_race() -> void:
	var farm: Farm = _fixture_farm()
	var expires: float = START + 100.0
	_expect(farm.market_place_order("race-sell", PLAYER_A, "sell", "greens", 10, 1, expires, START).ok,
		"The race fixture places one sell order")
	var base: Dictionary = farm.snapshot()

	var cancel_first := Farm.new()
	cancel_first.restore_snapshot(base)
	var cancel_won: Dictionary = cancel_first.market_cancel_order("race-cancel", PLAYER_A,
		"race-sell", START + 50.0)
	var late_expire: Dictionary = cancel_first.market_expire(expires)
	_expect(cancel_won.ok and cancel_won.amount == 1 and late_expire.expired == 0,
		"A cancel before the boundary wins and the later sweep releases nothing")
	_expect(cancel_first.bag(PLAYER_A).greens == 2
		and cancel_first.market_order("race-sell").released == 1,
		"The cancel path returns the goods exactly once")

	var expire_first := Farm.new()
	expire_first.restore_snapshot(base)
	var expired: Dictionary = expire_first.market_expire(expires)
	var late_cancel: Dictionary = expire_first.market_cancel_order("race-cancel", PLAYER_A,
		"race-sell", expires)
	_expect(expired.expired == 1 and not late_cancel.ok
		and late_cancel.reason == "order_closed",
		"An expiry at the boundary closes the order before a later cancel")
	_expect(expire_first.bag(PLAYER_A).greens == 2
		and expire_first.market_order("race-sell").released == 1,
		"The expiry path also returns the goods exactly once")

	var cancel_at_boundary := Farm.new()
	cancel_at_boundary.restore_snapshot(base)
	var refused: Dictionary = cancel_at_boundary.market_cancel_order("race-cancel", PLAYER_A,
		"race-sell", expires)
	_expect(not refused.ok and refused.reason == "order_expired"
		and cancel_at_boundary.bag(PLAYER_A).greens == 1,
		"A cancel at the UTC boundary is refused because the order is already due")
	var boundary_sweep: Dictionary = cancel_at_boundary.market_expire(expires)
	_expect(boundary_sweep.expired == 1 and cancel_at_boundary.bag(PLAYER_A).greens == 2,
		"The boundary sweep then releases the goods once")

	var twin_a := Farm.new()
	var twin_b := Farm.new()
	twin_a.restore_snapshot(base)
	twin_b.restore_snapshot(base)
	_expect(twin_a.market_expire(expires).expired == 1
		and twin_b.market_expire(expires).expired == 1,
		"Two candidates from the same snapshot expire the same order")
	_expect(twin_a.snapshot() == twin_b.snapshot(),
		"Same starting snapshot and UTC time produce identical expiry candidates")

	var final_bag: int = 2
	_expect(cancel_first.bag(PLAYER_A).greens == final_bag
		and expire_first.bag(PLAYER_A).greens == final_bag
		and cancel_at_boundary.bag(PLAYER_A).greens == final_bag,
		"Cancel-first, expire-first and boundary-refusal all end with one released basket")
	_expect(cancel_first.economy_total_cash() == 240
		and expire_first.economy_total_cash() == 240
		and cancel_at_boundary.economy_total_cash() == 240,
		"Every race order keeps cash conserved")


func _test_merchant() -> void:
	var farm: Farm = _fixture_farm()
	var before_open: int = farm.economy_issued()
	var opened: Dictionary = farm.market_open_merchant("merchant-open", START)
	_expect(opened.ok and opened.amount == Market.MERCHANT_BUDGET,
		"The one-time merchant opening issues the experimental budget")
	_expect(farm.market_merchant().opened and farm.market_merchant().cash == Market.MERCHANT_BUDGET,
		"The merchant holds the issued budget in its own cash field")
	_expect(farm.economy_issued() == before_open + Market.MERCHANT_BUDGET,
		"Merchant budget is explicit issuance, not magic inventory")
	_expect(farm.economy_total_cash() == farm.economy_issued(),
		"Player accounts plus merchant cash equal the issued total")
	var accepted: Dictionary = farm.snapshot()
	var replay: Dictionary = farm.market_open_merchant("merchant-open", START)
	_expect(replay.ok and replay.duplicate and farm.snapshot() == accepted,
		"Replaying the merchant opening does not issue a second budget")
	_expect(not farm.market_open_merchant("merchant-open-2", START).ok
		and farm.snapshot() == accepted,
		"A second merchant opening id is refused without changing the budget")
	var greens: Dictionary = farm.market_quote("greens")
	_expect(greens.bid == 4 and greens.ask == 7 and greens.buy_capacity == 150
		and greens.sell_capacity == 0,
		"The opened merchant can buy 150 greens but holds none to sell")
	var bought: Dictionary = farm.market_place_order("merchant-buy", Market.MERCHANT, "buy",
		"greens", greens.bid, 100, START + HOUR, START)
	_expect(bought.ok and bought.owner == Market.MERCHANT and bought.reserved == 400,
		"A merchant buy at the bid reserves budget")
	_expect(farm.market_merchant().cash == 200,
		"Merchant cash falls by the reserved budget")
	_expect(farm.market_quote("greens").buy_capacity == 50,
		"The quote capacity follows the remaining budget")
	var after_buy: Dictionary = farm.snapshot()
	var over_budget: Dictionary = farm.market_place_order("merchant-over", Market.MERCHANT, "buy",
		"greens", 4, 51, START + HOUR, START)
	_expect(not over_budget.ok and over_budget.reason == "insufficient_cash"
		and farm.snapshot() == after_buy,
		"The merchant cannot buy beyond its remaining budget")
	var no_stock: Dictionary = farm.market_place_order("merchant-sell", Market.MERCHANT, "sell",
		"greens", greens.ask, 1, START + HOUR, START)
	_expect(not no_stock.ok and no_stock.reason == "insufficient_goods"
		and farm.snapshot() == after_buy,
		"The merchant cannot sell goods it does not hold")
	var wrong_price: Dictionary = farm.market_place_order("merchant-wrong", Market.MERCHANT, "buy",
		"greens", 5, 1, START + HOUR, START)
	_expect(not wrong_price.ok and wrong_price.reason == "invalid_price"
		and farm.snapshot() == after_buy,
		"A merchant buy must use the quoted bid")
	var foreign_cancel: Dictionary = farm.market_cancel_order("merchant-foreign", PLAYER_A,
		"merchant-buy", START + 10)
	_expect(not foreign_cancel.ok and foreign_cancel.reason == "not_owner",
		"A player cannot cancel the merchant's order")
	var cancelled: Dictionary = farm.market_cancel_order("merchant-cancel", Market.MERCHANT,
		"merchant-buy", START + 10)
	_expect(cancelled.ok and cancelled.amount == 400 and farm.market_merchant().cash == 600,
		"Cancelling a merchant buy returns the reserved budget")
	_expect(farm.market_quote("greens").buy_capacity == 150,
		"The quote capacity recovers with the returned budget")
	_expect(farm.economy_total_cash() == farm.economy_issued(),
		"Merchant cancel keeps player and merchant cash conserved")


func _test_reopen_and_eviction() -> void:
	var farm: Farm = _fixture_farm()
	_expect(farm.market_place_order("persist-sell", PLAYER_A, "sell", "greens", 10, 1,
		START + HOUR, START).ok, "The restart fixture places a sell order")
	_expect(farm.market_place_order("persist-buy", PLAYER_A, "buy", "carrot", 30, 1,
		START + HOUR, START).ok, "The restart fixture places a buy order")
	_expect(farm.market_open_merchant("persist-merchant", START).ok,
		"The restart fixture opens the merchant")
	var saved: Dictionary = farm.snapshot()
	var store := FarmStore.new(test_root.path_join("restart"))
	_expect(store.load_state().kind == "missing", "The isolated restart directory is admitted")
	_expect(store.save(saved, Decorations.new().snapshot()).ok, "The market snapshot saves")
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok, "The saved market snapshot loads")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(loaded.farm), "The loaded market snapshot restores")
	_expect(restored.snapshot() == farm.snapshot(),
		"Orders, escrow, merchant budget and the ledger survive the disk round trip")
	_expect(restored.bag(PLAYER_A).greens == 1 and restored.economy_cash(PLAYER_A) == 90
		and restored.market_merchant().cash == Market.MERCHANT_BUDGET,
		"Escrowed goods, escrowed cash and merchant cash are all recovered")
	var accepted: Dictionary = restored.snapshot()
	_expect(restored.market_place_order("persist-sell", PLAYER_A, "sell", "greens", 10, 1,
		START + HOUR, START).duplicate and restored.snapshot() == accepted,
		"A restarted world replays the sell order id without a second reservation")
	_expect(restored.market_place_order("persist-buy", PLAYER_A, "buy", "carrot", 30, 1,
		START + HOUR, START).duplicate and restored.snapshot() == accepted,
		"A restarted world replays the buy order id without a second reservation")
	_expect(restored.market_open_merchant("persist-merchant", START).duplicate
		and restored.snapshot() == accepted,
		"A restarted world replays the merchant opening without a second budget")

	# Simulate the bounded command window losing every id. Order rows are the
	# durable record, so neither a second placement nor a second release happens.
	var evicted: Dictionary = restored.snapshot()
	evicted.economy.command_results = {}
	var reopened := Farm.new()
	_expect(reopened.restore_snapshot(evicted), "A snapshot with an evicted command window restores")
	var bag_before: int = reopened.bag(PLAYER_A).greens
	var cash_before: int = reopened.economy_cash(PLAYER_A)
	var duplicate: Dictionary = reopened.market_place_order("persist-sell", PLAYER_A, "sell",
		"greens", 10, 1, START + HOUR, START)
	_expect(not duplicate.ok and duplicate.reason == "order_exists"
		and reopened.bag(PLAYER_A).greens == bag_before,
		"An evicted place id cannot reserve the same goods twice")
	var first_cancel: Dictionary = reopened.market_cancel_order("persist-cancel", PLAYER_A,
		"persist-sell", START + 10)
	_expect(first_cancel.ok and first_cancel.amount == 1
		and reopened.bag(PLAYER_A).greens == bag_before + 1,
		"The durable order is still cancellable after the window is lost")
	var after_cancel: Dictionary = reopened.snapshot()
	after_cancel.economy.command_results = {}
	var replay_closed := Farm.new()
	_expect(replay_closed.restore_snapshot(after_cancel), "The evicted cancel snapshot restores")
	var no_second_release: Dictionary = replay_closed.market_cancel_order("persist-cancel", PLAYER_A,
		"persist-sell", START + 10)
	_expect(not no_second_release.ok and no_second_release.reason == "order_closed"
		and replay_closed.bag(PLAYER_A).greens == bag_before + 1,
		"An evicted cancel id cannot release the closed order a second time")
	_expect(replay_closed.economy_cash(PLAYER_A) == cash_before
		and replay_closed.economy_total_cash() == replay_closed.economy_issued(),
		"Eviction and replay leave cash conserved")


func _test_snapshot_validation() -> void:
	var farm: Farm = _fixture_farm()
	farm.market_open_merchant("valid-merchant", START)
	farm.market_place_order("valid-sell", PLAYER_A, "sell", "greens", 10, 1, START + HOUR, START)
	farm.market_place_order("valid-buy", PLAYER_A, "buy", "carrot", 30, 1, START + HOUR, START)
	var original: Dictionary = farm.snapshot()
	var json_value: Dictionary = JSON.parse_string(JSON.stringify(original))
	var restored := Farm.new()
	_expect(restored.restore_snapshot(json_value), "A JSON market snapshot restores")
	_expect(restored.market_order("valid-sell").price is int
		and restored.market_order("valid-sell").reserved is int
		and restored.market_order("valid-sell").closed_utc is float
		and restored.market_merchant().cash is int
		and restored.market_snapshot().sequence is int,
		"JSON numbers normalize back to integer market counts and float times")
	var corruptions: Array[Dictionary] = []
	var candidate: Dictionary = original.duplicate(true)
	candidate.economy.market.extra = true
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.sequence = -1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.merchant.cash = -1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.merchant.goods.greens = 0.5
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.merchant.opened = "yes"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.orders["valid-sell"].extra = true
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.orders["valid-sell"].side = "hold"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.orders["valid-sell"].price = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.orders["valid-sell"].remaining = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.orders["valid-sell"].reserved = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.orders["valid-sell"].status = "unknown"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.orders["valid-sell"].released = 1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.orders["valid-sell"].sequence = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.orders["valid-sell"].expires_utc = START
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.orders["valid-sell"].closed_by = "cancel"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.erase("market")
	candidate.economy.extra = true
	corruptions.append(candidate)
	for broken: Dictionary in corruptions:
		_expect(not farm.restore_snapshot(broken) and farm.snapshot() == original,
			"Malformed market state is rejected without changing the live farm")


func _test_authority_equivalence() -> void:
	var authority: Farm = _fixture_farm()
	var base: Dictionary = authority.snapshot()
	var local := Farm.new()
	_expect(local.restore_snapshot(base), "The local replay starts from the same pre-command snapshot")
	var commands: Array[Dictionary] = [
		{"kind": "merchant", "id": "eq-merchant", "now": START},
		{"kind": "place", "id": "eq-sell", "owner": PLAYER_A, "side": "sell", "good": "greens",
			"price": 10, "quantity": 1, "expires": START + HOUR, "now": START},
		{"kind": "place", "id": "eq-buy", "owner": PLAYER_A, "side": "buy", "good": "carrot",
			"price": 30, "quantity": 1, "expires": START + HOUR, "now": START},
		{"kind": "cancel", "id": "eq-cancel", "owner": PLAYER_A, "order": "eq-sell",
			"now": START + 10.0},
	]
	for entry: Dictionary in commands:
		_expect(_apply_market(authority, entry).ok, "Authority accepts " + str(entry.id))
		_expect(_apply_market(local, entry).ok, "Local copy accepts " + str(entry.id))
	_expect(authority.snapshot() == local.snapshot(),
		"The same market commands produce the same snapshot on authority and local copies")
	_expect(authority.market_order("eq-sell").status == Market.STATUS_CANCELLED
		and authority.bag(PLAYER_A).greens == 2,
		"The equivalence run ends with the sell order cancelled and its goods returned")
	_expect(authority.economy_total_cash() == authority.economy_issued(),
		"The equivalence run keeps cash conserved")


func _apply_market(farm: Farm, entry: Dictionary) -> Dictionary:
	match str(entry.kind):
		"merchant":
			return farm.market_open_merchant(entry.id, entry.now)
		"place":
			return farm.market_place_order(entry.id, entry.owner, entry.side, entry.good,
				entry.price, entry.quantity, entry.expires, entry.now)
		"cancel":
			return farm.market_cancel_order(entry.id, entry.owner, entry.order, entry.now)
		_:
			return {"ok": false, "reason": "unknown"}


func _fixture_farm() -> Farm:
	# A named harvest lands in bags; the fixture gives A two greens and B one
	# radish, and opens both cash accounts.
	var farm := Farm.new(START)
	farm.mature_all_crops(START)
	farm.harvest("field_03", "cell_06", START, PLAYER_A)
	farm.harvest("field_04", "cell_06", START, PLAYER_A)
	farm.harvest("field_05", "cell_06", START, PLAYER_B)
	farm.harvest("field_06", "cell_06", START)
	farm.economy_open_account("open-a", PLAYER_A, START)
	farm.economy_open_account("open-b", PLAYER_B, START)
	return farm


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
