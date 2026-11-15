extends SceneTree
## M12/M8 three panels over the real wire: the panels are mounted the way
## `main.gd` wires them, but every view and every reply comes from a real
## `world_server.gd` over loopback WSS through a real `WorldClient`.
##
## A real authority process serves one world. A host member declares the
## limited regime through the participation panel and the second member
## consents as attacker through the same panel; the host's own defender
## consent is sent directly because the panel deliberately hides player
## actions for the host. The member then opens the conflict panel (which first
## refreshes the authoritative participation view), fills the form and settles a
## real engagement over channels 19/20. A second member connection opens a real
## public project, pledges its fixed cost and builds it with an organization
## fund over channels 21/22. A visitor then reads all three views and every
## write is refused with the authority's own reason text.
##
## The last phase proves the panels never allow anything locally: the view stays
## on the authority's last state before a send and after a refusal, and
## refreshing or closing the panels rewrites no authority document.
##
## Everything runs under .local/verification/panels-network-<ticks>/.

const WorldClient = preload("res://world/world_client.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")
const Participation = preload("res://conflict/participation_state.gd")
const PublicFund = preload("res://world/public_fund.gd")
const PublicWorks = preload("res://world/public_works.gd")
const ConflictStore = preload("res://world/conflict_store.gd")
const PublicWorksStore = preload("res://world/public_works_store.gd")
const FundStore = preload("res://world/fund_store.gd")
const ParticipationStore = preload("res://world/participation_store.gd")
const ParticipationPanel = preload("res://ui/participation_panel.gd")
const ConflictPanel = preload("res://ui/conflict_panel.gd")
const PublicWorksPanel = preload("res://ui/public_works_panel.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
## One installation credential per identity; a shared credential binds the
## first player id that presents it.
const PLAYER_SECRET_A: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const PLAYER_SECRET_B: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMjI="
const PLAYER_SECRET_VISITOR: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMzM="
const START: float = 1800000000.0
const WORLD: String = "world-panels-network"
const PLAYER_A: String = "player_00000000000000000000000000000091"
const PLAYER_B: String = "player_00000000000000000000000000000092"
const VISITOR_ID: String = "player_00000000000000000000000000000093"
const NAME_A: String = "阿host"
const NAME_B: String = "阿客"
const VISITOR_NAME: String = "旁观者"
const ORG: String = "guild_panels_net"
const ROAD_PROJECT: String = "road_panel_ui"
const DECLARATION_ID: String = "decl_panels_net"
const AREA_ID: String = "yard"
const WINDOW_ID: String = "day"
const A_ACCOUNT: String = "panels-a-account"
const A_MERCHANT: String = "panels-a-merchant"
const A_BUY: String = "panels-a-buy"
const A_UNIT: String = "panels-unit-a"
const B_ACCOUNT: String = "panels-b-account"
const B_MERCHANT: String = "panels-b-merchant"
const B_BUY: String = "panels-b-buy"
const B_UNIT: String = "panels-unit-b"
const ORG_CREATE: String = "panels-org-create"
const FUND_OPEN: String = "panels-fund-open"
const A_CONTRIBUTE: String = "panels-a-contribute"
const B_CONTRIBUTE: String = "panels-b-contribute"
const REGIME_ID: String = "panels-regime"
const A_CONSENT: String = "panels-a-defender"
const B_CONSENT: String = "panels-b-attacker"
const PEOPLE: int = 1
const SUPPLIES_TO_BUY: int = 8
const GREENS_PRICE: int = 7
const CONTRIBUTION: int = 60
const LOSS_CAP: int = 5
const ROAD_COST: int = 120

var dir: String = ""
var world_dir: String = ""
var server_pid: int = 0
var port: int = 0
var url: String = ""
var log_path: String = ""
var log_captured: bool = false
var checks: int = 0
var failures: Array[String] = []

var client: WorldClient
var _ready: bool = false
var _refusals: Array[String] = []
var _participation_pending: Dictionary = {}
var _conflict_pending: Dictionary = {}
var _works_pending: Dictionary = {}
var _unit_pending: Dictionary = {}
var _fund_pending: Dictionary = {}
var _organization_pending: Dictionary = {}
var _command_pending: Dictionary = {}
## Every panel reply in arrival order. UI actions generate their request id
## inside the panel, so the test waits on a reply count instead of an id.
var _participation_events: Array = []
var _conflict_events: Array = []
var _works_events: Array = []
var _fund_id: String = ""
var _effective_utc: float = 0.0

var participation_panel: ParticipationPanel
var conflict_panel: ConflictPanel
var public_works_panel: PublicWorksPanel


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/panels-network-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	root.size = Vector2i(1280, 720)
	_mount_panels()
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

	await _phase_host_declaration(codes)
	await _close_client()
	await _phase_member_consent_and_engage(codes)
	await _close_client()
	await _phase_public_works(codes)
	await _close_client()
	await _phase_visitor(codes)
	await _close_client()
	await _stop_server()
	_finish()


# -------------------------------------------------------------- panel wiring

## Mirrors `main.gd`: one panel per authority reply, delivery actions forwarded
## with their command id, and refreshes ask the authority for a fresh view.
func _mount_panels() -> void:
	participation_panel = ParticipationPanel.new()
	participation_panel.name = "Participation"
	root.add_child(participation_panel)
	participation_panel.participation_action.connect(_participation_action)
	participation_panel.refresh_requested.connect(_participation_refresh)

	public_works_panel = PublicWorksPanel.new()
	public_works_panel.name = "PublicWorks"
	root.add_child(public_works_panel)
	public_works_panel.public_works_action.connect(_public_works_action)
	public_works_panel.refresh_requested.connect(_public_works_refresh)

	conflict_panel = ConflictPanel.new()
	conflict_panel.name = "Conflict"
	root.add_child(conflict_panel)
	conflict_panel.conflict_action.connect(_conflict_action)
	conflict_panel.refresh_requested.connect(_conflict_refresh)


func _participation_action(action: String, args: Dictionary) -> void:
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = _new_command_id()
		payload["command_id"] = request_id
	if client == null or not client.request_participation(request_id, action, payload):
		participation_panel.show_status("还没有连上世界，参与制度操作没有发出去。")


func _participation_refresh() -> void:
	if client == null or not client.request_participation("participation-state", "state"):
		participation_panel.show_status("还没有连上世界，参与制度没有刷新。")


func _public_works_action(action: String, args: Dictionary) -> void:
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = _new_command_id()
		payload["command_id"] = request_id
	if client == null or not client.request_public_works(request_id, action, payload):
		public_works_panel.show_status("还没有连上世界，公共项目操作没有发出去。")


func _public_works_refresh() -> void:
	if client == null or not client.request_public_works("public-works-state", "state"):
		public_works_panel.show_status("还没有连上世界，公共项目没有刷新。")


func _conflict_action(action: String, args: Dictionary) -> void:
	var payload: Dictionary = args.duplicate(true)
	var request_id: String = str(payload.get("command_id", ""))
	if request_id.is_empty():
		request_id = _new_command_id()
		payload["command_id"] = request_id
	if client == null or not client.request_conflict(request_id, action, payload):
		conflict_panel.show_status("还没有连上世界，交战操作没有发出去。")


func _conflict_refresh() -> void:
	if client == null or not client.request_conflict("conflict-state", "state"):
		conflict_panel.show_status("还没有连上世界，交战没有刷新。")
		return
	client.request_participation("participation-state", "state")


func _open_participation_panel() -> void:
	participation_panel.set_self_id(client.player_id if client != null else "")
	participation_panel.open_panel(participation_panel.view.duplicate(true))
	if client == null:
		participation_panel.show_status("参与制度需要进入共享世界。")
		return
	if not client.request_participation("participation-state", "state"):
		participation_panel.show_status("还没有连上世界，参与制度没有刷新。")


func _open_conflict_panel() -> void:
	conflict_panel.set_participation(participation_panel.view)
	conflict_panel.open_panel(conflict_panel.view.duplicate(true))
	if client == null:
		conflict_panel.show_status("交战需要进入共享世界。")
		return
	if not client.request_conflict("conflict-state", "state"):
		conflict_panel.show_status("还没有连上世界，交战没有刷新。")
	# The conflict view does not carry the regime; refresh the authoritative
	# participation view so the read-only header is not stale.
	client.request_participation("participation-state", "state")


func _open_public_works_panel() -> void:
	public_works_panel.open_panel(public_works_panel.view.duplicate(true))
	if client == null:
		public_works_panel.show_status("公共项目需要进入共享世界。")
		return
	if not client.request_public_works("public-works-state", "state"):
		public_works_panel.show_status("还没有连上世界，公共项目没有刷新。")


# ---------------------------------------------------------------- phase host

func _phase_host_declaration(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host joins as a named member over WSS")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.MEMBER,
		"The join reply confers the member role")
	await _prepare_assets(A_ACCOUNT, A_MERCHANT, A_BUY, A_UNIT, "host", true)
	await _prepare_fund_owner()

	var before: int = _participation_events.size()
	_open_participation_panel()
	var fresh: Dictionary = await _next_event(_participation_events, before,
		"participation state")
	_expect(bool(fresh.get("ok", false)),
		"The participation panel receives a real state reply")
	var fresh_state: Dictionary = _state(fresh)
	_expect(str(fresh_state.get("host", "")) == PLAYER_A,
		"The real participation view names the startup host")
	_expect(str(_regime(fresh_state).get("tier", "")) == Participation.TIER_PEACE,
		"The fresh authority regime is peace")
	_expect(participation_panel.is_open(), "Opening the participation panel shows it")
	_expect(_label_text(participation_panel, "Regime").contains("和平"),
		"The panel renders the authoritative peace regime")
	_expect(_label_text(participation_panel, "Host").contains(PLAYER_A)
			and _label_text(participation_panel, "Host").contains("你"),
		"The panel renders the authoritative host and marks the local player")
	var host_section: VBoxContainer = participation_panel.find_child(
		"HostSection", true, false) as VBoxContainer
	var player_section: VBoxContainer = participation_panel.find_child(
		"PlayerSection", true, false) as VBoxContainer
	_expect(host_section != null and host_section.visible,
		"The host sees the declaration controls")
	_expect(player_section != null and not player_section.visible,
		"The host is not offered the player-only actions")

	var now: float = float(fresh_state.get("now_utc", 0.0))
	_expect(now > 0.0, "The participation view carries the authority clock")
	_effective_utc = float(int(now) + 2)
	var tier: OptionButton = participation_panel.find_child("Tier", true, false) as OptionButton
	var declaration_id: LineEdit = participation_panel.find_child(
		"DeclarationId", true, false) as LineEdit
	var effective: LineEdit = participation_panel.find_child(
		"EffectiveUtc", true, false) as LineEdit
	var area_input: LineEdit = participation_panel.find_child(
		"AreaInput", true, false) as LineEdit
	var window_input: LineEdit = participation_panel.find_child(
		"WindowInput", true, false) as LineEdit
	var loss_cap: LineEdit = participation_panel.find_child(
		"LossCap", true, false) as LineEdit
	var offline_cap: LineEdit = participation_panel.find_child(
		"OfflineLossCap", true, false) as LineEdit
	var declare_button: Button = participation_panel.find_child(
		"DeclareRegime", true, false) as Button
	_expect(tier != null and declaration_id != null and effective != null
			and area_input != null and window_input != null and loss_cap != null
			and offline_cap != null and declare_button != null,
		"The participation panel exposes the host declaration fields")
	if tier == null or declare_button == null:
		return
	tier.select(1)
	declaration_id.text = DECLARATION_ID
	effective.text = str(int(_effective_utc))
	area_input.text = "%s,0,0,100,100" % AREA_ID
	window_input.text = "%s,%d,%d" % [WINDOW_ID, int(now - 60.0), int(now + 86400.0)]
	loss_cap.text = str(LOSS_CAP)
	offline_cap.text = str(LOSS_CAP)

	before = _participation_events.size()
	declare_button.pressed.emit()
	var declared: Dictionary = await _next_event(_participation_events, before,
		"regime declaration")
	_expect(bool(declared.get("ok", false)) and not bool(declared.get("duplicate", true)),
		"The host's declaration sent through the panel lands on the authority (%s)"
			% str(declared.get("reason", "")))
	var declared_state: Dictionary = _state(declared)
	var regime: Dictionary = _regime(declared_state)
	_expect(str(regime.get("tier", "")) == Participation.TIER_LIMITED
			and int(regime.get("revision", -1)) == 1,
		"The authoritative regime is limited at revision 1")
	_expect(absf(float(regime.get("effective_utc", 0.0)) - _effective_utc) < 0.001,
		"The authoritative effective time is the one entered in the panel")
	_expect(_ids(declared_state.get("areas")) == [AREA_ID]
			and _ids(declared_state.get("windows")) == [WINDOW_ID],
		"The authoritative view carries the panel's area and window")
	_expect(_label_text(participation_panel, "Regime").contains("有限冲突")
			and _label_text(participation_panel, "Regime").contains("第 1 版"),
		"The panel renders the authoritative limited regime")
	_expect(_label_text(participation_panel, "Regime").contains("在线上限 %d" % LOSS_CAP),
		"The panel renders the authoritative loss cap")
	_expect(participation_panel.find_child("Area_" + AREA_ID, true, false) != null,
		"The panel renders the authoritative area row")
	_expect(participation_panel.find_child("Window_" + WINDOW_ID, true, false) != null,
		"The panel renders the authoritative window row")
	_expect(_has_text(_list(participation_panel, "ParticipantList"), "还没有参与者。"),
		"The panel says there are no participants instead of inventing one")
	_expect(_panel_status(participation_panel).is_empty(),
		"A successful declaration clears the panel status")

	_expect(await _wait_for_effective(), "The authority clock passes the declared instant")

	# The panel deliberately hides player actions from the host, so the host's
	# defender consent is fixture setup sent directly over the real channel.
	before = _participation_events.size()
	_expect(client.request_participation(A_CONSENT, "declare", {
		"role": Participation.ROLE_DEFENDER, "command_id": A_CONSENT,
	}), "The host's defender consent is sent over channel 17")
	var consented: Dictionary = await _next_event(_participation_events, before,
		"host defender consent")
	_expect(bool(consented.get("ok", false)),
		"The host's defender consent lands on the authority")
	var host_row: Dictionary = _participant(_state(consented), PLAYER_A)
	_expect(bool(host_row.get("defender", false))
			and int(host_row.get("consent_revision", -1)) == 1,
		"The authoritative participant row records the host as defender")
	var host_label: Label = participation_panel.find_child(
		"Participant_" + PLAYER_A, true, false) as Label
	_expect(host_label != null and host_label.text.contains("防守方")
			and host_label.text.contains("同意第 1 版"),
		"The panel renders the authoritative participant row")

	var stored: Dictionary = _read_json(world_dir.path_join(ParticipationStore.MAIN))
	var stored_state: Dictionary = stored.get("state", {}) \
		if stored.get("state") is Dictionary else {}
	_expect(int(stored.get("version", -1)) == 1
			and int(_regime(stored_state).get("revision", -1)) == 1,
		"The declaration is persisted to participation.json")


# -------------------------------------------------------------- phase member

func _phase_member_consent_and_engage(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_B, NAME_B,
		PLAYER_SECRET_B), "The second member joins as a named member over WSS")
	if client == null or not client.joined:
		return
	await _prepare_assets(B_ACCOUNT, B_MERCHANT, B_BUY, B_UNIT, "member", false)
	var contribution: Dictionary = await _fund(B_CONTRIBUTE, "contribute", {
		"fund_id": _fund_id, "amount": CONTRIBUTION, "command_id": B_CONTRIBUTE,
	})
	_expect(bool(contribution.get("ok", false)),
		"The second member contributes to the organization fund")
	_expect(int(_fund_row(contribution, _fund_id).get("balance", -1)) == ROAD_COST,
		"The organization fund now holds the road's fixed cost")

	var before: int = _participation_events.size()
	_open_participation_panel()
	var view_reply: Dictionary = await _next_event(_participation_events, before,
		"member participation state")
	_expect(bool(view_reply.get("ok", false)),
		"The member's participation panel receives the authoritative state")
	var state: Dictionary = _state(view_reply)
	_expect(str(_regime(state).get("tier", "")) == Participation.TIER_LIMITED
			and int(_regime(state).get("revision", -1)) == 1,
		"The member sees the authoritative limited regime")
	_expect(_label_text(participation_panel, "Regime").contains("有限冲突")
			and _label_text(participation_panel, "Regime").contains("第 1 版"),
		"The member's panel renders the authoritative regime")
	_expect(_label_text(participation_panel, "Host").contains(PLAYER_A)
			and not _label_text(participation_panel, "Host").contains("你"),
		"The member's panel renders the host without marking it local")
	_expect(participation_panel.find_child("Area_" + AREA_ID, true, false) != null
			and participation_panel.find_child("Window_" + WINDOW_ID, true, false) != null,
		"The member's panel renders the authoritative area and window")
	var host_row: Label = participation_panel.find_child(
		"Participant_" + PLAYER_A, true, false) as Label
	_expect(host_row != null and host_row.text.contains("防守方"),
		"The member's panel renders the host's authoritative participant row")
	var host_section: VBoxContainer = participation_panel.find_child(
		"HostSection", true, false) as VBoxContainer
	var player_section: VBoxContainer = participation_panel.find_child(
		"PlayerSection", true, false) as VBoxContainer
	_expect(host_section != null and not host_section.visible,
		"A non-host member does not see the declaration controls")
	_expect(player_section != null and player_section.visible,
		"A non-host member sees the player actions")

	var role: OptionButton = participation_panel.find_child("Role", true, false) as OptionButton
	var consent_button: Button = participation_panel.find_child(
		"Consent", true, false) as Button
	_expect(role != null and consent_button != null,
		"The participation panel exposes the role and consent controls")
	if role == null or consent_button == null:
		return
	role.select(0)
	before = _participation_events.size()
	consent_button.pressed.emit()
	var consent: Dictionary = await _next_event(_participation_events, before,
		"member consent")
	_expect(bool(consent.get("ok", false)) and not bool(consent.get("duplicate", true)),
		"The member's consent sent through the panel lands on the authority")
	var member_row: Dictionary = _participant(_state(consent), PLAYER_B)
	_expect(bool(member_row.get("attacker", false))
			and not bool(member_row.get("defender", true))
			and int(member_row.get("consent_revision", -1)) == 1,
		"The authoritative participant row records the member as attacker")
	var member_label: Label = participation_panel.find_child(
		"Participant_" + PLAYER_B, true, false) as Label
	_expect(member_label != null and member_label.text.contains("进攻方")
			and member_label.text.contains("同意第 1 版"),
		"The panel renders the member's authoritative consent")
	_expect(_panel_status(participation_panel).is_empty(),
		"A successful consent clears the panel status")

	# Opening the conflict panel first refreshes the participation view, exactly
	# like main.gd, so the read-only regime header comes from the authority.
	var conflict_before: int = _conflict_events.size()
	var participation_before: int = _participation_events.size()
	_open_conflict_panel()
	var conflict_state: Dictionary = await _next_event(_conflict_events, conflict_before,
		"conflict state")
	var refreshed: Dictionary = await _next_event(_participation_events,
		participation_before, "participation refresh on conflict open")
	_expect(bool(conflict_state.get("ok", false)),
		"The conflict panel receives the authoritative conflict view")
	_expect(bool(refreshed.get("ok", false)),
		"Opening the conflict panel refreshes the authoritative participation view")
	_expect(conflict_panel.is_open(), "Opening the conflict panel shows it")
	_expect(_label_text(conflict_panel, "Regime").contains("有限冲突")
			and _label_text(conflict_panel, "Regime").contains("在线上限 %d" % LOSS_CAP),
		"The conflict panel renders the authoritative regime header")
	_expect(_label_text(conflict_panel, "Host").contains(PLAYER_A),
		"The conflict panel renders the authoritative host header")

	var defender: LineEdit = conflict_panel.find_child("Defender", true, false) as LineEdit
	var attacker_units: LineEdit = conflict_panel.find_child(
		"AttackerUnits", true, false) as LineEdit
	var defender_units: LineEdit = conflict_panel.find_child(
		"DefenderUnits", true, false) as LineEdit
	var x: LineEdit = conflict_panel.find_child("X", true, false) as LineEdit
	var z: LineEdit = conflict_panel.find_child("Z", true, false) as LineEdit
	var parcel: LineEdit = conflict_panel.find_child("TargetParcel", true, false) as LineEdit
	var engage: Button = conflict_panel.find_child("Engage", true, false) as Button
	var confirm: ConfirmationDialog = conflict_panel.find_child(
		"EngageConfirm", true, false) as ConfirmationDialog
	_expect(defender != null and attacker_units != null and defender_units != null
			and x != null and z != null and parcel != null and engage != null
			and confirm != null,
		"The conflict panel exposes the engage form")
	if engage == null or confirm == null:
		return
	defender.text = PLAYER_A
	attacker_units.text = B_UNIT
	defender_units.text = A_UNIT
	x.text = "5"
	z.text = "5"
	parcel.text = ""

	var view_before: Dictionary = conflict_panel.view.duplicate(true)
	conflict_before = _conflict_events.size()
	engage.pressed.emit()
	await process_frame
	_expect(_conflict_events.size() == conflict_before,
		"Clicking engage alone never reaches the authority")
	_expect(JSON.stringify(conflict_panel.view) == JSON.stringify(view_before),
		"The panel keeps the authority's last state before sending")
	confirm.get_ok_button().pressed.emit()
	var engaged: Dictionary = await _next_event(_conflict_events, conflict_before,
		"engagement")
	_expect(bool(engaged.get("ok", false)) and not bool(engaged.get("duplicate", true)),
		"The member's engagement sent through the panel is settled (%s)"
			% str(engaged.get("reason", "")))
	_expect(str(engaged.get("action", "")) == "engage",
		"The authoritative engagement reply names the action")
	var engaged_state: Dictionary = _state(engaged)
	var recent: Array = engaged_state.get("recent", []) \
		if engaged_state.get("recent") is Array else []
	_expect(recent.size() == 1,
		"The authoritative conflict view carries the settled engagement")
	var command_id: String = str((recent[0] as Dictionary).get("command_id", "")) \
		if not recent.is_empty() else ""
	_expect(_has_text(_list(conflict_panel, "RecentList"), PLAYER_B)
			and _has_text(_list(conflict_panel, "RecentList"), PLAYER_A),
		"The conflict panel renders the authoritative recent result")
	_expect(conflict_panel.find_child("Recent_" + command_id, true, false) != null,
		"The rendered recent row is keyed by the authoritative command id")
	_expect(_has_text(_list(conflict_panel, "TargetList"), "防守者 %s" % PLAYER_A),
		"The conflict panel renders the authoritative target")
	_expect(_has_text(_list(conflict_panel, "TargetList"),
			"累计损失 1/%d" % _view_target_cap(engaged_state, PLAYER_A)),
		"The conflict panel renders the authoritative loss budget")
	_expect(_panel_status(conflict_panel) == "交战已结算。",
		"A settled engagement reports the settlement")
	_expect(FileAccess.file_exists(world_dir.path_join(ConflictStore.MAIN)),
		"The settled engagement writes conflicts.json")
	_expect(_stored_target_lost(PLAYER_A) == 1,
		"conflicts.json stores the authoritative target loss")


