extends SceneTree
## M12-04 warning deadline over the real wire: the real `DisputePanel` is
## mounted the way `main.gd` wires it, and every view and reply comes from a
## real `world_server.gd` over loopback WSS through a real `WorldClient`
## (RPC 23/24).
##
## The startup host A (the only roster administrator) accepts a case through the
## panel and rules it `warning` with a reason. The persisted `disputes.json`
## carries the ruling; the authority derives the warning window from that ruling
## time and a constant, and never writes a deadline field.
##
## The filer and the warned party each reconnect and refresh through their own
## panel: the case row shows `警告 生效中｜UTC <start> 至 <expires>` computed
## from the authority's own reply. An unrelated named visitor only receives the
## public status row and has no case row, so the panel's rendered case and
## public lists contain no `警告`.
##
## Re-sending the exact same ruling command returns `duplicate`, leaves
## `disputes.json` byte-identical and keeps the derived warning unchanged. After
## a graceful stop and restart the warning is still derived from the persisted
## ruling, the document bytes are unchanged, and no new field exists.
##
## Everything runs under .local/verification/dispute-warning-network-<ticks>/.

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const Disputes = preload("res://world/dispute_state.gd")
const DisputesStore = preload("res://world/disputes_store.gd")
const DisputePanel = preload("res://ui/dispute_panel.gd")
const FarmCommand = preload("res://farm/farm_command.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
## One installation credential per identity (ADR-029).
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const PLAYER_SECRET_T: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtNDQ="
const PLAYER_SECRET_VISITOR: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMzM="
const START: float = 1800000000.0
const WORLD: String = "world-dispute-warning-network"
const PLAYER_A: String = "player_00000000000000000000000000000211"
const PLAYER_B: String = "player_00000000000000000000000000000212"
const PLAYER_T: String = "player_00000000000000000000000000000213"
const VISITOR_ID: String = "player_00000000000000000000000000000214"
const NAME_A: String = "阿管"
const NAME_B: String = "阿诉"
const NAME_T: String = "阿警"
const VISITOR_NAME: String = "旁听者"
const CASE_WARN: String = "case_warning_network_1"
const EVENT_T: String = "event_warning_network_open_t"
const WARNING_REASON: String = "证据成立，予以警告"
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
## The exact warning ruling request the panel emitted, kept so the same command
## id and payload can be replayed in the same phase.
var _warning_rule: Dictionary = {}
## The warning dictionary the authority returned with the ruling; later replies
## must derive the same window.
var _warning_after_rule: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/dispute-warning-network-%d" % Time.get_ticks_usec())
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
	await _phase_admin_rules(codes)
	await _close_client()
	await _phase_filer_refreshes(codes)
	await _close_client()
	await _phase_target_refreshes(codes)
	await _close_client()
	await _phase_visitor(codes)
	await _close_client()

	var disputes_before_stop: PackedByteArray = _bytes(_disputes_path())
	_expect(not disputes_before_stop.is_empty(),
		"The warning ruling is persisted before the restart")
	await _stop_server()
	if not await _start_authority(START + 3600.0):
		_finish()
		return
	var restart_codes: Dictionary = _join_codes()
	await _phase_restart(restart_codes, disputes_before_stop)
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
		_warning_rule = {"request_id": request_id, "args": payload.duplicate(true)}
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

## The warned party opens a real account. The resulting accepted farm command is
## the authoritative event the filer later cites; the opening grant is checked
## only so the event is clearly a real one.
func _phase_target_account(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_T, NAME_T,
		PLAYER_SECRET_T), "The warned party joins as a named member over WSS")
	if client == null or not client.joined:
		return
	var opened: Dictionary = await _submit(FarmCommand.make_account_open(
		EVENT_T, client.world_time()))
	_expect(bool(opened.get("ok", false)) and not bool(opened.get("duplicate", true)),
		"The warned party opens a real cash account (%s)"
			% str(opened.get("reason", "")))
	var farm: Dictionary = _farm_doc()
	var restored: bool = not farm.is_empty()
	_expect(restored, "The authoritative farm document restores after the opening")
	if not restored:
		return
	var FarmState = load("res://farm/farm_state.gd")
	var state = FarmState.new()
	_expect(state.restore_snapshot(farm),
		"The farm snapshot restores for the opening grant check")
	_expect(state.economy_cash(PLAYER_T) == OPENING_GRANT,
		"The warned party holds exactly the opening grant")


