extends Control
## 参与制度面板：把权威发来的参与视图摆出来，并把点击变成参与制度操作意图。
##
## 面板不判断房主身份、风险声明、角色或退战延迟：参与视图是权威给出的公开
## 房间事实，这里只据此决定显示什么，把动作原样交给调用方。因此没有网络也能测。
##
## 视图整份替换，面板不合并增量，也不乐观修改制度、参与者或损失。

signal participation_action(action: String, args: Dictionary)
signal refresh_requested
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const INK := FarmTheme.INK
const TIER_LIMITED: String = "limited"
const ROLE_ATTACKER: String = "attacker"
const ROLE_DEFENDER: String = "defender"

## 权威视图：`{available, host, sequence, regime, areas, windows, participants, losses}`。
var view: Dictionary = {}
## 当前客户端玩家 id；只用来决定房间制度区与玩家操作区是否显示，不参与授权判断。
var self_id: String = ""

var _focus_before: Control
## A message written while the panel is hidden belongs to the next open.
var _status_pending: bool = false
var _regime_label: Label
var _host_label: Label
var _area_list: VBoxContainer
var _window_list: VBoxContainer
var _participant_list: VBoxContainer
var _loss_list: VBoxContainer
var _host_section: VBoxContainer
var _player_section: VBoxContainer
var _tier: OptionButton
var _declaration_id: LineEdit
var _effective_utc: LineEdit
var _area_input: LineEdit
var _window_input: LineEdit
var _loss_cap: LineEdit
var _offline_loss_cap: LineEdit
var _declare_button: Button
var _role: OptionButton
var _consent_button: Button
var _withdraw_button: Button
var _status: Label
var _confirm: ConfirmationDialog
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
	title.text = "参与制度"
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
	_heading(body, "风险区域")
	_area_list = _list(body, "AreaList")
	_heading(body, "时间窗口")
	_window_list = _list(body, "WindowList")
	_heading(body, "参与者")
	_participant_list = _list(body, "ParticipantList")
	_heading(body, "损失累计")
	_loss_list = _list(body, "LossList")
	_host_section = VBoxContainer.new()
	_host_section.name = "HostSection"
	_host_section.add_theme_constant_override("separation", 10)
	body.add_child(_host_section)
	_heading(_host_section, "声明制度（房主）")
	var tier_row := HBoxContainer.new()
	tier_row.add_theme_constant_override("separation", 8)
	_host_section.add_child(tier_row)
	_tier = OptionButton.new()
	_tier.name = "Tier"
	_tier.custom_minimum_size.x = 140
	tier_row.add_child(_tier)
	_tier.add_item("和平")
	_tier.set_item_metadata(0, "peace")
	_tier.add_item("有限冲突")
	_tier.set_item_metadata(1, TIER_LIMITED)
	FarmTheme.configure_option(_tier)
	_declaration_id = LineEdit.new()
	_declaration_id.name = "DeclarationId"
	_declaration_id.placeholder_text = "声明 id"
	_declaration_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tier_row.add_child(_declaration_id)
	_effective_utc = LineEdit.new()
	_effective_utc.name = "EffectiveUtc"
	_effective_utc.placeholder_text = "生效 UTC 秒，留空为现在"
	_effective_utc.max_length = 18
	_effective_utc.custom_minimum_size.x = 200
	tier_row.add_child(_effective_utc)
	_area_input = LineEdit.new()
	_area_input.name = "AreaInput"
	_area_input.placeholder_text = "区域 id,min_x,min_z,max_x,max_z（分号分隔多个）"
	_area_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host_section.add_child(_area_input)
	_window_input = LineEdit.new()
	_window_input.name = "WindowInput"
	_window_input.placeholder_text = "窗口 id,start_utc,end_utc（分号分隔多个）"
	_window_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host_section.add_child(_window_input)
	var cap_row := HBoxContainer.new()
	cap_row.add_theme_constant_override("separation", 8)
	_host_section.add_child(cap_row)
	_loss_cap = LineEdit.new()
	_loss_cap.name = "LossCap"
	_loss_cap.placeholder_text = "在线上限"
	_loss_cap.max_length = 12
	_loss_cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cap_row.add_child(_loss_cap)
	_offline_loss_cap = LineEdit.new()
	_offline_loss_cap.name = "OfflineLossCap"
	_offline_loss_cap.placeholder_text = "离线上限"
	_offline_loss_cap.max_length = 12
	_offline_loss_cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cap_row.add_child(_offline_loss_cap)
	_declare_button = _button(_host_section, "声明制度", "DeclareRegime", 140.0)
	_declare_button.pressed.connect(_request_regime)
	_player_section = VBoxContainer.new()
	_player_section.name = "PlayerSection"
	_player_section.add_theme_constant_override("separation", 10)
	body.add_child(_player_section)
	_heading(_player_section, "参与")
	var player_row := HBoxContainer.new()
	player_row.add_theme_constant_override("separation", 8)
	_player_section.add_child(player_row)
	_role = OptionButton.new()
	_role.name = "Role"
	_role.custom_minimum_size.x = 140
	player_row.add_child(_role)
	_role.add_item("进攻方")
	_role.set_item_metadata(0, ROLE_ATTACKER)
	_role.add_item("防守方")
	_role.set_item_metadata(1, ROLE_DEFENDER)
	FarmTheme.configure_option(_role)
	_consent_button = _button(player_row, "同意参与", "Consent", 120.0)
	_consent_button.pressed.connect(_request_consent)
	_withdraw_button = _button(player_row, "申请退战", "Withdraw", 120.0)
	_withdraw_button.pressed.connect(_request_withdraw)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	_confirm = ConfirmationDialog.new()
	_confirm.name = "WithdrawConfirm"
	_confirm.ok_button_text = "申请退战"
	_confirm.cancel_button_text = "取消"
	_confirm.confirmed.connect(_confirmed_withdraw)
	add_child(_confirm)
	visibility_changed.connect(_on_visibility_changed)
	hide()


