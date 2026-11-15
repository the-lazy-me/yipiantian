extends Control
## 居民对话面板：只读显示权威 `dialogues_view()`，并把点按变成一次 `say` 意图。
##
## 面板不推导人格或关系、不预测回复、不写任何文档；冷却、日上限、邀约门限与
## 拒绝原因都由权威决定。视图整份替换，面板只做两处显示换算：
## `今日剩余 = daily_limit - daily_affinity`，以及按行内 `ready`、冷却剩余和
## 日额度决定按钮能否点按。这不是规则回放：权威仍可拒绝任何一次对话。
##
## 视图形状见 `HeadlessWorld.dialogues_view()`。面板只渲染本人行与本人最近的
## 回复，不请求、也不显示其他玩家的对话状态。

signal dialogue_intent(action: String, args: Dictionary)
signal refresh_requested
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const NpcDialogue = preload("res://npc/npc_dialogue.gd")
const INK := FarmTheme.INK

## 七类固定话语的按钮文字；键与 `NpcDialogue.CATEGORIES` 一致。
const CATEGORY_LABELS: Dictionary = {
	"greet": "问候",
	"ask_work": "问农事",
	"ask_market": "问行情",
	"apologize": "道歉",
	"thank": "道谢",
	"invite": "邀约",
	"farewell": "告别",
}

## RECORD-17 只下发 `reply_kind`，中文正文在这里维护；未知 id 原样显示。
const REPLY_LABELS: Dictionary = {
	"reply_greet_warm": "他回应得温和，和你多聊了几句。",
	"reply_greet_neutral": "他点头回应了你的问候。",
	"reply_greet_guarded": "他略显戒备地应了一声。",
	"reply_work_recorded": "他看过你的农事记录，问了几句田里的事。",
	"reply_work_unrecorded": "他说还没有看到你的农事记录。",
	"reply_market_recorded": "他提起了最近一笔公开成交的价格。",
	"reply_market_unrecorded": "他说最近的行情还没有记录。",
	"reply_apology_accepted": "他接受了你的道歉。",
	"reply_apology_withheld": "他没有马上接受你的道歉。",
	"reply_thanks_warm": "他摆摆手，说心意收下了。",
	"reply_thanks_neutral": "他应了一声，收下了你的道谢。",
	"reply_invite_consider": "他说会考虑你的邀约。",
	"reply_farewell": "他向你道别。",
}

## 权威拒绝原因的中文兜底；答复带 `reason_text` 时优先用权威原文。
const REASON_LABELS: Dictionary = {
	"not_open": "世界尚未打开。",
	"not_a_member": "尚未加入这个世界。",
	"forbidden": "当前身份不能执行这个操作。",
	"read_only": "世界正在迁移，暂时只读。",
	"no_player": "玩家身份无效。",
	"invalid_player": "玩家身份无效。",
	"unknown_action": "未知的对话操作。",
	"invalid_request": "对话请求无效。",
	"invalid_npc": "找不到这位居民。",
	"invalid_category": "这句话的类型无效。",
	"invalid_command": "对话编号无效。",
	"command_conflict": "这个对话编号已经用于另一次对话。",
	"duplicate": "这次对话已经记录过了。",
	"cooldown": "这位居民刚和你聊过，请稍后再来。",
	"low_affinity": "你和这位居民还不够熟。",
	"not_inclined": "这位居民现在不想答应。",
	"disabled": "居民对话尚未启用。",
	"invalid_time": "时间无效。",
	"invalid_state": "对话状态无效。",
	"invalid_memory": "居民记忆无法写入。",
	"dialogue_capacity": "这位居民认识的人已经太多了。",
	"payload_too_large": "指令过大。",
	"rate_limited": "请求太频繁，请稍后再试。",
}

const UNAVAILABLE_LABELS: Dictionary = {
	"not_open": "世界尚未打开",
	"disabled": "居民对话尚未启用",
	"not_a_member": "尚未加入这个世界",
}

## 权威对话视图：`{available, reason, viewer, is_member, now_utc, residents,
## recent}`。`residents` 只含本人行，`recent` 只含本人最近回复。
var view: Dictionary = {}
## 权威居民行，按权威顺序保留；面板不排序、不补行。
var residents: Array = []
## 本人最近的回复行，按权威顺序保留。
var recent: Array = []
## 当前选中的居民 id；只用于决定请求对象与按钮显隐，不作为授权依据。
var selected_npc_id: String = ""

