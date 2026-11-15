extends SceneTree
## M12-04 dispute compensation over the real wire: the real `DisputePanel` is
## mounted the way `main.gd` wires it, and every view and reply comes from a real
## `world_server.gd` over loopback WSS through a real `WorldClient` (RPC 23/24).
##
## The startup host A (the only roster administrator) rules a `compensation`
## case through the panel: select the outcome, fill the amount, confirm, and the
## authority moves cash from the sanctioned party to the filer. The persisted
## `disputes.json` carries the ruled case and `enforcement[case].paid = true`;
## the farm ledger carries one balanced `dispute_compensate_<case>` entry, the
## two cash balances move by exactly the amount, `economy_issued()` and total
## cash stay fixed, and `economy_reconcile()` still passes.
##
## Re-sending the same ruling command returns `duplicate` without a second
## transfer. A second case whose compensation exceeds the payer's balance is
## refused with the authority's own reason text and stays `accepted` with no
## cash moved. A non-administrator member and a named visitor both get
## `forbidden`. After a graceful stop and restart, the documents and balances
## are intact and the same command still replays without transferring again.
##
## Everything runs under .local/verification/dispute-compensation-network-<ticks>/.

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const Disputes = preload("res://world/dispute_state.gd")
const DisputesStore = preload("res://world/disputes_store.gd")
const DisputePanel = preload("res://ui/dispute_panel.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const FarmState = preload("res://farm/farm_state.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
## One installation credential per identity (ADR-029); the one-time account
## grant is keyed by the credential, so every named player has its own secret.
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const PLAYER_SECRET_T: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtNDQ="
const PLAYER_SECRET_VISITOR: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMzM="
const START: float = 1800000000.0
const WORLD: String = "world-dispute-compensation-network"
const PLAYER_A: String = "player_00000000000000000000000000000111"
const PLAYER_B: String = "player_00000000000000000000000000000112"
const PLAYER_T: String = "player_00000000000000000000000000000113"
const VISITOR_ID: String = "player_00000000000000000000000000000114"
const NAME_A: String = "阿管"
const NAME_B: String = "阿诉"
const NAME_T: String = "阿偿"
const VISITOR_NAME: String = "旁听者"
const CASE_COMP: String = "case_comp_network_1"
const CASE_POOR: String = "case_comp_network_poor"
const EVENT_T: String = "event_comp_network_open_t"
const EVENT_B: String = "event_comp_network_open_b"
const COMP_AMOUNT: int = 30
const POOR_AMOUNT: int = 100000
const COMP_REASON: String = "证据成立，补偿三十"
const POOR_REASON: String = "要求超额补偿"
const MEMBER_RULE_REASON: String = "成员越权补偿"
const OPENING_GRANT: int = 120

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var url: String = ""
var log_path: String = ""
var checks: int = 0
var failures: Array[String] = []
var closes: int = 0

var client: WorldClient
var dispute_panel: DisputePanel
var _ready: bool = false
var _refusals: Array[String] = []
var _events: Array = []
var _command_pending: Dictionary = {}
## The exact ruling request the panel emitted, kept so later phases can resend
## the same command id and payload after a reconnect and after a restart.
var _last_rule: Dictionary = {}
## The successful compensation ruling specifically; `_last_rule` is replaced by
## later (refused) attempts, but this one must survive to prove the replay.
var _compensation_rule: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/dispute-compensation-network-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	root.size = Vector2i(1280, 720)
	_mount_panel()
	await process_frame

	if not await _start_authority(START):
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

	await _phase_target_account(codes)
	await _close_client()
	await _phase_filer_files(codes)
	await _close_client()
	await _phase_admin_compensates(codes)
	await _close_client()
	await _phase_member_refused(codes)
	await _close_client()
	await _phase_visitor_refused(codes)
	await _close_client()

	var disputes_before_stop: PackedByteArray = _bytes(_disputes_path())
	var balances_before_stop: Dictionary = _measure("before stop")
	await _stop_server()
	if not await _start_authority(START + 3600.0):
		_finish()
		return
	var restart_codes: Dictionary = _join_codes()
	await _phase_restart(restart_codes, disputes_before_stop, balances_before_stop)
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
	if action == "rule":
		_last_rule = {"request_id": request_id, "args": payload.duplicate(true)}
	if client == null or not client.request_dispute(request_id, action, payload):
		dispute_panel.show_status("还没有连上世界，纠纷操作没有发出去。")


func _dispute_refresh() -> void:
	if client == null or not client.request_dispute("dispute-state", "state"):
		dispute_panel.show_status("还没有连上世界，纠纷没有刷新。")


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


## A manual request (not generated by the panel) that waits for its own reply.
func _request_dispute(request_id: String, action: String,
		args: Dictionary = {}) -> Dictionary:
	var before: int = _events.size()
	if client == null or not client.request_dispute(request_id, action, args):
		_expect(false, "The %s request %s is sent" % [action, request_id])
		return {}
	return await _next_event(_events, before, "%s request %s" % [action, request_id])


# ------------------------------------------------------------------ phases

func _phase_target_account(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_T, NAME_T,
		PLAYER_SECRET_T), "The sanctioned party joins as a named member over WSS")
	if client == null or not client.joined:
		return
	var opened: Dictionary = await _submit(FarmCommand.make_account_open(
		EVENT_T, client.world_time()))
	_expect(bool(opened.get("ok", false)) and not bool(opened.get("duplicate", true)),
		"The sanctioned party opens a real cash account (%s)"
			% str(opened.get("reason", "")))
	var measured: Dictionary = _measure("target account")
	_expect(int(measured.get("target", -1)) == OPENING_GRANT,
		"The sanctioned party holds exactly the opening grant")
	_expect(int(measured.get("issued", -1)) == OPENING_GRANT,
		"The opening grant is the only issued cash so far")