# --------------------------------------------------------- phase public works

func _phase_public_works(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("member", "")), PLAYER_A, NAME_A,
		PLAYER_SECRET_A), "The host rejoins for the public works panel")
	if client == null or not client.joined:
		return
	var before: int = _works_events.size()
	_open_public_works_panel()
	var view: Dictionary = await _next_event(_works_events, before,
		"public works state")
	_expect(bool(view.get("ok", false)),
		"The public works panel receives the authoritative project view")
	_expect(public_works_panel.is_open(), "Opening the public works panel shows it")
	_expect(_has_text(_list(public_works_panel, "ProjectList"), "还没有公共项目。"),
		"The panel says there are no projects instead of inventing one")

	var project_id: LineEdit = public_works_panel.find_child(
		"ProjectId", true, false) as LineEdit
	var kind: OptionButton = public_works_panel.find_child("Kind", true, false) as OptionButton
	var parcel: LineEdit = public_works_panel.find_child(
		"ParcelId", true, false) as LineEdit
	var open_button: Button = public_works_panel.find_child(
		"OpenProject", true, false) as Button
	_expect(project_id != null and kind != null and parcel != null and open_button != null,
		"The public works panel exposes the registration fields")
	if project_id == null or kind == null or open_button == null:
		return
	project_id.text = ROAD_PROJECT
	kind.select(2)
	parcel.text = ""
	before = _works_events.size()
	open_button.pressed.emit()
	var opened: Dictionary = await _next_event(_works_events, before,
		"project registration")
	_expect(bool(opened.get("ok", false)) and str(opened.get("action", "")) == "open",
		"The project registration sent through the panel lands on the authority")
	var opened_row: Dictionary = _project_row(opened, ROAD_PROJECT)
	_expect(str(opened_row.get("kind", "")) == PublicWorks.KIND_ROAD_SEGMENT
			and str(opened_row.get("status", "")) == PublicWorks.STATUS_UNBUILT,
		"The authoritative project row is an unbuilt road")
	_expect(_project_text_has(ROAD_PROJECT, "石板路")
			and _project_text_has(ROAD_PROJECT, "已承诺 0")
			and _project_text_has(ROAD_PROJECT, "固定成本覆盖 0"),
		"The panel renders the authoritative unbuilt project row")
	_expect(_panel_status(public_works_panel).is_empty(),
		"A successful registration clears the panel status")

	var pledge_project: LineEdit = public_works_panel.find_child(
		"PledgeProject", true, false) as LineEdit
	var pledge_amount: LineEdit = public_works_panel.find_child(
		"PledgeAmount", true, false) as LineEdit
	var pledge_button: Button = public_works_panel.find_child(
		"Pledge", true, false) as Button
	_expect(pledge_project != null and pledge_amount != null and pledge_button != null,
		"The public works panel exposes the pledge fields")
	if pledge_project == null or pledge_amount == null or pledge_button == null:
		return
	pledge_project.text = ROAD_PROJECT
	pledge_amount.text = str(ROAD_COST)
	before = _works_events.size()
	pledge_button.pressed.emit()
	var pledged: Dictionary = await _next_event(_works_events, before,
		"project pledge")
	_expect(bool(pledged.get("ok", false)) and str(pledged.get("action", "")) == "pledge",
		"The pledge sent through the panel lands on the authority")
	var pledged_row: Dictionary = _project_row(pledged, ROAD_PROJECT)
	_expect(int(pledged_row.get("pledged", -1)) == ROAD_COST
			and int(pledged_row.get("funded", -1)) == ROAD_COST
			and str(pledged_row.get("status", "")) == PublicWorks.STATUS_FUNDED,
		"The authoritative project is fully funded")
	_expect(_project_text_has(ROAD_PROJECT, "已承诺 %d" % ROAD_COST)
			and _project_text_has(ROAD_PROJECT, "固定成本覆盖 %d" % ROAD_COST)
			and _project_text_has(ROAD_PROJECT, "已足额"),
		"The panel renders the authoritative funded project row")

	var build_project: LineEdit = public_works_panel.find_child(
		"BuildProject", true, false) as LineEdit
	var build_fund: LineEdit = public_works_panel.find_child(
		"BuildFund", true, false) as LineEdit
	var build_button: Button = public_works_panel.find_child(
		"Build", true, false) as Button
	_expect(build_project != null and build_fund != null and build_button != null,
		"The public works panel exposes the build fields")
	if build_project == null or build_fund == null or build_button == null:
		return
	build_project.text = ROAD_PROJECT
	build_fund.text = _fund_id
	before = _works_events.size()
	build_button.pressed.emit()
	var built: Dictionary = await _next_event(_works_events, before,
		"project build")
	_expect(bool(built.get("ok", false)) and str(built.get("action", "")) == "build",
		"The fund-backed build sent through the panel lands on the authority (%s)"
			% str(built.get("reason", "")))
	var built_row: Dictionary = _project_row(built, ROAD_PROJECT)
	_expect(str(built_row.get("status", "")) == PublicWorks.STATUS_BUILT
			and float(built_row.get("built_utc", 0.0)) > 0.0,
		"The authoritative project view reports the road built")
	_expect(_project_text_has(ROAD_PROJECT, "已建成")
			and _project_text_has(ROAD_PROJECT, "建成 "),
		"The panel renders the built project with its authoritative time")
	_expect(_panel_status(public_works_panel).contains("已建成"),
		"A successful build reports the project is built")

	var works_document: Dictionary = _read_json(
		world_dir.path_join(PublicWorksStore.MAIN))
	var stored: Dictionary = _stored_project(
		works_document.get("state", {}) if works_document.get("state") is Dictionary else {},
		ROAD_PROJECT)
	_expect(str(stored.get("status", "")) == PublicWorks.STATUS_BUILT,
		"The built project is persisted to public_works.json")
	var funds_document: Dictionary = _read_json(world_dir.path_join(FundStore.MAIN))
	var stored_fund: Dictionary = _fund_doc_row(
		funds_document.get("state", {}) if funds_document.get("state") is Dictionary else {},
		_fund_id)
	_expect(int(stored_fund.get("balance", -1)) == 0
			and int(stored_fund.get("spent", -1)) == ROAD_COST,
		"The fund document records the fixed-cost spend")

	# A refresh replaces the rendered list from the authority and writes nothing.
	var works_bytes: PackedByteArray = _bytes(
		world_dir.path_join(PublicWorksStore.MAIN))
	var fund_bytes: PackedByteArray = _bytes(world_dir.path_join(FundStore.MAIN))
	var refresh: Button = public_works_panel.find_child("Refresh", true, false) as Button
	before = _works_events.size()
	refresh.pressed.emit()
	var refreshed: Dictionary = await _next_event(_works_events, before,
		"public works refresh")
	_expect(bool(refreshed.get("ok", false))
			and _project_text_has(ROAD_PROJECT, "已建成"),
		"A refresh re-renders the same authoritative built project")
	_expect(_bytes(world_dir.path_join(PublicWorksStore.MAIN)) == works_bytes
			and _bytes(world_dir.path_join(FundStore.MAIN)) == fund_bytes,
		"Refreshing the public works panel writes nothing")
	var close_events: Array = []
	public_works_panel.closed.connect(func() -> void: close_events.append(true))
	public_works_panel.close_panel()
	await process_frame
	_expect(not public_works_panel.is_open() and close_events.size() == 1,
		"Closing the public works panel emits one close signal")
	_expect(_bytes(world_dir.path_join(PublicWorksStore.MAIN)) == works_bytes
			and _bytes(world_dir.path_join(FundStore.MAIN)) == fund_bytes,
		"Closing the public works panel writes nothing")


