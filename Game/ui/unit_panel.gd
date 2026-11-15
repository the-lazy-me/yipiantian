extends Control
## 单位面板：把权威发来的单位视图摆出来，并把点击变成单位操作意图。
##
## 面板不判断谁能招募、解散或补给，也不核对现金、粮草与归属：名册是权威给出的
## 公开事实，这里只据此决定显示什么，把动作原样交给调用方。因此没有网络也能测。
##
## 视图整份替换，面板不合并增量，也不乐观增删单位。

signal unit_action(action: String, args: Dictionary)
signal refresh_requested
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const UnitState = preload("res://conflict/unit_state.gd")
const INK := FarmTheme.INK
const KIND_TEXT := {"militia": "民兵", "guard": "卫兵"}
const EQUIPMENT_TEXT := {
	"none": "无装备", "basic": "基础装备", "standard": "标准装备", "elite": "精锐装备",
}

## 权威视图行：`{id, owner, kind, people, equipment, station, unfed_days}`。
var units: Array = []

var _focus_before: Control
## A message written while the panel is hidden belongs to the next open.
var _status_pending: bool = false
var _unit_list: VBoxContainer
var _kind: OptionButton
var _people: LineEdit
var _equipment: OptionButton
var _station: LineEdit
var _recruit: Button
var _upkeep: Button
var _status: Label
var _confirm: ConfirmationDialog
var _confirm_unit: String = ""
var _request_counter: int = 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = FarmTheme.create()
	var dim := ColorRect.new()
	dim.color = Color(0.08, 0.1, 0.09, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var paper := PanelContainer.new()
	paper.add_theme_stylebox_override("panel", FarmTheme.framed_paper(FarmTheme.PAPER))
	paper.custom_minimum_size = Vector2(760, 580)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	paper.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	column.add_child(header)
	var title := Label.new()
	title.text = "单位"
	title.add_theme_color_override("font_color", INK)
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var refresh := _button(header, "刷新", "Refresh", 84.0)
	refresh.pressed.connect(func() -> void:
		_clear_status()
		refresh_requested.emit())
	var close_button := _button(header, "收起", "Close", 84.0)
	close_button.pressed.connect(func() -> void: close_panel())
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
	_heading(body, "名册")
	_unit_list = VBoxContainer.new()
	_unit_list.name = "UnitList"
	_unit_list.add_theme_constant_override("separation", 4)
	body.add_child(_unit_list)
	_heading(body, "招募")
	var first_row := HBoxContainer.new()
	first_row.add_theme_constant_override("separation", 8)
	body.add_child(first_row)
	_kind = OptionButton.new()
	_kind.name = "Kind"
	_kind.custom_minimum_size.x = 120
	first_row.add_child(_kind)
	_people = LineEdit.new()
	_people.name = "People"
	_people.placeholder_text = "人数"
	_people.max_length = 6
	_people.custom_minimum_size.x = 96
	first_row.add_child(_people)
	_equipment = OptionButton.new()
	_equipment.name = "Equipment"
	_equipment.custom_minimum_size.x = 140
	first_row.add_child(_equipment)
	_station = LineEdit.new()
	_station.name = "Station"
	_station.placeholder_text = "驻地"
	_station.max_length = UnitState.MAX_STATION_LENGTH
	_station.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	first_row.add_child(_station)
	var recruit_row := HBoxContainer.new()
	recruit_row.add_theme_constant_override("separation", 8)
	body.add_child(recruit_row)
	_recruit = _button(recruit_row, "招募", "Recruit", 120.0)
	_recruit.pressed.connect(_request_recruit)
	_heading(body, "补给")
	_upkeep = _button(body, "补给", "Upkeep", 120.0)
	_upkeep.pressed.connect(_request_upkeep)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	_fill_options()
	_confirm = ConfirmationDialog.new()
	_confirm.name = "DisbandConfirm"
	_confirm.ok_button_text = "解散"
	_confirm.cancel_button_text = "取消"
	_confirm.confirmed.connect(_confirmed_disband)
	_confirm.canceled.connect(func() -> void: _confirm_unit = "")
	add_child(_confirm)
	visibility_changed.connect(_on_visibility_changed)
	hide()


## Rebuilds from the authoritative unit view. The panel never merges rows itself;
## the next authority reply replaces the whole list.
func open_panel(view: Dictionary) -> void:
	var focus_key: String = FarmTheme.focus_key_within(self)
	units = _rows_from(view)
	_fill_list()
	if not _status_pending:
		_status.text = ""
	_status_pending = false
	show()
	if visible:
		FarmTheme.wrap_focus(self, focus_key)


func show_status(text: String) -> void:
	_status.text = text
	_status_pending = not visible and not text.is_empty()


func is_open() -> bool:
	return visible


## True while a dropdown or the disband confirmation owns the next Esc. The main
## scene uses this so a popup consumes the first Esc instead of closing the panel.
func is_popup_open() -> bool:
	if _confirm.visible:
		return true
	for option: OptionButton in [_kind, _equipment]:
		if option.get_popup().visible:
			return true
	return false


func close_panel() -> void:
	if not visible:
		return
	_confirm.hide()
	_confirm_unit = ""
	for option: OptionButton in [_kind, _equipment]:
		option.get_popup().hide()
	hide()
	closed.emit()


## The authority reply is the only source of a new roster. A refused action keeps
## the view the reply carried (if any) and shows the authority's own reason text.
func apply_result(_request_id: String, payload: Dictionary) -> void:
	var state_value: Variant = payload.get("state")
	if state_value is Dictionary:
		units = _rows_from(state_value)
		_fill_list()
	var text: String = str(payload.get("reason_text", ""))
	if text.is_empty():
		text = str(payload.get("reason", ""))
	if not bool(payload.get("ok", false)):
		if not text.is_empty():
			show_status(text)
		return
	if bool(payload.get("duplicate", false)):
		show_status("这条单位操作已经执行过。")
		return
	_clear_status()


func _fill_options() -> void:
	var kinds: Array = UnitState.CATALOG.keys()
	kinds.sort()
	for kind_value: Variant in kinds:
		var kind: String = str(kind_value)
		_kind.add_item(_kind_text(kind))
		_kind.set_item_metadata(_kind.item_count - 1, kind)
	var equipment_ids: Array = UnitState.EQUIPMENT.keys()
	equipment_ids.sort()
	for equipment_value: Variant in equipment_ids:
		var equipment: String = str(equipment_value)
		_equipment.add_item(_equipment_text(equipment))
		_equipment.set_item_metadata(_equipment.item_count - 1, equipment)
	FarmTheme.configure_option(_kind)
	FarmTheme.configure_option(_equipment)


func _fill_list() -> void:
	_clear(_unit_list)
	if units.is_empty():
		_add(_unit_list, "还没有单位。")
		return
	for value: Variant in units:
		if not value is Dictionary:
			continue
		var row: Dictionary = value
		var unit_id: String = str(row.get("id", ""))
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 8)
		_unit_list.add_child(line)
		var label := Label.new()
		label.name = "Unit_" + unit_id
		label.text = _unit_text(row)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", INK)
		label.add_theme_font_size_override("font_size", 16)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(label)
		var disband := _button(line, "解散", "Disband_" + unit_id, 84.0)
		disband.pressed.connect(_request_disband.bind(unit_id))


