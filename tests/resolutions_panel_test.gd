extends SceneTree
## 决议面板作为视图：它只根据权威决议视图决定显示什么，并把点击变成决议操作
## 意图；成员资格、投票窗口、计票阈值、生效与撤销都由权威决定。
##
## 没有网络：视图直接构造，面板在测试里通过一个假远程对象转发请求与答复。

const ResolutionsPanel = preload("res://ui/resolutions_panel.gd")

const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"
const CAROL: String = "player_00000000000000000000000000000003"


class FakeRemote extends RefCounted:
	signal resolutions_result(request_id: String, payload: Dictionary)

	var calls: Array = []

	func request_resolutions(request_id: String, action: String,
			args: Dictionary = {}) -> bool:
		calls.append({
			"request_id": request_id, "action": action,
			"args": args.duplicate(true),
		})
		return true


var panel: ResolutionsPanel
var fake: FakeRemote
var closes: int = 0
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = ResolutionsPanel.new()
	panel.name = "ResolutionsPanel"
	root.add_child(panel)
	fake = FakeRemote.new()
	fake.resolutions_result.connect(panel.apply_result)
	panel.resolution_action.connect(_forward_action)
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

	# An empty authority view: nothing is invented, and every section says so.
	panel.open_panel({})
	var action_section: VBoxContainer = panel.find_child("ActionSection", true, false) as VBoxContainer
	var proposal_section: VBoxContainer = panel.find_child("ProposalSection", true, false) as VBoxContainer
	var select: OptionButton = panel.find_child("ResolutionSelect", true, false) as OptionButton
	_expect(panel.is_open(), "Opening the panel shows it")
	_expect(_label_text("RulesVersion") == "世界尚未打开",
		"A view without an open world says so instead of inventing a version")
	_expect(_has_text(_list("VersionList"), "还没有规则版本变化。"),
		"An empty view says there are no rule versions")
	_expect(_has_text(_list("ResolutionList"), "世界尚未打开，决议不可用。"),
		"An empty view disables the resolution list")
	_expect(select != null and select.disabled,
		"The resolution picker is disabled while the world is closed")
	_expect(action_section != null and not action_section.visible
		and proposal_section != null and not proposal_section.visible,
		"Write sections are hidden while the world is closed")

	# A member view renders the rule version, the version diff, and every row.
	var writes_before: int = fake.calls.size()
	panel.open_panel(_view(true, BOB, true))
	_expect(_label_text("RulesVersion") == "规则版本 v3",
		"The header shows the authoritative rules version")
	_expect(_label_text("ViewerState") == "成员｜" + BOB,
		"The header marks the viewer as a member")
	_expect(_has_text(_list("VersionList"), "v1 生效 · res_3")
		and _has_text(_list("VersionList"), "v2 生效 · res_4")
		and _has_text(_list("VersionList"), "v3 撤销 · res_4"),
		"Every version row is rendered verbatim and in order")
	_expect(panel.resolutions.size() == 4, "Every authoritative resolution is kept")
	var proposed_text: String = _row_text("res_1")
	_expect(proposed_text.contains("res_1") and proposed_text.contains("公共建设")
		and proposed_text.contains("修桥") and proposed_text.contains(ALICE)
		and proposed_text.contains("提案中（proposed）"),
		"A row shows its id, kind, title, proposer and status")
	_expect(proposed_text.contains("投票 UTC 100–1060")
		and proposed_text.contains("生效 UTC 4660")
		and proposed_text.contains("修订 1") and proposed_text.contains("生效版本 0")
		and proposed_text.contains("撤销版本 0"),
		"A row shows the vote window, effective time, revision and versions")
	_expect(proposed_text.contains("赞成 1") and proposed_text.contains("反对 0"),
		"A member sees the approval and rejection counts")
	_expect(proposed_text.contains("赞成者 " + CAROL) and proposed_text.contains("反对者 无"),
		"A related member sees the voter ids")
	var revoked_text: String = _row_text("res_4")
	_expect(revoked_text.contains("已撤销（revoked）")
		and revoked_text.contains("失效 UTC 3000"),
		"A revoked row shows its authoritative end time")
	_expect(action_section.visible and proposal_section.visible,
		"An open world offers the action and proposal sections")
	var scroll: ScrollContainer = panel.find_child("Scroll", true, false) as ScrollContainer
	_expect(scroll != null and scroll.follow_focus,
		"The resolution view scrolls to follow keyboard focus")
	_expect(fake.calls.size() == writes_before,
		"Rendering the view writes nothing")
	var view_before: Dictionary = panel.view.duplicate(true)
	select.select(1)
	select.item_selected.emit(1)
	await process_frame
	_expect(fake.calls.size() == writes_before and panel.view == view_before,
		"Selecting a row sends no request and does not edit the view")

	# A non-member view loses the counts and the voter identities.
	panel.open_panel(_view(false, "", false))
	_expect(_label_text("ViewerState") == "访客",
		"A non-member view is marked as a visitor")
	proposed_text = _row_text("res_1")
	_expect(not proposed_text.contains("赞成 1") and not proposed_text.contains("反对 0"),
		"A non-member sees no vote counts")
	_expect(not proposed_text.contains("赞成者"),
		"A non-member sees no voter identities")
	_expect(panel.resolutions.size() == 4,
		"Public rows still carry every resolution")
	var approve_button: Button = panel.find_child("Approve", true, false) as Button
	_expect(not approve_button.is_visible_in_tree(),
		"A non-member is not offered the vote buttons")

	# A joined visitor reads the counts (is_member) but cannot write (can_write).
	panel.open_panel(_joined_visitor_view())
	_expect(_label_text("ViewerState") == "访客｜" + BOB,
		"A joined visitor is still labelled a visitor")
	proposed_text = _row_text("res_1")
	_expect(proposed_text.contains("赞成 1"),
		"A joined visitor still sees the authoritative vote counts")
	_expect(not proposed_text.contains("赞成者"),
		"A joined visitor sees no voter identities")
	select.select(0)
	select.item_selected.emit(0)
	_expect(not approve_button.is_visible_in_tree(),
		"A joined visitor is not offered the vote buttons")
	var visitor_close: Button = panel.find_child("CloseVote", true, false) as Button
	_expect(not visitor_close.is_visible_in_tree(),
		"A joined visitor is not offered the close-vote button")
	select.select(1)
	select.item_selected.emit(1)
	var visitor_activate: Button = panel.find_child("Activate", true, false) as Button
	_expect(not visitor_activate.is_visible_in_tree(),
		"A joined visitor is not offered the activation button")

	# Vote visibility follows the view: proposer, status and related voters.
	panel.open_panel(_view(true, BOB, true))
	select.select(0)
	select.item_selected.emit(0)
	_expect(approve_button.is_visible_in_tree(),
		"A member who has not voted sees the vote buttons on a proposal")
	var withdraw_button: Button = panel.find_child("Withdraw", true, false) as Button
	var close_button: Button = panel.find_child("CloseVote", true, false) as Button
	var activate_button: Button = panel.find_child("Activate", true, false) as Button
	var revoke_button: Button = panel.find_child("Revoke", true, false) as Button
	_expect(not withdraw_button.is_visible_in_tree(),
		"A non-proposer is not offered withdrawal")
	_expect(close_button.is_visible_in_tree(),
		"A member is offered closing an open proposal")
	_expect(not activate_button.is_visible_in_tree()
		and not revoke_button.is_visible_in_tree(),
		"Lifecycle actions that do not apply to the row are hidden")

	select.select(1)
	select.item_selected.emit(1)
	_expect(not approve_button.is_visible_in_tree()
		and not close_button.is_visible_in_tree(),
		"A passed resolution offers no vote or close buttons")
	_expect(activate_button.is_visible_in_tree(),
		"A member is offered activating a passed proposal")
	select.select(3)
	select.item_selected.emit(3)
	_expect(not activate_button.is_visible_in_tree()
		and not revoke_button.is_visible_in_tree(),
		"A revoked resolution offers no lifecycle actions")

	# A proposer sees withdrawal and never the vote buttons on that row.
	panel.open_panel(_view(true, ALICE, true))
	select.select(0)
	select.item_selected.emit(0)
	_expect(withdraw_button.is_visible_in_tree(),
		"The proposer is offered withdrawal before the window closes")
	_expect(not approve_button.is_visible_in_tree(),
		"The proposer is not offered voting on their own proposal")
	select.select(1)
	select.item_selected.emit(1)
	_expect(activate_button.is_visible_in_tree(),
		"A member is offered activation on a passed proposal")

	# A related approver is offered revocation on an effective resolution.
	panel.open_panel(_view(true, CAROL, true))
	select.select(2)
	select.item_selected.emit(2)
	_expect(revoke_button.is_visible_in_tree(),
		"An approving member is offered revocation on an effective resolution")

	# Voting sends exactly one request after confirmation; cancelling sends none.
	panel.open_panel(_view(true, BOB, true))
	select.select(0)
	select.item_selected.emit(0)
	var before: int = fake.calls.size()
	approve_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and panel.is_popup_open(),
		"Clicking approve alone only opens a confirmation")
	var confirm: ConfirmationDialog = panel.find_child("ResolutionConfirm", true, false) as ConfirmationDialog
	confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and not panel.is_popup_open(),
		"Cancelling the vote confirmation sends no request")
	approve_button.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "vote",
		"Confirming emits one vote intent")
	_expect(fake.calls.back().request_id == fake.calls.back().args.get("command_id"),
		"The vote request id doubles as the command id")
	_expect(fake.calls.back().args.get("resolution_id") == "res_1"
		and fake.calls.back().args.get("approve") == true,
		"The vote request names the row and the approval flag")
	_expect(not fake.calls.back().args.has("voter") and not fake.calls.back().args.has("actor"),
		"The panel sends no voter or actor")

	var reject_button: Button = panel.find_child("Reject", true, false) as Button
	before = fake.calls.size()
	reject_button.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "vote"
		and fake.calls.back().args.get("approve") == false,
		"Reject sends an opposing vote for the same row")

	# Lifecycle buttons each forward exactly one request with only the row id.
	for entry: Array in [
		["CloseVote", "close"], ["Activate", "activate"],
		["Withdraw", "withdraw"], ["Revoke", "revoke"],
	]:
		var button: Button = panel.find_child(str(entry[0]), true, false) as Button
		var start: int = fake.calls.size()
		button.pressed.emit()
		await process_frame
		_expect(fake.calls.size() == start and confirm.visible,
			"The %s button only opens a confirmation" % str(entry[1]))
		confirm.get_cancel_button().pressed.emit()
		await process_frame
		_expect(fake.calls.size() == start, "Cancelling %s sends nothing" % str(entry[1]))
		button.pressed.emit()
		await process_frame
		confirm.get_ok_button().pressed.emit()
		await process_frame
		_expect(fake.calls.size() == start + 1
			and fake.calls.back().action == str(entry[1])
			and fake.calls.back().args.get("resolution_id") == panel.selected_id,
			"Confirming %s forwards the selected row once" % str(entry[1]))

	# A proposal forwards the entered fields and never an actor.
	var proposal_id: LineEdit = panel.find_child("ResolutionId", true, false) as LineEdit
	var proposal_kind: OptionButton = panel.find_child("Kind", true, false) as OptionButton
	var proposal_title: LineEdit = panel.find_child("Title", true, false) as LineEdit
	var vote_start: LineEdit = panel.find_child("VoteStart", true, false) as LineEdit
	var vote_end: LineEdit = panel.find_child("VoteEnd", true, false) as LineEdit
	var effective: LineEdit = panel.find_child("EffectiveUtc", true, false) as LineEdit
	var propose_button: Button = panel.find_child("Propose", true, false) as Button
	_expect(proposal_kind.item_count == 2
		and str(proposal_kind.get_item_metadata(0)) == "public_works"
		and str(proposal_kind.get_item_metadata(1)) == "tax",
		"The proposal kind options come from the rule kinds")
	proposal_id.text = "  res_new  "
	proposal_kind.select(1)
	proposal_title.text = " 新修水渠 "
	vote_start.text = " 5000 "
	vote_end.text = " 5600 "
	effective.text = " 9200 "
	before = fake.calls.size()
	propose_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and confirm.visible,
		"Submitting a proposal only opens a confirmation")
	_expect(confirm.dialog_text.contains("权威"),
		"The proposal confirmation says the authority checks the window")
	confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before, "Cancelling the proposal sends nothing")
	propose_button.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "propose",
		"Confirming emits one proposal intent")
	var proposal: Dictionary = fake.calls.back().args.get("proposal", {})
	_expect(fake.calls.back().args.get("resolution_id") == "res_new",
		"The proposal request carries the trimmed resolution id")
	_expect(proposal.get("kind") == "tax" and proposal.get("title") == "新修水渠",
		"The proposal carries the selected kind and trimmed title")
	_expect(float(proposal.get("vote_start_utc", 0.0)) == 5000.0
		and float(proposal.get("vote_end_utc", 0.0)) == 5600.0
		and float(proposal.get("effective_utc", 0.0)) == 9200.0,
		"The proposal carries the three UTC times as numbers")
	_expect(not proposal.has("proposed_by") and not fake.calls.back().args.has("actor"),
		"The panel does not claim a proposer")

	vote_end.text = "soon"
	before = fake.calls.size()
	propose_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("UTC 秒"),
		"A non-numeric time never becomes a proposal")
	proposal_title.text = "   "
	vote_end.text = "5600"
	before = fake.calls.size()
	propose_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("标题"),
		"An empty title never becomes a proposal")

	# A refusal shows the authority's own text and leaves the view untouched.
	var row_count: int = panel.resolutions.size()
	fake.resolutions_result.emit("vote-req", {
		"ok": false, "reason": "already_voted", "reason_text": "你已经投过票了。",
		"duplicate": false, "action": "vote", "state": {},
	})
	await process_frame
	_expect(_status() == "你已经投过票了。",
		"A refused action shows the authority's reason text")
	_expect(panel.resolutions.size() == row_count
		and panel.find_child("Resolution_res_1", true, false) != null,
		"A refusal with no state leaves the visible resolutions untouched")
	fake.resolutions_result.emit("vote-req", {
		"ok": false, "reason": "forbidden", "reason_text": "",
		"duplicate": false, "action": "vote", "state": {},
	})
	await process_frame
	_expect(_status() == "forbidden",
		"A refusal without a reason text shows the authority reason code")

	# A successful reply replaces the whole view and reports the action.
	var replacement: Dictionary = _view(true, BOB, true)
	replacement.resolutions = [_row("res_new", "proposed", "tax", "新修水渠", BOB, 5000.0)]
	replacement.versions = []
	replacement.rules_version = 3
	fake.resolutions_result.emit("propose-req", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": false,
		"action": "propose", "state": replacement,
	})
	await process_frame
	_expect(panel.resolutions.size() == 1,
		"The reply's state replaces the resolution list")
	_expect(panel.find_child("Resolution_res_1", true, false) == null
		and panel.find_child("Resolution_res_new", true, false) != null,
		"A resolution missing from the reply is not kept locally")
	_expect(_status() == "决议已提交。", "A successful proposal is reported")
	_expect(_has_text(_list("VersionList"), "还没有规则版本变化。"),
		"The version diff is replaced with the reply, not merged")

	fake.resolutions_result.emit("activate-req", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": true,
		"action": "activate", "state": replacement,
	})
	await process_frame
	_expect(_status() == "这条决议操作已经执行过。", "A duplicate reply is reported")

	# Losing the world clears the lists without hiding the panel.
	panel.show_unavailable("not_open")
	_expect(_label_text("RulesVersion") == "世界尚未打开"
		and select.disabled and panel.resolutions.is_empty(),
		"An unavailable world clears the list and disables the picker")

	# Malformed payloads and rows do not crash the panel.
	panel.apply_result("", {})
	panel.apply_result("state-req", {"ok": true, "state": {
		"available": true, "is_member": true, "viewer": BOB,
		"rules_version": 2, "versions": ["bad", {}],
		"resolutions": ["bad", {}, {"resolution_id": "res_bare"}],
	}})
	_expect(panel.resolutions.size() == 1
		and panel.find_child("Resolution_res_bare", true, false) != null,
		"Malformed rows are skipped and a bare row still renders without crashing")
	panel.show_status("")
	_expect(_status().is_empty(), "Writing an empty status clears it")

	# The confirmation owns the first Esc; the next one closes the panel and
	# returns focus to the HUD button that opened it.
	panel.open_panel(_view(true, BOB, true))
	select.select(0)
	select.item_selected.emit(0)
	approve_button.pressed.emit()
	await process_frame
	_expect(panel.is_popup_open(), "An open vote confirmation reports that it owns Esc")
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(panel.is_open() and not panel.is_popup_open(),
		"The first Esc only dismisses the vote confirmation")
	esc.pressed = false
	root.push_input(esc)
	var close_panel_button: Button = panel.find_child("Close", true, false) as Button
	close_panel_button.grab_focus()
	await process_frame
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(not panel.is_open(), "Esc closes the resolution panel")
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
	fake.request_resolutions(request_id, action, payload)


