extends SceneTree
## 参与制度面板作为视图：它只根据权威参与视图决定显示什么，并把点击变成参与
## 制度操作意图；谁能声明制度、同意参与或退战，以及退战何时生效，都由权威决定。
##
## 没有网络：视图直接构造，面板在测试里通过一个假远程对象转发请求与答复。

const ParticipationPanel = preload("res://ui/participation_panel.gd")

const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"


class FakeRemote extends RefCounted:
	signal participation_result(request_id: String, payload: Dictionary)

	var calls: Array = []

	func request_participation(request_id: String, action: String,
			args: Dictionary = {}) -> bool:
		calls.append({
			"request_id": request_id, "action": action,
			"args": args.duplicate(true),
		})
		return true


var panel: ParticipationPanel
var fake: FakeRemote
var closes: int = 0
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = ParticipationPanel.new()
	panel.name = "ParticipationPanel"
	root.add_child(panel)
	fake = FakeRemote.new()
	fake.participation_result.connect(panel.apply_result)
	panel.participation_action.connect(_forward_action)
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
	await process_frame

	# Without a player identity neither the host form nor the player actions show.
	panel.open_panel({})
	var regime: Label = panel.find_child("Regime", true, false) as Label
	var host_label: Label = panel.find_child("Host", true, false) as Label
	var host_section: VBoxContainer = panel.find_child("HostSection", true, false) as VBoxContainer
	var player_section: VBoxContainer = panel.find_child("PlayerSection", true, false) as VBoxContainer
	_expect(panel.is_open(), "Opening the panel shows it")
	_expect(regime != null and regime.text.contains("和平"),
		"A missing regime is shown as peace")
	_expect(host_label != null and host_label.text.contains("未登记"),
		"A missing host is reported instead of invented")
	_expect(host_section != null and not host_section.visible,
		"The host form is hidden without an identity")
	_expect(player_section != null and not player_section.visible,
		"The player actions are hidden without an identity")

	# Peace regime with the local player as host: declaration controls, no consent.
	panel.set_self_id(ALICE)
	panel.open_panel(_peace_view(ALICE))
	_expect(regime.text.contains("和平"), "A peace regime says it is peace")
	_expect(host_label.text.contains(ALICE) and host_label.text.contains("你"),
		"The host line names the host and marks the local player")
	_expect(host_section.visible, "The host sees the declaration controls")
	_expect(not player_section.visible, "The host does not see the player actions")
	var declare_button: Button = panel.find_child("DeclareRegime", true, false) as Button
	var consent_button: Button = panel.find_child("Consent", true, false) as Button
	_expect(declare_button != null and declare_button.is_visible_in_tree(),
		"The declare action is offered to the host")
	_expect(consent_button != null and not consent_button.is_visible_in_tree(),
		"The consent action is not offered to the host")

	# Limited regime seen by another player: read-only facts plus player actions.
	panel.set_self_id(BOB)
	panel.open_panel(_limited_view(ALICE))
	_expect(regime.text.contains("有限冲突"), "The declared tier is shown in words")
	_expect(regime.text.contains("第 1 版"), "The regime revision is shown")
	_expect(regime.text.contains("在线上限 500") and regime.text.contains("离线上限 100"),
		"Both authoritative loss caps are shown")
	var area_row: Label = panel.find_child("Area_area_a", true, false) as Label
	_expect(area_row != null and area_row.text.contains("area_a")
		and area_row.text.contains("4") and area_row.text.contains("5"),
		"A declared area shows its id and rectangle")
	var window_row: Label = panel.find_child("Window_window_a", true, false) as Label
	_expect(window_row != null and window_row.text.contains("window_a")
		and window_row.text.contains("100") and window_row.text.contains("200"),
		"A declared window shows its id and interval")
	var participant_row: Label = panel.find_child("Participant_" + BOB, true, false) as Label
	_expect(participant_row != null and participant_row.text.contains("进攻方")
		and participant_row.text.contains("同意第 1 版"),
		"A participant row shows the authoritative role and consent revision")
	var loss_row: Label = panel.find_child("Loss_" + BOB + "_window_a", true, false) as Label
	_expect(loss_row != null and loss_row.text.contains("累计 40"),
		"A loss row shows the cumulative authoritative amount")
	_expect(not host_section.visible, "A non-host does not see the declaration controls")
	_expect(player_section.visible, "A non-host sees the player actions")
	var withdraw_button: Button = panel.find_child("Withdraw", true, false) as Button
	_expect(consent_button.is_visible_in_tree() and withdraw_button.is_visible_in_tree(),
		"Consent and withdrawal are offered to a non-host player")

	# The refresh button asks the caller for a fresh authoritative view.
	var refresh: Button = panel.find_child("Refresh", true, false) as Button
	var before: int = fake.calls.size()
	refresh.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "state"
		and fake.calls.back().request_id == "participation-state",
		"Refreshing asks the caller for the authoritative state")

	# The host declares peace: no scope and no budget.
	panel.set_self_id(ALICE)
	panel.open_panel(_peace_view(ALICE))
	var tier: OptionButton = panel.find_child("Tier", true, false) as OptionButton
	var declaration_id: LineEdit = panel.find_child("DeclarationId", true, false) as LineEdit
	var effective: LineEdit = panel.find_child("EffectiveUtc", true, false) as LineEdit
	tier.select(0)
	declaration_id.text = "decl-peace"
	effective.text = "1000"
	before = fake.calls.size()
	declare_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "regime",
		"Declaring a regime emits a regime intent")
	var args: Dictionary = fake.calls.back().args
	_expect(not str(args.get("command_id", "")).is_empty(),
		"A regime request carries a non-empty command id")
	var declaration: Dictionary = args.get("declaration", {})
	_expect(str(declaration.get("tier", "")) == "peace", "The peace tier is sent as peace")
	_expect(not bool(declaration.get("higher_risk", true)),
		"A peace declaration is not a higher-risk declaration")
	_expect((declaration.get("areas", []) as Array).is_empty()
		and (declaration.get("windows", []) as Array).is_empty(),
		"A peace declaration carries no scope")
	_expect(int(declaration.get("loss_cap", -1)) == 0
		and int(declaration.get("offline_loss_cap", -1)) == 0,
		"A peace declaration carries no loss budget")
	_expect(float(declaration.get("effective_utc", -1.0)) == 1000.0,
		"The declaration carries the entered effective time")

	# An empty effective time uses the authority clock from the view, not the
	# local system clock: a client's clock may differ from the authority's.
	effective.text = ""
	before = fake.calls.size()
	declare_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1,
		"An empty effective time still forms a request")
	_expect(float((fake.calls.back().args.get("declaration", {}) as Dictionary)
		.get("effective_utc", -1.0)) == 4321.0,
		"An empty effective time uses the authority clock from the view")
	effective.text = "1000"

	# An empty declaration id never becomes a request.
	declaration_id.text = ""
	before = fake.calls.size()
	declare_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("声明 id"),
		"An empty declaration id never becomes a request")

	# The host declares limited conflict with an explicit area, window and caps.
	declaration_id.text = "decl-limited"
	effective.text = "2000"
	tier.select(1)
	var area_input: LineEdit = panel.find_child("AreaInput", true, false) as LineEdit
	var window_input: LineEdit = panel.find_child("WindowInput", true, false) as LineEdit
	var loss_cap: LineEdit = panel.find_child("LossCap", true, false) as LineEdit
	var offline_cap: LineEdit = panel.find_child("OfflineLossCap", true, false) as LineEdit
	area_input.text = "area_a,0,0,4,4;area_b,10,10,14,14"
	window_input.text = "window_a,100,200"
	loss_cap.text = "500"
	offline_cap.text = "100"
	before = fake.calls.size()
	declare_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "regime",
		"The limited declaration emits a regime intent")
	declaration = fake.calls.back().args.get("declaration", {})
	_expect(str(declaration.get("tier", "")) == "limited", "The limited tier is sent")
	_expect(bool(declaration.get("higher_risk", false)),
		"A limited declaration is marked higher risk")
	var areas: Array = declaration.get("areas", [])
	_expect(areas.size() == 2 and str((areas[0] as Dictionary).get("id", "")) == "area_a"
		and int((areas[1] as Dictionary).get("max_z", -1)) == 14,
		"The declaration carries every parsed area")
	var windows: Array = declaration.get("windows", [])
	_expect(windows.size() == 1
		and float((windows[0] as Dictionary).get("start_utc", -1.0)) == 100.0
		and float((windows[0] as Dictionary).get("end_utc", -1.0)) == 200.0,
		"The declaration carries the parsed window interval")
	_expect(int(declaration.get("loss_cap", 0)) == 500
		and int(declaration.get("offline_loss_cap", 0)) == 100,
		"The declaration carries both entered caps")

	# Malformed scope and caps are refused before they become requests.
	area_input.text = "area_a,0,0"
	before = fake.calls.size()
	declare_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("区域"),
		"A malformed area never becomes a request")
	area_input.text = "area_a,0,0,4,4"
	offline_cap.text = "600"
	before = fake.calls.size()
	declare_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("离线上限"),
		"An offline cap above the online cap never becomes a request")
	offline_cap.text = "100"
	effective.text = "abc"
	before = fake.calls.size()
	declare_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("生效时间"),
		"An invalid effective time never becomes a request")

	# A player consents with the selected role.
	panel.set_self_id(BOB)
	panel.open_panel(_limited_view(ALICE))
	var role: OptionButton = panel.find_child("Role", true, false) as OptionButton
	role.select(0)
	before = fake.calls.size()
	consent_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "declare",
		"Consent emits a declare intent")
	_expect(str(fake.calls.back().args.get("role", "")) == "attacker",
		"The attacker role is sent verbatim")
	_expect(not str(fake.calls.back().args.get("command_id", "")).is_empty(),
		"A consent carries a non-empty command id")
	role.select(1)
	before = fake.calls.size()
	consent_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1
		and str(fake.calls.back().args.get("role", "")) == "defender",
		"The defender role is sent verbatim")

	# Withdrawal asks for confirmation first.
	before = fake.calls.size()
	withdraw_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and panel.is_popup_open(),
		"Withdrawal only opens a confirmation")
	var confirm: ConfirmationDialog = panel.find_child("WithdrawConfirm", true, false) as ConfirmationDialog
	confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and not panel.is_popup_open(),
		"Cancelling the confirmation sends no withdraw request")
	withdraw_button.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "withdraw",
		"Confirming emits a withdraw request")
	_expect(not str(fake.calls.back().args.get("command_id", "")).is_empty(),
		"A withdrawal carries a non-empty command id")
	_expect(not fake.calls.back().args.has("role"),
		"A withdrawal does not carry a role")

	# A successful withdrawal reply replaces the view and shows the delay notice.
	var pending_view: Dictionary = _limited_view(ALICE)
	var participant: Dictionary = (pending_view.participants as Array)[0]
	participant.withdraw_utc = 1500.0
	participant.withdraw_effective_utc = 5100.0
	fake.participation_result.emit("withdraw-req", {
		"ok": true, "action": "withdraw", "duplicate": false, "reason": "",
		"reason_text": "", "state": pending_view,
	})
	await process_frame
	_expect(_status().contains("延迟"),
		"A successful withdrawal tells the player it takes effect after a delay")
	participant_row = panel.find_child("Participant_" + BOB, true, false) as Label
	_expect(participant_row != null and participant_row.text.contains("退战登记")
		and participant_row.text.contains("5100"),
		"The participant row shows the authoritative withdrawal delay")

	# A refused action shows the authority's reason without changing the view.
	var refused_view: Dictionary = _limited_view(ALICE)
	fake.participation_result.emit("regime-req", {
		"ok": false, "action": "regime", "duplicate": false, "reason": "not_host",
		"reason_text": "", "state": refused_view,
	})
	await process_frame
	_expect(_status().contains("not_host"),
		"A refused reply without a reason text shows the authority reason code")
	fake.participation_result.emit("regime-req", {
		"ok": false, "action": "regime", "duplicate": false, "reason": "not_host",
		"reason_text": "只有房主可以声明参战规则。", "state": refused_view,
	})
	await process_frame
	_expect(_status().contains("只有房主"),
		"A refused reply shows the authority's reason text")
	_expect(regime.text.contains("有限冲突"),
		"A refused reply leaves the authoritative regime on screen")

	# A successful state reply replaces the whole view, including removed rows.
	var replacement: Dictionary = _limited_view(ALICE)
	replacement.areas = [{"id": "area_z", "min_x": 7, "min_z": 7, "max_x": 9, "max_z": 9}]
	replacement.regime.revision = 2
	replacement.regime.declaration_id = "decl-2"
	fake.participation_result.emit("state-req", {
		"ok": true, "action": "state", "duplicate": false, "reason": "",
		"reason_text": "", "state": replacement,
	})
	await process_frame
	_expect(regime.text.contains("第 2 版") and regime.text.contains("decl-2"),
		"A successful reply replaces the regime")
	_expect(panel.find_child("Area_area_z", true, false) != null,
		"The replacement area is rendered")
	_expect(panel.find_child("Area_area_a", true, false) == null,
		"An area missing from the reply is not kept locally")
	_expect(_status().is_empty(), "A successful reply clears the status line")

	# A duplicate reply is reported instead of silently ignored.
	fake.participation_result.emit("declare-req", {
		"ok": true, "action": "declare", "duplicate": true, "reason": "",
		"reason_text": "", "state": replacement,
	})
	await process_frame
	_expect(_status().contains("已经执行过"), "A duplicate reply is reported")

	# Malformed payloads do not crash the panel.
	panel.apply_result("", {})
	panel.open_panel({})
	_expect(regime.text.contains("和平"), "A malformed view falls back to peace")
	panel.show_status("")
	_expect(_status().is_empty(), "Writing an empty status clears it")

	# Esc closes only the open panel and returns focus to the HUD button.
	panel.open_panel(_peace_view(ALICE))
	var close_button: Button = panel.find_child("Close", true, false) as Button
	close_button.grab_focus()
	await process_frame
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(not panel.is_open(), "Esc closes the participation panel")
	_expect(closes == 1, "Closing the panel emits exactly one close signal")
	_expect(root.gui_get_focus_owner() == opener,
		"Closing returns keyboard focus to the HUD button that opened the panel")
	esc.pressed = false
	root.push_input(esc)
	root.push_input(esc)
	await process_frame
	_expect(closes == 1, "Esc after closing is ignored")
	_finish()