func _phase_filer_files(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The filing member joins as a named member over WSS")
	if client == null or not client.joined:
		return
	var opened: Dictionary = await _submit(FarmCommand.make_account_open(
		EVENT_B, client.world_time()))
	_expect(bool(opened.get("ok", false)) and not bool(opened.get("duplicate", true)),
		"The filing member opens a real cash account (%s)"
			% str(opened.get("reason", "")))
	var measured: Dictionary = _measure("filer account")
	_expect(int(measured.get("filer", -1)) == OPENING_GRANT
			and int(measured.get("target", -1)) == OPENING_GRANT,
		"Both parties start at the 120 opening grant")

	var reply: Dictionary = await _open_panel("filer")
	var state: Dictionary = _state(reply)
	_expect(bool(state.get("available", false)),
		"The filer's panel sees the real dispute authority")
	_expect(str(state.get("viewer", "")) == PLAYER_B
			and not bool(state.get("is_authority", true)),
		"The filer's view is non-authoritative and names the filer")

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
		"The filer's panel exposes the filing fields")
	if file_case == null or file_button == null:
		return
	for pair: Array in [[CASE_COMP, EVENT_T], [CASE_POOR, EVENT_T]]:
		var case_id: String = str(pair[0])
		file_case.text = case_id
		file_against.text = PLAYER_T
		file_events.text = str(pair[1])
		var before: int = _events.size()
		file_button.pressed.emit()
		var filed: Dictionary = await _next_event(_events, before, "file " + case_id)
		_expect(bool(filed.get("ok", false))
				and not bool(filed.get("duplicate", true))
				and str(filed.get("action", "")) == "file"
				and str(filed.get("status", "")) == Disputes.STATUS_FILED,
			"The filer's %s lands on the authority as filed (%s)"
				% [case_id, str(filed.get("reason", ""))])
		var stored: Dictionary = _stored_case(case_id)
		_expect(str(stored.get("filed_by", "")) == PLAYER_B
				and str(stored.get("against", "")) == PLAYER_T
				and str(stored.get("status", "")) == Disputes.STATUS_FILED,
			"disputes.json persists %s with both parties" % case_id)
	_expect(_panel_status(dispute_panel) == "案件已立案。",
		"The panel reports the second filing as landed")