func _request_refresh() -> void:
	fake.request_resolutions("resolution-state", "state")


## A member view carries counts; only a related viewer carries the voter ids.
## The panel renders exactly what it is sent.
func _view(member: bool, viewer: String, related: bool) -> Dictionary:
	var rows: Array = [
		_row("res_1", "proposed", "public_works", "修桥", ALICE, 100.0),
		_row("res_2", "passed", "public_works", "修桥", BOB, 100.0),
		_row("res_3", "effective", "tax", "田税", ALICE, 100.0),
		_row("res_4", "revoked", "tax", "田税", ALICE, 100.0),
	]
	for value: Variant in rows:
		var row: Dictionary = value
		if not member:
			continue
		row["approvals"] = 1 if str(row.resolution_id) == "res_1" else 2
		row["rejections"] = 0 if str(row.resolution_id) == "res_1" else 1
		if not related:
			continue
		match str(row.resolution_id):
			"res_1":
				row["approvers"] = [CAROL]
			"res_2":
				row["approvers"] = [ALICE, CAROL]
			"res_3":
				row["approvers"] = [ALICE, CAROL]
			_:
				row["approvers"] = [ALICE, BOB]
		row["rejecters"] = []
	return {
		"available": true, "now_utc": 1000.0, "viewer": viewer,
		"is_member": member, "can_write": member, "rules_version": 3,
		"versions": [
			{"version": 1, "resolution_id": "res_3", "change": "effective"},
			{"version": 2, "resolution_id": "res_4", "change": "effective"},
			{"version": 3, "resolution_id": "res_4", "change": "revoked"},
		],
		"resolutions": rows,
	}