# --------------------------------------------------------------- phase visitor

func _phase_visitor(codes: Dictionary) -> void:
	_expect(await _open_client(str(codes.get("visitor", "")), VISITOR_ID, VISITOR_NAME,
		PLAYER_SECRET_VISITOR), "A visitor joins with the visitor code")
	if client == null or not client.joined:
		return
	_expect(str(client.member.role) == WorldInvite.VISITOR,
		"The visitor code confers the visitor role")

	# Participation: the visitor reads the authoritative room but may not write.
	var before: int = _participation_events.size()
	_open_participation_panel()
	var view: Dictionary = await _next_event(_participation_events, before,
		"visitor participation state")
	_expect(bool(view.get("ok", false)),
		"A visitor may read the participation view")
	_expect(_label_text(participation_panel, "Regime").contains("有限冲突")
			and _label_text(participation_panel, "Host").contains(PLAYER_A),
		"The visitor's panel renders the authoritative regime and host")
	var player_section: VBoxContainer = participation_panel.find_child(
		"PlayerSection", true, false) as VBoxContainer
	_expect(player_section != null and player_section.visible,
		"The visitor is offered the player actions so the authority can refuse them")
	var view_before: Dictionary = participation_panel.view.duplicate(true)
	var role: OptionButton = participation_panel.find_child("Role", true, false) as OptionButton
	var consent_button: Button = participation_panel.find_child(
		"Consent", true, false) as Button
	if role == null or consent_button == null:
		_expect(false, "The visitor's participation panel exposes the consent control")
		return
	role.select(0)
	before = _participation_events.size()
	consent_button.pressed.emit()
	var refused: Dictionary = await _next_event(_participation_events, before,
		"visitor participation refusal")
	_expect(not bool(refused.get("ok", true)),
		"A visitor's participation write is refused")
	_expect(str(refused.get("reason", "")) == "forbidden",
		"The participation refusal reason is forbidden")
	var reason_text: String = str(refused.get("reason_text", ""))
	_expect(not reason_text.is_empty(),
		"The participation refusal carries an authority reason text")
	_expect(_panel_status(participation_panel) == reason_text,
		"The participation panel shows the authority reason text verbatim")
	_expect(_same_participation_view(participation_panel.view, view_before),
		"The refused participation write leaves the view at the authority's last state")
	_expect(_label_text(participation_panel, "Regime").contains("有限冲突"),
		"The refused participation write does not clear the authoritative regime")

	# Conflict: the visitor reads targets and recent results, then is refused.
	var conflict_before: int = _conflict_events.size()
	var participation_before: int = _participation_events.size()
	_open_conflict_panel()
	var conflict_view: Dictionary = await _next_event(_conflict_events, conflict_before,
		"visitor conflict state")
	await _next_event(_participation_events, participation_before,
		"visitor participation refresh")
	_expect(bool(conflict_view.get("ok", false)),
		"A visitor may read the conflict view")
	_expect(_label_text(conflict_panel, "Regime").contains("有限冲突"),
		"The visitor's conflict panel renders the authoritative regime")
	_expect(_has_text(_list(conflict_panel, "TargetList"), "防守者 %s" % PLAYER_A),
		"The visitor's conflict panel renders the authoritative target")
	var recent_before: int = _recent_count(conflict_panel.view)
	var loss_before: int = _view_target_lost(conflict_panel.view, PLAYER_A)
	_expect(recent_before == 1 and loss_before == 1,
		"The visitor sees the settled engagement and target loss")

	var defender: LineEdit = conflict_panel.find_child("Defender", true, false) as LineEdit
	var attacker_units: LineEdit = conflict_panel.find_child(
		"AttackerUnits", true, false) as LineEdit
	var defender_units: LineEdit = conflict_panel.find_child(
		"DefenderUnits", true, false) as LineEdit
	var x: LineEdit = conflict_panel.find_child("X", true, false) as LineEdit
	var z: LineEdit = conflict_panel.find_child("Z", true, false) as LineEdit
	var engage: Button = conflict_panel.find_child("Engage", true, false) as Button
	var confirm: ConfirmationDialog = conflict_panel.find_child(
		"EngageConfirm", true, false) as ConfirmationDialog
	if defender == null or attacker_units == null or defender_units == null \
			or x == null or z == null or engage == null or confirm == null:
		_expect(false, "The visitor's conflict panel exposes the engage form")
		return
	defender.text = PLAYER_A
	attacker_units.text = B_UNIT
	defender_units.text = A_UNIT
	x.text = "5"
	z.text = "5"
	view_before = conflict_panel.view.duplicate(true)
	conflict_before = _conflict_events.size()
	engage.pressed.emit()
	await process_frame
	_expect(_conflict_events.size() == conflict_before,
		"The visitor's engage click alone never reaches the authority")
	confirm.get_ok_button().pressed.emit()
	refused = await _next_event(_conflict_events, conflict_before,
		"visitor engagement refusal")
	_expect(not bool(refused.get("ok", true)),
		"A visitor's engagement is refused")
	_expect(str(refused.get("reason", "")) == "forbidden",
		"The engagement refusal reason is forbidden")
	reason_text = str(refused.get("reason_text", ""))
	_expect(not reason_text.is_empty(),
		"The engagement refusal carries an authority reason text")
	_expect(_panel_status(conflict_panel) == reason_text,
		"The conflict panel shows the authority reason text verbatim")
	_expect(JSON.stringify(conflict_panel.view) == JSON.stringify(view_before),
		"The refused engagement leaves the view at the authority's last state")
	_expect(_recent_count(conflict_panel.view) == recent_before
			and _view_target_lost(conflict_panel.view, PLAYER_A) == loss_before,
		"The refused engagement adds no local battle result or loss")

	# Public works: the visitor reads the built project, and a registration is
	# refused without adding a local row.
	before = _works_events.size()
	_open_public_works_panel()
	var works_view: Dictionary = await _next_event(_works_events, before,
		"visitor public works state")
	_expect(bool(works_view.get("ok", false)),
		"A visitor may read the public works view")
	_expect(_project_text_has(ROAD_PROJECT, "已建成"),
		"The visitor's panel renders the authoritative built project")
	var project_count: int = public_works_panel.projects.size()
	var works_before: Dictionary = public_works_panel.view.duplicate(true)
	var project_id: LineEdit = public_works_panel.find_child(
		"ProjectId", true, false) as LineEdit
	var kind: OptionButton = public_works_panel.find_child("Kind", true, false) as OptionButton
	var open_button: Button = public_works_panel.find_child(
		"OpenProject", true, false) as Button
	if project_id == null or kind == null or open_button == null:
		_expect(false, "The visitor's public works panel exposes the registration fields")
		return
	project_id.text = "visitor_project"
	kind.select(0)
	before = _works_events.size()
	open_button.pressed.emit()
	var refused_works: Dictionary = await _next_event(_works_events, before,
		"visitor project refusal")
	_expect(not bool(refused_works.get("ok", true)),
		"A visitor's project registration is refused")
	_expect(str(refused_works.get("reason", "")) == "forbidden",
		"The project refusal reason is forbidden")
	reason_text = str(refused_works.get("reason_text", ""))
	_expect(not reason_text.is_empty(),
		"The project refusal carries an authority reason text")
	_expect(_panel_status(public_works_panel) == reason_text,
		"The public works panel shows the authority reason text verbatim")
	_expect(public_works_panel.projects.size() == project_count,
		"The refused registration adds no local project row")
	_expect(JSON.stringify(public_works_panel.view) == JSON.stringify(works_before),
		"The refused registration leaves the view at the authority's last state")

	# Refreshing and closing all three panels must not rewrite authority
	# documents: panels only ask for reads and never submit a write on exit.
	var participation_bytes: PackedByteArray = _bytes(
		world_dir.path_join(ParticipationStore.MAIN))
	var conflict_bytes: PackedByteArray = _bytes(
		world_dir.path_join(ConflictStore.MAIN))
	var works_bytes: PackedByteArray = _bytes(
		world_dir.path_join(PublicWorksStore.MAIN))
	var fund_bytes: PackedByteArray = _bytes(world_dir.path_join(FundStore.MAIN))
	_expect(not participation_bytes.is_empty() and not conflict_bytes.is_empty()
			and not works_bytes.is_empty() and not fund_bytes.is_empty(),
		"The authority documents exist before the read-only refresh probe")

	var participation_refresh: Button = participation_panel.find_child(
		"Refresh", true, false) as Button
	var conflict_refresh: Button = conflict_panel.find_child(
		"Refresh", true, false) as Button
	var works_refresh: Button = public_works_panel.find_child(
		"Refresh", true, false) as Button
	before = _participation_events.size()
	participation_refresh.pressed.emit()
	var refreshed: Dictionary = await _next_event(_participation_events, before,
		"visitor participation refresh")
	_expect(bool(refreshed.get("ok", false)),
		"Refreshing the participation panel is a read")
	conflict_before = _conflict_events.size()
	participation_before = _participation_events.size()
	conflict_refresh.pressed.emit()
	await _next_event(_conflict_events, conflict_before, "visitor conflict refresh")
	await _next_event(_participation_events, participation_before,
		"visitor participation refresh from conflict")
	before = _works_events.size()
	works_refresh.pressed.emit()
	await _next_event(_works_events, before, "visitor public works refresh")

	participation_panel.close_panel()
	conflict_panel.close_panel()
	public_works_panel.close_panel()
	await process_frame
	_expect(not participation_panel.is_open() and not conflict_panel.is_open()
			and not public_works_panel.is_open(),
		"All three panels close")
	_expect(_bytes(world_dir.path_join(ParticipationStore.MAIN)) == participation_bytes
			and _bytes(world_dir.path_join(ConflictStore.MAIN)) == conflict_bytes
			and _bytes(world_dir.path_join(PublicWorksStore.MAIN)) == works_bytes
			and _bytes(world_dir.path_join(FundStore.MAIN)) == fund_bytes,
		"Refreshing and closing the panels rewrites no authority document")


