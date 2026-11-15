extends SceneTree
## 交战面板作为视图：它只根据权威交战视图决定显示什么，并把点击变成一次交战
## 请求；参与同意、单位归属、损失上限与资产都由权威裁决。
##
## 没有网络：视图直接构造，面板在测试里通过一个假远程对象转发请求与答复。

const ConflictPanel = preload("res://ui/conflict_panel.gd")

const PLAYER_DEFENDER: String = "player_defender"
const KEY_A: String = "defender_a|parcel_a"
const KEY_B: String = "defender_b|parcel_b"
const COMMAND_A: String = "conflict-engage-100"
const COMMAND_B: String = "conflict-engage-200"


class FakeRemote extends RefCounted:
	signal conflict_result(request_id: String, payload: Dictionary)

	var calls: Array = []

	func request_conflict(request_id: String, action: String,
			args: Dictionary = {}) -> bool:
		calls.append({
			"request_id": request_id, "action": action,
			"args": args.duplicate(true),
		})
		return true


var panel: ConflictPanel
var fake: FakeRemote
var closes: int = 0
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = ConflictPanel.new()
	panel.name = "ConflictPanel"
	root.add_child(panel)
	fake = FakeRemote.new()
	fake.conflict_result.connect(panel.apply_result)
	panel.conflict_action.connect(_forward_action)
	panel.refresh_requested.connect(_request_refresh)
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

	# Empty authority view: the lists say so instead of inventing targets or
	# battle reports, and the header admits the regime was never supplied.
	panel.open_panel({})
	_expect(panel.is_open(), "Opening the panel shows it")
	_expect(_has_text(_list("TargetList"), "还没有交战目标。"),
		"An empty conflict view says there are no targets")
	_expect(_has_text(_list("RecentList"), "还没有交战结果。"),
		"An empty conflict view says there are no recent results")
	_expect(_label_text("Regime") == "当前制度未载入。",
		"Without a participation view the regime is not invented")
	_expect(_label_text("Host") == "房主 未登记", "Without a participation view the host is unknown")

	# The regime and host come from the authoritative participation view that the
	# caller passes in; the conflict view itself carries neither.
	panel.set_participation(_participation("limited", "player_host", 3, 40, 10))
	_expect(_label_text("Regime").contains("有限冲突") and _label_text("Regime").contains("在线上限 40"),
		"A limited regime shows its authoritative caps")
	_expect(_label_text("Host") == "房主 player_host", "The host is shown from the participation view")
	panel.set_participation(_participation("peace", "", 0, 0, 0))
	_expect(_label_text("Regime").contains("和平"),
		"A peace regime says conflict is closed")
	_expect(_label_text("Host") == "房主 未登记", "An empty host is shown as 未登记")
	panel.set_participation(_participation("limited", "player_host", 3, 40, 10))

	# Multi-row view: targets and recent results are sorted by their authoritative
	# keys, and every displayed value comes from the reply.
	panel.open_panel(_conflict_view())
	_expect(panel.targets.size() == 2, "All authoritative targets are kept in the view")
	var first_target: Label = _row_label("TargetList", 0)
	var second_target: Label = _row_label("TargetList", 1)
	_expect(first_target != null and first_target.name == "Target_" + KEY_A,
		"Targets are sorted by key (got %s)" % (first_target.name if first_target != null else "null"))
	_expect(second_target != null and second_target.name == "Target_" + KEY_B,
		"The second target follows the key order")
	var first_text: String = first_target.text if first_target != null else ""
	var second_text: String = second_target.text if second_target != null else ""
	_expect(first_text.contains("player_defender_a") and first_text.contains("parcel_a"),
		"A target row shows its defender and parcel")
	_expect(first_text.contains("累计损失 14/100"),
		"A target row shows the authoritative losses against its cap")
	_expect(second_text.contains("未绑定"), "An unbound target parcel is shown as 未绑定")
	_expect(second_text.contains("累计损失 3/100"),
		"Each target keeps its own authoritative losses")
	_expect(panel.recent.size() == 2, "All authoritative recent results are kept")
	var first_recent: Label = _row_label("RecentList", 0)
	_expect(first_recent != null and first_recent.name == "Recent_" + COMMAND_A,
		"Recent results are sorted by command id")
	var recent_text: String = first_recent.text if first_recent != null else ""
	_expect(recent_text.contains("attacker_a") and recent_text.contains("player_defender"),
		"A recent result shows the attacker and defender the authority sent")
	_expect(recent_text.contains("损失 14") and recent_text.contains("缴获现金 2"),
		"A recent result shows the sent loss and spoils figures")
	_expect(recent_text.contains("防守方在线"), "A recent result shows the authority's online flag")
	var focus_owner: Control = root.gui_get_focus_owner()
	_expect(focus_owner != null and panel.is_ancestor_of(focus_owner),
		"Opening the conflict panel captures keyboard focus inside it")
	var scroll: ScrollContainer = panel.find_child("Scroll", true, false) as ScrollContainer
	_expect(scroll != null and scroll.follow_focus,
		"The conflict view scrolls to follow keyboard focus")

	# The refresh button asks the caller for a fresh authoritative view.
	var refresh: Button = panel.find_child("Refresh", true, false) as Button
	var before: int = fake.calls.size()
	refresh.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "state"
		and fake.calls.back().request_id == "conflict-state",
		"Refreshing asks the caller for the authoritative state")

	# Engaging only opens a confirmation; cancelling sends nothing.
	var defender: LineEdit = panel.find_child("Defender", true, false) as LineEdit
	var attacker: LineEdit = panel.find_child("AttackerUnits", true, false) as LineEdit
	var protecting: LineEdit = panel.find_child("DefenderUnits", true, false) as LineEdit
	var x: LineEdit = panel.find_child("X", true, false) as LineEdit
	var z: LineEdit = panel.find_child("Z", true, false) as LineEdit
	var parcel: LineEdit = panel.find_child("TargetParcel", true, false) as LineEdit
	var engage: Button = panel.find_child("Engage", true, false) as Button
	var confirm: ConfirmationDialog = panel.find_child("EngageConfirm", true, false) as ConfirmationDialog
	_fill_engage(defender, attacker, protecting, x, z, parcel)
	before = fake.calls.size()
	engage.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before,
		"Clicking engage alone never becomes a request")
	_expect(confirm.visible and panel.is_popup_open(),
		"Engaging opens a confirmation that owns the next Esc")
	confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before,
		"Cancelling the engage confirmation sends no request")
	_expect(not panel.is_popup_open(), "Cancelling releases Esc ownership")

	# Confirming forwards the entered arguments verbatim. The panel does not
	# decide consent, unit ownership, loss caps or assets.
	engage.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "engage",
		"Confirming emits one engage intent")
	var args: Dictionary = fake.calls.back().args
	_expect(args.get("defender") == PLAYER_DEFENDER,
		"The engage request carries the trimmed defender id")
	_expect(str(args.get("attacker_units")) == '["unit-b", "unit-a"]',
		"The attacker unit list is forwarded in the entered order")
	_expect(str(args.get("defender_units")) == '["unit-d", "unit-c"]',
		"The defender unit list is forwarded in the entered order")
	_expect(int(args.get("x", 0)) == 12 and int(args.get("z", 0)) == -4,
		"The engage request carries integer coordinates")
	_expect(args.get("target_parcel") == "parcel_a",
		"The optional target parcel is forwarded when filled")
	_expect(not str(args.get("command_id", "")).is_empty(),
		"An engage request carries a non-empty request id")
	_expect(fake.calls.back().request_id == args.get("command_id"),
		"The request id doubles as the command id")
	_expect(not args.has("outcome") and not args.has("actor"),
		"The panel decides no outcome and sends no actor")

	# An empty target parcel is omitted instead of sending an invented one.
	parcel.text = "   "
	before = fake.calls.size()
	engage.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and not fake.calls.back().args.has("target_parcel"),
		"An empty target parcel is omitted from the request")

	# Blank fields and non-integer coordinates are refused before a request.
	parcel.text = "parcel_a"
	for bad: Dictionary in [
		{"field": "defender", "value": "", "message": "防守者"},
		{"field": "attacker", "value": "   ", "message": "进攻单位 id"},
		{"field": "attacker", "value": "unit-a,,unit-b", "message": "逗号分隔"},
		{"field": "defender_units", "value": "", "message": "防守单位 id"},
		{"field": "x", "value": "abc", "message": "整数"},
		{"field": "x", "value": "", "message": "整数"},
		{"field": "z", "value": "1.5", "message": "整数"},
	]:
		_fill_engage(defender, attacker, protecting, x, z, parcel)
		match str(bad.field):
			"defender": defender.text = str(bad.value)
			"attacker": attacker.text = str(bad.value)
			"defender_units": protecting.text = str(bad.value)
			"x": x.text = str(bad.value)
			"z": z.text = str(bad.value)
		before = fake.calls.size()
		engage.pressed.emit()
		await process_frame
		_expect(fake.calls.size() == before and not confirm.visible,
			"An invalid %s value never opens a confirmation" % str(bad.field))
		_expect(_status().contains(str(bad.message)),
			"An invalid %s value explains what to fill" % str(bad.field))
		_fill_engage(defender, attacker, protecting, x, z, parcel)

	# A successful state reply replaces the whole view, removing old rows.
	fake.conflict_result.emit("conflict-state", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": false,
		"action": "state", "state": {"sequence": 4, "targets": [_target(
			KEY_B, "player_defender_b", "", 3, 100)], "recent": []},
	})
	await process_frame
	_expect(panel.targets.size() == 1, "The reply's state replaces the target list")
	_expect(panel.find_child("Target_" + KEY_A, true, false) == null,
		"A target missing from the reply is not kept locally")
	_expect(panel.find_child("Target_" + KEY_B, true, false) != null,
		"The replacement target is rendered")
	_expect(panel.recent.is_empty() and _has_text(_list("RecentList"), "还没有交战结果。"),
		"The reply's empty recent list is rendered as empty")
	_expect(_status().is_empty(), "A successful state reply clears the status line")

	# A refused reply shows the authority's own reason and keeps the view it sent.
	fake.conflict_result.emit("engage-req", {
		"ok": false, "reason": "no_consent", "reason_text": "防守方还没有同意参与。",
		"duplicate": false, "action": "engage",
		"state": {"sequence": 4, "targets": [_target(KEY_B, "player_defender_b", "", 3, 100)],
			"recent": []},
	})
	await process_frame
	_expect(_status().contains("防守方还没有同意参与"),
		"A refused reply shows the authority's reason text")
	_expect(panel.targets.size() == 1 and _row_label("TargetList", 0).text.contains("3/100"),
		"A refused reply leaves the target budget exactly as the authority sent it")

	# Without a reason text the raw reason code is shown instead.
	fake.conflict_result.emit("engage-req", {
		"ok": false, "reason": "target_cap", "reason_text": "", "duplicate": false,
		"action": "engage", "state": {"sequence": 4, "targets": [], "recent": []},
	})
	await process_frame
	_expect(_status().contains("target_cap"),
		"A refused reply without a reason text shows the authority reason code")

	# A successful engage reports the settlement, and a duplicate does not claim
	# a second battle.
	fake.conflict_result.emit("engage-req", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": false,
		"action": "engage", "state": {"sequence": 5, "targets": [], "recent": []},
	})
	await process_frame
	_expect(_status() == "交战已结算。", "A successful engage reports the settlement")
	fake.conflict_result.emit("engage-req", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": true,
		"action": "engage", "state": {"sequence": 5, "targets": [], "recent": []},
	})
	await process_frame
	_expect(_status().contains("已经结算"), "A duplicate reply reports the earlier settlement")

	# Malformed payloads and rows do not crash the panel.
	panel.apply_result("", {})
	_expect(_has_text(_list("TargetList"), "还没有交战目标。"),
		"A payload without a state keeps the rendered list unchanged")
	panel.apply_result("state-req", {"ok": true, "state": {"targets": ["bad", {}], "recent": []}})
	_expect(panel.targets.size() == 1 and _row_label("TargetList", 0) != null,
		"Malformed rows are skipped and a bare row still renders without crashing")
	panel.show_status("")
	_expect(_status().is_empty(), "Writing an empty status clears it")

	# An open confirmation owns the first Esc, then Esc closes the panel and
	# returns focus to the HUD button that opened it.
	panel.open_panel(_conflict_view())
	_fill_engage(defender, attacker, protecting, x, z, parcel)
	engage.pressed.emit()
	await process_frame
	_expect(panel.is_popup_open(), "An open engage confirmation reports that it owns Esc")
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(panel.is_open() and not panel.is_popup_open(),
		"The first Esc only dismisses the engage confirmation")
	esc.pressed = false
	root.push_input(esc)
	var close_button: Button = panel.find_child("Close", true, false) as Button
	close_button.grab_focus()
	await process_frame
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(not panel.is_open(), "Esc closes the conflict panel")
	_expect(closes == 1, "Closing the panel emits exactly one close signal")
	_expect(root.gui_get_focus_owner() == opener,
		"Closing returns keyboard focus to the HUD button that opened the panel")
	esc.pressed = false
	root.push_input(esc)
	root.push_input(esc)
	await process_frame
	_expect(closes == 1, "Esc after closing is ignored")
	_finish()


