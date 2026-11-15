extends Control
## 规则决议面板：把权威发来的决议视图摆出来，并把点击变成决议操作意图。
##
## 面板不判断成员资格、窗口、预告期、计票阈值或生命周期：这些都由权威文档与
## 规则决定，拒绝原因原样显示。这里只根据视图里的 `is_member`、提案人和相关
## 投票人决定哪些按钮出现，把动作原样交给调用方，因此没有网络也能测。
##
## 视图整份替换，面板不合并增量，也不在本地改状态、票数或规则版本。

signal resolution_action(action: String, args: Dictionary)
signal refresh_requested
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const ResolutionState = preload("res://world/resolution_state.gd")
const INK := FarmTheme.INK

const KIND_LABELS: Dictionary = {
	"public_works": "公共建设",
	"tax": "税费",
}
const STATUS_LABELS: Dictionary = {
	"proposed": "提案中",
	"passed": "已通过",
	"rejected": "已否决",
	"withdrawn": "已撤案",
	"effective": "已生效",
	"revoked": "已撤销",
}
const CHANGE_LABELS: Dictionary = {
	"effective": "生效",
	"revoked": "撤销",
}

## 权威决议视图：`{available, now_utc, viewer, is_member, rules_version,
## versions, resolutions}`。计票人数只在成员视图出现，投票人身份只在相关成员
## 的视图出现；面板只渲染拿到的字段。
var view: Dictionary = {}
## 权威决议行，按权威顺序保留；面板不排序。
var resolutions: Array = []
## 当前选中的决议 id；只用于决定动作区和按钮显隐，不作为权限判断。
var selected_id: String = ""

var _focus_before: Control
## A message written while the panel is hidden belongs to the next open.
var _status_pending: bool = false
var _rules_label: Label
var _viewer_label: Label
var _version_list: VBoxContainer
var _resolution_list: VBoxContainer
var _action_section: VBoxContainer
var _proposal_section: VBoxContainer
var _select: OptionButton
var _approve_button: Button
var _reject_button: Button
var _withdraw_button: Button
var _close_button: Button
var _activate_button: Button
var _revoke_button: Button
var _proposal_id: LineEdit
var _proposal_kind: OptionButton
var _proposal_title: LineEdit
var _vote_start: LineEdit
var _vote_end: LineEdit
var _effective: LineEdit
var _propose_button: Button
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
	paper.custom_minimum_size = Vector2(920, 700)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	paper.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	column.add_child(header)
	var title := Label.new()
	title.text = "决议"
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
	_rules_label = _add(body, "")
	_rules_label.name = "RulesVersion"
	_viewer_label = _add(body, "")
	_viewer_label.name = "ViewerState"
	_heading(body, "规则版本")
	_version_list = _list(body, "VersionList")
	_heading(body, "决议")
	_resolution_list = _list(body, "ResolutionList")
	_build_action_section(body)
	_build_proposal_section(body)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	_confirm = ConfirmationDialog.new()
	_confirm.name = "ResolutionConfirm"
	_confirm.ok_button_text = "确定"
	_confirm.cancel_button_text = "取消"
	_confirm.confirmed.connect(_confirmed_action)
	_confirm.canceled.connect(func() -> void: _pending_action = {})
	add_child(_confirm)
	_fill_view()
	visibility_changed.connect(_on_visibility_changed)
	hide()