# ------------------------------------------------------------------ fixtures

func _prepare_assets(account_id: String, merchant_id: String, buy_id: String,
		unit_id: String, label: String, open_merchant: bool) -> void:
	var account: Dictionary = await _submit(FarmCommand.make_account_open(
		account_id, client.world_time()))
	_expect(bool(account.get("ok", false)),
		"The %s opens a real economy account" % label)
	if open_merchant:
		# The rule merchant is a single world market; the second member only
		# places a buy order against the market the first member opened.
		var merchant: Dictionary = await _submit(FarmCommand.make_market_open(
			merchant_id, client.world_time()))
		_expect(bool(merchant.get("ok", false)),
			"The %s opens the real rule merchant" % label)
	await _buy_supplies(buy_id, label)
	var recruited: Dictionary = await _unit(unit_id, "recruit", {
		"kind": "militia", "people": PEOPLE, "equipment": "none",
		"station": "farm_a", "command_id": unit_id,
	})
	_expect(bool(recruited.get("ok", false)) and not bool(recruited.get("duplicate", true)),
		"The %s recruits a real militia unit" % label)
	_expect(_unit_people(unit_id) == PEOPLE,
		"The %s's unit is in units.json" % label)


func _prepare_fund_owner() -> void:
	var created: Dictionary = await _organization(ORG_CREATE, "create", {
		"org_id": ORG, "name": "面板测试工程", "command_id": ORG_CREATE,
	})
	_expect(bool(created.get("ok", false)),
		"The host creates the organization through channels 11/12")
	_fund_id = PublicFund.fund_for(ORG)
	var opened: Dictionary = await _fund(FUND_OPEN, "open", {
		"org_id": ORG, "command_id": FUND_OPEN,
	})
	_expect(bool(opened.get("ok", false)),
		"The host opens the derived organization fund over channel 15")
	var contributed: Dictionary = await _fund(A_CONTRIBUTE, "contribute", {
		"fund_id": _fund_id, "amount": CONTRIBUTION, "command_id": A_CONTRIBUTE,
	})
	_expect(bool(contributed.get("ok", false)),
		"The host contributes to the organization fund")
	_expect(int(_fund_row(contributed, _fund_id).get("balance", -1)) == CONTRIBUTION,
		"The host's contribution reaches the fund")