var _focus_before: Control
## A message written while the panel is hidden belongs to the next open.
var _status_pending: bool = false
var _status_line: Label
var _resident_list: VBoxContainer
var _recent_section: VBoxContainer
var _recent_list: VBoxContainer
var _action_section: VBoxContainer
var _target: OptionButton
var _hint: Label
## `category -> Button`；七类按钮只创建一次，随后只切换禁用状态。
var _buttons: Dictionary = {}
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
	paper.custom_minimum_size = Vector2(900, 680)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	paper.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	column.add_child(header)
	var title := Label.new()
	title.text = "对话"
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
	_status_line = Label.new()
	_status_line.name = "DialogueStatus"
	_status_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status_line)
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
	_heading(body, "居民")
	_resident_list = _list(body, "DialogueList")
	_recent_section = VBoxContainer.new()
	_recent_section.name = "RecentSection"
	_recent_section.add_theme_constant_override("separation", 4)
	body.add_child(_recent_section)
	_heading(_recent_section, "最近对话")
	_recent_list = _list(_recent_section, "RecentList")
	_build_action_section(body)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	visibility_changed.connect(_on_visibility_changed)
	_fill_view()
	hide()


func _build_action_section(body: VBoxContainer) -> void:
	_action_section = VBoxContainer.new()
	_action_section.name = "ActionSection"
	_action_section.add_theme_constant_override("separation", 8)
	body.add_child(_action_section)
	_heading(_action_section, "说点什么")
	_target = OptionButton.new()
	_target.name = "TargetSelect"
	_target.custom_minimum_size.x = 320
	_target.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	FarmTheme.configure_option(_target)
	_target.item_selected.connect(_on_target_selected)
	_action_section.add_child(_target)
	_hint = Label.new()
	_hint.name = "ActionHint"
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_action_section.add_child(_hint)
	var grid := GridContainer.new()
	grid.name = "CategoryButtons"
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	_action_section.add_child(grid)
	for category: String in NpcDialogue.CATEGORIES:
		var button := _button(grid, str(CATEGORY_LABELS.get(category, category)),
			"Say_" + category, 150.0)
		button.pressed.connect(func() -> void: _say(category))
		_buttons[category] = button


## Rebuilds from the authoritative dialogue view. The next reply replaces the
## whole view; the panel never merges rows or invents a resident.
func open_panel(next: Dictionary = {}) -> void:
	var focus_key: String = FarmTheme.focus_key_within(self)
	_apply_view(next)
	if not _status_pending:
		_status.text = ""
	_status_pending = false
	show()
	if visible:
		FarmTheme.wrap_focus(self, focus_key)


## Clears the view and renders the unavailable state without showing the panel.
## Used when the world is single-player or the connection is gone.
func show_unavailable(reason: String = "not_open") -> void:
	_apply_view({
		"available": false, "reason": reason, "viewer": "", "is_member": false,
		"now_utc": 0.0, "residents": [], "recent": [],
	})


func show_status(text: String) -> void:
	_status.text = text
	_status_pending = not visible and not text.is_empty()


func is_open() -> bool:
	return visible


## True while the target dropdown owns the next Esc.
func is_popup_open() -> bool:
	return _target != null and _target.get_popup().visible


func close_panel() -> void:
	if not visible:
		return
	if _target != null:
		_target.get_popup().hide()
	hide()
	closed.emit()


## The authority reply is the only source of dialogue facts. A refusal keeps the
## last confirmed view and shows the authority's own reason text; a success shows
## the replied template and replaces the view with the reply's state.
func apply_result(payload: Dictionary) -> void:
	var state_value: Variant = payload.get("state")
	if state_value is Dictionary:
		_apply_view(state_value)
	if not bool(payload.get("ok", false)):
		show_status(_refusal_text(payload))
		return
	if bool(payload.get("duplicate", false)):
		show_status(str(REASON_LABELS.get("duplicate", "这次对话已经记录过了。")))
		return
	var kind: String = str(payload.get("reply_kind", ""))
	if kind.is_empty():
		show_status("对话已记录。")
		return
	show_status(_reply_text(kind))


func _apply_view(next: Dictionary) -> void:
	view = next.duplicate(true)
	residents = _resident_rows(view.get("residents"))
	recent = _dict_rows(view.get("recent"))
	_fill_view()


