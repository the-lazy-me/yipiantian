extends CanvasLayer
## The scene applies preferences and owns saving. This modal only presents intent.

signal settings_changed(value: Dictionary)
signal save_requested
signal close_requested
signal quit_requested
signal wallpaper_requested
signal developer_requested(action: String)
signal world_export_requested(directory: String)
signal world_import_requested(directory: String)
signal world_import_confirmed
signal world_import_cancelled
signal identity_reset_requested
signal disaster_mode_changed(mode: String)
signal dismissed

const FarmTheme = preload("res://ui/farm_theme.gd")
const Presets = preload("res://settings/graphics_presets.gd")
const QUALITY_VALUES: Array[String] = ["high", "standard", "low"]
const RESOLUTION_VALUES: Array[String] = ["native", "720", "1080", "1440", "2160"]
const FSR_VALUES: Array[String] = ["off", "quality", "balanced", "performance"]
const ABOUT_TAB: int = 3
const DEVELOPER_TAB: int = 4
const WORLD_TAB: int = 5
static var developer_unlocked: bool = false
var _about_clicks: int = 0
var _last_about_click: int = 0
var _root: Control
var _pages: Array[Control] = []
var _tabs: Array[Button] = []
var _sliders: Dictionary = {}
var _volume_labels: Dictionary = {}
var _window: OptionButton
var _quality: OptionButton
var _graphics: Dictionary = {}
var _wallpaper_active: bool = false
var _wallpaper_supported: bool = true
var _wallpaper_interactive: bool = true
var _wallpaper_confirmation: PanelContainer
var _resolution: OptionButton
var _fsr: OptionButton
var _sway: Button
var _sway_delay: SpinBox
var _dof: Button
var _status: Label
var _close: Button
var _quit: Button
var _retry: Button
var _developer_buttons: Dictionary = {}
var _wallpaper: Button
var _values: Dictionary = {}
var _populating: bool = false
var _page_index: int = 0
var _paper: PanelContainer
var _quit_confirmation: PanelContainer
var _keep_playing: Button
var _export_world: Button
var _import_world: Button
var _world_status: Label
var _world_import_confirmation: PanelContainer
var _world_import_text: Label
var _world_import_error: Label
var _identity: Button
var _identity_confirmation: PanelContainer
var _identity_keep: Button
var _export_dialog: FileDialog
var _import_dialog: FileDialog
var _disaster: OptionButton
var _disaster_mode: String = "gentle"
# Headless tests set these before pressing the buttons; empty uses the dialog.
var export_path_override: String = ""
var import_path_override: String = ""
var closing: bool = false
var _motion: Tween
var _page_motion: Tween
var _confirmation_motion: Tween


