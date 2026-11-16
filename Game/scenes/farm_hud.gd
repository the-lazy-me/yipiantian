extends CanvasLayer
## UI owns presentation and emits intent; it never changes farm state.

signal palette_requested(palette: String)
signal cancel_tool_requested
signal tool_requested(tool: String)
signal tool_press_started(tool: String)
signal crop_requested(crop_id: String)
signal retry_requested
signal recovery_requested
signal exit_requested
signal settings_requested
signal preview_hour_requested(hour: float)
signal time_preview_opened
signal basket_requested
signal construction_requested
signal social_requested
signal homes_requested
signal market_requested
signal bank_requested
signal organization_requested
signal unit_requested
signal fund_requested
signal participation_requested
signal public_works_requested
signal conflict_requested
signal dispute_requested
signal residents_requested
signal resolutions_requested
signal dialogue_requested

const Crops = preload("res://farm/crop_catalog.gd")
const FarmTheme = preload("res://ui/farm_theme.gd")
const WeatherMood = preload("res://presentation/weather_mood.gd")
const DisasterMood = preload("res://presentation/disaster_mood.gd")
const INK := FarmTheme.INK
## Text-only entries in the world row. Each label is two characters, so the
## shared theme's 18px side insets would waste width; a 10px inset keeps the
## pigment surface in a 62px entry. Twelve entries on their own centred row
## fit inside the 1552px available width.
const TEXT_ENTRY_WIDTH: float = 62.0
const TEXT_ENTRY_INSET: float = 10.0
var _basket: Button
var _build: Button
var _social: Button
var _homes: Button
var _market: Button
var _bank: Button
var _organization: Button
var _unit: Button
var _fund: Button
var _participation: Button
var _public_works: Button
var _conflict: Button
var _dispute: Button
var _residents: Button
var _dialogue: Button
var _resolutions: Button
var _settings: Button
var _tools: HBoxContainer
var _world: HBoxContainer
var _tool_row: HBoxContainer
var _palette: String = ""
var _decorating: bool = false
var _row_tweens: Dictionary = {}
var _row_open: Dictionary = {}
var _crop_row: HBoxContainer
var _crop_buttons: Dictionary = {}
var _buttons: Dictionary = {}
var _storage_overlay: ColorRect
var _storage_message: Label
var _retry: Button
var _recover: Button
var _exit: Button
var _time_panel: PanelContainer
var _time_slider: HSlider
var _preview_minutes: int = -1
var _notice: Label
var _notice_timer: Timer
var _environment: Label
var _weather: Label
var _disaster: Label
var _top_lines: VBoxContainer


func _ready() -> void:
	layer = 10
	var root := Control.new()
	root.name = "Layout"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.theme = FarmTheme.create()
	_build_farm_controls(root)
	if OS.is_debug_build() and OS.has_feature("editor"):
		_build_time_preview(root)
	_build_storage_overlay(root)
	# The four read-only lines share one stack, so a wrapped notice pushes the
	# soil/weather/disaster lines down instead of drawing over them.
	_top_lines = VBoxContainer.new()
	_top_lines.name = "TopLines"
	_top_lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top_lines.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_top_lines.offset_left = -280.0
	_top_lines.offset_right = 280.0
	_top_lines.offset_top = 28.0
	_top_lines.add_theme_constant_override("separation", 4)
	root.add_child(_top_lines)
	_build_notice(_top_lines)
	_build_environment_info(_top_lines)
	_build_weather_info(_top_lines)
	_build_disaster_info(_top_lines)


