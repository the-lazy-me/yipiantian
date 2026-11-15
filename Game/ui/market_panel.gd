extends CanvasLayer
## 市场面板：把权威同步来的市场视图摆出来，并把点击变成下单、撤单、发货和
## 交付意图。
##
## 面板不判断余额、库存、托管或路线是否足够；这些规则在 FarmState 里，这里
## 只根据视图决定显示什么。因此没有网络和存档也能测。
##
## 视图整份替换，面板不合并增量，也不乐观修改余额。

signal order_requested(side: String, good_id: String, price: int, quantity: int, expires_utc: float)
signal cancel_requested(order_id: String)
signal ship_requested(good_id: String, quantity: int, origin: String, destination: String)
signal deliver_requested
signal refresh_requested
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const Catalog = preload("res://farm/economy_catalog.gd")
const Market = preload("res://farm/market_state.gd")
const INK := FarmTheme.INK
const LOCATION_NAMES := {"farm_market": "农田市场", "harbor_market": "港口市场"}

var view: Dictionary = {}
var read_only: bool = false
## The shared world's authority clock delivers arrived shipments on its own, so
## the manual delivery button is hidden instead of inviting an action nobody
## needs to take.
var auto_delivery: bool = false
var now_utc: float = 0.0
var my_id: String = ""

var _wallet: Label
var _status: Label
var _read_only: Label
var _root: Control
var _focus_before: Control
## A status written on purpose (an opening summary or an authority refusal)
## survives opening the panel; a stale one is cleared by the next open.
## A message written while the panel is hidden belongs to the next open.
var _status_pending: bool = false
var _quotes: GridContainer
var _orders: VBoxContainer
var _shipments: VBoxContainer
var _deliveries: VBoxContainer
var _side: OptionButton
var _good: OptionButton
var _price: SpinBox
var _quantity: SpinBox
var _expires: SpinBox
var _place: Button
var _ship_good: OptionButton
var _ship_quantity: SpinBox
var _ship_origin: OptionButton
var _ship_destination: OptionButton
var _ship_hint: Label
var _ship: Button
var _deliver: Button
var _deliver_hint: Label
var _refresh: Button
## Last price the panel filled in from a quote. A price the player typed is left
## alone when a refreshed view arrives.
var _auto_price: int = 1
## Inputs that stop accepting changes while the shared world is read-only.
var _editable: Array[Control] = []


func _ready() -> void:
	layer = 23
	var root := Control.new()
	_root = root
	root.name = "Market"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = FarmTheme.create()
	add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0.08, 0.1, 0.09, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var paper := PanelContainer.new()
	paper.custom_minimum_size = Vector2(760, 560)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	paper.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	column.add_child(header)
	var title := Label.new()
	title.text = "市场"
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_refresh = _button(header, "刷新", 84.0)
	_refresh.name = "Refresh"
	_refresh.pressed.connect(func() -> void:
		_clear_status()
		refresh_requested.emit())
	var close := _button(header, "收起", 84.0)
	close.name = "Close"
	close.pressed.connect(_close)
	_wallet = Label.new()
	_wallet.name = "Wallet"
	_wallet.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_wallet)
	_read_only = Label.new()
	_read_only.name = "ReadOnly"
	_read_only.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_read_only.visible = false
	column.add_child(_read_only)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	scroll.add_child(body)
	_build_quotes(body)
	_build_order_form(body)
	_orders = _section(body, "订单")
	_build_ship_form(body)
	_shipments = _section(body, "发货")
	_deliveries = _section(body, "交付记录")
	visibility_changed.connect(_on_visibility_changed)
	hide()