func _forward_action(action: String, args: Dictionary) -> void:
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = "test-%d" % fake.calls.size()
		payload["command_id"] = request_id
	fake.request_participation(request_id, action, payload)


func _request_refresh() -> void:
	fake.request_participation("participation-state", "state")


func _peace_view(host: String) -> Dictionary:
	return {
		"available": true, "host": host, "sequence": 0, "now_utc": 4321.0,
		"regime": {
			"tier": "peace", "revision": 0, "declaration_id": "", "declared_by": "",
			"declared_utc": 0.0, "effective_utc": 0.0, "higher_risk": false,
			"area_ids": [], "window_ids": [], "loss_cap": 0, "offline_loss_cap": 0,
		},
		"areas": [], "windows": [], "participants": [], "losses": [],
	}


func _limited_view(host: String) -> Dictionary:
	return {
		"available": true, "host": host, "sequence": 5,
		"regime": {
			"tier": "limited", "revision": 1, "declaration_id": "decl-1",
			"declared_by": host, "declared_utc": 1000.0, "effective_utc": 1000.0,
			"higher_risk": true, "area_ids": ["area_a"], "window_ids": ["window_a"],
			"loss_cap": 500, "offline_loss_cap": 100,
		},
		"areas": [
			{"id": "area_a", "min_x": 0, "min_z": 1, "max_x": 4, "max_z": 5},
		],
		"windows": [
			{"id": "window_a", "start_utc": 100.0, "end_utc": 200.0},
		],
		"participants": [
			{
				"participant": BOB, "attacker": true, "defender": false,
				"consent_revision": 1, "consent_utc": 1000.0,
				"withdraw_utc": 0.0, "withdraw_effective_utc": 0.0,
			},
		],
		"losses": [
			{"target": BOB, "window_id": "window_a", "amount": 40},
		],
	}


func _status() -> String:
	var label: Label = panel.find_child("Status", true, false) as Label
	return label.text if label != null else ""


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("PARTICIPATION_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
