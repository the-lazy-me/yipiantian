extends SceneTree
## 市场面板作为视图：它只根据市场视图决定显示什么，并把点击变成下单、撤单、
## 发货和交付意图；余额、托管、库存和路线是否足够由权威规则决定。
##
## 没有网络和存档：视图直接构造，面板不在这里修改任何规则状态。

const MarketPanel = preload("res://ui/market_panel.gd")
const Catalog = preload("res://farm/economy_catalog.gd")
const Market = preload("res://farm/market_state.gd")

const NOW: float = 1800000000.0
const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"

var panel: MarketPanel
var events: Array = []
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = MarketPanel.new()
	panel.name = "Market"
	root.add_child(panel)
	panel.order_requested.connect(func(side: String, good_id: String, price: int, quantity: int,
			expires_utc: float) -> void:
		events.append({"action": "order", "side": side, "good": good_id, "price": price,
			"quantity": quantity, "expires": expires_utc}))
	panel.cancel_requested.connect(func(order_id: String) -> void:
		events.append({"action": "cancel", "order_id": order_id}))
	panel.ship_requested.connect(func(good_id: String, quantity: int, origin: String,
			destination: String) -> void:
		events.append({"action": "ship", "good": good_id, "quantity": quantity,
			"origin": origin, "destination": destination}))
	panel.deliver_requested.connect(func() -> void: events.append({"action": "deliver"}))
	panel.refresh_requested.connect(func() -> void: events.append({"action": "refresh"}))
	panel.closed.connect(func() -> void: events.append({"action": "closed"}))
	await process_frame
	_expect(not panel.is_open(), "The panel starts closed until the player opens it")

	var view: Dictionary = _view(false)
	panel.present(view)
	var wallet: Label = panel.find_child("Wallet", true, false) as Label
	_expect(wallet != null and wallet.text.contains("118") and wallet.text.contains("20")
		and wallet.text.contains("在途 2 件"),
		"The wallet shows available cash, escrow and goods in transit")
	_expect(panel.find_child("Quote_greens_Bid", true, false) != null,
		"Every priced good has a merchant bid")
	_expect(panel.find_child("Quote_garlic_SellCapacity", true, false) != null,
		"Every priced good has both merchant capacities")
	var quote_count: int = 0
	for good_id: String in Catalog.goods_ids():
		if panel.find_child("Quote_%s_Ask" % good_id, true, false) != null:
			quote_count += 1
	_expect(quote_count == Catalog.goods_ids().size(),
		"All six goods are quoted in the same table")
	var greens_bid: Label = panel.find_child("Quote_greens_Bid", true, false) as Label
	_expect(greens_bid != null and greens_bid.text == "4",
		"The bid shown is the one the market view carries")
	var quoted_price: SpinBox = panel.find_child("OrderPrice", true, false) as SpinBox
	_expect(quoted_price != null
		and int(quoted_price.value) == int((view.quotes.greens as Dictionary).get("ask", 0)),
		"The order form starts from the current merchant ask")

	var partial: Label = panel.find_child("Order_order-a", true, false) as Label
	_expect(partial != null and partial.text.contains("部分成交") and partial.text.contains("已成交 1"),
		"A partially filled order says so and keeps the filled count")
	_expect(panel.find_child("Cancel_order-a", true, false) != null,
		"My open order offers cancellation")
	_expect(panel.find_child("Cancel_order-b", true, false) != null,
		"A second open order of mine also offers cancellation")
	var filled: Label = panel.find_child("Order_order-c", true, false) as Label
	_expect(filled != null and filled.text.contains("商人") and filled.text.contains("已成交"),
		"A merchant order is labelled and its filled status is visible")
	_expect(panel.find_child("Cancel_order-c", true, false) == null,
		"A merchant order offers me no cancellation")
	var cancelled: Label = panel.find_child("Order_order-d", true, false) as Label
	_expect(cancelled != null and cancelled.text.contains("他人") and cancelled.text.contains("已撤销"),
		"Another player's closed order stays visible without actions")
	_expect(panel.find_child("Cancel_order-d", true, false) == null,
		"Another player's order offers me no cancellation")

	var transit: Label = panel.find_child("Shipment_ship-a", true, false) as Label
	_expect(transit != null and transit.text.contains("在途") and transit.text.contains("5 分钟"),
		"An in-transit shipment shows its remaining travel time")
	var delivered: Label = panel.find_child("Shipment_ship-b", true, false) as Label
	_expect(delivered != null and delivered.text.contains("已交付"),
		"A delivered shipment says so")
	_expect(panel.find_child("Delivery_delivery_1", true, false) != null,
		"A delivery event is listed after the shipments")

	var side: OptionButton = panel.find_child("OrderSide", true, false) as OptionButton
	var good: OptionButton = panel.find_child("OrderGood", true, false) as OptionButton
	var price: SpinBox = panel.find_child("OrderPrice", true, false) as SpinBox
	var quantity: SpinBox = panel.find_child("OrderQuantity", true, false) as SpinBox
	var expires: SpinBox = panel.find_child("OrderExpires", true, false) as SpinBox
	side.select(1)
	good.select(2)
	price.value = 17
	quantity.value = 2
	expires.value = 30
	var place: Button = panel.find_child("PlaceOrder", true, false) as Button
	place.pressed.emit()
	_expect(events.size() == 1 and events[0].action == "order" and events[0].side == "sell"
		and events[0].good == "radish" and events[0].price == 17 and events[0].quantity == 2
		and is_equal_approx(float(events[0].expires), NOW + 1800.0),
		"The order intent carries the chosen side, good, price, quantity and UTC expiry")

	var cancel: Button = panel.find_child("Cancel_order-a", true, false) as Button
	cancel.pressed.emit()
	_expect(events.size() == 2 and events[1].action == "cancel" and events[1].order_id == "order-a",
		"Cancelling names the order it belongs to")

	var ship_good: OptionButton = panel.find_child("ShipGood", true, false) as OptionButton
	var ship_quantity: SpinBox = panel.find_child("ShipQuantity", true, false) as SpinBox
	var ship_origin: OptionButton = panel.find_child("ShipOrigin", true, false) as OptionButton
	var ship_destination: OptionButton = panel.find_child("ShipDestination", true, false) as OptionButton
	ship_good.select(3)
	ship_quantity.value = 3
	ship_origin.select(1)
	ship_destination.select(0)
	var ship: Button = panel.find_child("Ship", true, false) as Button
	ship.pressed.emit()
	_expect(events.size() == 3 and events[2].action == "ship" and events[2].good == "carrot"
		and events[2].quantity == 3 and events[2].origin == "harbor_market"
		and events[2].destination == "farm_market",
		"The shipping intent carries the goods, quantity and route")
	var deliver: Button = panel.find_child("Deliver", true, false) as Button
	deliver.pressed.emit()
	_expect(events.size() == 4 and events[3].action == "deliver",
		"The panel emits one delivery intent")
	var refresh: Button = panel.find_child("Refresh", true, false) as Button
	refresh.pressed.emit()
	_expect(events.size() == 5 and events[4].action == "refresh",
		"The panel can ask for a fresh view")

	var before: String = wallet.text
	panel.show_status("现金不够。")
	_expect(wallet.text == before, "A refusal message does not change the displayed wallet")
	_expect(panel.find_child("Status", true, false) != null
		and (panel.find_child("Status", true, false) as Label).text.contains("现金不够"),
		"An authority refusal is shown as a Chinese reason")

	panel.present(_view(true))
	var read_only: Label = panel.find_child("ReadOnly", true, false) as Label
	_expect(read_only != null and read_only.visible and read_only.text.contains("只读"),
		"The shared world says the market is read-only")
	_expect((panel.find_child("PlaceOrder", true, false) as Button).disabled,
		"Read-only mode disables placing orders")
	_expect((panel.find_child("Ship", true, false) as Button).disabled,
		"Read-only mode disables shipping")
	_expect((panel.find_child("Deliver", true, false) as Button).disabled,
		"Read-only mode disables delivery")
	_expect(panel.find_child("Cancel_order-a", true, false) == null,
		"Read-only mode offers no cancellation")

	panel.show()
	_expect(panel.is_open(), "Showing the panel makes it open")
	var close: Button = panel.find_child("Close", true, false) as Button
	close.pressed.emit()
	_expect(not panel.is_open() and events.back().action == "closed",
		"Closing hides the panel and emits one closed event")
	_finish()


