extends Control
## 交战面板：把权威发来的交战视图摆出来，并把点击变成一次交战请求。
##
## 面板不判断参与同意、单位归属、损失上限或资产余额：目标和近期结果都是权威
## 给出的公开事实，交战参数原样转发。这里只检查空字段与坐标的整数格式，因此
## 没有网络也能测。
##
## 视图整份替换，面板不合并增量，也不本地计算战利品或补全未下发的战报字段。

signal conflict_action(action: String, args: Dictionary)
signal refresh_requested
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const INK := FarmTheme.INK
const TIER_LIMITED: String = "limited"

## 权威交战视图：`{sequence, targets, recent}`。
var view: Dictionary = {}
## 交战视图不下发制度与房主；它们来自参与制度视图，只用于只读展示。
var participation: Dictionary = {}
## 权威目标行，按 key 排序；面板只渲染它们，不推导上限或损失。
var targets: Array = []
## 权威近期结果摘要，按 command_id 排序；字段缺失时少显示，不补造战报。
var recent: Array = []

var _focus_before: Control
## A message written while the panel is hidden belongs to the next open.
var _status_pending: bool = false
var _regime_label: Label
var _host_label: Label
var _target_list: VBoxContainer
var _recent_list: VBoxContainer
var _defender: LineEdit
var _attacker_units: LineEdit
var _defender_units: LineEdit
var _x: LineEdit
var _z: LineEdit
var _target_parcel: LineEdit
var _engage_button: Button
var _status: Label
var _confirm: ConfirmationDialog
var _pending_engage: Dictionary = {}
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
	title.text = "交战"
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
	_heading(body, "当前制度")
	_regime_label = _add(body, "")
	_regime_label.name = "Regime"
	_host_label = _add(body, "")
	_host_label.name = "Host"
	_heading(body, "目标")
	_target_list = _list(body, "TargetList")
	_heading(body, "近期结果")
	_recent_list = _list(body, "RecentList")
	_heading(body, "发起交战")
	var defender_row := HBoxContainer.new()
	defender_row.add_theme_constant_override("separation", 8)
	body.add_child(defender_row)
	_defender = LineEdit.new()
	_defender.name = "Defender"
	_defender.placeholder_text = "防守者玩家 id"
	_defender.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	defender_row.add_child(_defender)
	var x_row := HBoxContainer.new()
	x_row.add_theme_constant_override("separation", 8)
	body.add_child(x_row)
	_x = LineEdit.new()
	_x.name = "X"
	_x.placeholder_text = "x 坐标"
	_x.max_length = 12
	_x.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	x_row.add_child(_x)
	_z = LineEdit.new()
	_z.name = "Z"
	_z.placeholder_text = "z 坐标"
	_z.max_length = 12
	_z.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	x_row.add_child(_z)
	_target_parcel = LineEdit.new()
	_target_parcel.name = "TargetParcel"
	_target_parcel.placeholder_text = "目标地块 id（可留空）"
	_target_parcel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_target_parcel)
	_attacker_units = LineEdit.new()
	_attacker_units.name = "AttackerUnits"
	_attacker_units.placeholder_text = "进攻单位 id，逗号分隔"
	_attacker_units.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_attacker_units)
	_defender_units = LineEdit.new()
	_defender_units.name = "DefenderUnits"
	_defender_units.placeholder_text = "防守单位 id，逗号分隔"
	_defender_units.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_defender_units)
	_engage_button = _button(body, "交战", "Engage", 140.0)
	_engage_button.pressed.connect(_request_engage)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	_confirm = ConfirmationDialog.new()
	_confirm.name = "EngageConfirm"
	_confirm.ok_button_text = "交战"
	_confirm.cancel_button_text = "取消"
	_confirm.confirmed.connect(_confirmed_engage)
	_confirm.canceled.connect(func() -> void: _pending_engage = {})
	add_child(_confirm)
	_fill_view()
	visibility_changed.connect(_on_visibility_changed)
	hide()


## Rebuilds from the authoritative conflict view. The panel never merges rows
## itself; the next authority reply replaces the whole view.
func open_panel(next: Dictionary = {}) -> void:
	var focus_key: String = FarmTheme.focus_key_within(self)
	_apply_view(next)
	if not _status_pending:
		_status.text = ""
	_status_pending = false
	show()
	if visible:
		FarmTheme.wrap_focus(self, focus_key)


## The regime and host are not part of the conflict view; the caller supplies the
## last authoritative participation view so the read-only header stays honest.
func set_participation(next: Dictionary) -> void:
	participation = next.duplicate(true)
	_fill_participation()


