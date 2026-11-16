extends CanvasLayer
## 组织面板：把权威发来的组织视图摆出来，并把点击变成组织操作意图。
##
## 面板不判断谁能创建、加入、退出、任命或交接：成员与职位是权威给出的公开
## 事实，这里只据此决定显示什么，把动作原样交给调用方。因此没有网络也能测。
##
## 视图整份替换，面板不合并增量，也不乐观修改成员或职位。

signal org_action(action: String, args: Dictionary)
signal refresh_requested
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const INK := FarmTheme.INK
const ROLE_TEXT := {"leader": "负责人", "officer": "干事", "member": "成员"}

## 权威视图：`{id, name, created_utc, members: {player_id: role}, roles}` 的数组。
var organizations: Array = []
var my_id: String = ""
var can_write: bool = true
var selected_id: String = ""

var _root: Control
var _focus_before: Control
## A message written while the panel is hidden belongs to the next open.
var _status_pending: bool = false
var _org_list: VBoxContainer
var _member_list: VBoxContainer
var _name: LineEdit
var _target: OptionButton
var _create: Button
var _join: Button
var _leave: Button
var _appoint: Button
var _transfer: Button
var _dissolve: Button
var _status: Label
var _confirm: ConfirmationDialog
## The confirm dialog owns the exact arguments, so cancelling sends nothing.
var _pending_dissolve: Dictionary = {}


func _ready() -> void:
	layer = 23
	_root = Control.new()
	_root.name = "Governance"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.theme = FarmTheme.create()
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.08, 0.1, 0.09, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var paper := PanelContainer.new()
	paper.add_theme_stylebox_override("panel", FarmTheme.framed_paper(FarmTheme.PAPER))
	paper.custom_minimum_size = Vector2(720, 560)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	paper.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	column.add_child(header)
	var title := Label.new()
	title.text = "组织"
	title.add_theme_color_override("font_color", INK)
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var refresh := _button(header, "刷新", "Refresh", 84.0)
	refresh.pressed.connect(func() -> void:
		_clear_status()
		refresh_requested.emit())
	var close_button := _button(header, "收起", "Close", 84.0)
	close_button.pressed.connect(func() -> void: close())
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
	_heading(body, "组织")
	_org_list = VBoxContainer.new()
	_org_list.name = "OrgList"
	_org_list.add_theme_constant_override("separation", 4)
	body.add_child(_org_list)
	_heading(body, "成员与职位")
	_member_list = VBoxContainer.new()
	_member_list.name = "MemberList"
	_member_list.add_theme_constant_override("separation", 4)
	body.add_child(_member_list)
	_heading(body, "创建")
	var create_row := HBoxContainer.new()
	create_row.add_theme_constant_override("separation", 8)
	body.add_child(create_row)
	_name = LineEdit.new()
	_name.name = "OrgName"
	_name.placeholder_text = "组织名称"
	_name.max_length = 64
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	create_row.add_child(_name)
	_create = _button(create_row, "创建组织", "CreateOrg", 120.0)
	_create.pressed.connect(_request_create)
	_heading(body, "管理")
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 8)
	body.add_child(join_row)
	_join = _button(join_row, "加入", "JoinOrg", 96.0)
	_join.pressed.connect(_request_join)
	_leave = _button(join_row, "退出", "LeaveOrg", 96.0)
	_leave.pressed.connect(_request_leave)
	var manage_row := HBoxContainer.new()
	manage_row.add_theme_constant_override("separation", 8)
	body.add_child(manage_row)
	_target = OptionButton.new()
	_target.name = "TargetMember"
	_target.custom_minimum_size.x = 200
	manage_row.add_child(_target)
	_appoint = _button(manage_row, "任命干事", "AppointOfficer", 120.0)
	_appoint.pressed.connect(_request_appoint)
	_transfer = _button(manage_row, "交接负责人", "TransferLeadership", 140.0)
	_transfer.pressed.connect(_request_transfer)
	_dissolve = _button(manage_row, "解散组织", "DissolveOrg", 120.0)
	_dissolve.pressed.connect(_request_dissolve)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	_confirm = ConfirmationDialog.new()
	_confirm.name = "DissolveConfirm"
	_confirm.title = "解散组织"
	# The embedded window does not inherit AcceptDialog's dark default panel;
	# use the same paper as the panel so the inherited ink text stays readable.
	_confirm.add_theme_stylebox_override("panel", FarmTheme.framed_paper(FarmTheme.PAPER))
	_confirm.add_theme_stylebox_override("embedded_border",
		FarmTheme.framed_paper(FarmTheme.PAPER))
	_confirm.add_theme_color_override("title_color", INK)
	_confirm.ok_button_text = "解散"
	_confirm.cancel_button_text = "取消"
	_confirm.confirmed.connect(_confirmed_dissolve)
	_confirm.canceled.connect(_discard_dissolve)
	_root.add_child(_confirm)
	visibility_changed.connect(_on_visibility_changed)
	hide()