func _ready() -> void:
	layer = 30
	_root = Control.new()
	_root.name = "Modal"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.theme = FarmTheme.create()
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0.15, 0.20, 0.15, 0.38)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	var panel := PanelContainer.new()
	_paper = panel
	panel.name = "Paper"
	_root.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -310
	panel.offset_right = 310
	panel.offset_top = -270
	panel.offset_bottom = 270
	var style: StyleBox = FarmTheme.framed_paper()
	style.content_margin_left = 26
	style.content_margin_right = 26
	style.content_margin_top = 20
	style.content_margin_bottom = 20
	panel.add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	panel.add_child(column)
	var tabs := HBoxContainer.new()
	column.add_child(tabs)
	var titles: Array[String] = ["显示", "音量", "操作", "关于", "开发者", "世界"]
	for title: String in titles:
		var tab: Button = _button(tabs, title)
		tab.toggle_mode = true
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var index: int = _tabs.size()
		tab.pressed.connect(func() -> void: _tab_pressed(index))
		_tabs.append(tab)
	_tabs[DEVELOPER_TAB].visible = developer_enabled()
	var content := Control.new()
	content.name = "Pages"
	content.custom_minimum_size = Vector2(560, 350)
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(content)
	var settings := VBoxContainer.new()
	content.add_child(settings)
	settings.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pages.append(settings)
	for entry: Array in [["master", "总音量"], ["music", "音乐"], ["effects", "音效"]]:
		var row: HBoxContainer = _row(settings, entry[1])
		var slider := HSlider.new()
		slider.name = entry[0].capitalize()
		slider.min_value = 0
		slider.max_value = 100
		slider.step = 1
		slider.custom_minimum_size = Vector2(250, 42)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(slider)
		var number := Label.new()
		number.custom_minimum_size.x = 62
		number.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(number)
		_sliders[entry[0]] = slider
		_volume_labels[entry[0]] = number
		var key: String = entry[0]
		slider.value_changed.connect(func(value: float) -> void:
			number.text = "%d%%" % roundi(value)
			_change(key, value / 100.0))
	var scroll := ScrollContainer.new()
	scroll.name = "DisplayScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	content.add_child(scroll)
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pages.push_front(scroll)
	var display := VBoxContainer.new()
	display.name = "Display"
	display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(display)
	_quality = _option(display, "画质预设", "Quality", ["高画质", "中画质", "低画质", "自定义"])
	_quality.set_item_disabled(3, true)
	_quality.item_selected.connect(_choose_preset)
	_resolution = _option(display, "分辨率", "RenderResolution", ["原生", "720p", "1080p", "1440p", "2160p（4K）"])
	_resolution.item_selected.connect(func(index: int) -> void: _change("resolution", RESOLUTION_VALUES[index]))
	_fsr = _option(display, "FSR 超分", "FSR", ["关闭", "画质优先", "平衡", "性能优先"])
	_fsr.item_selected.connect(func(index: int) -> void:
		_change("fsr", FSR_VALUES[index])
		_refresh_fsr())
	for entry: Array in [["quality", "场景细节"], ["shadows", "阴影质量"], ["lighting", "光照效果"], ["antialiasing", "抗锯齿"]]:
		var key: String = entry[0]
		var option_titles: Array = ["关闭", "2×", "4×"] if key == "antialiasing" else ["高", "中", "低"]
		var choices: Array = ["off", "2x", "4x"] if key == "antialiasing" else QUALITY_VALUES
		var option: OptionButton = _option(display, entry[1], key.capitalize(), option_titles)
		_graphics[key] = option
		option.item_selected.connect(func(index: int) -> void: _change(key, choices[index]))
	_dof = _button(_row(display, "景深"), "开启")
	_dof.name = "DepthOfField"
	_dof.toggle_mode = true
	_dof.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dof.toggled.connect(func(enabled: bool) -> void:
		_change("dof_enabled", enabled)
		_refresh_dof())
	_window = _option(display, "窗口模式", "WindowMode", ["窗口", "全屏"])
	_window.item_selected.connect(func(index: int) -> void: _change("fullscreen", index == 1))
	_sway = _button(_row(display, "轻微晃动"), "已关闭")
	_sway.name = "CameraSway"
	_sway.toggle_mode = true
	_sway.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sway.toggled.connect(func(enabled: bool) -> void:
		_change("sway_enabled", enabled)
		_refresh_sway())
	_sway_delay = SpinBox.new()
	_sway_delay.name = "SwayIdleSeconds"
	_sway_delay.min_value = 0
	_sway_delay.max_value = 600
	_sway_delay.step = 1
	_sway_delay.suffix = "秒"
	var delay_edit: LineEdit = _sway_delay.get_line_edit()
	delay_edit.add_theme_stylebox_override("normal", FarmTheme.framed_paper())
	delay_edit.add_theme_stylebox_override("read_only", FarmTheme.framed_paper())
	delay_edit.add_theme_color_override("font_color", FarmTheme.INK)
	delay_edit.add_theme_color_override("font_uneditable_color", FarmTheme.INK.lightened(.3))
	_sway_delay.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sway_delay.custom_minimum_size.y = 42
	_row(display, "空闲后晃动").add_child(_sway_delay)
	_sway_delay.value_changed.connect(func(value: float) -> void: _change("sway_idle_seconds", roundi(value)))
	var operations: RichTextLabel = _text_page(content, "操作说明")
	operations.text = "[b]照料田地[/b]\n空手点击田格展开菜单，选择动作；播种时先选蔬菜拿起种子，再点击土地种植。点空白、右键或 Esc 关闭菜单。门前种子篮、锄头、水壶可拿起对应工具，再点击土地连续操作；底部种植／工具按钮展开横排选择。选菜后鼠标携带种子，点击土地可连续种植；右键、Esc 或取消按钮放下工具。每轮可浇水一次，不同作物节省的生长时间不同；成熟收获一篮。\n\n[b]照料菜架[/b]\n点击架脚的种植位靠近，再点种植位播种丝瓜；也可点藤蔓或果实浇水、收获。扩架增加位置，缩架前先收获会被移除的作物。\n\n[b]观察院落[/b]\n滚轮用于调整镜头，拿着种子时也不会切换菜品。点击田块靠近，向后滚轮返回聚焦前的机位；中键拖动转动视角，Shift＋中键平移。\n\n[b]返回与布置[/b]\n右键或 Esc 先放下工具，再清除选格、返回全景。“建设”内选择土地、建筑或摆件：选装饰、点空位，再确认；旋转适用于地面装饰。\n\n作物按现实时间生长。离开后再次进入，会继续上次的农场。"
	var sources: RichTextLabel = _text_page(content, "关于")
	sources.text = "[b]我有一片田 · Demo %s[/b]\n开发中试玩版，内容与体验仍在完善。\n\n图像：OpenAI 图像生成，依项目定稿参考制作。\n模型草案：Tripo；模型整理与补制：Blender。\n场景、界面与交互：Godot。\n音乐、环境声与操作声：项目内合成制作。\n\n[b]中文字体[/b]\n汇文明朝体 · Huiwen-mincho\n原字体随游戏内置，无需安装。\n字体内版权标记：Public Domain。" % ProjectSettings.get_setting("application/config/version", "")
	var developer := VBoxContainer.new()
	developer.name = "Developer"
	developer.add_theme_constant_override("separation", 10)
	content.add_child(developer)
	developer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pages.append(developer)
	for entry: Array in [["camera_tuning", "相机调节"], ["sway_tuning", "镜头晃动"], ["free_camera", "自由视角"], ["models", "模型检查"], ["time", "昼夜预览"], ["mature", "全部作物成熟"]]:
		var button := _button(developer, entry[1])
		button.name = entry[0]
		_developer_buttons[entry[0]] = button
		button.pressed.connect(func() -> void: developer_requested.emit(entry[0]))
	var world := VBoxContainer.new()
	world.name = "World"
	world.add_theme_constant_override("separation", 10)
	content.add_child(world)
	world.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pages.append(world)
	# A world-level switch, persisted in nature.json rather than settings.json.
	# The scene owns the save; this only reports intent.
	_disaster = _option(world, "灾害", "DisasterMode", ["温和", "关闭"])
	_disaster.item_selected.connect(func(index: int) -> void:
		var mode: String = "off" if index == 1 else "gentle"
		if mode != _disaster_mode:
			_disaster_mode = mode
			disaster_mode_changed.emit(mode))
	_export_world = _button(world, "导出世界")
	_export_world.name = "ExportWorld"
	_export_world.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_export_world.pressed.connect(_choose_world_export)
	_import_world = _button(world, "导入世界")
	_import_world.name = "ImportWorld"
	_import_world.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_import_world.pressed.connect(_choose_world_import)
	_identity = _button(world, "重置身份")
	_identity.name = "ResetIdentity"
	_identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_exit(_identity)
	_identity.pressed.connect(_request_identity_reset)
	_world_status = Label.new()
	_world_status.name = "WorldStatus"
	_world_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_world_status.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_world_status.add_theme_font_size_override("font_size", 17)
	world.add_child(_world_status)
	_status = Label.new()
	_status.name = "SettingsStatus"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 17)
	column.add_child(_status)
	_retry = _button(column, "重试保存")
	_retry.name = "RetrySettings"
	_retry.pressed.connect(func() -> void: save_requested.emit())
	var actions := HBoxContainer.new()
	actions.name = "Actions"
	column.add_child(actions)
	_quit = _button(actions, "退出游戏")
	_quit.name = "QuitGame"
	_quit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_exit(_quit)
	_quit.pressed.connect(func() -> void:
		_paper.hide()
		_quit_confirmation.show()
		_animate_confirmation(_quit_confirmation)
		_keep_playing.grab_focus())
	_wallpaper = _button(actions, "设为壁纸")
	_wallpaper.name = "DesktopWallpaper"
	_wallpaper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wallpaper.tooltip_text = "在当前屏幕展示农场；右键点击系统托盘图标可返回农场。"
	_wallpaper.pressed.connect(_request_wallpaper)
	_close = _button(actions, "返回农场")
	_close.name = "ReturnToFarm"
	_close.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_close.pressed.connect(func() -> void: close_requested.emit())
	_build_quit_confirmation()
	_build_wallpaper_confirmation()
	_build_world_import_confirmation()
	_build_identity_confirmation()
	_build_world_dialogs()
	_show_page(0)
	hide()