func _build_action_section(body: VBoxContainer) -> void:
	_action_section = VBoxContainer.new()
	_action_section.name = "ActionSection"
	_action_section.add_theme_constant_override("separation", 10)
	body.add_child(_action_section)
	_heading(_action_section, "表决与生命周期")
	_select = OptionButton.new()
	_select.name = "ResolutionSelect"
	_select.custom_minimum_size.x = 300
	_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	FarmTheme.configure_option(_select)
	_action_section.add_child(_select)
	_select.item_selected.connect(func(_index: int) -> void: _on_selected())
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	_action_section.add_child(action_row)
	_approve_button = _button(action_row, "赞成", "Approve", 100.0)
	_approve_button.pressed.connect(func() -> void: _request_vote(true))
	_reject_button = _button(action_row, "反对", "Reject", 100.0)
	_reject_button.pressed.connect(func() -> void: _request_vote(false))
	_withdraw_button = _button(action_row, "撤案", "Withdraw", 100.0)
	_withdraw_button.pressed.connect(func() -> void: _request_lifecycle("withdraw"))
	_close_button = _button(action_row, "关闭投票", "CloseVote", 120.0)
	_close_button.pressed.connect(func() -> void: _request_lifecycle("close"))
	_activate_button = _button(action_row, "生效", "Activate", 100.0)
	_activate_button.pressed.connect(func() -> void: _request_lifecycle("activate"))
	_revoke_button = _button(action_row, "撤销", "Revoke", 100.0)
	_revoke_button.pressed.connect(func() -> void: _request_lifecycle("revoke"))


func _build_proposal_section(body: VBoxContainer) -> void:
	_proposal_section = VBoxContainer.new()
	_proposal_section.name = "ProposalSection"
	_proposal_section.add_theme_constant_override("separation", 10)
	body.add_child(_proposal_section)
	_heading(_proposal_section, "提案")
	var id_row := HBoxContainer.new()
	id_row.add_theme_constant_override("separation", 8)
	_proposal_section.add_child(id_row)
	_proposal_id = _field(id_row, "ResolutionId", "决议 id", 240.0)
	_proposal_kind = OptionButton.new()
	_proposal_kind.name = "Kind"
	_proposal_kind.custom_minimum_size.x = 160
	id_row.add_child(_proposal_kind)
	for kind: String in ResolutionState.KINDS:
		_proposal_kind.add_item(str(KIND_LABELS.get(kind, kind)))
		_proposal_kind.set_item_metadata(_proposal_kind.item_count - 1, kind)
	FarmTheme.configure_option(_proposal_kind)
	_proposal_title = _field(_proposal_section, "Title", "标题", 0.0)
	var time_row := HBoxContainer.new()
	time_row.add_theme_constant_override("separation", 8)
	_proposal_section.add_child(time_row)
	_vote_start = _field(time_row, "VoteStart", "投票开始 UTC 秒", 0.0)
	_vote_end = _field(time_row, "VoteEnd", "投票结束 UTC 秒", 0.0)
	_effective = _field(time_row, "EffectiveUtc", "生效 UTC 秒", 0.0)
	_propose_button = _button(_proposal_section, "提交提案", "Propose", 140.0)
	_propose_button.pressed.connect(_request_propose)


## Rebuilds from the authoritative resolution view. The panel never merges rows
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


## Clears the view and renders the unavailable state without showing the panel.
## Used when the world is single-player or the connection is gone.
func show_unavailable(reason: String = "not_open") -> void:
	_apply_view({
		"available": false, "reason": reason, "now_utc": 0.0, "viewer": "",
		"is_member": false, "rules_version": 0, "versions": [], "resolutions": [],
	})


func show_status(text: String) -> void:
	_status.text = text
	_status_pending = not visible and not text.is_empty()


func is_open() -> bool:
	return visible


## True while the confirmation or a dropdown owns the next Esc.
func is_popup_open() -> bool:
	if _confirm != null and _confirm.visible:
		return true
	for option: OptionButton in [_select, _proposal_kind]:
		if option.get_popup().visible:
			return true
	return false


func close_panel() -> void:
	if not visible:
		return
	_confirm.hide()
	_pending_action = {}
	for option: OptionButton in [_select, _proposal_kind]:
		option.get_popup().hide()
	hide()
	closed.emit()


