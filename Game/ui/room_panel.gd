extends CanvasLayer
## 联机入口：把一串加入码交给游戏，或者在这台电脑上开一间房。
##
## 面板只收集意图：加入码由玩家粘贴，建房由启动场景真正执行。它不碰网络、
## 不判断加入码是否有效，因此可以在没有服务器的环境里测。

signal join_requested(code: String)
signal host_requested
signal local_requested
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const INK := FarmTheme.INK

var _root: Control
var _status: Label
var _name: LineEdit
var _code: LineEdit
var _join: Button
var _host: Button
var _room_row: HBoxContainer
var _room_code: LineEdit
var _enter: Button
var _local: Button
var _busy: bool = false
var _focus_before: Control


func _ready() -> void:
	layer = 30
	_root = Control.new()
	_root.name = "Room"
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
	paper.custom_minimum_size = Vector2(600, 0)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	paper.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	column.add_child(header)
	var title := Label.new()
	title.text = "一起种田"
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close := _button(header, "收起", 84.0)
	close.name = "Close"
	close.pressed.connect(_close)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)

	var name_heading := Label.new()
	name_heading.text = "你的名字"
	name_heading.add_theme_font_size_override("font_size", 18)
	name_heading.add_theme_color_override("font_color", INK)
	column.add_child(name_heading)
	_name = LineEdit.new()
	_name.name = "PlayerName"
	_name.placeholder_text = "邻居怎么称呼你"
	_name.max_length = 24
	column.add_child(_name)

	var join_heading := Label.new()
	join_heading.text = "去朋友的农场"
	join_heading.add_theme_font_size_override("font_size", 18)
	join_heading.add_theme_color_override("font_color", INK)
	column.add_child(join_heading)
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 8)
	column.add_child(join_row)
	_code = LineEdit.new()
	_code.name = "Code"
	_code.placeholder_text = "粘贴房主给你的加入码…"
	_code.max_length = 8192
	_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code.text_submitted.connect(func(_text: String) -> void: _submit_join())
	join_row.add_child(_code)
	_join = _button(join_row, "加入", 84.0)
	_join.name = "Join"
	_join.pressed.connect(_submit_join)

	var host_heading := Label.new()
	host_heading.text = "在这台电脑上开一间房"
	host_heading.add_theme_font_size_override("font_size", 18)
	host_heading.add_theme_color_override("font_color", INK)
	column.add_child(host_heading)
	_host = _button(column, "开房并邀请朋友", 200.0)
	_host.name = "Host"
	_host.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_host.pressed.connect(func() -> void:
		if _busy: return
		host_requested.emit())
	var hint := Label.new()
	hint.text = "房间开在这台电脑上，朋友需要和你在同一个网络。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", FarmTheme.Tokens.MUTED)
	column.add_child(hint)

	_room_row = HBoxContainer.new()
	_room_row.name = "RoomCode"
	_room_row.add_theme_constant_override("separation", 8)
	column.add_child(_room_row)
	_room_code = LineEdit.new()
	_room_code.editable = false
	_room_code.max_length = 8192
	_room_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_row.add_child(_room_code)
	var copy := _button(_room_row, "复制", 68.0)
	copy.name = "Copy"
	copy.pressed.connect(_copy)
	_room_row.hide()
	_enter = _button(column, "进入这间房", 200.0)
	_enter.name = "Enter"
	_enter.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_enter.pressed.connect(func() -> void:
		if _busy: return
		join_requested.emit(_room_code.text))
	_enter.hide()
	_local = _button(column, "先自己种田", 200.0)
	_local.name = "Local"
	_local.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_local.hide()
	_local.pressed.connect(func() -> void: local_requested.emit())
	visibility_changed.connect(_on_visibility_changed)
	hide()


## The name is remembered by the game, not decided here; the panel only carries
## it while the player is choosing a room.
func set_player_name(value: String) -> void:
	_name.text = value


func player_name() -> String:
	return _name.text.strip_edges()


## Idle: paste a code or start a room. Nothing is in flight.
func show_idle() -> void:
	_busy = false
	_join.disabled = false
	_host.disabled = false
	_code.editable = true
	_name.editable = true
	_room_row.hide()
	_enter.hide()
	_local.hide()
	_status.text = "把一个世界的加入码粘贴到这里，或者自己开一间。"
	show()


## The player asked to join; the game is working on it.
func show_joining() -> void:
	_busy = true
	_join.disabled = true
	_host.disabled = true
	_code.editable = false
	_name.editable = false
	_status.text = "正在进入世界…"
	show()


## A room answered: show the code the host can share and let them enter it.
func show_room(join_code: String) -> void:
	_busy = false
	_join.disabled = true
	_host.disabled = true
	_code.editable = false
	_room_code.text = join_code
	_room_row.show()
	_enter.show()
	_local.hide()
	# The name is still editable here: entering the room needs one.
	_name.editable = true
	_status.text = "房间已经开好。把这串加入码发给朋友，然后进入这间房。"
	show()


## A failure left the player to decide: retry by hand or go back to a local farm.
func show_failure(message: String) -> void:
	_busy = false
	_join.disabled = false
	_host.disabled = false
	_code.editable = true
	_name.editable = true
	_room_row.hide()
	_enter.hide()
	_local.show()
	_status.text = message
	show()


func show_status(text: String) -> void:
	_status.text = text


func is_open() -> bool:
	return visible


## Main/startup Esc handling can ask this before dismissing the whole panel: a
## focused text field owns the first Esc.
func is_popup_open() -> bool:
	return (_name != null and _name.has_focus()) or (_code != null and _code.has_focus()) \
		or (_room_code != null and _room_code.has_focus())


func _input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE):
		return
	if _dismiss_popup():
		get_viewport().set_input_as_handled()


func _dismiss_popup() -> bool:
	for field: LineEdit in [_name, _code, _room_code]:
		if field != null and field.has_focus():
			field.release_focus()
			return true
	return false


func _submit_join() -> void:
	if _busy: return
	var text: String = _code.text.strip_edges()
	if text.is_empty():
		show_status("先粘贴房主给你的加入码。")
		_code.grab_focus()
		return
	join_requested.emit(text)


func _copy() -> void:
	DisplayServer.clipboard_set(_room_code.text)
	show_status("加入码已复制，发给朋友即可。")


func _close() -> void:
	hide()
	closed.emit()


func _on_visibility_changed() -> void:
	if visible:
		if _focus_before == null and is_inside_tree():
			_focus_before = get_viewport().gui_get_focus_owner()
		# Visibility propagates after this signal, so take focus on the next idle.
		_focus_after_show.call_deferred()
	else:
		if _focus_before != null and is_instance_valid(_focus_before) and _focus_before.is_inside_tree():
			_focus_before.grab_focus()
		_focus_before = null


func _focus_after_show() -> void:
	if visible:
		FarmTheme.wrap_focus(_root)


func _button(parent: Control, text: String, width: float) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(width, 36)
	FarmTheme.pointer_focus(button)
	parent.add_child(button)
	return button
