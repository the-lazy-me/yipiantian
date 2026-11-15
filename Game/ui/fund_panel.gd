extends Control
## 公共基金面板：把权威发来的基金视图摆出来，并把点击变成基金操作意图。
##
## 面板不判断谁能开立、缴入、支出或换届，也不核对余额与负责人：基金视图是
## 权威给出的公开财政事实，这里只据此决定显示什么，把动作原样交给调用方。
## 因此没有网络也能测。
##
## 视图整份替换，面板不合并增量，也不乐观修改余额或负责人。

signal fund_action(action: String, args: Dictionary)
signal refresh_requested
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const FUND_PREFIX: String = "fund_"
const INK := FarmTheme.INK

## 权威视图行：`{fund_id, org_id, keeper, balance, spent, contributors}`。
var funds: Array = []

var _focus_before: Control
## A message written while the panel is hidden belongs to the next open.
var _status_pending: bool = false
var _fund_list: VBoxContainer
var _open_org: LineEdit
var _open_button: Button
var _contribute_target: LineEdit
var _contribute_amount: LineEdit
var _contribute_button: Button
var _spend_target: LineEdit
var _spend_project: LineEdit
var _spend_amount: LineEdit
var _spend_button: Button
var _rotate_target: LineEdit
var _rotate_keeper: LineEdit
var _rotate_button: Button
var _status: Label
var _confirm: ConfirmationDialog
var _confirm_target: Dictionary = {}
var _confirm_keeper: String = ""
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
	paper.custom_minimum_size = Vector2(800, 620)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	paper.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	column.add_child(header)
	var title := Label.new()
	title.text = "公共基金"
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
	_heading(body, "基金")
	_fund_list = VBoxContainer.new()
	_fund_list.name = "FundList"
	_fund_list.add_theme_constant_override("separation", 4)
	body.add_child(_fund_list)
	_heading(body, "开立")
	var open_row := HBoxContainer.new()
	open_row.add_theme_constant_override("separation", 8)
	body.add_child(open_row)
	_open_org = LineEdit.new()
	_open_org.name = "OpenOrg"
	_open_org.placeholder_text = "组织 id"
	_open_org.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_row.add_child(_open_org)
	_open_button = _button(open_row, "开立基金", "OpenFund", 120.0)
	_open_button.pressed.connect(_request_open)
	_heading(body, "缴入")
	var contribute_row := HBoxContainer.new()
	contribute_row.add_theme_constant_override("separation", 8)
	body.add_child(contribute_row)
	_contribute_target = LineEdit.new()
	_contribute_target.name = "ContributeFund"
	_contribute_target.placeholder_text = "基金 id 或组织 id"
	_contribute_target.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	contribute_row.add_child(_contribute_target)
	_contribute_amount = LineEdit.new()
	_contribute_amount.name = "ContributeAmount"
	_contribute_amount.placeholder_text = "金额"
	_contribute_amount.max_length = 12
	_contribute_amount.custom_minimum_size.x = 120
	contribute_row.add_child(_contribute_amount)
	_contribute_button = _button(contribute_row, "缴入", "Contribute", 96.0)
	_contribute_button.pressed.connect(_request_contribute)
	_heading(body, "支出")
	var spend_row := HBoxContainer.new()
	spend_row.add_theme_constant_override("separation", 8)
	body.add_child(spend_row)
	_spend_target = LineEdit.new()
	_spend_target.name = "SpendFund"
	_spend_target.placeholder_text = "基金 id 或组织 id"
	_spend_target.custom_minimum_size.x = 200
	spend_row.add_child(_spend_target)
	_spend_project = LineEdit.new()
	_spend_project.name = "SpendProject"
	_spend_project.placeholder_text = "项目 id"
	_spend_project.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spend_row.add_child(_spend_project)
	_spend_amount = LineEdit.new()
	_spend_amount.name = "SpendAmount"
	_spend_amount.placeholder_text = "金额"
	_spend_amount.max_length = 12
	_spend_amount.custom_minimum_size.x = 120
	spend_row.add_child(_spend_amount)
	_spend_button = _button(spend_row, "支出", "Spend", 96.0)
	_spend_button.pressed.connect(_request_spend)
	_heading(body, "换届")
	var rotate_row := HBoxContainer.new()
	rotate_row.add_theme_constant_override("separation", 8)
	body.add_child(rotate_row)
	_rotate_target = LineEdit.new()
	_rotate_target.name = "RotateFund"
	_rotate_target.placeholder_text = "基金 id 或组织 id"
	_rotate_target.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rotate_row.add_child(_rotate_target)
	_rotate_keeper = LineEdit.new()
	_rotate_keeper.name = "RotateKeeper"
	_rotate_keeper.placeholder_text = "新负责人 id"
	_rotate_keeper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rotate_row.add_child(_rotate_keeper)
	_rotate_button = _button(rotate_row, "换届", "Rotate", 96.0)
	_rotate_button.pressed.connect(_request_rotate)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	_confirm = ConfirmationDialog.new()
	_confirm.name = "RotateConfirm"
	_confirm.ok_button_text = "换届"
	_confirm.cancel_button_text = "取消"
	_confirm.confirmed.connect(_confirmed_rotate)
	_confirm.canceled.connect(_clear_confirm)
	add_child(_confirm)
	visibility_changed.connect(_on_visibility_changed)
	hide()