## Rebuilds from the authoritative market view. `read_only` is a view fact the
## scene decides from the world's role: members may submit commands, visitors
## may only read.
func present(next_view: Dictionary) -> void:
	var focus_key: String = FarmTheme.focus_key_within(_root)
	view = next_view.duplicate(true)
	now_utc = float(view.get("now_utc", 0.0))
	my_id = str(view.get("owner", ""))
	read_only = bool(view.get("read_only", false))
	auto_delivery = bool(view.get("auto_delivery", false))
	_wallet.text = _wallet_text()
	_read_only.visible = read_only
	_read_only.text = str(view.get("read_only_reason", "")) if read_only else ""
	# A refresh keeps the last success or refusal; opening clears it unless the
	# game wrote it while the panel was closed. The read-only reason has its own
	# label.
	_fill_quotes()
	_fill_orders()
	_fill_shipments()
	_fill_deliveries()
	# Keep a price the player typed; only follow the quote when the field still
	# holds the previous automatic value.
	if int(round(_price.value)) == _auto_price:
		_sync_price()
	_deliver.visible = not auto_delivery
	_deliver_hint.text = "货物到达后由世界自动入袋，无需手动交付。" if auto_delivery else ""
	_set_editable(not read_only)
	_update_ship_hint()
	if visible:
		FarmTheme.wrap_focus(_root, focus_key)


func show_status(text: String) -> void:
	_status.text = text
	_status_pending = not visible


func is_open() -> bool:
	return visible


func close() -> void:
	hide()
	closed.emit()


func is_popup_open() -> bool:
	for option: OptionButton in [_side, _good, _ship_good, _ship_origin, _ship_destination]:
		if option != null and option.get_popup().visible:
			return true
	for spin: SpinBox in [_price, _quantity, _expires, _ship_quantity]:
		if spin != null and spin.get_line_edit().has_focus():
			return true
	return false


func _on_visibility_changed() -> void:
	if visible:
		if _focus_before == null and is_inside_tree():
			_focus_before = get_viewport().gui_get_focus_owner()
		# A message written while hidden belongs to this open; a stale one goes.
		if not _status_pending:
			_status.text = ""
		_status_pending = false
		# Visibility propagates after this signal, so take focus on the next idle.
		_focus_after_show.call_deferred()
	else:
		if _focus_before != null and is_instance_valid(_focus_before) and _focus_before.is_inside_tree():
			_focus_before.grab_focus()
		_focus_before = null


func _focus_after_show() -> void:
	if visible:
		FarmTheme.wrap_focus(_root)


func _clear_status() -> void:
	_status.text = ""
	_status_pending = false


func _input(event: InputEvent) -> void:
	# Main handles Esc for the whole panel; while a dropdown is open or a field is
	# being edited, the first Esc belongs to that control instead.
	if not visible or not (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE):
		return
	if _dismiss_popup():
		get_viewport().set_input_as_handled()


func _dismiss_popup() -> bool:
	var dismissed: bool = false
	for option: OptionButton in [_side, _good, _ship_good, _ship_origin, _ship_destination]:
		if option != null and option.get_popup().visible:
			option.get_popup().hide()
			dismissed = true
	for spin: SpinBox in [_price, _quantity, _expires, _ship_quantity]:
		if spin != null and spin.get_line_edit().has_focus():
			spin.get_line_edit().release_focus()
			dismissed = true
	return dismissed


func _wallet_text() -> String:
	return "现金 %d COIN · 口袋 %d 件 · 托管 %d COIN / %d 件 · 在途 %d 件" % [
		int(view.get("cash", 0)), int(view.get("goods", 0)),
		int(view.get("escrow_cash", 0)), int(view.get("escrow_goods", 0)),
		int(view.get("in_transit", 0)),
	]


func _build_quotes(parent: Control) -> void:
	var heading := _heading(parent, "商人报价")
	heading.name = "QuotesHeading"
	_quotes = GridContainer.new()
	_quotes.name = "Quotes"
	_quotes.columns = 5
	_quotes.add_theme_constant_override("h_separation", 18)
	parent.add_child(_quotes)


func _fill_quotes() -> void:
	_clear(_quotes)
	for text: String in ["商品", "收购", "出售", "可收", "可售"]:
		_cell(_quotes, text, "")
	var quotes: Dictionary = view.get("quotes", {}) as Dictionary
	for good_id: String in Catalog.goods_ids():
		var quote: Dictionary = quotes.get(good_id, {}) as Dictionary
		var name: String = str(Catalog.definition(good_id).get("name", good_id))
		_cell(_quotes, name, "Quote_%s_Name" % good_id)
		_cell(_quotes, str(int(quote.get("bid", 0))), "Quote_%s_Bid" % good_id)
		_cell(_quotes, str(int(quote.get("ask", 0))), "Quote_%s_Ask" % good_id)
		_cell(_quotes, str(int(quote.get("buy_capacity", 0))), "Quote_%s_BuyCapacity" % good_id)
		_cell(_quotes, str(int(quote.get("sell_capacity", 0))), "Quote_%s_SellCapacity" % good_id)


