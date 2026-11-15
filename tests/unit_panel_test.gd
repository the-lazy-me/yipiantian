extends SceneTree
## 单位面板作为视图：它只根据权威单位视图决定显示什么，并把点击变成单位操作
## 意图；能否招募、解散或补给，以及现金与粮草是否足够，都由权威决定。
##
## 没有网络：视图直接构造，面板不在这里发起任何请求。

const UnitPanel = preload("res://ui/unit_panel.gd")

const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"

var panel: UnitPanel
var events: Array = []
var refreshes: int = 0
var closes: int = 0
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = UnitPanel.new()
	panel.name = "Units"
	root.add_child(panel)
	panel.unit_action.connect(func(action: String, args: Dictionary) -> void:
		events.append({"action": action, "args": args}))
	panel.refresh_requested.connect(func() -> void: refreshes += 1)
	panel.closed.connect(func() -> void: closes += 1)
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

	# Empty authority view: the list says so instead of inventing a unit.
	panel.open_panel({"units": []})
	var unit_list: VBoxContainer = panel.find_child("UnitList", true, false) as VBoxContainer
	_expect(panel.is_open(), "Opening the panel shows it")
	_expect(unit_list != null and _has_text(unit_list, "还没有单位。"),
		"An empty authority view says there are no units")
	_expect(panel.find_child("Disband_unit-a", true, false) == null,
		"No disband action appears for an empty roster")

	# Multi-row view: rows are sorted by id and every authoritative field is shown.
	panel.open_panel(_units())
	_expect(panel.units.size() == 2, "Both authoritative units are kept in the view")
	var first: Label = _row_label(0)
	var second: Label = _row_label(1)
	_expect(first != null and first.name == "Unit_unit-a",
		"Rows are sorted by unit id (got %s)" % (first.name if first != null else "null"))
	_expect(second != null and second.name == "Unit_unit-b",
		"A second row follows the sort order")
	var text: String = second.text if second != null else ""
	_expect(text.contains("unit-b") and text.contains(BOB),
		"A row names the unit and its owner (got %s)" % text)
	_expect(text.contains("卫兵"), "A row shows the authoritative kind")
	_expect(text.contains("80 人"), "A row shows the authoritative people count")
	_expect(text.contains("精锐装备"), "A row shows the authoritative equipment")
	_expect(text.contains("camp-b"), "A row shows the authoritative station")
	_expect(text.contains("欠供 2 天"), "A row shows the authoritative unfed days")
	_expect(panel.find_child("Disband_unit-b", true, false) != null,
		"Every row offers its own disband action")
	var focus_owner: Control = root.gui_get_focus_owner()
	_expect(focus_owner != null and panel.is_ancestor_of(focus_owner),
		"Opening the unit panel captures keyboard focus inside it")
	var scroll: ScrollContainer = panel.find_child("Scroll", true, false) as ScrollContainer
	_expect(scroll != null and scroll.follow_focus,
		"The roster scrolls to follow keyboard focus")
	var refresh: Button = panel.find_child("Refresh", true, false) as Button
	refresh.pressed.emit()
	await process_frame
	_expect(refreshes == 1, "Refreshing asks the caller for a new authoritative view")

	# Recruiting carries the chosen kind, people, equipment, station and a unique id.
	_select_meta(panel._kind, "guard")
	_select_meta(panel._equipment, "basic")
	panel._people.text = "12"
	panel._station.text = "  camp-a  "
	var recruit: Button = panel.find_child("Recruit", true, false) as Button
	var before: int = events.size()
	recruit.pressed.emit()
	await process_frame
	_expect(events.size() == before + 1 and events.back().action == "recruit",
		"Recruiting emits a recruit intent")
	var args: Dictionary = events.back().args
	_expect(not str(args.get("command_id", "")).is_empty(),
		"A recruit request carries a non-empty request id")
	_expect(args.get("kind") == "guard", "The recruit names the chosen kind")
	_expect(int(args.get("people", 0)) == 12, "The recruit carries the entered people count")
	_expect(args.get("equipment") == "basic", "The recruit names the chosen equipment")
	_expect(args.get("station") == "camp-a",
		"The recruit carries the trimmed station (got %s)" % str(args.get("station")))

	# A failed-input shape never becomes a request. No resource check happens here.
	var first_id: String = str(args.get("command_id", ""))
	panel._people.text = "0"
	before = events.size()
	recruit.pressed.emit()
	await process_frame
	_expect(events.size() == before and panel._status.text.contains("正整数"),
		"Zero people is refused before it becomes a request")
	panel._people.text = "abc"
	before = events.size()
	recruit.pressed.emit()
	await process_frame
	_expect(events.size() == before and panel._status.text.contains("正整数"),
		"Non-numeric people is refused before it becomes a request")
	panel._people.text = ""
	before = events.size()
	recruit.pressed.emit()
	await process_frame
	_expect(events.size() == before, "An empty people field never becomes a request")
	panel._people.text = "12"
	recruit.pressed.emit()
	await process_frame
	_expect(events.size() == before + 1 and str(events.back().args.command_id) != first_id,
		"Each recruit click gets its own request id")

	# Disband asks for confirmation: clicking alone, or cancelling, sends nothing.
	var disband: Button = panel.find_child("Disband_unit-b", true, false) as Button
	before = events.size()
	disband.pressed.emit()
	await process_frame
	_expect(events.size() == before and panel._confirm.visible,
		"Disbanding only opens a confirmation")
	_expect(panel.is_popup_open(), "An open confirmation owns the next Esc")
	panel._confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(events.size() == before,
		"Cancelling the confirmation sends no disband request")
	_expect(not panel.is_popup_open(), "Cancelling releases the Esc ownership")
	disband.pressed.emit()
	await process_frame
	panel._confirm.get_ok_button().pressed.emit()
	await process_frame
	_expect(events.size() == before + 1 and events.back().action == "disband",
		"Confirming emits a disband request")
	_expect(str(events.back().args.get("unit_id", "")) == "unit-b",
		"The disband names the chosen unit")
	_expect(not str(events.back().args.get("command_id", "")).is_empty(),
		"The disband carries a non-empty request id")

	# Upkeep is one request with no target unit.
	var upkeep: Button = panel.find_child("Upkeep", true, false) as Button
	before = events.size()
	upkeep.pressed.emit()
	await process_frame
	_expect(events.size() == before + 1 and events.back().action == "upkeep",
		"Upkeep emits an upkeep intent")
	_expect(not str(events.back().args.get("command_id", "")).is_empty(),
		"Upkeep carries a non-empty request id")

	# A successful authority reply replaces the whole roster.
	panel.apply_result("unit-state", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": false,
		"state": {"units": [_unit("unit-c", ALICE, "militia", 20, "none", "camp-c", 0)]},
	})
	_expect(panel.units.size() == 1, "The reply's state replaces the roster")
	_expect(_row_label(0) != null and _row_label(0).name == "Unit_unit-c",
		"The replacement roster is rendered")
	_expect(panel.find_child("Unit_unit-a", true, false) == null,
		"A unit missing from the reply is not kept locally")
	_expect(panel.find_child("Unit_unit-b", true, false) == null,
		"A disbanded unit is not kept locally either")
	_expect(panel._status.text.is_empty(), "A successful reply clears the status line")

	# A refused reply shows the authority's own reason and never edits the roster.
	var refusal: Dictionary = {
		"ok": false, "reason": "insufficient_cash",
		"reason_text": "现金不足，暂时不能招募。", "duplicate": false,
		"state": {"units": [_unit("unit-c", ALICE, "militia", 20, "none", "camp-c", 0)]},
	}
	panel.apply_result("unit-recruit", refusal)
	_expect(panel._status.text.contains("现金不足"),
		"A refused reply shows the authority's reason text")
	_expect(panel.units.size() == 1 and panel.find_child("Unit_unit-c", true, false) != null,
		"A refused reply leaves the roster exactly as the authority sent it")
	_expect(panel.find_child("Disband_unit-a", true, false) == null,
		"A refused reply never invents a local unit")

	# Malformed or empty payloads and writes do not crash the panel.
	panel.apply_result("", {})
	panel.apply_result("unit-state", {"ok": true, "state": {"units": []}})
	_expect(panel.units.is_empty() and _has_text(unit_list, "还没有单位。"),
		"An empty state empties the rendered roster")
	panel.open_panel({})
	_expect(panel.is_open() and _has_text(unit_list, "还没有单位。"),
		"A malformed view falls back to the empty state without crashing")
	panel.show_status("")
	_expect(panel._status.text.is_empty(), "Writing an empty status clears it")

	# Esc closes only the open panel and returns focus to the HUD button.
	panel.open_panel(_units())
	var close_button: Button = panel.find_child("Close", true, false) as Button
	close_button.grab_focus()
	await process_frame
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(not panel.is_open(), "Esc closes the unit panel")
	_expect(closes == 1, "Closing the panel emits exactly one close signal")
	_expect(root.gui_get_focus_owner() == opener,
		"Closing returns keyboard focus to the HUD button that opened the panel")
	esc.pressed = false
	root.push_input(esc)
	root.push_input(esc)
	await process_frame
	_expect(closes == 1, "Esc after closing is ignored")
	_finish()


func _units() -> Dictionary:
	return {
		"units": [
			_unit("unit-b", BOB, "guard", 80, "elite", "camp-b", 2),
			_unit("unit-a", ALICE, "militia", 100, "standard", "camp-a", 0),
		],
	}


func _unit(unit_id: String, owner: String, kind: String, people: int,
		equipment: String, station: String, unfed_days: int) -> Dictionary:
	return {
		"id": unit_id, "owner": owner, "kind": kind, "people": people,
		"equipment": equipment, "station": station, "unfed_days": unfed_days,
	}


func _row_label(index: int) -> Label:
	var list: VBoxContainer = panel.find_child("UnitList", true, false) as VBoxContainer
	if list == null or index < 0 or index >= list.get_child_count():
		return null
	var line: Node = list.get_child(index)
	for child: Node in line.get_children():
		if child is Label:
			return child as Label
	return null


func _select_meta(option: OptionButton, value: String) -> void:
	for index: int in option.item_count:
		if str(option.get_item_metadata(index)) == value:
			option.select(index)
			return


func _has_text(node: Node, fragment: String) -> bool:
	for child: Node in node.get_children():
		if child is Label and (child as Label).text.contains(fragment):
			return true
		if _has_text(child, fragment):
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("UNIT_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