func _buy_supplies(command_id: String, label: String) -> void:
	var now: float = client.world_time()
	var placed: Dictionary = await _submit(FarmCommand.make_market_place(
		command_id, "buy", "greens", GREENS_PRICE, SUPPLIES_TO_BUY,
		now + 3600.0, now))
	_expect(bool(placed.get("ok", false)),
		"The %s places a real buy order for greens" % label)
	var owner: String = str(client.player_id)
	var purchased: bool = await _wait(func() -> bool:
		return _supplies(_farm_doc(), owner) >= SUPPLIES_TO_BUY, 20000)
	_expect(purchased,
		"The authority's economy sweep delivers the merchant stock to the %s" % label)
	await create_timer(0.4).timeout


# ------------------------------------------------------------------- clients

func _open_client(code: String, player_id: String, display_name: String,
		secret_text: String) -> bool:
	_ready = false
	_refusals.clear()
	_participation_pending.clear()
	_conflict_pending.clear()
	_works_pending.clear()
	_unit_pending.clear()
	_fund_pending.clear()
	_organization_pending.clear()
	_command_pending.clear()
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
			_now: float) -> void:
		_ready = true)
	client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
	client.lost.connect(func(reason: String) -> void: _refusals.append(reason))
	client.participation_result.connect(participation_panel.apply_result)
	client.participation_result.connect(_on_participation_result)
	client.participation_result.connect(_mirror_participation_to_conflict)
	client.conflict_result.connect(conflict_panel.apply_result)
	client.conflict_result.connect(_on_conflict_result)
	client.public_works_result.connect(public_works_panel.apply_result)
	client.public_works_result.connect(_on_public_works_result)
	client.unit_result.connect(_on_unit_result)
	client.fund_result.connect(_on_fund_result)
	client.organization_result.connect(_on_organization_result)
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
	_participation_pending.clear()
	_conflict_pending.clear()
	_works_pending.clear()
	_unit_pending.clear()
	_fund_pending.clear()
	_organization_pending.clear()
	_command_pending.clear()
	await process_frame
	await process_frame
	await create_timer(0.2).timeout