func present(value: Dictionary, message: String = "") -> void:
	if _motion: _motion.kill()
	closing = false
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	cancel_quit_confirmation()
	cancel_wallpaper_confirmation()
	cancel_identity_reset_confirmation()
	_world_import_confirmation.hide()
	_world_import_error.text = ""
	_world_import_error.visible = false
	set_world_status("")
	if _confirmation_motion: _confirmation_motion.kill()
	_paper.modulate.a = 1.0
	_quit_confirmation.scale = Vector2.ONE
	_quit_confirmation.modulate.a = 1.0
	_values = value.duplicate(true)
	_populating = true
	for key: String in _sliders:
		_sliders[key].set_value_no_signal(roundf(float(value[key]) * 100.0))
		_volume_labels[key].text = "%d%%" % roundi(float(value[key]) * 100.0)
	_window.select(1 if value.fullscreen else 0)
	_sync_graphics()
	_refresh_fsr()
	_refresh_dof()
	_refresh_sway()
	_sway_delay.set_value_no_signal(value.sway_idle_seconds)
	_populating = false
	set_status(message)
	_show_page(0)
	show()
	_root.modulate.a = 0.0
	_paper.pivot_offset = _paper.size * .5
	_paper.scale = Vector2.ONE * .96
	_motion = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_motion.tween_property(_root, "modulate:a", 1.0, .20)
	_motion.tween_property(_paper, "scale", Vector2.ONE, .22)
	_refresh_focus_chain(0)
	_tabs[0].grab_focus()