func _build_farm_controls(root: Control) -> void:
	# Shared-world entries sit on their own row above the five farm tools. One
	# 17-entry strip had no slack left at 1600px and mixed two very different
	# scopes; two centred rows keep both readable without hiding any entry.
	_world = HBoxContainer.new()
	_world.name = "WorldControls"
	root.add_child(_world)
	_world.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_world.anchor_left = 0.0
	_world.anchor_right = 1.0
	_world.offset_left = 24
	_world.offset_right = -24
	_world.offset_top = -118
	_world.offset_bottom = -72
	_world.alignment = BoxContainer.ALIGNMENT_CENTER
	_world.add_theme_constant_override("separation", 8)
	_world.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tools = HBoxContainer.new()
	_tools.name = "FarmControls"
	root.add_child(_tools)
	_tools.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	# Span the whole width and centre the entries, so the bar never depends on a
	# hand-tuned half width that an added entry would silently outgrow.
	_tools.anchor_left = 0.0
	_tools.anchor_right = 1.0
	_tools.offset_left = 24
	_tools.offset_right = -24
	_tools.offset_top = -66
	_tools.offset_bottom = -18
	_tools.alignment = BoxContainer.ALIGNMENT_CENTER
	_tools.add_theme_constant_override("separation", 8)
	_tools.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for item: Array in [["sow", "种植", "Sow"], ["tools", "工具", "Tools"]]:
		var entry := _toolbar_button(item[1], "res://art/ui/toolbar/plant.png" if item[0] == "sow" else "res://art/ui/toolbar/tools.png")
		entry.name = item[2]
		entry.toggle_mode = true
		entry.pressed.connect(func() -> void: palette_requested.emit(item[0]))
	_basket = _toolbar_button("菜篮", "res://art/ui/toolbar/basket.png")
	_basket.name = "OpenBasket"
	_basket.pressed.connect(func() -> void: basket_requested.emit())
	_build = _toolbar_button("建设", "res://art/ui/toolbar/build.png")
	_build.name = "BuildIsland"
	_build.pressed.connect(func() -> void: construction_requested.emit())
	# Presence and the market have no dedicated artwork yet; a text entry keeps
	# the bar honest instead of borrowing an icon that means something else.
	_market = _text_entry("市场")
	_market.name = "Market"
	_market.pressed.connect(func() -> void: market_requested.emit())
	_bank = _text_entry("银行")
	_bank.name = "Bank"
	_bank.pressed.connect(func() -> void: bank_requested.emit())
	# 组织只在共享世界里成立；入口始终可见，单机点击后由场景说明需要进入共享
	# 世界，不虚构本地组织。
	_organization = _text_entry("组织")
	_organization.name = "Organization"
	_organization.pressed.connect(func() -> void: organization_requested.emit())
	# 单位名册只存在于共享世界；入口始终可见，单机点击后由场景说明需要进入
	# 共享世界，不虚构本地名册。
	_unit = _text_entry("单位")
	_unit.name = "Units"
	_unit.pressed.connect(func() -> void: unit_requested.emit())
	# 公共基金只存在于共享世界；入口始终可见，单机点击后由场景说明需要进入
	# 共享世界，不虚构本地基金。
	_fund = _text_entry("基金")
	_fund.name = "Funds"
	_fund.pressed.connect(func() -> void: fund_requested.emit())
	# 参与制度只存在于共享世界；入口始终可见，单机点击后由场景说明需要进入
	# 共享世界，不虚构本地制度。
	_participation = _text_entry("参战")
	_participation.name = "Participation"
	_participation.pressed.connect(func() -> void: participation_requested.emit())
	# 公共项目只存在于共享世界；入口始终可见，单机点击后由场景说明需要进入
	# 共享世界，不虚构本地项目。
	_public_works = _text_entry("公建")
	_public_works.name = "PublicWorks"
	_public_works.pressed.connect(func() -> void: public_works_requested.emit())
	# 交战只存在于共享世界；入口始终可见，单机点击后由场景说明需要进入共享
	# 世界，不虚构本地战场。
	_conflict = _text_entry("交战")
	_conflict.name = "Conflict"
	_conflict.pressed.connect(func() -> void: conflict_requested.emit())
	# 纠纷只存在于共享世界；入口始终可见，单机点击后由场景说明需要进入共享
	# 世界，不虚构本地案件或管理员。
	_dispute = _text_entry("纠纷")
	_dispute.name = "Dispute"
	_dispute.pressed.connect(func() -> void: dispute_requested.emit())
	# 居民只读视图只存在于共享世界；入口始终可见，单机点击后由场景说明需要
	# 进入共享世界，不虚构本地居民。
	_residents = _text_entry("居民")
	_residents.name = "Residents"
	_residents.pressed.connect(func() -> void: residents_requested.emit())
	# 对话只存在于共享世界；入口始终可见，单机点击后由场景说明需要进入共享
	# 世界，不虚构本地对话。
	_dialogue = _text_entry("对话")
	_dialogue.name = "Dialogue"
	_dialogue.pressed.connect(func() -> void: dialogue_requested.emit())
	# 规则决议只存在于共享世界；入口始终可见，单机点击后由场景说明需要进入
	# 共享世界，不虚构本地规则版本。
	_resolutions = _text_entry("决议")
	_resolutions.name = "Resolutions"
	_resolutions.pressed.connect(func() -> void: resolutions_requested.emit())
	# Presence has no artwork yet; a text entry keeps the bar honest instead of
	# borrowing an icon that means something else.
	_social = _text_entry("邻里")
	_social.name = "Neighbors"
	_social.pressed.connect(func() -> void: social_requested.emit())
	_social.hide()
	_homes = _text_entry("宅基")
	_homes.name = "Homes"
	_homes.pressed.connect(func() -> void: homes_requested.emit())
	_homes.hide()
	_settings = _toolbar_button("设置", "res://art/ui/toolbar/settings.png")
	_settings.name = "Settings"
	_settings.pressed.connect(func() -> void: settings_requested.emit())
	var cancel := _toolbar_button("取消", "res://art/ui/toolbar/cancel.png")
	cancel.name = "CancelTool"
	cancel.pressed.connect(func() -> void: cancel_tool_requested.emit())
	cancel.hide()
	_crop_row = _choice_row(root, "CropChoices", Crops.crop_ids().size() * 36.0)
	for crop_id: String in Crops.crop_ids():
		var card := _choice_card(_crop_row, crop_id, Crops.definition(crop_id).name, load(Crops.icon_path(crop_id)))
		card.pressed.connect(func() -> void: crop_requested.emit(crop_id))
		_crop_buttons[crop_id] = card
	_tool_row = _choice_row(root, "ToolChoices", 145)
	for item: Array in [["water", "浇水"], ["harvest", "收获"], ["weed", "除草"], ["till", "开垦"]]:
		var button := _choice_card(_tool_row, item[0].capitalize(), item[1], load("res://art/ui/crops/%s.png" % item[0]))
		button.button_down.connect(func() -> void: tool_press_started.emit(item[0]))
		button.pressed.connect(func() -> void: tool_requested.emit(item[0]))
		_buttons[item[0]] = button