## Rebuilds from the authoritative organization view. `can_write` is a view fact
## the scene decides from the world's role: named members may submit commands,
## visitors and anonymous connections may only read. `status` is the last
## authority `reason_text` (or the reason this view is read-only).
func present(next_organizations: Array, next_my_id: String, next_can_write: bool,
		status: String) -> void:
	var focus_key: String = FarmTheme.focus_key_within(_root)
	organizations = next_organizations.duplicate(true)
	my_id = next_my_id
	can_write = next_can_write
	_prune_selection()
	_fill_list()
	_fill_members()
	_sync_controls()
	_status.text = status
	_status_pending = not visible and not status.is_empty()
	if visible:
		FarmTheme.wrap_focus(_root, focus_key)


## The authority reply replaces the view like any refresh; a successful dissolve
## additionally shows the clearing total the authority already computed. The
## panel never picks refund recipients or derives per-member amounts.
func present_result(next_organizations: Array, next_my_id: String,
		next_can_write: bool, status: String, payload: Dictionary) -> void:
	present(next_organizations, next_my_id, next_can_write,
		_result_status(payload, status))


func show_status(text: String) -> void:
	_status.text = text
	_status_pending = not visible


func is_open() -> bool:
	return visible


func close() -> void:
	if not visible:
		return
	_target.get_popup().hide()
	_confirm.hide()
	_pending_dissolve = {}
	hide()
	closed.emit()


func is_popup_open() -> bool:
	return (_target != null and _target.get_popup().visible) \
		or (_name != null and _name.has_focus()) \
		or (_confirm != null and _confirm.visible)


func _prune_selection() -> void:
	if not selected_id.is_empty() and not _org_by_id(selected_id).is_empty():
		return
	selected_id = ""
	if not organizations.is_empty() and organizations[0] is Dictionary:
		selected_id = str((organizations[0] as Dictionary).get("id", ""))


func _fill_list() -> void:
	_clear(_org_list)
	if organizations.is_empty():
		_add(_org_list, "还没有组织。")
		return
	for value: Variant in organizations:
		if not value is Dictionary:
			continue
		var org: Dictionary = value
		var org_id: String = str(org.get("id", ""))
		var button := _button(_org_list, _org_text(org), "OrgAction_" + org_id, 0.0)
		button.toggle_mode = true
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.set_pressed_no_signal(org_id == selected_id)
		button.set_meta("org_id", org_id)
		button.set_meta("focus_key", "org:" + org_id)
		button.pressed.connect(_select.bind(org_id))


func _fill_members() -> void:
	_clear(_member_list)
	var org: Dictionary = _org_by_id(selected_id)
	if org.is_empty():
		_add(_member_list, "先选择一个组织。")
		return
	var members: Dictionary = _members_of(org)
	var ids: Array = members.keys()
	ids.sort()
	for player_id: Variant in ids:
		var who: String = str(player_id)
		var role: String = str(members[player_id])
		var label := Label.new()
		label.name = "Member_" + who
		label.text = "%s · %s%s" % [who, _role_text(role), "（我）" if who == my_id else ""]
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", INK)
		label.add_theme_font_size_override("font_size", 16)
		_member_list.add_child(label)


func _sync_controls() -> void:
	var org: Dictionary = _org_by_id(selected_id)
	var has_org: bool = not org.is_empty()
	var role: String = _role_of(org)
	var closed: bool = _is_closed(org)
	_name.editable = can_write
	_fill_targets(org)
	var has_target: bool = _target.item_count > 0
	_create.disabled = not can_write
	_join.disabled = not can_write or not has_org or not role.is_empty() or closed
	_leave.disabled = not can_write or not has_org or role.is_empty() or closed
	_appoint.disabled = not can_write or not has_org or not has_target or closed
	_transfer.disabled = not can_write or not has_org or not has_target or closed
	_target.disabled = not can_write or not has_org or not has_target or closed
	_dissolve.disabled = not can_write or not has_org or closed or role != "leader"


func _fill_targets(org: Dictionary) -> void:
	var previous: String = _selected_target()
	_target.clear()
	if not org.is_empty():
		var members: Dictionary = _members_of(org)
		var ids: Array = members.keys()
		ids.sort()
		for player_id: Variant in ids:
			var who: String = str(player_id)
			if who == my_id:
				continue
			_target.add_item("%s（%s）" % [who, _role_text(str(members[player_id]))])
			_target.set_item_metadata(_target.item_count - 1, who)
	var index: int = _target_index(previous)
	if index >= 0:
		_target.select(index)
	FarmTheme.configure_option(_target)