func set_status(message: String, can_leave_unsaved: bool = false) -> void:
	_status.text = message
	_status.visible = not message.is_empty()
	_retry.visible = can_leave_unsaved
	_close.text = "暂不保存，返回" if can_leave_unsaved else "返回农场"
	_quit.text = "仍然退出" if can_leave_unsaved else "退出游戏"
	_refresh_focus_chain(_page_index)


## Shows the authoritative world's mode. A shared world is read-only here; the
## authority owns the switch and clients must not change it locally.
func set_disaster_mode(mode: String, editable: bool) -> void:
	if _disaster == null:
		return
	_disaster_mode = mode if mode == "off" else "gentle"
	_disaster.select(1 if _disaster_mode == "off" else 0)
	_disaster.disabled = not editable
	_disaster.tooltip_text = "" if editable else "联机模式下，灾害由世界房主决定。"
	_refresh_focus_chain(_page_index)


func dismiss() -> void:
	_about_clicks = 0
	if not visible or closing: return
	closing = true
	if _motion: _motion.kill()
	if _confirmation_motion: _confirmation_motion.kill()
	_window.get_popup().hide()
	_quality.get_popup().hide()
	_resolution.get_popup().hide()
	_fsr.get_popup().hide()
	_disaster.get_popup().hide()
	_export_dialog.hide()
	_import_dialog.hide()
	for option: OptionButton in _graphics.values(): option.get_popup().hide()
	var panel: Control = _quit_confirmation if _quit_confirmation.visible else (_wallpaper_confirmation if _wallpaper_confirmation.visible else (_world_import_confirmation if _world_import_confirmation.visible else (_identity_confirmation if _identity_confirmation.visible else _paper)))
	panel.pivot_offset = panel.size * .5
	_motion = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_motion.tween_property(_root, "modulate:a", 0.0, .14)
	_motion.tween_property(panel, "scale", Vector2.ONE * .96, .14)
	_motion.chain().tween_callback(func() -> void:
		hide()
		closing = false
		dismissed.emit())


func _input(event: InputEvent) -> void:
	# Keep the modal shield until the last frame, including keyboard activation.
	if visible and closing and (event is InputEventMouse or event is InputEventKey):
		get_viewport().set_input_as_handled()


func _refresh_sway() -> void:
	_sway.set_pressed_no_signal(_values.sway_enabled)
	_sway.text = "已开启" if _values.sway_enabled else "已关闭"
	_sway_delay.editable = _values.sway_enabled


func _refresh_fsr() -> void:
	var supported: bool = RenderingServer.get_current_rendering_method() == "forward_plus"
	_fsr.disabled = not supported
	_fsr.tooltip_text = "用较低清晰度绘制，再重建画面；性能优先可能更模糊。不是补帧。" if supported else "当前显示模式不支持 FSR。"
	_resolution.disabled = supported and _values.get("fsr", "off") != "off"
	_resolution.tooltip_text = "已由 FSR 档位控制；关闭 FSR 后恢复此选择。" if _resolution.disabled else ""
	_graphics.antialiasing.disabled = _resolution.disabled
	_graphics.antialiasing.tooltip_text = "FSR 已包含抗锯齿；关闭 FSR 后恢复此选择。" if _resolution.disabled else ""


func _refresh_dof() -> void:
	if _values.is_empty():
		return
	_dof.set_pressed_no_signal(_values.dof_enabled)
	_dof.text = "已开启" if _values.dof_enabled else "已关闭"