## Rebuilds from the authoritative participation view. The panel never merges
## rows itself; the next authority reply replaces the whole view.
func open_panel(next: Dictionary = {}) -> void:
	var focus_key: String = FarmTheme.focus_key_within(self)
	_apply_view(next)
	if not _status_pending:
		_status.text = ""
	_status_pending = false
	show()
	if visible:
		FarmTheme.wrap_focus(self, focus_key)


## The local player id only decides which actions are offered; the authority still
## decides whether the host or a participant may perform them.
func set_self_id(player_id: String) -> void:
	self_id = player_id
	_update_sections()


func show_status(text: String) -> void:
	_status.text = text
	_status_pending = not visible and not text.is_empty()


func is_open() -> bool:
	return visible


## True while the withdraw confirmation or a dropdown owns the next Esc.
func is_popup_open() -> bool:
	if _confirm.visible:
		return true
	for option: OptionButton in [_tier, _role]:
		if option.get_popup().visible:
			return true
	return false


func close_panel() -> void:
	if not visible:
		return
	_confirm.hide()
	for option: OptionButton in [_tier, _role]:
		option.get_popup().hide()
	hide()
	closed.emit()


## The authority reply is the only source of participation facts. A refused
## action keeps whatever view the reply carried and shows the authority's own
## reason text so the player sees why it was rejected.
func apply_result(_request_id: String, payload: Dictionary) -> void:
	var state_value: Variant = payload.get("state")
	if state_value is Dictionary:
		_apply_view(state_value)
	var text: String = str(payload.get("reason_text", ""))
	if text.is_empty():
		text = str(payload.get("reason", ""))
	if not bool(payload.get("ok", false)):
		show_status(text if not text.is_empty() else "参与制度操作被拒绝。")
		return
	if bool(payload.get("duplicate", false)):
		show_status("这条参与制度操作已经执行过。")
		return
	if str(payload.get("action", "")) == "withdraw":
		show_status("退战已登记，延迟结束后才正式退出。")
		return
	_clear_status()


func _apply_view(next: Dictionary) -> void:
	view = next.duplicate(true)
	_fill_view()


func _fill_view() -> void:
	_regime_label.text = _regime_text()
	_host_label.text = _host_text()
	_fill_list(_area_list, "areas", "Area",
		func(row: Dictionary) -> String: return str(row.get("id", "")),
		_area_text, "还没有声明风险区域。")
	_fill_list(_window_list, "windows", "Window",
		func(row: Dictionary) -> String: return str(row.get("id", "")),
		_window_text, "还没有声明时间窗口。")
	_fill_list(_participant_list, "participants", "Participant",
		func(row: Dictionary) -> String: return str(row.get("participant", "")),
		_participant_text, "还没有参与者。")
	_fill_list(_loss_list, "losses", "Loss",
		func(row: Dictionary) -> String: return "%s_%s" % [
			str(row.get("target", "")), str(row.get("window_id", "")),
		], _loss_text, "还没有损失。")
	_update_sections()


func _update_sections() -> void:
	if _host_section == null:
		return
	var available: bool = bool(view.get("available", false))
	var host: String = str(view.get("host", ""))
	var is_host: bool = available and not self_id.is_empty() and host == self_id
	var is_player: bool = available and not self_id.is_empty() and host != self_id
	_host_section.visible = is_host
	_player_section.visible = is_player


