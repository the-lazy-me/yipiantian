extends SceneTree
## 组织面板作为视图：它只根据权威组织视图决定显示什么，并把点击变成组织操作
## 意图；谁能创建、加入、退出、任命或交接由权威决定。
##
## 没有网络：视图直接构造，面板不在这里发起任何请求。

const GovernancePanel = preload("res://ui/governance_panel.gd")

const NOW: float = 1800000000.0
const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"
const CAROL: String = "player_00000000000000000000000000000003"
const DAVE: String = "player_00000000000000000000000000000004"

var panel: GovernancePanel
var events: Array = []
var refreshes: int = 0
var closes: int = 0
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = GovernancePanel.new()
	panel.name = "Governance"
	root.add_child(panel)
	panel.org_action.connect(func(action: String, args: Dictionary) -> void:
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

	# Empty authority view: no organisations, but creating one is still offered.
	panel.present([], ALICE, true, "")
	var org_list: VBoxContainer = panel.find_child("OrgList", true, false) as VBoxContainer
	_expect(org_list != null and _has_text(org_list, "还没有组织。"),
		"An empty authority view says there are no organisations instead of inventing one")
	var create: Button = panel.find_child("CreateOrg", true, false) as Button
	var join: Button = panel.find_child("JoinOrg", true, false) as Button
	var leave: Button = panel.find_child("LeaveOrg", true, false) as Button
	var appoint: Button = panel.find_child("AppointOfficer", true, false) as Button
	var transfer: Button = panel.find_child("TransferLeadership", true, false) as Button
	_expect(create != null and not create.disabled, "Creating an organisation is offered when writable")
	_expect(join.disabled and leave.disabled and appoint.disabled and transfer.disabled,
		"Without a selected organisation the membership actions stay disabled")
	_expect(panel.find_child("OrgAction_river", true, false) == null,
		"No per-organisation action appears for an empty list")

	# One organisation: name, member count and my role are all shown.
	panel.present(_organizations(), ALICE, true, "")
	var river: Button = panel.find_child("OrgAction_river", true, false) as Button
	_expect(river != null and river.text.contains("河岸合作社") and river.text.contains("3 人")
		and river.text.contains("负责人"),
		"An organisation row names it, counts members and shows my role (got %s)"
			% (river.text if river != null else "null"))
	var harbor: Button = panel.find_child("OrgAction_harbor", true, false) as Button
	_expect(harbor != null and harbor.text.contains("港口行会") and harbor.text.contains("成员"),
		"A second organisation is listed with my role in it")
	_expect(panel.selected_id == "river", "The first organisation is selected for the detail view")
	var me: Label = panel.find_child("Member_" + ALICE, true, false) as Label
	_expect(me != null and me.text.contains("负责人") and me.text.contains("我"),
		"My own member row names my role and marks me (got %s)" % (me.text if me != null else "null"))
	var bob_row: Label = panel.find_child("Member_" + BOB, true, false) as Label
	_expect(bob_row != null and bob_row.text.contains("干事"),
		"Every member is listed with their role")
	_expect(panel._target.item_count == 2,
		"The other two members can be chosen as the target (got %d)" % panel._target.item_count)

	# The same view seen by another member: my role follows the view, not a cache.
	panel.present(_organizations(), BOB, true, "")
	river = panel.find_child("OrgAction_river", true, false) as Button
	_expect(river != null and river.text.contains("干事"),
		"My role in the list follows the authoritative view")

	# Selecting another organisation moves the member detail with it.
	harbor = panel.find_child("OrgAction_harbor", true, false) as Button
	harbor.pressed.emit()
	await process_frame
	_expect(panel.selected_id == "harbor", "Clicking an organisation selects it")
	var dave_row: Label = panel.find_child("Member_" + DAVE, true, false) as Label
	_expect(dave_row != null and dave_row.text.contains("负责人"),
		"The selected organisation's members and roles are shown")
	_expect(panel.find_child("Member_" + ALICE, true, false) != null,
		"A member who belongs to both organisations still appears")
	panel.present(_organizations(), ALICE, true, "")
	_expect(panel.selected_id == "harbor",
		"A refresh keeps the organisation selected by id")

	# A player who is not a member can ask to join; a member can ask to leave.
	panel.present(_organizations(), DAVE, true, "")
	# The selection is preserved by id, so point it at an organisation DAVE is not
	# in before checking the membership buttons.
	(panel.find_child("OrgAction_river", true, false) as Button).pressed.emit()
	await process_frame
	join = panel.find_child("JoinOrg", true, false) as Button
	leave = panel.find_child("LeaveOrg", true, false) as Button
	_expect(not join.disabled and leave.disabled,
		"A non-member is offered joining and not leaving")
	var before: int = events.size()
	join.pressed.emit()
	await process_frame
	_expect(events.size() == before + 1 and events.back().action == "join"
		and events.back().args.org_id == panel.selected_id,
		"Joining names the selected organisation")
	panel.present(_organizations(), ALICE, true, "")
	join = panel.find_child("JoinOrg", true, false) as Button
	leave = panel.find_child("LeaveOrg", true, false) as Button
	_expect(join.disabled and not leave.disabled,
		"A member is offered leaving and not joining")
	leave.pressed.emit()
	await process_frame
	_expect(events.back().action == "leave" and events.back().args.org_id == panel.selected_id,
		"Leaving names the selected organisation")

	# Appoint and transfer carry the organisation, the chosen member and the role.
	panel.present(_organizations(), ALICE, true, "")
	appoint = panel.find_child("AppointOfficer", true, false) as Button
	transfer = panel.find_child("TransferLeadership", true, false) as Button
	_expect(not appoint.disabled and not transfer.disabled,
		"With another member present, appointing and transferring are offered")
	var bob_index: int = _target_index(BOB)
	_expect(bob_index >= 0, "The chosen member can be found in the target list")
	panel._target.select(bob_index)
	appoint.pressed.emit()
	await process_frame
	_expect(events.back().action == "appoint" and events.back().args.org_id == "river"
		and events.back().args.player_id == BOB and events.back().args.role == "officer",
		"Appointing sends the organisation, the member and the officer role")
	panel._target.select(_target_index(BOB))
	transfer.pressed.emit()
	await process_frame
	_expect(events.back().action == "transfer_leadership" and events.back().args.org_id == "river"
		and events.back().args.player_id == BOB,
		"Transferring sends the organisation and the next leader")

	# Creation only collects a name; a blank one never becomes a request.
	var name_field: LineEdit = panel.find_child("OrgName", true, false) as LineEdit
	name_field.text = "  新合作社  "
	create = panel.find_child("CreateOrg", true, false) as Button
	before = events.size()
	create.pressed.emit()
	await process_frame
	_expect(events.size() == before + 1 and events.back().action == "create"
		and events.back().args.name == "新合作社",
		"Creating an organisation sends its trimmed name")
	name_field.text = "   "
	before = events.size()
	create.pressed.emit()
	await process_frame
	_expect(events.size() == before and panel._status.text.contains("先写一个组织名称"),
		"A blank organisation name is refused before it becomes a request")

	# The status line is the authority's reason text.
	panel.present(_organizations(), ALICE, true, "负责人必须先交接给其他成员。")
	_expect(panel._status.text.contains("负责人必须先交接"),
		"The bottom status line shows the authority's reason text")
	var refresh: Button = panel.find_child("Refresh", true, false) as Button
	refresh.pressed.emit()
	await process_frame
	_expect(refreshes == 1 and panel._status.text.is_empty(),
		"Refreshing asks for a new view and clears the stale status")

	# A visitor sees the same organisations but cannot write.
	panel.present(_organizations(), ALICE, false, "访客只能查看组织，不能创建或管理。")
	_expect(panel.find_child("OrgAction_river", true, false) != null,
		"A read-only view still lists the organisations")
	_expect((panel.find_child("CreateOrg", true, false) as Button).disabled
		and (panel.find_child("JoinOrg", true, false) as Button).disabled
		and (panel.find_child("LeaveOrg", true, false) as Button).disabled
		and (panel.find_child("AppointOfficer", true, false) as Button).disabled
		and (panel.find_child("TransferLeadership", true, false) as Button).disabled,
		"Read-only mode disables every write button")
	_expect(not name_field.editable, "Read-only mode stops editing the organisation name")
	_expect(panel._status.text.contains("访客"),
		"Read-only mode shows why the actions are unavailable")

	# Focus ownership, focus restoration across a refresh, Tab wrapping and Esc.
	panel.present(_organizations(), ALICE, true, "")
	panel.show()
	await process_frame
	var focus_owner: Control = root.gui_get_focus_owner()
	_expect(focus_owner != null and panel.is_ancestor_of(focus_owner),
		"Opening the organisation panel captures keyboard focus inside it")
	var scroll: ScrollContainer = panel.find_child("Scroll", true, false) as ScrollContainer
	_expect(scroll != null and scroll.follow_focus,
		"The organisation list scrolls to follow keyboard focus")
	var river_button: Button = panel.find_child("OrgAction_river", true, false) as Button
	river_button.grab_focus()
	panel.present(_organizations(), ALICE, true, "")
	var restored: Control = root.gui_get_focus_owner()
	_expect(restored != null and restored.name == "OrgAction_river" and restored != river_button,
		"Refreshing the view restores focus to the same organisation")
	var transfer_button: Button = panel.find_child("TransferLeadership", true, false) as Button
	transfer_button.grab_focus()
	var tab_event := InputEventKey.new()
	tab_event.keycode = KEY_TAB
	tab_event.pressed = true
	root.push_input(tab_event)
	await process_frame
	_expect(root.gui_get_focus_owner() == panel.find_child("Refresh", true, false),
		"Real Tab input wraps from the last organisation control back to the first")
	tab_event.pressed = false
	root.push_input(tab_event)
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(not panel.is_open(), "Esc closes the organisation panel")
	_expect(closes == 1, "Closing the panel emits exactly one close signal")
	_expect(root.gui_get_focus_owner() == opener,
		"Closing returns keyboard focus to the HUD button that opened the panel")
	_finish()


func _organizations() -> Array:
	return [
		{
			"id": "river", "name": "河岸合作社", "created_utc": NOW,
			"members": {ALICE: "leader", BOB: "officer", CAROL: "member"},
			"roles": {"leader": {"can_spend": true, "can_manage": true},
				"officer": {"can_spend": true, "can_manage": false},
				"member": {"can_spend": false, "can_manage": false}},
		},
		{
			"id": "harbor", "name": "港口行会", "created_utc": NOW,
			"members": {DAVE: "leader", ALICE: "member"},
			"roles": {"leader": {"can_spend": true, "can_manage": true},
				"officer": {"can_spend": true, "can_manage": false},
				"member": {"can_spend": false, "can_manage": false}},
		},
	]


func _target_index(player_id: String) -> int:
	for index: int in panel._target.item_count:
		if str(panel._target.get_item_metadata(index)) == player_id:
			return index
	return -1


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
	print("GOVERNANCE_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
