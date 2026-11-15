extends Control
## 公共项目面板：把权威发来的项目视图摆出来，并把点击变成公共项目操作意图。
##
## 面板不判断发起人身份、组织权限、基金余额或项目是否足额：项目视图是权威给出
## 的公开预算事实，这里只据此决定显示什么，把动作原样交给调用方。因此没有网络
## 也能测。
##
## 视图整份替换，面板不合并增量，也不乐观修改承诺、覆盖或建成状态。

signal public_works_action(action: String, args: Dictionary)
signal refresh_requested
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const INK := FarmTheme.INK
const KIND_VILLAGE_SQUARE: String = "village_square"
const KIND_PUBLIC_WELL: String = "public_well"
const KIND_ROAD_SEGMENT: String = "road_segment"
const STATUS_UNBUILT: String = "unbuilt"
const STATUS_FUNDED: String = "funded"
const STATUS_BUILT: String = "built"
const KIND_LABELS: Dictionary = {
	KIND_VILLAGE_SQUARE: "村口广场",
	KIND_PUBLIC_WELL: "公井",
	KIND_ROAD_SEGMENT: "石板路",
}
const KINDS: Array[String] = [
	KIND_VILLAGE_SQUARE, KIND_PUBLIC_WELL, KIND_ROAD_SEGMENT,
]
const STATUS_LABELS: Dictionary = {
	STATUS_UNBUILT: "未建",
	STATUS_FUNDED: "已足额",
	STATUS_BUILT: "已建成",
}

## 权威视图：`{projects: [{project_id, kind, parcel_id, funded, pledged, status, built_utc}]}`。
var view: Dictionary = {}
## 权威视图行，按 project_id 排序；面板只渲染它们，不推导成本或状态。
var projects: Array = []

var _focus_before: Control
## A message written while the panel is hidden belongs to the next open.
var _status_pending: bool = false
var _project_list: VBoxContainer
var _open_project_id: LineEdit
var _kind: OptionButton
var _open_parcel: LineEdit
var _open_button: Button
var _pledge_project_id: LineEdit
var _pledge_amount: LineEdit
var _pledge_button: Button
var _release_project_id: LineEdit
var _release_amount: LineEdit
var _release_button: Button
var _build_project_id: LineEdit
var _build_fund: LineEdit
var _build_button: Button
var _status: Label
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
	paper.custom_minimum_size = Vector2(860, 680)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	paper.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	column.add_child(header)
	var title := Label.new()
	title.text = "公共项目"
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
	_heading(body, "项目")
	_project_list = VBoxContainer.new()
	_project_list.name = "ProjectList"
	_project_list.add_theme_constant_override("separation", 4)
	body.add_child(_project_list)
	_heading(body, "登记项目")
	var open_row := HBoxContainer.new()
	open_row.add_theme_constant_override("separation", 8)
	body.add_child(open_row)
	_open_project_id = LineEdit.new()
	_open_project_id.name = "ProjectId"
	_open_project_id.placeholder_text = "项目 id"
	_open_project_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_row.add_child(_open_project_id)
	_kind = OptionButton.new()
	_kind.name = "Kind"
	_kind.custom_minimum_size.x = 150
	open_row.add_child(_kind)
	for index: int in KINDS.size():
		var kind: String = KINDS[index]
		_kind.add_item(str(KIND_LABELS[kind]))
		_kind.set_item_metadata(index, kind)
	FarmTheme.configure_option(_kind)
	_open_parcel = LineEdit.new()
	_open_parcel.name = "ParcelId"
	_open_parcel.placeholder_text = "地块 id（可留空）"
	_open_parcel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_row.add_child(_open_parcel)
	_open_button = _button(open_row, "登记", "OpenProject", 96.0)
	_open_button.pressed.connect(_request_open)
	_heading(body, "承诺")
	var pledge_row := HBoxContainer.new()
	pledge_row.add_theme_constant_override("separation", 8)
	body.add_child(pledge_row)
	_pledge_project_id = LineEdit.new()
	_pledge_project_id.name = "PledgeProject"
	_pledge_project_id.placeholder_text = "项目 id"
	_pledge_project_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pledge_row.add_child(_pledge_project_id)
	_pledge_amount = LineEdit.new()
	_pledge_amount.name = "PledgeAmount"
	_pledge_amount.placeholder_text = "金额"
	_pledge_amount.max_length = 12
	_pledge_amount.custom_minimum_size.x = 120
	pledge_row.add_child(_pledge_amount)
	_pledge_button = _button(pledge_row, "承诺", "Pledge", 96.0)
	_pledge_button.pressed.connect(_request_pledge)
	_heading(body, "退回")
	var release_row := HBoxContainer.new()
	release_row.add_theme_constant_override("separation", 8)
	body.add_child(release_row)
	_release_project_id = LineEdit.new()
	_release_project_id.name = "ReleaseProject"
	_release_project_id.placeholder_text = "项目 id"
	_release_project_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	release_row.add_child(_release_project_id)
	_release_amount = LineEdit.new()
	_release_amount.name = "ReleaseAmount"
	_release_amount.placeholder_text = "金额"
	_release_amount.max_length = 12
	_release_amount.custom_minimum_size.x = 120
	release_row.add_child(_release_amount)
	_release_button = _button(release_row, "退回", "Release", 96.0)
	_release_button.pressed.connect(_request_release)
	_heading(body, "用基金建成")
	var build_row := HBoxContainer.new()
	build_row.add_theme_constant_override("separation", 8)
	body.add_child(build_row)
	_build_project_id = LineEdit.new()
	_build_project_id.name = "BuildProject"
	_build_project_id.placeholder_text = "项目 id"
	_build_project_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	build_row.add_child(_build_project_id)
	_build_fund = LineEdit.new()
	_build_fund.name = "BuildFund"
	_build_fund.placeholder_text = "基金 id"
	_build_fund.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	build_row.add_child(_build_fund)
	_build_button = _button(build_row, "建成", "Build", 96.0)
	_build_button.pressed.connect(_request_build)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	visibility_changed.connect(_on_visibility_changed)
	hide()