func _phase_admin_compensates(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host administrator joins to rule")
	if client == null or not client.joined:
		return
	var reply: Dictionary = await _open_panel("admin compensation")
	var state: Dictionary = _state(reply)
	_expect(bool(state.get("available", false))
			and bool(state.get("is_authority", false))
			and str(state.get("viewer", "")) == PLAYER_A,
		"The administrator's view reports the authoritative roster")

	var admin_case: LineEdit = dispute_panel.find_child(
		"AdminCaseId", true, false) as LineEdit
	var accept_button: Button = dispute_panel.find_child(
		"Accept", true, false) as Button
	_expect(admin_case != null and accept_button != null,
		"The administrator's panel exposes the case and accept controls")
	if admin_case == null or accept_button == null:
		return
	admin_case.text = CASE_COMP
	var before: int = _events.size()
	accept_button.pressed.emit()
	var accepted: Dictionary = await _next_event(_events, before, "accept compensation")
	_expect(bool(accepted.get("ok", false))
			and str(accepted.get("status", "")) == Disputes.STATUS_ACCEPTED,
		"The administrator accepts the compensation case through the panel")

	var measured_before: Dictionary = _measure("before compensation")
	var filer_before: int = int(measured_before.get("filer", -1))
	var target_before: int = int(measured_before.get("target", -1))
	var issued_before: int = int(measured_before.get("issued", -1))
	var total_before: int = int(measured_before.get("total", -1))
	var entries_before: int = (measured_before.get("entries", []) as Array).size()
	_expect(bool(measured_before.get("reconcile_ok", false)),
		"The ledger reconciles before the compensation")

	# The amount field is part of the real panel: hidden until the outcome is
	# compensation, then required and forwarded with the ruling.
	var rule_outcome: OptionButton = dispute_panel.find_child(
		"RuleOutcome", true, false) as OptionButton
	var rule_amount: LineEdit = dispute_panel.find_child(
		"CompensationAmount", true, false) as LineEdit
	var rule_reason: LineEdit = dispute_panel.find_child(
		"RuleReason", true, false) as LineEdit
	var rule_button: Button = dispute_panel.find_child(
		"Rule", true, false) as Button
	var confirm: ConfirmationDialog = dispute_panel.find_child(
		"DisputeConfirm", true, false) as ConfirmationDialog
	_expect(rule_outcome != null and rule_amount != null and rule_reason != null
			and rule_button != null and confirm != null,
		"The administrator's panel exposes the compensation ruling controls")
	if rule_outcome == null or rule_amount == null or rule_button == null \
			or confirm == null:
		return
	_expect(not rule_amount.is_visible_in_tree(),
		"The compensation amount starts hidden")
	var compensation_index: int = _outcome_index(rule_outcome, "compensation")
	_expect(compensation_index >= 0,
		"The panel offers the compensation outcome")
	if compensation_index < 0:
		return
	rule_outcome.select(compensation_index)
	rule_outcome.item_selected.emit(compensation_index)
	_expect(rule_amount.is_visible_in_tree(),
		"Selecting compensation reveals the amount field")
	rule_amount.text = str(COMP_AMOUNT)
	rule_reason.text = COMP_REASON

	var bytes_before: PackedByteArray = _bytes(_disputes_path())
	var view_before: Dictionary = dispute_panel.view.duplicate(true)
	before = _events.size()
	rule_button.pressed.emit()
	await process_frame
	_expect(_events.size() == before and confirm.visible,
		"Clicking rule only opens the confirmation")
	_expect(confirm.dialog_text.contains("补偿")
			and confirm.dialog_text.contains("转出"),
		"The compensation confirmation warns that cash will be transferred")
	confirm.get_cancel_button().pressed.emit()
	await process_frame
	_expect(_events.size() == before and not confirm.visible,
		"Cancelling the compensation confirmation sends nothing")
	_expect(_same_view(dispute_panel.view, view_before)
			and _bytes(_disputes_path()) == bytes_before,
		"A cancelled compensation leaves the view and document unchanged")

	before = _events.size()
	rule_button.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	var ruled: Dictionary = await _next_event(_events, before, "compensation rule")
	_expect(bool(ruled.get("ok", false))
			and not bool(ruled.get("duplicate", true))
			and str(ruled.get("action", "")) == "rule"
			and str(ruled.get("status", "")) == Disputes.STATUS_RULED,
		"The administrator's compensation rule lands on the authority (%s)"
			% str(ruled.get("reason", "")))
	_expect(_panel_status(dispute_panel) == "裁定已记录。",
		"The panel reports the recorded ruling")
	_expect(not _last_rule.is_empty()
			and int((_last_rule.get("args", {}) as Dictionary).get("amount", 0))
				== COMP_AMOUNT,
		"The panel forwarded the amount with the ruling command")
	_compensation_rule = _last_rule.duplicate(true)

	var stored: Dictionary = _stored_case(CASE_COMP)
	var ruling: Dictionary = _dict(stored.get("ruling"))
	_expect(str(stored.get("status", "")) == Disputes.STATUS_RULED
			and str(ruling.get("outcome", "")) == "compensation"
			and str(ruling.get("by", "")) == PLAYER_A
			and str(ruling.get("reason", "")) == COMP_REASON,
		"disputes.json persists the compensation ruling and its author")
	var enforcement: Dictionary = _stored_enforcement(CASE_COMP)
	_expect(int(enforcement.get("amount", 0)) == COMP_AMOUNT
			and bool(enforcement.get("paid", false))
			and float(enforcement.get("at_utc", 0.0)) > 0.0,
		"disputes.json records the compensation as paid exactly once")
	_expect(_case_text(CASE_COMP).contains("已裁定（ruled）")
			and _case_text(CASE_COMP).contains("compensation"),
		"The administrator's panel renders the authoritative compensation ruling")

	var measured_after: Dictionary = _measure("after compensation")
	var filer_after: int = int(measured_after.get("filer", -1))
	var target_after: int = int(measured_after.get("target", -1))
	_expect(filer_after == filer_before + COMP_AMOUNT,
		"The filer receives exactly the compensation amount")
	_expect(target_after == target_before - COMP_AMOUNT,
		"The sanctioned party pays exactly the compensation amount")
	_expect(int(measured_after.get("issued", -1)) == issued_before,
		"The compensation issues no new cash")
	_expect(int(measured_after.get("total", -1)) == total_before,
		"The compensation conserves total cash")
	_expect(bool(measured_after.get("reconcile_ok", false)),
		"The ledger reconciles after the compensation")

	var entries: Array = measured_after.get("entries", []) as Array
	var entry: Dictionary = _entry(entries, DisputesStore.COMPENSATION_EVENT_PREFIX
		+ CASE_COMP)
	_expect(str(entry.get("kind", "")) == "pay",
		"The compensation is a balanced pay ledger entry")
	var lines: Array = entry.get("lines", []) if entry.get("lines") is Array else []
	_expect(lines.size() == 2
			and _line_matches(lines, "account:" + PLAYER_B, COMP_AMOUNT, 0)
			and _line_matches(lines, "account:" + PLAYER_T, 0, COMP_AMOUNT),
		"The ledger debits the filer and credits the sanctioned party")
	_expect(entries.size() == entries_before + 1,
		"The compensation adds exactly one ledger entry")

	# Resend the exact same ruling command: the persisted journal must answer
	# duplicate and move no cash again.
	var disputes_after_rule: PackedByteArray = _bytes(_disputes_path())
	var farm_after_rule: PackedByteArray = _bytes(_farm_path())
	var replay: Dictionary = await _request_dispute(
		str(_compensation_rule.get("request_id", "")), "rule",
		_dict(_compensation_rule.get("args")))
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Resending the same ruling command returns duplicate")
	_expect(_panel_status(dispute_panel) == "这条纠纷操作已经执行过。",
		"The panel reports the duplicate ruling from the authority")
	var measured_replay: Dictionary = _measure("after duplicate")
	_expect(int(measured_replay.get("filer", -1)) == filer_after
			and int(measured_replay.get("target", -1)) == target_after
			and int(measured_replay.get("issued", -1)) == issued_before,
		"A duplicate ruling moves no cash and issues nothing")
	_expect((measured_replay.get("entries", []) as Array).size() == entries_before + 1,
		"A duplicate ruling adds no ledger entry")
	_expect(_bytes(_disputes_path()) == disputes_after_rule
			and _bytes(_farm_path()) == farm_after_rule,
		"A duplicate ruling leaves both documents byte-identical")

	# A second case whose compensation exceeds the payer's available cash is
	# refused; the case stays accepted and no cash or marker is written.
	admin_case.text = CASE_POOR
	before = _events.size()
	accept_button.pressed.emit()
	var poor_accepted: Dictionary = await _next_event(_events, before, "accept poor")
	_expect(bool(poor_accepted.get("ok", false))
			and str(poor_accepted.get("status", "")) == Disputes.STATUS_ACCEPTED,
		"The administrator accepts the unaffordable case")
	rule_amount.text = str(POOR_AMOUNT)
	rule_reason.text = POOR_REASON
	var bytes_before_poor: PackedByteArray = _bytes(_disputes_path())
	before = _events.size()
	rule_button.pressed.emit()
	await process_frame
	confirm.get_ok_button().pressed.emit()
	var refused: Dictionary = await _next_event(_events, before, "unaffordable rule")
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "compensation_insufficient",
		"An unaffordable compensation is refused by the authority")
	var reason_text: String = str(refused.get("reason_text", ""))
	_expect(not reason_text.is_empty() and reason_text.contains("不足"),
		"The refusal carries the authority's insufficient-cash reason text")
	_expect(_panel_status(dispute_panel) == reason_text,
		"The panel shows the authority's refusal text verbatim")
	_expect(str(_stored_case(CASE_POOR).get("status", "")) == Disputes.STATUS_ACCEPTED,
		"The refused case stays accepted")
	_expect(_stored_enforcement(CASE_POOR).is_empty(),
		"The refused case records no paid marker")
	_expect(_bytes(_disputes_path()) == bytes_before_poor,
		"The refused ruling writes no authority document")
	var measured_refused: Dictionary = _measure("after refusal")
	_expect(int(measured_refused.get("filer", -1)) == filer_after
			and int(measured_refused.get("target", -1)) == target_after
			and int(measured_refused.get("issued", -1)) == issued_before
			and bool(measured_refused.get("reconcile_ok", false)),
		"A refused compensation moves no cash and still reconciles")


