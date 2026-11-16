extends Control
## 纠纷面板：把权威发来的纠纷视图摆出来，并把点击变成纠纷操作意图。
##
## 面板不判断管理员身份、案件状态、证据窗口或申诉资格：这些都由权威文档与规则
## 决定。这里只依据视图里的 `is_authority` 决定是否显示管理员区，把动作原样交给
## 调用方，因此没有网络也能测。
##
## 视图整份替换，面板不合并增量，也不在本地放行、改写、删除或补全任何案件。

signal dispute_action(action: String, args: Dictionary)
signal refresh_requested
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const INK := FarmTheme.INK

const STATUS_LABELS := {
	"filed": "已立案", "accepted": "已受理", "rejected": "已驳回",
	"ruled": "已裁定", "appealed": "已申诉", "corrected": "已更正",
	"closed": "已结案",
}
const EVIDENCE_KINDS: Array[Array] = [
	["authority_event", "权威事件"], ["ledger", "账目"], ["witness", "证人"],
	["chat", "对话"], ["document", "文件"],
]
const OUTCOMES: Array[Array] = [
	["upheld", "维持"], ["dismissed", "驳回"], ["warning", "警告"],
	["compensation", "补偿"],
]

## 权威纠纷视图：
## `{available, now_utc, viewer, is_authority, authority_roles, cases, public}`。
var view: Dictionary = {}
## 权威案件行，按案件编号排序；面板只渲染它们，不推导状态或权限。
var cases: Array = []
## 权威公开状态行，按案件编号排序；公开行不含证据、裁定、申诉或审计细节。
var public_rows: Array = []

