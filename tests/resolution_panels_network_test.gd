extends SceneTree
## M11-03 resolution panel over the real wire: RPC 27/28, not the pure rules and
## not the `HeadlessWorld` seam.
##
## The real `Game/ui/resolutions_panel.gd` is mounted and wired exactly the way
## `main.gd` wires it: the panel's intent signals go to `WorldClient.request_resolutions()`
## and every authority reply is handed to `panel.apply_result()`. Everything runs
## against a real `world_server.gd` over loopback WSS.
##
##   - a named member files a tax proposal through the panel form; the authority
##     reply replaces the panel view and the row is rendered;
##   - two named members vote yes through the panel; the counts grow to 2;
##   - closing before the window ends is refused (`window_open`), closing after it
##     passes the proposal, and activating before the effective instant is refused
##     (`too_early`) with the authority's own text;
##   - the authority is restarted with a later clock so the effective instant is
##     really reached, then activation through the panel succeeds and the view's
##     `effects.tax_rate_permille` becomes 10;
##   - replaying the same command id returns `duplicate` and writes no second
##     effect: both documents stay byte-identical and `applied` keeps one row;
##   - a visitor reads the effective row but its write is refused `forbidden` with
##     the authority reason text shown verbatim;
##   - a final restart keeps the row, rules version and tax rate, and rewrites
##     neither document.
##
## Two named members use different installation credentials (ADR-029) and join
## one at a time because `WorldClient` always creates `/root/WorldSession`.
## Everything runs under .local/verification/resolution-panels-network-<ticks>/.

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const Resolution = preload("res://world/resolution_state.gd")
const ResolutionEffects = preload("res://world/resolution_effects.gd")
const ResolutionsStore = preload("res://world/resolutions_store.gd")
const ResolutionEffectsStore = preload("res://world/resolution_effects_store.gd")
const ResolutionsPanel = preload("res://ui/resolutions_panel.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const PLAYER_SECRET_C: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMzI="
const PLAYER_SECRET_VISITOR: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtNDI="
const START: float = 1800000000.0
const WORLD: String = "world-resolution-panels-network"
const PLAYER_A: String = "player_000000000000000000000000000000a1"
const PLAYER_B: String = "player_000000000000000000000000000000b2"
const PLAYER_C: String = "player_000000000000000000000000000000c3"
const VISITOR_ID: String = "player_000000000000000000000000000000d4"
const NAME_A: String = "阿金"
const NAME_B: String = "阿木"
const NAME_C: String = "阿土"
const VISITOR_NAME: String = "围观者"
const RESOLUTION_ID: String = "res_panel_net_tax"
const TITLE: String = "田税"
const TAX_RATE_PERMILLE: int = ResolutionEffects.TAX_STEP_PERMILLE

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var url: String = ""
var checks: int = 0
var failures: Array[String] = []
var client: WorldClient
var panel: ResolutionsPanel
var _ready: bool = false
var _refusals: Array[String] = []
var _pending: Dictionary = {}
## Every resolution reply in arrival order. Panel actions generate their request
## id inside the panel, so the test waits on the reply count, not on an id.
var _events: Array = []
var _vote_start: int = 0
var _vote_end: int = 0
var _effective: int = 0
var _restart_now: float = 0.0
var _effects_bytes_after_activation: PackedByteArray = PackedByteArray()
var _resolutions_bytes_after_activation: PackedByteArray = PackedByteArray()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/resolution-panels-network-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	root.size = Vector2i(1280, 720)
	_mount_panel()
	await process_frame

	if not await _start_authority(START):
		_finish()
		return
	var codes: Dictionary = _join_codes()
	if str(codes.get("member", "")).is_empty() or str(codes.get("visitor", "")).is_empty():
		_expect(false, "Member and visitor join codes are built")
		await _stop_server()
		_finish()
		return

	await _phase_propose(codes)
	await _close_client()
	await _phase_vote(codes, PLAYER_A, NAME_A, PLAYER_SECRET_A, 1)
	await _close_client()
	await _phase_vote_and_close(codes)
	await _close_client()

	_expect(not _bytes(_resolutions_path()).is_empty(),
		"The proposal is persisted before the first restart")
	await _stop_server()
	# Activation waits for the declared effective instant. A real wait would be
	# the 3600 s notice period, so the authority is restarted with a later clock
	# exactly like the network fixture; the RPC and the rule check stay real.
	_restart_now = float(_effective) + 30.0
	if not await _start_authority(_restart_now):
		_finish()
		return
	await _phase_activate(_join_codes())
	await _close_client()
	await _phase_visitor(_join_codes())
	await _close_client()

	_expect(not _effects_bytes_after_activation.is_empty(),
		"The effect document exists before the final restart")
	await _stop_server()
	if not await _start_authority(_restart_now):
		_finish()
		return
	await _phase_restart(_join_codes())
	await _close_client()
	await _stop_server()
	_finish()


# -------------------------------------------------------------- panel wiring

## Mirrors `main.gd`: panel intents carry their command id as the request id and
## every reply reaches `apply_result()`, which is the only thing that rewrites the
## view.
func _mount_panel() -> void:
	panel = ResolutionsPanel.new()
	panel.name = "Resolutions"
	root.add_child(panel)
	panel.resolution_action.connect(_resolution_action)
	panel.refresh_requested.connect(_resolutions_refresh)


func _resolution_action(action: String, args: Dictionary) -> void:
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = _new_command_id()
		payload["command_id"] = request_id
	if client == null or not client.request_resolutions(request_id, action, payload):
		panel.show_status("还没有连上世界，决议操作没有发出去。")


func _resolutions_refresh() -> void:
	if client == null or not client.request_resolutions("resolution-state", "state"):
		panel.show_status("还没有连上世界，决议没有刷新。")


func _open_panel() -> void:
	panel.open_panel(panel.view.duplicate(true))
	if client == null or not client.request_resolutions("resolution-state", "state"):
		panel.show_status("还没有连上世界，决议没有刷新。")


# --------------------------------------------------------------- phase write

func _phase_propose(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The proposing member joins over WSS")
	if client == null or not client.joined:
		return
	var before: int = _events.size()
	_open_panel()
	var view: Dictionary = await _next_event(_events, before, "fresh resolution state")
	_expect(bool(view.get("ok", false)),
		"The panel receives the authoritative resolution view")
	var state: Dictionary = _state(view)
	for key: String in ["available", "now_utc", "viewer", "is_member", "can_write",
			"rules_version", "versions", "effects", "resolutions"]:
		_expect(state.has(key), "The resolution view carries %s" % key)
	_expect(bool(state.get("is_member", false))
			and str(state.get("viewer", "")) == PLAYER_B,
		"A named member's view is marked as a member")
	_expect(bool(state.get("can_write", false)),
		"A named member's view carries the write permission")
	_expect(int(state.get("rules_version", -1)) == 0
			and (state.get("resolutions", []) as Array).is_empty(),
		"A fresh room has no resolutions and rules version 0")
	_expect(_label_text("RulesVersion") == "规则版本 v0",
		"The panel renders the authoritative rules version")
	_expect(_label_text("ViewerState") == "成员｜" + PLAYER_B,
		"The panel marks the viewer as a member")
	_expect(_has_text(_list("ResolutionList"), "还没有决议。"),
		"The panel says there are no resolutions instead of inventing one")

	var now: float = float(state.get("now_utc", 0.0))
	_expect(now > 0.0, "The view carries the authority clock")
	_vote_start = int(now) + 6
	_vote_end = _vote_start + 20
	_effective = _vote_end + int(Resolution.NOTICE_SECONDS) + 60
	var resolution_id: LineEdit = panel.find_child("ResolutionId", true, false) as LineEdit
	var kind: OptionButton = panel.find_child("Kind", true, false) as OptionButton
	var title: LineEdit = panel.find_child("Title", true, false) as LineEdit
	var vote_start: LineEdit = panel.find_child("VoteStart", true, false) as LineEdit
	var vote_end: LineEdit = panel.find_child("VoteEnd", true, false) as LineEdit
	var effective: LineEdit = panel.find_child("EffectiveUtc", true, false) as LineEdit
	var propose: Button = panel.find_child("Propose", true, false) as Button
	var confirm: ConfirmationDialog = panel.find_child(
		"ResolutionConfirm", true, false) as ConfirmationDialog
	_expect(resolution_id != null and kind != null and title != null
			and vote_start != null and vote_end != null and effective != null
			and propose != null and confirm != null,
		"The panel exposes the proposal form")
	if resolution_id == null or kind == null or title == null or vote_start == null \
			or vote_end == null or effective == null or propose == null or confirm == null:
		return
	resolution_id.text = RESOLUTION_ID
	kind.select(1)
	_expect(str(kind.get_item_metadata(1)) == Resolution.KIND_TAX,
		"The tax kind is offered by the panel")
	title.text = TITLE
	vote_start.text = str(_vote_start)
	vote_end.text = str(_vote_end)
	effective.text = str(_effective)

	var writes_before: int = _events.size()
	propose.pressed.emit()
	await process_frame
	_expect(_events.size() == writes_before,
		"Clicking propose alone only opens a confirmation")
	confirm.get_ok_button().pressed.emit()
	var proposed: Dictionary = await _next_event(_events, writes_before,
		"proposal reply")
	_expect(bool(proposed.get("ok", false))
			and str(proposed.get("action", "")) == "propose",
		"The member's proposal lands on the authority through the panel (%s)"
			% str(proposed.get("reason", "")))
	var proposed_state: Dictionary = _state(proposed)
	var row: Dictionary = _row(proposed_state, RESOLUTION_ID)
	_expect(str(row.get("status", "")) == Resolution.STATUS_PROPOSED
			and str(row.get("kind", "")) == Resolution.KIND_TAX
			and str(row.get("proposed_by", "")) == PLAYER_B,
		"The authoritative row records the proposal, its kind and the connection identity")
	_expect(float(row.get("vote_start_utc", 0.0)) == float(_vote_start)
			and float(row.get("vote_end_utc", 0.0)) == float(_vote_end)
			and float(row.get("effective_utc", 0.0)) == float(_effective),
		"The authoritative row carries the times entered in the panel")
	_expect(panel.find_child("Resolution_" + RESOLUTION_ID, true, false) != null,
		"The panel renders the new authoritative row")
	var row_text: String = _row_text(RESOLUTION_ID)
	_expect(row_text.contains(RESOLUTION_ID) and row_text.contains(TITLE)
			and row_text.contains("提案中（proposed）"),
		"The rendered row shows the id, title and proposed status")
	_expect(_label_text("Status") == "决议已提交。",
		"A successful proposal reports it")
	_expect(panel.selected_id == RESOLUTION_ID,
		"The panel selects the reply's row for the next action")

	var document: Dictionary = await _json_ready(_resolutions_path())
	var stored_row: Dictionary = _stored_row(document, RESOLUTION_ID)
	_expect(str(stored_row.get("status", "")) == Resolution.STATUS_PROPOSED,
		"The proposal is persisted to resolutions.json")
	_expect(not (document.get("commands", []) as Array).is_empty(),
		"resolutions.json persists the replay journal")

	# Closing right after a fresh proposal is necessarily before the window ends,
	# so the refusal is deterministic. The direct client call stands in for the
	# panel's close intent; its reply still reaches `apply_result()`.
	var early_id: String = "resolution-early-close"
	var early: Dictionary = await _resolution(early_id, "close", {
		"command_id": early_id, "resolution_id": RESOLUTION_ID,
	})
	_expect(not bool(early.get("ok", true))
			and str(early.get("reason", "")) == "window_open",
		"Closing before the window ends is refused as window_open")
	var early_text: String = str(early.get("reason_text", ""))
	_expect(not early_text.is_empty(),
		"The window_open refusal carries a human-readable reason")
	_expect(_label_text("Status") == early_text,
		"The panel shows the authority window_open text verbatim")
	_expect(str(_row(_state(early), RESOLUTION_ID).get("status", ""))
			== Resolution.STATUS_PROPOSED,
		"The refused close leaves the row proposed")


# --------------------------------------------------------------- phase votes

## One named member votes yes through the panel. The window has not been reached
## by the first voter's clock, so the caller keeps the window generous.
func _phase_vote(codes: Dictionary, player_id: String, display_name: String,
		secret_text: String, expected_approvals: int) -> void:
	_expect(await _open_client(str(codes.get("member", "")), player_id, display_name,
		secret_text), "The voting member joins over WSS")
	if client == null or not client.joined:
		return
	var before: int = _events.size()
	_open_panel()
	var view: Dictionary = await _next_event(_events, before, "voting member state")
	_expect(bool(view.get("ok", false))
			and str(_state(view).get("viewer", "")) == player_id,
		"The voter receives its own authoritative view")
	_expect(await _wait_for_vote_start(), "The authority clock reaches the vote window")
	var approve: Button = panel.find_child("Approve", true, false) as Button
	var confirm: ConfirmationDialog = panel.find_child(
		"ResolutionConfirm", true, false) as ConfirmationDialog
	_expect(approve != null and confirm != null,
		"The panel exposes the vote controls")
	if approve == null or confirm == null:
		return
	_select_row()
	_expect(approve.is_visible_in_tree(),
		"A member who has not voted is offered the vote buttons")
	var writes_before: int = _events.size()
	approve.pressed.emit()
	await process_frame
	_expect(_events.size() == writes_before,
		"Clicking approve alone only opens a confirmation")
	confirm.get_ok_button().pressed.emit()
	var voted: Dictionary = await _next_event(_events, writes_before, "vote reply")
	_expect(bool(voted.get("ok", false))
			and str(voted.get("action", "")) == "vote",
		"The vote lands on the authority through the panel (%s)"
			% str(voted.get("reason", "")))
	var voted_row: Dictionary = _row(_state(voted), RESOLUTION_ID)
	_expect(int(voted_row.get("approvals", -1)) == expected_approvals,
		"The authoritative approval count is %d" % expected_approvals)
	_expect(_row_text(RESOLUTION_ID).contains("赞成 %d" % expected_approvals),
		"The panel renders the authoritative approval count")
	_expect(_label_text("Status") == "投票已记录。", "A successful vote reports it")


func _phase_vote_and_close(codes: Dictionary) -> void:
	await _phase_vote(codes, PLAYER_C, NAME_C, PLAYER_SECRET_C, 2)
	if client == null or not client.joined:
		return
	var close_vote: Button = panel.find_child("CloseVote", true, false) as Button
	var confirm: ConfirmationDialog = panel.find_child(
		"ResolutionConfirm", true, false) as ConfirmationDialog
	_expect(close_vote != null and confirm != null,
		"The panel exposes the close-vote control")
	if close_vote == null or confirm == null:
		return
	# Closing earlier was already refused with its own text in the propose phase;
	# this phase waits for the authoritative window to actually end.
	_expect(await _wait_for_window_end(), "The authority clock passes the vote window")
	_select_row()
	_expect(close_vote.is_visible_in_tree(),
		"A member is offered closing an open proposal")
	var before: int = _events.size()
	close_vote.pressed.emit()
	await process_frame
	_expect(_events.size() == before,
		"Clicking close alone only opens a confirmation")
	confirm.get_ok_button().pressed.emit()
	var closed: Dictionary = await _next_event(_events, before, "close reply")
	_expect(bool(closed.get("ok", false))
			and str(closed.get("action", "")) == "close"
			and str(closed.get("status", "")) == Resolution.STATUS_PASSED,
		"The close lands on the authority and passes the proposal (%s)"
			% str(closed.get("reason", "")))
	var closed_row: Dictionary = _row(_state(closed), RESOLUTION_ID)
	_expect(int(closed_row.get("revision", -1)) == 2
			and int(closed_row.get("effective_version", -1)) == 0,
		"The passed row is revision 2 and has no version yet")
	_expect(_row_text(RESOLUTION_ID).contains("已通过（passed）"),
		"The panel renders the passed status")
	var activate: Button = panel.find_child("Activate", true, false) as Button
	_expect(activate != null and activate.is_visible_in_tree(),
		"A member is offered activation on a passed proposal")
	_expect(_label_text("Status") == "投票已关闭。", "A successful close reports it")

	# Activation before the effective instant is refused by the authority.
	var early_activate: Dictionary = await _resolution("resolution-early-activate",
		"activate", {"command_id": "resolution-early-activate",
			"resolution_id": RESOLUTION_ID})
	_expect(not bool(early_activate.get("ok", true))
			and str(early_activate.get("reason", "")) == "too_early",
		"Activating before the effective instant is refused as too_early")
	_expect(not str(early_activate.get("reason_text", "")).is_empty(),
		"The too_early refusal carries a human-readable reason")
	_expect(_label_text("Status") == str(early_activate.get("reason_text", "")),
		"The panel shows the authority too_early text verbatim")
	_expect(str(_row(_state(early_activate), RESOLUTION_ID).get("status", ""))
			== Resolution.STATUS_PASSED,
		"The refused activation leaves the row passed")
	_expect(int(_state(early_activate).get("rules_version", -1)) == 0,
		"The refused activation does not bump the rules version")


func _wait_for_vote_start() -> bool:
	return await _wait_until_now(float(_vote_start))


func _wait_for_window_end() -> bool:
	return await _wait_until_now(float(_vote_end))


## Polls the authoritative clock over RPC until it reaches `target_utc`. Each poll
## is one state request, so the interval stays at 1 s to stay inside the command
## token bucket.
func _wait_until_now(target_utc: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		var reply: Dictionary = await _resolution("resolution-clock-%d"
			% Time.get_ticks_usec(), "state")
		if float(_state(reply).get("now_utc", 0.0)) >= target_utc:
			return true
		await create_timer(1.0).timeout
	_expect(false, "The authority clock reaches %d within 30 s" % int(target_utc))
	return false


# ----------------------------------------------------------- phase activation

func _phase_activate(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host rejoins the restarted authority")
	if client == null or not client.joined:
		return
	var before: int = _events.size()
	_open_panel()
	var view: Dictionary = await _next_event(_events, before, "restarted state")
	var state: Dictionary = _state(view)
	_expect(bool(view.get("ok", false)), "The restarted authority answers a state request")
	_expect(str(_row(state, RESOLUTION_ID).get("status", ""))
			== Resolution.STATUS_PASSED,
		"The passed proposal survives the restart")
	_expect(_row_text(RESOLUTION_ID).contains("已通过（passed）"),
		"The panel renders the passed proposal after the restart")
	var activate: Button = panel.find_child("Activate", true, false) as Button
	var confirm: ConfirmationDialog = panel.find_child(
		"ResolutionConfirm", true, false) as ConfirmationDialog
	_expect(activate != null and confirm != null,
		"The panel exposes the activation control")
	if activate == null or confirm == null:
		return
	_select_row()
	_expect(activate.is_visible_in_tree(),
		"A member is offered activation after the effective instant")
	before = _events.size()
	activate.pressed.emit()
	await process_frame
	_expect(_events.size() == before,
		"Clicking activate alone only opens a confirmation")
	confirm.get_ok_button().pressed.emit()
	var activated: Dictionary = await _next_event(_events, before, "activation reply")
	_expect(bool(activated.get("ok", false))
			and str(activated.get("action", "")) == "activate"
			and str(activated.get("status", "")) == Resolution.STATUS_EFFECTIVE,
		"The activation lands on the authority (%s)" % str(activated.get("reason", "")))
	var activated_state: Dictionary = _state(activated)
	_expect(int(activated_state.get("rules_version", -1)) == 1,
		"The activation bumps the rules version to 1")
	var effects: Dictionary = _effects(activated_state)
	_expect(int(effects.get("applied_version", -1)) == 1
			and int(effects.get("tax_rate_permille", -1)) == TAX_RATE_PERMILLE,
		"The view reports the applied tax rate %d" % TAX_RATE_PERMILLE)
	_expect(_row_text(RESOLUTION_ID).contains("已生效（effective）")
			and _row_text(RESOLUTION_ID).contains("生效版本 1"),
		"The panel renders the effective row and its version")
	_expect(_has_text(_list("VersionList"), "v1 生效 · " + RESOLUTION_ID),
		"The panel renders the authoritative version difference")
	_expect(_label_text("Status") == "决议已生效。", "A successful activation reports it")
	# The member's write permission reaches the panel as visible controls: vote and
	# close do not apply to an effective row, but the approver may revoke it.
	var member_approve: Button = panel.find_child("Approve", true, false) as Button
	var member_close: Button = panel.find_child("CloseVote", true, false) as Button
	var member_activate: Button = panel.find_child("Activate", true, false) as Button
	var member_revoke: Button = panel.find_child("Revoke", true, false) as Button
	_expect(member_approve != null and not member_approve.is_visible_in_tree()
			and member_close != null and not member_close.is_visible_in_tree()
			and member_activate != null and not member_activate.is_visible_in_tree(),
		"An effective row offers the member no vote, close or activation button")
	_expect(member_revoke != null and member_revoke.is_visible_in_tree(),
		"The approving member is offered the revoke button")

	var effects_doc: Dictionary = await _json_ready(_effects_path())
	var effects_state: Dictionary = effects_doc.get("state", {}) \
		if effects_doc.get("state") is Dictionary else {}
	var applied: Array = effects_state.get("applied", []) \
		if effects_state.get("applied") is Array else []
	_expect(int(effects_state.get("applied_version", -1)) == 1 and applied.size() == 1,
		"resolution_effects.json records exactly one applied version")
	_expect(applied.size() == 1
			and str((applied[0] as Dictionary).get("resolution_id", "")) == RESOLUTION_ID
			and int((applied[0] as Dictionary).get("version", -1)) == 1,
		"The applied record names the resolution and its version")
	_effects_bytes_after_activation = _bytes(_effects_path())
	_resolutions_bytes_after_activation = _bytes(_resolutions_path())

	# Replay the panel's own activation command id: same actor, same args, so the
	# authority answers duplicate and writes nothing a second time.
	var command_id: String = await _activation_command_id()
	_expect(not command_id.is_empty(),
		"The persisted journal carries the panel's activation command id")
	if command_id.is_empty():
		return
	var replay: Dictionary = await _resolution(command_id, "activate", {
		"command_id": command_id, "resolution_id": RESOLUTION_ID,
	})
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the activation command id returns duplicate (got ok=%s duplicate=%s reason=%s)"
			% [str(replay.get("ok", false)), str(replay.get("duplicate", false)),
				str(replay.get("reason", ""))])
	var replay_state: Dictionary = _state(replay)
	_expect(int(replay_state.get("rules_version", -1)) == 1,
		"The replayed activation keeps rules version 1")
	_expect(int(_effects(replay_state).get("applied_version", -1)) == 1
			and int(_effects(replay_state).get("tax_rate_permille", -1))
				== TAX_RATE_PERMILLE,
		"The replayed activation does not apply the tax a second time")
	_expect(_bytes(_resolutions_path()) == _resolutions_bytes_after_activation
			and _bytes(_effects_path()) == _effects_bytes_after_activation,
		"The replay leaves both authority documents byte-identical")


# --------------------------------------------------------------- phase visitor

func _phase_visitor(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("visitor", "")), VISITOR_ID, VISITOR_NAME,
		PLAYER_SECRET_VISITOR), "A visitor joins with the visitor code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")
	var before: int = _events.size()
	_open_panel()
	var view: Dictionary = await _next_event(_events, before, "visitor state")
	var state: Dictionary = _state(view)
	_expect(bool(view.get("ok", false)), "A visitor may read the resolution view")
	_expect(str(state.get("viewer", "")) == VISITOR_ID,
		"The visitor's view names the connection identity")
	_expect(str(_row(state, RESOLUTION_ID).get("status", ""))
			== Resolution.STATUS_EFFECTIVE
			and int(state.get("rules_version", -1)) == 1,
		"The visitor sees the effective resolution and rules version 1")
	# `is_member` means "joined" and drives the privacy tiers; `can_write` is the
	# separate write fact. A joined visitor keeps the counts and loses the write.
	_expect(bool(state.get("is_member", false)),
		"A joined visitor still reads the counts as a joined viewer")
	_expect(int(_row(state, RESOLUTION_ID).get("approvals", -1)) == 2,
		"The joined visitor still sees the authoritative vote counts")
	_expect(not bool(state.get("can_write", true)),
		"A visitor's view reports that it cannot write")
	_expect(not _row(state, RESOLUTION_ID).has("approvers"),
		"An unrelated viewer gets no voter identities")
	var approve: Button = panel.find_child("Approve", true, false) as Button
	var close_vote: Button = panel.find_child("CloseVote", true, false) as Button
	var activate: Button = panel.find_child("Activate", true, false) as Button
	var revoke: Button = panel.find_child("Revoke", true, false) as Button
	_expect(approve != null and not approve.is_visible_in_tree()
			and close_vote != null and not close_vote.is_visible_in_tree()
			and activate != null and not activate.is_visible_in_tree()
			and revoke != null and not revoke.is_visible_in_tree(),
		"A visitor is offered none of the four member-only buttons")

	# The proposal section is open to any available view, so the visitor really
	# presses a write through the panel and the authority's refusal comes back
	# verbatim.
	var view_before: Dictionary = panel.view.duplicate(true)
	var proposal_id: LineEdit = panel.find_child("ResolutionId", true, false) as LineEdit
	var title: LineEdit = panel.find_child("Title", true, false) as LineEdit
	var vote_start: LineEdit = panel.find_child("VoteStart", true, false) as LineEdit
	var vote_end: LineEdit = panel.find_child("VoteEnd", true, false) as LineEdit
	var effective: LineEdit = panel.find_child("EffectiveUtc", true, false) as LineEdit
	var propose: Button = panel.find_child("Propose", true, false) as Button
	var confirm: ConfirmationDialog = panel.find_child(
		"ResolutionConfirm", true, false) as ConfirmationDialog
	_expect(proposal_id != null and title != null and vote_start != null
			and vote_end != null and effective != null and propose != null
			and confirm != null,
		"The visitor's panel exposes the proposal form")
	if propose == null or confirm == null or proposal_id == null or title == null \
			or vote_start == null or vote_end == null or effective == null:
		return
	proposal_id.text = "res_visitor_probe"
	title.text = "访客提案"
	vote_start.text = str(_vote_start)
	vote_end.text = str(_vote_end)
	effective.text = str(_effective)
	before = _events.size()
	propose.pressed.emit()
	await process_frame
	_expect(_events.size() == before,
		"The visitor's propose click alone never reaches the authority")
	confirm.get_ok_button().pressed.emit()
	var refused: Dictionary = await _next_event(_events, before, "visitor propose refusal")
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "forbidden",
		"A visitor's resolution write is refused as forbidden")
	var reason_text: String = str(refused.get("reason_text", ""))
	_expect(not reason_text.is_empty(),
		"The visitor refusal carries an authority reason text")
	_expect(_label_text("Status") == reason_text,
		"The panel shows the authority reason text verbatim")
	_expect(_same_view(panel.view, view_before),
		"The refused write leaves the panel view at the authority's last state")
	_expect(_row(panel.view, "res_visitor_probe").is_empty(),
		"The refused write adds no local resolution row")
	# A refresh still reads after the refusal, and writes nothing.
	var effects_bytes: PackedByteArray = _bytes(_effects_path())
	var resolutions_bytes: PackedByteArray = _bytes(_resolutions_path())
	before = _events.size()
	var refresh: Button = panel.find_child("Refresh", true, false) as Button
	refresh.pressed.emit()
	var refreshed: Dictionary = await _next_event(_events, before, "visitor refresh")
	_expect(bool(refreshed.get("ok", false))
			and str(_row(_state(refreshed), RESOLUTION_ID).get("status", ""))
				== Resolution.STATUS_EFFECTIVE,
		"The visitor can still read after a refusal")
	_expect(_bytes(_effects_path()) == effects_bytes
			and _bytes(_resolutions_path()) == resolutions_bytes,
		"Refreshing the visitor panel writes nothing")