func _phase_member_refused(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The filer rejoins to attempt an unauthorized ruling")
	if client == null or not client.joined:
		return
	var reply: Dictionary = await _open_panel("member refusal")
	var state: Dictionary = _state(reply)
	_expect(not bool(state.get("is_authority", true)),
		"The filer's view is still non-authoritative")
	var measured_before: Dictionary = _measure("before member refusal")
	var bytes_before: PackedByteArray = _bytes(_disputes_path())
	var refused: Dictionary = await _send_rule(dispute_panel, CASE_POOR,
		"compensation", 10, MEMBER_RULE_REASON, "member compensation refusal")
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "forbidden",
		"A non-administrator member's compensation is refused as forbidden")
	var reason_text: String = str(refused.get("reason_text", ""))
	_expect(not reason_text.is_empty()
			and _panel_status(dispute_panel) == reason_text,
		"The member's panel shows the authority refusal text verbatim")
	var case_row: Dictionary = _view_case(_state(refused), CASE_POOR)
	_expect(str(case_row.get("status", "")) == Disputes.STATUS_ACCEPTED,
		"The unauthorized attempt leaves the case accepted")
	var measured_after: Dictionary = _measure("after member refusal")
	_expect(int(measured_after.get("filer", -1))
				== int(measured_before.get("filer", -2))
			and int(measured_after.get("target", -1))
				== int(measured_before.get("target", -2)),
		"The unauthorized member attempt moves no cash")
	_expect(_bytes(_disputes_path()) == bytes_before,
		"The unauthorized member attempt writes no authority document")