func _on_participation_result(_request_id: String, payload: Dictionary) -> void:
	_participation_pending[_request_id] = payload
	_participation_events.append(payload.duplicate(true))


## Mirrors main.gd: the conflict panel's read-only header comes from the last
## authoritative participation view, whatever request produced it.
func _mirror_participation_to_conflict(_request_id: String, payload: Dictionary) -> void:
	if conflict_panel == null:
		return
	var state_value: Variant = payload.get("state")
	if state_value is Dictionary:
		conflict_panel.set_participation(state_value)


func _on_conflict_result(_request_id: String, payload: Dictionary) -> void:
	_conflict_pending[_request_id] = payload
	_conflict_events.append(payload.duplicate(true))


func _on_public_works_result(_request_id: String, payload: Dictionary) -> void:
	_works_pending[_request_id] = payload
	_works_events.append(payload.duplicate(true))


func _on_unit_result(request_id: String, payload: Dictionary) -> void:
	_unit_pending[request_id] = payload


func _on_fund_result(request_id: String, payload: Dictionary) -> void:
	_fund_pending[request_id] = payload


func _on_organization_result(request_id: String, payload: Dictionary) -> void:
	_organization_pending[request_id] = payload


func _on_committed(request_id: String, payload: Dictionary) -> void:
	_command_pending[request_id] = payload