func _change(key: String, value: Variant) -> void:
	if _populating:
		return
	if _values.get(key) == value: return
	_values[key] = value
	_refresh_preset()
	settings_changed.emit(_values.duplicate(true))


func developer_enabled() -> bool:
	return developer_unlocked or (OS.is_debug_build() and OS.has_feature("editor"))


func _tab_pressed(index: int) -> void:
	if index == ABOUT_TAB and not developer_enabled():
		var now: int = Time.get_ticks_msec()
		_about_clicks = _about_clicks + 1 if now - _last_about_click <= 2000 else 1
		_last_about_click = now
		if _about_clicks >= 10:
			developer_unlocked = true
			_tabs[DEVELOPER_TAB].show()
			_show_page(DEVELOPER_TAB)
			return
	else:
		_about_clicks = 0
	if index == DEVELOPER_TAB and not developer_enabled(): return
	_show_page(index)


func _show_page(index: int) -> void:
	var changed: bool = index != _page_index
	if _page_motion: _page_motion.kill()
	_page_index = index
	_window.get_popup().hide()
	_quality.get_popup().hide()
	_resolution.get_popup().hide()
	_fsr.get_popup().hide()
	_disaster.get_popup().hide()
	_export_dialog.hide()
	_import_dialog.hide()
	for option: OptionButton in _graphics.values(): option.get_popup().hide()
	for page: int in _pages.size():
		_pages[page].visible = page == index
		_pages[page].modulate.a = 1.0
		_tabs[page].set_pressed_no_signal(page == index)
	_refresh_focus_chain(index)
	if visible and changed:
		_pages[index].modulate.a = 0.0
		_page_motion = create_tween()
		_page_motion.tween_property(_pages[index], "modulate:a", 1.0, .14).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _refresh_focus_chain(index: int) -> void:
	# A Control modal blocks pointer input, but default keyboard traversal may still
	# reach HUD buttons. Explicit wrapping keeps both Tab and arrows in this menu.
	var controls: Array[Control] = []
	for tab: Button in _tabs:
		if tab.visible: controls.append(tab)
	_collect_focus(_pages[index], controls)
	if _retry.visible: controls.append(_retry)
	for action: Button in [_quit, _wallpaper, _close]:
		if action.visible: controls.append(action)
	for position: int in controls.size():
		var control: Control = controls[position]
		control.focus_mode = Control.FOCUS_ALL
		var previous: NodePath = control.get_path_to(controls[(position - 1 + controls.size()) % controls.size()])
		var next: NodePath = control.get_path_to(controls[(position + 1) % controls.size()])
		control.focus_previous = previous
		control.focus_next = next
		control.focus_neighbor_left = previous
		control.focus_neighbor_top = previous
		control.focus_neighbor_right = next
		control.focus_neighbor_bottom = next


func _text_page(parent: Control, node_name: String) -> RichTextLabel:
	var text := RichTextLabel.new()
	text.name = node_name
	text.bbcode_enabled = true
	text.selection_enabled = true
	text.add_theme_color_override("default_color", FarmTheme.INK)
	text.add_theme_constant_override("line_separation", 5)
	parent.add_child(text)
	text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pages.append(text)
	return text


func _row(parent: Control, label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = 108
	row.add_child(label)
	return row


func _button(parent: Control, title: String) -> Button:
	var button := Button.new()
	button.text = title
	button.custom_minimum_size.y = 44
	FarmTheme.pointer_focus(button)
	parent.add_child(button)
	return button

func _collect_focus(node: Node, controls: Array[Control]) -> void:
	if node is BaseButton or node is Range or node is RichTextLabel:
		controls.append(node)
	for child: Node in node.get_children():
		_collect_focus(child, controls)


func show_free_view(active: bool) -> void:
	if _developer_buttons.has("free_camera"):
		_developer_buttons.free_camera.text = "退出自由视角" if active else "自由视角"


func _style_exit(button: Button) -> void:
	for state: String in ["hover", "pressed", "hover_pressed"]:
		var style := FarmTheme.framed_paper(FarmTheme.Tokens.DANGER_HOVER if state == "hover" else FarmTheme.Tokens.DANGER_PRESSED)
		style.set("edge", FarmTheme.Tokens.DANGER)
		button.add_theme_stylebox_override(state, style)
	for state: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, FarmTheme.Tokens.DANGER)
	var focus: StyleBoxFlat = button.get_theme_stylebox("focus").duplicate()
	focus.border_color = FarmTheme.Tokens.DANGER
	button.add_theme_stylebox_override("focus", focus)