func _phase_visitor_refused(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("visitor", "")), VISITOR_ID, VISITOR_NAME,
		PLAYER_SECRET_VISITOR), "A named visitor joins with the visitor code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")
	var reply: Dictionary = await _open_panel("visitor refusal")
	var state: Dictionary = _state(reply)
	_expect(bool(state.get("available", false))
			and not bool(state.get("is_authority", true)),
		"The visitor may read but not administer the dispute authority")
	_expect((state.get("cases", []) as Array).is_empty()
			and (state.get("public", []) as Array).size() == 2,
		"The visitor sees only the two public status rows")
	var measured_before: Dictionary = _measure("before visitor refusal")
	var bytes_before: PackedByteArray = _bytes(_disputes_path())
	var refused: Dictionary = await _send_rule(dispute_panel, CASE_POOR,
		"compensation", 10, MEMBER_RULE_REASON, "visitor compensation refusal")
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "forbidden",
		"A visitor's compensation is refused as forbidden")
	var reason_text: String = str(refused.get("reason_text", ""))
	_expect(not reason_text.is_empty()
			and _panel_status(dispute_panel) == reason_text,
		"The visitor's panel shows the authority refusal text verbatim")
	var measured_after: Dictionary = _measure("after visitor refusal")
	_expect(int(measured_after.get("filer", -1))
				== int(measured_before.get("filer", -2))
			and int(measured_after.get("target", -1))
				== int(measured_before.get("target", -2))
			and int(measured_after.get("issued", -1))
				== int(measured_before.get("issued", -2)),
		"The visitor's refused compensation moves no cash")
	_expect(_bytes(_disputes_path()) == bytes_before,
		"The visitor's refused compensation writes no authority document")