func _build_order_form(parent: Control) -> void:
	_heading(parent, "下单")
	var first := HBoxContainer.new()
	first.add_theme_constant_override("separation", 8)
	parent.add_child(first)
	_side = OptionButton.new()
	_side.name = "OrderSide"
	_side.add_item("买入")
	_side.set_item_metadata(0, Market.SIDE_BUY)
	_side.add_item("卖出")
	_side.set_item_metadata(1, Market.SIDE_SELL)
	FarmTheme.configure_option(_side)
	_label(first, "方向")
	first.add_child(_side)
	_label(first, "商品")
	_good = OptionButton.new()
	_good.name = "OrderGood"
	for good_id: String in Catalog.goods_ids():
		_good.add_item(str(Catalog.definition(good_id).get("name", good_id)))
		_good.set_item_metadata(_good.item_count - 1, good_id)
	FarmTheme.configure_option(_good)
	first.add_child(_good)
	var second := HBoxContainer.new()
	second.add_theme_constant_override("separation", 8)
	parent.add_child(second)
	_price = _spin(second, "OrderPrice", "价格", 1, Market.MAX_PRICE, 1)
	_quantity = _spin(second, "OrderQuantity", "数量", 1, Market.MAX_QUANTITY, 1)
	_expires = _spin(second, "OrderExpires", "有效期", 1, 1440, 60)
	_expires.suffix = " 分钟"
	_place = _button(second, "下单", 96.0)
	_place.name = "PlaceOrder"
	_side.item_selected.connect(func(_index: int) -> void: _sync_price())
	_good.item_selected.connect(func(_index: int) -> void: _sync_price())
	_place.pressed.connect(_emit_order)
	_editable.append(_side)
	_editable.append(_good)
	_editable.append(_price)
	_editable.append(_quantity)
	_editable.append(_expires)
	_editable.append(_place)
	_sync_price()


func _build_ship_form(parent: Control) -> void:
	_heading(parent, "发货")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	_label(row, "商品")
	_ship_good = OptionButton.new()
	_ship_good.name = "ShipGood"
	for good_id: String in Catalog.goods_ids():
		_ship_good.add_item(str(Catalog.definition(good_id).get("name", good_id)))
		_ship_good.set_item_metadata(_ship_good.item_count - 1, good_id)
	FarmTheme.configure_option(_ship_good)
	row.add_child(_ship_good)
	_ship_quantity = SpinBox.new()
	_ship_quantity.name = "ShipQuantity"
	_ship_quantity.min_value = 1
	_ship_quantity.max_value = Market.MAX_QUANTITY
	_ship_quantity.step = 1
	_ship_quantity.value = 1
	_label(row, "数量")
	row.add_child(_ship_quantity)
	var route := HBoxContainer.new()
	route.add_theme_constant_override("separation", 8)
	parent.add_child(route)
	_label(route, "从")
	_ship_origin = OptionButton.new()
	_ship_origin.name = "ShipOrigin"
	_ship_destination = OptionButton.new()
	_ship_destination.name = "ShipDestination"
	for location: String in Market.LOCATIONS:
		_ship_origin.add_item(LOCATION_NAMES.get(location, location))
		_ship_origin.set_item_metadata(_ship_origin.item_count - 1, location)
		_ship_destination.add_item(LOCATION_NAMES.get(location, location))
		_ship_destination.set_item_metadata(_ship_destination.item_count - 1, location)
	FarmTheme.configure_option(_ship_origin)
	FarmTheme.configure_option(_ship_destination)
	route.add_child(_ship_origin)
	_label(route, "到")
	route.add_child(_ship_destination)
	_ship_destination.select(1)
	_ship_hint = Label.new()
	_ship_hint.name = "ShipHint"
	_ship_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(_ship_hint)
	_ship = _button(parent, "发货", 96.0)
	_ship.name = "Ship"
	_ship.pressed.connect(_emit_ship)
	_deliver = _button(parent, "交付到达货物", 140.0)
	_deliver.name = "Deliver"
	_deliver.pressed.connect(func() -> void:
		_clear_status()
		deliver_requested.emit())
	_deliver_hint = Label.new()
	_deliver_hint.name = "DeliveryHint"
	_deliver_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(_deliver_hint)
	_editable.append(_ship_good)
	_editable.append(_ship_quantity)
	_editable.append(_ship_origin)
	_editable.append(_ship_destination)
	_editable.append(_ship)
	_editable.append(_deliver)


