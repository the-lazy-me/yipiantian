extends RefCounted
## Shared pigment surfaces and interaction states for HUD and menus.

const FONT = preload("res://art/ui/fonts/汇文明朝体.ttf")
const Tokens = preload("res://ui/ui_tokens.gd")
const PigmentStyle = preload("res://ui/pigment_style.gd")
const INK := Tokens.INK
const PAPER := Tokens.PAPER
const EDGE := Tokens.EDGE
const LEAF := Tokens.LEAF


static func create() -> Theme:
	var theme := Theme.new()
	theme.default_font = FONT
	theme.default_font_size = 20
	for type: String in ["Label", "Button", "OptionButton", "CheckButton", "CheckBox", "RichTextLabel", "PopupMenu"]:
		theme.set_color("font_color", type, INK)
		theme.set_color("font_hover_color", type, INK)
		theme.set_color("font_focus_color", type, INK)
		theme.set_color("font_pressed_color", type, INK)
		theme.set_color("font_hover_pressed_color", type, INK)
		theme.set_color("font_disabled_color", type, Tokens.MUTED)
	for type: String in ["Button", "OptionButton"]:
		theme.set_stylebox("normal", type, framed_paper(Tokens.WASH))
		theme.set_stylebox("hover", type, framed_paper(Tokens.WASH_HOVER))
		theme.set_stylebox("pressed", type, framed_paper(Tokens.WASH_PRESSED, true))
		theme.set_stylebox("hover_pressed", type, framed_paper(Tokens.WASH_PRESSED, true))
		theme.set_stylebox("disabled", type, framed_paper(Tokens.DISABLED))
		var focus := StyleBoxFlat.new()
		focus.draw_center = false
		focus.border_color = LEAF
		focus.set_border_width_all(1)
		focus.set_corner_radius_all(10)
		focus.set_expand_margin_all(-4)
		theme.set_stylebox("focus", type, focus)
		theme.set_constant("h_separation", type, 8)
	# Shared fields: a washed paper entry that stays legible on the beige panels.
	theme.set_stylebox("normal", "LineEdit", field(Tokens.WASH))
	theme.set_stylebox("read_only", "LineEdit", field(Tokens.DISABLED))
	theme.set_stylebox("focus", "LineEdit", field(Tokens.WASH_HOVER, LEAF))
	for color_name: String in ["font_color", "caret_color"]:
		theme.set_color(color_name, "LineEdit", INK)
	theme.set_color("font_uneditable_color", "LineEdit", Tokens.MUTED)
	theme.set_color("font_placeholder_color", "LineEdit", Tokens.MUTED)
	theme.set_color("selection_color", "LineEdit", LEAF)
	theme.set_color("font_selected_color", "LineEdit", PAPER)
	for state: String in ["checked", "unchecked", "checked_disabled", "unchecked_disabled"]:
		var icon: Texture2D = _check_icon(state.begins_with("checked"), state.ends_with("disabled"))
		if icon != null:
			theme.set_icon(state, "CheckBox", icon)
	theme.set_constant("h_separation", "CheckBox", 8)
	theme.set_stylebox("panel", "PanelContainer", framed_paper())
	theme.set_stylebox("panel", "Panel", framed_paper())
	var popup := framed_paper()
	popup.content_margin_left = 6
	popup.content_margin_right = 6
	popup.content_margin_top = 6
	popup.content_margin_bottom = 6
	theme.set_stylebox("panel", "PopupMenu", popup)
	var highlight := paper(Tokens.WASH_HOVER, 3)
	highlight.shadow_size = 0
	highlight.set_border_width_all(0)
	theme.set_stylebox("hover", "PopupMenu", highlight)
	theme.set_constant("arrow_margin", "OptionButton", 16)
	theme.set_constant("modulate_arrow", "OptionButton", 1)
	theme.set_color("font_hover_color", "PopupMenu", INK)
	theme.set_constant("v_separation", "PopupMenu", 16)
	theme.set_constant("separation", "VBoxContainer", Tokens.GAP)
	theme.set_constant("separation", "HBoxContainer", Tokens.GAP)
	var track: StyleBoxFlat = paper(Tokens.TRACK, 4)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	theme.set_stylebox("slider", "HSlider", track)
	var filled: StyleBoxFlat = paper(LEAF, 4)
	filled.content_margin_top = 3
	filled.content_margin_bottom = 3
	theme.set_stylebox("grabber_area", "HSlider", filled)
	theme.set_stylebox("grabber_area_highlight", "HSlider", filled)
	for state: String in ["grabber", "grabber_highlight", "grabber_disabled"]:
		theme.set_icon(state, "HSlider", preload("res://art/ui/pigment/slider-thumb.png"))
	for type: String in ["VScrollBar", "HScrollBar"]:
		for state: String in ["scroll", "grabber", "grabber_highlight", "grabber_pressed"]:
			var bar := paper(Tokens.TRACK if state == "scroll" else LEAF, 3)
			bar.shadow_size = 0
			bar.set_border_width_all(0)
			for side: int in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
				bar.set_content_margin(side, 3)
			theme.set_stylebox(state, type, bar)
	return theme