func _fill_list(node: VBoxContainer, key: String, prefix: String,
		name_of: Callable, text_of: Callable, empty_text: String) -> void:
	_clear(node)
	var count: int = 0
	var value: Variant = view.get(key)
	if value is Array:
		for row_value: Variant in value:
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			var label := Label.new()
			label.name = prefix + "_" + str(name_of.call(row))
			label.text = str(text_of.call(row))
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			label.add_theme_color_override("font_color", INK)
			label.add_theme_font_size_override("font_size", 16)
			node.add_child(label)
			count += 1
	if count == 0:
		_add(node, empty_text)


func _regime_text() -> String:
	var regime_value: Variant = view.get("regime")
	var regime: Dictionary = regime_value if regime_value is Dictionary else {}
	var tier: String = str(regime.get("tier", "peace"))
	if tier != TIER_LIMITED:
		return "和平：当前不开放交战。"
	var text: String = "有限冲突：第 %d 版｜声明 %s｜在线上限 %d｜离线上限 %d" % [
		int(regime.get("revision", 0)), str(regime.get("declaration_id", "")),
		int(regime.get("loss_cap", 0)), int(regime.get("offline_loss_cap", 0)),
	]
	var effective: float = float(regime.get("effective_utc", 0.0))
	if effective > 0.0:
		text += "｜生效 %d" % int(effective)
	return text


func _host_text() -> String:
	var host: String = str(view.get("host", ""))
	if host.is_empty():
		return "房主 未登记"
	if host == self_id and not self_id.is_empty():
		return "房主 %s（你）" % host
	return "房主 %s" % host


func _area_text(row: Dictionary) -> String:
	return "%s｜X %d–%d｜Z %d–%d" % [
		str(row.get("id", "")), int(row.get("min_x", 0)), int(row.get("max_x", 0)),
		int(row.get("min_z", 0)), int(row.get("max_z", 0)),
	]


func _window_text(row: Dictionary) -> String:
	return "%s｜开始 %d｜结束 %d" % [
		str(row.get("id", "")), int(float(row.get("start_utc", 0.0))),
		int(float(row.get("end_utc", 0.0))),
	]


func _participant_text(row: Dictionary) -> String:
	var roles: Array[String] = []
	if bool(row.get("attacker", false)):
		roles.append("进攻方")
	if bool(row.get("defender", false)):
		roles.append("防守方")
	var role_text: String = "、".join(PackedStringArray(roles)) if not roles.is_empty() else "无角色"
	var text: String = "%s｜%s｜同意第 %d 版" % [
		str(row.get("participant", "")), role_text, int(row.get("consent_revision", 0)),
	]
	var withdraw_utc: float = float(row.get("withdraw_utc", 0.0))
	if withdraw_utc > 0.0:
		text += "｜退战登记 %d，生效 %d" % [
			int(withdraw_utc), int(float(row.get("withdraw_effective_utc", 0.0))),
		]
	return text


func _loss_text(row: Dictionary) -> String:
	return "%s｜窗口 %s｜累计 %d" % [
		str(row.get("target", "")), str(row.get("window_id", "")),
		int(row.get("amount", 0)),
	]


func _request_regime() -> void:
	if _declare_button.disabled:
		return
	var declaration_id: String = _declaration_id.text.strip_edges()
	if declaration_id.is_empty():
		show_status("先填写声明 id。")
		return
	var effective: float = _effective_utc_value(_effective_utc.text)
	if effective < 0.0:
		show_status("生效时间请填写非负的 UTC 秒。")
		return
	var tier: String = _selected_meta(_tier)
	var declaration: Dictionary = {
		"tier": tier, "declaration_id": declaration_id, "effective_utc": effective,
		"higher_risk": tier == TIER_LIMITED, "areas": [], "windows": [],
		"loss_cap": 0, "offline_loss_cap": 0,
	}
	if tier == TIER_LIMITED:
		var areas: Dictionary = _parse_areas(_area_input.text)
		if not bool(areas.ok):
			show_status(str(areas.reason))
			return
		var windows: Dictionary = _parse_windows(_window_input.text)
		if not bool(windows.ok):
			show_status(str(windows.reason))
			return
		if (areas.rows as Array).is_empty():
			show_status("有限冲突至少要声明一个风险区域。")
			return
		if (windows.rows as Array).is_empty():
			show_status("有限冲突至少要声明一个时间窗口。")
			return
		var loss_cap: int = _positive_int(_loss_cap.text)
		var offline_cap: int = _positive_int(_offline_loss_cap.text)
		if loss_cap <= 0 or offline_cap <= 0:
			show_status("损失上限请填写正整数。")
			return
		if offline_cap > loss_cap:
			show_status("离线上限不能高于在线上限。")
			return
		declaration.areas = areas.rows
		declaration.windows = windows.rows
		declaration.loss_cap = loss_cap
		declaration.offline_loss_cap = offline_cap
	_clear_status()
	participation_action.emit("regime", {
		"command_id": _new_request_id("regime"), "declaration": declaration,
	})


