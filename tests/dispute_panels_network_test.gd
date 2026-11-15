extends SceneTree
## M12-04 dispute panel over the real wire: the panel is mounted exactly the way
## `main.gd` wires it, and every view and every reply comes from a real
## `world_server.gd` over loopback WSS through a real `WorldClient`.
##
## One authority serves one world. The startup host A (the only roster
## administrator) opens the panel and sees the authoritative roster and the
## administrator section. Member B then files a case, submits evidence and
## appeals entirely through the panel; A accepts, rules, corrects after the
## appeal and closes, also through the panel. Every write travels on RPC 23/24
## and lands in `disputes.json`; each reply replaces the panel's whole view with
## the authority state, and the original ruling plus the full audit trail stay.
##
## The refusal phase proves the panel never authorizes anything locally:
## B's hidden administrator controls are refused as `forbidden` with the
## authority's own reason text, the advisor checkbox produces `advisory_only`
## while the document stays byte-identical, a cancelled confirmation sends
## nothing, and refreshing or closing writes nothing. A named visitor reads the
## public status row and is refused both filing and evidence.
##
## Everything runs under .local/verification/dispute-panels-network-<ticks>/.

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const Disputes = preload("res://world/dispute_state.gd")
const DisputesStore = preload("res://world/disputes_store.gd")
const DisputePanel = preload("res://ui/dispute_panel.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
## One installation credential per identity (ADR-029); a shared credential binds
## the first player id that presents it.
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const PLAYER_SECRET_VISITOR: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMzM="
const START: float = 1800000000.0
const WORLD: String = "world-dispute-panels-network"
const PLAYER_A: String = "player_00000000000000000000000000000095"
const PLAYER_B: String = "player_00000000000000000000000000000096"
const PLAYER_REPORTED: String = "player_00000000000000000000000000000097"
const VISITOR_ID: String = "player_00000000000000000000000000000098"
const NAME_A: String = "阿管"
const NAME_B: String = "阿诉"
const VISITOR_NAME: String = "旁听者"
const CASE_ID: String = "case_panel_net_1"
const EVENT_ID: String = "event_panel_net_alpha"
const EVIDENCE_ID: String = "ev_panel_net_1"
const B_ACCEPT_REASON: String = "成员试图受理"
const B_RULE_REASON: String = "成员试图裁定"
const RULE_REASON: String = "证据成立"
const APPEAL_REASON: String = "不服裁定"
const CORRECT_REASON: String = "补充证据后更正"
const ADVISOR_REASON: String = "仅建议复核"

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var url: String = ""
var log_path: String = ""
var log_captured: bool = false
var checks: int = 0
var failures: Array[String] = []
var closes: int = 0

var client: WorldClient
var dispute_panel: DisputePanel
var _ready: bool = false
var _refusals: Array[String] = []
## Every dispute reply in arrival order. UI actions generate their request id
## inside the panel, so the test waits on a reply count instead of an id.
var _events: Array = []
## Preserved across phases so later corrections can prove the original ruling
## was never replaced.
var _expected_ruling: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/dispute-panels-network-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	root.size = Vector2i(1280, 720)
	_mount_panel()
	await process_frame

	if not await _start_authority():
		_finish()
		return
	var codes: Dictionary = _join_codes()
	_expect(not str(codes.get("member", "")).is_empty()
			and not str(codes.get("visitor", "")).is_empty(),
		"Member and visitor join codes are built from the operator's material")
	if str(codes.get("member", "")).is_empty() or str(codes.get("visitor", "")).is_empty():
		await _stop_server()
		_finish()
		return

	await _phase_admin_view(codes)
	await _close_client()
	await _phase_member_files(codes)
	await _close_client()
	await _phase_admin_accepts_and_rules(codes)
	await _close_client()
	await _phase_member_appeals_and_refusals(codes)
	await _close_client()
	await _phase_admin_corrects_closes_advisory(codes)
	await _close_client()
	await _phase_visitor(codes)
	await _close_client()
	await _stop_server()
	_finish()


# -------------------------------------------------------------- panel wiring

## Mirrors `main.gd`: one panel, delivery actions forwarded with their command
## id, refreshes ask the authority for a fresh view, and every reply replaces the
## panel's whole view.
func _mount_panel() -> void:
	dispute_panel = DisputePanel.new()
	dispute_panel.name = "Dispute"
	root.add_child(dispute_panel)
	dispute_panel.dispute_action.connect(_dispute_action)
	dispute_panel.refresh_requested.connect(_dispute_refresh)
	dispute_panel.closed.connect(func() -> void: closes += 1)


func _dispute_action(action: String, args: Dictionary) -> void:
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = _new_command_id()
		payload["command_id"] = request_id
	if client == null or not client.request_dispute(request_id, action, payload):
		dispute_panel.show_status("还没有连上世界，纠纷操作没有发出去。")


func _dispute_refresh() -> void:
	if client == null or not client.request_dispute("dispute-state", "state"):
		dispute_panel.show_status("还没有连上世界，纠纷没有刷新。")


## Mirrors `main.gd`: show the last known authoritative view first, then ask the
## authority for a fresh one.
func _open_panel(label: String) -> Dictionary:
	var before: int = _events.size()
	dispute_panel.open_panel(dispute_panel.view.duplicate(true))
	if client == null:
		dispute_panel.show_status("纠纷需要进入共享世界。")
		_expect(false, "The dispute panel needs a joined world (%s)" % label)
		return {}
	if not client.request_dispute("dispute-state", "state"):
		dispute_panel.show_status("还没有连上世界，纠纷没有刷新。")
		_expect(false, "The dispute panel state request is sent (%s)" % label)
		return {}
	_expect(dispute_panel.is_open(),
		"Opening the dispute panel shows it (%s)" % label)
	var reply: Dictionary = await _next_event(_events, before,
		"dispute state (%s)" % label)
	_expect(bool(reply.get("ok", false)),
		"The dispute panel receives a real authority state (%s, reason=%s)"
			% [label, str(reply.get("reason", ""))])
	return reply


# ---------------------------------------------------------------- phase host

func _phase_admin_view(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host administrator joins as a named member over WSS")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.MEMBER,
		"The join reply confers the member role")

	var reply: Dictionary = await _open_panel("host")
	var state: Dictionary = _state(reply)
	_expect(bool(state.get("available", false)),
		"The host's panel sees an available dispute authority")
	_expect(str(state.get("viewer", "")) == PLAYER_A,
		"The dispute view names the host as its viewer")
	_expect(bool(state.get("is_authority", false)),
		"The host's view reports is_authority=true")
	_expect(_role_ids(state, "admin").has(PLAYER_A),
		"The authoritative roster names the host as administrator")
	var now: float = float(state.get("now_utc", 0.0))
	_expect(now > 0.0, "The dispute view carries the authority clock")
	_expect(_authority_status_text().contains("管理员")
			and _authority_status_text().contains("权威已开放"),
		"The host's panel renders the authoritative administrator perspective")
	_expect(_authority_status_text().contains(str(int(now))),
		"The host's panel renders the authoritative UTC clock")
	var admin_section: VBoxContainer = dispute_panel.find_child(
		"AdminSection", true, false) as VBoxContainer
	var party_section: VBoxContainer = dispute_panel.find_child(
		"PartySection", true, false) as VBoxContainer
	var roster: Label = dispute_panel.find_child(
		"AuthorityRoster", true, false) as Label
	_expect(admin_section != null and admin_section.visible,
		"The administrator sees the administrator section")
	_expect(roster != null and roster.visible and roster.text.contains(PLAYER_A),
		"The administrator sees the authoritative roster")
	_expect(party_section != null and party_section.visible,
		"The party actions stay available")
	_expect(_has_text(_list("CaseList"), "还没有案件。"),
		"The host's panel says there are no cases instead of inventing one")
	_expect(_has_text(_list("PublicList"), "还没有公开状态。"),
		"The host's panel says there are no public rows instead of inventing one")


# -------------------------------------------------------------- phase member

func _phase_member_files(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The reporting member joins as a named member over WSS")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.MEMBER,
		"The second connection also has the member role")

	var reply: Dictionary = await _open_panel("member")
	var state: Dictionary = _state(reply)
	_expect(bool(state.get("available", false)),
		"The member's panel sees the real dispute authority")
	_expect(str(state.get("viewer", "")) == PLAYER_B,
		"The member's dispute view names the member as its viewer")
	_expect(not bool(state.get("is_authority", true)),
		"The member's view reports is_authority=false")
	var admin_section: VBoxContainer = dispute_panel.find_child(
		"AdminSection", true, false) as VBoxContainer
	var roster: Label = dispute_panel.find_child(
		"AuthorityRoster", true, false) as Label
	var party_section: VBoxContainer = dispute_panel.find_child(
		"PartySection", true, false) as VBoxContainer
	_expect(admin_section != null and not admin_section.visible,
		"The member's panel hides the administrator section")
	_expect(roster != null and not roster.visible and roster.text.is_empty(),
		"The member's panel hides the authoritative roster")
	_expect(party_section != null and party_section.visible,
		"The member's panel offers the party actions")
	_expect(_authority_status_text().contains("玩家 " + PLAYER_B),
		"The member's panel renders the player perspective")
	var accept_button: Button = dispute_panel.find_child("Accept", true, false) as Button
	_expect(accept_button != null and not accept_button.is_visible_in_tree(),
		"Administrator actions are not offered to the member")

	# Filing: the click alone sends nothing, the view stays on the authority's
	# last state, and the reply is the only source of the new case.
	var file_case: LineEdit = dispute_panel.find_child(
		"FileCaseId", true, false) as LineEdit
	var file_against: LineEdit = dispute_panel.find_child(
		"FileAgainst", true, false) as LineEdit
	var file_events: LineEdit = dispute_panel.find_child(
		"FileEvents", true, false) as LineEdit
	var file_button: Button = dispute_panel.find_child(
		"FileCase", true, false) as Button
	_expect(file_case != null and file_against != null and file_events != null
			and file_button != null,
		"The member's panel exposes the filing fields")
	if file_case == null or file_button == null:
		return
	file_case.text = CASE_ID
	file_against.text = PLAYER_REPORTED
	file_events.text = EVENT_ID
	var view_before: Dictionary = dispute_panel.view.duplicate(true)
	var before: int = _events.size()
	file_button.pressed.emit()
	_expect(_events.size() == before,
		"Clicking file alone never reaches the authority")
	_expect(_same_view(dispute_panel.view, view_before),
		"The panel keeps the authority's last state before sending")
	var filed: Dictionary = await _next_event(_events, before, "filing")
	_expect(bool(filed.get("ok", false)) and not bool(filed.get("duplicate", true)),
		"The member's filing sent through the panel lands on the authority (%s)"
			% str(filed.get("reason", "")))
	_expect(str(filed.get("action", "")) == "file"
			and str(filed.get("status", "")) == Disputes.STATUS_FILED,
		"The filing reply names the action and the filed status")
	_expect(_panel_status(dispute_panel) == "案件已立案。",
		"A successful filing is reported by the panel")
	var filed_state: Dictionary = _state(filed)
	var filed_row: Dictionary = _view_case(filed_state)
	_expect(str(filed_row.get("filed_by", "")) == PLAYER_B
			and str(filed_row.get("against", "")) == PLAYER_REPORTED
			and str(filed_row.get("status", "")) == Disputes.STATUS_FILED,
		"The authority view carries the filed case with both parties")
	_expect((filed_row.get("evidence", []) as Array).is_empty()
			and (filed_row.get("audit", []) as Array).is_empty(),
		"The fresh case has no invented evidence or audit entries")
	var case_text: String = _case_text()
	_expect(case_text.contains("已立案（filed）") and case_text.contains(PLAYER_B)
			and case_text.contains(PLAYER_REPORTED),
		"The member's panel renders the authoritative filed case")
	_expect(case_text.contains("证据 0") and case_text.contains("审计 0"),
		"The member's panel renders the authoritative zero counts")
	_expect(_public_text().contains("公开 " + CASE_ID)
			and _public_text().contains("已立案（filed）"),
		"The member's panel renders the authoritative public status row")
	var stored: Dictionary = _stored_case()
	_expect(str(stored.get("filed_by", "")) == PLAYER_B
			and str(stored.get("status", "")) == Disputes.STATUS_FILED
			and _string_array(stored.get("event_ids", [])) == [EVENT_ID],
		"The filing is persisted to disputes.json")
	var document: Dictionary = _stored_document()
	_expect(int(document.get("version", -1)) == 1
			and str(document.get("world_id", "")) == WORLD,
		"disputes.json carries version 1 and the world identity")
	var commands_value: Variant = document.get("commands", [])
	_expect(commands_value is Array and (commands_value as Array).size() >= 1,
		"disputes.json persists the replay journal")

	# Evidence: the authority supplies the submitter and the clock.
	var evidence_case: LineEdit = dispute_panel.find_child(
		"EvidenceCaseId", true, false) as LineEdit
	var evidence_id: LineEdit = dispute_panel.find_child(
		"EvidenceId", true, false) as LineEdit
	var evidence_kind: OptionButton = dispute_panel.find_child(
		"EvidenceKind", true, false) as OptionButton
	var evidence_source: LineEdit = dispute_panel.find_child(
		"EvidenceSource", true, false) as LineEdit
	var evidence_button: Button = dispute_panel.find_child(
		"SubmitEvidence", true, false) as Button
	_expect(evidence_case != null and evidence_id != null and evidence_kind != null
			and evidence_source != null and evidence_button != null,
		"The member's panel exposes the evidence fields")
	if evidence_case == null or evidence_button == null:
		return
	evidence_case.text = CASE_ID
	evidence_id.text = EVIDENCE_ID
	evidence_kind.select(0)
	evidence_source.text = EVENT_ID
	view_before = dispute_panel.view.duplicate(true)
	before = _events.size()
	evidence_button.pressed.emit()
	_expect(_events.size() == before,
		"Clicking submit evidence alone never reaches the authority")
	_expect(_same_view(dispute_panel.view, view_before),
		"The panel keeps the authority's last state before the evidence send")
	var evidence: Dictionary = await _next_event(_events, before, "evidence")
	_expect(bool(evidence.get("ok", false)) and not bool(evidence.get("duplicate", true)),
		"The member's evidence sent through the panel lands on the authority (%s)"
			% str(evidence.get("reason", "")))
	_expect(str(evidence.get("action", "")) == "evidence",
		"The evidence reply names the action")
	_expect(_panel_status(dispute_panel) == "证据已提交。",
		"A successful evidence submission is reported by the panel")
	var evidence_row: Dictionary = _view_case(_state(evidence))
	var evidence_rows: Array = evidence_row.get("evidence", []) \
		if evidence_row.get("evidence") is Array else []
	_expect(evidence_rows.size() == 1
			and str((evidence_rows[0] as Dictionary).get("submitted_by", "")) == PLAYER_B,
		"The authority records the member as the submitter")
	_expect(_case_text().contains("证据 1"),
		"The member's panel renders the authoritative evidence count")
	stored = _stored_case()
	var stored_evidence: Array = stored.get("evidence", []) \
		if stored.get("evidence") is Array else []
	_expect(stored_evidence.size() == 1
			and str((stored_evidence[0] as Dictionary).get("id", "")) == EVIDENCE_ID
			and str((stored_evidence[0] as Dictionary).get("submitted_by", "")) == PLAYER_B
			and float((stored_evidence[0] as Dictionary).get("at_utc", 0.0)) > 0.0,
		"disputes.json stores the evidence author and authority time")


# ----------------------------------------------------------- phase admin rule

func _phase_admin_accepts_and_rules(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The administrator rejoins to accept and rule")
	if client == null or not client.joined:
		return
	var reply: Dictionary = await _open_panel("admin accept")
	var state: Dictionary = _state(reply)
	_expect(bool(state.get("is_authority", false)),
		"The administrator's fresh view still reports is_authority=true")
	var opened_row: Dictionary = _view_case(state)
	_expect(str(opened_row.get("status", "")) == Disputes.STATUS_FILED
			and (opened_row.get("evidence", []) as Array).size() == 1,
		"The administrator sees the filed case and its evidence")

	var admin_case: LineEdit = dispute_panel.find_child(
		"AdminCaseId", true, false) as LineEdit
	var accept_button: Button = dispute_panel.find_child(
		"Accept", true, false) as Button
	_expect(admin_case != null and accept_button != null,
		"The administrator's panel exposes the accept control")
	if admin_case == null or accept_button == null:
		return
	admin_case.text = CASE_ID
	var view_before: Dictionary = dispute_panel.view.duplicate(true)
	var before: int = _events.size()
	accept_button.pressed.emit()
	_expect(_events.size() == before,
		"Clicking accept alone never reaches the authority")
	_expect(_same_view(dispute_panel.view, view_before),
		"The panel keeps the authority's last state before accepting")
	var accepted: Dictionary = await _next_event(_events, before, "accept")
	_expect(bool(accepted.get("ok", false)) and not bool(accepted.get("duplicate", true)),
		"The administrator's accept sent through the panel lands on the authority (%s)"
			% str(accepted.get("reason", "")))
	_expect(str(accepted.get("status", "")) == Disputes.STATUS_ACCEPTED,
		"The accept reply reports the accepted status")
	_expect(_panel_status(dispute_panel) == "案件已受理。",
		"A successful accept is reported by the panel")
	var accepted_state: Dictionary = _state(accepted)
	var accepted_row: Dictionary = _view_case(accepted_state)
	_expect(_audit_actions(accepted_row) == ["accept"],
		"The authority view carries the accept audit entry")
	_expect(_case_text().contains("已受理（accepted）")
			and _case_text().contains("审计 1"),
		"The administrator's panel renders the accepted status and audit count")
	var stored: Dictionary = _stored_case()
	_expect(str(stored.get("status", "")) == Disputes.STATUS_ACCEPTED
			and _audit_actions(stored) == ["accept"],
		"The accept is persisted to disputes.json")

	# A ruling needs confirmation; cancelling sends nothing and writes nothing.
	var rule_outcome: OptionButton = dispute_panel.find_child(
		"RuleOutcome", true, false) as OptionButton
	var rule_reason: LineEdit = dispute_panel.find_child(
		"RuleReason", true, false) as LineEdit
	var rule_advisor: CheckBox = dispute_panel.find_child(
		"RuleAdvisor", true, false) as CheckBox
	var rule_button: Button = dispute_panel.find_child(
		"Rule", true, false) as Button
	var confirm: ConfirmationDialog = dispute_panel.find_child(
		"DisputeConfirm", true, false) as ConfirmationDialog
	_expect(rule_outcome != null and rule_reason != null and rule_advisor != null
			and rule_button != null and confirm != null,
		"The administrator's panel exposes the ruling fields and confirmation")
	if rule_button == null or confirm == null:
		return
	rule_outcome.select(0)
	rule_reason.text = RULE_REASON
	rule_advisor.button_pressed = false
	var bytes_before: PackedByteArray = _bytes(_disputes_path())
	view_before = dispute_panel.view.duplicate(true)
	before = _events.size()
	rule_button.pressed.emit()
	await process_frame
	_expect(_events.size() == before and confirm.visible,
		"Clicking rule only opens the confirmation")
	_expect(dispute_panel.is_popup_open(),
		"The ruling confirmation owns the next Esc")
	confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(_events.size() == before and not confirm.visible,
		"Cancelling the ruling confirmation sends nothing")
	_expect(_same_view(dispute_panel.view, view_before),
		"A cancelled ruling leaves the view at the authority's last state")
	_expect(_bytes(_disputes_path()) == bytes_before,
		"A cancelled ruling writes no authority document")

	before = _events.size()
	rule_button.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	var ruled: Dictionary = await _next_event(_events, before, "rule")
	_expect(bool(ruled.get("ok", false)) and not bool(ruled.get("duplicate", true)),
		"The administrator's ruling sent through the panel lands on the authority (%s)"
			% str(ruled.get("reason", "")))
	_expect(str(ruled.get("action", "")) == "rule"
			and str(ruled.get("status", "")) == Disputes.STATUS_RULED,
		"The ruling reply reports the ruled status")
	_expect(_panel_status(dispute_panel) == "裁定已记录。",
		"A recorded ruling is reported by the panel")
	var ruled_state: Dictionary = _state(ruled)
	var ruled_row: Dictionary = _view_case(ruled_state)
	var ruling_value: Variant = ruled_row.get("ruling")
	var ruling: Dictionary = ruling_value if ruling_value is Dictionary else {}
	_expect(str(ruling.get("outcome", "")) == "upheld"
			and str(ruling.get("by", "")) == PLAYER_A
			and str(ruling.get("reason", "")) == RULE_REASON,
		"The authority view carries the ruling author, outcome and reason")
	_expect(_audit_actions(ruled_row) == ["accept", "rule"],
		"The authority view carries both administrator audit entries")
	_expect(_case_text().contains("已裁定（ruled）")
			and _case_text().contains("upheld") and _case_text().contains(PLAYER_A)
			and _case_text().contains("审计 2"),
		"The administrator's panel renders the authoritative ruling and audit")
	stored = _stored_case()
	_expect(str(stored.get("status", "")) == Disputes.STATUS_RULED
			and _audit_actions(stored) == ["accept", "rule"],
		"The ruling is persisted with its audit trail")
	_expected_ruling = _dict(stored.get("ruling"))


# ------------------------------------------------------ phase member refusals

func _phase_member_appeals_and_refusals(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The reporting member rejoins to appeal")
	if client == null or not client.joined:
		return
	var reply: Dictionary = await _open_panel("member appeal")
	var state: Dictionary = _state(reply)
	_expect(str(state.get("viewer", "")) == PLAYER_B
			and not bool(state.get("is_authority", true)),
		"The member's view stays non-authoritative across reconnects")
	var appealed_before: Dictionary = _view_case(state)
	_expect(str(appealed_before.get("status", "")) == Disputes.STATUS_RULED,
		"The member sees the authoritative ruled status")

	# Appeal via the panel.
	var appeal_case: LineEdit = dispute_panel.find_child(
		"AppealCaseId", true, false) as LineEdit
	var appeal_reason: LineEdit = dispute_panel.find_child(
		"AppealReason", true, false) as LineEdit
	var appeal_button: Button = dispute_panel.find_child(
		"Appeal", true, false) as Button
	_expect(appeal_case != null and appeal_reason != null and appeal_button != null,
		"The member's panel exposes the appeal fields")
	if appeal_case == null or appeal_button == null:
		return
	appeal_case.text = CASE_ID
	appeal_reason.text = APPEAL_REASON
	var view_before: Dictionary = dispute_panel.view.duplicate(true)
	var before: int = _events.size()
	appeal_button.pressed.emit()
	_expect(_events.size() == before,
		"Clicking appeal alone never reaches the authority")
	_expect(_same_view(dispute_panel.view, view_before),
		"The panel keeps the authority's last state before appealing")
	var appealed: Dictionary = await _next_event(_events, before, "appeal")
	_expect(bool(appealed.get("ok", false)) and not bool(appealed.get("duplicate", true)),
		"The member's appeal sent through the panel lands on the authority (%s)"
			% str(appealed.get("reason", "")))
	_expect(str(appealed.get("action", "")) == "appeal"
			and str(appealed.get("status", "")) == Disputes.STATUS_APPEALED,
		"The appeal reply reports the appealed status")
	_expect(_panel_status(dispute_panel) == "申诉已提交。",
		"A successful appeal is reported by the panel")
	var appealed_row: Dictionary = _view_case(_state(appealed))
	_expect(_dict(appealed_row.get("ruling")) == _expected_ruling,
		"An appeal preserves the original ruling in the view")
	_expect((appealed_row.get("appeals", []) as Array).size() == 1,
		"The authority view carries the appeal row")
	_expect(_case_text().contains("已申诉（appealed）")
			and _case_text().contains("申诉 1") and _case_text().contains("审计 2"),
		"The member's panel renders the appealed status and counters")
	var stored: Dictionary = _stored_case()
	_expect(str(stored.get("status", "")) == Disputes.STATUS_APPEALED
			and _dict(stored.get("ruling")) == _expected_ruling,
		"The appeal is persisted without replacing the ruling")

	# The member's hidden administrator controls are refused by the authority,
	# and the panel shows the authority's own reason text verbatim.
	var bytes_before: PackedByteArray = _bytes(_disputes_path())
	var admin_case: LineEdit = dispute_panel.find_child(
		"AdminCaseId", true, false) as LineEdit
	var accept_button: Button = dispute_panel.find_child(
		"Accept", true, false) as Button
	_expect(admin_case != null and accept_button != null,
		"The hidden administrator controls still exist for the authority to judge")
	if admin_case == null or accept_button == null:
		return
	admin_case.text = CASE_ID
	view_before = dispute_panel.view.duplicate(true)
	before = _events.size()
	accept_button.pressed.emit()
	_expect(_events.size() == before,
		"A refused accept click sends only after the reply request")
	var refused_accept: Dictionary = await _next_event(_events, before,
		"member accept refusal")
	_expect(not bool(refused_accept.get("ok", true)),
		"The member's accept is refused by the authority")
	_expect(str(refused_accept.get("reason", "")) == "forbidden",
		"The accept refusal reason is forbidden")
	var reason_text: String = str(refused_accept.get("reason_text", ""))
	_expect(not reason_text.is_empty(),
		"The accept refusal carries an authority reason text")
	_expect(_panel_status(dispute_panel) == reason_text,
		"The panel shows the accept refusal text verbatim")
	_expect(_same_view(dispute_panel.view, view_before),
		"The refused accept leaves the view at the authority's last state")
	_expect(str(_view_case(dispute_panel.view).get("status", ""))
			== Disputes.STATUS_APPEALED,
		"The refused accept does not change the authoritative case status")
	_expect(_bytes(_disputes_path()) == bytes_before,
		"A refused accept writes no authority document")

	var rule_outcome: OptionButton = dispute_panel.find_child(
		"RuleOutcome", true, false) as OptionButton
	var rule_reason: LineEdit = dispute_panel.find_child(
		"RuleReason", true, false) as LineEdit
	var rule_button: Button = dispute_panel.find_child(
		"Rule", true, false) as Button
	var confirm: ConfirmationDialog = dispute_panel.find_child(
		"DisputeConfirm", true, false) as ConfirmationDialog
	if rule_outcome == null or rule_reason == null or rule_button == null \
			or confirm == null:
		_expect(false, "The member's panel exposes the ruling controls")
		return
	rule_reason.text = B_RULE_REASON
	rule_outcome.select(0)
	view_before = dispute_panel.view.duplicate(true)
	before = _events.size()
	rule_button.pressed.emit()
	await process_frame
	_expect(_events.size() == before and confirm.visible,
		"The member's rule click only opens the confirmation")
	confirm.get_ok_button().pressed.emit()
	var refused_rule: Dictionary = await _next_event(_events, before,
		"member rule refusal")
	_expect(not bool(refused_rule.get("ok", true))
			and str(refused_rule.get("reason", "")) == "forbidden",
		"The member's ruling is refused as forbidden")
	reason_text = str(refused_rule.get("reason_text", ""))
	_expect(not reason_text.is_empty(),
		"The ruling refusal carries an authority reason text")
	_expect(_panel_status(dispute_panel) == reason_text,
		"The panel shows the ruling refusal text verbatim")
	_expect(_same_view(dispute_panel.view, view_before),
		"The refused ruling leaves the view at the authority's last state")
	_expect(_bytes(_disputes_path()) == bytes_before,
		"A refused ruling writes no authority document")


# ---------------------------------------------- phase admin correction/close

func _phase_admin_corrects_closes_advisory(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The administrator rejoins to correct and close")
	if client == null or not client.joined:
		return
	var reply: Dictionary = await _open_panel("admin correct")
	var state: Dictionary = _state(reply)
	_expect(bool(state.get("is_authority", false)),
		"The administrator's view is authoritative again")
	var open_row: Dictionary = _view_case(state)
	_expect(str(open_row.get("status", "")) == Disputes.STATUS_APPEALED
			and _dict(open_row.get("ruling")) == _expected_ruling,
		"The administrator sees the appealed case with its original ruling")

	var admin_case: LineEdit = dispute_panel.find_child(
		"AdminCaseId", true, false) as LineEdit
	var rule_reason: LineEdit = dispute_panel.find_child(
		"RuleReason", true, false) as LineEdit
	var correct_button: Button = dispute_panel.find_child(
		"Correct", true, false) as Button
	var close_case_button: Button = dispute_panel.find_child(
		"CloseCase", true, false) as Button
	var confirm: ConfirmationDialog = dispute_panel.find_child(
		"DisputeConfirm", true, false) as ConfirmationDialog
	_expect(admin_case != null and rule_reason != null and correct_button != null
			and close_case_button != null and confirm != null,
		"The administrator's panel exposes the correction and closing controls")
	if admin_case == null or correct_button == null or confirm == null:
		return
	admin_case.text = CASE_ID
	rule_reason.text = CORRECT_REASON

	var bytes_before: PackedByteArray = _bytes(_disputes_path())
	var view_before: Dictionary = dispute_panel.view.duplicate(true)
	var before: int = _events.size()
	correct_button.pressed.emit()
	await process_frame
	_expect(_events.size() == before and confirm.visible,
		"Clicking correct only opens the confirmation")
	confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(_events.size() == before,
		"Cancelling the correction confirmation sends nothing")
	_expect(_same_view(dispute_panel.view, view_before),
		"A cancelled correction leaves the view at the authority's last state")
	_expect(_bytes(_disputes_path()) == bytes_before,
		"A cancelled correction writes no authority document")

	before = _events.size()
	correct_button.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	var corrected: Dictionary = await _next_event(_events, before, "correct")
	_expect(bool(corrected.get("ok", false)) and not bool(corrected.get("duplicate", true)),
		"The administrator's correction sent through the panel lands on the authority (%s)"
			% str(corrected.get("reason", "")))
	_expect(str(corrected.get("action", "")) == "correct"
			and str(corrected.get("status", "")) == Disputes.STATUS_CORRECTED,
		"The correction reply reports the corrected status")
	_expect(_panel_status(dispute_panel) == "更正已记录。",
		"A recorded correction is reported by the panel")
	var corrected_row: Dictionary = _view_case(_state(corrected))
	_expect(_dict(corrected_row.get("ruling")) == _expected_ruling,
		"The correction preserves the original ruling")
	_expect((corrected_row.get("appeals", []) as Array).size() == 1
			and (corrected_row.get("corrections", []) as Array).size() == 1,
		"The correction keeps the appeal and adds one correction row")
	_expect(_audit_actions(corrected_row) == ["accept", "rule", "correct"],
		"The correction appends one audit entry")
	_expect(_case_text().contains("已更正（corrected）")
			and _case_text().contains("更正 1") and _case_text().contains("审计 3"),
		"The administrator's panel renders the correction and audit")
	var stored: Dictionary = _stored_case()
	_expect(_dict(stored.get("ruling")) == _expected_ruling
			and _audit_actions(stored) == ["accept", "rule", "correct"],
		"disputes.json preserves the ruling and the correction audit")

	# Closing also confirms first; cancelling writes nothing.
	bytes_before = _bytes(_disputes_path())
	view_before = dispute_panel.view.duplicate(true)
	before = _events.size()
	close_case_button.pressed.emit()
	await process_frame
	_expect(_events.size() == before and confirm.visible,
		"Clicking close only opens the confirmation")
	confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(_events.size() == before,
		"Cancelling the closing confirmation sends nothing")
	_expect(_same_view(dispute_panel.view, view_before),
		"A cancelled closing leaves the view at the authority's last state")
	_expect(_bytes(_disputes_path()) == bytes_before,
		"A cancelled closing writes no authority document")

	before = _events.size()
	close_case_button.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	var closed: Dictionary = await _next_event(_events, before, "close")
	_expect(bool(closed.get("ok", false)) and not bool(closed.get("duplicate", true)),
		"The administrator's closing sent through the panel lands on the authority (%s)"
			% str(closed.get("reason", "")))
	_expect(str(closed.get("action", "")) == "close"
			and str(closed.get("status", "")) == Disputes.STATUS_CLOSED,
		"The closing reply reports the closed status")
	_expect(_panel_status(dispute_panel) == "案件已结案。",
		"A successful closing is reported by the panel")
	var closed_row: Dictionary = _view_case(_state(closed))
	_expect(_audit_actions(closed_row) == ["accept", "rule", "correct", "close"],
		"The closed case carries the full administrator audit trail")
	_expect((closed_row.get("appeals", []) as Array).size() == 1
			and (closed_row.get("corrections", []) as Array).size() == 1,
		"The closed case keeps its appeal and correction history")
	_expect(_case_text().contains("已结案（closed）")
			and _case_text().contains("审计 4"),
		"The administrator's panel renders the closed case and full audit")
	stored = _stored_case()
	_expect(str(stored.get("status", "")) == Disputes.STATUS_CLOSED
			and _dict(stored.get("ruling")) == _expected_ruling
			and _audit_actions(stored) == ["accept", "rule", "correct", "close"],
		"disputes.json persists the closed case, ruling and full audit")
	var bytes_closed: PackedByteArray = _bytes(_disputes_path())

	# The advisor checkbox is forwarded verbatim; the authority answers
	# advisory_only and the document stays byte-identical.
	var rule_outcome: OptionButton = dispute_panel.find_child(
		"RuleOutcome", true, false) as OptionButton
	var rule_advisor: CheckBox = dispute_panel.find_child(
		"RuleAdvisor", true, false) as CheckBox
	var rule_button: Button = dispute_panel.find_child(
		"Rule", true, false) as Button
	if rule_outcome == null or rule_advisor == null or rule_button == null:
		_expect(false, "The administrator's panel exposes the advisor ruling controls")
		return
	rule_reason.text = ADVISOR_REASON
	rule_outcome.select(0)
	rule_advisor.button_pressed = true
	view_before = dispute_panel.view.duplicate(true)
	before = _events.size()
	rule_button.pressed.emit()
	await process_frame
	_expect(_events.size() == before and confirm.visible,
		"The advisor ruling click only opens the confirmation")
	confirm.get_ok_button().pressed.emit()
	var advisory: Dictionary = await _next_event(_events, before, "advisory rule")
	_expect(not bool(advisory.get("ok", true)),
		"The advisor ruling is refused by the authority")
	_expect(str(advisory.get("reason", "")) == "advisory_only",
		"The advisor ruling refusal reason is advisory_only")
	var reason_text: String = str(advisory.get("reason_text", ""))
	_expect(not reason_text.is_empty(),
		"The advisory_only refusal carries an authority reason text")
	_expect(_panel_status(dispute_panel) == reason_text,
		"The panel shows the advisory_only reason text verbatim")
	_expect(_same_view(dispute_panel.view, view_before),
		"The advisory_only refusal leaves the view at the authority's last state")
	var advisory_audit: Variant = _view_case(dispute_panel.view).get("audit", [])
	_expect(advisory_audit is Array and (advisory_audit as Array).size() == 4,
		"The advisory_only refusal adds no audit entry")
	_expect(_bytes(_disputes_path()) == bytes_closed,
		"The advisor ruling leaves disputes.json byte-identical")
	rule_advisor.button_pressed = false

	# A refresh re-renders the same authoritative document and writes nothing.
	before = _events.size()
	var refresh: Button = dispute_panel.find_child("Refresh", true, false) as Button
	_expect(refresh != null, "The panel exposes a refresh control")
	if refresh == null:
		return
	refresh.pressed.emit()
	var refreshed: Dictionary = await _next_event(_events, before, "admin refresh")
	_expect(bool(refreshed.get("ok", false)),
		"Refreshing the panel is answered by the authority")
	_expect(_case_text().contains("已结案（closed）")
			and _case_text().contains("审计 4"),
		"A refresh re-renders the authoritative closed case and audit")
	_expect(_panel_status(dispute_panel).is_empty(),
		"A successful refresh clears the panel status")
	_expect(_bytes(_disputes_path()) == bytes_closed,
		"Refreshing the dispute panel writes no authority document")

	var closes_before: int = closes
	var close_panel_button: Button = dispute_panel.find_child(
		"Close", true, false) as Button
	_expect(close_panel_button != null, "The panel exposes a close control")
	if close_panel_button == null:
		return
	close_panel_button.pressed.emit()
	await process_frame
	_expect(not dispute_panel.is_open() and closes == closes_before + 1,
		"Closing the dispute panel hides it and emits one close signal")
	_expect(_bytes(_disputes_path()) == bytes_closed,
		"Closing the dispute panel writes no authority document")


# --------------------------------------------------------------- phase visitor

func _phase_visitor(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("visitor", "")), VISITOR_ID, VISITOR_NAME,
		PLAYER_SECRET_VISITOR), "A named visitor joins with the visitor code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")
	var reply: Dictionary = await _open_panel("visitor")
	var state: Dictionary = _state(reply)
	_expect(bool(state.get("available", false)),
		"A visitor may read the dispute authority")
	_expect(str(state.get("viewer", "")) == VISITOR_ID
			and not bool(state.get("is_authority", true)),
		"The visitor's view is non-authoritative and names the visitor")
	_expect((state.get("cases", []) as Array).is_empty(),
		"The visitor sees no case details")
	_expect((state.get("public", []) as Array).size() == 1,
		"The visitor sees the public status row")
	var admin_section: VBoxContainer = dispute_panel.find_child(
		"AdminSection", true, false) as VBoxContainer
	_expect(admin_section != null and not admin_section.visible,
		"The visitor's panel hides the administrator section")
	_expect(_public_text().contains("公开 " + CASE_ID)
			and _public_text().contains("已结案（closed）"),
		"The visitor's panel renders the authoritative public status")
	_expect(_case_label() == null,
		"The visitor's panel renders no private case row")

	# The visitor is offered the party actions so the authority can refuse them.
	var bytes_before: PackedByteArray = _bytes(_disputes_path())
	var file_case: LineEdit = dispute_panel.find_child(
		"FileCaseId", true, false) as LineEdit
	var file_against: LineEdit = dispute_panel.find_child(
		"FileAgainst", true, false) as LineEdit
	var file_events: LineEdit = dispute_panel.find_child(
		"FileEvents", true, false) as LineEdit
	var file_button: Button = dispute_panel.find_child(
		"FileCase", true, false) as Button
	if file_case == null or file_against == null or file_events == null \
			or file_button == null:
		_expect(false, "The visitor's panel exposes the filing fields")
		return
	file_case.text = "case_visitor_attempt"
	file_against.text = PLAYER_REPORTED
	file_events.text = EVENT_ID
	var view_before: Dictionary = dispute_panel.view.duplicate(true)
	var before: int = _events.size()
	file_button.pressed.emit()
	_expect(_events.size() == before,
		"The visitor's file click alone never reaches the authority")
	_expect(_same_view(dispute_panel.view, view_before),
		"The panel keeps the authority's last state before the visitor send")
	var refused_file: Dictionary = await _next_event(_events, before,
		"visitor filing refusal")
	_expect(not bool(refused_file.get("ok", true))
			and str(refused_file.get("reason", "")) == "forbidden",
		"A visitor's filing is refused as forbidden")
	var reason_text: String = str(refused_file.get("reason_text", ""))
	_expect(not reason_text.is_empty(),
		"The visitor's filing refusal carries an authority reason text")
	_expect(_panel_status(dispute_panel) == reason_text,
		"The panel shows the visitor filing refusal text verbatim")
	_expect(_same_view(dispute_panel.view, view_before),
		"The refused visitor filing leaves the view at the authority's last state")
	_expect((dispute_panel.view.get("cases", []) as Array).is_empty(),
		"The refused visitor filing adds no local case row")
	_expect(_bytes(_disputes_path()) == bytes_before,
		"A refused visitor filing writes no authority document")

	var evidence_case: LineEdit = dispute_panel.find_child(
		"EvidenceCaseId", true, false) as LineEdit
	var evidence_id: LineEdit = dispute_panel.find_child(
		"EvidenceId", true, false) as LineEdit
	var evidence_source: LineEdit = dispute_panel.find_child(
		"EvidenceSource", true, false) as LineEdit
	var evidence_button: Button = dispute_panel.find_child(
		"SubmitEvidence", true, false) as Button
	if evidence_case == null or evidence_id == null or evidence_source == null \
			or evidence_button == null:
		_expect(false, "The visitor's panel exposes the evidence fields")
		return
	evidence_case.text = CASE_ID
	evidence_id.text = "ev_visitor_attempt"
	evidence_source.text = EVENT_ID
	view_before = dispute_panel.view.duplicate(true)
	before = _events.size()
	evidence_button.pressed.emit()
	_expect(_events.size() == before,
		"The visitor's evidence click alone never reaches the authority")
	_expect(_same_view(dispute_panel.view, view_before),
		"The panel keeps the authority's last state before the visitor evidence send")
	var refused_evidence: Dictionary = await _next_event(_events, before,
		"visitor evidence refusal")
	_expect(not bool(refused_evidence.get("ok", true))
			and str(refused_evidence.get("reason", "")) == "forbidden",
		"A visitor's evidence is refused as forbidden")
	reason_text = str(refused_evidence.get("reason_text", ""))
	_expect(not reason_text.is_empty(),
		"The visitor's evidence refusal carries an authority reason text")
	_expect(_panel_status(dispute_panel) == reason_text,
		"The panel shows the visitor evidence refusal text verbatim")
	_expect(_same_view(dispute_panel.view, view_before),
		"The refused visitor evidence leaves the view at the authority's last state")
	_expect(_bytes(_disputes_path()) == bytes_before,
		"A refused visitor evidence writes no authority document")

	# Refreshing and closing are reads only.
	before = _events.size()
	var refresh: Button = dispute_panel.find_child("Refresh", true, false) as Button
	_expect(refresh != null, "The visitor's panel exposes a refresh control")
	if refresh == null:
		return
	refresh.pressed.emit()
	var refreshed: Dictionary = await _next_event(_events, before, "visitor refresh")
	_expect(bool(refreshed.get("ok", false)),
		"Refreshing the visitor panel is answered by the authority")
	_expect(_public_text().contains("已结案（closed）"),
		"The visitor refresh re-renders the authoritative public row")
	_expect(_bytes(_disputes_path()) == bytes_before,
		"Refreshing the visitor panel writes no authority document")
	var closes_before: int = closes
	dispute_panel.close_panel()
	await process_frame
	_expect(not dispute_panel.is_open() and closes == closes_before + 1,
		"Closing the visitor panel hides it and emits one close signal")
	_expect(_bytes(_disputes_path()) == bytes_before,
		"Closing the visitor panel writes no authority document")


# ------------------------------------------------------------------- clients

func _open_client(code: String, player_id: String, display_name: String,
		secret_text: String) -> bool:
	_ready = false
	_refusals.clear()
	_events.clear()
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
			_now: float) -> void:
		_ready = true)
	client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
	client.lost.connect(func(reason: String) -> void: _refusals.append(reason))
	client.dispute_result.connect(dispute_panel.apply_result)
	client.dispute_result.connect(_on_dispute_result)
	var secret: PackedByteArray = Marshalls.base64_to_raw(secret_text) \
		if not player_id.is_empty() else PackedByteArray()
	if not client.start(code, player_id, display_name, secret):
		return false
	var arrived: bool = await _wait(func() -> bool:
		return (_ready and client.joined) or not _refusals.is_empty(), 20000)
	if not arrived or not _ready or not client.joined:
		_expect(false, "The client joins: refusals=%s" % str(_refusals))
		return false
	return true