## A joined visitor: the authority hands them the counts, but never the write.
func _joined_visitor_view() -> Dictionary:
	var view: Dictionary = _view(true, BOB, false)
	view["can_write"] = false
	return view


func _row(resolution_id: String, status: String, kind: String, title: String,
		proposer: String, vote_start: float) -> Dictionary:
	var revision: int = 1
	var effective_version: int = 0
	var revoked_version: int = 0
	var revoked_by: String = ""
	var revoked_utc: float = 0.0
	if status == "passed":
		revision = 2
	elif status == "effective":
		revision = 3
		effective_version = 1
	elif status == "revoked":
		revision = 4
		effective_version = 2
		revoked_version = 3
		revoked_by = CAROL
		revoked_utc = 3000.0
	return {
		"resolution_id": resolution_id, "kind": kind, "title": title,
		"proposed_by": proposer, "proposed_utc": vote_start,
		"vote_start_utc": vote_start, "vote_end_utc": vote_start + 960.0,
		"effective_utc": vote_start + 4560.0, "status": status,
		"revision": revision, "effective_version": effective_version,
		"revoked_by": revoked_by, "revoked_utc": revoked_utc,
		"revoked_version": revoked_version,
		"ends_utc": revoked_utc if status == "revoked" else 0.0,
	}


func _row_text(resolution_id: String) -> String:
	var label: Label = panel.find_child("Resolution_" + resolution_id, true, false) as Label
	return label.text if label != null else ""


func _list(node_name: String) -> VBoxContainer:
	return panel.find_child(node_name, true, false) as VBoxContainer


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
	print("RESOLUTIONS_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