## Rebuilds from the authoritative public works view. The panel never merges rows
## itself; the next authority reply replaces the whole list.
func open_panel(next: Dictionary = {}) -> void:
	var focus_key: String = FarmTheme.focus_key_within(self)
	_apply_view(next)
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


## True while the kind dropdown owns the next Esc.
func is_popup_open() -> bool:
	return _kind != null and _kind.get_popup().visible


func close_panel() -> void:
	if not visible:
		return
	_kind.get_popup().hide()
	hide()
	closed.emit()


## The authority reply is the only source of project facts. A refused action
## keeps whatever view the reply carried and shows the authority's own reason
## text so the player sees why it was rejected.
func apply_result(_request_id: String, payload: Dictionary) -> void:
	var state_value: Variant = payload.get("state")
	if state_value is Dictionary:
		_apply_view(state_value)
	var text: String = str(payload.get("reason_text", ""))
	if text.is_empty():
		text = str(payload.get("reason", ""))
	if not bool(payload.get("ok", false)):
		show_status(text if not text.is_empty() else "公共项目操作被拒绝。")
		return
	if bool(payload.get("duplicate", false)):
		show_status("这条公共项目操作已经执行过。")
		return
	if str(payload.get("action", "")) == "build":
		show_status("公共项目已建成。")
		return
	_clear_status()


func _apply_view(next: Dictionary) -> void:
	view = next.duplicate(true)
	projects = _rows_from(view)
	_fill_list()


func _fill_list() -> void:
	_clear(_project_list)
	if projects.is_empty():
		_add(_project_list, "还没有公共项目。")
		return
	for value: Variant in projects:
		var row: Dictionary = value
		var label := Label.new()
		label.name = "Project_" + str(row.get("project_id", ""))
		label.text = _project_text(row)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", INK)
		label.add_theme_font_size_override("font_size", 16)
		_project_list.add_child(label)


