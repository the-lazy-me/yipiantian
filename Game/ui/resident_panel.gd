extends Control
## 居民只读面板：把权威发来的 `residents` 视图摆出来。
##
## 面板不派生人格、不推导关系、不排序、不合并增量，也不写任何文档或发动作；
## 每次答复整份替换视图。`available=false` 时只显示权威给出的原因，并禁用列表，
## 不发明本地居民。
##
## 视图形状见 `HeadlessWorld.residents_view()`：每行含显示名、角色、五维人格、
## 两名邻居的关系、记忆条数与最近时刻、已消费意图数和最近购买。

signal refresh_requested
signal close_requested

const FarmTheme = preload("res://ui/farm_theme.gd")
const NpcPersonality = preload("res://npc/npc_personality.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")
const INK := FarmTheme.INK

const ROLE_LABELS: Dictionary = {
	"merchant": "商人", "banker": "银行家", "official": "官员",
}

## 权威居民视图：`{available, reason, viewer, residents: [...]}`。
var view: Dictionary = {}
## 权威居民行，按权威数组顺序保留；面板不排序。
var residents: Array = []

var _focus_before: Control
var _status: Label
var _list: VBoxContainer


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
	paper.custom_minimum_size = Vector2(860, 640)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	paper.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	column.add_child(header)
	var title := Label.new()
	title.text = "居民"
	title.add_theme_color_override("font_color", INK)
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var refresh := _button(header, "刷新", "Refresh", 84.0)
	refresh.pressed.connect(func() -> void: refresh_requested.emit())
	var close_button := _button(header, "收起", "Close", 84.0)
	close_button.pressed.connect(func() -> void: close_panel())
	_status = Label.new()
	_status.name = "ResidentStatus"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
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
	_list = VBoxContainer.new()
	_list.name = "ResidentList"
	_list.add_theme_constant_override("separation", 12)
	body.add_child(_list)
	visibility_changed.connect(_on_visibility_changed)
	_fill_view()
	hide()


## Rebuilds from the authoritative resident view. The next reply replaces the
## whole view; the panel never merges rows itself.
func open_panel(next: Dictionary = {}) -> void:
	var focus_key: String = FarmTheme.focus_key_within(self)
	_apply_view(next)
	show()
	if visible:
		FarmTheme.wrap_focus(self, focus_key)


## Clears the view and renders the unavailable state without showing the panel.
## Used when the world is single-player or the connection is gone, so a stale
## authoritative view is not left on screen.
func show_unavailable(reason: String = "not_open") -> void:
	_apply_view({"available": false, "reason": reason, "viewer": "", "residents": []})


func is_open() -> bool:
	return visible


## The resident panel has no dropdown or confirmation of its own.
func is_popup_open() -> bool:
	return false


func close_panel() -> void:
	if not visible:
		return
	hide()
	close_requested.emit()


## The authority reply is the only source of resident facts. A reply without a
## `state` changes nothing; a reply with one replaces the whole view.
func apply_result(payload: Dictionary) -> void:
	var state_value: Variant = payload.get("state")
	if state_value is Dictionary:
		_apply_view(state_value)


func _apply_view(next: Dictionary) -> void:
	view = next.duplicate(true)
	residents = _rows_from(view)
	_fill_view()


func _fill_view() -> void:
	if _list == null:
		return
	var available: bool = bool(view.get("available", false))
	_status.text = _availability_text(available)
	# A read-only list has nothing to disable but its visibility: when the
	# authority says it is unavailable, no resident row is rendered.
	_list.visible = available
	_clear(_list)
	if not available:
		return
	if residents.is_empty():
		_add(_list, "还没有居民。")
		return
	for row_value: Variant in residents:
		if row_value is Dictionary:
			_build_resident(row_value as Dictionary)


func _availability_text(available: bool) -> String:
	if available:
		return "居民已启用｜%d 位居民" % residents.size()
	match str(view.get("reason", "")):
		"disabled":
			return "居民未启用"
		_:
			return "世界尚未打开"