func _view(shared: bool) -> Dictionary:
	var economy: Dictionary = {"market": {"merchant": {
		"opened": true, "cash": 600,
		"goods": {"greens": 2, "spinach": 0, "radish": 0, "carrot": 0, "celery": 0, "garlic": 0},
	}}}
	var quotes: Dictionary = Market.quotes(economy)
	return {
		"now_utc": NOW,
		"owner": ALICE,
		"cash": 118,
		"goods": 4,
		"escrow_cash": 20,
		"escrow_goods": 1,
		"in_transit": 2,
		"quotes": quotes,
		"orders": [
			{"id": "order-a", "owner": ALICE, "side": "buy", "good": "greens", "price": 10,
				"quantity": 3, "remaining": 2, "filled": 1, "reserved": 20, "sequence": 1,
				"created_utc": NOW - 100.0, "expires_utc": NOW + 600.0, "status": "open",
				"released": 0, "closed_by": "", "closed_utc": 0.0},
			{"id": "order-b", "owner": ALICE, "side": "sell", "good": "garlic", "price": 12,
				"quantity": 1, "remaining": 1, "filled": 0, "reserved": 1, "sequence": 2,
				"created_utc": NOW - 80.0, "expires_utc": NOW + 600.0, "status": "open",
				"released": 0, "closed_by": "", "closed_utc": 0.0},
			{"id": "order-c", "owner": Market.MERCHANT, "side": "sell", "good": "greens",
				"price": 7, "quantity": 1, "remaining": 0, "filled": 1, "reserved": 0,
				"sequence": 3, "created_utc": NOW - 60.0, "expires_utc": NOW + 600.0,
				"status": "filled", "released": 0, "closed_by": "", "closed_utc": NOW},
			{"id": "order-d", "owner": BOB, "side": "buy", "good": "carrot", "price": 20,
				"quantity": 2, "remaining": 2, "filled": 0, "reserved": 40, "sequence": 4,
				"created_utc": NOW - 40.0, "expires_utc": NOW + 600.0, "status": "cancelled",
				"released": 40, "closed_by": "cancel-b", "closed_utc": NOW},
		],
		"shipments": [
			{"id": "ship-a", "sequence": 1, "owner": ALICE, "good": "radish", "quantity": 2,
				"origin": "farm_market", "destination": "harbor_market", "fee": 2,
				"depart_utc": NOW - 300.0, "arrive_utc": NOW + 300.0,
				"status": "in_transit", "delivered_utc": 0.0, "delivery_id": ""},
			{"id": "ship-b", "sequence": 2, "owner": ALICE, "good": "greens", "quantity": 1,
				"origin": "harbor_market", "destination": "farm_market", "fee": 2,
				"depart_utc": NOW - 900.0, "arrive_utc": NOW - 300.0,
				"status": "delivered", "delivered_utc": NOW - 300.0,
				"delivery_id": "delivery_1"},
		],
		"deliveries": [
			{"id": "delivery_1", "sequence": 1, "shipment_id": "ship-b", "owner": ALICE,
				"good": "greens", "quantity": 1, "origin": "harbor_market",
				"destination": "farm_market", "at_utc": NOW - 300.0},
		],
		"routes": [
			{"origin": "farm_market", "destination": "harbor_market", "fee": 2,
				"delivery_seconds": 600.0},
		],
		"read_only": shared,
		"read_only_reason": "联机世界暂只读：市场命令尚未接入网络权限。" if shared else "",
	}


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("MARKET_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
