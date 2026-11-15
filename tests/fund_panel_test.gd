extends SceneTree
## 公共基金面板作为视图：它只根据权威基金视图决定显示什么，并把点击变成基金
## 操作意图；能否开立、缴入、支出或换届，以及余额是否足够，都由权威决定。
##
## 没有网络：视图直接构造，面板不在这里发起任何请求。

const FundPanel = preload("res://ui/fund_panel.gd")

const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"
const ORG_A: String = "player_0000000000000000000000000000000a"
const ORG_B: String = "player_0000000000000000000000000000000b"

var panel: FundPanel
var events: Array = []
var refreshes: int = 0
var closes: int = 0
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = FundPanel.new()
	panel.name = "FundPanel"
	root.add_child(panel)
	panel.fund_action.connect(func(action: String, args: Dictionary) -> void:
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

	# Empty authority view: the list says so instead of inventing a fund.
	panel.open_panel({"funds": []})
	var fund_list: VBoxContainer = panel.find_child("FundList", true, false) as VBoxContainer
	_expect(panel.is_open(), "Opening the panel shows it")
	_expect(fund_list != null and _has_text(fund_list, "还没有公共基金。"),
		"An empty authority view says there are no public funds")

	# Multi-row view: rows are sorted by fund id and every authoritative field is shown.
	panel.open_panel(_funds())
	_expect(panel.funds.size() == 2, "Both authoritative funds are kept in the view")
	var first: Label = _row_label(0)
	var second: Label = _row_label(1)
	_expect(first != null and first.name == "Fund_fund_org-a",
		"Rows are sorted by fund id (got %s)" % (first.name if first != null else "null"))
	_expect(second != null and second.name == "Fund_fund_org-b",
		"A second row follows the sort order")
	var text: String = second.text if second != null else ""
	_expect(text.contains("fund_org-b"), "A row names the fund id (got %s)" % text)
	_expect(text.contains(ORG_B), "A row shows the authoritative org id")
	_expect(text.contains(BOB), "A row shows the authoritative keeper")
	_expect(text.contains("余额 30"), "A row shows the authoritative balance")
	_expect(text.contains("支出 20"), "A row shows the authoritative spent total")
	_expect(text.contains("缴入累计 50"), "A row sums contributor totals")
	_expect(text.contains("%s 20" % ALICE) and text.contains("%s 30" % BOB),
		"A row lists each contributor's running total")
	var focus_owner: Control = root.gui_get_focus_owner()
	_expect(focus_owner != null and panel.is_ancestor_of(focus_owner),
		"Opening the fund panel captures keyboard focus inside it")
	var scroll: ScrollContainer = panel.find_child("Scroll", true, false) as ScrollContainer
	_expect(scroll != null and scroll.follow_focus,
		"The fund list scrolls to follow keyboard focus")
	var refresh: Button = panel.find_child("Refresh", true, false) as Button
	refresh.pressed.emit()
	await process_frame
	_expect(refreshes == 1, "Refreshing asks the caller for a new authoritative view")

	# Opening a fund carries the typed org id and a non-empty request id.
	panel._open_org.text = "  " + ORG_A + "  "
	var open_button: Button = panel.find_child("OpenFund", true, false) as Button
	var before: int = events.size()
	open_button.pressed.emit()
	await process_frame
	_expect(events.size() == before + 1 and events.back().action == "open",
		"Opening emits an open intent")
	var args: Dictionary = events.back().args
	_expect(not str(args.get("command_id", "")).is_empty(),
		"An open request carries a non-empty request id")
	_expect(args.get("org_id") == ORG_A,
		"The open request carries the trimmed org id (got %s)" % str(args.get("org_id")))
	var first_id: String = str(args.get("command_id", ""))
	panel._open_org.text = ""
	before = events.size()
	open_button.pressed.emit()
	await process_frame
	_expect(events.size() == before and panel._status.text.contains("组织 id"),
		"An empty org id never becomes a request")

	# Contributing accepts a fund id or an org id, plus a positive integer amount.
	panel._contribute_target.text = "fund_org-a"
	panel._contribute_amount.text = "25"
	var contribute: Button = panel.find_child("Contribute", true, false) as Button
	before = events.size()
	contribute.pressed.emit()
	await process_frame
	_expect(events.size() == before + 1 and events.back().action == "contribute",
		"Contributing emits a contribute intent")
	args = events.back().args
	_expect(args.get("fund_id") == "fund_org-a",
		"A fund id target is sent as fund_id")
	_expect(not args.has("org_id"), "A fund id target does not also send org_id")
	_expect(int(args.get("amount", 0)) == 25, "The contribution carries the entered amount")
	_expect(not str(args.get("command_id", "")).is_empty(),
		"A contribution carries a non-empty request id")
	var contribute_id: String = str(args.get("command_id", ""))
	panel._contribute_target.text = ORG_A
	before = events.size()
	contribute.pressed.emit()
	await process_frame
	_expect(events.size() == before + 1 and events.back().args.get("org_id") == ORG_A,
		"An org id target is sent as org_id")
	_expect(str(events.back().args.get("command_id", "")) != contribute_id,
		"Each contribution click gets its own request id")

	# A bad amount never becomes a request; the panel does not check the balance.
	for bad_amount: String in ["0", "-3", "abc", ""]:
		panel._contribute_amount.text = bad_amount
		before = events.size()
		contribute.pressed.emit()
		await process_frame
		_expect(events.size() == before and panel._status.text.contains("正整数"),
			"An amount %s is refused before it becomes a request" % ("(empty)" if bad_amount.is_empty() else bad_amount))
	panel._contribute_amount.text = "10"
	panel._contribute_target.text = ""
	before = events.size()
	contribute.pressed.emit()
	await process_frame
	_expect(events.size() == before and panel._status.text.contains("基金 id 或组织 id"),
		"An empty contribution target never becomes a request")

	# Spending carries the fund, project and amount.
	panel._spend_target.text = "fund_org-a"
	panel._spend_project.text = "  project-a  "
	panel._spend_amount.text = "40"
	var spend: Button = panel.find_child("Spend", true, false) as Button
	before = events.size()
	spend.pressed.emit()
	await process_frame
	_expect(events.size() == before + 1 and events.back().action == "spend",
		"Spending emits a spend intent")
	args = events.back().args
	_expect(args.get("fund_id") == "fund_org-a", "The spend names the fund")
	_expect(args.get("project_id") == "project-a",
		"The spend carries the trimmed project id")
	_expect(int(args.get("amount", 0)) == 40, "The spend carries the entered amount")
	_expect(not str(args.get("command_id", "")).is_empty(),
		"A spend carries a non-empty request id")
	panel._spend_amount.text = "-1"
	before = events.size()
	spend.pressed.emit()
	await process_frame
	_expect(events.size() == before and panel._status.text.contains("正整数"),
		"A negative spend amount is refused before it becomes a request")
	panel._spend_amount.text = "10"
	panel._spend_project.text = ""
	before = events.size()
	spend.pressed.emit()
	await process_frame
	_expect(events.size() == before and panel._status.text.contains("项目 id"),
		"An empty project never becomes a spend")

	# Rotating the keeper asks for confirmation: clicking alone, or cancelling,
	# sends nothing.
	panel._rotate_target.text = "fund_org-a"
	panel._rotate_keeper.text = BOB
	var rotate: Button = panel.find_child("Rotate", true, false) as Button
	before = events.size()
	rotate.pressed.emit()
	await process_frame
	_expect(events.size() == before and panel._confirm.visible,
		"Rotating only opens a confirmation")
	_expect(panel.is_popup_open(), "An open confirmation owns the next Esc")
	panel._confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(events.size() == before,
		"Cancelling the confirmation sends no rotate request")
	_expect(not panel.is_popup_open(), "Cancelling releases the Esc ownership")
	rotate.pressed.emit()
	await process_frame
	panel._confirm.get_ok_button().pressed.emit()
	await process_frame
	_expect(events.size() == before + 1 and events.back().action == "rotate",
		"Confirming emits a rotate request")
	args = events.back().args
	_expect(args.get("fund_id") == "fund_org-a", "The rotate names the fund")
	_expect(args.get("new_keeper") == BOB, "The rotate names the new keeper")
	_expect(not str(args.get("command_id", "")).is_empty(),
		"A rotate carries a non-empty request id")
	panel._rotate_keeper.text = ""
	before = events.size()
	rotate.pressed.emit()
	await process_frame
	_expect(events.size() == before and not panel._confirm.visible,
		"An empty new keeper never opens a rotate confirmation")

	# A successful authority reply replaces the whole view.
	panel.apply_result("fund-state", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": false,
		"state": {"funds": [_fund("fund_org-c", ORG_A + "c", ALICE, 200, 50,
			{ALICE: 200, BOB: 50})]},
	})
	_expect(panel.funds.size() == 1, "The reply's state replaces the fund list")
	_expect(_row_label(0) != null and _row_label(0).name == "Fund_fund_org-c",
		"The replacement fund is rendered")
	_expect(panel.find_child("Fund_fund_org-a", true, false) == null,
		"A fund missing from the reply is not kept locally")
	_expect(panel._status.text.is_empty(), "A successful reply clears the status line")

	# A refused reply shows the authority's own reason and never edits the view.
	var refusal: Dictionary = {
		"ok": false, "reason": "insufficient_funds",
		"reason_text": "基金余额不足，暂时不能支出。", "duplicate": false,
		"state": {"funds": [_fund("fund_org-c", ORG_A + "c", ALICE, 200, 50,
			{ALICE: 200, BOB: 50})]},
	}
	panel.apply_result("fund-spend", refusal)
	_expect(panel._status.text.contains("余额不足"),
		"A refused reply shows the authority's reason text")
	_expect(panel.funds.size() == 1 and _row_label(0).text.contains("余额 200"),
		"A refused reply leaves the balance exactly as the authority sent it")
	_expect(panel._status.text.contains("余额不足") and not panel._status.text.contains("150"),
		"The panel never subtracts the refused amount locally")

	# Malformed or empty payloads and writes do not crash the panel.
	panel.apply_result("", {})
	panel.apply_result("fund-state", {"ok": true, "state": {"funds": []}})
	_expect(panel.funds.is_empty() and _has_text(fund_list, "还没有公共基金。"),
		"An empty state empties the rendered fund list")
	panel.open_panel({})
	_expect(panel.is_open() and _has_text(fund_list, "还没有公共基金。"),
		"A malformed view falls back to the empty state without crashing")
	panel.open_panel({"funds": ["bad", {}, {"fund_id": "fund_org-x"}]})
	_expect(panel.funds.size() == 2 and _row_label(0) != null,
		"Malformed rows are skipped and a bare row still renders without crashing")
	panel.show_status("")
	_expect(panel._status.text.is_empty(), "Writing an empty status clears it")

	# Esc closes only the open panel and returns focus to the HUD button.
	panel.open_panel(_funds())
	var close_button: Button = panel.find_child("Close", true, false) as Button
	close_button.grab_focus()
	await process_frame
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(not panel.is_open(), "Esc closes the fund panel")
	_expect(closes == 1, "Closing the panel emits exactly one close signal")
	_expect(root.gui_get_focus_owner() == opener,
		"Closing returns keyboard focus to the HUD button that opened the panel")
	esc.pressed = false
	root.push_input(esc)
	root.push_input(esc)
	await process_frame
	_expect(closes == 1, "Esc after closing is ignored")
	_finish()


func _funds() -> Dictionary:
	return {
		"funds": [
			_fund("fund_org-b", ORG_B, BOB, 30, 20, {ALICE: 20, BOB: 30}),
			_fund("fund_org-a", ORG_A, ALICE, 120, 10, {ALICE: 130}),
		],
	}


func _fund(fund_id: String, org_id: String, keeper: String, balance: int,
		spent: int, contributors: Dictionary) -> Dictionary:
	return {
		"fund_id": fund_id, "org_id": org_id, "keeper": keeper,
		"balance": balance, "spent": spent, "contributors": contributors,
	}


func _row_label(index: int) -> Label:
	var list: VBoxContainer = panel.find_child("FundList", true, false) as VBoxContainer
	if list == null or index < 0 or index >= list.get_child_count():
		return null
	var child: Node = list.get_child(index)
	return child as Label


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
	print("FUND_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