func _phase_restart(codes: Dictionary, disputes_before_stop: PackedByteArray,
		balances_before_stop: Dictionary) -> void:
	var filer_expected: int = int(balances_before_stop.get("filer", -1))
	var target_expected: int = int(balances_before_stop.get("target", -1))
	var issued_expected: int = int(balances_before_stop.get("issued", -1))
	var total_expected: int = int(balances_before_stop.get("total", -1))
	_expect(not disputes_before_stop.is_empty(),
		"The compensation ruling is persisted before the restart")
	_expect(_bytes(_disputes_path()) == disputes_before_stop,
		"The restart loads disputes.json without rewriting it")
	var stored_after_stop: Dictionary = _stored_case(CASE_COMP)
	var enforcement: Dictionary = _stored_enforcement(CASE_COMP)
	_expect(str(stored_after_stop.get("status", "")) == Disputes.STATUS_RULED
			and bool(enforcement.get("paid", false))
			and int(enforcement.get("amount", 0)) == COMP_AMOUNT,
		"The ruled case and its paid marker survive the restart")
	var measured_restart: Dictionary = _measure("after restart")
	_expect(int(measured_restart.get("filer", -1)) == filer_expected
			and int(measured_restart.get("target", -1)) == target_expected,
		"Both compensation balances survive the restart exactly once")
	_expect(int(measured_restart.get("issued", -1)) == issued_expected
			and int(measured_restart.get("total", -1)) == total_expected
			and bool(measured_restart.get("reconcile_ok", false)),
		"Issued cash, total cash and the ledger survive the restart")
	var compensation_entries: int = _entry_count(
		measured_restart.get("entries", []) as Array,
		DisputesStore.COMPENSATION_EVENT_PREFIX + CASE_COMP)
	_expect(compensation_entries == 1,
		"Exactly one compensation ledger entry exists after the restart")

	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The administrator rejoins the restarted authority")
	if client == null or not client.joined:
		return
	var reply: Dictionary = await _open_panel("restart admin")
	var state: Dictionary = _state(reply)
	_expect(bool(state.get("is_authority", false))
			and str(_view_case(state, CASE_COMP).get("status", ""))
				== Disputes.STATUS_RULED,
		"The administrator sees the ruled case after the restart")
	_expect(_case_text(CASE_COMP).contains("已裁定（ruled）"),
		"The restarted panel renders the authoritative compensation ruling")

	var disputes_before_replay: PackedByteArray = _bytes(_disputes_path())
	var farm_before_replay: PackedByteArray = _bytes(_farm_path())
	var replay: Dictionary = await _request_dispute(
		str(_compensation_rule.get("request_id", "")), "rule",
		_dict(_compensation_rule.get("args")))
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"The same ruling command still replays after the restart")
	var measured_replay: Dictionary = _measure("after restart replay")
	_expect(int(measured_replay.get("filer", -1)) == filer_expected
			and int(measured_replay.get("target", -1)) == target_expected
			and int(measured_replay.get("issued", -1)) == issued_expected,
		"The post-restart replay transfers no cash a second time")
	_expect(_entry_count(measured_replay.get("entries", []) as Array,
			DisputesStore.COMPENSATION_EVENT_PREFIX + CASE_COMP) == 1,
		"The post-restart replay adds no compensation entry")
	_expect(_bytes(_disputes_path()) == disputes_before_replay
			and _bytes(_farm_path()) == farm_before_replay,
		"The post-restart replay leaves both documents byte-identical")


# -------------------------------------------------------------- panel helpers