func _build_quit_confirmation() -> void:
	_quit_confirmation = PanelContainer.new()
	_quit_confirmation.name = "QuitConfirmation"
	_root.add_child(_quit_confirmation)
	_quit_confirmation.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_quit_confirmation.offset_left = -230
	_quit_confirmation.offset_right = 230
	_quit_confirmation.offset_top = -80
	_quit_confirmation.offset_bottom = 80
	var column := VBoxContainer.new()
	_quit_confirmation.add_child(column)
	var label := Label.new()
	label.text = "确定退出游戏？"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(label)
	var row := HBoxContainer.new()
	column.add_child(row)
	var confirm := _button(row, "确认退出")
	confirm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_exit(confirm)
	confirm.pressed.connect(func() -> void:
		cancel_quit_confirmation()
		quit_requested.emit())
	_keep_playing = _button(row, "继续游戏")
	_keep_playing.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_keep_playing.pressed.connect(cancel_quit_confirmation)
	for pair: Array in [[confirm, _keep_playing], [_keep_playing, confirm]]:
		var path: NodePath = pair[0].get_path_to(pair[1])
		for property: String in ["focus_next", "focus_previous", "focus_neighbor_left", "focus_neighbor_right", "focus_neighbor_top", "focus_neighbor_bottom"]:
			pair[0].set(property, path)
	_quit_confirmation.hide()


func cancel_quit_confirmation() -> bool:
	if closing: return false
	if not _quit_confirmation.visible: return false
	_quit_confirmation.hide()
	_paper.show()
	_animate_confirmation(_paper)
	_quit.grab_focus()
	return true


func _animate_confirmation(panel: Control) -> void:
	if _confirmation_motion: _confirmation_motion.kill()
	panel.pivot_offset = panel.size * .5
	panel.scale = Vector2.ONE * .97
	panel.modulate.a = 0.0
	_confirmation_motion = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_confirmation_motion.tween_property(panel, "scale", Vector2.ONE, .18)
	_confirmation_motion.tween_property(panel, "modulate:a", 1.0, .14)


func set_wallpaper_available(available: bool) -> void:
	_wallpaper_supported = available
	_wallpaper.visible = available
	_refresh_focus_chain(_page_index)


func set_wallpaper_interaction(enabled: bool) -> void:
	_wallpaper_interactive = enabled
	set_wallpaper_mode(_wallpaper_active)


func set_wallpaper_mode(active: bool) -> void:
	_wallpaper_active = active
	_wallpaper.text = "结束桌面操作" if active else "设为壁纸"
	if not _wallpaper_interactive:
		_wallpaper.tooltip_text = "全屏展示农场，不接收桌面点击；菜单栏图标可返回窗口。"
		return
	_wallpaper.tooltip_text = "收起操作控件，继续展示壁纸。" if active else "悬停农具高亮，点击后直接在桌面照料农场；托盘可返回窗口。"


func _option(parent: Control, title: String, node_name: String, items: Array) -> OptionButton:
	var option := OptionButton.new()
	option.name = node_name
	for item: String in items: option.add_item(item)
	FarmTheme.configure_option(option)
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.custom_minimum_size.y = 42
	_row(parent, title).add_child(option)
	return option


func _refresh_preset() -> void:
	_quality.select(Presets.matching(_values, get_window().size.y, RenderingServer.get_current_rendering_method() == "forward_plus"))


func _sync_graphics() -> void:
	_refresh_preset()
	_resolution.select(RESOLUTION_VALUES.find(_values.resolution))
	_fsr.select(FSR_VALUES.find(_values.fsr))
	for key: String in _graphics:
		var choices: Array = ["off", "2x", "4x"] if key == "antialiasing" else QUALITY_VALUES
		_graphics[key].select(choices.find(_values[key]))


func _choose_preset(index: int) -> void:
	if _populating or index >= QUALITY_VALUES.size(): return
	_values.merge(Presets.values(QUALITY_VALUES[index], get_window().size.y, RenderingServer.get_current_rendering_method() == "forward_plus"), true)
	_sync_graphics()
	_refresh_fsr()
	_refresh_dof()
	settings_changed.emit(_values.duplicate(true))


func _request_wallpaper() -> void:
	if not _wallpaper_supported: return
	if _wallpaper_active:
		wallpaper_requested.emit()
		return
	_paper.hide()
	_wallpaper_confirmation.show()
	_animate_confirmation(_wallpaper_confirmation)
	_wallpaper_confirmation.get_node("Column/Actions/Cancel").grab_focus()