func show_status(text: String) -> void:
	_status.text = text
	_status_pending = not visible and not text.is_empty()


func is_open() -> bool:
	return visible


## True while the engage confirmation owns the next Esc.
func is_popup_open() -> bool:
	return _confirm != null and _confirm.visible


func close_panel() -> void:
	if not visible:
		return
	_confirm.hide()
	_pending_engage = {}
	hide()
	closed.emit()


## The authority reply is the only source of conflict facts. A refused action
## keeps whatever view the reply carried and shows the authority's own reason
## text; the panel never invents an outcome.
func apply_result(_request_id: String, payload: Dictionary) -> void:
	var state_value: Variant = payload.get("state")
	if state_value is Dictionary:
		_apply_view(state_value)
	var text: String = str(payload.get("reason_text", ""))
	if text.is_empty():
		text = str(payload.get("reason", ""))
	if not bool(payload.get("ok", false)):
		show_status(text if not text.is_empty() else "交战操作被拒绝。")
		return
	if bool(payload.get("duplicate", false)):
		show_status("这次交战已经结算过。")
		return
	if str(payload.get("action", "")) == "engage":
		show_status("交战已结算。")
		return
	_clear_status()


func _apply_view(next: Dictionary) -> void:
	view = next.duplicate(true)
	targets = _target_rows(view)
	recent = _recent_rows(view)
	_fill_view()


func _fill_view() -> void:
	_fill_participation()
	_fill_targets()
	_fill_recent()


func _fill_participation() -> void:
	if _regime_label == null:
		return
	_regime_label.text = _regime_text()
	_host_label.text = _host_text()


func _regime_text() -> String:
	var regime_value: Variant = participation.get("regime")
	var regime: Dictionary = regime_value if regime_value is Dictionary else {}
	var tier: String = str(regime.get("tier", ""))
	if tier == TIER_LIMITED:
		return "有限冲突：第 %d 版｜在线上限 %d｜离线上限 %d" % [
			int(regime.get("revision", 0)), int(regime.get("loss_cap", 0)),
			int(regime.get("offline_loss_cap", 0)),
		]
	if tier == "peace":
		return "和平：当前不开放交战。"
	return "当前制度未载入。"


func _host_text() -> String:
	var host: String = str(participation.get("host", ""))
	if host.is_empty():
		return "房主 未登记"
	return "房主 %s" % host


func _fill_targets() -> void:
	_clear(_target_list)
	if targets.is_empty():
		_add(_target_list, "还没有交战目标。")
		return
	for value: Variant in targets:
		var row: Dictionary = value
		var label := Label.new()
		label.name = "Target_" + str(row.get("key", ""))
		label.text = _target_text(row)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", INK)
		label.add_theme_font_size_override("font_size", 16)
		_target_list.add_child(label)


func _fill_recent() -> void:
	_clear(_recent_list)
	if recent.is_empty():
		_add(_recent_list, "还没有交战结果。")
		return
	for value: Variant in recent:
		var row: Dictionary = value
		var label := Label.new()
		label.name = "Recent_" + str(row.get("command_id", ""))
		label.text = _recent_text(row)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", INK)
		label.add_theme_font_size_override("font_size", 16)
		_recent_list.add_child(label)


func _target_text(row: Dictionary) -> String:
	var target: String = str(row.get("target", ""))
	var parcel: String = str(row.get("parcel_id", ""))
	return "%s｜防守者 %s｜地块 %s｜累计损失 %d/%d" % [
		str(row.get("key", "")), target,
		parcel if not parcel.is_empty() else "未绑定",
		int(row.get("lost", 0)), int(row.get("cap", 0)),
	]


## Only fields the authority actually sent are shown. A summary without a full
## battle report therefore renders a shorter line instead of guessing.
func _recent_text(row: Dictionary) -> String:
	var parts: Array[String] = []
	parts.append(str(row.get("command_id", "")))
	if row.has("attacker") or row.has("defender"):
		parts.append("%s → %s" % [
			str(row.get("attacker", "")), str(row.get("defender", "")),
		])
	var parcel: String = str(row.get("parcel_id", ""))
	if not parcel.is_empty():
		parts.append("地块 %s" % parcel)
	for field: Array in [
		["troops", "兵力"], ["losses", "损失"], ["taken_cash", "损失现金"],
		["taken_supplies", "损失物资"], ["spoils_cash", "缴获现金"],
		["spoils_supplies", "缴获物资"], ["destroyed", "摧毁"],
		["supply_cost", "补给消耗"],
	]:
		if row.has(field[0]):
			parts.append("%s %d" % [field[1], int(row.get(field[0], 0))])
	if row.has("at_utc") and float(row.get("at_utc", 0.0)) > 0.0:
		parts.append("UTC %d" % int(float(row.get("at_utc", 0.0))))
	var window_id: String = str(row.get("window_id", ""))
	if not window_id.is_empty():
		parts.append("窗口 %s" % window_id)
	if row.has("target_lost_after") or row.has("target_cap"):
		parts.append("目标 %d/%d" % [
			int(row.get("target_lost_after", 0)), int(row.get("target_cap", 0)),
		])
	if row.has("defender_online"):
		parts.append("防守方在线" if bool(row.get("defender_online", false)) else "防守方离线")
	return "｜".join(PackedStringArray(parts))