func _submit(command: Dictionary) -> Dictionary:
	var request_id: String = str(command.get("id", ""))
	_command_pending.erase(request_id)
	if client == null or not client.submit(command):
		return {"ok": false, "reason": "not_sent"}
	var arrived: bool = await _wait(func() -> bool:
		return _command_pending.has(request_id), 15000)
	if not arrived:
		_expect(false, "A command reply arrives for %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _command_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


func _unit(request_id: String, action: String, args: Dictionary = {}) -> Dictionary:
	_unit_pending.erase(request_id)
	if client == null or not client.request_unit(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	var arrived: bool = await _wait(func() -> bool:
		return _unit_pending.has(request_id), 15000)
	if not arrived:
		_expect(false, "A unit reply arrives for %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _unit_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


func _organization(request_id: String, action: String,
		args: Dictionary = {}) -> Dictionary:
	_organization_pending.erase(request_id)
	if client == null or not client.request_organization(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	var arrived: bool = await _wait(func() -> bool:
		return _organization_pending.has(request_id), 15000)
	if not arrived:
		_expect(false, "An organization reply arrives for %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _organization_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


func _fund(request_id: String, action: String, args: Dictionary = {}) -> Dictionary:
	_fund_pending.erase(request_id)
	if client == null or not client.request_fund(request_id, action, args):
		return {"ok": false, "reason": "not_sent"}
	var arrived: bool = await _wait(func() -> bool:
		return _fund_pending.has(request_id), 15000)
	if not arrived:
		_expect(false, "A fund reply arrives for %s" % request_id)
		return {"ok": false, "reason": "no_reply"}
	var payload: Variant = _fund_pending.get(request_id, {})
	return (payload as Dictionary).duplicate(true) if payload is Dictionary else {}


# ------------------------------------------------------------------- replies

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


func _wait_for_effective() -> bool:
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var before: int = _participation_events.size()
		var request_id: String = "panels-clock-%d" % Time.get_ticks_usec()
		if client == null or not client.request_participation(request_id, "state"):
			return false
		var reply: Dictionary = await _next_event(_participation_events, before,
			"authority clock", 5000)
		if float(_state(reply).get("now_utc", 0.0)) >= _effective_utc:
			return true
		await create_timer(0.25).timeout
	return false


# --------------------------------------------------------------- state readers

func _state(reply: Dictionary) -> Dictionary:
	var value: Variant = reply.get("state")
	return value if value is Dictionary else {}


func _regime(state: Dictionary) -> Dictionary:
	var value: Variant = state.get("regime")
	return value if value is Dictionary else {}


func _participant(state: Dictionary, player_id: String) -> Dictionary:
	var rows: Variant = state.get("participants")
	if not rows is Array:
		return {}
	for value: Variant in rows:
		if value is Dictionary \
				and str((value as Dictionary).get("participant", "")) == player_id:
			return value
	return {}


func _ids(rows_value: Variant) -> Array:
	var ids: Array = []
	if not rows_value is Array:
		return ids
	for value: Variant in rows_value:
		if value is Dictionary:
			ids.append(str((value as Dictionary).get("id", "")))
	return ids


func _recent_count(view: Dictionary) -> int:
	var rows: Variant = view.get("recent")
	return rows.size() if rows is Array else 0


func _view_target_lost(view: Dictionary, target: String) -> int:
	var row: Dictionary = _view_target_row(view, target)
	return int(row.get("lost", -1)) if not row.is_empty() else -1


func _view_target_cap(view: Dictionary, target: String) -> int:
	var row: Dictionary = _view_target_row(view, target)
	return int(row.get("cap", -1)) if not row.is_empty() else -1


func _view_target_row(view: Dictionary, target: String) -> Dictionary:
	var rows: Variant = view.get("targets")
	if not rows is Array:
		return {}
	for value: Variant in rows:
		if value is Dictionary \
				and str((value as Dictionary).get("target", "")) == target:
			return value
	return {}


## The participation view carries the live authority clock, which advances even
## when a refused write changes nothing else. Everything else must survive the
## refusal unchanged.
func _same_participation_view(a: Dictionary, b: Dictionary) -> bool:
	var left: Dictionary = a.duplicate(true)
	var right: Dictionary = b.duplicate(true)
	left.erase("now_utc")
	right.erase("now_utc")
	return JSON.stringify(left) == JSON.stringify(right)


func _stored_target_lost(target: String) -> int:
	var state_value: Variant = _read_json(
		world_dir.path_join(ConflictStore.MAIN)).get("state")
	if not state_value is Dictionary:
		return -1
	var targets_value: Variant = (state_value as Dictionary).get("targets")
	if not targets_value is Dictionary:
		return -1
	var total: int = 0
	for key: Variant in targets_value:
		var row_value: Variant = (targets_value as Dictionary)[key]
		if row_value is Dictionary \
				and str((row_value as Dictionary).get("target", "")) == target:
			total += int((row_value as Dictionary).get("lost", 0))
	return total


func _project_row(reply: Dictionary, project_id: String) -> Dictionary:
	var state_value: Variant = reply.get("state")
	if not state_value is Dictionary:
		return {}
	var rows: Variant = (state_value as Dictionary).get("projects")
	if not rows is Array:
		return {}
	for value: Variant in rows:
		if value is Dictionary \
				and str((value as Dictionary).get("project_id", "")) == project_id:
			return value
	return {}


func _stored_project(document: Dictionary, project_id: String) -> Dictionary:
	var projects_value: Variant = document.get("projects")
	if not projects_value is Dictionary:
		return {}
	var row_value: Variant = (projects_value as Dictionary).get(project_id)
	return row_value if row_value is Dictionary else {}


func _fund_row(reply: Dictionary, fund_id: String) -> Dictionary:
	var state_value: Variant = reply.get("state")
	if not state_value is Dictionary:
		return {}
	var rows: Variant = (state_value as Dictionary).get("funds")
	if rows is Array:
		for value: Variant in rows:
			if value is Dictionary \
					and str((value as Dictionary).get("fund_id", "")) == fund_id:
				return value
		return {}
	return _fund_doc_row(state_value, fund_id)


func _fund_doc_row(document: Dictionary, fund_id: String) -> Dictionary:
	var funds_value: Variant = document.get("funds")
	if not funds_value is Dictionary:
		return {}
	var row_value: Variant = (funds_value as Dictionary).get(fund_id)
	return row_value if row_value is Dictionary else {}


func _farm_doc() -> Dictionary:
	var saved: Dictionary = _read_json(world_dir.path_join("farm.json"))
	var farm: Variant = saved.get("farm")
	return farm if farm is Dictionary else {}


func _units_doc() -> Dictionary:
	var saved: Dictionary = _read_json(world_dir.path_join("units.json"))
	var state: Variant = saved.get("state")
	return state if state is Dictionary else {}


func _unit_people(unit_id: String) -> int:
	var rows_value: Variant = _units_doc().get("units")
	if not rows_value is Dictionary:
		return 0
	var row_value: Variant = (rows_value as Dictionary).get(unit_id)
	if not row_value is Dictionary:
		return 0
	return int((row_value as Dictionary).get("people", 0))


func _supplies(farm: Dictionary, owner: String) -> int:
	var bags: Variant = farm.get("bags")
	if not bags is Dictionary:
		return 0
	var pocket: Variant = (bags as Dictionary).get(owner)
	if not pocket is Dictionary:
		return 0
	var total: int = 0
	for good_id: String in EconomyCatalog.goods_ids():
		total += int((pocket as Dictionary).get(good_id, 0))
	return total


# ------------------------------------------------------------------- panel UI

func _label_text(panel: Control, node_name: String) -> String:
	var label: Label = panel.find_child(node_name, true, false) as Label
	return label.text if label != null else ""


func _panel_status(panel: Control) -> String:
	return _label_text(panel, "Status")


func _list(panel: Control, node_name: String) -> VBoxContainer:
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


func _project_text_has(project_id: String, fragment: String) -> bool:
	var label: Label = public_works_panel.find_child(
		"Project_" + project_id, true, false) as Label
	return label != null and label.text.contains(fragment)


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
		"The status file records the startup host player")
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
	return "panels-%d-%d" % [Time.get_ticks_usec(), checks]


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("PANELS_NETWORK_INTEGRATION_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