## The filer files a case against the warned party, citing the real event.
func _phase_filer_files(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The filing member joins as a named member over WSS")
	if client == null or not client.joined:
		return
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
	if file_case == null or file_against == null or file_events == null \
			or file_button == null:
		return
	file_case.text = CASE_WARN
	file_against.text = PLAYER_T
	file_events.text = EVENT_T
	var before: int = _events.size()
	file_button.pressed.emit()
	var filed: Dictionary = await _next_event(_events, before, "file warning case")
	_expect(bool(filed.get("ok", false))
			and not bool(filed.get("duplicate", true))
			and str(filed.get("action", "")) == "file"
			and str(filed.get("status", "")) == Disputes.STATUS_FILED,
		"The filer's warning case lands on the authority as filed (%s)"
			% str(filed.get("reason", "")))
	var stored: Dictionary = _stored_case(CASE_WARN)
	_expect(str(stored.get("filed_by", "")) == PLAYER_B
			and str(stored.get("against", "")) == PLAYER_T
			and str(stored.get("status", "")) == Disputes.STATUS_FILED,
		"disputes.json persists the warning case with both parties")
	_expect(_panel_status(dispute_panel) == "案件已立案。",
		"The panel reports the filing as landed")


## The administrator accepts the case and rules it `warning` with a reason.
func _phase_admin_rules(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host administrator joins to rule")
	if client == null or not client.joined:
		return
	var reply: Dictionary = await _open_panel("admin warning")
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
	admin_case.text = CASE_WARN
	var before: int = _events.size()
	accept_button.pressed.emit()
	var accepted: Dictionary = await _next_event(_events, before, "accept warning case")
	_expect(bool(accepted.get("ok", false))
			and str(accepted.get("status", "")) == Disputes.STATUS_ACCEPTED,
		"The administrator accepts the warning case through the panel")

	var rule_outcome: OptionButton = dispute_panel.find_child(
		"RuleOutcome", true, false) as OptionButton
	var rule_reason: LineEdit = dispute_panel.find_child(
		"RuleReason", true, false) as LineEdit
	var rule_button: Button = dispute_panel.find_child(
		"Rule", true, false) as Button
	var confirm: ConfirmationDialog = dispute_panel.find_child(
		"DisputeConfirm", true, false) as ConfirmationDialog
	_expect(rule_outcome != null and rule_reason != null
			and rule_button != null and confirm != null,
		"The administrator's panel exposes the warning ruling controls")
	if rule_outcome == null or rule_reason == null or rule_button == null \
			or confirm == null:
		return
	var warning_index: int = _outcome_index(rule_outcome, "warning")
	_expect(warning_index >= 0, "The panel offers the warning outcome")
	if warning_index < 0:
		return
	rule_outcome.select(warning_index)
	rule_outcome.item_selected.emit(warning_index)
	rule_reason.text = WARNING_REASON

	before = _events.size()
	rule_button.pressed.emit()
	await process_frame
	_expect(_events.size() == before and confirm.visible,
		"Clicking rule only opens the confirmation")
	confirm.get_ok_button().pressed.emit()
	var ruled: Dictionary = await _next_event(_events, before, "warning rule")
	_expect(bool(ruled.get("ok", false))
			and not bool(ruled.get("duplicate", true))
			and str(ruled.get("action", "")) == "rule"
			and str(ruled.get("status", "")) == Disputes.STATUS_RULED,
		"The administrator's warning rule lands on the authority (%s)"
			% str(ruled.get("reason", "")))
	_expect(_panel_status(dispute_panel) == "裁定已记录。",
		"The panel reports the recorded warning ruling")
	_expect(not _warning_rule.is_empty()
			and str(((_warning_rule.get("args", {}) as Dictionary)
				.get("decision", {}) as Dictionary).get("outcome", "")) == "warning"
			and str(((_warning_rule.get("args", {}) as Dictionary)
				.get("decision", {}) as Dictionary).get("reason", "")) == WARNING_REASON,
		"The panel forwarded the warning outcome and reason")

	var stored: Dictionary = _stored_case(CASE_WARN)
	var stored_ruling: Dictionary = _dict(stored.get("ruling"))
	_expect(str(stored.get("status", "")) == Disputes.STATUS_RULED
			and str(stored_ruling.get("outcome", "")) == Disputes.OUTCOME_WARNING
			and str(stored_ruling.get("by", "")) == PLAYER_A
			and str(stored_ruling.get("reason", "")) == WARNING_REASON,
		"disputes.json persists the warning ruling, its author and reason")
	_expect(float(stored_ruling.get("at_utc", 0.0)) > 0.0,
		"disputes.json records the ruling time the window derives from")
	_expect(not stored.has("warning"),
		"disputes.json writes no warning deadline field")
	_expect(_warning_text(CASE_WARN).contains("警告 生效中")
			and _warning_text(CASE_WARN).contains("UTC "),
		"The administrator's panel renders the derived warning window")

	var warning: Dictionary = _view_case(_state(ruled), CASE_WARN).get(
		"warning", {}) as Dictionary
	_expect(bool(warning.get("ok", false))
			and str(warning.get("status", "")) == Disputes.WARNING_ACTIVE,
		"The ruling reply carries an active warning for the administrator")
	_expect(is_equal_approx(float(warning.get("expires_utc", 0.0))
			- float(warning.get("starts_utc", 0.0)),
		Disputes.WARNING_WINDOW_SECONDS),
		"The authority derives the window from the ruling time and constant")
	_expect(is_equal_approx(float(warning.get("starts_utc", 0.0)),
			float(stored_ruling.get("at_utc", -1.0))),
		"The derived warning starts at the persisted ruling time")
	_warning_after_rule = warning.duplicate(true)

	# Resend the exact same ruling command: the persisted journal must answer
	# duplicate without rewriting the document or changing the derived warning.
	var disputes_after_rule: PackedByteArray = _bytes(_disputes_path())
	var replay: Dictionary = await _request_dispute(
		str(_warning_rule.get("request_id", "")), "rule",
		_dict(_warning_rule.get("args")))
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Resending the same warning ruling returns duplicate")
	_expect(_panel_status(dispute_panel) == "这条纠纷操作已经执行过。",
		"The panel reports the duplicate ruling from the authority")
	_expect(_bytes(_disputes_path()) == disputes_after_rule,
		"A duplicate warning ruling leaves disputes.json byte-identical")
	var replay_warning: Dictionary = _view_case(_state(replay), CASE_WARN).get(
		"warning", {}) as Dictionary
	_expect(_same_dict(replay_warning, _warning_after_rule),
		"The duplicate reply carries the unchanged warning")
	_expect(not _stored_case(CASE_WARN).has("warning"),
		"The duplicate reply writes no new warning field")


## The filer reconnects and refreshes: the case row shows the warning window.
func _phase_filer_refreshes(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The filer rejoins to refresh the warning")
	if client == null or not client.joined:
		return
	var reply: Dictionary = await _open_panel("filer warning")
	var state: Dictionary = _state(reply)
	_expect(not bool(state.get("is_authority", true)),
		"The filer's refreshed view is non-authoritative")
	_expect_warning_row(state, "filer")
	_expect(_warning_text(CASE_WARN).contains(_warning_line(_warning_after_rule)),
		"The filer's panel renders the active warning window")


## The warned party reconnects and refreshes: the same derived warning.
func _phase_target_refreshes(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_T, NAME_T,
		PLAYER_SECRET_T), "The warned party rejoins to refresh the warning")
	if client == null or not client.joined:
		return
	var reply: Dictionary = await _open_panel("target warning")
	var state: Dictionary = _state(reply)
	_expect(not bool(state.get("is_authority", true)),
		"The warned party's refreshed view is non-authoritative")
	_expect_warning_row(state, "warned party")
	_expect(_warning_text(CASE_WARN).contains(_warning_line(_warning_after_rule)),
		"The warned party's panel renders the active warning window")


## An unrelated named visitor only gets the public row; no case row is rendered.
func _phase_visitor(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("visitor", "")), VISITOR_ID, VISITOR_NAME,
		PLAYER_SECRET_VISITOR), "A named visitor joins with the visitor code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")
	var reply: Dictionary = await _open_panel("visitor")
	var state: Dictionary = _state(reply)
	_expect(bool(state.get("available", false))
			and not bool(state.get("is_authority", true)),
		"The visitor may read but not administer the dispute authority")
	_expect((state.get("cases", []) as Array).is_empty()
			and (state.get("public", []) as Array).size() == 1,
		"The visitor sees only the single public status row")
	_expect(dispute_panel.cases.is_empty(),
		"The visitor's panel renders no case row")
	_expect(_warning_text(CASE_WARN).is_empty(),
		"The visitor's panel has no warning case label")
	var public_text: String = _public_text(CASE_WARN)
	_expect(public_text.contains("公开")
			and not public_text.contains("警告"),
		"The public row carries no warning detail")
	_expect(not _list_text("CaseList").contains("警告")
			and not _list_text("PublicList").contains("警告"),
		"The visitor's rendered case and public lists contain no warning")
	_expect(_admin_section_visible() == false,
		"The visitor's panel hides the administrator section")