static func framed_paper(fill: Color = PAPER, selected: bool = false) -> StyleBox:
	var style := PigmentStyle.new()
	style.fill = fill
	style.edge = EDGE
	style.selected = selected
	style.content_margin_left = Tokens.INSET_X
	style.content_margin_right = Tokens.INSET_X
	style.content_margin_top = Tokens.INSET_Y
	style.content_margin_bottom = Tokens.INSET_Y
	return style


## Text entries use the same pigment surface with tighter, field-sized insets.
static func field(fill: Color = Tokens.WASH, edge: Color = EDGE) -> StyleBox:
	var style := PigmentStyle.new()
	style.fill = fill
	style.edge = edge
	style.radius = 8.0
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	return style


static func configure_option(button: OptionButton) -> void:
	for index: int in button.item_count:
		button.get_popup().set_item_as_radio_checkable(index, false)
	pointer_focus(button)


static func pointer_focus(button: BaseButton) -> void:
	# Pointer activation need not leave a keyboard-navigation ring behind.
	if button.has_meta("_farm_pointer_focus"):
		return
	button.set_meta("_farm_pointer_focus", true)
	button.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and not event.pressed:
			(func() -> void:
				if is_instance_valid(button) and button.is_inside_tree():
					button.release_focus()).call_deferred())


## Focus traversal that stays inside one modal. Visible, enabled inputs get a
## closed ring in both directions so Tab and arrow keys cannot reach the HUD.
static func wrap_focus(root: Control, key: String = "") -> void:
	var controls: Array[Control] = []
	_collect_focus(root, controls)
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
	if controls.is_empty():
		return
	var target: Control = null
	if not key.is_empty():
		for control: Control in controls:
			if focus_key(control) == key:
				target = control
				break
	if target == null:
		var owner: Control = null
		if root.is_inside_tree():
			owner = root.get_viewport().gui_get_focus_owner()
		if owner != null and root.is_ancestor_of(owner):
			return
		target = controls[0]
	target.grab_focus()


static func focus_key(control: Control) -> String:
	# A SpinBox's inner LineEdit has an internal name; the field is addressed by
	# its owner so a rebuild can find it again.
	var named: Control = control
	if control is LineEdit and control.get_parent() is SpinBox:
		named = control.get_parent() as Control
	return str(named.get_meta("focus_key", str(named.name)))


## The key of the control that currently owns keyboard focus inside this modal,
## or an empty string when focus is elsewhere.
static func focus_key_within(root: Control) -> String:
	if not root.is_inside_tree():
		return ""
	var owner: Control = root.get_viewport().gui_get_focus_owner()
	return focus_key(owner) if owner != null and root.is_ancestor_of(owner) else ""


static func _collect_focus(node: Node, controls: Array[Control]) -> void:
	if node is Control:
		var control: Control = node as Control
		var disabled: bool = control is BaseButton and (control as BaseButton).disabled
		# A SpinBox owns its inner LineEdit as an internal child and reports
		# FOCUS_NONE itself; the line edit is the control that takes typing focus,
		# so the ring visits it instead of the wrapper.
		if not (control is SpinBox) and control.is_visible_in_tree() and not disabled \
				and control.focus_mode != Control.FOCUS_NONE \
				and (control is BaseButton or control is Range or control is LineEdit):
			controls.append(control)
	for child: Node in node.get_children(true):
		_collect_focus(child, controls)


static func _check_icon(checked: bool, disabled: bool = false) -> Texture2D:
	var edge: String = "#" + (Tokens.MUTED if disabled else LEAF).to_html(false)
	var ink: String = "#" + (Tokens.MUTED if disabled else INK).to_html(false)
	var fill: String = "#" + Tokens.DISABLED.to_html(false)
	var mark: String = ""
	if checked:
		mark = '<path d="M5 10.4 L8.4 13.8 L15.2 5.8" fill="none" stroke="%s" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>' % ink
	var svg: String = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20"><rect x="1.5" y="1.5" width="17" height="17" rx="3.5" fill="%s" stroke="%s" stroke-width="1.5"/>%s</svg>' % [fill, edge, mark]
	var image := Image.new()
	if image.load_svg_from_string(svg) != OK:
		return null
	return ImageTexture.create_from_image(image)


static func paper(color: Color = PAPER, radius: int = 18) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = EDGE
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.corner_detail = 24
	style.content_margin_left = Tokens.INSET_X
	style.content_margin_right = Tokens.INSET_X
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	style.shadow_color = Color(0.22, 0.24, 0.17, 0.16)
	style.shadow_size = 3
	style.shadow_offset = Vector2(0, 2)
	return style