func _close_client() -> void:
	if client != null:
		if is_instance_valid(client):
			client.close()
			client.queue_free()
		client = null
	_events.clear()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout


func _on_dispute_result(_request_id: String, payload: Dictionary) -> void:
	_events.append(payload.duplicate(true))


func _next_event(events: Array, before: int, label: String,
		timeout_ms: int = 15000) -> Dictionary:
	var arrived: bool = await _wait(func() -> bool: return events.size() > before,
		timeout_ms)
	if not arrived:
		_expect(false, "A %s reply arrives" % label)
		return {}
	var value: Variant = events[events.size() - 1]
	if not value is Dictionary:
		return {}
	return (value as Dictionary).duplicate(true)


# --------------------------------------------------------------- state readers

func _state(reply: Dictionary) -> Dictionary:
	var value: Variant = reply.get("state")
	return value if value is Dictionary else {}


func _view_case(view: Dictionary) -> Dictionary:
	var rows: Variant = view.get("cases")
	if rows is Array:
		for row_value: Variant in rows:
			if row_value is Dictionary \
					and str((row_value as Dictionary).get("case_id", "")) == CASE_ID:
				return (row_value as Dictionary).duplicate(true)
	return {}


func _role_ids(state: Dictionary, key: String) -> Array:
	var roles_value: Variant = state.get("authority_roles")
	if not roles_value is Dictionary:
		return []
	var ids_value: Variant = (roles_value as Dictionary).get(key)
	return ids_value.duplicate() if ids_value is Array else []