func _request_engage() -> void:
	if _engage_button.disabled:
		return
	var defender: String = _defender.text.strip_edges()
	if defender.is_empty():
		show_status("先填写防守者玩家 id。")
		return
	var attacker: Dictionary = _parse_units(_attacker_units.text, "进攻单位 id")
	if not bool(attacker.get("ok", false)):
		show_status(str(attacker.get("reason", "")))
		return
	var protecting: Dictionary = _parse_units(_defender_units.text, "防守单位 id")
	if not bool(protecting.get("ok", false)):
		show_status(str(protecting.get("reason", "")))
		return
	var x: Dictionary = _coordinate(_x.text, "x")
	if not bool(x.get("ok", false)):
		show_status(str(x.get("reason", "")))
		return
	var z: Dictionary = _coordinate(_z.text, "z")
	if not bool(z.get("ok", false)):
		show_status(str(z.get("reason", "")))
		return
	# The request id doubles as the authority's command id; retries replay as the
	# same command instead of creating a second battle.
	var request_id: String = _new_request_id("engage")
	_pending_engage = {
		"command_id": request_id,
		"defender": defender,
		"attacker_units": attacker.ids,
		"defender_units": protecting.ids,
		"x": int(x.value),
		"z": int(z.value),
	}
	var parcel: String = _target_parcel.text.strip_edges()
	if not parcel.is_empty():
		_pending_engage["target_parcel"] = parcel
	# A battle cannot be undone, so the click only opens a confirmation; the
	# request is sent after the player confirms.
	_confirm.dialog_text = "确定发起交战吗？交战不可撤销，双方的损失与战利品会立即结算。"
	_confirm.popup_centered()


func _confirmed_engage() -> void:
	if _pending_engage.is_empty():
		return
	var args: Dictionary = _pending_engage
	_pending_engage = {}
	_clear_status()
	conflict_action.emit("engage", args)


## Splits a comma-separated unit list. Only blank fields are refused here; unit
## existence, ownership and participation consent stay with the authority.
func _parse_units(text: String, label: String) -> Dictionary:
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty():
		return {"ok": false, "reason": "先填写%s。" % label}
	var ids: Array = []
	for piece: String in trimmed.split(",", true):
		var unit_id: String = piece.strip_edges()
		if unit_id.is_empty():
			return {"ok": false, "reason": "%s 请用逗号分隔填写。" % label}
		ids.append(unit_id)
	return {"ok": true, "ids": ids}


## Coordinates are integers; their world bounds are an authority decision.
func _coordinate(text: String, label: String) -> Dictionary:
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty():
		return {"ok": false, "reason": "%s 坐标请填写整数。" % label}
	if not trimmed.is_valid_int():
		return {"ok": false, "reason": "%s 坐标请填写整数。" % label}
	return {"ok": true, "value": int(trimmed)}


func _new_request_id(action: String) -> String:
	_request_counter += 1
	return "conflict-%s-%d-%d" % [action, Time.get_ticks_usec(), _request_counter]


## Copies the rows so the panel's view never aliases the authority document, and
## sorts by target key regardless of reply order.
func _target_rows(source: Dictionary) -> Array:
	var rows: Array = []
	var value: Variant = source.get("targets")
	if value is Array:
		for row_value: Variant in value:
			if row_value is Dictionary:
				rows.append((row_value as Dictionary).duplicate(true))
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("key", "")) < str(b.get("key", "")))
	return rows


func _recent_rows(source: Dictionary) -> Array:
	var rows: Array = []
	var value: Variant = source.get("recent")
	if value is Array:
		for row_value: Variant in value:
			if row_value is Dictionary:
				rows.append((row_value as Dictionary).duplicate(true))
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("command_id", "")) < str(b.get("command_id", "")))
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
	# Esc belongs to the panel only while it is open. The engage confirmation
	# takes the first Esc; the next one closes the panel.
	if not visible or not (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE):
		return
	if _confirm.visible:
		_confirm.hide()
		_pending_engage = {}
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