var _focus_before: Control
## A message written while the panel is hidden belongs to the next open.
var _status_pending: bool = false
var _authority_status: Label
var _roster: Label
var _case_list: VBoxContainer
var _public_list: VBoxContainer
var _party_section: VBoxContainer
var _admin_section: VBoxContainer
var _file_case: LineEdit
var _file_against: LineEdit
var _file_events: LineEdit
var _file_button: Button
var _evidence_case: LineEdit
var _evidence_id: LineEdit
var _evidence_kind: OptionButton
var _evidence_source: LineEdit
var _evidence_button: Button
var _appeal_case: LineEdit
var _appeal_reason: LineEdit
var _appeal_button: Button
var _admin_case: LineEdit
var _rule_outcome: OptionButton
var _rule_amount: LineEdit
var _rule_reason: LineEdit
var _rule_advisor: CheckBox
var _accept_button: Button
var _reject_button: Button
var _rule_button: Button
var _correct_button: Button
var _close_case_button: Button
var _status: Label
var _confirm: ConfirmationDialog
var _pending_action: Dictionary = {}
var _request_counter: int = 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = FarmTheme.create()
	var dim := ColorRect.new()
	dim.color = Color(0.08, 0.1, 0.09, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var paper := PanelContainer.new()
	paper.add_theme_stylebox_override("panel", FarmTheme.framed_paper(FarmTheme.PAPER))
	paper.custom_minimum_size = Vector2(900, 680)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	paper.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	column.add_child(header)
	var title := Label.new()
	title.text = "纠纷"
	title.add_theme_color_override("font_color", INK)
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var refresh := _button(header, "刷新", "Refresh", 84.0)
	refresh.pressed.connect(func() -> void:
		_clear_status()
		refresh_requested.emit())
	var close_button := _button(header, "收起", "Close", 84.0)
	close_button.pressed.connect(func() -> void: close_panel())
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	scroll.add_child(body)
	_heading(body, "纠纷状态")
	_authority_status = _add(body, "")
	_authority_status.name = "AuthorityStatus"
	_roster = _add(body, "")
	_roster.name = "AuthorityRoster"
	_heading(body, "案件")
	_case_list = _list(body, "CaseList")
	_heading(body, "公开状态")
	_public_list = _list(body, "PublicList")
	_party_section = VBoxContainer.new()
	_party_section.name = "PartySection"
	_party_section.add_theme_constant_override("separation", 10)
	body.add_child(_party_section)
	_build_party_section()
	_admin_section = VBoxContainer.new()
	_admin_section.name = "AdminSection"
	_admin_section.add_theme_constant_override("separation", 10)
	body.add_child(_admin_section)
	_build_admin_section()
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	_confirm = ConfirmationDialog.new()
	_confirm.name = "DisputeConfirm"
	_confirm.ok_button_text = "确定"
	_confirm.cancel_button_text = "取消"
	_confirm.confirmed.connect(_confirmed_action)
	_confirm.canceled.connect(func() -> void: _pending_action = {})
	add_child(_confirm)
	_fill_view()
	visibility_changed.connect(_on_visibility_changed)
	hide()


func _build_party_section() -> void:
	_heading(_party_section, "立案")
	var file_row := HBoxContainer.new()
	file_row.add_theme_constant_override("separation", 8)
	_party_section.add_child(file_row)
	_file_case = _field(file_row, "FileCaseId", "案件编号", 190.0)
	_file_against = _field(file_row, "FileAgainst", "被举报人玩家 id", 240.0)
	_file_events = _field(file_row, "FileEvents", "权威事件 id，逗号分隔", 0.0)
	_file_button = _button(_party_section, "立案", "FileCase", 140.0)
	_file_button.pressed.connect(_request_file)
	_heading(_party_section, "提交证据")
	var evidence_row := HBoxContainer.new()
	evidence_row.add_theme_constant_override("separation", 8)
	_party_section.add_child(evidence_row)
	_evidence_case = _field(evidence_row, "EvidenceCaseId", "案件编号", 190.0)
	_evidence_id = _field(evidence_row, "EvidenceId", "证据 id", 170.0)
	_evidence_kind = OptionButton.new()
	_evidence_kind.name = "EvidenceKind"
	_evidence_kind.custom_minimum_size.x = 150
	evidence_row.add_child(_evidence_kind)
	for item: Array in EVIDENCE_KINDS:
		_evidence_kind.add_item(str(item[1]))
		_evidence_kind.set_item_metadata(_evidence_kind.item_count - 1, item[0])
	FarmTheme.configure_option(_evidence_kind)
	var source_row := HBoxContainer.new()
	source_row.add_theme_constant_override("separation", 8)
	_party_section.add_child(source_row)
	_evidence_source = _field(source_row, "EvidenceSource", "来源（事件 id 或文件）", 0.0)
	_evidence_button = _button(_party_section, "提交证据", "SubmitEvidence", 140.0)
	_evidence_button.pressed.connect(_request_evidence)
	_heading(_party_section, "申诉")
	var appeal_row := HBoxContainer.new()
	appeal_row.add_theme_constant_override("separation", 8)
	_party_section.add_child(appeal_row)
	_appeal_case = _field(appeal_row, "AppealCaseId", "案件编号", 190.0)
	_appeal_reason = _field(appeal_row, "AppealReason", "申诉理由", 0.0)
	_appeal_button = _button(_party_section, "申诉", "Appeal", 140.0)
	_appeal_button.pressed.connect(_request_appeal)


func _build_admin_section() -> void:
	_heading(_admin_section, "管理员操作（权威花名册）")
	var case_row := HBoxContainer.new()
	case_row.add_theme_constant_override("separation", 8)
	_admin_section.add_child(case_row)
	_admin_case = _field(case_row, "AdminCaseId", "案件编号", 280.0)
	_accept_button = _button(case_row, "受理", "Accept", 110.0)
	_accept_button.pressed.connect(_request_accept)
	_reject_button = _button(case_row, "驳回", "Reject", 110.0)
	_reject_button.pressed.connect(_request_reject)
	_heading(_admin_section, "裁定")
	var rule_row := HBoxContainer.new()
	rule_row.add_theme_constant_override("separation", 8)
	_admin_section.add_child(rule_row)
	_rule_outcome = OptionButton.new()
	_rule_outcome.name = "RuleOutcome"
	_rule_outcome.custom_minimum_size.x = 150
	rule_row.add_child(_rule_outcome)
	for item: Array in OUTCOMES:
		_rule_outcome.add_item(str(item[1]))
		_rule_outcome.set_item_metadata(_rule_outcome.item_count - 1, item[0])
	FarmTheme.configure_option(_rule_outcome)
	_rule_amount = _field(rule_row, "CompensationAmount", "补偿金额", 110.0)
	_rule_amount.visible = false
	_rule_outcome.item_selected.connect(_sync_rule_amount)
	_rule_reason = _field(rule_row, "RuleReason", "裁定理由", 0.0)
	_rule_advisor = CheckBox.new()
	_rule_advisor.name = "RuleAdvisor"
	_rule_advisor.text = "仅建议（由权威判定 advisory_only）"
	rule_row.add_child(_rule_advisor)
	_rule_button = _button(_admin_section, "裁定", "Rule", 140.0)
	_rule_button.pressed.connect(_request_rule)
	_heading(_admin_section, "更正与结案")
	var correct_row := HBoxContainer.new()
	correct_row.add_theme_constant_override("separation", 8)
	_admin_section.add_child(correct_row)
	_correct_button = _button(correct_row, "更正", "Correct", 120.0)
	_correct_button.pressed.connect(_request_correct)
	_close_case_button = _button(correct_row, "结案", "CloseCase", 120.0)
	_close_case_button.pressed.connect(_request_close)


## Rebuilds from the authoritative dispute view. The panel never merges rows
## itself; the next authority reply replaces the whole view.
func open_panel(next: Dictionary = {}) -> void:
	var focus_key: String = FarmTheme.focus_key_within(self)
	_apply_view(next)
	if not _status_pending:
		_status.text = ""
	_status_pending = false
	show()
	if visible:
		FarmTheme.wrap_focus(self, focus_key)


func show_status(text: String) -> void:
	_status.text = text
	_status_pending = not visible and not text.is_empty()


func is_open() -> bool:
	return visible


## True while the confirmation or a dropdown owns the next Esc.
func is_popup_open() -> bool:
	if _confirm != null and _confirm.visible:
		return true
	for option: OptionButton in [_evidence_kind, _rule_outcome]:
		if option.get_popup().visible:
			return true
	return false


func close_panel() -> void:
	if not visible:
		return
	_confirm.hide()
	_pending_action = {}
	for option: OptionButton in [_evidence_kind, _rule_outcome]:
		option.get_popup().hide()
	hide()
	closed.emit()


## The authority reply is the only source of dispute facts. A refused action
## keeps whatever view the reply carried and shows the authority's own reason
## text; the panel never decides an outcome or edits a case.
func apply_result(_request_id: String, payload: Dictionary) -> void:
	var state_value: Variant = payload.get("state")
	if state_value is Dictionary:
		_apply_view(state_value)
	var text: String = str(payload.get("reason_text", ""))
	if text.is_empty():
		text = str(payload.get("reason", ""))
	if not bool(payload.get("ok", false)):
		show_status(text if not text.is_empty() else "纠纷操作被拒绝。")
		return
	if bool(payload.get("duplicate", false)):
		show_status("这条纠纷操作已经执行过。")
		return
	match str(payload.get("action", "")):
		"file":
			show_status("案件已立案。")
		"evidence":
			show_status("证据已提交。")
		"accept":
			show_status("案件已受理。")
		"reject":
			show_status("案件已驳回。")
		"rule":
			show_status("裁定已记录。")
		"appeal":
			show_status("申诉已提交。")
		"correct":
			show_status("更正已记录。")
		"close":
			show_status("案件已结案。")
		_:
			_clear_status()


func _apply_view(next: Dictionary) -> void:
	view = next.duplicate(true)
	cases = _case_rows(view)
	public_rows = _public_rows(view)
	_fill_view()


func _fill_view() -> void:
	if _authority_status == null:
		return
	_authority_status.text = _authority_text()
	_fill_roster()
	_fill_cases()
	_fill_public()
	_update_sections()


func _update_sections() -> void:
	if _admin_section == null:
		return
	_admin_section.visible = bool(view.get("is_authority", false))


func _authority_text() -> String:
	if not bool(view.get("available", false)):
		return "纠纷权威未开放。"
	var now_utc: int = int(float(view.get("now_utc", 0.0)))
	var viewer: String = str(view.get("viewer", ""))
	var role: String
	if bool(view.get("is_authority", false)):
		role = "管理员"
	elif viewer.is_empty():
		role = "访客"
	else:
		role = "玩家 " + viewer
	return "权威已开放｜当前 UTC %d｜视角 %s" % [now_utc, role]


func _fill_roster() -> void:
	_roster.visible = bool(view.get("is_authority", false))
	if not _roster.visible:
		_roster.text = ""
		return
	var roles_value: Variant = view.get("authority_roles")
	var roles: Dictionary = roles_value if roles_value is Dictionary else {}
	_roster.text = "权威花名册｜管理 %s｜仲裁 %s" % [
		_join_ids(roles.get("admin")), _join_ids(roles.get("arbiter")),
	]


func _join_ids(value: Variant) -> String:
	if not value is Array or (value as Array).is_empty():
		return "无"
	var ids: Array[String] = []
	for entry: Variant in value:
		ids.append(str(entry))
	return "、".join(PackedStringArray(ids))


func _fill_cases() -> void:
	_clear(_case_list)
	if cases.is_empty():
		_add(_case_list, "还没有案件。")
		return
	for value: Variant in cases:
		var row: Dictionary = value
		var label := Label.new()
		label.name = "Case_" + str(row.get("case_id", ""))
		label.text = _case_text(row)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", INK)
		label.add_theme_font_size_override("font_size", 16)
		_case_list.add_child(label)


func _fill_public() -> void:
	_clear(_public_list)
	if public_rows.is_empty():
		_add(_public_list, "还没有公开状态。")
		return
	for value: Variant in public_rows:
		var row: Dictionary = value
		var label := Label.new()
		label.name = "Public_" + str(row.get("case_id", ""))
		label.text = "公开 %s｜状态 %s｜立案 UTC %d" % [
			str(row.get("case_id", "")), _status_text(str(row.get("status", ""))),
			int(float(row.get("filed_utc", 0.0))),
		]
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", INK)
		label.add_theme_font_size_override("font_size", 16)
		_public_list.add_child(label)


func _case_text(row: Dictionary) -> String:
	var evidence: Array = row.get("evidence", []) if row.get("evidence") is Array else []
	var appeals: Array = row.get("appeals", []) if row.get("appeals") is Array else []
	var corrections: Array = row.get("corrections", []) if row.get("corrections") is Array else []
	var audit: Array = row.get("audit", []) if row.get("audit") is Array else []
	var lines: Array[String] = [
		"案件 %s｜立案 %s｜被举报 %s｜状态 %s" % [
			str(row.get("case_id", "")), str(row.get("filed_by", "")),
			str(row.get("against", "")), _status_text(str(row.get("status", ""))),
		],
		"证据 %d｜裁定 %s｜申诉 %d｜更正 %d｜审计 %d" % [
			evidence.size(), _ruling_text(row.get("ruling")), appeals.size(),
			corrections.size(), audit.size(),
		],
	]
	var warning_value: Variant = row.get("warning")
	if warning_value is Dictionary and bool((warning_value as Dictionary).get("ok", false)):
		var warning: Dictionary = warning_value
		lines.append("警告 %s｜UTC %d 至 %d" % [
			_warning_text(str(warning.get("status", ""))),
			int(float(warning.get("starts_utc", 0.0))),
			int(float(warning.get("expires_utc", 0.0))),
		])
	for index: int in audit.size():
		var entry_value: Variant = audit[index]
		if entry_value is Dictionary:
			var entry: Dictionary = entry_value
			lines.append("审计 %d：%s｜%s｜UTC %d" % [
				index + 1, str(entry.get("action", "")), str(entry.get("by", "")),
				int(float(entry.get("at_utc", 0.0))),
			])
	return "\n".join(lines)


func _ruling_text(value: Variant) -> String:
	if not value is Dictionary or (value as Dictionary).is_empty():
		return "未裁定"
	var ruling: Dictionary = value
	return "%s｜%s｜UTC %d｜%s" % [
		str(ruling.get("outcome", "")), str(ruling.get("by", "")),
		int(float(ruling.get("at_utc", 0.0))), str(ruling.get("reason", "")),
	]


func _status_text(status: String) -> String:
	var label: String = str(STATUS_LABELS.get(status, ""))
	return "%s（%s）" % [label, status] if not label.is_empty() else status


func _warning_text(status: String) -> String:
	match status:
		"active": return "生效中"
		"expired": return "已到期"
		"not_started": return "未开始"
	return status


func _request_file() -> void:
	if _file_button.disabled:
		return
	var case_id: String = _file_case.text.strip_edges()
	if case_id.is_empty():
		show_status("先填写案件编号。")
		return
	var against: String = _file_against.text.strip_edges()
	if against.is_empty():
		show_status("先填写被举报人玩家 id。")
		return
	var events: Dictionary = _parse_ids(_file_events.text, "权威事件 id")
	if not bool(events.get("ok", false)):
		show_status(str(events.get("reason", "")))
		return
	_clear_status()
	dispute_action.emit("file", {
		"command_id": _new_request_id("file"), "case_id": case_id,
		"against": against, "event_ids": events.ids,
	})


func _request_evidence() -> void:
	if _evidence_button.disabled:
		return
	var case_id: String = _evidence_case.text.strip_edges()
	if case_id.is_empty():
		show_status("先填写案件编号。")
		return
	var evidence_id: String = _evidence_id.text.strip_edges()
	if evidence_id.is_empty():
		show_status("先填写证据 id。")
		return
	var source: String = _evidence_source.text.strip_edges()
	if source.is_empty():
		show_status("先填写证据来源。")
		return
	_clear_status()
	dispute_action.emit("evidence", {
		"command_id": _new_request_id("evidence"), "case_id": case_id,
		"evidence_id": evidence_id, "kind": _selected_meta(_evidence_kind),
		"source": source,
	})


func _request_appeal() -> void:
	if _appeal_button.disabled:
		return
	var case_id: String = _appeal_case.text.strip_edges()
	if case_id.is_empty():
		show_status("先填写案件编号。")
		return
	var reason: String = _appeal_reason.text.strip_edges()
	if reason.is_empty():
		show_status("先填写申诉理由。")
		return
	_clear_status()
	dispute_action.emit("appeal", {
		"command_id": _new_request_id("appeal"), "case_id": case_id,
		"reason": reason,
	})


func _request_accept() -> void:
	_send_admin_action("accept")


func _request_reject() -> void:
	_send_admin_action("reject")


## 受理与驳回只是状态切换；裁定、更正和结案会写审计或终结案件，先二次确认。
func _send_admin_action(action: String) -> void:
	if _admin_case == null:
		return
	var case_id: String = _admin_case.text.strip_edges()
	if case_id.is_empty():
		show_status("先填写案件编号。")
		return
	_clear_status()
	dispute_action.emit(action, {
		"command_id": _new_request_id(action), "case_id": case_id,
	})


func _request_rule() -> void:
	var case_id: String = _admin_case.text.strip_edges()
	if case_id.is_empty():
		show_status("先填写案件编号。")
		return
	var reason: String = _rule_reason.text.strip_edges()
	if reason.is_empty():
		show_status("先填写裁定理由。")
		return
	# The advisor flag is forwarded verbatim. The authority alone decides whether
	# it is advisory-only; the panel does not pre-judge or suppress the request.
	var advisor: bool = _rule_advisor.button_pressed
	var outcome: String = _selected_meta(_rule_outcome)
	var args: Dictionary = {
		"command_id": _new_request_id("rule"), "case_id": case_id,
		"decision": {
			"advisor": advisor, "authority": not advisor,
			"outcome": outcome, "reason": reason,
		},
	}
	var note: String = "确定提交裁定吗？裁定会写入权威案件与审计记录。"
	if outcome == "compensation" and not advisor:
		# A real compensation moves cash at ruling time. The amount is part of the
		# request; the authority checks accounts, balance and one-time execution.
		var amount_text: String = _rule_amount.text.strip_edges()
		if not amount_text.is_valid_int() or int(amount_text) < 1:
			show_status("补偿裁定要填写正整数金额。")
			return
		args["amount"] = int(amount_text)
		note = "确定提交补偿裁定吗？会从被裁定方转出补偿金额。"
	_open_confirm("rule", args, note)


func _sync_rule_amount(index: int) -> void:
	if _rule_amount == null or index < 0 or index >= _rule_outcome.item_count:
		return
	_rule_amount.visible = str(_rule_outcome.get_item_metadata(index)) == "compensation"


func _request_correct() -> void:
	var case_id: String = _admin_case.text.strip_edges()
	if case_id.is_empty():
		show_status("先填写案件编号。")
		return
	var reason: String = _rule_reason.text.strip_edges()
	if reason.is_empty():
		show_status("先填写更正理由。")
		return
	_open_confirm("correct", {
		"command_id": _new_request_id("correct"), "case_id": case_id,
		"reason": reason,
	}, "确定提交更正吗？更正会追加记录并保留原裁定。")


func _request_close() -> void:
	var case_id: String = _admin_case.text.strip_edges()
	if case_id.is_empty():
		show_status("先填写案件编号。")
		return
	_open_confirm("close", {
		"command_id": _new_request_id("close"), "case_id": case_id,
	}, "确定结案吗？结案后不再受理证据或更正。")


func _open_confirm(action: String, args: Dictionary, text: String) -> void:
	_pending_action = {"action": action, "args": args}
	_confirm.dialog_text = text
	_confirm.popup_centered()


func _confirmed_action() -> void:
	if _pending_action.is_empty():
		return
	var action: String = str(_pending_action.get("action", ""))
	var args: Dictionary = _pending_action.get("args", {})
	_pending_action = {}
	_clear_status()
	dispute_action.emit(action, args)


## Splits a comma-separated id list. Only empty fields are refused here; id
## validity and event existence stay with the authority.
func _parse_ids(text: String, label: String) -> Dictionary:
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty():
		return {"ok": false, "reason": "先填写%s。" % label}
	var ids: Array = []
	for piece: String in trimmed.split(",", true):
		var entry: String = piece.strip_edges()
		if entry.is_empty():
			return {"ok": false, "reason": "%s 请用逗号分隔填写。" % label}
		ids.append(entry)
	return {"ok": true, "ids": ids}


func _selected_meta(option: OptionButton) -> String:
	if option == null or option.selected < 0:
		return ""
	return str(option.get_item_metadata(option.selected))


func _new_request_id(action: String) -> String:
	_request_counter += 1
	return "dispute-%s-%d-%d" % [action, Time.get_ticks_usec(), _request_counter]


## Copies the rows so the panel's view never aliases the authority document, and
## sorts by case id regardless of reply order.
func _case_rows(source: Dictionary) -> Array:
	var rows: Array = []
	var value: Variant = source.get("cases")
	if value is Array:
		for row_value: Variant in value:
			if row_value is Dictionary:
				rows.append((row_value as Dictionary).duplicate(true))
	elif value is Dictionary:
		for case_id: Variant in (value as Dictionary).keys():
			var row_value: Variant = (value as Dictionary)[case_id]
			if row_value is Dictionary:
				var row: Dictionary = (row_value as Dictionary).duplicate(true)
				if not row.has("case_id"):
					row["case_id"] = str(case_id)
				rows.append(row)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("case_id", "")) < str(b.get("case_id", "")))
	return rows