func _audit_actions(row: Dictionary) -> Array:
	var actions: Array = []
	var audit_value: Variant = row.get("audit")
	if audit_value is Array:
		for entry_value: Variant in audit_value:
			if entry_value is Dictionary:
				actions.append(str((entry_value as Dictionary).get("action", "")))
	return actions


func _dict(value: Variant) -> Dictionary:
	return value.duplicate(true) if value is Dictionary else {}


func _string_array(value: Variant) -> Array:
	var output: Array = []
	if value is Array:
		for entry: Variant in value:
			output.append(str(entry))
	return output


## The view carries the live authority clock, which advances between replies.
## Everything else must survive a refused write unchanged.
func _same_view(a: Dictionary, b: Dictionary) -> bool:
	var left: Dictionary = a.duplicate(true)
	var right: Dictionary = b.duplicate(true)
	left.erase("now_utc")
	right.erase("now_utc")
	return JSON.stringify(left) == JSON.stringify(right)


# ------------------------------------------------------------------ panel UI

func _panel_status(panel: Control) -> String:
	var label: Label = panel.find_child("Status", true, false) as Label
	return label.text if label != null else ""


## The read-only authority line, distinct from the message line above.
func _authority_status_text() -> String:
	var label: Label = dispute_panel.find_child("AuthorityStatus", true, false) as Label
	return label.text if label != null else ""


