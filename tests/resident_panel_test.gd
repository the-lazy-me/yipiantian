extends SceneTree
## 居民面板作为只读视图：它只根据权威 `residents` 视图决定显示什么，不派生、
## 不排序、不写回，也不发动作。没有网络：视图直接构造，刷新通过假请求器转发。

const ResidentPanel = preload("res://ui/resident_panel.gd")

const LIN: String = "npc_lin_shen"
const XU: String = "npc_xu_bo"
const ZHOU: String = "npc_a_zhou"
const ORDER: Array[String] = [ZHOU, XU, LIN]


class FakeRemote extends RefCounted:
	signal residents_result(payload: Dictionary)

	var calls: Array = []

	func request_residents(request_id: String, action: String = "state",
			args: Dictionary = {}) -> bool:
		calls.append({
			"request_id": request_id, "action": action, "args": args.duplicate(true),
		})
		return true


var panel: ResidentPanel
var fake: FakeRemote
var closes: int = 0
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = ResidentPanel.new()
	panel.name = "ResidentPanel"
	root.add_child(panel)
	fake = FakeRemote.new()
	fake.residents_result.connect(panel.apply_result)
	panel.refresh_requested.connect(_request_refresh)
	panel.close_requested.connect(func() -> void: closes += 1)
	await process_frame
	_expect(not panel.is_open(), "The panel starts hidden until the player opens it")

	# A hidden panel must not consume Esc or steal focus from the HUD button.
	var opener := Button.new()
	opener.text = "opener"
	root.add_child(opener)
	opener.grab_focus()
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(not panel.is_open() and closes == 0,
		"A hidden panel ignores Esc instead of opening or closing itself")
	_expect(root.gui_get_focus_owner() == opener,
		"A hidden panel does not take focus from the HUD button")
	esc.pressed = false
	root.push_input(esc)
	await process_frame

	# An empty view is not an empty world: the panel says the world is not open
	# and renders no resident row.
	panel.open_panel({})
	_expect(panel.is_open(), "Opening the panel shows it")
	_expect(_status() == "世界尚未打开",
		"An empty view says the world is not open")
	_expect(not _list().visible and _list().get_child_count() == 0,
		"An empty view disables the resident list")

	# The two authoritative unavailable reasons get distinct copy.
	panel.open_panel(_view(false, "disabled", []))
	_expect(_status() == "居民未启用", "A disabled authority says residents are disabled")
	_expect(not _list().visible and _list().get_child_count() == 0,
		"A disabled view renders no resident row")
	panel.open_panel(_view(false, "not_open", []))
	_expect(_status() == "世界尚未打开", "A closed world says it is not open")
	_expect(not _list().visible, "A closed world disables the resident list")

	# The authority's array order is rendered as-is: this fixture is deliberately
	# not in NpcRoster.IDS order, and the panel must not sort it.
	panel.open_panel(_view(true, "", _rows()))
	_expect(panel.is_open() and _list().visible,
		"An available view shows the resident list")
	_expect(panel.residents.size() == 3, "All authoritative residents are kept")
	_expect(_ids(panel.residents) == ORDER,
		"Resident rows keep the authority array order instead of sorting locally")
	_expect(_child_names() == _expected_names(ORDER),
		"The rendered blocks follow the authority order")
	_expect(_status() == "居民已启用｜3 位居民",
		"The status line reports the authoritative resident count")

	# Each block carries exactly the authoritative facts: name, role, five
	# personality readings, two relations, memory size/time, intents and purchase.
	var lin_name: String = _label("Name_" + LIN)
	_expect(lin_name.contains("林婶") and lin_name.contains("官员")
		and lin_name.contains("official"),
		"A resident row shows its display name and authoritative role")
	var lin_traits: String = _label("Traits_" + LIN)
	for fragment: String in ["勤勉 50", "温和 70", "多疑 30", "好奇 60", "慷慨 60"]:
		_expect(lin_traits.contains(fragment),
			"A resident row shows the trait reading %s" % fragment)
	var lin_xu: String = _label("Relation_%s_%s" % [LIN, XU])
	_expect(lin_xu.contains("许伯") and lin_xu.contains("好感 8")
		and lin_xu.contains("动作 4") and lin_xu.contains("赠礼 1")
		and lin_xu.contains("UTC 1800052812"),
		"A relation row shows affinity, acts, gifts and the last time")
	_expect(panel.find_child("Relation_%s_%s" % [LIN, ZHOU], true, false) != null,
		"Every authoritative relation row is rendered")
	_expect(_label("Memory_" + LIN).contains("记忆 4 条")
		and _label("Memory_" + LIN).contains("UTC 1800052812"),
		"A resident row shows its memory count and latest time")
	_expect(_label("Invitation_" + LIN).contains("待答邀约 1")
		and _label("Invitation_" + LIN).contains("最近 待答")
		and _label("Invitation_" + LIN).contains("阿舟")
		and _label("Invitation_" + LIN).contains("林婶")
		and _label("Invitation_" + LIN).contains("UTC 1800052800"),
		"A resident row shows pending invitations and the latest outcome")
	_expect(_label("Invitation_" + ZHOU).contains("待答邀约 0"),
		"A resident without invitations says zero")
	_expect(_label("Intent_" + LIN).contains("已消费意图 1"),
		"A resident row shows its consumed intent count")
	var purchase: String = _label("Purchase_" + LIN)
	_expect(purchase.contains("青菜") and purchase.contains("greens")
		and purchase.contains("UTC 1800052810"),
		"A resident row shows the projected last purchase")
	var zhou_purchase: String = _label("Purchase_" + ZHOU)
	_expect(zhou_purchase.contains("暂无成交记录"),
		"A resident without a completed purchase says so")

	# The panel offers no write surface: no text field, checkbox, dropdown or
	# action signal, and refreshing changes nothing locally.
	_expect(_editable_count() == 0,
		"The read-only panel contains no editable control")
	_expect(not panel.has_signal("action") and not panel.has_signal("resident_action"),
		"The panel exposes no write action signal")
	_expect(_button_names() == ["Refresh", "Close"],
		"The panel offers only refresh and close")
	var view_before: Dictionary = panel.view.duplicate(true)
	var calls_before: int = fake.calls.size()
	var refresh: Button = panel.find_child("Refresh", true, false) as Button
	refresh.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == calls_before + 1,
		"Refreshing asks the caller exactly once")
	_expect(fake.calls.back().request_id == "resident-state"
		and fake.calls.back().action == "state",
		"Refreshing sends the documented state request")
	_expect(panel.view == view_before,
		"A refresh request changes nothing on the panel before the reply")

	# A later authority reply replaces the whole view; removed residents do not
	# linger and no row is appended twice.
	var replacement: Dictionary = _view(true, "", [_row(ZHOU, 0, {}, {})])
	fake.residents_result.emit({"ok": true, "state": replacement})
	await process_frame
	_expect(panel.residents.size() == 1,
		"A reply replaces the resident rows instead of merging them")
	_expect(panel.find_child("Resident_" + LIN, true, false) == null
		and panel.find_child("Resident_" + XU, true, false) == null,
		"Residents missing from the replacement are removed")
	_expect(_child_names() == _expected_names([ZHOU]),
		"The replacement list has exactly the new row")
	fake.residents_result.emit({"ok": false, "reason": "rate_limited"})
	await process_frame
	_expect(panel.residents.size() == 1,
		"A refusal without a state keeps the last confirmed rows")

	# Malformed payloads and rows do not crash the panel.
	panel.apply_result({})
	panel.apply_result({"state": {"residents": ["bad", {"id": "odd"}]}})
	await process_frame
	_expect(panel.residents.size() == 1,
		"Malformed resident rows are skipped without crashing")

	# Esc closes the panel and returns focus to the button that opened it.
	panel.open_panel(_view(true, "", _rows()))
	var focus_owner: Control = root.gui_get_focus_owner()
	_expect(focus_owner != null and panel.is_ancestor_of(focus_owner),
		"Opening the resident panel captures keyboard focus inside it")
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(not panel.is_open(), "Esc closes the resident panel")
	_expect(closes == 1, "Closing the panel emits exactly one close signal")
	_expect(root.gui_get_focus_owner() == opener,
		"Closing returns keyboard focus to the HUD button that opened the panel")
	esc.pressed = false
	root.push_input(esc)
	root.push_input(esc)
	await process_frame
	_expect(closes == 1, "Esc after closing is ignored")
	_finish()