func _request_recruit() -> void:
	if _recruit.disabled:
		return
	var text: String = _people.text.strip_edges()
	if not text.is_valid_int() or int(text) < 1:
		show_status("人数请填写正整数。")
		return
	var kind: String = _selected_meta(_kind)
	var equipment: String = _selected_meta(_equipment)
	if kind.is_empty() or equipment.is_empty():
		show_status("先选择兵种和装备。")
		return
	var station: String = _station.text.strip_edges()
	if station.is_empty():
		show_status("先填写驻地。")
		return
	_clear_status()
	unit_action.emit("recruit", {
		"command_id": _new_request_id("recruit"), "kind": kind,
		"people": int(text), "equipment": equipment, "station": station,
	})


## A disband is destructive and irreversible on the authority, so the comment
## only becomes a request after the player confirms it.
func _request_disband(unit_id: String) -> void:
	if unit_id.is_empty():
		return
	_confirm_unit = unit_id
	_confirm.dialog_text = "确定解散单位 %s 吗？" % unit_id
	_confirm.popup_centered()


func _confirmed_disband() -> void:
	var unit_id: String = _confirm_unit
	_confirm_unit = ""
	if unit_id.is_empty():
		return
	_clear_status()
	unit_action.emit("disband", {
		"command_id": _new_request_id("disband"), "unit_id": unit_id,
	})