func _case_text() -> String:
	var label: Label = _case_label()
	return label.text if label != null else ""


func _case_label() -> Label:
	return dispute_panel.find_child("Case_" + CASE_ID, true, false) as Label


func _public_text() -> String:
	var label: Label = dispute_panel.find_child(
		"Public_" + CASE_ID, true, false) as Label
	return label.text if label != null else ""


func _list(node_name: String) -> VBoxContainer:
	return dispute_panel.find_child(node_name, true, false) as VBoxContainer


func _has_text(node: Node, fragment: String) -> bool:
	if node == null:
		return false
	for child: Node in node.get_children():
		if child is Label and (child as Label).text.contains(fragment):
			return true
		if _has_text(child, fragment):
			return true
	return false


# --------------------------------------------------------------- server/plumbing

func _start_authority() -> bool:
	port = _free_port()
	_expect(port > 0, "A free loopback port is available for the authority")
	if port <= 0:
		return false
	url = "wss://127.0.0.1:%d" % port
	var args: Array[String] = [
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % START, "--run-seconds=0", "--join-url=" + url,
		"--host-player=" + PLAYER_A,
	]
	log_path = world_dir.path_join("server-%d.log" % Time.get_ticks_usec())
	log_captured = OS.get_name() != "Windows"
	if log_captured:
		var command: String = "exec " + _shell_quote(OS.get_executable_path())
		for argument: String in args:
			command += " " + _shell_quote(argument)
		command += " > " + _shell_quote(log_path) + " 2>&1"
		server_pid = OS.create_process("/bin/sh", PackedStringArray(["-c", command]), false)
	else:
		server_pid = OS.create_process(OS.get_executable_path(),
			PackedStringArray(args), false)
	_expect(server_pid > 0, "The authority process starts")
	if server_pid <= 0:
		return false
	var running: bool = await _wait(func() -> bool:
		var status: Dictionary = _status()
		return str(status.get("state", "")) == "running" \
			and int(status.get("pid", 0)) == server_pid, 20000)
	_expect(running, "The authority reports ready")
	if not running:
		return false
	var status: Dictionary = _status()
	_expect(str(status.get("world_id", "")) == WORLD,
		"The status file names the world the authority serves")
	_expect(str(status.get("host_player", "")) == PLAYER_A,
		"The status file records the startup host")
	if log_captured:
		var appeared: bool = await _wait(func() -> bool:
			return _read_text(log_path).contains("WORLD_SERVER_READY"), 3000)
		_expect(appeared, "The authority log reports readiness")
		var text: String = _read_text(log_path)
		_expect(not text.contains("WORLD_SERVER_ERROR"),
			"The authority log has no server error line")
		_expect(not text.contains("SCRIPT ERROR"),
			"The authority log has no script error")
	return true


