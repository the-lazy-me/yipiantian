extends CanvasLayer
## 邻里面板：把权威发来的社交视图摆出来，并把点击变成动作意图。
##
## 面板不判断“能不能邀请”或“是不是联系人”：那些规则在权威文档里，这里只
## 根据视图决定显示什么，再把动作交给调用方。因此没有网络也能测。
##
## 视图与名册都是整份替换，面板不合并增量。

signal action_requested(action: String, args: Dictionary)
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const INK := FarmTheme.INK

var view: Dictionary = {}
var roster: Array = []
var _root: Control
var _status: Label
var _online: VBoxContainer
var _invites: VBoxContainer
var _contacts: VBoxContainer
var _messages: VBoxContainer
var _grants: VBoxContainer
var _compose: LineEdit
var _target: OptionButton


func _ready() -> void:
	layer = 24
	_root = Control.new()
	_root.name = "Neighbors"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.theme = FarmTheme.create()
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.06, 0.08, 0.06, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var paper := PanelContainer.new()
	paper.custom_minimum_size = Vector2(560, 520)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	paper.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	column.add_child(header)
	var title := Label.new()
	title.text = "邻里"
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var refresh := _button(header, "刷新", 84.0)
	refresh.name = "Refresh"
	refresh.pressed.connect(func() -> void: action_requested.emit("state", {}))
	var close := _button(header, "收起", 84.0)
	close.name = "Close"
	close.pressed.connect(_close)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	scroll.add_child(list)
	_online = _section(list, "在线")
	_invites = _section(list, "邀请")
	_contacts = _section(list, "联系人")
	_messages = _section(list, "留言")
	_grants = _section(list, "照料授权")
	# Composer: one line and one target, so sending stays a single deliberate act.
	var compose_row := HBoxContainer.new()
	compose_row.add_theme_constant_override("separation", 8)
	list.add_child(compose_row)
	_compose = LineEdit.new()
	_compose.name = "Message"
	_compose.placeholder_text = "留一句话…"
	_compose.max_length = 200
	_compose.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	compose_row.add_child(_compose)
	_target = OptionButton.new()
	_target.name = "Target"
	_target.custom_minimum_size.x = 120
	compose_row.add_child(_target)
	var send := _button(compose_row, "发送", 84.0)
	send.name = "Send"
	send.pressed.connect(_send)
	hide()


## Rebuilds from the authoritative view. An empty view means the authority has
## not answered yet; that is different from "no neighbours", so it says so.
func present(next_view: Dictionary, next_roster: Array) -> void:
	view = next_view
	roster = next_roster
	_status.text = ""
	for section: VBoxContainer in [_online, _invites, _contacts, _messages, _grants]:
		_clear(section)
	if view.is_empty():
		_add(_online, "还没有收到世界的社交信息。")
	else:
		_fill_online()
		_fill_invites()
		_fill_contacts()
		_fill_messages()
		_fill_grants()
		_fill_targets()


func show_status(text: String) -> void:
	_status.text = text


func _fill_online() -> void:
	if roster.is_empty():
		_add(_online, "此刻只有你在这里。")
		return
	for row: Dictionary in roster:
		var name: String = str(row.get("name", ""))
		var who: String = name if not name.is_empty() else "一位匿名旅人"
		var role: String = {"member": "成员", "visitor": "访客"}.get(str(row.get("role", "")), "成员")
		_add(_online, "%s（%s）" % [who, role])


func _fill_invites() -> void:
	var pending: Array = view.get("pending", []) as Array
	if pending.is_empty():
		_add(_invites, "没有待答的邀请。")
		return
	for row: Dictionary in pending:
		var name: String = str(row.get("name", ""))
		if str(row.get("direction", "")) == "in":
			_row(_invites, "%s 想和你成为邻里" % name, [
				["接受", "accept", {"player_id": row.get("player_id", "")}],
				["拒绝", "decline", {"player_id": row.get("player_id", "")}],
			])
		else:
			_add(_invites, "已邀请 %s，等对方答复。" % name)