func _request_refresh() -> void:
	fake.request_residents("resident-state", "state")


func _view(available: bool, reason: String, rows: Array) -> Dictionary:
	return {
		"available": available, "reason": reason, "viewer": "",
		"residents": rows.duplicate(true),
	}


func _rows() -> Array:
	return [
		_row(ZHOU, 3, {XU: _relation(XU, "许伯", 5, 1800052600.0, 2, 0)},
			{"good": "", "at_utc": 0.0}),
		_row(XU, 2, {LIN: _relation(LIN, "林婶", 6, 1800052700.0, 3, 2)},
			{"good": "greens", "at_utc": 1800052705.0}),
		_row(LIN, 4, {
			XU: _relation(XU, "许伯", 8, 1800052812.0, 4, 1),
			ZHOU: _relation(ZHOU, "阿舟", -3, 1800052800.0, 2, 0),
		}, {"good": "greens", "at_utc": 1800052810.0}),
	]


func _row(npc_id: String, memory_count: int, relations: Dictionary,
		purchase: Dictionary) -> Dictionary:
	var traits: Dictionary = {
		"diligence": 50, "warmth": 70, "suspicion": 30,
		"curiosity": 60, "generosity": 60,
	}
	if npc_id == ZHOU:
		traits = {"diligence": 55, "warmth": 45, "suspicion": 20,
			"curiosity": 80, "generosity": 60}
	elif npc_id == XU:
		traits = {"diligence": 60, "warmth": 50, "suspicion": 40,
			"curiosity": 30, "generosity": 70}
	var rows: Array = []
	for peer_id: String in _peer_order(npc_id):
		if relations.has(peer_id):
			rows.append(relations[peer_id])
	return {
		"id": npc_id,
		"display_name": _display_name(npc_id),
		"role": _role(npc_id),
		"traits": traits,
		"relations": rows,
		"memory_count": memory_count,
		"last_memory_utc": 1800052812.0 if memory_count > 0 else 0.0,
		"intents_consumed": 1 if npc_id == LIN else 0,
		"last_purchase": purchase,
		"pending_invitations": 1 if npc_id == LIN else 0,
		"last_invitation": {
			"from": ZHOU, "to": LIN, "status": "pending",
			"created_utc": 1800052800.0,
		} if npc_id == LIN else {},
	}