## Rebuilds from the authoritative fund view. The panel never merges rows itself;
## the next authority reply replaces the whole list.
func open_panel(view: Dictionary) -> void:
	var focus_key: String = FarmTheme.focus_key_within(self)
	funds = _rows_from(view)
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


## True while the rotate confirmation owns the next Esc. The main scene uses this
## so the popup consumes the first Esc instead of closing the panel.
func is_popup_open() -> bool:
	return _confirm.visible


func close_panel() -> void:
	if not visible:
		return
	_confirm.hide()
	_clear_confirm()
	hide()
	closed.emit()


## The authority reply is the only source of fund facts. A refused action keeps
## whatever state the reply carried and shows the authority's own reason text.
func apply_result(_request_id: String, payload: Dictionary) -> void:
	var state_value: Variant = payload.get("state")
	if state_value is Dictionary:
		funds = _rows_from(state_value)
		_fill_list()
	var text: String = str(payload.get("reason_text", ""))
	if text.is_empty():
		text = str(payload.get("reason", ""))
	if not bool(payload.get("ok", false)):
		if not text.is_empty():
			show_status(text)
		return
	if bool(payload.get("duplicate", false)):
		show_status("这条基金操作已经执行过。")
		return
	_clear_status()


func _fill_list() -> void:
	_clear(_fund_list)
	if funds.is_empty():
		_add(_fund_list, "还没有公共基金。")
		return
	for value: Variant in funds:
		if not value is Dictionary:
			continue
		var row: Dictionary = value
		var fund_id: String = str(row.get("fund_id", ""))
		var label := Label.new()
		label.name = "Fund_" + fund_id
		label.text = _fund_text(row)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", INK)
		label.add_theme_font_size_override("font_size", 16)
		_fund_list.add_child(label)


func _request_open() -> void:
	if _open_button.disabled:
		return
	var org_id: String = _open_org.text.strip_edges()
	if org_id.is_empty():
		show_status("先填写组织 id。")
		return
	_clear_status()
	# The request id doubles as the authority's command id.
	var request_id: String = _new_request_id("open")
	fund_action.emit("open", {"command_id": request_id, "org_id": org_id})


func _request_contribute() -> void:
	if _contribute_button.disabled:
		return
	var amount: int = _positive_amount(_contribute_amount.text)
	if amount <= 0:
		show_status("金额请填写正整数。")
		return
	var target: Dictionary = _target_args(_contribute_target.text)
	if target.is_empty():
		show_status("先填写基金 id 或组织 id。")
		return
	_clear_status()
	var request_id: String = _new_request_id("contribute")
	var args: Dictionary = target.duplicate()
	args["command_id"] = request_id
	args["amount"] = amount
	fund_action.emit("contribute", args)