func _fill_contacts() -> void:
	var contacts: Array = view.get("contacts", []) as Array
	if contacts.is_empty():
		_add(_contacts, "还没有联系人。")
		return
	for row: Dictionary in contacts:
		var name: String = str(row.get("name", ""))
		_row(_contacts, name, [
			["允许收获", "grant", {"player_id": row.get("player_id", ""),
				"kinds": ["harvest"], "fields": [], "expires_at": 0.0}],
			["移除", "remove", {"player_id": row.get("player_id", "")}],
			["屏蔽", "block", {"player_id": row.get("player_id", ""), "reason": ""}],
		])


func _fill_messages() -> void:
	var inbox: Array = view.get("inbox", []) as Array
	if inbox.is_empty():
		_add(_messages, "还没有留言。")
		return
	for row: Dictionary in inbox:
		var who: String = str(row.get("from_name", ""))
		if who.is_empty(): who = "匿名旅人"
		var text: String = str(row.get("text", ""))
		var label: String = "%s：%s" % [who, text]
		if not bool(row.get("read", false)): label = "· " + label
		_row(_messages, label, [
			["已读", "read", {"id": row.get("id", "")}],
			["删除", "delete", {"id": row.get("id", "")}],
		])


func _fill_grants() -> void:
	var grants: Array = view.get("grants", []) as Array
	if grants.is_empty():
		_add(_grants, "还没有照料授权。")
		return
	for row: Dictionary in grants:
		var kinds: Array = row.get("kinds", []) as Array
		var fields: Array = row.get("fields", []) as Array
		var scope: String = "整座农场" if fields.is_empty() else "%d 块地" % fields.size()
		var expires: float = float(row.get("expires_at", 0.0))
		var limit: String = "不过期" if expires <= 0.0 else "限时"
		var who: String = str(row.get("to_name", "")) if str(row.get("direction", "")) == "out" \
			else str(row.get("from_name", ""))
		var label: String = "%s%s：%s · %s · %s" % [
			"给" if str(row.get("direction", "")) == "out" else "来自",
			who, "、".join(PackedStringArray(kinds)), scope, limit]
		if str(row.get("direction", "")) == "out":
			_row(_grants, label, [["撤销", "revoke", {"id": row.get("id", "")}]])
		else:
			_add(_grants, label)


func _fill_targets() -> void:
	_target.clear()
	_target.add_item("公开")
	_target.set_item_metadata(0, "")
	var contacts: Array = view.get("contacts", []) as Array
	for row: Dictionary in contacts:
		var name: String = str(row.get("name", ""))
		_target.add_item(name)
		_target.set_item_metadata(_target.item_count - 1, row.get("player_id", ""))


func _send() -> void:
	var text: String = _compose.text.strip_edges()
	if text.is_empty():
		show_status("先写一句话再发送。")
		return
	var to: String = ""
	if _target.selected >= 0:
		to = str(_target.get_item_metadata(_target.selected))
	action_requested.emit("send", {"to": to, "text": text})
	_compose.text = ""


func _close() -> void:
	hide()
	closed.emit()


# ------------------------------------------------------------------ helpers

func _section(parent: Control, title: String) -> VBoxContainer:
	var heading := Label.new()
	heading.text = title
	heading.add_theme_color_override("font_color", INK)
	heading.add_theme_font_size_override("font_size", 18)
	parent.add_child(heading)
	var rows := VBoxContainer.new()
	rows.name = title
	rows.add_theme_constant_override("separation", 4)
	parent.add_child(rows)
	return rows


func _add(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)


func _row(parent: Control, text: String, actions: Array) -> void:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	parent.add_child(box)
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(label)
	for action: Array in actions:
		var button := _button(box, str(action[0]), 76.0)
		button.name = str(action[0])
		var verb: String = str(action[1])
		var payload: Dictionary = action[2] as Dictionary
		button.pressed.connect(func() -> void: action_requested.emit(verb, payload))


func _button(parent: Control, text: String, width: float) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(width, 34)
	FarmTheme.pointer_focus(button)
	parent.add_child(button)
	return button


func _clear(node: Node) -> void:
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()