func _build_resident(row: Dictionary) -> void:
	var npc_id: String = str(row.get("id", ""))
	var block := VBoxContainer.new()
	block.name = "Resident_" + npc_id
	block.add_theme_constant_override("separation", 2)
	_list.add_child(block)
	var role: String = str(row.get("role", ""))
	var role_label: String = str(ROLE_LABELS.get(role, role))
	_add(block, "%s｜%s（%s）" % [
		str(row.get("display_name", "")), role_label, role,
	], "Name_" + npc_id)
	_add(block, "人格：" + _traits_text(row.get("traits")), "Traits_" + npc_id)
	var relations: Variant = row.get("relations", [])
	if relations is Array:
		for peer_value: Variant in relations:
			if peer_value is Dictionary:
				var peer: Dictionary = peer_value
				var peer_id: String = str(peer.get("id", ""))
				_add(block, _relation_text(peer),
					"Relation_%s_%s" % [npc_id, peer_id])
	var memory_count: int = int(row.get("memory_count", 0))
	var last_memory: float = float(row.get("last_memory_utc", 0.0))
	var memory_text: String = "记忆 %d 条｜最近 %s" % [
		memory_count, _utc_text(last_memory),
	]
	_add(block, memory_text, "Memory_" + npc_id)
	_add(block, "已消费意图 %d" % int(row.get("intents_consumed", 0)),
		"Intent_" + npc_id)
	_add(block, _purchase_text(row.get("last_purchase")), "Purchase_" + npc_id)


func _traits_text(value: Variant) -> String:
	var traits: Dictionary = value if value is Dictionary else {}
	var readings: Array[String] = []
	for trait_name: String in NpcPersonality.TRAITS:
		if not traits.has(trait_name):
			continue
		readings.append("%s %d" % [
			str(NpcPersonality.LABELS.get(trait_name, trait_name)),
			int(traits[trait_name]),
		])
	return "、".join(readings) if not readings.is_empty() else "未记录"


func _relation_text(peer: Dictionary) -> String:
	return "与 %s：好感 %d｜动作 %d｜赠礼 %d｜最近 %s" % [
		str(peer.get("display_name", "")), int(peer.get("affinity", 0)),
		int(peer.get("acts", 0)), int(peer.get("gifts", 0)),
		_utc_text(float(peer.get("last_utc", 0.0))),
	]


func _purchase_text(value: Variant) -> String:
	if not value is Dictionary or (value as Dictionary).is_empty():
		return "最近购买：暂无成交记录"
	var purchase: Dictionary = value
	var good: String = str(purchase.get("good", ""))
	var good_name: String = str(EconomyCatalog.definition(good).get("name", good))
	if good_name.is_empty():
		return "最近购买：暂无成交记录"
	return "最近购买 %s（%s）｜%s" % [
		good_name, good, _utc_text(float(purchase.get("at_utc", 0.0))),
	]


func _utc_text(value: float) -> String:
	return "UTC %d" % int(value) if value > 0.0 else "未记录"


## Copies the rows in the authority's own order. Unlike the case or project
## lists there is no local sort: roster order is an authoritative fact.
func _rows_from(source: Dictionary) -> Array:
	var rows: Array = []
	var value: Variant = source.get("residents")
	if value is Array:
		for row_value: Variant in value:
			if row_value is Dictionary:
				rows.append((row_value as Dictionary).duplicate(true))
	return rows


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
		FarmTheme.wrap_focus(self)


func _input(event: InputEvent) -> void:
	# Esc belongs to the panel only while it is open and there is no popup.
	if not visible or not (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE):
		return
	close_panel()
	get_viewport().set_input_as_handled()


func _add(parent: Control, text: String, node_name: String = "") -> Label:
	var label := Label.new()
	if not node_name.is_empty():
		label.name = node_name
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", INK)
	label.add_theme_font_size_override("font_size", 16)
	parent.add_child(label)
	return label


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