func _build_wallpaper_confirmation() -> void:
	_wallpaper_confirmation = PanelContainer.new()
	_wallpaper_confirmation.name = "WallpaperConfirmation"
	_root.add_child(_wallpaper_confirmation)
	_wallpaper_confirmation.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_wallpaper_confirmation.offset_left = -280
	_wallpaper_confirmation.offset_right = 280
	_wallpaper_confirmation.offset_top = -150
	_wallpaper_confirmation.offset_bottom = 150
	var column := VBoxContainer.new()
	column.name = "Column"
	_wallpaper_confirmation.add_child(column)
	var title := Label.new()
	title.text = "设为桌面壁纸？"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	var message := Label.new()
	message.text = "想在壁纸上操作农场，可以点击门前的椅子。\n\n想回到游戏窗口，请右键点击右下角系统托盘中的游戏图标，选择“返回农场”。"
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(message)
	var actions := HBoxContainer.new()
	actions.name = "Actions"
	column.add_child(actions)
	var cancel := _button(actions, "取消")
	cancel.name = "Cancel"
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(cancel_wallpaper_confirmation)
	var confirm := _button(actions, "设为桌面壁纸")
	confirm.name = "Confirm"
	confirm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm.pressed.connect(func() -> void:
		cancel_wallpaper_confirmation()
		wallpaper_requested.emit())
	for pair: Array in [[cancel, confirm], [confirm, cancel]]:
		for property: String in ["focus_next", "focus_previous", "focus_neighbor_left", "focus_neighbor_right", "focus_neighbor_top", "focus_neighbor_bottom"]:
			pair[0].set(property, pair[0].get_path_to(pair[1]))
	_wallpaper_confirmation.hide()


func cancel_wallpaper_confirmation() -> bool:
	if closing or not _wallpaper_confirmation.visible: return false
	_wallpaper_confirmation.hide()
	_paper.show()
	_animate_confirmation(_paper)
	_wallpaper.grab_focus()
	return true


## Replacing the local identity changes membership in every world, so it asks
## again and names what does not follow the new id. The scene owns the reset;
## this menu only reports intent and never touches the profile files.
func _request_identity_reset() -> void:
	_paper.hide()
	_identity_confirmation.show()
	_animate_confirmation(_identity_confirmation)
	_identity_keep.grab_focus()


func cancel_identity_reset_confirmation() -> bool:
	if closing or not _identity_confirmation.visible: return false
	_identity_confirmation.hide()
	_paper.show()
	_animate_confirmation(_paper)
	_identity.grab_focus()
	return true


func _build_identity_confirmation() -> void:
	_identity_confirmation = PanelContainer.new()
	_identity_confirmation.name = "IdentityResetConfirmation"
	_root.add_child(_identity_confirmation)
	_identity_confirmation.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_identity_confirmation.offset_left = -300
	_identity_confirmation.offset_right = 300
	_identity_confirmation.offset_top = -120
	_identity_confirmation.offset_bottom = 120
	var column := VBoxContainer.new()
	column.name = "Column"
	_identity_confirmation.add_child(column)
	var title := Label.new()
	title.text = "重置玩家身份？"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	var message := Label.new()
	message.text = "会换用新的玩家 ID 和本机凭据。\n旧身份在世界里的成员资格和开户赠款不会迁移；旧身份材料会归档保留。"
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(message)
	var actions := HBoxContainer.new()
	actions.name = "Actions"
	column.add_child(actions)
	var cancel := _button(actions, "取消")
	cancel.name = "Cancel"
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(cancel_identity_reset_confirmation)
	_identity_keep = cancel
	var confirm := _button(actions, "重置身份")
	confirm.name = "Confirm"
	confirm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_exit(confirm)
	confirm.pressed.connect(func() -> void:
		_identity_confirmation.hide()
		_paper.show()
		_animate_confirmation(_paper)
		identity_reset_requested.emit())
	for pair: Array in [[cancel, confirm], [confirm, cancel]]:
		for property: String in ["focus_next", "focus_previous", "focus_neighbor_left", "focus_neighbor_right", "focus_neighbor_top", "focus_neighbor_bottom"]:
			pair[0].set(property, pair[0].get_path_to(pair[1]))
	_identity_confirmation.hide()


func _choose_world_export() -> void:
	if not export_path_override.is_empty():
		world_export_requested.emit(export_path_override)
		return
	_show_world_dialog(_export_dialog)


func _choose_world_import() -> void:
	if not import_path_override.is_empty():
		world_import_requested.emit(import_path_override)
		return
	_show_world_dialog(_import_dialog)


func _show_world_dialog(dialog: FileDialog) -> void:
	_export_dialog.hide()
	_import_dialog.hide()
	dialog.popup_centered_ratio(0.7)