func _fill_engage(defender: LineEdit, attacker: LineEdit, protecting: LineEdit,
		x: LineEdit, z: LineEdit, parcel: LineEdit) -> void:
	defender.text = "  %s  " % PLAYER_DEFENDER
	attacker.text = " unit-b , unit-a "
	protecting.text = " unit-d,unit-c "
	x.text = " 12 "
	z.text = " -4 "
	parcel.text = " parcel_a "


func _forward_action(action: String, args: Dictionary) -> void:
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = "test-%d" % fake.calls.size()
		payload["command_id"] = request_id
	fake.request_conflict(request_id, action, payload)


func _request_refresh() -> void:
	fake.request_conflict("conflict-state", "state")


func _conflict_view() -> Dictionary:
	return {
		"sequence": 2,
		"targets": [
			_target(KEY_B, "player_defender_b", "", 3, 100),
			_target(KEY_A, "player_defender_a", "parcel_a", 14, 100),
		],
		"recent": [
			_recent(COMMAND_B, "attacker_b"),
			_recent(COMMAND_A, "attacker_a"),
		],
	}


func _participation(tier: String, host: String, revision: int, loss_cap: int,
		offline_cap: int) -> Dictionary:
	return {
		"available": true, "host": host,
		"regime": {
			"tier": tier, "revision": revision, "loss_cap": loss_cap,
			"offline_loss_cap": offline_cap,
		},
	}