## The authority reply is the only source of resolution facts. A refused action
## keeps the local view and shows the authority's own reason text.
func apply_result(_request_id: String, payload: Dictionary) -> void:
	if bool(payload.get("ok", false)):
		var state_value: Variant = payload.get("state")
		if state_value is Dictionary:
			_apply_view(state_value)
	var text: String = str(payload.get("reason_text", ""))
	if text.is_empty():
		text = str(payload.get("reason", ""))
	if text.is_empty():
		text = "决议操作被拒绝。"
	if not bool(payload.get("ok", false)):
		show_status(text)
		return
	if bool(payload.get("duplicate", false)):
		show_status("这条决议操作已经执行过。")
		return
	match str(payload.get("action", "")):
		"propose":
			show_status("决议已提交。")
		"vote":
			show_status("投票已记录。")
		"close":
			show_status("投票已关闭。")
		"activate":
			show_status("决议已生效。")
		"withdraw":
			show_status("决议已撤案。")
		"revoke":
			show_status("决议已撤销。")
		_:
			_clear_status()


func _apply_view(next: Dictionary) -> void:
	view = next.duplicate(true)
	resolutions = _rows_from(view)
	_fill_view()


func _fill_view() -> void:
	if _resolution_list == null:
		return
	var available: bool = bool(view.get("available", false))
	_rules_label.text = _rules_text(available)
	_viewer_label.text = _viewer_text()
	_fill_versions()
	_fill_resolutions(available)
	_update_sections(available)


func _rules_text(available: bool) -> String:
	if not available:
		var reason: String = str(view.get("reason", ""))
		if reason == "not_open" or reason.is_empty():
			return "世界尚未打开"
		return reason
	return "规则版本 v%d" % int(view.get("rules_version", 0))


func _viewer_text() -> String:
	var viewer: String = str(view.get("viewer", ""))
	var membership: String = "成员" if bool(view.get("is_member", false)) else "访客"
	if viewer.is_empty():
		return membership
	return "%s｜%s" % [membership, viewer]


func _fill_versions() -> void:
	_clear(_version_list)
	var value: Variant = view.get("versions")
	var count: int = 0
	if value is Array:
		for row_value: Variant in value:
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			var change: String = str(row.get("change", ""))
			_add(_version_list, "v%d %s · %s" % [
				int(row.get("version", 0)),
				str(CHANGE_LABELS.get(change, change)),
				str(row.get("resolution_id", "")),
			])
			count += 1
	if count == 0:
		_add(_version_list, "还没有规则版本变化。")


func _fill_resolutions(available: bool) -> void:
	_clear(_resolution_list)
	_select.clear()
	_select.disabled = not available
	if not available:
		_add(_resolution_list, "世界尚未打开，决议不可用。")
		selected_id = ""
		_sync_action_visibility()
		return
	if resolutions.is_empty():
		_add(_resolution_list, "还没有决议。")
		selected_id = ""
		_sync_action_visibility()
		return
	var keep: String = selected_id
	var keep_index: int = -1
	for row_value: Variant in resolutions:
		var row: Dictionary = row_value
		var resolution_id: String = str(row.get("resolution_id", ""))
		var key: String = resolution_id
		var label := Label.new()
		label.name = "Resolution_" + key
		label.text = _resolution_text(row)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", INK)
		label.add_theme_font_size_override("font_size", 16)
		_resolution_list.add_child(label)
		_select.add_item("%s · %s" % [resolution_id, str(row.get("title", ""))])
		_select.set_item_metadata(_select.item_count - 1, resolution_id)
		if resolution_id == keep:
			keep_index = _select.item_count - 1
	if keep_index >= 0:
		_select.select(keep_index)
		selected_id = keep
	elif _select.item_count > 0:
		_select.select(0)
		selected_id = str(_select.get_item_metadata(0))
	_sync_action_visibility()