func _request_open() -> void:
	if _open_button.disabled:
		return
	var project_id: String = _open_project_id.text.strip_edges()
	if project_id.is_empty():
		show_status("先填写项目 id。")
		return
	var kind: String = _selected_meta(_kind)
	if kind.is_empty():
		show_status("先选择项目类型。")
		return
	_clear_status()
	# The request id doubles as the authority's command id.
	var request_id: String = _new_request_id("open")
	public_works_action.emit("open", {
		"command_id": request_id,
		"project_id": project_id,
		"kind": kind,
		"parcel_id": _open_parcel.text.strip_edges(),
	})


func _request_pledge() -> void:
	if _pledge_button.disabled:
		return
	var project_id: String = _pledge_project_id.text.strip_edges()
	if project_id.is_empty():
		show_status("先填写项目 id。")
		return
	var amount: int = _positive_amount(_pledge_amount.text)
	if amount <= 0:
		show_status("金额请填写正整数。")
		return
	_clear_status()
	var request_id: String = _new_request_id("pledge")
	public_works_action.emit("pledge", {
		"command_id": request_id, "project_id": project_id, "amount": amount,
	})


func _request_release() -> void:
	if _release_button.disabled:
		return
	var project_id: String = _release_project_id.text.strip_edges()
	if project_id.is_empty():
		show_status("先填写项目 id。")
		return
	var amount: int = _positive_amount(_release_amount.text)
	if amount <= 0:
		show_status("金额请填写正整数。")
		return
	_clear_status()
	var request_id: String = _new_request_id("release")
	public_works_action.emit("release", {
		"command_id": request_id, "project_id": project_id, "amount": amount,
	})


func _request_build() -> void:
	if _build_button.disabled:
		return
	var project_id: String = _build_project_id.text.strip_edges()
	if project_id.is_empty():
		show_status("先填写项目 id。")
		return
	var fund_id: String = _build_fund.text.strip_edges()
	if fund_id.is_empty():
		show_status("先填写基金 id。")
		return
	_clear_status()
	var request_id: String = _new_request_id("build")
	public_works_action.emit("build", {
		"command_id": request_id, "project_id": project_id, "fund_id": fund_id,
	})


func _positive_amount(text: String) -> int:
	var trimmed: String = text.strip_edges()
	if not trimmed.is_valid_int():
		return -1
	var amount: int = int(trimmed)
	if amount < 1:
		return -1
	return amount


func _selected_meta(option: OptionButton) -> String:
	if option.selected < 0:
		return ""
	return str(option.get_item_metadata(option.selected))


func _new_request_id(action: String) -> String:
	_request_counter += 1
	return "public-works-%s-%d-%d" % [action, Time.get_ticks_usec(), _request_counter]


func _project_text(row: Dictionary) -> String:
	var project_id: String = str(row.get("project_id", ""))
	var kind: String = str(row.get("kind", ""))
	var parcel: String = str(row.get("parcel_id", ""))
	var status: String = str(row.get("status", ""))
	var text: String = "%s｜%s｜地块 %s｜已承诺 %d｜固定成本覆盖 %d｜%s" % [
		project_id,
		str(KIND_LABELS.get(kind, kind)),
		parcel if not parcel.is_empty() else "未绑定",
		int(row.get("pledged", 0)),
		int(row.get("funded", 0)),
		str(STATUS_LABELS.get(status, status)),
	]
	var built_utc: float = float(row.get("built_utc", 0.0))
	if built_utc > 0.0:
		text += "｜建成 %d" % int(built_utc)
	elif status == STATUS_BUILT:
		text += "｜建成时间未记录"
	return text


## Copies the rows so the panel's view never aliases the authority document, and
## sorts by project id regardless of reply order.
func _rows_from(source: Dictionary) -> Array:
	var rows: Array = []
	var value: Variant = source.get("projects")
	if value is Array:
		for row_value: Variant in value:
			if row_value is Dictionary:
				rows.append((row_value as Dictionary).duplicate(true))
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("project_id", "")) < str(b.get("project_id", "")))
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
	# Esc belongs to the panel only while it is open. An open dropdown takes the
	# first Esc; the next one closes the panel.
	if not visible or not (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE):
		return
	if _kind.get_popup().visible:
		_kind.get_popup().hide()
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


func _add(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


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