## Relation rows are kept in the fixture insertion order to prove the panel does
## not reorder or derive them.
func _peer_order(npc_id: String) -> Array[String]:
	match npc_id:
		LIN:
			return [XU, ZHOU]
		XU:
			return [LIN, ZHOU]
		_:
			return [LIN, XU]


func _relation(peer_id: String, display_name: String, affinity: int,
		last_utc: float, acts: int, gifts: int) -> Dictionary:
	return {
		"id": peer_id, "display_name": display_name, "affinity": affinity,
		"last_utc": last_utc, "acts": acts, "gifts": gifts,
	}


func _display_name(npc_id: String) -> String:
	match npc_id:
		LIN:
			return "林婶"
		XU:
			return "许伯"
		_:
			return "阿舟"


func _role(npc_id: String) -> String:
	match npc_id:
		LIN:
			return "official"
		XU:
			return "banker"
		_:
			return "merchant"


func _list() -> VBoxContainer:
	return panel.find_child("ResidentList", true, false) as VBoxContainer


func _status() -> String:
	var label: Label = panel.find_child("ResidentStatus", true, false) as Label
	return label.text if label != null else ""


func _label(node_name: String) -> String:
	var label: Label = panel.find_child(node_name, true, false) as Label
	return label.text if label != null else ""


func _child_names() -> Array[String]:
	var names: Array[String] = []
	for child: Node in _list().get_children():
		names.append(str(child.name))
	return names


func _expected_names(ids: Array) -> Array[String]:
	var names: Array[String] = []
	for id: Variant in ids:
		names.append("Resident_" + str(id))
	return names


func _ids(rows: Array) -> Array[String]:
	var ids: Array[String] = []
	for row_value: Variant in rows:
		if row_value is Dictionary:
			ids.append(str((row_value as Dictionary).get("id", "")))
	return ids


func _editable_count() -> int:
	var count: int = 0
	for node: Node in panel.find_children("*", "", true, false):
		if node is LineEdit or node is TextEdit or node is SpinBox \
				or node is CheckBox or node is OptionButton:
			count += 1
	return count


func _button_names() -> Array[String]:
	var names: Array[String] = []
	for node: Node in panel.find_children("*", "Button", true, false):
		if not node is CheckBox and not node is OptionButton:
			names.append(str(node.name))
	return names


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("RESIDENT_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