func _resolution_text(row: Dictionary) -> String:
	var status: String = str(row.get("status", ""))
	var lines: Array[String] = [
		"%s｜%s｜%s｜提案 %s｜%s（%s）" % [
			str(row.get("resolution_id", "")),
			str(KIND_LABELS.get(str(row.get("kind", "")), str(row.get("kind", "")))),
			str(row.get("title", "")), str(row.get("proposed_by", "")),
			str(STATUS_LABELS.get(status, status)), status,
		],
		"投票 %s｜生效 %s｜修订 %d｜生效版本 %d｜撤销版本 %d" % [
			_range_text(row.get("vote_start_utc", 0.0), row.get("vote_end_utc", 0.0)),
			_utc_text(row.get("effective_utc", 0.0)),
			int(row.get("revision", 0)), int(row.get("effective_version", 0)),
			int(row.get("revoked_version", 0)),
		],
	]
	var counts: Array[String] = []
	if row.get("approvals") is int or row.get("approvals") is float:
		counts.append("赞成 %d" % int(row.get("approvals", 0)))
	if row.get("rejections") is int or row.get("rejections") is float:
		counts.append("反对 %d" % int(row.get("rejections", 0)))
	if not counts.is_empty():
		lines.append("｜".join(counts))
	if row.get("approvers") is Array:
		lines.append("赞成者 %s｜反对者 %s" % [
			_join_ids(row.get("approvers")), _join_ids(row.get("rejecters")),
		])
	if status == ResolutionState.STATUS_REVOKED:
		lines.append("失效 %s" % _utc_text(row.get("ends_utc", 0.0)))
	return "\n".join(lines)


func _join_ids(value: Variant) -> String:
	if not value is Array or (value as Array).is_empty():
		return "无"
	var ids: Array[String] = []
	for entry: Variant in value:
		ids.append(str(entry))
	return "、".join(PackedStringArray(ids))


func _utc_text(value: Variant) -> String:
	var number: float = float(value)
	return "UTC %d" % int(number) if number > 0.0 else "未定"


func _range_text(start: Variant, end: Variant) -> String:
	var first: float = float(start)
	var last: float = float(end)
	if first <= 0.0 and last <= 0.0:
		return "未定"
	return "UTC %d–%d" % [int(first), int(last)]


func _update_sections(available: bool) -> void:
	_action_section.visible = available
	_proposal_section.visible = available
	if not available:
		_approve_button.disabled = true
		_reject_button.disabled = true
		_withdraw_button.disabled = true
		_close_button.disabled = true
		_activate_button.disabled = true
		_revoke_button.disabled = true
		_propose_button.disabled = true
		return
	_propose_button.disabled = false
	_sync_action_visibility()


## Buttons are shown only where the view says the action could apply. The
## authority still decides every action and its refusal is displayed verbatim.
func _sync_action_visibility() -> void:
	if _approve_button == null:
		return
	var row: Dictionary = _selected_row()
	var member: bool = bool(view.get("is_member", false)) and not row.is_empty()
	var viewer: String = str(view.get("viewer", ""))
	var status: String = str(row.get("status", ""))
	var proposer: String = str(row.get("proposed_by", ""))
	var voted: bool = false
	if not viewer.is_empty():
		if row.get("approvers") is Array and (row.get("approvers") as Array).has(viewer):
			voted = true
		if row.get("rejecters") is Array and (row.get("rejecters") as Array).has(viewer):
			voted = true
	_approve_button.visible = member and status == ResolutionState.STATUS_PROPOSED \
		and not viewer.is_empty() and viewer != proposer and not voted
	_reject_button.visible = _approve_button.visible
	_withdraw_button.visible = status == ResolutionState.STATUS_PROPOSED \
		and not viewer.is_empty() and viewer == proposer
	_close_button.visible = member and status == ResolutionState.STATUS_PROPOSED
	_activate_button.visible = member and status == ResolutionState.STATUS_PASSED
	_revoke_button.visible = member and status == ResolutionState.STATUS_EFFECTIVE \
		and row.get("approvers") is Array \
		and (row.get("approvers") as Array).has(viewer) and not viewer.is_empty()
	_approve_button.disabled = not _approve_button.visible
	_reject_button.disabled = not _reject_button.visible
	_withdraw_button.disabled = not _withdraw_button.visible
	_close_button.disabled = not _close_button.visible
	_activate_button.disabled = not _activate_button.visible
	_revoke_button.disabled = not _revoke_button.visible


func _on_selected() -> void:
	selected_id = str(_select.get_item_metadata(_select.selected)) \
		if _select.selected >= 0 else ""
	_sync_action_visibility()


func _selected_row() -> Dictionary:
	for row_value: Variant in resolutions:
		if row_value is Dictionary \
				and str((row_value as Dictionary).get("resolution_id", "")) == selected_id:
			return row_value
	return {}