func _join_codes() -> Dictionary:
	var invite_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		world_dir.path_join("invite.bin"))
	var pem: String = FileAccess.get_file_as_bytes(
		world_dir.path_join("server.crt")).get_string_from_ascii()
	var member_code: String = WorldJoinCode.encode(WorldInvite.make(
		"server-invite", invite_bytes, WorldInvite.MEMBER, WORLD, 0.0, false),
		url, pem, "localhost")
	var visitor_code: String = FileAccess.get_file_as_string(
		world_dir.path_join("visitor-join-code.txt")).strip_edges()
	return {"member": member_code, "visitor": visitor_code}


func _stop_server() -> void:
	if server_pid <= 0:
		return
	var marker := FileAccess.open(world_dir.path_join("stop"), FileAccess.WRITE)
	if marker != null:
		marker.store_string("stop")
		marker.close()
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline and OS.is_process_running(server_pid):
		await create_timer(0.05).timeout
	var stopped: bool = not OS.is_process_running(server_pid)
	_expect(stopped, "The authority process shuts down cleanly")
	var status: Dictionary = _status()
	_expect(str(status.get("state", "")) == "stopped",
		"The shutdown is recorded in the status file")
	if not stopped:
		OS.kill(server_pid)
	if log_captured:
		var appeared: bool = await _wait(func() -> bool:
			return _read_text(log_path).contains("WORLD_SERVER_STOP"), 3000)
		_expect(appeared, "The authority log reports a graceful stop")
		_expect(not _read_text(log_path).contains("SCRIPT ERROR"),
			"The stopped authority log has no script error")
	server_pid = 0