func _choice_card(parent: Control, card_name: String, text: String, texture: Texture2D) -> Button:
	var card := preload("res://ui/item_card.gd").new()
	card.name = card_name
	card.toggle_mode = true
	parent.add_child(card)
	card.configure(text,texture)
	return card


func _choice_row(root: Control, row_name: String, half_width: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = row_name
	root.add_child(row)
	row.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	row.offset_left = -half_width
	row.offset_right = half_width
	row.offset_top = -216
	row.offset_bottom = -132
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.modulate.a = 0.0
	row.hide()
	_row_open[row] = false
	return row


func _animate_row(row: Control, opened: bool) -> void:
	if _row_open[row] == opened:
		return
	_row_open[row] = opened
	if _row_tweens.has(row):
		_row_tweens[row].kill()
	if opened and not row.visible:
		row.offset_top = -204
		row.offset_bottom = -120
	row.show()
	var tween := create_tween().set_parallel(true)
	_row_tweens[row] = tween
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(row, "modulate:a", 1.0 if opened else 0.0, .18)
	tween.tween_property(row, "offset_top", -216.0 if opened else -204.0, .22)
	tween.tween_property(row, "offset_bottom", -132.0 if opened else -120.0, .22)
	if not opened:
		tween.chain().tween_callback(row.hide)


func _sync_rows() -> void:
	_animate_row(_crop_row, not _decorating and _palette == "sow")
	_animate_row(_tool_row, not _decorating and _palette == "tools")


func _exit_tree() -> void:
	for tween: Tween in _row_tweens.values():
		tween.kill()
	_row_tweens.clear()
	_row_open.clear()


func _build_time_preview(root: Control) -> void:
	_time_panel = PanelContainer.new()
	_time_panel.name = "DebugTimePreview"
	root.add_child(_time_panel)
	_time_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_time_panel.offset_left = -350
	_time_panel.offset_right = -18
	_time_panel.offset_top = 196
	var box := VBoxContainer.new()
	_time_panel.add_child(box)
	_time_slider = HSlider.new()
	_time_slider.name = "TimeSlider"
	_time_slider.max_value = 1439
	_time_slider.step = 1
	_time_slider.custom_minimum_size = Vector2(296, 38)
	box.add_child(_time_slider)
	_time_slider.value_changed.connect(func(value: float) -> void:
		_preview_minutes = int(value)
		preview_hour_requested.emit(value / 60.0))
	var actions := HBoxContainer.new()
	box.add_child(actions)
	var live := _button(actions, "恢复实时", 160)
	live.name = "LiveTime"
	live.pressed.connect(func() -> void:
		_preview_minutes = -1
		_sync_time_slider()
		preview_hour_requested.emit(-1.0))
	_button(actions, "收起", 110).pressed.connect(hide_time_preview)
	_time_panel.hide()


func _toggle_time_preview() -> void:
	if _time_panel == null: _build_time_preview(get_node("Layout"))
	if _time_panel.visible:
		hide_time_preview()
	else:
		_sync_time_slider()
		_time_panel.show()
		time_preview_opened.emit()


func _sync_time_slider() -> void:
	var local := Time.get_datetime_dict_from_system(false)
	_time_slider.set_value_no_signal(_preview_minutes if _preview_minutes >= 0 else int(local.hour) * 60 + int(local.minute))


func hide_time_preview() -> void:
	if _time_panel != null:
		_time_panel.hide()
		_time_slider.release_focus()


func _build_storage_overlay(root: Control) -> void:
	_storage_overlay = ColorRect.new()
	_storage_overlay.name = "StorageOverlay"
	_storage_overlay.color = FarmTheme.Tokens.SCRIM_BLOCKING
	root.add_child(_storage_overlay)
	_storage_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	_storage_overlay.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -290
	panel.offset_right = 290
	panel.offset_top = -135
	panel.offset_bottom = 135
	var style := FarmTheme.framed_paper()
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 24
	style.content_margin_bottom = 24
	panel.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	panel.add_child(box)
	box.add_theme_constant_override("separation", 16)
	_storage_message = _label(box, "", 20)
	_storage_message.name = "Message"
	_storage_message.custom_minimum_size = Vector2(500, 70)
	_storage_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_retry = _button(box, "重试读取", 180)
	_retry.name = "Retry"
	_retry.pressed.connect(func() -> void: retry_requested.emit())
	_recover = _button(box, "从备份恢复", 180)
	_recover.name = "Recover"
	_recover.pressed.connect(func() -> void: recovery_requested.emit())
	_exit = _button(box, "退出", 180)
	_exit.name = "Exit"
	_exit.pressed.connect(func() -> void: exit_requested.emit())
	_storage_overlay.hide()


func show_storage_issue(kind: String, unsaved: bool) -> void:
	if unsaved:
		_storage_message.text = "保存未完成，最新进度仍在本次窗口中。请重试保存。"
	elif kind.begins_with("nature_"):
		# A refused weather record is not a farm recovery: there is no second
		# copy to restore, and the bytes stay on disk for a later retry.
		_storage_message.text = "天气记录来自更新的版本，请先更新游戏。原文件已保留。" \
			if kind.ends_with("unsupported") \
			else "天气记录无法读取，原文件已保留。修复后可重试。"
	else:
		_storage_message.text = {
			"recovery_available": "存档未能读取，可恢复上一份备份。最近的改动可能丢失，原文件会保留。",
			"unsupported": "这份存档来自其他版本。请使用对应版本打开，原文件已保留。",
			"corrupt": "存档与备份都无法读取。原文件已保留，修复文件后可重试。"
		}.get(kind, "暂时无法读取存档。请检查存档文件夹后重试，原文件已保留。")
	_retry.text = "重试保存" if unsaved else "重试读取"
	_recover.visible = not unsaved and kind == "recovery_available"
	_exit.text = "仍然退出（最新进度未保存）" if unsaved else "退出"
	_storage_overlay.show()
	var choices: Array[Control] = [_retry]
	if _recover.visible:
		choices.append(_recover)
	choices.append(_exit)
	for index: int in choices.size():
		var control: Control = choices[index]
		var previous: NodePath = control.get_path_to(choices[posmod(index - 1, choices.size())])
		var following: NodePath = control.get_path_to(choices[(index + 1) % choices.size()])
		control.focus_previous = previous
		control.focus_next = following
		control.focus_neighbor_top = previous
		control.focus_neighbor_left = previous
		control.focus_neighbor_bottom = following
		control.focus_neighbor_right = following
	_retry.grab_focus()


func _build_notice(parent: Control) -> void:
	_notice = Label.new()
	_notice.name = "Notice"
	_notice.visible = false
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.add_theme_color_override("font_color", INK)
	# A paper outline keeps the line readable over dark soil and at night without
	# adding a panel that the rest of this read-only HUD deliberately avoids.
	_notice.add_theme_color_override("font_outline_color", FarmTheme.PAPER)
	_notice.add_theme_constant_override("outline_size", 4)
	_notice.add_theme_font_size_override("font_size", 17)
	parent.add_child(_notice)
	_notice_timer = Timer.new()
	_notice_timer.one_shot = true
	_notice_timer.wait_time = 3.5
	_notice_timer.timeout.connect(func() -> void: _notice.hide())
	add_child(_notice_timer)


## One short line for refusals the player must see but cannot act on. It replaces
## the previous line instead of stacking, so repeated clicks stay quiet.
func show_notice(text: String) -> void:
	if _notice == null or text.is_empty():
		return
	_notice.text = text
	_notice.show()
	_notice_timer.start()


func show_saved() -> void:
	_storage_overlay.hide()


## One short read-only line under the notice while a cell is selected. No
## panel, icon or animation: the soil value and its current growth effect are
## the whole message.
func _build_environment_info(parent: Control) -> void:
	_environment = Label.new()
	_environment.name = "EnvironmentInfo"
	_environment.visible = false
	_environment.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_environment.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_environment.add_theme_color_override("font_color", INK)
	_environment.add_theme_color_override("font_outline_color", FarmTheme.PAPER)
	_environment.add_theme_constant_override("outline_size", 4)
	_environment.add_theme_font_size_override("font_size", 16)
	parent.add_child(_environment)


static func environment_text(cell: Dictionary) -> String:
	if cell.is_empty():
		return ""
	var label: String = {"dry": "干燥", "damp": "湿润", "wet": "潮湿"}.get(
		str(cell.get("moisture_label", "")), "")
	if label.is_empty():
		return ""
	return "土壤：%s · 生长 %d%%" % [label, roundi(float(cell.get("growth_rate", 1.0)) * 100.0)]


## One read-only line below the soil line. No panel, icon or animation; an
## empty/unknown kind produces no line at all.
func _build_weather_info(parent: Control) -> void:
	_weather = Label.new()
	_weather.name = "WeatherInfo"
	_weather.visible = false
	_weather.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_weather.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_weather.add_theme_color_override("font_color", INK)
	_weather.add_theme_color_override("font_outline_color", FarmTheme.PAPER)
	_weather.add_theme_constant_override("outline_size", 4)
	_weather.add_theme_font_size_override("font_size", 16)
	parent.add_child(_weather)


static func weather_text(kind: String, next_change_utc: float = -1.0, now_utc: float = -1.0) -> String:
	# The copy lives with the weather mood table so a headless rule fixture can
	# check it without this scene script's art preloads.
	return WeatherMood.hud_text(kind, next_change_utc, now_utc)


func show_weather(text: String, loaded: bool) -> void:
	if _weather == null:
		return
	if not loaded or text.is_empty():
		_weather.visible = false
		return
	if _weather.text != text:
		_weather.text = text
	_weather.visible = true


## One read-only line below the weather line. It reuses the same font and ink as
## the two lines above and stays hidden for no event, an unloaded scene or an
## expired summary. No panel, icon or animation.
func _build_disaster_info(parent: Control) -> void:
	_disaster = Label.new()
	_disaster.name = "DisasterInfo"
	_disaster.visible = false
	_disaster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_disaster.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_disaster.add_theme_color_override("font_color", INK)
	_disaster.add_theme_color_override("font_outline_color", FarmTheme.PAPER)
	_disaster.add_theme_constant_override("outline_size", 4)
	_disaster.add_theme_font_size_override("font_size", 16)
	parent.add_child(_disaster)


func show_disaster(text: String, loaded: bool) -> void:
	if _disaster == null:
		return
	if not DisasterMood.hud_visible(text, loaded):
		_disaster.visible = false
		return
	if _disaster.text != text:
		_disaster.text = text
	_disaster.visible = true


## A shared world has neighbours to show and no local courtyard to edit.
func set_world_mode(shared: bool) -> void:
	if _build != null: _build.visible = not shared
	if _basket != null: _basket.visible = not shared
	if _social != null: _social.visible = shared
	if _homes != null: _homes.visible = shared


func show_decoration_mode(active: bool) -> void:
	_decorating = active
	_tools.get_node("Sow").visible = not active
	_tools.get_node("Tools").visible = not active
	_tools.get_node("CancelTool").visible = not active and _tools.get_node("CancelTool").visible
	_sync_rows()


func show_state(cell: Dictionary, _harvested: Dictionary, tool: String, crop_id: String, traveling: bool, _field_index: int = -1, palette: String = "", _inventory: Dictionary = {}, trellis_field: bool = false) -> void:
	_palette = palette
	_environment.text = environment_text(cell)
	_environment.visible = not _environment.text.is_empty()
	# The strip offers only what this field can actually grow; a trellis has the
	# climbing crop and ordinary beds have every other seed.
	var sowable: Array[String] = Crops.seeds(trellis_field)
	for id: String in _crop_buttons:
		var card: Button = _crop_buttons[id]
		card.visible = sowable.has(id)
		card.disabled = traveling or palette != "sow"
		card.set_pressed_no_signal(tool == "sow" and id == crop_id)
	for tool_id: String in _buttons:
		var button: Button = _buttons[tool_id]
		button.disabled = traveling or palette != "tools"
		button.set_pressed_no_signal(tool_id == tool)
	for entry: String in ["Sow", "Tools"]:
		var button: Button = _tools.get_node(entry)
		button.disabled = traveling
		button.set_pressed_no_signal(palette == ("sow" if entry == "Sow" else "tools"))
	# Every bar entry bails while the camera travels, so none of them may keep
	# looking active and swallow the click without an explanation.
	for child: Node in _tools.get_children():
		if child is Button:
			(child as Button).disabled = traveling
	for child: Node in _world.get_children():
		if child is Button:
			(child as Button).disabled = traveling
	_tools.get_node("CancelTool").visible = not _decorating and not tool.is_empty()
	_sync_rows()


func _label(parent: Control, text: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", INK)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label


func _button(parent: Control, text: String, width: float) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(width, 44)
	FarmTheme.pointer_focus(button)
	parent.add_child(button)
	return button


## A two-character bottom-bar entry. The shared theme's 18px side insets would
## widen it to 76px even against a smaller minimum, so the tighter inset is set
## on every interaction state rather than only `normal`.
func _text_entry(caption: String) -> Button:
	var button := _button(_world, caption, TEXT_ENTRY_WIDTH)
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var box: StyleBox = FarmTheme.framed_paper(
			FarmTheme.Tokens.WASH if state == "normal" else _entry_fill(state),
			state == "pressed" or state == "hover_pressed")
		box.content_margin_left = TEXT_ENTRY_INSET
		box.content_margin_right = TEXT_ENTRY_INSET
		button.add_theme_stylebox_override(state, box)
	return button


func _entry_fill(state: String) -> Color:
	match state:
		"hover": return FarmTheme.Tokens.WASH_HOVER
		"pressed", "hover_pressed": return FarmTheme.Tokens.WASH_PRESSED
		_: return FarmTheme.Tokens.DISABLED


func show_settings_issue(has_issue: bool) -> void:
	_settings.text = "设置 !" if has_issue else "设置"


func is_time_preview_open() -> bool:
	return _time_panel != null and _time_panel.visible

func _toolbar_button(caption: String, icon_path: String) -> Button:
	var button := _button(_tools, caption, 104)
	button.icon = load(icon_path)
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_constant_override("icon_max_width", 28)
	button.add_theme_constant_override("h_separation", 6)
	_fit_toolbar_button(button)
	return button


func _fit_toolbar_button(button: Button) -> void:
	var text_width: float = button.get_theme_font("font").get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")).x
	# Expanded icons do not contribute to Button minimum width; reserve their slot.
	button.custom_minimum_size.x = maxf(112.0, text_width + 70.0)


func set_workarea(area: Vector4) -> void:
	var root: Control = $Layout
	root.anchor_left = area.x
	root.anchor_top = area.y
	root.anchor_right = area.z
	root.anchor_bottom = area.w