func _public_rows(source: Dictionary) -> Array:
	var rows: Array = []
	var value: Variant = source.get("public")
	if value is Array:
		for row_value: Variant in value:
			if row_value is Dictionary:
				rows.append((row_value as Dictionary).duplicate(true))
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("case_id", "")) < str(b.get("case_id", "")))
	return rows


func _on_visibility_changed() -> void:
	if visible:
		if _focus_before == null and is_inside_tree():
			_focus_before = get_viewport().gui_get_focus_owner()
		# A message written while hidden belongs to this open; a stale one goes.
		if not _status_pending:
			_status.text = ""
		_status_pending = false
		# Visibility propagates after this signal, so take focus on the next idle.
		_focus_after_show.call_deferred()
	else:
		if _focus_before != null and is_instance_valid(_focus_before) and _focus_before.is_inside_tree():
			_focus_before.grab_focus()
		_focus_before = null


func _focus_after_show() -> void:
	if visible:
		FarmTheme.wrap_focus(self)


func _clear_status() -> void:
	_status.text = ""
	_status_pending = false


func _input(event: InputEvent) -> void:
	# Esc belongs to the panel only while it is open. The confirmation or an open
	# dropdown takes the first Esc; the next one closes the panel.
	if not visible or not (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE):
		return
	if _confirm.visible:
		_confirm.hide()
		_pending_action = {}
		get_viewport().set_input_as_handled()
		return
	for option: OptionButton in [_evidence_kind, _rule_outcome]:
		if option.get_popup().visible:
			option.get_popup().hide()
			get_viewport().set_input_as_handled()
			return
	close_panel()
	get_viewport().set_input_as_handled()


func _heading(parent: Control, text: String) -> Label:
	var heading := Label.new()
	heading.text = text
	heading.add_theme_color_override("font_color", INK)
	heading.add_theme_font_size_override("font_size", 18)
	parent.add_child(heading)
	return heading


func _add(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _list(parent: Control, node_name: String) -> VBoxContainer:
	var list := VBoxContainer.new()
	list.name = node_name
	list.add_theme_constant_override("separation", 4)
	parent.add_child(list)
	return list


func _field(parent: Control, node_name: String, placeholder: String,
		width: float) -> LineEdit:
	var field := LineEdit.new()
	field.name = node_name
	field.placeholder_text = placeholder
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if width > 0.0:
		field.custom_minimum_size.x = width
	parent.add_child(field)
	return field


func _button(parent: Control, text: String, node_name: String, width: float) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	if width > 0.0:
		button.custom_minimum_size = Vector2(width, 40)
	else:
		button.custom_minimum_size = Vector2(0, 40)
	FarmTheme.pointer_focus(button)
	parent.add_child(button)
	return button


func _clear(node: Node) -> void:
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()
