extends SceneTree
## 纠纷面板作为视图：它只根据权威纠纷视图决定显示什么，并把点击变成纠纷操作
## 意图；管理员身份、案件状态、证据窗口、裁定与更正都由权威决定。
##
## 没有网络：视图直接构造，面板在测试里通过一个假远程对象转发请求与答复。

const DisputePanel = preload("res://ui/dispute_panel.gd")

const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"
const CAROL: String = "player_00000000000000000000000000000003"


class FakeRemote extends RefCounted:
	signal dispute_result(request_id: String, payload: Dictionary)

	var calls: Array = []

	func request_dispute(request_id: String, action: String,
			args: Dictionary = {}) -> bool:
		calls.append({
			"request_id": request_id, "action": action,
			"args": args.duplicate(true),
		})
		return true


var panel: DisputePanel
var fake: FakeRemote
var closes: int = 0
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = DisputePanel.new()
	panel.name = "DisputePanel"
	root.add_child(panel)
	fake = FakeRemote.new()
	fake.dispute_result.connect(panel.apply_result)
	panel.dispute_action.connect(_forward_action)
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

	# An empty authority view: no case, roster or public row is invented.
	panel.open_panel({})
	var admin_section: VBoxContainer = panel.find_child("AdminSection", true, false) as VBoxContainer
	var party_section: VBoxContainer = panel.find_child("PartySection", true, false) as VBoxContainer
	var roster: Label = panel.find_child("AuthorityRoster", true, false) as Label
	_expect(panel.is_open(), "Opening the panel shows it")
	_expect(_label_text("AuthorityStatus").contains("未开放"),
		"A missing dispute authority is reported instead of invented")
	_expect(admin_section != null and not admin_section.visible,
		"The administrator section is hidden without an authority view")
	_expect(party_section != null and party_section.visible,
		"The party actions stay available for the authority to refuse")
	_expect(_has_text(_list("CaseList"), "还没有案件。"),
		"An empty view says there are no cases")
	_expect(_has_text(_list("PublicList"), "还没有公开状态。"),
		"An empty view says there are no public status rows")

	# An ordinary player sees only related cases (the authority decides which rows
	# these are); the roster and administrator controls are not shown.
	panel.open_panel(_view(false, BOB))
	_expect(_label_text("AuthorityStatus").contains("玩家 " + BOB),
		"The status line names the viewing player")
	_expect(_label_text("AuthorityStatus").contains("4321"),
		"The status line carries the authority UTC clock")
	_expect(roster != null and not roster.visible and roster.text.is_empty(),
		"An ordinary player does not see the authority roster")
	_expect(not admin_section.visible,
		"The administrator section is hidden from an ordinary player")
	_expect(party_section.visible, "The party actions are shown to an ordinary player")
	var accept_button: Button = panel.find_child("Accept", true, false) as Button
	var close_case_button: Button = panel.find_child("CloseCase", true, false) as Button
	_expect(accept_button != null and not accept_button.is_visible_in_tree()
		and close_case_button != null and not close_case_button.is_visible_in_tree(),
		"Administrator actions are not offered to an ordinary player")
	_expect(panel.cases.size() == 2, "All authoritative related cases are kept")
	var filed_text: String = _case_text("case_filed")
	_expect(filed_text.contains("case_filed") and filed_text.contains(ALICE)
		and filed_text.contains(BOB),
		"A case row shows its number, filer and reported player")
	_expect(filed_text.contains("已立案（filed）"), "A case row shows its authoritative status")
	_expect(filed_text.contains("证据 1"), "A case row counts the evidence rows")
	_expect(filed_text.contains("未裁定"), "A case without a ruling says so")
	_expect(filed_text.contains("申诉 0") and filed_text.contains("更正 0"),
		"A case row counts appeals and corrections")
	_expect(filed_text.contains("审计 0"), "A case without audit rows shows zero")
	var corrected_text: String = _case_text("case_corrected")
	_expect(corrected_text.contains("已更正（corrected）"),
		"The corrected case status is rendered from the authority")
	_expect(corrected_text.contains("证据 2"), "The evidence count comes from the reply")
	_expect(corrected_text.contains("upheld") and corrected_text.contains("证据成立"),
		"The ruling summary shows the authoritative outcome and reason")
	_expect(corrected_text.contains("申诉 1") and corrected_text.contains("更正 1")
		and corrected_text.contains("审计 3"),
		"Appeal, correction and audit counts come from the reply")
	_expect(corrected_text.contains("审计 1：accept") and corrected_text.contains(ALICE),
		"Every audit entry is displayed with its action and author")
	_expect(corrected_text.contains("警告 生效中｜UTC 1500 至 2593500"),
		"The authoritative warning window is rendered from the reply")
	_expect(not filed_text.contains("警告"),
		"A case without an authoritative warning shows no warning line")
	var public_filed: Label = panel.find_child("Public_case_filed", true, false) as Label
	_expect(panel.public_rows.size() == 2 and public_filed != null,
		"The public status rows are rendered separately")
	_expect(public_filed != null and public_filed.text.contains("公开 case_filed")
		and public_filed.text.contains("已立案（filed）")
		and public_filed.text.contains("立案 UTC 1000"),
		"A public row shows only the case number, status and filing time")
	var focus_owner: Control = root.gui_get_focus_owner()
	_expect(focus_owner != null and panel.is_ancestor_of(focus_owner),
		"Opening the dispute panel captures keyboard focus inside it")
	var scroll: ScrollContainer = panel.find_child("Scroll", true, false) as ScrollContainer
	_expect(scroll != null and scroll.follow_focus,
		"The dispute view scrolls to follow keyboard focus")

	# The refresh button asks the caller for a fresh authoritative view.
	var refresh: Button = panel.find_child("Refresh", true, false) as Button
	var before: int = fake.calls.size()
	refresh.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "state"
		and fake.calls.back().request_id == "dispute-state",
		"Refreshing asks the caller for the authoritative state")

	# Filing builds only the request the authority accepts; the request id doubles
	# as the command id, and no actor or submitted_by is invented locally.
	var file_case: LineEdit = panel.find_child("FileCaseId", true, false) as LineEdit
	var file_against: LineEdit = panel.find_child("FileAgainst", true, false) as LineEdit
	var file_events: LineEdit = panel.find_child("FileEvents", true, false) as LineEdit
	var file_button: Button = panel.find_child("FileCase", true, false) as Button
	file_case.text = "  case_new  "
	file_against.text = "  " + CAROL + "  "
	file_events.text = " event_a , event_b "
	before = fake.calls.size()
	file_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "file",
		"Filing emits a file intent")
	_expect(fake.calls.back().request_id == fake.calls.back().args.get("command_id")
		and not str(fake.calls.back().request_id).is_empty(),
		"The filing request id doubles as the command id")
	var args: Dictionary = fake.calls.back().args
	_expect(args.get("case_id") == "case_new", "The filing request carries the trimmed case id")
	_expect(args.get("against") == CAROL, "The filing request carries the reported player")
	_expect(str(args.get("event_ids")) == '["event_a", "event_b"]',
		"The filing request carries every trimmed event id")
	_expect(not args.has("actor") and not args.has("submitted_by"),
		"The panel sends no actor or evidence author")
	file_events.text = "event_a,,event_b"
	before = fake.calls.size()
	file_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("逗号分隔"),
		"An empty event id never becomes a request")
	file_events.text = "event_a"
	file_against.text = ""
	before = fake.calls.size()
	file_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("被举报人"),
		"An empty reported player never becomes a request")
	file_case.text = ""
	before = fake.calls.size()
	file_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("案件编号"),
		"An empty case id never becomes a filing request")

	# Evidence carries the entered kind and source; the authority supplies the
	# submitter and time, so the panel never sends them.
	var evidence_case: LineEdit = panel.find_child("EvidenceCaseId", true, false) as LineEdit
	var evidence_id: LineEdit = panel.find_child("EvidenceId", true, false) as LineEdit
	var evidence_kind: OptionButton = panel.find_child("EvidenceKind", true, false) as OptionButton
	var evidence_source: LineEdit = panel.find_child("EvidenceSource", true, false) as LineEdit
	var evidence_button: Button = panel.find_child("SubmitEvidence", true, false) as Button
	evidence_case.text = "case_filed"
	evidence_id.text = " ev_1 "
	evidence_kind.select(2)
	evidence_source.text = " event_a "
	before = fake.calls.size()
	evidence_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "evidence",
		"Submitting evidence emits an evidence intent")
	args = fake.calls.back().args
	_expect(args.get("case_id") == "case_filed" and args.get("evidence_id") == "ev_1",
		"The evidence request carries the case and evidence ids")
	_expect(args.get("kind") == "witness", "The selected evidence kind is sent verbatim")
	_expect(args.get("source") == "event_a", "The evidence source is sent verbatim")
	_expect(not args.has("submitted_by") and not args.has("at_utc"),
		"The panel does not claim an evidence author or time")
	evidence_source.text = ""
	before = fake.calls.size()
	evidence_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("证据来源"),
		"An empty evidence source never becomes a request")

	# Appeals carry the entered case and reason.
	var appeal_case: LineEdit = panel.find_child("AppealCaseId", true, false) as LineEdit
	var appeal_reason: LineEdit = panel.find_child("AppealReason", true, false) as LineEdit
	var appeal_button: Button = panel.find_child("Appeal", true, false) as Button
	appeal_case.text = "case_corrected"
	appeal_reason.text = " 原裁定未说明证据  "
	before = fake.calls.size()
	appeal_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "appeal"
		and fake.calls.back().args.get("case_id") == "case_corrected"
		and fake.calls.back().args.get("reason") == "原裁定未说明证据",
		"An appeal forwards the case and trimmed reason")
	appeal_reason.text = ""
	before = fake.calls.size()
	appeal_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("申诉理由"),
		"An empty appeal reason never becomes a request")

	# The authority view is the only source of administrator visibility and the
	# roster; every case is rendered when the view says the viewer is authority.
	panel.open_panel(_view(true, ALICE))
	_expect(_label_text("AuthorityStatus").contains("管理员"),
		"The authority viewer is marked as administrator")
	_expect(roster != null and roster.visible
		and roster.text.contains(ALICE) and roster.text.contains(CAROL),
		"The administrator sees the authoritative roster")
	_expect(admin_section.visible, "The administrator section is shown to an authority")
	_expect(accept_button.is_visible_in_tree(),
		"The administrator actions are offered to an authority")
	_expect(panel.cases.size() == 2, "The administrator sees every case in the view")

	var admin_case: LineEdit = panel.find_child("AdminCaseId", true, false) as LineEdit
	var rule_outcome: OptionButton = panel.find_child("RuleOutcome", true, false) as OptionButton
	var rule_amount: LineEdit = panel.find_child("CompensationAmount", true, false) as LineEdit
	var rule_reason: LineEdit = panel.find_child("RuleReason", true, false) as LineEdit
	var rule_advisor: CheckBox = panel.find_child("RuleAdvisor", true, false) as CheckBox
	var reject_button: Button = panel.find_child("Reject", true, false) as Button
	var rule_button: Button = panel.find_child("Rule", true, false) as Button
	var correct_button: Button = panel.find_child("Correct", true, false) as Button
	var confirm: ConfirmationDialog = panel.find_child("DisputeConfirm", true, false) as ConfirmationDialog

	# Accept and reject are single-step state transitions.
	admin_case.text = " case_filed "
	before = fake.calls.size()
	accept_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "accept"
		and fake.calls.back().args.get("case_id") == "case_filed",
		"Accept forwards the trimmed case id")
	before = fake.calls.size()
	reject_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "reject",
		"Reject forwards a reject intent")

	# A ruling needs confirmation; cancelling sends nothing.
	rule_outcome.select(0)
	rule_reason.text = " 证据成立 "
	before = fake.calls.size()
	rule_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().is_empty(),
		"Clicking rule alone never becomes a request")
	_expect(confirm.visible and panel.is_popup_open(),
		"Ruling opens a confirmation that owns the next Esc")
	_expect(confirm.dialog_text.contains("裁定"), "The ruling confirmation explains the action")
	confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before, "Cancelling the ruling confirmation sends no request")
	_expect(not panel.is_popup_open(), "Cancelling the ruling releases Esc ownership")
	rule_button.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "rule",
		"Confirming emits one ruling intent")
	var decision: Dictionary = fake.calls.back().args.get("decision", {})
	_expect(decision.get("advisor") == false and decision.get("authority") == true,
		"An unchecked advisor box sends an authority decision")
	_expect(decision.get("outcome") == "upheld", "The selected outcome is sent verbatim")
	_expect(decision.get("reason") == "证据成立", "The trimmed ruling reason is sent")
	_expect(not fake.calls.back().args.has("actor") and not fake.calls.back().args.has("outcome"),
		"The panel sends no actor and no top-level outcome")

	# Compensation needs a positive amount. The picker reveals the field, an
	# invalid amount blocks the confirmation, and a valid one travels with the
	# ruling for the authority to execute.
	_expect(not rule_amount.visible, "The compensation amount is hidden for other outcomes")
	rule_outcome.select(3)
	rule_outcome.item_selected.emit(3)
	_expect(rule_amount.visible, "Choosing compensation reveals the amount field")
	rule_amount.text = "  "
	before = fake.calls.size()
	rule_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and not confirm.visible
		and _status().contains("正整数金额"),
		"A compensation ruling without an amount sends nothing")
	rule_amount.text = " 12 "
	rule_button.pressed.emit()
	await process_frame
	_expect(confirm.visible and confirm.dialog_text.contains("补偿"),
		"A valid compensation asks for confirmation before moving cash")
	confirm.get_ok_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "rule"
		and int(fake.calls.back().args.get("amount", 0)) == 12
		and fake.calls.back().args.get("decision", {}).get("outcome") == "compensation",
		"The compensation amount and outcome travel together")
	rule_outcome.select(0)
	rule_outcome.item_selected.emit(0)
	_expect(not rule_amount.visible, "Switching back hides the compensation amount")

	# The advisor flag is forwarded, not judged locally: the authority is expected
	# to answer advisory_only and the panel only displays that refusal.
	rule_advisor.button_pressed = true
	before = fake.calls.size()
	rule_button.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	await process_frame
	decision = fake.calls.back().args.get("decision", {})
	_expect(fake.calls.size() == before + 1 and decision.get("advisor") == true
		and decision.get("authority") == false,
		"The advisor flag is forwarded for the authority to judge")
	rule_advisor.button_pressed = false
	fake.dispute_result.emit("rule-req", {
		"ok": false, "reason": "advisory_only", "reason_text": "仅建议的裁定不会写入案件。",
		"duplicate": false, "action": "rule", "state": _view(true, ALICE),
	})
	await process_frame
	_expect(_status().contains("仅建议"),
		"An advisory_only refusal shows the authority's reason text")

	# Corrections and closing confirm first and forward only the entered fields.
	rule_reason.text = " 更正说明 "
	before = fake.calls.size()
	correct_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and confirm.visible,
		"Correcting only opens a confirmation")
	confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before, "Cancelling the correction sends no request")
	correct_button.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "correct"
		and fake.calls.back().args.get("case_id") == "case_filed"
		and fake.calls.back().args.get("reason") == "更正说明",
		"Confirming forwards the correction case and reason")
	before = fake.calls.size()
	close_case_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and confirm.visible,
		"Closing only opens a confirmation")
	confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before, "Cancelling the closing sends no request")
	close_case_button.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "close"
		and fake.calls.back().args.get("case_id") == "case_filed"
		and not fake.calls.back().args.has("reason"),
		"Confirming forwards only the closing case id")

	# A successful state reply replaces the whole view, dropping removed cases.
	var replacement: Dictionary = _view(true, ALICE)
	replacement.cases = [_case("case_new", "filed", 0)]
	replacement.public = [{
		"case_id": "case_new", "status": "filed", "filed_utc": 5000.0,
	}]
	fake.dispute_result.emit("state-req", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": false,
		"action": "state", "state": replacement,
	})
	await process_frame
	_expect(panel.cases.size() == 1, "The reply's state replaces the case list")
	_expect(panel.find_child("Case_case_filed", true, false) == null,
		"A case missing from the reply is not kept locally")
	_expect(panel.find_child("Case_case_new", true, false) != null,
		"The replacement case is rendered")
	_expect(_status().is_empty(), "A successful state reply clears the status line")

	# A refused action shows the authority's own reason and keeps the sent view.
	fake.dispute_result.emit("accept-req", {
		"ok": false, "reason": "forbidden",
		"reason_text": "只有花名册中的管理员可以执行此操作。",
		"duplicate": false, "action": "accept", "state": replacement,
	})
	await process_frame
	_expect(_status().contains("花名册"),
		"A refused reply shows the authority's reason text")
	_expect(panel.find_child("Case_case_new", true, false) != null,
		"A refused reply leaves the authoritative case on screen")
	fake.dispute_result.emit("accept-req", {
		"ok": false, "reason": "forbidden", "reason_text": "",
		"duplicate": false, "action": "accept", "state": replacement,
	})
	await process_frame
	_expect(_status().contains("forbidden"),
		"A refused reply without a reason text shows the authority reason code")

	# Duplicate and successful actions are reported from the authority reply.
	fake.dispute_result.emit("file-req", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": true,
		"action": "file", "state": replacement,
	})
	await process_frame
	_expect(_status().contains("已经执行过"), "A duplicate reply is reported")
	fake.dispute_result.emit("file-req", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": false,
		"action": "file", "state": replacement,
	})
	await process_frame
	_expect(_status() == "案件已立案。", "A successful filing is reported")
	fake.dispute_result.emit("correct-req", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": false,
		"action": "correct", "state": replacement,
	})
	await process_frame
	_expect(_status() == "更正已记录。", "A successful correction is reported")

	# Malformed payloads and rows do not crash the panel.
	panel.apply_result("", {})
	panel.apply_result("state-req", {"ok": true, "state": {"cases": ["bad", {}]}})
	_expect(panel.cases.size() == 1 and panel.find_child("Case_", true, false) != null,
		"Malformed rows are skipped and a bare case still renders without crashing")
	panel.show_status("")
	_expect(_status().is_empty(), "Writing an empty status clears it")

	# An open confirmation owns the first Esc, then Esc closes the panel and
	# returns focus to the HUD button that opened it.
	panel.open_panel(_view(true, ALICE))
	admin_case.text = "case_filed"
	rule_reason.text = "再次裁定"
	rule_outcome.select(0)
	rule_button.pressed.emit()
	await process_frame
	_expect(panel.is_popup_open(), "An open ruling confirmation reports that it owns Esc")
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(panel.is_open() and not panel.is_popup_open(),
		"The first Esc only dismisses the ruling confirmation")
	esc.pressed = false
	root.push_input(esc)
	var close_button: Button = panel.find_child("Close", true, false) as Button
	close_button.grab_focus()
	await process_frame
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(not panel.is_open(), "Esc closes the dispute panel")
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
	fake.request_dispute(request_id, action, payload)