func _fill_view() -> void:
	if _resident_list == null:
		return
	var available: bool = bool(view.get("available", false))
	_status_line.text = _availability_text(available)
	_resident_list.visible = available
	_clear(_resident_list)
	if available:
		if residents.is_empty():
			_add(_resident_list, "还没有居民。")
		else:
			for row_value: Variant in residents:
				_build_resident(row_value as Dictionary)
	_fill_recent(available)
	_action_section.visible = available
	_fill_targets(available)
	_sync_actions()


func _availability_text(available: bool) -> String:
	if available:
		return "对话已启用｜%d 位居民" % residents.size()
	var reason: String = str(view.get("reason", ""))
	if reason.is_empty():
		return "世界尚未打开"
	return str(UNAVAILABLE_LABELS.get(reason, reason))


func _build_resident(row: Dictionary) -> void:
	var npc_id: String = str(row.get("id", ""))
	var label := Label.new()
	label.name = "Dialogue_" + npc_id
	label.text = _resident_text(row)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", INK)
	label.add_theme_font_size_override("font_size", 16)
	_resident_list.add_child(label)


## 行内只展示权威字段。`今日剩余` 是显示换算，冷却文案取行内剩余秒数；面板不
## 判定关系、模板或邀约资格。
func _resident_text(row: Dictionary) -> String:
	var npc_id: String = str(row.get("id", ""))
	var display_name: String = str(row.get("display_name", ""))
	if display_name.is_empty():
		display_name = npc_id
	var daily: int = int(row.get("daily_affinity", 0))
	var limit: int = int(row.get("daily_limit", 0))
	var remaining: int = maxi(0, limit - daily)
	return "%s（%s）｜最近对话 %s｜今日剩余 %d / %d｜%s" % [
		display_name, npc_id, _utc_text(row.get("last_dialogue_utc", 0.0)),
		remaining, limit, _cooldown_text(row),
	]


func _cooldown_text(row: Dictionary) -> String:
	var cooldown: float = float(row.get("cooldown_remaining", 0.0))
	if cooldown > 0.0:
		return "冷却中，还需约 %d 秒" % ceili(cooldown)
	if bool(row.get("ready", false)):
		return "可以对话"
	return "暂不可对话"


func _fill_recent(available: bool) -> void:
	_recent_section.visible = available
	_clear(_recent_list)
	if not available:
		return
	if recent.is_empty():
		_add(_recent_list, "还没有对话记录。")
		return
	for index: int in recent.size():
		var row: Dictionary = recent[index]
		# The command id comes from a client request and may contain characters
		# Godot forbids in node names; the index is the stable local key.
		var label := _add(_recent_list, _recent_text(row), "Recent_%d" % index)
		label.add_theme_color_override("font_color", INK)
		label.add_theme_font_size_override("font_size", 16)


func _recent_text(row: Dictionary) -> String:
	var npc_id: String = str(row.get("npc_id", ""))
	return "%s｜%s｜UTC %d" % [
		_resident_name(npc_id), _reply_text(str(row.get("reply_kind", ""))),
		int(float(row.get("at_utc", 0.0))),
	]


func _fill_targets(available: bool) -> void:
	_target.clear()
	_target.disabled = not available or residents.is_empty()
	if not available or residents.is_empty():
		selected_npc_id = ""
		return
	var keep: String = selected_npc_id
	var keep_index: int = -1
	for row_value: Variant in residents:
		var row: Dictionary = row_value
		var npc_id: String = str(row.get("id", ""))
		if npc_id.is_empty():
			continue
		_target.add_item("%s（%s）" % [_resident_name(npc_id), npc_id])
		_target.set_item_metadata(_target.item_count - 1, npc_id)
		if npc_id == keep:
			keep_index = _target.item_count - 1
	if keep_index >= 0:
		_target.select(keep_index)
	elif _target.item_count > 0:
		_target.select(0)
	selected_npc_id = str(_target.get_item_metadata(_target.selected)) \
		if _target.selected >= 0 else ""


func _on_target_selected(index: int) -> void:
	if index < 0 or index >= _target.item_count:
		selected_npc_id = ""
	else:
		selected_npc_id = str(_target.get_item_metadata(index))
	_sync_actions()


## 按钮是否可点只由视图决定：权威说 `ready=false`、仍在冷却或今日额度已满时
## 禁用，并把原因写在按钮上方。真正能否成交仍由权威裁决。
func _sync_actions() -> void:
	if _buttons.is_empty():
		return
	var available: bool = bool(view.get("available", false))
	var row: Dictionary = _selected_row()
	var enabled: bool = available and not row.is_empty() and _can_say(row)
	for category: String in NpcDialogue.CATEGORIES:
		var button: Button = _buttons.get(category) as Button
		if button != null:
			button.disabled = not enabled
	_hint.text = _hint_text(available, row)