func _fill_orders() -> void:
	_clear(_orders)
	var orders: Array = view.get("orders", []) as Array
	if orders.is_empty():
		_add(_orders, "还没有订单。")
		return
	for order: Dictionary in orders:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_orders.add_child(row)
		var label := Label.new()
		label.name = "Order_" + str(order.get("id", ""))
		label.text = _order_text(order)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		if not read_only and str(order.get("owner", "")) == my_id \
				and str(order.get("status", "")) == Market.STATUS_OPEN:
			var cancel := _button(row, "撤单", 76.0)
			cancel.name = "Cancel_" + str(order.get("id", ""))
			var order_id: String = str(order.get("id", ""))
			cancel.pressed.connect(func() -> void:
				_clear_status()
				cancel_requested.emit(order_id))


func _order_text(order: Dictionary) -> String:
	var side: String = str(order.get("side", ""))
	var side_text: String = "买入" if side == Market.SIDE_BUY else "卖出"
	var good_id: String = str(order.get("good", ""))
	var good_text: String = str(Catalog.definition(good_id).get("name", good_id))
	var owner: String = str(order.get("owner", ""))
	var who: String = "我" if owner == my_id else ("商人" if owner == Market.MERCHANT else "他人")
	var reserved: String = "%d COIN" % int(order.get("reserved", 0)) if side == Market.SIDE_BUY \
		else "%d 件" % int(order.get("reserved", 0))
	var text: String = "#%d %s %s · 剩余 %d/%d · 限价 %d · 托管 %s · %s" % [
		int(order.get("sequence", 0)), side_text, good_text,
		int(order.get("remaining", 0)), int(order.get("quantity", 0)),
		int(order.get("price", 0)), reserved, who]
	var filled: int = int(order.get("filled", 0))
	if filled > 0:
		text += " · 已成交 %d" % filled
	text += " · " + _order_status_text(str(order.get("status", "")), filled)
	return text


func _order_status_text(status: String, filled: int) -> String:
	match status:
		Market.STATUS_OPEN:
			return "部分成交" if filled > 0 else "进行中"
		Market.STATUS_FILLED:
			return "已成交"
		Market.STATUS_CANCELLED:
			return "已撤销"
		Market.STATUS_EXPIRED:
			return "已到期"
	return "未知"


func _fill_shipments() -> void:
	_clear(_shipments)
	var shipments: Array = view.get("shipments", []) as Array
	if shipments.is_empty():
		_add(_shipments, "还没有发货记录。")
		return
	for shipment: Dictionary in shipments:
		var label := Label.new()
		label.name = "Shipment_" + str(shipment.get("id", ""))
		label.text = _shipment_text(shipment)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_shipments.add_child(label)


func _shipment_text(shipment: Dictionary) -> String:
	var good_id: String = str(shipment.get("good", ""))
	var good_text: String = str(Catalog.definition(good_id).get("name", good_id))
	var origin: String = str(shipment.get("origin", ""))
	var destination: String = str(shipment.get("destination", ""))
	var route: String = "%s → %s" % [LOCATION_NAMES.get(origin, origin),
		LOCATION_NAMES.get(destination, destination)]
	var status: String = str(shipment.get("status", ""))
	var progress: String = ""
	if status == Market.SHIPMENT_STATUS_TRANSIT:
		var left: float = maxf(0.0, float(shipment.get("arrive_utc", 0.0)) - now_utc)
		progress = "在途，约 %d 分钟后到达" % int(ceil(left / 60.0))
	elif status == Market.SHIPMENT_STATUS_LOST:
		# A lost shipment is terminal evidence, not a delivery. Labeling it
		# "已交付" would tell the player goods arrived that were destroyed.
		progress = "路上损失"
	else:
		progress = "已交付"
	return "#%d %s ×%d · %s · %s" % [
		int(shipment.get("sequence", 0)), good_text, int(shipment.get("quantity", 0)),
		route, progress]