## After a graceful restart the warning is still derived from the same ruling.
func _phase_restart(codes: Dictionary, disputes_before_stop: PackedByteArray) -> void:
	_expect(_bytes(_disputes_path()) == disputes_before_stop,
		"The restart loads disputes.json without rewriting it")
	var stored: Dictionary = _stored_case(CASE_WARN)
	var stored_ruling: Dictionary = _dict(stored.get("ruling"))
	_expect(str(stored.get("status", "")) == Disputes.STATUS_RULED
			and str(stored_ruling.get("outcome", "")) == Disputes.OUTCOME_WARNING
			and str(stored_ruling.get("reason", "")) == WARNING_REASON,
		"The warning ruling survives the restart")
	_expect(not stored.has("warning"),
		"The restarted document still has no warning deadline field")

	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The administrator rejoins the restarted authority")
	if client == null or not client.joined:
		return
	var reply: Dictionary = await _open_panel("restart admin warning")
	var state: Dictionary = _state(reply)
	_expect(bool(state.get("is_authority", false)),
		"The administrator still has the authoritative view after the restart")
	var warning: Dictionary = _view_case(state, CASE_WARN).get(
		"warning", {}) as Dictionary
	_expect(bool(warning.get("ok", false))
			and str(warning.get("status", "")) == Disputes.WARNING_ACTIVE,
		"The restarted authority derives an active warning from the ruling")
	_expect(_same_dict(warning, _warning_after_rule),
		"The restarted warning window is identical to the pre-restart window")
	_expect(_warning_text(CASE_WARN).contains(_warning_line(warning)),
		"The restarted panel renders the persisted warning window")
	_expect(_bytes(_disputes_path()) == disputes_before_stop,
		"Reading the warning after the restart writes nothing")


