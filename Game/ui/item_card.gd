extends Button
## Shared picture-above-caption treatment for actual crop, tool and item choices.
const FarmTheme = preload("res://ui/farm_theme.gd")
const Tokens = preload("res://ui/ui_tokens.gd")
var _picture: TextureRect
var _caption: Label
var _badge: Label
var _chip: Panel
var _available: bool = true


func _ready() -> void:
	FarmTheme.pointer_focus(self)


func configure(label: String, texture: Texture2D, dimensions: Vector2 = Vector2(66,84), font_size: int = 16) -> void:
	custom_minimum_size = dimensions
	# The caption band follows its own glyph line instead of a fixed 24px strip;
	# larger cards (seasons, gifts) otherwise clip descenders at the bottom edge.
	var band: int = font_size + 8
	_picture = TextureRect.new()
	_picture.name = "Icon"
	_picture.texture = texture
	_picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_picture)
	_picture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_picture.offset_left = 7
	_picture.offset_right = -7
	_picture.offset_top = 4
	_picture.offset_bottom = -(band + 3)
	_caption = Label.new()
	_caption.name = "Caption"
	_caption.text = label
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_caption.clip_text = true
	_caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_caption.add_theme_font_size_override("font_size",font_size)
	add_child(_caption)
	_caption.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_caption.offset_top = -(band + 2)
	_caption.offset_bottom = -2
	_chip = Panel.new()
	_chip.name = "StateChip"
	_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chip.visible = false
	var chip_style := StyleBoxFlat.new()
	chip_style.bg_color = FarmTheme.PAPER
	chip_style.border_color = FarmTheme.EDGE
	chip_style.set_border_width_all(1)
	chip_style.set_corner_radius_all(3)
	_chip.add_theme_stylebox_override("panel", chip_style)
	add_child(_chip)
	_badge = Label.new()
	_badge.name = "State"
	_badge.position = Vector2(9,4)
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge.add_theme_font_size_override("font_size",Tokens.FONT_BADGE)
	add_child(_badge)

func show_state(placed: bool, available: bool) -> void:
	_available = available
	set_badge("已摆放" if placed else ("未解锁" if not available else ""))


## New-state words ("一篮" for a delivered basket) share the same paper chip.
func set_badge(text: String) -> void:
	_badge.text = text
	_chip.visible = not text.is_empty()
	if _chip.visible:
		if is_inside_tree():
			_layout_chip()
		else:
			# The resolved project font is only available once the card is in a
			# themed tree; size the chip after that instead of with a fallback.
			_layout_chip.call_deferred()
	queue_redraw()


func _layout_chip() -> void:
	if not _chip.visible:
		return
	var font: Font = _badge.get_theme_font("font")
	var width: float = font.get_string_size(_badge.text, HORIZONTAL_ALIGNMENT_LEFT, -1, Tokens.FONT_BADGE).x
	_chip.position = Vector2(4, 2)
	_chip.size = Vector2(width + 10, Tokens.FONT_BADGE + 8)

func _draw() -> void:
	if _caption == null: return
	var mode: int = get_draw_mode()
	var color_name: String = "font_color"
	if disabled: color_name = "font_disabled_color"
	elif mode in [BaseButton.DRAW_PRESSED,BaseButton.DRAW_HOVER_PRESSED]: color_name = "font_pressed_color"
	elif mode == BaseButton.DRAW_HOVER: color_name = "font_hover_color"
	var color: Color = get_theme_color(color_name,"Button")
	_caption.add_theme_color_override("font_color",color)
	_badge.add_theme_color_override("font_color",color)
	_picture.modulate.a = .35 if not _available else (.45 if disabled else 1.0)