func _request_upkeep() -> void:
	if _upkeep.disabled:
		return
	_clear_status()
	unit_action.emit("upkeep", {"command_id": _new_request_id("upkeep")})


func _new_request_id(action: String) -> String:
	_request_counter += 1
	return "unit-%s-%d-%d" % [action, Time.get_ticks_usec(), _request_counter]


func _unit_text(row: Dictionary) -> String:
	return "%s｜所有者 %s｜%s｜%d 人｜%s｜驻地 %s｜欠供 %d 天" % [
		str(row.get("id", "")), str(row.get("owner", "")),
		_kind_text(str(row.get("kind", ""))), int(row.get("people", 0)),
		_equipment_text(str(row.get("equipment", ""))),
		str(row.get("station", "")), int(row.get("unfed_days", 0)),
	]


func _kind_text(kind: String) -> String:
	return str(KIND_TEXT.get(kind, kind))


func _equipment_text(equipment: String) -> String:
	return str(EQUIPMENT_TEXT.get(equipment, equipment))


## Copies the rows so the panel's view never aliases the authority document, and
## sorts by id as the contract requires regardless of reply order.
func _rows_from(view: Dictionary) -> Array:
	var rows: Array = []
	var value: Variant = view.get("units")
	if value is Array:
		for row_value: Variant in value:
			if row_value is Dictionary:
				rows.append((row_value as Dictionary).duplicate(true))
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("id", "")) < str(b.get("id", "")))
	return rows


func _selected_meta(option: OptionButton) -> String:
	if option.selected < 0:
		return ""
	return str(option.get_item_metadata(option.selected))


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
		FarmTheme.wrap_focus(self)


func _clear_status() -> void:
	_status.text = ""
	_status_pending = false


func _input(event: InputEvent) -> void:
	# Esc belongs to the panel only while it is open. An open dropdown or the
	# disband confirmation takes the first Esc; the next one closes the panel.
	if not visible or not (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE):
		return
	if _confirm.visible:
		_confirm.hide()
		_confirm_unit = ""
		get_viewport().set_input_as_handled()
		return
	for option: OptionButton in [_kind, _equipment]:
		if option.get_popup().visible:
			option.get_popup().hide()
			get_viewport().set_input_as_handled()
			return
	close_panel()
	get_viewport().set_input_as_handled()


func _heading(parent: Control, text: String) -> Label:
	var heading := Label.new()
	heading.text = text
	heading.add_theme_color_override("font_color", INK)
	heading.add_theme_font_size_override("font_size", 18)
	parent.add_child(heading)
	return heading


func _add(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)


func _button(parent: Control, text: String, node_name: String, width: float) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	if width > 0.0:
		button.custom_minimum_size = Vector2(width, 40)
	else:
		button.custom_minimum_size = Vector2(0, 40)
	FarmTheme.pointer_focus(button)
	parent.add_child(button)
	return button


func _clear(node: Node) -> void:
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()