func _request_refresh() -> void:
	fake.request_dispute("dispute-state", "state")


func _view(authority: bool, viewer: String) -> Dictionary:
	return {
		"available": true, "now_utc": 4321.0, "viewer": viewer,
		"is_authority": authority,
		"authority_roles": {"admin": [ALICE], "arbiter": [CAROL]},
		"cases": [
			_case("case_corrected", "corrected", 3),
			_case("case_filed", "filed", 0),
		],
		"public": [
			{"case_id": "case_corrected", "status": "corrected", "filed_utc": 900.0},
			{"case_id": "case_filed", "status": "filed", "filed_utc": 1000.0},
		],
	}


## A minimal authoritative case row. The panel only renders the fields it is
## sent, so this fixture carries no extra client-side facts.
func _case(case_id: String, status: String, audit_count: int) -> Dictionary:
	var row: Dictionary = {
		"case_id": case_id, "filed_by": ALICE, "against": BOB,
		"event_ids": ["event_a"],
		"evidence": [{
			"id": "ev_1", "kind": "authority_event", "source": "event_a",
			"submitted_by": BOB, "at_utc": 1200.0,
		}],
		"status": status, "ruling": {}, "appeals": [], "corrections": [],
		"manager_only": true, "filed_utc": 1000.0, "audit": [],
	}
	if audit_count == 0:
		row.evidence = [row.evidence[0]]
		return row
	row.evidence.append({
		"id": "ev_2", "kind": "ledger", "source": "ledger_1",
		"submitted_by": ALICE, "at_utc": 1300.0,
	})
	row.ruling = {
		"by": ALICE, "at_utc": 1500.0, "outcome": "upheld", "reason": "证据成立",
	}
	row["warning"] = {
		"ok": true, "status": "active",
		"starts_utc": 1500.0, "expires_utc": 2593500.0,
	}
	row.appeals = [{"by": BOB, "at_utc": 1600.0, "reason": "仍有异议"}]
	row.corrections = [{"by": ALICE, "at_utc": 1700.0, "reason": "补充说明"}]
	row.audit = [
		{"action": "accept", "by": ALICE, "at_utc": 1400.0},
		{"action": "rule", "by": ALICE, "at_utc": 1500.0},
		{"action": "correct", "by": ALICE, "at_utc": 1700.0},
	]
	return row


func _case_text(case_id: String) -> String:
	var label: Label = panel.find_child("Case_" + case_id, true, false) as Label
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
	print("DISPUTE_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