## Selects an outcome, fills the amount and reason, confirms, and waits for the
## reply. Used for the refusals where the only evidence is the authority answer.
func _send_rule(panel: Control, case_id: String, outcome: String, amount: int,
		reason: String, label: String) -> Dictionary:
	var admin_case: LineEdit = panel.find_child("AdminCaseId", true, false) as LineEdit
	var rule_outcome: OptionButton = panel.find_child(
		"RuleOutcome", true, false) as OptionButton
	var rule_amount: LineEdit = panel.find_child(
		"CompensationAmount", true, false) as LineEdit
	var rule_reason: LineEdit = panel.find_child(
		"RuleReason", true, false) as LineEdit
	var rule_button: Button = panel.find_child("Rule", true, false) as Button
	var confirm: ConfirmationDialog = panel.find_child(
		"DisputeConfirm", true, false) as ConfirmationDialog
	_expect(admin_case != null and rule_outcome != null and rule_amount != null
			and rule_reason != null and rule_button != null and confirm != null,
		"The panel exposes the ruling controls (%s)" % label)
	if admin_case == null or rule_outcome == null or rule_amount == null \
			or rule_reason == null or rule_button == null or confirm == null:
		return {}
	var index: int = _outcome_index(rule_outcome, outcome)
	_expect(index >= 0, "The panel offers the %s outcome (%s)" % [outcome, label])
	if index < 0:
		return {}
	admin_case.text = case_id
	rule_outcome.select(index)
	rule_outcome.item_selected.emit(index)
	rule_amount.text = str(amount)
	rule_reason.text = reason
	var before: int = _events.size()
	rule_button.pressed.emit()
	await process_frame
	_expect(_events.size() == before and confirm.visible,
		"The ruling click only opens the confirmation (%s)" % label)
	confirm.get_ok_button().pressed.emit()
	return await _next_event(_events, before, label)


func _outcome_index(option: OptionButton, outcome: String) -> int:
	for index: int in option.item_count:
		if str(option.get_item_metadata(index)) == outcome:
			return index
	return -1


# ------------------------------------------------------------ state readers

func _measure(label: String) -> Dictionary:
	var document: Dictionary = _farm_doc()
	var farm := FarmState.new()
	var restored: bool = not document.is_empty() and farm.restore_snapshot(document)
	_expect(restored, "The authoritative farm document restores (%s)" % label)
	if not restored:
		return {}
	var reconciled: Dictionary = farm.economy_reconcile()
	return {
		"filer": farm.economy_cash(PLAYER_B),
		"target": farm.economy_cash(PLAYER_T),
		"issued": farm.economy_issued(),
		"total": farm.economy_total_cash(),
		"reconcile_ok": bool(reconciled.get("ok", false)),
		"entries": farm.economy_ledger_entries(),
	}


func _entry(entries: Array, event_id: String) -> Dictionary:
	for value: Variant in entries:
		if value is Dictionary \
				and str((value as Dictionary).get("event_id", "")) == event_id:
			return (value as Dictionary).duplicate(true)
	return {}


func _entry_count(entries: Array, event_id: String) -> int:
	var count: int = 0
	for value: Variant in entries:
		if value is Dictionary \
				and str((value as Dictionary).get("event_id", "")) == event_id:
			count += 1
	return count


func _line_matches(lines: Array, account: String, debit: int, credit: int) -> bool:
	for value: Variant in lines:
		if value is Dictionary \
				and str((value as Dictionary).get("account", "")) == account \
				and int((value as Dictionary).get("debit", 0)) == debit \
				and int((value as Dictionary).get("credit", 0)) == credit:
			return true
	return false


func _state(reply: Dictionary) -> Dictionary:
	var value: Variant = reply.get("state")
	return value if value is Dictionary else {}


func _view_case(view: Dictionary, case_id: String) -> Dictionary:
	var rows: Variant = view.get("cases")
	if rows is Array:
		for row_value: Variant in rows:
			if row_value is Dictionary \
					and str((row_value as Dictionary).get("case_id", "")) == case_id:
				return (row_value as Dictionary).duplicate(true)
	return {}


func _dict(value: Variant) -> Dictionary:
	return value.duplicate(true) if value is Dictionary else {}


## The view carries the live authority clock, which advances between replies.
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


