extends SceneTree
## M7-04 limited logistics: two fixed markets, in-transit goods that cannot be
## sold twice, a flat burned shipping fee, deterministic arrival and durable
## delivery events. Headless and isolated; no scene, system clock or player save
## is touched.

const Farm = preload("res://farm/farm_state.gd")
const Market = preload("res://farm/market_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const V27Importer = preload("res://farm/v27_importer.gd")

const START: float = 1800000000.0
const HOUR: float = 3600.0
const ARRIVE: float = START + Market.DELIVERY_SECONDS
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const PLAYER_D: String = "player_00000000000000000000000000000004"

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/logistics-%d" % OS.get_process_id()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_initial_state()
	_test_ship_validation()
	_test_in_transit_cannot_be_resold()
	_test_delivery_boundaries()
	_test_delivery_events_and_replay()
	_test_fee_and_goods_conservation()
	_test_order_independence()
	_test_save_reopen()
	_test_snapshot_validation()
	for failure: String in failures:
		push_error(failure)
	print("MARKET_LOGISTICS_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_initial_state() -> void:
	var farm: Farm = _fixture()
	var market: Dictionary = farm.market_snapshot()
	_expect(market.shipments is Dictionary and market.shipments.is_empty(),
		"A new market starts with no shipments")
	_expect(market.deliveries is Dictionary and market.deliveries.is_empty(),
		"A new market starts with no delivery events")
	_expect(market.shipment_sequence == 0 and market.delivery_sequence == 0,
		"No shipment or delivery sequence is consumed before the first shipment")
	_expect(Market.valid(farm.economy_snapshot()),
		"The empty shipment ledger is part of the valid market shape")
	_expect(FarmStore.VERSION == 27,
		"Logistics does not change the farm format version")
	_expect("economy" in V27Importer.KNOWN_FARM_KEYS \
		and not ("logistics" in V27Importer.KNOWN_FARM_KEYS) \
		and not ("shipments" in V27Importer.KNOWN_FARM_KEYS),
		"Logistics stays inside the known economy key; no farm top-level key was added")
	var route: Dictionary = farm.market_route(Market.LOCATION_FARM, Market.LOCATION_HARBOR)
	_expect(route.fee == Market.SHIPMENT_FEE and route.delivery_seconds == Market.DELIVERY_SECONDS,
		"The two-market route exposes the deterministic fee and travel time")
	_expect(farm.market_routes().size() == 2,
		"The two markets expose one route in each direction")
	_expect(farm.market_route(Market.LOCATION_FARM, Market.LOCATION_FARM).is_empty()
		and farm.market_route("moon", Market.LOCATION_HARBOR).is_empty(),
		"A shipment must move between two known and distinct markets")
	var before: Dictionary = farm.snapshot()
	var sweep: Dictionary = farm.market_deliver(START)
	_expect(sweep.ok and sweep.count == 0 and farm.snapshot() == before,
		"An empty delivery sweep changes nothing")
	_expect(farm.market_deliver(-1.0).reason == "invalid_time",
		"Delivery requires finite nonnegative UTC seconds")
	_expect(farm.market_shipments().is_empty() and farm.market_deliveries().is_empty(),
		"The query views are empty before any shipment")


func _test_ship_validation() -> void:
	var farm: Farm = _fixture()
	var cases: Array[Dictionary] = [
		{"id": "", "owner": PLAYER_A, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR, "good": "greens", "quantity": 1,
			"now": START, "reason": "invalid_command", "label": "empty command id"},
		{"id": "x".repeat(Market.MAX_COMMAND_ID_LENGTH + 1), "owner": PLAYER_A,
			"origin": Market.LOCATION_FARM, "destination": Market.LOCATION_HARBOR,
			"good": "greens", "quantity": 1, "now": START,
			"reason": "invalid_command", "label": "overlong command id"},
		{"id": "bad-owner", "owner": "bad id", "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR, "good": "greens", "quantity": 1,
			"now": START, "reason": "invalid_owner", "label": "malformed owner"},
		{"id": "world-owner", "owner": "@world", "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR, "good": "greens", "quantity": 1,
			"now": START, "reason": "invalid_owner", "label": "public inventory owner"},
		{"id": "merchant-owner", "owner": Market.MERCHANT, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR, "good": "greens", "quantity": 1,
			"now": START, "reason": "invalid_owner", "label": "rule merchant owner"},
		{"id": "luffa-good", "owner": PLAYER_A, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR, "good": "luffa", "quantity": 1,
			"now": START, "reason": "invalid_good", "label": "unpriced crop"},
		{"id": "unknown-good", "owner": PLAYER_A, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR, "good": "not_a_good", "quantity": 1,
			"now": START, "reason": "invalid_good", "label": "unknown good"},
		{"id": "same-market", "owner": PLAYER_A, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_FARM, "good": "greens", "quantity": 1,
			"now": START, "reason": "invalid_route", "label": "same origin and destination"},
		{"id": "unknown-market", "owner": PLAYER_A, "origin": "moon",
			"destination": Market.LOCATION_HARBOR, "good": "greens", "quantity": 1,
			"now": START, "reason": "invalid_route", "label": "unknown market"},
		{"id": "zero-quantity", "owner": PLAYER_A, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR, "good": "greens", "quantity": 0,
			"now": START, "reason": "invalid_quantity", "label": "zero quantity"},
		{"id": "negative-quantity", "owner": PLAYER_A, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR, "good": "greens", "quantity": -1,
			"now": START, "reason": "invalid_quantity", "label": "negative quantity"},
		{"id": "fractional-quantity", "owner": PLAYER_A, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR, "good": "greens", "quantity": 1.5,
			"now": START, "reason": "invalid_quantity", "label": "fractional quantity"},
		{"id": "too-many", "owner": PLAYER_A, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR, "good": "greens",
			"quantity": Market.MAX_QUANTITY + 1, "now": START,
			"reason": "invalid_quantity", "label": "quantity above the order bound"},
		{"id": "bad-time", "owner": PLAYER_A, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR, "good": "greens", "quantity": 1,
			"now": -1.0, "reason": "invalid_time", "label": "negative UTC time"},
		{"id": "missing-goods", "owner": PLAYER_A, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR, "good": "radish", "quantity": 1,
			"now": START, "reason": "insufficient_goods", "label": "goods not in the bag"},
	]
	for entry: Dictionary in cases:
		var before: Dictionary = farm.snapshot()
		var result: Dictionary = farm.market_ship(str(entry.id), str(entry.owner),
			str(entry.origin), str(entry.destination), str(entry.good), entry.quantity,
			float(entry.now))
		_expect(not result.ok and result.reason == str(entry.reason),
			"Shipping refuses " + str(entry.label))
		_expect(farm.snapshot() == before,
			"A refused shipment leaves the live farm unchanged: " + str(entry.label))

	var poor: Farm = _fixture()
	_expect(poor.economy_pay("drain-c", PLAYER_C, PLAYER_A, 120, START).ok,
		"The insufficient-cash fixture removes C's whole balance")
	var poor_before: Dictionary = poor.snapshot()
	var unpaid: Dictionary = poor.market_ship("ship-poor", PLAYER_C,
		Market.LOCATION_FARM, Market.LOCATION_HARBOR, "greens", 1, START)
	_expect(not unpaid.ok and unpaid.reason == "insufficient_cash",
		"A shipment fee cannot be paid from an empty account")
	_expect(poor.snapshot() == poor_before,
		"A refused fee still leaves the goods and cash untouched")

	var no_account: Farm = _fixture()
	var raw: Dictionary = no_account.snapshot()
	raw.economy.accounts.erase(PLAYER_D)
	raw.bags[PLAYER_D] = {"greens": 1}
	var unopened := Farm.new()
	_expect(unopened.restore_snapshot(raw),
		"A player can hold goods without ever opening a cash account")
	_expect(unopened.market_ship("ship-unopened", PLAYER_D, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 1, START).reason == "unknown_account",
		"Shipping requires an account to pay the fee; it does not create one")


func _test_in_transit_cannot_be_resold() -> void:
	var farm: Farm = _fixture()
	var shipped: Dictionary = farm.market_ship("ship-a", PLAYER_A,
		Market.LOCATION_FARM, Market.LOCATION_HARBOR, "greens", 8, START)
	_expect(shipped.ok and shipped.status == Market.SHIPMENT_STATUS_TRANSIT \
		and shipped.quantity == 8 and shipped.fee == Market.SHIPMENT_FEE \
		and shipped.arrive_utc == ARRIVE,
		"Shipping moves eight greens into one in-transit row with a known arrival")
	_expect(farm.bag(PLAYER_A).greens == 0,
		"In-transit goods leave the owner's available bag")
	_expect(farm.market_shipment("ship-a").status == Market.SHIPMENT_STATUS_TRANSIT
		and farm.market_shipment("ship-a").delivery_id == "",
		"The shipment row carries no delivery until it actually arrives")
	_expect(farm.economy_cash(PLAYER_A) == 118,
		"The sender pays the flat fee from available cash")
	_expect(farm.economy_issued() == 358 and farm.economy_total_cash() == 358,
		"The shipping fee is burned from issued and total cash together")
	_expect_goods(farm, 24, "shipping goods into transit")

	var before: Dictionary = farm.snapshot()
	var resell: Dictionary = farm.market_place_order("sell-transit", PLAYER_A, "sell",
		"greens", 10, 1, START + HOUR, START)
	_expect(not resell.ok and resell.reason == "insufficient_goods",
		"In-transit goods cannot be escrowed by a sell order")
	_expect(farm.market_place_order("sell-transit-two", PLAYER_A, "sell", "greens", 10, 1,
		START + HOUR, START).reason == "insufficient_goods",
		"The same refusal holds without relying on the command ledger")
	_expect(farm.snapshot() == before,
		"Both refused sells leave the shipment and bags unchanged")

	var replay: Dictionary = farm.market_ship("ship-a", PLAYER_A,
		Market.LOCATION_FARM, Market.LOCATION_HARBOR, "greens", 8, START)
	_expect(replay.ok and replay.duplicate and replay.shipment_id == "ship-a",
		"Replaying the same shipment id returns the durable shipment")
	var conflict: Dictionary = farm.market_ship("ship-a", PLAYER_A,
		Market.LOCATION_FARM, Market.LOCATION_HARBOR, "greens", 7, START)
	_expect(not conflict.ok and conflict.reason == "command_conflict",
		"The same shipment id with another payload is a conflict")
	_expect(farm.market_ship("ship-again", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 1, START).reason == "insufficient_goods",
		"A new shipment id still cannot move goods that are already in transit")
	_expect(farm.snapshot() == before,
		"No retry or second shipment duplicates the in-transit goods")

	var evicted: Dictionary = before.duplicate(true)
	evicted.economy.command_results = {}
	var from_evicted := Farm.new()
	_expect(from_evicted.restore_snapshot(evicted),
		"The in-transit snapshot restores after the command window is lost")
	var evicted_before: Dictionary = from_evicted.snapshot()
	_expect(from_evicted.market_ship("ship-a", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 8, START).reason == "shipment_exists",
		"The durable shipment id still refuses a re-ship after eviction")
	_expect(from_evicted.snapshot() == evicted_before,
		"An evicted retry cannot re-escrow or re-charge the goods")

	# An order escrow and a shipment are both "not in the bag" but only the
	# order is released by cancel/expiry; in-transit goods must stay in transit.
	var expiring: Farm = _fixture()
	_expect(expiring.market_place_order("sell-two", PLAYER_A, "sell", "greens", 10, 2,
		START + 100.0, START).ok, "A rests two greens before shipping the rest")
	_expect(expiring.market_ship("ship-four", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 4, START).ok,
		"The sender ships four of the six remaining greens")
	_expect(expiring.bag(PLAYER_A).greens == 2
		and expiring.market_shipment("ship-four").quantity == 4,
		"Escrow and in-transit rows are separate deductions from the bag")
	var expired: Dictionary = expiring.market_expire(START + 100.0)
	_expect(expired.expired == 1 and expired.released_goods == {"greens": 2},
		"Order expiry releases only the order escrow")
	_expect(expiring.bag(PLAYER_A).greens == 4
		and expiring.market_shipment("ship-four").status == Market.SHIPMENT_STATUS_TRANSIT,
		"Expiry returns the escrow to the bag and leaves the shipment in transit")
	_expect_goods(expiring, 24, "order expiry beside an in-transit shipment")
	_expect(expiring.market_place_order("sell-five", PLAYER_A, "sell", "greens", 10, 5,
		START + HOUR, START).reason == "insufficient_goods",
		"Only the returned four are sellable; in-transit goods stay unavailable")

	var cancelling: Farm = _fixture()
	cancelling.market_place_order("sell-cancel", PLAYER_A, "sell", "greens", 10, 2,
		START + HOUR, START)
	cancelling.market_ship("ship-cancel", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 4, START)
	var cancelled: Dictionary = cancelling.market_cancel_order("cancel-escrow", PLAYER_A,
		"sell-cancel", START + 10.0)
	_expect(cancelled.ok and cancelled.amount == 2,
		"Cancel releases exactly the order escrow")
	_expect(cancelling.bag(PLAYER_A).greens == 4
		and cancelling.market_shipment("ship-cancel").status == Market.SHIPMENT_STATUS_TRANSIT,
		"Cancel returns order goods without touching the in-transit row")
	_expect_goods(cancelling, 24, "order cancel beside an in-transit shipment")


func _test_delivery_boundaries() -> void:
	var farm: Farm = _fixture()
	farm.market_ship("ship-three", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 3, START)
	var before: Dictionary = farm.snapshot()
	var early: Dictionary = farm.market_deliver(ARRIVE - 1.0)
	_expect(early.ok and early.count == 0 and farm.snapshot() == before,
		"One second before arrival nothing is delivered")
	_expect(farm.market_shipment("ship-three").status == Market.SHIPMENT_STATUS_TRANSIT
		and farm.bag(PLAYER_A).greens == 5,
		"The goods remain in transit and out of the bag before arrival")

	var at: Dictionary = farm.market_deliver(ARRIVE)
	_expect(at.ok and at.count == 1 and at.deliveries.size() == 1,
		"At the arrival second the shipment is delivered once")
	_expect(farm.market_shipment("ship-three").status == Market.SHIPMENT_STATUS_DELIVERED
		and farm.market_shipment("ship-three").delivered_utc == ARRIVE
		and farm.market_shipment("ship-three").delivery_id == "delivery_1",
		"The shipment row records the delivery time and durable event id")
	_expect(farm.bag(PLAYER_A).greens == 8,
		"Delivered goods return to the owner's bag")
	var event: Dictionary = farm.market_delivery("delivery_1")
	_expect(event.sequence == 1 and event.shipment_id == "ship-three"
		and event.owner == PLAYER_A and event.good == "greens"
		and event.quantity == 3 and event.origin == Market.LOCATION_FARM
		and event.destination == Market.LOCATION_HARBOR and event.at_utc == ARRIVE,
		"The delivery event is traceable to the shipment, owner, goods and route")
	_expect_goods(farm, 24, "delivery at the arrival boundary")
	_expect_conserved(farm, "delivery at the arrival boundary")

	var settled: Dictionary = farm.snapshot()
	var late: Dictionary = farm.market_deliver(ARRIVE + 1.0)
	_expect(late.ok and late.count == 0 and farm.snapshot() == settled,
		"After the first delivery a later sweep is a no-op")
	_expect(farm.market_deliveries().size() == 1,
		"One shipment produces exactly one durable delivery event")


func _test_delivery_events_and_replay() -> void:
	var farm: Farm = _fixture()
	farm.market_ship("ship-one", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 2, START)
	farm.market_ship("ship-two", PLAYER_B, Market.LOCATION_HARBOR,
		Market.LOCATION_FARM, "greens", 3, START + 100.0)
	var delivered: Dictionary = farm.market_deliver(START + 700.0)
	_expect(delivered.ok and delivered.count == 2,
		"One sweep delivers every shipment whose arrival has been reached")
	_expect(delivered.deliveries[0].id == "delivery_1"
		and delivered.deliveries[0].shipment_id == "ship-one"
		and delivered.deliveries[1].id == "delivery_2"
		and delivered.deliveries[1].shipment_id == "ship-two",
		"Delivery ids are unique and ordered by shipment sequence")
	_expect(farm.market_deliveries().size() == 2
		and farm.market_delivery("delivery_1").sequence == 1
		and farm.market_delivery("delivery_2").sequence == 2,
		"The durable delivery log exposes both events")
	_expect(farm.bag(PLAYER_A).greens == 8 and farm.bag(PLAYER_B).greens == 8,
		"Each owner receives its own delivered quantity")
	var settled: Dictionary = farm.snapshot()
	_expect(farm.market_deliver(START + 700.0).count == 0 and farm.snapshot() == settled,
		"Repeating the delivery sweep cannot deliver again")
	_expect_goods(farm, 24, "two delivered shipments")
	_expect_conserved(farm, "two delivered shipments")

	var bound: Farm = _fixture()
	bound.market_ship("ship-bound", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 2, START)
	var first: Dictionary = bound.market_deliver(ARRIVE, "deliver-command")
	_expect(first.ok and not first.duplicate and first.count == 1,
		"A command-bound delivery sweep records its accepted count")
	var after_first: Dictionary = bound.snapshot()
	var retry: Dictionary = bound.market_deliver(ARRIVE, "deliver-command")
	_expect(retry.ok and retry.duplicate and retry.count == 1
		and bound.snapshot() == after_first,
		"The same delivery id and UTC time replays without a second delivery")
	var conflict: Dictionary = bound.market_deliver(ARRIVE + 1.0, "deliver-command")
	_expect(not conflict.ok and conflict.reason == "command_conflict"
		and conflict.duplicate and bound.snapshot() == after_first,
		"The same delivery id at another time is a conflict with no change")
	var bad_id: Dictionary = bound.market_deliver(ARRIVE,
		"x".repeat(Market.MAX_COMMAND_ID_LENGTH + 1))
	_expect(not bad_id.ok and bad_id.reason == "invalid_command",
		"An overlong delivery id is refused")

	var evicted: Dictionary = after_first.duplicate(true)
	evicted.economy.command_results = {}
	var from_evicted := Farm.new()
	_expect(from_evicted.restore_snapshot(evicted),
		"The delivered snapshot restores after the command window is lost")
	var after: Dictionary = from_evicted.market_deliver(ARRIVE, "deliver-command")
	_expect(after.ok and not after.duplicate and after.count == 0,
		"After eviction the same delivery id finds nothing left to deliver")
	_expect(from_evicted.market_deliveries().size() == 1
		and from_evicted.market_delivery("delivery_1").shipment_id == "ship-bound",
		"The evicted retry still leaves exactly one delivery event")
	_expect(from_evicted.bag(PLAYER_A).greens == 8
		and from_evicted.economy_total_cash() == from_evicted.economy_issued(),
		"The evicted retry cannot deliver or burn a second time")


func _test_fee_and_goods_conservation() -> void:
	var farm: Farm = _fixture()
	_expect(farm.market_ship("ship-a1", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 2, START).ok, "A ships two greens")
	_expect(farm.market_ship("ship-b1", PLAYER_B, Market.LOCATION_HARBOR,
		Market.LOCATION_FARM, "greens", 3, START).ok, "B ships three greens back")
	_expect(farm.economy_issued() == 356 and farm.economy_total_cash() == 356,
		"Two shipments burn two fees from issued and total cash")
	_expect(farm.economy_cash(PLAYER_A) == 118 and farm.economy_cash(PLAYER_B) == 118,
		"Each sender pays exactly one flat fee")
	_expect_goods(farm, 24, "two in-transit shipments")
	_expect_conserved(farm, "two in-transit shipments")

	farm.market_deliver(ARRIVE)
	_expect(farm.economy_issued() == 356 and farm.economy_total_cash() == 356,
		"Delivery moves goods without changing money")
	_expect_goods(farm, 24, "two delivered shipments")
	_expect(farm.bag(PLAYER_A).greens == 8 and farm.bag(PLAYER_B).greens == 8,
		"Both delivered quantities return to their own bags")

	var empty: Farm = _fixture()
	empty.market_ship("ship-empty", PLAYER_C, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 8, START)
	_expect(empty.market_ship("ship-second", PLAYER_C, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 1, START).reason == "insufficient_goods",
		"A second shipment cannot spend the same baskets")
	_expect(empty.market_place_order("sell-empty", PLAYER_C, "sell", "greens", 10, 1,
		START + HOUR, START).reason == "insufficient_goods",
		"Nor can an order escrow them")


func _test_order_independence() -> void:
	# A due shipment, an open order pair, an expiring order and a cancellable
	# order all touch different rows. Delivery must commute with the matching,
	# cancel and expiry paths because it only moves the shipment's own goods.
	var base := _fixture()
	base.market_place_order("sell-a", PLAYER_A, "sell", "greens", 10, 2,
		START + HOUR, START)
	base.market_ship("ship-a", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 2, START)
	base.market_place_order("sell-extra", PLAYER_A, "sell", "greens", 20, 1,
		START + HOUR, START)
	base.market_place_order("sell-c-expiring", PLAYER_C, "sell", "greens", 10, 1,
		START + 100.0, START)
	base.market_place_order("buy-b", PLAYER_B, "buy", "greens", 10, 3,
		START + HOUR, START)
	var snapshot: Dictionary = base.snapshot()

	var deliver_first := Farm.new()
	_expect(deliver_first.restore_snapshot(snapshot), "The deliver-first copy restores")
	var d1: Dictionary = deliver_first.market_deliver(START + 700.0)
	var c1: Dictionary = deliver_first.market_cancel_order("cancel-extra", PLAYER_A,
		"sell-extra", START + 700.0)
	var m1: Dictionary = deliver_first.market_match(START + 700.0)
	var e1: Dictionary = deliver_first.market_expire(START + 700.0)
	_expect(d1.count == 1 and c1.ok and m1.count == 1 and e1.expired == 1,
		"The deliver-first ordering performs all four independent changes")

	var expire_first := Farm.new()
	_expect(expire_first.restore_snapshot(snapshot), "The expire-first copy restores")
	var e2: Dictionary = expire_first.market_expire(START + 700.0)
	var m2: Dictionary = expire_first.market_match(START + 700.0)
	var c2: Dictionary = expire_first.market_cancel_order("cancel-extra", PLAYER_A,
		"sell-extra", START + 700.0)
	var d2: Dictionary = expire_first.market_deliver(START + 700.0)
	_expect(e2.expired == 1 and m2.count == 1 and c2.ok and d2.count == 1,
		"The expire-first ordering performs the same four changes")
	_expect(deliver_first.snapshot() == expire_first.snapshot(),
		"Delivery commutes with matching, cancel and expiry at one UTC instant")
	_expect(deliver_first.market_trade("trade_1").quantity == 2
		and deliver_first.market_order("sell-c-expiring").status == Market.STATUS_EXPIRED
		and deliver_first.market_order("sell-extra").status == Market.STATUS_CANCELLED
		and deliver_first.market_shipment("ship-a").status == Market.SHIPMENT_STATUS_DELIVERED,
		"The final rows show one fill, one expiry, one cancel and one delivery")
	_expect(deliver_first.bag(PLAYER_A).greens == 6
		and deliver_first.bag(PLAYER_B).greens == 10
		and deliver_first.bag(PLAYER_C).greens == 8,
		"Every basket lands where the four independent paths put it")
	_expect_goods(deliver_first, 24, "delivery beside match, cancel and expiry")
	_expect_conserved(deliver_first, "delivery beside match, cancel and expiry")

	var match_then_deliver := Farm.new()
	var deliver_then_match := Farm.new()
	match_then_deliver.restore_snapshot(snapshot)
	deliver_then_match.restore_snapshot(snapshot)
	match_then_deliver.market_match(START + 700.0)
	deliver_then_match.market_deliver(START + 700.0)
	match_then_deliver.market_deliver(START + 700.0)
	deliver_then_match.market_match(START + 700.0)
	_expect(match_then_deliver.snapshot() == deliver_then_match.snapshot(),
		"Matching and delivery can be applied in either order at one instant")


func _test_save_reopen() -> void:
	var farm: Farm = _fixture()
	farm.market_ship("ship-one", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 2, START)
	farm.market_ship("ship-two", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 3, START)
	farm.market_deliver(ARRIVE)
	farm.market_ship("ship-three", PLAYER_A, Market.LOCATION_HARBOR,
		Market.LOCATION_FARM, "greens", 1, START + 700.0)
	var store := FarmStore.new(test_root.path_join("reopen"))
	_expect(store.load_state().kind == "missing", "The isolated reopen directory is admitted")
	_expect(store.save(farm.snapshot(), Decorations.new().snapshot()).ok,
		"The in-transit snapshot saves")
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok, "The in-transit snapshot loads")
	var reopened := Farm.new()
	_expect(reopened.restore_snapshot(loaded.farm),
		"The in-transit snapshot restores through the farm validator")
	_expect(reopened.snapshot() == farm.snapshot(),
		"Shipments, delivery events, fee burn and sequences survive the round trip")
	_expect(reopened.market_shipments().size() == 3
		and reopened.market_deliveries().size() == 2
		and reopened.market_shipment("ship-three").sequence is int
		and reopened.market_shipment("ship-three").depart_utc is float
		and reopened.market_delivery("delivery_1").quantity is int,
		"Reopened rows resolve with normalized counts and floats")
	_expect(reopened.market_shipment("ship-three").status == Market.SHIPMENT_STATUS_TRANSIT
		and reopened.market_shipment("ship-one").status == Market.SHIPMENT_STATUS_DELIVERED,
		"Delivered and in-transit states survive the restart")
	_expect(reopened.market_deliver(ARRIVE).count == 0,
		"A repeated early sweep after reopening delivers nothing")
	_expect(reopened.market_deliver(ARRIVE + 700.0).count == 1,
		"The remaining in-transit shipment can still arrive after reopening")
	_expect_goods(reopened, 24, "delivery after a restart")
	_expect_conserved(reopened, "delivery after a restart")

	var evicted: Dictionary = reopened.snapshot()
	evicted.economy.command_results = {}
	var from_evicted := Farm.new()
	_expect(from_evicted.restore_snapshot(evicted),
		"A delivered snapshot with an evicted ledger restores")
	_expect(from_evicted.market_ship("ship-one", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 2, START).reason == "shipment_exists",
		"An evicted shipment id cannot move the same goods again")
	_expect(from_evicted.market_delivery("delivery_1").shipment_id == "ship-one"
		and from_evicted.market_delivery("delivery_2").shipment_id == "ship-two",
		"The durable delivery ids still resolve after eviction")


func _test_snapshot_validation() -> void:
	var farm: Farm = _fixture()
	farm.market_ship("ship-1", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 2, START)
	farm.market_deliver(ARRIVE)
	farm.market_ship("ship-2", PLAYER_B, Market.LOCATION_HARBOR,
		Market.LOCATION_FARM, "greens", 1, START + 700.0)
	var original: Dictionary = farm.snapshot()
	var json_value: Dictionary = JSON.parse_string(JSON.stringify(original))
	var restored := Farm.new()
	_expect(restored.restore_snapshot(json_value),
		"A JSON logistics snapshot restores")
	_expect(restored.snapshot() == original,
		"JSON number normalization keeps the logistics snapshot identical")

	var corruptions: Array[Dictionary] = []
	var candidate: Dictionary = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].extra = true
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].id = "ship-other"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].owner = Market.MERCHANT
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].owner = "@world"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].good = "luffa"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].quantity = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].quantity = Market.MAX_QUANTITY + 1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].destination = Market.LOCATION_HARBOR
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].origin = "moon"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].fee = 3
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].arrive_utc += 1.0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].depart_utc = -1.0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].status = "lost"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].delivery_id = "delivery_9"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].sequence = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipment_sequence = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments = []
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.deliveries["delivery_1"].extra = true
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.deliveries["delivery_1"].id = "delivery_9"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.deliveries["delivery_1"].shipment_id = "ship-2"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.deliveries["delivery_1"].quantity = 1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.deliveries["delivery_1"].owner = PLAYER_C
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.deliveries["delivery_1"].at_utc += 1.0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.deliveries["delivery_1"].sequence = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.delivery_sequence = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	var duplicate_delivery: Dictionary = candidate.economy.market.deliveries["delivery_1"].duplicate(true)
	duplicate_delivery.id = "delivery_2"
	duplicate_delivery.sequence = 2
	candidate.economy.market.deliveries["delivery_2"] = duplicate_delivery
	candidate.economy.market.delivery_sequence = 2
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.shipments["ship-2"].delivered_utc = ARRIVE
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.erase("delivery_sequence")
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.market.erase("deliveries")
	corruptions.append(candidate)
	for broken: Dictionary in corruptions:
		_expect(not farm.restore_snapshot(broken) and farm.snapshot() == original,
			"Malformed logistics state is rejected without changing the live farm")

	var legacy: Dictionary = _fixture().snapshot()
	for key: String in Market.LOGISTICS_KEYS:
		legacy.economy.market.erase(key)
	var legacy_restored := Farm.new()
	_expect(legacy_restored.restore_snapshot(legacy),
		"An M7-03 market without the shipment ledger still restores")
	_expect(legacy_restored.market_snapshot().shipments.is_empty()
		and legacy_restored.market_snapshot().deliveries.is_empty()
		and legacy_restored.market_snapshot().shipment_sequence == 0,
		"A missing shipment ledger becomes empty without touching orders or trades")

	var oldest: Dictionary = _fixture().snapshot()
	for key: String in Market.LOGISTICS_KEYS:
		oldest.economy.market.erase(key)
	oldest.economy.market.erase("trades")
	oldest.economy.market.erase("trade_sequence")
	var oldest_restored := Farm.new()
	_expect(oldest_restored.restore_snapshot(oldest),
		"An M7-02 market without trade or shipment ledgers still restores")
	_expect(oldest_restored.market_trades().is_empty()
		and oldest_restored.market_shipments().is_empty(),
		"Both missing logs default to empty without a migration branch")

	var partial: Dictionary = _fixture().snapshot()
	partial.economy.market.erase("delivery_sequence")
	_expect(not Farm.new().restore_snapshot(partial),
		"A partially present shipment ledger is rejected, not defaulted")


func _fixture() -> Farm:
	# Three players each start with eight greens grown on real cells and 120
	# COIN, so every shipment below has a real source and the goods invariant can
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
	for shipment: Dictionary in farm.market_shipments():
		if str(shipment.good) == good_id \
				and str(shipment.status) == Market.SHIPMENT_STATUS_TRANSIT:
			total += int(shipment.quantity)
	return total


func _expect_goods(farm: Farm, expected: int, label: String) -> void:
	_expect(_goods_total(farm, "greens") == expected,
		"Pockets + escrow + in transit still hold " + str(expected) + " greens after " + label)


func _expect_conserved(farm: Farm, label: String) -> void:
	_expect(farm.economy_total_cash() == farm.economy_issued(),
		"Total cash equals net issued after " + label)
	_expect(farm.economy_issued() >= 0,
		"Issued cash never goes negative after " + label)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