func _request_consent() -> void:
	if _consent_button.disabled:
		return
	var role: String = _selected_meta(_role)
	if role.is_empty():
		show_status("先选择参战角色。")
		return
	_clear_status()
	participation_action.emit("declare", {
		"command_id": _new_request_id("declare"), "role": role,
	})


## Withdrawal cannot be cancelled while its delay runs, so a click only opens a
## confirmation; the request is sent after the player confirms.
func _request_withdraw() -> void:
	if _withdraw_button.disabled:
		return
	_confirm.dialog_text = "确定申请退战吗？退战会延迟生效。"
	_confirm.popup_centered()


func _confirmed_withdraw() -> void:
	_clear_status()
	participation_action.emit("withdraw", {
		"command_id": _new_request_id("withdraw"),
	})


## A declaration needs a valid effective time. Leaving the field empty uses the
## local clock; the authority still decides whether the declaration is acceptable.
func _effective_utc_value(text: String) -> float:
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty():
		return float(Time.get_unix_time_from_system())
	if not trimmed.is_valid_float():
		return -1.0
	var value: float = float(trimmed)
	if value < 0.0:
		return -1.0
	return value


func _parse_areas(text: String) -> Dictionary:
	var rows: Array = []
	for entry: String in _entries(text):
		var parts: PackedStringArray = entry.split(",")
		if parts.size() != 5:
			return {"ok": false,
				"reason": "区域请按 区域 id,min_x,min_z,max_x,max_z 填写。"}
		var area_id: String = parts[0].strip_edges()
		if area_id.is_empty():
			return {"ok": false, "reason": "区域 id 不能为空。"}
		var numbers: Array[int] = []
		for index: int in range(1, 5):
			var piece: String = parts[index].strip_edges()
			if not piece.is_valid_int():
				return {"ok": false, "reason": "区域坐标请填写整数。"}
			numbers.append(int(piece))
		if numbers[0] > numbers[2] or numbers[1] > numbers[3]:
			return {"ok": false, "reason": "区域的最小坐标不能大于最大坐标。"}
		rows.append({
			"id": area_id, "min_x": numbers[0], "min_z": numbers[1],
			"max_x": numbers[2], "max_z": numbers[3],
		})
	return {"ok": true, "rows": rows}


func _parse_windows(text: String) -> Dictionary:
	var rows: Array = []
	for entry: String in _entries(text):
		var parts: PackedStringArray = entry.split(",")
		if parts.size() != 3:
			return {"ok": false, "reason": "窗口请按 窗口 id,start_utc,end_utc 填写。"}
		var window_id: String = parts[0].strip_edges()
		if window_id.is_empty():
			return {"ok": false, "reason": "窗口 id 不能为空。"}
		var start_text: String = parts[1].strip_edges()
		var end_text: String = parts[2].strip_edges()
		if not start_text.is_valid_float() or not end_text.is_valid_float():
			return {"ok": false, "reason": "窗口时间请填写 UTC 秒。"}
		var start_utc: float = float(start_text)
		var end_utc: float = float(end_text)
		if start_utc < 0.0 or end_utc <= start_utc:
			return {"ok": false, "reason": "窗口的结束时间必须晚于开始时间。"}
		rows.append({"id": window_id, "start_utc": start_utc, "end_utc": end_utc})
	return {"ok": true, "rows": rows}


func _entries(text: String) -> Array[String]:
	var output: Array[String] = []
	for chunk: String in text.replace("\n", ";").split(";", false):
		var entry: String = chunk.strip_edges()
		if not entry.is_empty():
			output.append(entry)
	return output


func _positive_int(text: String) -> int:
	var trimmed: String = text.strip_edges()
	if not trimmed.is_valid_int():
		return -1
	var value: int = int(trimmed)
	if value < 1:
		return -1
	return value


func _selected_meta(option: OptionButton) -> String:
	if option.selected < 0:
		return ""
	return str(option.get_item_metadata(option.selected))


func _new_request_id(action: String) -> String:
	_request_counter += 1
	return "participation-%s-%d-%d" % [action, Time.get_ticks_usec(), _request_counter]


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
	# withdraw confirmation takes the first Esc; the next one closes the panel.
	if not visible or not (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE):
		return
	if _confirm.visible:
		_confirm.hide()
		get_viewport().set_input_as_handled()
		return
	for option: OptionButton in [_tier, _role]:
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