func _status() -> Dictionary:
	return _read_json(world_dir.path_join("server-status.json"))


func _disputes_path() -> String:
	return world_dir.path_join(DisputesStore.MAIN)


func _stored_document() -> Dictionary:
	return _read_json(_disputes_path())


func _stored_case() -> Dictionary:
	var state_value: Variant = _stored_document().get("state")
	if not state_value is Dictionary:
		return {}
	var cases_value: Variant = (state_value as Dictionary).get("cases")
	if not cases_value is Dictionary:
		return {}
	var row_value: Variant = (cases_value as Dictionary).get(CASE_ID)
	return (row_value as Dictionary).duplicate(true) if row_value is Dictionary else {}


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _read_text(path: String) -> String:
	return FileAccess.get_file_as_string(path) \
		if FileAccess.file_exists(path) else ""


func _bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) \
		if FileAccess.file_exists(path) else PackedByteArray()


func _wait(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _free_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0, "127.0.0.1") != OK:
		return 0
	var chosen: int = probe.get_local_port()
	probe.stop()
	return chosen


func _shell_quote(text: String) -> String:
	return "'" + text.replace("'", "'\\''") + "'"


func _new_command_id() -> String:
	return "dispute-panel-%d-%d" % [Time.get_ticks_usec(), checks]


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("DISPUTE_PANELS_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