func _request_spend() -> void:
	if _spend_button.disabled:
		return
	var amount: int = _positive_amount(_spend_amount.text)
	if amount <= 0:
		show_status("金额请填写正整数。")
		return
	var target: Dictionary = _target_args(_spend_target.text)
	if target.is_empty():
		show_status("先填写基金 id 或组织 id。")
		return
	var project: String = _spend_project.text.strip_edges()
	if project.is_empty():
		show_status("先填写项目 id。")
		return
	_clear_status()
	var request_id: String = _new_request_id("spend")
	var args: Dictionary = target.duplicate()
	args["command_id"] = request_id
	args["project_id"] = project
	args["amount"] = amount
	fund_action.emit("spend", args)


## Rotating the keeper changes who can spend the fund, so a click alone only
## opens a confirmation; the request is sent after the player confirms.
func _request_rotate() -> void:
	if _rotate_button.disabled:
		return
	var target: Dictionary = _target_args(_rotate_target.text)
	if target.is_empty():
		show_status("先填写基金 id 或组织 id。")
		return
	var new_keeper: String = _rotate_keeper.text.strip_edges()
	if new_keeper.is_empty():
		show_status("先填写新负责人 id。")
		return
	_confirm_target = target
	_confirm_keeper = new_keeper
	_confirm.dialog_text = "确定把基金 %s 的负责人换成 %s 吗？" % [
		_target_text(target), new_keeper,
	]
	_confirm.popup_centered()


func _confirmed_rotate() -> void:
	var target: Dictionary = _confirm_target
	var new_keeper: String = _confirm_keeper
	_clear_confirm()
	if target.is_empty() or new_keeper.is_empty():
		return
	_clear_status()
	var request_id: String = _new_request_id("rotate")
	var args: Dictionary = target.duplicate()
	args["command_id"] = request_id
	args["new_keeper"] = new_keeper
	fund_action.emit("rotate", args)


func _clear_confirm() -> void:
	_confirm_target = {}
	_confirm_keeper = ""


## The authority resolves either `fund_id` or `org_id`; the panel only decides
## which key the typed target names. It never checks whether the fund exists.
func _target_args(text: String) -> Dictionary:
	var target: String = text.strip_edges()
	if target.is_empty():
		return {}
	if target.begins_with(FUND_PREFIX):
		return {"fund_id": target}
	return {"org_id": target}


func _target_text(target: Dictionary) -> String:
	if target.has("fund_id"):
		return str(target["fund_id"])
	return str(target.get("org_id", ""))


func _positive_amount(text: String) -> int:
	var trimmed: String = text.strip_edges()
	if not trimmed.is_valid_int():
		return -1
	var amount: int = int(trimmed)
	if amount < 1:
		return -1
	return amount


func _new_request_id(action: String) -> String:
	_request_counter += 1
	return "fund-%s-%d-%d" % [action, Time.get_ticks_usec(), _request_counter]


func _fund_text(row: Dictionary) -> String:
	var contributors: Dictionary = _contributors_of(row)
	var player_ids: Array = contributors.keys()
	player_ids.sort()
	var parts: Array[String] = []
	var total: int = 0
	for player_value: Variant in player_ids:
		var player_id: String = str(player_value)
		var amount: int = int(contributors[player_value])
		total += amount
		parts.append("%s %d" % [player_id, amount])
	var detail: String = "、".join(PackedStringArray(parts)) if not parts.is_empty() else "无"
	return "%s｜组织 %s｜负责人 %s｜余额 %d｜支出 %d｜缴入累计 %d（%s）" % [
		str(row.get("fund_id", "")), str(row.get("org_id", "")),
		str(row.get("keeper", "")), int(row.get("balance", 0)),
		int(row.get("spent", 0)), total, detail,
	]


func _contributors_of(row: Dictionary) -> Dictionary:
	var value: Variant = row.get("contributors")
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {}


## Copies the rows so the panel's view never aliases the authority document, and
## sorts by fund id as the contract requires regardless of reply order.
func _rows_from(view: Dictionary) -> Array:
	var rows: Array = []
	var value: Variant = view.get("funds")
	if value is Array:
		for row_value: Variant in value:
			if row_value is Dictionary:
				rows.append((row_value as Dictionary).duplicate(true))
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("fund_id", "")) < str(b.get("fund_id", "")))
	return rows


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
	# Esc belongs to the panel only while it is open. The rotate confirmation
	# takes the first Esc; the next one closes the panel.
	if not visible or not (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE):
		return
	if _confirm.visible:
		_confirm.hide()
		_clear_confirm()
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