func _fill_deliveries() -> void:
	_clear(_deliveries)
	var deliveries: Array = view.get("deliveries", []) as Array
	if deliveries.is_empty():
		_add(_deliveries, "还没有交付记录。")
		return
	for delivery: Dictionary in deliveries:
		var label := Label.new()
		label.name = "Delivery_" + str(delivery.get("id", ""))
		var good_id: String = str(delivery.get("good", ""))
		var good_text: String = str(Catalog.definition(good_id).get("name", good_id))
		var origin: String = str(delivery.get("origin", ""))
		var destination: String = str(delivery.get("destination", ""))
		label.text = "%s ×%d · %s → %s" % [good_text, int(delivery.get("quantity", 0)),
			LOCATION_NAMES.get(origin, origin), LOCATION_NAMES.get(destination, destination)]
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_deliveries.add_child(label)


func _set_editable(enabled: bool) -> void:
	for control: Control in _editable:
		if control is SpinBox:
			(control as SpinBox).editable = enabled
		elif control is BaseButton:
			(control as BaseButton).disabled = not enabled


func _sync_price() -> void:
	var side: String = str(_side.get_item_metadata(maxi(0, _side.selected)))
	var good_id: String = str(_good.get_item_metadata(maxi(0, _good.selected)))
	var quote: Dictionary = (view.get("quotes", {}) as Dictionary).get(good_id, {}) as Dictionary
	var price: int = int(quote.get("ask", 1)) if side == Market.SIDE_BUY else int(quote.get("bid", 1))
	_price.value = maxi(1, price)
	_auto_price = int(round(_price.value))


func _emit_order() -> void:
	_clear_status()
	var side: String = str(_side.get_item_metadata(maxi(0, _side.selected)))
	var good_id: String = str(_good.get_item_metadata(maxi(0, _good.selected)))
	var minutes: int = maxi(1, int(round(_expires.value)))
	order_requested.emit(side, good_id, int(round(_price.value)), int(round(_quantity.value)),
		now_utc + float(minutes) * 60.0)


func _emit_ship() -> void:
	_clear_status()
	var good_id: String = str(_ship_good.get_item_metadata(maxi(0, _ship_good.selected)))
	var origin: String = str(_ship_origin.get_item_metadata(maxi(0, _ship_origin.selected)))
	var destination: String = str(_ship_destination.get_item_metadata(maxi(0, _ship_destination.selected)))
	ship_requested.emit(good_id, int(round(_ship_quantity.value)), origin, destination)


func _update_ship_hint() -> void:
	var routes: Array = view.get("routes", []) as Array
	if routes.is_empty():
		_ship_hint.text = ""
		return
	var route: Dictionary = routes[0] as Dictionary
	_ship_hint.text = "运费 %d COIN · 约 %d 分钟到达" % [
		int(route.get("fee", 0)), int(ceil(float(route.get("delivery_seconds", 0.0)) / 60.0))]


func _close() -> void:
	close()


func _heading(parent: Control, text: String) -> Label:
	var heading := Label.new()
	heading.text = text
	heading.add_theme_color_override("font_color", INK)
	heading.add_theme_font_size_override("font_size", 18)
	parent.add_child(heading)
	return heading


func _section(parent: Control, title: String) -> VBoxContainer:
	_heading(parent, title)
	var rows := VBoxContainer.new()
	rows.name = title
	rows.add_theme_constant_override("separation", 4)
	parent.add_child(rows)
	return rows


func _cell(parent: Control, text: String, node_name: String) -> Label:
	var label := Label.new()
	label.text = text
	if not node_name.is_empty():
		label.name = node_name
	parent.add_child(label)
	return label


func _label(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	parent.add_child(label)
	return label


func _add(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)


func _spin(parent: Control, node_name: String, label_text: String, minimum: int,
		maximum: int, value: int) -> SpinBox:
	_label(parent, label_text)
	var spin := SpinBox.new()
	spin.name = node_name
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = 1
	spin.value = value
	parent.add_child(spin)
	return spin


func _button(parent: Node, text: String, width: float) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(width, 40)
	FarmTheme.pointer_focus(button)
	parent.add_child(button)
	return button


func _clear(node: Node) -> void:
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()