func _can_say(row: Dictionary) -> bool:
	if not bool(row.get("ready", false)):
		return false
	return int(row.get("daily_affinity", 0)) < int(row.get("daily_limit", 0))


func _hint_text(available: bool, row: Dictionary) -> String:
	if not available:
		return ""
	if row.is_empty():
		return "先选择一位居民。"
	var cooldown: float = float(row.get("cooldown_remaining", 0.0))
	if cooldown > 0.0:
		return "这位居民刚和你聊过，还需要等 %d 秒。" % ceili(cooldown)
	var daily: int = int(row.get("daily_affinity", 0))
	var limit: int = int(row.get("daily_limit", 0))
	if daily >= limit:
		return "今日对话点数已用完，明天再来吧。"
	if not bool(row.get("ready", false)):
		return "这位居民现在不能对话。"
	return ""


func _say(category: String) -> void:
	if not NpcDialogue.CATEGORIES.has(category):
		return
	var row: Dictionary = _selected_row()
	# Disabled buttons cannot be pressed by a pointer, but a programmatic signal
	# or a stale focus ring must not turn a cooled-down row into an intent.
	if row.is_empty() or not _can_say(row):
		return
	_clear_status()
	dialogue_intent.emit("say", {
		"command_id": _new_request_id(category),
		"npc_id": selected_npc_id,
		"category": category,
	})


func _selected_row() -> Dictionary:
	for row_value: Variant in residents:
		if row_value is Dictionary \
				and str((row_value as Dictionary).get("id", "")) == selected_npc_id:
			return row_value
	return {}


func _resident_name(npc_id: String) -> String:
	for row_value: Variant in residents:
		if row_value is Dictionary \
				and str((row_value as Dictionary).get("id", "")) == npc_id:
			var name: String = str((row_value as Dictionary).get("display_name", ""))
			if not name.is_empty():
				return name
	return npc_id


func _reply_text(kind: String) -> String:
	return str(REPLY_LABELS.get(kind, kind))


func _refusal_text(payload: Dictionary) -> String:
	var text: String = str(payload.get("reason_text", ""))
	if not text.is_empty():
		return text
	var reason: String = str(payload.get("reason", ""))
	if reason.is_empty():
		return "对话被拒绝。"
	if REASON_LABELS.has(reason):
		return str(REASON_LABELS[reason])
	if reason.begins_with("save_resident_state_"):
		return "居民状态未能保存这次对话。"
	return reason


func _utc_text(value: Variant) -> String:
	var number: float = float(value)
	return "UTC %d" % int(number) if number > 0.0 else "未记录"


func _new_request_id(category: String) -> String:
	_request_counter += 1
	return "dialogue-%s-%d-%d" % [category, Time.get_ticks_usec(), _request_counter]


## Copies the rows in the authority's own order. Rows without a dictionary shape
## are skipped; a resident row without an id cannot be targeted.
func _resident_rows(value: Variant) -> Array:
	var rows: Array = _dict_rows(value)
	var kept: Array = []
	for row_value: Variant in rows:
		var row: Dictionary = row_value
		if not str(row.get("id", "")).is_empty():
			kept.append(row)
	return kept


func _dict_rows(value: Variant) -> Array:
	var rows: Array = []
	if not value is Array:
		return rows
	for row_value: Variant in value:
		if row_value is Dictionary:
			rows.append((row_value as Dictionary).duplicate(true))
	return rows


func _on_visibility_changed() -> void:
	if visible:
		if _focus_before == null and is_inside_tree():
			_focus_before = get_viewport().gui_get_focus_owner()
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
	if _target != null and _target.get_popup().visible:
		_target.get_popup().hide()
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


func _add(parent: Control, text: String, node_name: String = "") -> Label:
	var label := Label.new()
	if not node_name.is_empty():
		label.name = node_name
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _list(parent: Control, node_name: String) -> VBoxContainer:
	var list := VBoxContainer.new()
	list.name = node_name
	list.add_theme_constant_override("separation", 4)
	parent.add_child(list)
	return list


func _button(parent: Control, text: String, node_name: String, width: float) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(width, 40)
	FarmTheme.pointer_focus(button)
	parent.add_child(button)
	return button


func _clear(node: Node) -> void:
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()