# ------------------------------------------------------------------ assertions

## Both parties must see the full case row with the same active warning. The
## expected window comes from the authority reply, not a hard-coded value.
func _expect_warning_row(state: Dictionary, label: String) -> void:
	var row: Dictionary = _view_case(state, CASE_WARN)
	var warning: Dictionary = row.get("warning", {}) as Dictionary
	_expect(str(row.get("status", "")) == Disputes.STATUS_RULED,
		"The %s sees the ruled case (%s)" % [label, CASE_WARN])
	_expect(bool(warning.get("ok", false))
			and str(warning.get("status", "")) == Disputes.WARNING_ACTIVE,
		"The %s sees an active warning" % label)
	_expect(is_equal_approx(float(warning.get("expires_utc", 0.0))
			- float(warning.get("starts_utc", 0.0)),
		Disputes.WARNING_WINDOW_SECONDS),
		"The %s warning spans the fixed window" % label)
	_expect(is_equal_approx(float(warning.get("starts_utc", -1.0)),
			float(_warning_after_rule.get("starts_utc", -2.0)))
			and is_equal_approx(float(warning.get("expires_utc", -1.0)),
			float(_warning_after_rule.get("expires_utc", -2.0))),
		"The %s sees the same derived window as the ruling reply" % label)
	_expect(_same_dict(warning, _warning_after_rule),
		"The %s warning matches the authority's ruling reply" % label)


func _warning_line(warning: Dictionary) -> String:
	return "警告 生效中｜UTC %d 至 %d" % [
		int(float(warning.get("starts_utc", 0.0))),
		int(float(warning.get("expires_utc", 0.0))),
	]


# -------------------------------------------------------------- panel helpers

func _outcome_index(option: OptionButton, outcome: String) -> int:
	for index: int in option.item_count:
		if str(option.get_item_metadata(index)) == outcome:
			return index
	return -1


# ------------------------------------------------------------ state readers

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


func _same_dict(a: Dictionary, b: Dictionary) -> bool:
	return JSON.stringify(a) == JSON.stringify(b)


# ------------------------------------------------------------------ panel UI

func _panel_status(panel: Control) -> String:
	var label: Label = panel.find_child("Status", true, false) as Label
	return label.text if label != null else ""


## The rendered warning line inside a case label, or "" when the case row is not
## rendered (the visitor has no case rows).
func _warning_text(case_id: String) -> String:
	var label: Label = dispute_panel.find_child(
		"Case_" + case_id, true, false) as Label
	if label == null:
		return ""
	for line: String in label.text.split("\n"):
		if line.begins_with("警告"):
			return line
	return ""


func _public_text(case_id: String) -> String:
	var label: Label = dispute_panel.find_child(
		"Public_" + case_id, true, false) as Label
	return label.text if label != null else ""


func _list_text(node_name: String) -> String:
	var list: Node = dispute_panel.find_child(node_name, true, false)
	if list == null:
		return ""
	var pieces: Array[String] = []
	for child: Node in list.get_children():
		if child is Label:
			pieces.append((child as Label).text)
	return "\n".join(pieces)


func _admin_section_visible() -> bool:
	var section: Node = dispute_panel.find_child("AdminSection", true, false)
	return section is CanvasItem and (section as CanvasItem).is_visible_in_tree()


# --------------------------------------------------------------- clients

func _open_client(code: String, player_id: String, display_name: String,
		secret_text: String) -> bool:
	_ready = false
	_refusals.clear()
	_events.clear()
	_command_pending.clear()
	_warning_rule = {}
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


func _farm_doc() -> Dictionary:
	var saved: Dictionary = _read_json(world_dir.path_join("farm.json"))
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
	return "dispute-warning-%d-%d" % [Time.get_ticks_usec(), checks]


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("DISPUTE_WARNING_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