func _request_propose() -> void:
	if _propose_button.disabled:
		return
	var resolution_id: String = _proposal_id.text.strip_edges()
	if resolution_id.is_empty():
		show_status("先填写决议 id。")
		return
	var title: String = _proposal_title.text.strip_edges()
	if title.is_empty():
		show_status("先填写决议标题。")
		return
	var times: Dictionary = _parse_times()
	if not bool(times.ok):
		show_status(str(times.reason))
		return
	var proposal: Dictionary = {
		"kind": _selected_meta(_proposal_kind), "title": title,
		"vote_start_utc": times.vote_start_utc, "vote_end_utc": times.vote_end_utc,
		"effective_utc": times.effective_utc,
	}
	_clear_status()
	_open_confirm("propose", {
		"command_id": _new_request_id("propose"), "resolution_id": resolution_id,
		"proposal": proposal,
	}, "确定提交这项决议吗？投票与预告期由权威校验。")


## Parses the three UTC fields. Only the numeric form is checked here; window
## order and the notice period stay with the authority.
func _parse_times() -> Dictionary:
	var starts: float = _time_value(_vote_start)
	if starts < 0.0:
		return {"ok": false, "reason": "投票开始请填写非负的 UTC 秒。"}
	var ends: float = _time_value(_vote_end)
	if ends < 0.0:
		return {"ok": false, "reason": "投票结束请填写非负的 UTC 秒。"}
	var effective: float = _time_value(_effective)
	if effective < 0.0:
		return {"ok": false, "reason": "生效时刻请填写非负的 UTC 秒。"}
	return {
		"ok": true, "vote_start_utc": starts, "vote_end_utc": ends,
		"effective_utc": effective,
	}


func _time_value(field: LineEdit) -> float:
	var trimmed: String = field.text.strip_edges()
	if not trimmed.is_valid_float():
		return -1.0
	var value: float = float(trimmed)
	if not is_finite(value) or value < 0.0:
		return -1.0
	return value


func _request_vote(approve: bool) -> void:
	var row: Dictionary = _selected_row()
	if row.is_empty():
		show_status("先选择一条决议。")
		return
	var resolution_id: String = str(row.get("resolution_id", ""))
	_clear_status()
	_open_confirm("vote", {
		"command_id": _new_request_id("vote"), "resolution_id": resolution_id,
		"approve": approve,
	}, "确定投%s票吗？" % ("赞成" if approve else "反对"))


func _request_lifecycle(action: String) -> void:
	var row: Dictionary = _selected_row()
	if row.is_empty():
		show_status("先选择一条决议。")
		return
	var resolution_id: String = str(row.get("resolution_id", ""))
	var notes: Dictionary = {
		"withdraw": "确定撤案吗？撤案后不能再表决。",
		"close": "确定关闭投票吗？之后由权威按计票结果定案。",
		"activate": "确定让决议生效吗？这会推进世界规则版本。",
		"revoke": "确定撤销这条决议吗？这会推进世界规则版本。",
	}
	_clear_status()
	_open_confirm(action, {
		"command_id": _new_request_id(action), "resolution_id": resolution_id,
	}, str(notes.get(action, "确定执行这个决议操作吗？")))


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
	resolution_action.emit(action, args)


func _selected_meta(option: OptionButton) -> String:
	if option.selected < 0:
		return ""
	return str(option.get_item_metadata(option.selected))


func _new_request_id(action: String) -> String:
	_request_counter += 1
	return "resolution-%s-%d-%d" % [action, Time.get_ticks_usec(), _request_counter]


## Copies the rows in the authority's own order; the panel never sorts or
## completes a row. A row without a resolution id cannot be selected or acted on,
## so it is skipped instead of rendered under an empty key.
func _rows_from(source: Dictionary) -> Array:
	var rows: Array = []
	var value: Variant = source.get("resolutions")
	if value is Array:
		for row_value: Variant in value:
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			if str(row.get("resolution_id", "")).is_empty():
				continue
			rows.append(row.duplicate(true))
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
	for option: OptionButton in [_select, _proposal_kind]:
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