func _target(key: String, target: String, parcel_id: String, lost: int,
		cap: int) -> Dictionary:
	return {"key": key, "target": target, "parcel_id": parcel_id, "lost": lost, "cap": cap}


func _recent(command_id: String, attacker: String) -> Dictionary:
	return {
		"command_id": command_id, "attacker": attacker,
		"defender": PLAYER_DEFENDER, "parcel_id": "parcel_a", "troops": 20,
		"losses": 14, "taken_cash": 4, "taken_supplies": 10, "spoils_cash": 2,
		"spoils_supplies": 5, "destroyed": 27, "supply_cost": 20,
		"at_utc": 1760000000.0, "defender_online": true,
		"target_lost_after": 14, "target_cap": 100, "window_id": "window_1",
	}


func _list(node_name: String) -> VBoxContainer:
	return panel.find_child(node_name, true, false) as VBoxContainer


func _row_label(list_name: String, index: int) -> Label:
	var list: VBoxContainer = _list(list_name)
	if list == null or index < 0 or index >= list.get_child_count():
		return null
	return list.get_child(index) as Label


func _label_text(node_name: String) -> String:
	var label: Label = panel.find_child(node_name, true, false) as Label
	return label.text if label != null else ""


func _status() -> String:
	return _label_text("Status")


func _has_text(node: Node, fragment: String) -> bool:
	if node == null:
		return false
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
	print("CONFLICT_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
