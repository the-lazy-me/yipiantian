extends SceneTree
## 公共项目面板作为视图：它只根据权威项目视图决定显示什么，并把点击变成公共
## 项目操作意图；谁能登记、承诺、退回或用基金建成，以及基金余额是否足够，都由
## 权威决定。
##
## 没有网络：视图直接构造，面板在测试里通过一个假远程对象转发请求与答复。

const PublicWorksPanel = preload("res://ui/public_works_panel.gd")

const PROJECT_A: String = "project_a"
const PROJECT_B: String = "project_b"
const PROJECT_C: String = "project_c"
const FUND_A: String = "fund_org-a"


class FakeRemote extends RefCounted:
	signal public_works_result(request_id: String, payload: Dictionary)

	var calls: Array = []

	func request_public_works(request_id: String, action: String,
			args: Dictionary = {}) -> bool:
		calls.append({
			"request_id": request_id, "action": action,
			"args": args.duplicate(true),
		})
		return true


var panel: PublicWorksPanel
var fake: FakeRemote
var closes: int = 0
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = PublicWorksPanel.new()
	panel.name = "PublicWorksPanel"
	root.add_child(panel)
	fake = FakeRemote.new()
	fake.public_works_result.connect(panel.apply_result)
	panel.public_works_action.connect(_forward_action)
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

	# Empty authority view: the list says so instead of inventing a project.
	panel.open_panel({})
	var project_list: VBoxContainer = panel.find_child("ProjectList", true, false) as VBoxContainer
	_expect(panel.is_open(), "Opening the panel shows it")
	_expect(project_list != null and _has_text(project_list, "还没有公共项目。"),
		"An empty authority view says there are no public projects")

	# Multi-row view: rows are sorted by project id and every authoritative field
	# is shown with the agreed kind and status wording.
	panel.open_panel(_projects())
	_expect(panel.projects.size() == 3, "All authoritative projects are kept in the view")
	var first: Label = _row_label(0)
	var second: Label = _row_label(1)
	var third: Label = _row_label(2)
	_expect(first != null and first.name == "Project_" + PROJECT_A,
		"Rows are sorted by project id (got %s)" % (first.name if first != null else "null"))
	_expect(second != null and second.name == "Project_" + PROJECT_B,
		"The second row follows the sort order")
	_expect(third != null and third.name == "Project_" + PROJECT_C,
		"The third row follows the sort order")
	var first_text: String = first.text if first != null else ""
	var second_text: String = second.text if second != null else ""
	var third_text: String = third.text if third != null else ""
	_expect(first_text.contains("村口广场"), "village_square is shown as 村口广场")
	_expect(second_text.contains("公井"), "public_well is shown as 公井")
	_expect(third_text.contains("石板路"), "road_segment is shown as 石板路")
	_expect(first_text.contains("parcel_1"), "A row shows its parcel id")
	_expect(second_text.contains("未绑定"), "An unbound parcel is shown as 未绑定")
	_expect(first_text.contains("已承诺 350"), "A row shows the authoritative pledged total")
	_expect(first_text.contains("固定成本覆盖 300"),
		"A row shows the authoritative funded amount")
	_expect(first_text.contains("已足额"), "The funded status is shown in words")
	_expect(second_text.contains("未建"), "The unbuilt status is shown in words")
	_expect(third_text.contains("已建成"), "The built status is shown in words")
	_expect(third_text.contains("建成 1234"), "A built row shows its authoritative built time")
	var focus_owner: Control = root.gui_get_focus_owner()
	_expect(focus_owner != null and panel.is_ancestor_of(focus_owner),
		"Opening the public works panel captures keyboard focus inside it")
	var scroll: ScrollContainer = panel.find_child("Scroll", true, false) as ScrollContainer
	_expect(scroll != null and scroll.follow_focus,
		"The project list scrolls to follow keyboard focus")

	# The refresh button asks the caller for a fresh authoritative view.
	var refresh: Button = panel.find_child("Refresh", true, false) as Button
	var before: int = fake.calls.size()
	refresh.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "state"
		and fake.calls.back().request_id == "public-works-state",
		"Refreshing asks the caller for the authoritative state")

	# Registering carries the project id, selected kind and trimmed parcel id.
	var open_project: LineEdit = panel.find_child("ProjectId", true, false) as LineEdit
	var kind: OptionButton = panel.find_child("Kind", true, false) as OptionButton
	var parcel: LineEdit = panel.find_child("ParcelId", true, false) as LineEdit
	var parcel_choice: OptionButton = panel.find_child("ParcelChoice", true, false) as OptionButton
	var open_button: Button = panel.find_child("OpenProject", true, false) as Button
	_expect(parcel_choice != null, "The registration row offers a parcel picker")
	panel.set_parcels(["parcel_03", "parcel_01", "parcel_03", "", " parcel_02 "])
	_expect(parcel_choice != null and parcel_choice.item_count == 4,
		"Parcel choices deduplicate and skip empty ids (got %d options)"
		% (parcel_choice.item_count if parcel_choice != null else -1))
	_expect(parcel_choice != null and parcel_choice.get_item_text(0) == "不绑定",
		"The first parcel option is 不绑定")
	_expect(parcel_choice != null and parcel_choice.get_item_text(1) == "parcel_01"
		and parcel_choice.get_item_text(2) == "parcel_02"
		and parcel_choice.get_item_text(3) == "parcel_03",
		"Parcel choices are trimmed and sorted by id")
	parcel.text = ""
	parcel_choice.select(2)
	parcel_choice.item_selected.emit(2)
	_expect(parcel.text == "parcel_02",
		"Choosing a parcel writes its id into the parcel text field")
	parcel_choice.select(0)
	parcel_choice.item_selected.emit(0)
	_expect(parcel.text.is_empty(), "Choosing 不绑定 clears the parcel text")
	parcel.text = "parcel_02"
	panel.set_parcels(["parcel_02", "parcel_01"])
	_expect(parcel_choice.item_count == 3 and parcel_choice.selected == 2,
		"Rebuilding choices keeps typed text and selects the matching option")
	panel.set_parcels([])
	_expect(parcel_choice.item_count == 1 and parcel_choice.get_item_text(0) == "不绑定",
		"Without a cadastre the picker still offers only 不绑定")
	open_project.text = "  project_d  "
	kind.select(1)
	parcel.text = "  parcel_9  "
	before = fake.calls.size()
	open_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "open",
		"Registering a project emits an open intent")
	var args: Dictionary = fake.calls.back().args
	_expect(args.get("project_id") == "project_d",
		"The open request carries the trimmed project id (got %s)" % str(args.get("project_id")))
	_expect(args.get("kind") == "public_well",
		"The selected kind is sent verbatim (got %s)" % str(args.get("kind")))
	_expect(args.get("parcel_id") == "parcel_9",
		"The open request carries the trimmed parcel id")
	_expect(not str(args.get("command_id", "")).is_empty(),
		"An open request carries a non-empty request id")
	_expect(fake.calls.back().request_id == args.get("command_id"),
		"The request id doubles as the command id")
	open_project.text = ""
	before = fake.calls.size()
	open_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("项目 id"),
		"An empty project id never becomes a request")
	open_project.text = "project_e"
	panel.set_parcels(["parcel_01", "parcel_02", "parcel_03"])
	parcel_choice.select(3)
	parcel_choice.item_selected.emit(3)
	before = fake.calls.size()
	open_button.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1
		and fake.calls.back().args.get("parcel_id") == "parcel_03",
		"A picked parcel id still travels as the request's text value")

	# Pledging needs a project and a positive whole amount. The panel never checks
	# whether the project exists or how much funding it still needs.
	var pledge_project: LineEdit = panel.find_child("PledgeProject", true, false) as LineEdit
	var pledge_amount: LineEdit = panel.find_child("PledgeAmount", true, false) as LineEdit
	var pledge: Button = panel.find_child("Pledge", true, false) as Button
	pledge_project.text = "  project_a  "
	pledge_amount.text = "25"
	before = fake.calls.size()
	pledge.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "pledge",
		"Pledging emits a pledge intent")
	args = fake.calls.back().args
	_expect(args.get("project_id") == "project_a", "The pledge names the trimmed project")
	_expect(int(args.get("amount", 0)) == 25, "The pledge carries the entered amount")
	_expect(not str(args.get("command_id", "")).is_empty(),
		"A pledge carries a non-empty request id")
	_expect(fake.calls.back().request_id == args.get("command_id"),
		"The pledge request id doubles as the command id")
	for bad_amount: String in ["0", "-3", "abc", ""]:
		pledge_amount.text = bad_amount
		before = fake.calls.size()
		pledge.pressed.emit()
		await process_frame
		_expect(fake.calls.size() == before and _status().contains("正整数"),
			"An amount %s is refused before it becomes a request" % ("(empty)" if bad_amount.is_empty() else bad_amount))
	pledge_amount.text = "10"
	pledge_project.text = ""
	before = fake.calls.size()
	pledge.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("项目 id"),
		"An empty pledge project never becomes a request")

	# Releasing a pledge carries the project and the amount to take back.
	var release_project: LineEdit = panel.find_child("ReleaseProject", true, false) as LineEdit
	var release_amount: LineEdit = panel.find_child("ReleaseAmount", true, false) as LineEdit
	var release: Button = panel.find_child("Release", true, false) as Button
	release_project.text = "  project_a  "
	release_amount.text = "10"
	before = fake.calls.size()
	release.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "release",
		"Releasing a pledge emits a release intent")
	args = fake.calls.back().args
	_expect(args.get("project_id") == "project_a", "The release names the trimmed project")
	_expect(int(args.get("amount", 0)) == 10, "The release carries the entered amount")
	_expect(not str(args.get("command_id", "")).is_empty(),
		"A release carries a non-empty request id")
	release_amount.text = "0"
	before = fake.calls.size()
	release.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("正整数"),
		"A non-positive release amount never becomes a request")

	# Building carries the project and the fund chosen by the player; whether the
	# project is funded, the fund exists or its keeper may spend is left to the
	# authority.
	var build_project: LineEdit = panel.find_child("BuildProject", true, false) as LineEdit
	var build_fund: LineEdit = panel.find_child("BuildFund", true, false) as LineEdit
	var build: Button = panel.find_child("Build", true, false) as Button
	build_project.text = "  project_c  "
	build_fund.text = "  " + FUND_A + "  "
	before = fake.calls.size()
	build.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before + 1 and fake.calls.back().action == "build",
		"Building emits a build intent")
	args = fake.calls.back().args
	_expect(args.get("project_id") == "project_c", "The build names the trimmed project")
	_expect(args.get("fund_id") == FUND_A, "The build names the trimmed fund id")
	_expect(not args.has("amount"), "The panel does not decide the fixed cost itself")
	_expect(not str(args.get("command_id", "")).is_empty(),
		"A build carries a non-empty request id")
	build_fund.text = ""
	before = fake.calls.size()
	build.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("基金 id"),
		"An empty fund id never becomes a build request")
	build_project.text = ""
	build_fund.text = FUND_A
	before = fake.calls.size()
	build.pressed.emit()
	await process_frame
	_expect(fake.calls.size() == before and _status().contains("项目 id"),
		"An empty build project never becomes a request")

	# A successful authority reply replaces the whole view, removing old rows.
	fake.public_works_result.emit("state-req", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": false,
		"action": "state", "state": {"projects": [_project(
			"project_z", "road_segment", "parcel_z", 120, 140, "built", 9000.0)]},
	})
	await process_frame
	_expect(panel.projects.size() == 1, "The reply's state replaces the project list")
	_expect(_row_label(0) != null and _row_label(0).name == "Project_project_z",
		"The replacement project is rendered")
	_expect(panel.find_child("Project_" + PROJECT_A, true, false) == null,
		"A project missing from the reply is not kept locally")
	_expect(_status().is_empty(), "A successful state reply clears the status line")

	# A refused reply shows the authority's own reason and never edits the view.
	fake.public_works_result.emit("pledge-req", {
		"ok": false, "reason": "not_member",
		"reason_text": "只有世界成员可以承诺公共项目。", "duplicate": false,
		"action": "pledge",
		"state": {"projects": [_project(
			"project_z", "road_segment", "parcel_z", 120, 140, "built", 9000.0)]},
	})
	await process_frame
	_expect(_status().contains("只有世界成员"),
		"A refused reply shows the authority's reason text")
	_expect(panel.projects.size() == 1
		and _row_label(0).text.contains("已承诺 140"),
		"A refused reply leaves the pledged total exactly as the authority sent it")

	# Without a reason text the raw reason code is shown instead.
	fake.public_works_result.emit("build-req", {
		"ok": false, "reason": "underfunded", "reason_text": "", "duplicate": false,
		"action": "build", "state": {"projects": []},
	})
	await process_frame
	_expect(_status().contains("underfunded"),
		"A refused reply without a reason text shows the authority reason code")

	# A successful build reply tells the player the project is built.
	fake.public_works_result.emit("build-req", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": false,
		"action": "build", "state": {"projects": [_project(
			"project_z", "road_segment", "parcel_z", 120, 140, "built", 9000.0)]},
	})
	await process_frame
	_expect(_status().contains("已建成"), "A successful build reports the project is built")
	fake.public_works_result.emit("build-req", {
		"ok": true, "reason": "", "reason_text": "", "duplicate": true,
		"action": "build", "state": {"projects": []},
	})
	await process_frame
	_expect(_status().contains("已经执行过"), "A duplicate reply is reported")

	# Malformed payloads do not crash the panel.
	panel.apply_result("", {})
	_expect(panel.projects.is_empty() and _has_text(project_list, "还没有公共项目。"),
		"A payload without a state keeps the rendered list unchanged")
	panel.apply_result("state-req", {"ok": true, "state": {"projects": []}})
	_expect(panel.projects.is_empty() and _has_text(project_list, "还没有公共项目。"),
		"An empty state empties the rendered project list")
	panel.open_panel({"projects": ["bad", {"project_id": "project_x"}]})
	_expect(panel.projects.size() == 1 and _row_label(0) != null,
		"Malformed rows are skipped and a bare row still renders without crashing")
	panel.show_status("")
	_expect(_status().is_empty(), "Writing an empty status clears it")

	# An open dropdown owns the next Esc, then Esc closes the panel and returns
	# focus to the HUD button that opened it.
	panel.open_panel(_projects())
	kind.get_popup().show()
	await process_frame
	_expect(panel.is_popup_open(), "An open kind dropdown reports that it owns Esc")
	kind.get_popup().hide()
	await process_frame
	_expect(not panel.is_popup_open(), "Hiding the dropdown releases Esc ownership")
	var close_button: Button = panel.find_child("Close", true, false) as Button
	close_button.grab_focus()
	await process_frame
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	_expect(not panel.is_open(), "Esc closes the public works panel")
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
	fake.request_public_works(request_id, action, payload)


func _request_refresh() -> void:
	fake.request_public_works("public-works-state", "state")


func _projects() -> Dictionary:
	return {
		"projects": [
			_project(PROJECT_C, "road_segment", "", 120, 130, "built", 1234.0),
			_project(PROJECT_B, "public_well", "", 50, 50, "unbuilt", 0.0),
			_project(PROJECT_A, "village_square", "parcel_1", 300, 350, "funded", 0.0),
		],
	}


func _project(project_id: String, kind: String, parcel_id: String, funded: int,
		pledged: int, status: String, built_utc: float) -> Dictionary:
	return {
		"project_id": project_id, "kind": kind, "parcel_id": parcel_id,
		"funded": funded, "pledged": pledged, "status": status,
		"built_utc": built_utc,
	}


func _row_label(index: int) -> Label:
	var list: VBoxContainer = panel.find_child("ProjectList", true, false) as VBoxContainer
	if list == null or index < 0 or index >= list.get_child_count():
		return null
	var child: Node = list.get_child(index)
	return child as Label


func _status() -> String:
	var label: Label = panel.find_child("Status", true, false) as Label
	return label.text if label != null else ""


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
	print("PUBLIC_WORKS_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