# --------------------------------------------------------------- final restart

func _phase_restart(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host rejoins for the final restart")
	if client == null or not client.joined:
		return
	var before: int = _events.size()
	_open_panel()
	var view: Dictionary = await _next_event(_events, before, "final restart state")
	var state: Dictionary = _state(view)
	_expect(bool(view.get("ok", false)),
		"The final authority answers a state request")
	_expect(str(_row(state, RESOLUTION_ID).get("status", ""))
			== Resolution.STATUS_EFFECTIVE
			and int(state.get("rules_version", -1)) == 1,
		"The effective resolution survives the restart")
	_expect(int(_effects(state).get("applied_version", -1)) == 1
			and int(_effects(state).get("tax_rate_permille", -1))
				== TAX_RATE_PERMILLE,
		"The tax rate survives the restart")
	_expect(panel.find_child("Resolution_" + RESOLUTION_ID, true, false) != null
			and _row_text(RESOLUTION_ID).contains("已生效（effective）"),
		"The panel renders the surviving effective row")
	_expect(_has_text(_list("VersionList"), "v1 生效 · " + RESOLUTION_ID),
		"The panel renders the surviving version difference")
	_expect(_bytes(_resolutions_path()) == _resolutions_bytes_after_activation
			and _bytes(_effects_path()) == _effects_bytes_after_activation,
		"The final restart rewrites neither authority document")


# ------------------------------------------------------------------- clients

func _open_client(code: String, player_id: String, display_name: String,
		secret_text: String) -> bool:
	_ready = false
	_refusals.clear()
	_pending.clear()
	_events.clear()
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
			_now: float) -> void:
		_ready = true)
	client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
	client.lost.connect(func(reason: String) -> void: _refusals.append(reason))
	client.resolutions_result.connect(panel.apply_result)
	client.resolutions_result.connect(_on_result)
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
	_pending.clear()
	_events.clear()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout


func _on_result(request_id: String, payload: Dictionary) -> void:
	_pending[request_id] = payload
	_events.append(payload.duplicate(true))


func _resolution(request_id: String, action: String,
		args: Dictionary = {}) -> Dictionary:
	_pending.erase(request_id)
	if client == null or not client.request_resolutions(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	var arrived: bool = await _wait(func() -> bool:
		return _pending.has(request_id), 15000)
	if not arrived:
		_expect(false, "A resolution reply arrives for request %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _pending.get(request_id, {})
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


# ------------------------------------------------------------------- readers

func _state(reply: Dictionary) -> Dictionary:
	var value: Variant = reply.get("state")
	return value if value is Dictionary else {}


func _effects(view: Dictionary) -> Dictionary:
	var value: Variant = view.get("effects")
	return value if value is Dictionary else {}


func _row(view: Dictionary, resolution_id: String) -> Dictionary:
	var rows: Variant = view.get("resolutions")
	if rows is Array:
		for row_value: Variant in rows:
			if row_value is Dictionary \
					and str((row_value as Dictionary).get("resolution_id", "")) \
						== resolution_id:
				return row_value
	return {}


func _stored_row(document: Dictionary, resolution_id: String) -> Dictionary:
	var state_value: Variant = document.get("state")
	if not state_value is Dictionary:
		return {}
	var table: Variant = (state_value as Dictionary).get("resolutions")
	if not table is Dictionary:
		return {}
	var row: Variant = (table as Dictionary).get(resolution_id)
	return row if row is Dictionary else {}


## The live authority clock advances between replies; everything else must match.
func _same_view(a: Dictionary, b: Dictionary) -> bool:
	var left: Dictionary = a.duplicate(true)
	var right: Dictionary = b.duplicate(true)
	left.erase("now_utc")
	right.erase("now_utc")
	return JSON.stringify(left) == JSON.stringify(right)


func _activation_command_id() -> String:
	var found: bool = await _wait(func() -> bool:
		return not _activation_command_id_now().is_empty(), 10000)
	return _activation_command_id_now() if found else ""


func _activation_command_id_now() -> String:
	var document: Dictionary = _read_json(_resolutions_path())
	var commands: Variant = document.get("commands")
	if not commands is Array:
		return ""
	for row_value: Variant in commands:
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		var result: Variant = row.get("result")
		if result is Dictionary \
				and str((result as Dictionary).get("action", "")) == "activate":
			return str(row.get("command_id", ""))
	return ""


# ------------------------------------------------------------------- panel UI

func _select_row() -> void:
	var select: OptionButton = panel.find_child("ResolutionSelect", true, false) as OptionButton
	if select == null:
		return
	for index: int in select.item_count:
		if str(select.get_item_metadata(index)) == RESOLUTION_ID:
			select.select(index)
			select.item_selected.emit(index)
			return


func _row_text(resolution_id: String) -> String:
	var label: Label = panel.find_child("Resolution_" + resolution_id, true, false) as Label
	return label.text if label != null else ""


func _label_text(node_name: String) -> String:
	var label: Label = panel.find_child(node_name, true, false) as Label
	return label.text if label != null else ""


func _list(node_name: String) -> VBoxContainer:
	return panel.find_child(node_name, true, false) as VBoxContainer


func _has_text(node: Node, fragment: String) -> bool:
	if node == null:
		return false
	for child: Node in node.get_children():
		if child is Label and (child as Label).text.contains(fragment):
			return true
		if _has_text(child, fragment):
			return true
	return false


# --------------------------------------------------------------- authority

func _start_authority(now: float) -> bool:
	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if port <= 0:
		return false
	url = "wss://127.0.0.1:%d" % port
	server_pid = _spawn_server(now, "server-%d.log" % Time.get_ticks_usec())
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
	_expect(str(status.get("host_player", "")) == PLAYER_A,
		"The status file records the host player")
	_expect(str(status.get("world_id", "")) == WORLD,
		"The status file names the world the authority serves")
	return true


func _spawn_server(now: float, log_name: String) -> int:
	var arguments := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % now, "--run-seconds=0", "--join-url=" + url,
		"--host-player=" + PLAYER_A,
	])
	if OS.get_name() == "Windows":
		return OS.create_process(OS.get_executable_path(), arguments, false)
	var pieces: PackedStringArray = []
	pieces.append(_shell_quote(OS.get_executable_path()))
	for argument: String in arguments:
		pieces.append(_shell_quote(argument))
	var command: String = "exec " + " ".join(pieces) + " > " \
		+ _shell_quote(dir.path_join(log_name)) + " 2>&1"
	return OS.create_process("/bin/sh", PackedStringArray(["-c", command]), false)


func _shell_quote(value: String) -> String:
	return "'" + value.replace("'", "'\\''") + "'"


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
	server_pid = 0


# ------------------------------------------------------------------- files

func _resolutions_path() -> String:
	return world_dir.path_join(ResolutionsStore.MAIN)


func _effects_path() -> String:
	return world_dir.path_join(ResolutionEffectsStore.MAIN)


## The authority writes these documents before answering; the poll only absorbs
## the small gap between the atomic rename and the reply. The loop is explicit
## because a GDScript lambda captures locals by value: assigning the document
## inside a Callable would never reach the caller.
func _json_ready(path: String) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		var document: Dictionary = _read_json(path)
		if not document.is_empty():
			return document
		await create_timer(0.05).timeout
	return _read_json(path)


func _status() -> Dictionary:
	return _read_json(world_dir.path_join("server-status.json"))


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) \
		if FileAccess.file_exists(path) else PackedByteArray()


# ------------------------------------------------------------------- helpers

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


func _new_command_id() -> String:
	return "resolution-panels-%d" % Time.get_ticks_usec()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("RESOLUTION_PANELS_NETWORK_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