func _select(org_id: String) -> void:
	selected_id = org_id
	for child: Node in _org_list.get_children():
		if child is Button:
			(child as Button).set_pressed_no_signal(str(child.get_meta("org_id", "")) == org_id)
	_fill_members()
	_sync_controls()


func _request_create() -> void:
	if not can_write:
		return
	var name: String = _name.text.strip_edges()
	if name.is_empty():
		show_status("先写一个组织名称。")
		return
	_clear_status()
	org_action.emit("create", {"name": name})


func _request_join() -> void:
	if _join.disabled:
		return
	_clear_status()
	org_action.emit("join", {"org_id": selected_id})


func _request_leave() -> void:
	if _leave.disabled:
		return
	_clear_status()
	org_action.emit("leave", {"org_id": selected_id})


func _request_appoint() -> void:
	if _appoint.disabled:
		return
	var target: String = _selected_target()
	if target.is_empty():
		return
	_clear_status()
	org_action.emit("appoint", {"org_id": selected_id, "player_id": target,
		"role": "officer"})


func _request_transfer() -> void:
	if _transfer.disabled:
		return
	var target: String = _selected_target()
	if target.is_empty():
		return
	_clear_status()
	org_action.emit("transfer_leadership", {"org_id": selected_id, "player_id": target})


func _request_dissolve() -> void:
	if _dissolve.disabled or selected_id.is_empty():
		return
	_pending_dissolve = {"org_id": selected_id, "command_id": _new_command_id()}
	_confirm.dialog_text = "确定解散这个组织吗？解散不可撤销，组织资金会退还给缴入的成员。"
	_confirm.popup_centered()


func _confirmed_dissolve() -> void:
	if _pending_dissolve.is_empty():
		return
	var args: Dictionary = _pending_dissolve
	_pending_dissolve = {}
	_clear_status()
	org_action.emit("dissolve", args)


func _discard_dissolve() -> void:
	_pending_dissolve = {}


func _new_command_id() -> String:
	return "%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]


func _org_text(org: Dictionary) -> String:
	var role: String = _role_text(_role_of(org))
	if role.is_empty():
		role = "未加入"
	var closed: String = " · 已解散" if _is_closed(org) else ""
	return "%s · %d 人 · %s%s" % [str(org.get("name", "")), _members_of(org).size(),
		role, closed]


func _is_closed(org: Dictionary) -> bool:
	# Rows built before the status field existed stay active, not hidden.
	return str(org.get("status", "active")) == "closed"


## A dissolve success shows the authority's clearing total; anything else keeps
## the authority's own reason text. A plain success needs its own neutral line.
func _result_status(payload: Dictionary, status: String) -> String:
	if not bool(payload.get("ok", false)) or str(payload.get("action", "")) != "dissolve":
		return status
	var clearing_value: Variant = payload.get("clearing")
	if not clearing_value is Dictionary:
		return "组织已解散。"
	return "已解散，退还 %d 枚。" % _cleared_total(clearing_value as Dictionary)


## Sums the authoritative refund rows so one total is shown; it never decides who
## was refunded. An empty row list falls back to the cleared balance.
func _cleared_total(clearing: Dictionary) -> int:
	var rows_value: Variant = clearing.get("refunds")
	if rows_value is Array:
		var total: int = 0
		for row: Variant in rows_value:
			if row is Dictionary:
				total += int((row as Dictionary).get("amount", 0))
		return total
	return int(clearing.get("balance", 0))


func _role_of(org: Dictionary) -> String:
	if org.is_empty() or my_id.is_empty():
		return ""
	return str(_members_of(org).get(my_id, ""))


func _members_of(org: Dictionary) -> Dictionary:
	var value: Variant = org.get("members")
	if value is Dictionary:
		return value
	return {}


func _role_text(role: String) -> String:
	return str(ROLE_TEXT.get(role, ""))


func _org_by_id(org_id: String) -> Dictionary:
	if org_id.is_empty():
		return {}
	for value: Variant in organizations:
		if value is Dictionary and str((value as Dictionary).get("id", "")) == org_id:
			return value
	return {}


func _selected_target() -> String:
	if _target == null or _target.selected < 0:
		return ""
	return str(_target.get_item_metadata(_target.selected))


func _target_index(player_id: String) -> int:
	if player_id.is_empty():
		return -1
	for index: int in _target.item_count:
		if str(_target.get_item_metadata(index)) == player_id:
			return index
	return -1


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
	# Esc belongs to the panel: an open member dropdown takes the first Esc, the
	# next one closes the panel and returns focus to the HUD button that opened it.
	if not visible or not (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE):
		return
	if _confirm != null and _confirm.visible:
		_confirm.hide()
		_discard_dissolve()
		get_viewport().set_input_as_handled()
		return
	if _target != null and _target.get_popup().visible:
		_target.get_popup().hide()
		get_viewport().set_input_as_handled()
		return
	close()
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
