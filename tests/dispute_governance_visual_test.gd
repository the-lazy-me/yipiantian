extends SceneTree
## 窗口渲染证据：治理面板的解散态与纠纷面板的警告行。
##
## 用与 `governance_panel_test` / `dispute_panel_test` 相同的权威视图夹具实例化
## 两个真实面板，在非 headless 窗口中逐张保存 PNG 到
## `.local/verification/dispute-governance-visual/`。测试本身只断言可见文本、
## 禁用态和产物尺寸；文字是否被裁切由人工查看图片确认。
##
## 运行（必须不带 `--headless`）：
##   Godot --path Game --audio-driver Dummy --script tests/dispute_governance_visual_test.gd

const GovernancePanel = preload("res://ui/governance_panel.gd")
const DisputePanel = preload("res://ui/dispute_panel.gd")

const NOW: float = 1800000000.0
const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"
const CAROL: String = "player_00000000000000000000000000000003"
const DAVE: String = "player_00000000000000000000000000000004"

var governance: GovernancePanel
var dispute: DisputePanel
var folder: String = ""
var shots: Array[String] = []
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	folder = ProjectSettings.globalize_path(
		"res://../.local/verification/dispute-governance-visual")
	DirAccess.make_dir_recursive_absolute(folder)
	root.size = Vector2i(1600, 1000)
	DisplayServer.window_set_size(Vector2i(1600, 1000))
	# canvas_items keeps a fixed base viewport; match it to the window so the
	# captured texture is the full 1600x1000 rather than the 1600x900 project base.
	root.content_scale_size = Vector2i(1600, 1000)
	# Keep the dissolve confirmation inside the viewport texture.
	root.gui_embed_subwindows = true
	governance = GovernancePanel.new()
	governance.name = "Governance"
	root.add_child(governance)
	dispute = DisputePanel.new()
	dispute.name = "DisputePanel"
	root.add_child(dispute)
	await process_frame
	await process_frame
	print("WINDOW size=%s viewport=%s" % [
		str(DisplayServer.window_get_size()), str(root.get_texture().get_size()),
	])

	# 1. 已解散组织：行上显示“已解散”，所有写按钮禁用。
	var closed_rows: Array = _organizations()
	(closed_rows[0] as Dictionary)["status"] = "closed"
	(closed_rows[0] as Dictionary)["closed_utc"] = NOW
	governance.present(closed_rows, ALICE, true, "")
	governance.show()
	await process_frame
	await process_frame
	var closed_row: Button = governance.find_child("OrgAction_river", true, false) as Button
	_expect(closed_row != null and closed_row.text.contains("已解散"),
		"The closed organisation row says 已解散 (got %s)"
			% (closed_row.text if closed_row != null else "null"))
	_expect(_button("JoinOrg").disabled and _button("LeaveOrg").disabled
		and _button("AppointOfficer").disabled
		and _button("TransferLeadership").disabled
		and _button("DissolveOrg").disabled,
		"A closed organisation disables every write action")
	await _shot("01-governance-closed.png")

	# 2. 未关闭的负责人视图：“解散组织”按钮可用。
	governance.present(_organizations(), ALICE, true, "")
	governance.show()
	await process_frame
	await process_frame
	var dissolve: Button = _button("DissolveOrg")
	_expect(not dissolve.disabled,
		"The leader of an active organisation can dissolve it")
	_expect(dissolve.text == "解散组织", "The dissolve button keeps its label")
	await _shot("02-governance-leader-dissolve.png")

	# 3. 确认框弹出态：文案完整，取消不发送请求。
	dissolve.pressed.emit()
	await process_frame
	await process_frame
	var confirm: ConfirmationDialog = governance.find_child(
		"DissolveConfirm", true, false) as ConfirmationDialog
	_expect(confirm != null and confirm.visible,
		"Clicking dissolve opens the confirmation")
	_expect(confirm != null and confirm.dialog_text.contains("解散不可撤销")
		and confirm.dialog_text.contains("退还给缴入的成员"),
		"The dissolve confirmation shows its full irreversible-refund text")
	await _shot("03-governance-dissolve-confirm.png")
	confirm.get_cancel_button().pressed.emit()
	await process_frame
	governance.hide()
	await process_frame
	await process_frame

	# 4. 纠纷面板：警告行与无警告案件同时出现，警告窗口与 RECORD-26 一致。
	dispute.open_panel(_view(false, BOB))
	await process_frame
	await process_frame
	var warning_row: Label = dispute.find_child("Case_case_corrected", true, false) as Label
	_expect(warning_row != null
		and warning_row.text.contains("警告 生效中｜UTC 1500 至 2593500"),
		"The warning case renders the active window from the authority (got %s)"
			% (warning_row.text if warning_row != null else "null"))
	var plain_row: Label = dispute.find_child("Case_case_filed", true, false) as Label
	_expect(plain_row != null and not plain_row.text.contains("警告"),
		"A case without an authoritative warning shows no warning line")
	await _shot("04-dispute-warning.png")

	# 5. 无 warning 的案件对照：同一面板只保留无警告案件。
	var plain_view: Dictionary = _view(false, BOB)
	plain_view.cases = [(plain_view.cases as Array)[1]]
	plain_view.public = [(plain_view.public as Array)[1]]
	dispute.open_panel(plain_view)
	await process_frame
	await process_frame
	var only_row: Label = dispute.find_child("Case_case_filed", true, false) as Label
	_expect(only_row != null and dispute.find_child("Case_case_corrected", true, false) == null
		and not only_row.text.contains("警告"),
		"The control view shows only the case without a warning")
	await _shot("05-dispute-no-warning.png")

	_finish()


# ------------------------------------------------------------------ fixtures

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


## 与 `dispute_panel_test._view()` / `_case()` 相同的权威视图：第一个案件带
## `warning`（active，UTC 1500 至 2593500），第二个案件没有警告。
func _view(authority: bool, viewer: String) -> Dictionary:
	return {
		"available": true, "now_utc": 4321.0, "viewer": viewer,
		"is_authority": authority,
		"authority_roles": {"admin": [ALICE], "arbiter": [CAROL]},
		"cases": [
			_case("case_corrected", "corrected", true),
			_case("case_filed", "filed", false),
		],
		"public": [
			{"case_id": "case_corrected", "status": "corrected", "filed_utc": 900.0},
			{"case_id": "case_filed", "status": "filed", "filed_utc": 1000.0},
		],
	}


func _case(case_id: String, status: String, warning: bool) -> Dictionary:
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
	if not warning:
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


# ------------------------------------------------------------------ helpers

func _button(node_name: String) -> Button:
	return governance.find_child(node_name, true, false) as Button


func _shot(name: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	var path: String = folder.path_join(name)
	var error: Error = image.save_png(path)
	_expect(error == OK and FileAccess.file_exists(path), "Saved " + name)
	_expect(image.get_width() >= 1600 and image.get_height() >= 1000,
		"%s is at least 1600x1000 (got %dx%d)"
			% [name, image.get_width(), image.get_height()])
	print("SHOT %s %dx%d" % [path, image.get_width(), image.get_height()])
	shots.append(path)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("DISPUTE_GOVERNANCE_VISUAL_TEST checks=%d failures=%d dir=%s" % [
		checks, failures.size(), folder,
	])
	quit(0 if failures.is_empty() else 1)
