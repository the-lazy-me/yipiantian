extends CanvasLayer
## 宅基面板：把权威同步来的建筑摆出来，并把点击变成建造或拆除意图。
##
## 面板不判断“能不能建”：槽位是否为空、是不是房主由权威的规则决定，这里只
## 根据状态决定显示什么。因此没有网络也能测。
##
## 视图整份替换，面板不合并增量。

signal build_requested(slot_id: String, blueprint: String)
signal demolish_requested(slot_id: String)
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const Catalog = preload("res://farm/building_catalog.gd")
const INK := FarmTheme.INK

var buildings: Dictionary = {}
var now_utc: float = 0.0
var my_id: String = ""
var _root: Control
var _status: Label
var _list: VBoxContainer
var _slot_choices: Dictionary = {}


func _ready() -> void:
	layer = 25
	_root = Control.new()
	_root.name = "Homes"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.theme = FarmTheme.create()
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.08, 0.1, 0.09, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var paper := PanelContainer.new()
	paper.add_theme_stylebox_override("panel", FarmTheme.framed_paper(FarmTheme.PAPER))
	paper.custom_minimum_size = Vector2(560, 420)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	paper.add_child(column)
	var title := Label.new()
	title.text = "宅基"
	title.add_theme_color_override("font_color", INK)
	title.add_theme_font_size_override("font_size", 26)
	column.add_child(title)
	var hint := Label.new()
	hint.text = "占下宅基后要等一会儿才建成；施工中可以取消，建成后只有房主能拆。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(hint)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	var close := Button.new()
	close.name = "Close"
	close.text = "关闭"
	close.custom_minimum_size.y = 44
	close.pressed.connect(func() -> void:
		hide()
		closed.emit())
	column.add_child(close)
	hide()


## Rebuilds from the mirrored farm document. `now_utc` is the world clock: the
## panel does not run its own timer, so what it shows matches what the rules
## would decide at that instant.
func present(next_buildings: Dictionary, next_now_utc: float, next_my_id: String) -> void:
	buildings = next_buildings
	now_utc = next_now_utc
	my_id = next_my_id
	_status.text = ""
	_slot_choices.clear()
	_clear(_list)
	for slot_id: String in Catalog.SLOTS:
		_row(slot_id)


func show_status(text: String) -> void:
	_status.text = text


func is_open() -> bool:
	return visible


func _row(slot_id: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_list.add_child(row)
	var label := Label.new()
	label.name = "Slot_" + slot_id
	var recorded: Dictionary = buildings.get(slot_id, {}) as Dictionary
	label.text = Catalog.name_of_slot(slot_id)
	label.custom_minimum_size.x = 120
	label.add_theme_color_override("font_color", INK)
	row.add_child(label)
	if recorded.is_empty():
		var picker := OptionButton.new()
		picker.name = "Blueprint_" + slot_id
		picker.custom_minimum_size.x = 140
		for blueprint_id: String in Catalog.blueprint_ids():
			picker.add_item(str(Catalog.definition(blueprint_id).get("name", blueprint_id)))
			picker.set_item_metadata(picker.item_count - 1, blueprint_id)
		row.add_child(picker)
		_slot_choices[slot_id] = picker
		var build := _button(row, "建造", "Build_" + slot_id)
		build.pressed.connect(func() -> void: _request_build(slot_id))
		return
	var state: String = str(recorded.get("state", "done"))
	var owner: String = str(recorded.get("owner", ""))
	var text: String = "%s · %s" % [str(recorded.get("name", "")), _state_text(state, recorded)]
	var detail := Label.new()
	detail.name = "State_" + slot_id
	detail.text = text
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_color_override("font_color", INK)
	row.add_child(detail)
	if owner == my_id and not my_id.is_empty():
		var remove := _button(row, "取消建造" if state == "building" else "拆除", "Demolish_" + slot_id)
		remove.pressed.connect(func() -> void: _request_demolish(slot_id))


func _state_text(state: String, recorded: Dictionary) -> String:
	if state != "building":
		return "已建成"
	var left: float = maxf(0.0, float(recorded.get("done_utc", 0.0)) - now_utc)
	return "施工中，还要 %d 分钟" % int(ceil(left / 60.0))


func _request_build(slot_id: String) -> void:
	var picker: OptionButton = _slot_choices.get(slot_id) as OptionButton
	if picker == null or picker.item_count == 0:
		return
	var blueprint: String = str(picker.get_item_metadata(maxi(0, picker.selected)))
	build_requested.emit(slot_id, blueprint)


func _request_demolish(slot_id: String) -> void:
	demolish_requested.emit(slot_id)


func _button(parent: Node, text: String, node_name: String) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(96, 40)
	parent.add_child(button)
	return button


func _clear(node: Node) -> void:
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()
