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
const Crops = preload("res://farm/crop_catalog.gd")
const INK := FarmTheme.INK

var view: Dictionary = {}
var roster: Array = []
var _root: Control
var _focus_before: Control
## A message written while the panel is hidden belongs to the next open.
var _status_pending: bool = false
var _status: Label
var _online: VBoxContainer
var _invites: VBoxContainer
var _contacts: VBoxContainer
var _messages: VBoxContainer
var _grants: VBoxContainer
var _compose: LineEdit
var _target: OptionButton
## 送礼用自己口袋里的收成；面板不判断余额，权威会拒绝超额的那一份。
var bag: Dictionary = {}
var _gift_crop: OptionButton
var _gift_target: OptionButton
var _gift_button: Button
var _gift_hint: Label
## 房主的加入码：面板不会过期，房主忘了复制也能再拿一次。
var _room_row: HBoxContainer
var _room_code: LineEdit
## 偷菜开关只代表权威回给我的状态；勾选不在这里生效，等下一次视图回来。
var _theft_box: CheckBox
var _theft_syncing: bool = false


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
	refresh.pressed.connect(func() -> void:
		_clear_status()
		action_requested.emit("state", {}))
	var close := _button(header, "收起", 84.0)
	close.name = "Close"
	close.pressed.connect(self.close)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	_room_row = HBoxContainer.new()
	_room_row.name = "RoomCode"
	_room_row.add_theme_constant_override("separation", 8)
	_room_row.hide()
	column.add_child(_room_row)
	var room_label := Label.new()
	room_label.text = "房间加入码"
	_room_row.add_child(room_label)
	_room_code = LineEdit.new()
	_room_code.editable = false
	_room_code.max_length = 8192
	_room_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_row.add_child(_room_code)
	var room_copy := _button(_room_row, "复制", 68.0)
	room_copy.name = "CopyRoom"
	room_copy.pressed.connect(func() -> void:
		_clear_status()
		DisplayServer.clipboard_set(_room_code.text)
		show_status("加入码已复制，发给朋友即可。"))
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.follow_focus = true
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
	var theft_row := HBoxContainer.new()
	theft_row.add_theme_constant_override("separation", 8)
	list.add_child(theft_row)
	_theft_box = CheckBox.new()
	_theft_box.name = "AllowTheft"
	_theft_box.text = "允许邻居偷一份成熟收成"
	_theft_box.tooltip_text = "开启后别人可以收走你种的作物，每天最多 3 份，同一人 10 分钟内只能取一次。"
	_theft_box.add_theme_color_override("font_color", INK)
	_theft_box.toggled.connect(_on_theft_toggled)
	theft_row.add_child(_theft_box)
	var gift_heading := Label.new()
	gift_heading.text = "送一份收成"
	gift_heading.add_theme_color_override("font_color", INK)
	gift_heading.add_theme_font_size_override("font_size", 18)
	list.add_child(gift_heading)
	var gift_row := HBoxContainer.new()
	gift_row.add_theme_constant_override("separation", 8)
	list.add_child(gift_row)
	_gift_crop = OptionButton.new()
	_gift_crop.name = "GiftCrop"
	_gift_crop.custom_minimum_size.x = 140
	gift_row.add_child(_gift_crop)
	_gift_target = OptionButton.new()
	_gift_target.name = "GiftTarget"
	_gift_target.custom_minimum_size.x = 120
	gift_row.add_child(_gift_target)
	_gift_button = _button(gift_row, "送出", 76.0)
	_gift_button.name = "Gift"
	_gift_button.pressed.connect(_send_gift)
	_gift_hint = Label.new()
	_gift_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	list.add_child(_gift_hint)
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
	_compose.text_submitted.connect(func(_text: String) -> void: _send())
	visibility_changed.connect(_on_visibility_changed)
	hide()


## Rebuilds from the authoritative view. An empty view means the authority has
## not answered yet; that is different from "no neighbours", so it says so.
func present(next_view: Dictionary, next_roster: Array, next_bag: Dictionary = {},
		theft_enabled: bool = false) -> void:
	var focus_key: String = FarmTheme.focus_key_within(_root)
	var target_id: String = _selected_metadata(_target)
	var gift_crop: String = _selected_metadata(_gift_crop)
	var gift_target: String = _selected_metadata(_gift_target)
	view = next_view
	roster = next_roster
	bag = next_bag
	_theft_syncing = true
	if _theft_box != null:
		_theft_box.button_pressed = theft_enabled
	_theft_syncing = false
	# A refresh keeps the last success or refusal; opening clears it unless the
	# game wrote it while the panel was closed, and a new action clears it.
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
		_fill_targets(target_id)
		_fill_gift(gift_crop, gift_target)
	if visible:
		FarmTheme.wrap_focus(_root, focus_key)


func show_status(text: String) -> void:
	_status.text = text
	_status_pending = not visible


func _on_theft_toggled(enabled: bool) -> void:
	# The checkbox only states an intention; the authority decides, and the next
	# view carries the result back.
	if _theft_syncing:
		return
	_clear_status()
	action_requested.emit("set_theft", {"enabled": enabled})


## Only a host has a code to share; a member passes an empty string.
func show_room_code(code: String) -> void:
	_room_code.text = code
	_room_row.visible = not code.is_empty()