func _case_text(case_id: String) -> String:
	var label: Label = dispute_panel.find_child(
		"Case_" + case_id, true, false) as Label
	return label.text if label != null else ""


# --------------------------------------------------------------- clients

func _open_client(code: String, player_id: String, display_name: String,
		secret_text: String) -> bool:
	_ready = false
	_refusals.clear()
	_events.clear()
	_command_pending.clear()
	_last_rule = {}
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
	client.committed.connect(_on_committed)
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
	_command_pending.clear()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout


func _on_dispute_result(_request_id: String, payload: Dictionary) -> void:
	_events.append(payload.duplicate(true))


func _on_committed(request_id: String, payload: Dictionary) -> void:
	_command_pending[request_id] = payload


func _submit(command: Dictionary) -> Dictionary:
	var request_id: String = str(command.get("id", ""))
	_command_pending.erase(request_id)
	if client == null or not client.submit(command):
		return {"ok": false, "reason": "not_sent"}
	var arrived: bool = await _wait(func() -> bool:
		return _command_pending.has(request_id), 20000)
	if not arrived:
		_expect(false, "A command reply arrives for %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _command_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


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


# --------------------------------------------------------------- server/plumbing

func _start_authority(now: float) -> bool:
	port = _free_port()
	_expect(port > 0, "A free loopback port is available for the authority")
	if port <= 0:
		return false
	url = "wss://127.0.0.1:%d" % port
	server_pid = _spawn_server(now)
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
	if OS.get_name() != "Windows":
		var ready: bool = await _wait(func() -> bool:
			return _read_text(log_path).contains("WORLD_SERVER_READY"), 3000)
		_expect(ready, "The authority log reports readiness")
		_expect(not _read_text(log_path).contains("SCRIPT ERROR"),
			"The authority log has no script error")
	return true


func _spawn_server(now: float) -> int:
	var arguments := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % now, "--run-seconds=0", "--join-url=" + url,
		"--host-player=" + PLAYER_A,
	])
	log_path = world_dir.path_join("server-%d.log" % Time.get_ticks_usec())
	if OS.get_name() == "Windows":
		return OS.create_process(OS.get_executable_path(), arguments, false)
	var pieces: PackedStringArray = [_shell_quote(OS.get_executable_path())]
	for argument: String in arguments:
		pieces.append(_shell_quote(argument))
	var command: String = "exec " + " ".join(pieces) + " > " \
		+ _shell_quote(log_path) + " 2>&1"
	return OS.create_process("/bin/sh", PackedStringArray(["-c", command]), false)


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
	_expect(str(_status().get("state", "")) == "stopped",
		"The shutdown is recorded in the status file")
	if not stopped:
		OS.kill(server_pid)
	if OS.get_name() != "Windows":
		_expect(not _read_text(log_path).contains("SCRIPT ERROR"),
			"The stopped authority log has no script error")
	server_pid = 0


func _status() -> Dictionary:
	return _read_json(world_dir.path_join("server-status.json"))


func _disputes_path() -> String:
	return world_dir.path_join(DisputesStore.MAIN)


func _farm_path() -> String:
	return world_dir.path_join("farm.json")


func _farm_doc() -> Dictionary:
	var saved: Dictionary = _read_json(_farm_path())
	var farm: Variant = saved.get("farm")
	return farm if farm is Dictionary else {}


func _stored_document() -> Dictionary:
	return _read_json(_disputes_path())


func _stored_case(case_id: String) -> Dictionary:
	var state_value: Variant = _stored_document().get("state")
	if not state_value is Dictionary:
		return {}
	var cases_value: Variant = (state_value as Dictionary).get("cases")
	if not cases_value is Dictionary:
		return {}
	var row_value: Variant = (cases_value as Dictionary).get(case_id)
	return (row_value as Dictionary).duplicate(true) if row_value is Dictionary else {}


func _stored_enforcement(case_id: String) -> Dictionary:
	var value: Variant = _stored_document().get("enforcement")
	if not value is Dictionary:
		return {}
	var row: Variant = (value as Dictionary).get(case_id)
	return (row as Dictionary).duplicate(true) if row is Dictionary else {}


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
	return "dispute-compensation-%d-%d" % [Time.get_ticks_usec(), checks]


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("DISPUTE_COMPENSATION_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