func _build_world_dialogs() -> void:
	var documents: String = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	_export_dialog = _world_dialog("选择世界包导出位置", documents)
	_export_dialog.name = "ExportWorldDialog"
	_export_dialog.dir_selected.connect(func(path: String) -> void:
		_export_dialog.hide()
		world_export_requested.emit(path))
	_import_dialog = _world_dialog("选择世界包目录", documents)
	_import_dialog.name = "ImportWorldDialog"
	_import_dialog.dir_selected.connect(func(path: String) -> void:
		_import_dialog.hide()
		world_import_requested.emit(path))


func _world_dialog(title: String, directory: String) -> FileDialog:
	var dialog := FileDialog.new()
	dialog.title = title
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = false
	if not directory.is_empty():
		dialog.current_dir = directory
	dialog.theme = _root.theme
	_root.add_child(dialog)
	return dialog


func set_world_status(message: String) -> void:
	if _world_status == null: return
	_world_status.text = message
	_world_status.visible = not message.is_empty()


func present_world_import(summary: Dictionary) -> void:
	if _confirmation_motion: _confirmation_motion.kill()
	_world_import_error.text = ""
	_world_import_error.visible = false
	_world_import_text.text = _world_import_summary(summary)
	_paper.hide()
	_world_import_confirmation.show()
	_animate_confirmation(_world_import_confirmation)
	_world_import_confirmation.get_node("Column/Actions/Cancel").grab_focus()


func world_import_failed(message: String) -> void:
	_world_import_error.text = message
	_world_import_error.visible = not message.is_empty()


func cancel_world_import_confirmation() -> bool:
	if closing or not _world_import_confirmation.visible: return false
	_world_import_confirmation.hide()
	_world_import_error.text = ""
	_world_import_error.visible = false
	_paper.show()
	_animate_confirmation(_paper)
	_import_world.grab_focus()
	world_import_cancelled.emit()
	return true


func _world_import_summary(summary: Dictionary) -> String:
	var world_id: String = str(summary.get("world_id", ""))
	var short_id: String = world_id.substr(0, 12) + "…" if world_id.length() > 12 else world_id
	var exported_at: int = int(summary.get("exported_at_utc_seconds", 0))
	var exported_text: String = "未记录" if exported_at <= 0 else Time.get_datetime_string_from_unix_time(exported_at, true)
	var backup: String = str(summary.get("backup_path", ""))
	var backup_text: String = backup if not backup.is_empty() else "当前还没有存档，本次导入会直接建立新存档。"
	return "世界：%s\n导出时间：%s\n\n导入后会替换当前的田地、库存、布局、邻居、厨房、动物记忆和装饰；玩家与设备标识沿用包内记录。\n\n原存档会保留在：\n%s" % [short_id, exported_text, backup_text]


func _build_world_import_confirmation() -> void:
	_world_import_confirmation = PanelContainer.new()
	_world_import_confirmation.name = "WorldImportConfirmation"
	_root.add_child(_world_import_confirmation)
	_world_import_confirmation.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_world_import_confirmation.offset_left = -330
	_world_import_confirmation.offset_right = 330
	_world_import_confirmation.offset_top = -220
	_world_import_confirmation.offset_bottom = 220
	var column := VBoxContainer.new()
	column.name = "Column"
	_world_import_confirmation.add_child(column)
	var title := Label.new()
	title.text = "导入这个世界包？"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	_world_import_text = Label.new()
	_world_import_text.name = "ImportSummary"
	_world_import_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_world_import_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_world_import_text)
	_world_import_error = Label.new()
	_world_import_error.name = "ImportError"
	_world_import_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_world_import_error.add_theme_font_size_override("font_size", 17)
	_world_import_error.add_theme_color_override("font_color", FarmTheme.Tokens.DANGER)
	column.add_child(_world_import_error)
	var actions := HBoxContainer.new()
	actions.name = "Actions"
	column.add_child(actions)
	var cancel := _button(actions, "取消")
	cancel.name = "Cancel"
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(cancel_world_import_confirmation)
	var confirm := _button(actions, "导入并替换")
	confirm.name = "Confirm"
	confirm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm.pressed.connect(func() -> void: world_import_confirmed.emit())
	for pair: Array in [[cancel, confirm], [confirm, cancel]]:
		for property: String in ["focus_next", "focus_previous", "focus_neighbor_left", "focus_neighbor_right", "focus_neighbor_top", "focus_neighbor_bottom"]:
			pair[0].set(property, pair[0].get_path_to(pair[1]))
	_world_import_confirmation.hide()