func _fill_online() -> void:
	if roster.is_empty():
		_add(_online, "此刻只有你在这里。")
		return
	# A player who is not already a contact or a pending invitation can be asked
	# to become a neighbour from here; the authority still decides whether the
	# invitation is allowed, so this is only an intent.
	var known: Dictionary = {}
	for row: Dictionary in view.get("contacts", []) as Array:
		known[str(row.get("player_id", ""))] = true
	for row: Dictionary in view.get("pending", []) as Array:
		known[str(row.get("player_id", ""))] = true
	var viewer: String = str(view.get("player_id", ""))
	for row: Dictionary in roster:
		var name: String = str(row.get("name", ""))
		var who: String = name if not name.is_empty() else "一位匿名旅人"
		var role: String = {"member": "成员", "visitor": "访客"}.get(str(row.get("role", "")), "成员")
		var player_id: String = str(row.get("player_id", ""))
		var label: String = "%s（%s）" % [who, role]
		if player_id.is_empty() or player_id == viewer or known.has(player_id):
			_add(_online, label)
		else:
			_row(_online, label, [
				["邀请为邻里", "invite", {"player_id": player_id, "name": name}],
			])


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
			# An empty field list is the issuer's own crops, not the whole farm:
			# the authority resolves the real cell owner for every harvest.
			["允许收获（我的）", "grant", {"player_id": row.get("player_id", ""),
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
		# `owned` comes from the authority: an empty harvest grant covers only
		# crops the issuer planted, not every field in the world.
		var scope: String
		match str(row.get("scope", "")):
			"owned": scope = "自己的作物"
			"whole": scope = "整座农场"
			"fields": scope = "%d 块地" % fields.size()
			_: scope = "整座农场" if fields.is_empty() else "%d 块地" % fields.size()
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


## Only produce the player actually owns is offered; an empty bag says so
## rather than opening an empty picker.
func _fill_gift(previous_crop: String = "", previous_target: String = "") -> void:
	_gift_crop.clear()
	_gift_target.clear()
	for crop_id: String in Crops.crop_ids():
		var count: int = int(bag.get(crop_id, 0))
		if count <= 0: continue
		_gift_crop.add_item("%s ×%d" % [str(Crops.definition(crop_id).get("name", crop_id)), count])
		_gift_crop.set_item_metadata(_gift_crop.item_count - 1, crop_id)
	var contacts: Array = view.get("contacts", []) as Array
	for row: Dictionary in contacts:
		_gift_target.add_item(str(row.get("name", "")))
		_gift_target.set_item_metadata(_gift_target.item_count - 1, row.get("player_id", ""))
	var crop_index: int = _metadata_index(_gift_crop, previous_crop)
	if crop_index >= 0:
		_gift_crop.select(crop_index)
	var target_index: int = _metadata_index(_gift_target, previous_target)
	if target_index >= 0:
		_gift_target.select(target_index)
	FarmTheme.configure_option(_gift_crop)
	FarmTheme.configure_option(_gift_target)
	var ready: bool = _gift_crop.item_count > 0 and _gift_target.item_count > 0
	_gift_button.disabled = not ready
	if _gift_crop.item_count == 0:
		_gift_hint.text = "还没有收成可以送。"
	elif _gift_target.item_count == 0:
		_gift_hint.text = "先和一位邻居成为联系人，才能送东西。"
	else:
		_gift_hint.text = "送出一份，数量固定为 1。"


func _send_gift() -> void:
	_clear_status()
	if _gift_crop.selected < 0 or _gift_target.selected < 0:
		show_status("先选一份收成和一位邻居。")
		return
	action_requested.emit("gift", {
		"player_id": _gift_target.get_item_metadata(_gift_target.selected),
		"crop_id": _gift_crop.get_item_metadata(_gift_crop.selected),
		"amount": 1,
	})


func _fill_targets(previous: String = "") -> void:
	_target.clear()
	_target.add_item("公开")
	_target.set_item_metadata(0, "")
	var contacts: Array = view.get("contacts", []) as Array
	for row: Dictionary in contacts:
		var name: String = str(row.get("name", ""))
		_target.add_item(name)
		_target.set_item_metadata(_target.item_count - 1, row.get("player_id", ""))
	var index: int = _metadata_index(_target, previous)
	if index >= 0:
		_target.select(index)
	FarmTheme.configure_option(_target)


func _selected_metadata(option: OptionButton) -> String:
	if option == null or option.selected < 0:
		return ""
	return str(option.get_item_metadata(option.selected))


func _metadata_index(option: OptionButton, value: String) -> int:
	for index: int in option.item_count:
		if str(option.get_item_metadata(index)) == value:
			return index
	return -1


func _send() -> void:
	_clear_status()
	var text: String = _compose.text.strip_edges()
	if text.is_empty():
		show_status("先写一句话再发送。")
		return
	var to: String = ""
	if _target.selected >= 0:
		to = str(_target.get_item_metadata(_target.selected))
	action_requested.emit("send", {"to": to, "text": text})
	_compose.text = ""


## The scene closes the panel on Esc; the button uses the same path.
func close() -> void:
	if not visible:
		return
	hide()
	closed.emit()


func is_popup_open() -> bool:
	for option: OptionButton in [_gift_crop, _gift_target, _target]:
		if option != null and option.get_popup().visible:
			return true
	return (_compose != null and _compose.has_focus()) or (_room_code != null and _room_code.has_focus())


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
	# Main handles Esc for the whole panel; an open recipient or gift dropdown
	# takes the first Esc so choosing a person never closes the panel.
	if not visible or not (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE):
		return
	if _dismiss_popup():
		get_viewport().set_input_as_handled()


func _dismiss_popup() -> bool:
	for option: OptionButton in [_gift_crop, _gift_target, _target]:
		if option != null and option.get_popup().visible:
			option.get_popup().hide()
			return true
	for field: LineEdit in [_compose, _room_code]:
		if field != null and field.has_focus():
			field.release_focus()
			return true
	return false


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
		button.set_meta("focus_key", "%s|%s" % [verb, str(payload.get("player_id", payload.get("id", "")))])
		button.pressed.connect(func() -> void:
			_clear_status()
			action_requested.emit(verb, payload))


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
