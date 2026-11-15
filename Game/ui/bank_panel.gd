extends CanvasLayer
## 银行面板：把权威同步来的银行与贷款视图摆出来，并把点击变成开市、借款、
## 还款和刷新意图。
##
## 面板不判断银行现金、账户余额、在贷笔数或期限是否合法；这些规则在
## FarmState/Loans 里，这里只根据视图决定显示什么。报价直接复用
## `Loans.quote`，不自行计算费用。因此没有网络和存档也能测。
##
## 视图整份替换，面板不合并增量，也不乐观修改余额。

signal open_requested
signal borrow_requested(principal: int, term: int)
signal repay_requested(loan_id: String)
signal refresh_requested
signal closed

const FarmTheme = preload("res://ui/farm_theme.gd")
const Loans = preload("res://farm/loan_state.gd")
const INK := FarmTheme.INK

var view: Dictionary = {}
var read_only: bool = false
var now_utc: float = 0.0
var my_id: String = ""

var _bank_opened: bool = false
var _quote_ok: bool = false
var _summary: Label
var _read_only: Label
var _status: Label
var _root: Control
var _focus_before: Control
## A message written while the panel is hidden belongs to the next open.
var _status_pending: bool = false
var _contracts: VBoxContainer
var _term: OptionButton
var _principal: SpinBox
var _quote: Label
var _open_bank: Button
var _borrow: Button
var _refresh: Button


func _ready() -> void:
	layer = 23
	var root := Control.new()
	_root = root
	root.name = "Bank"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = FarmTheme.create()
	add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0.08, 0.1, 0.09, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var paper := PanelContainer.new()
	paper.custom_minimum_size = Vector2(720, 560)
	center.add_child(paper)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	paper.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	column.add_child(header)
	var title := Label.new()
	title.text = "银行"
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_refresh = _button(header, "刷新", 84.0)
	_refresh.name = "Refresh"
	_refresh.pressed.connect(func() -> void:
		_clear_status()
		refresh_requested.emit())
	var close := _button(header, "收起", 84.0)
	close.name = "Close"
	close.pressed.connect(_close)
	_summary = Label.new()
	_summary.name = "Summary"
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_summary)
	_read_only = Label.new()
	_read_only.name = "ReadOnly"
	_read_only.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_read_only.visible = false
	column.add_child(_read_only)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
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
	_build_borrow_form(body)
	_contracts = _section(body, "合同")
	visibility_changed.connect(_on_visibility_changed)
	hide()


## Rebuilds from the authoritative bank view. `read_only` is a view fact the
## scene decides from the world's role: members may submit commands, visitors
## may only read.
func present(next_view: Dictionary) -> void:
	var focus_key: String = FarmTheme.focus_key_within(_root)
	view = next_view.duplicate(true)
	now_utc = float(view.get("now_utc", 0.0))
	my_id = str(view.get("owner", ""))
	read_only = bool(view.get("read_only", false))
	var bank: Dictionary = view.get("bank", {}) as Dictionary
	_bank_opened = bool(bank.get("opened", false))
	_summary.text = _summary_text(bank)
	_read_only.visible = read_only
	_read_only.text = str(view.get("read_only_reason", "")) if read_only else ""
	# A refresh keeps the last success or refusal; opening clears it unless the
	# game wrote it while the panel was closed. The read-only reason has its own
	# label.
	_fill_contracts()
	_sync_quote()
	_refresh_controls()
	if visible:
		FarmTheme.wrap_focus(_root, focus_key)


func show_status(text: String) -> void:
	_status.text = text
	_status_pending = not visible


func is_open() -> bool:
	return visible


func close() -> void:
	hide()
	closed.emit()


func is_popup_open() -> bool:
	if _term != null and _term.get_popup().visible:
		return true
	return _principal != null and _principal.get_line_edit().has_focus()


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
		FarmTheme.wrap_focus(_root)


func _clear_status() -> void:
	_status.text = ""
	_status_pending = false


func _input(event: InputEvent) -> void:
	# Main handles Esc for the whole panel; while the term dropdown is open or the
	# principal is being edited, the first Esc belongs to that control instead.
	if not visible or not (event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE):
		return
	if _dismiss_popup():
		get_viewport().set_input_as_handled()


func _dismiss_popup() -> bool:
	if _term != null and _term.get_popup().visible:
		_term.get_popup().hide()
		return true
	if _principal != null and _principal.get_line_edit().has_focus():
		_principal.get_line_edit().release_focus()
		return true
	return false


func _summary_text(bank: Dictionary) -> String:
	var state: String = "已开市" if _bank_opened else "尚未开市"
	return "银行%s · 现金 %d COIN · 资本 %d COIN · 未结清本金 %d COIN · 已收费用 %d COIN · 我的现金 %d COIN" % [
		state, int(bank.get("cash", 0)), int(bank.get("capital", 0)),
		int(view.get("outstanding", 0)), int(view.get("fees", 0)),
		int(view.get("cash", 0)),
	]


func _build_borrow_form(parent: Control) -> void:
	_heading(parent, "借款")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	_label(row, "期限")
	_term = OptionButton.new()
	_term.name = "Term"
	for term: int in Loans.TERMS:
		_term.add_item("%d 天" % int(term / 86400))
		_term.set_item_metadata(_term.item_count - 1, term)
	FarmTheme.configure_option(_term)
	row.add_child(_term)
	_principal = _spin(row, "Principal", "本金", Loans.MIN_PRINCIPAL,
		Loans.MAX_PRINCIPAL, 100)
	_open_bank = _button(row, "开市", 96.0)
	_open_bank.name = "OpenBank"
	_open_bank.pressed.connect(_emit_open)
	_borrow = _button(row, "借款", 96.0)
	_borrow.name = "Borrow"
	_borrow.pressed.connect(_emit_borrow)
	_quote = Label.new()
	_quote.name = "Quote"
	_quote.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(_quote)
	_term.item_selected.connect(func(_index: int) -> void: _sync_quote())
	_principal.value_changed.connect(func(_value: float) -> void: _sync_quote())


func _fill_contracts() -> void:
	_clear(_contracts)
	var loans: Array = view.get("loans", []) as Array
	if loans.is_empty():
		_add(_contracts, "还没有贷款合同。")
		return
	for contract: Dictionary in loans:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_contracts.add_child(row)
		var label := Label.new()
		var loan_id: String = str(contract.get("id", ""))
		label.name = "Contract_" + loan_id
		label.text = _contract_text(contract)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		if _my_active_contract(contract):
			var repay := _button(row, "还款", 76.0)
			repay.name = "Repay_" + loan_id
			repay.pressed.connect(func() -> void: _emit_repay(loan_id))


func _contract_text(contract: Dictionary) -> String:
	var who: String = "我" if _contract_scope(contract) == "me" else "他人"
	return "%s · 本金 %d COIN · 费用 %d COIN · 合计 %d COIN · 到期 %s · %s" % [
		who, int(contract.get("principal", 0)), int(contract.get("fee", 0)),
		int(contract.get("principal", 0)) + int(contract.get("fee", 0)),
		_due_text(float(contract.get("due_utc", 0.0))),
		_contract_status_text(str(contract.get("status", ""))),
	]


func _contract_status_text(status: String) -> String:
	match status:
		Loans.STATUS_OPEN:
			return "进行中"
		Loans.STATUS_OVERDUE:
			return "已逾期"
		Loans.STATUS_REPAID:
			return "已结清"
	return "未知"


## ADR-027: a projected contract carries `owner_scope` instead of `borrower`.
## A row with neither is not this player's, so the repay button is hidden.
func _contract_scope(contract: Dictionary) -> String:
	if contract.has("owner_scope"):
		return str(contract.get("owner_scope", ""))
	var borrower: String = str(contract.get("borrower", ""))
	if borrower.is_empty():
		return "other"
	return "me" if borrower == my_id else "other"


func _my_active_contract(contract: Dictionary) -> bool:
	return not read_only and _contract_scope(contract) == "me" \
		and str(contract.get("status", "")) in [Loans.STATUS_OPEN, Loans.STATUS_OVERDUE]


## The quote comes from the rule module at the visible principal and term. The
## panel never derives a fee or due date on its own.
func _sync_quote() -> void:
	var principal: int = int(round(_principal.value))
	var term: int = _selected_term()
	var quoted: Dictionary = Loans.quote(principal, term, now_utc)
	_quote_ok = bool(quoted.get("ok", false))
	if _quote_ok:
		_quote.text = "报价：本金 %d COIN · 费用 %d COIN · 合计 %d COIN · 到期 %s" % [
			int(quoted.get("principal", 0)), int(quoted.get("fee", 0)),
			int(quoted.get("total", 0)), _due_text(float(quoted.get("due_utc", 0.0))),
		]
	else:
		_quote.text = _quote_reason(str(quoted.get("reason", "")))
	_refresh_controls()


func _quote_reason(reason: String) -> String:
	match reason:
		"invalid_principal":
			return "本金需在 10 到 1000 COIN 之间。"
		"invalid_term":
			return "期限只能是 7、14 或 30 天。"
		"invalid_time":
			return "当前时间无效，请稍后再试。"
		"invalid_due":
			return "到期时间超出范围。"
	return "无法生成报价。"


func _refresh_controls() -> void:
	_term.disabled = read_only
	_principal.editable = not read_only
	_open_bank.visible = not read_only and not _bank_opened
	_borrow.disabled = read_only or not _bank_opened or not _quote_ok


func _selected_term() -> int:
	var index: int = maxi(0, _term.selected)
	return int(_term.get_item_metadata(index))


func _due_text(due_utc: float) -> String:
	return Time.get_datetime_string_from_unix_time(int(due_utc), true) + " UTC"


func _emit_open() -> void:
	if read_only or _bank_opened:
		return
	_clear_status()
	open_requested.emit()


func _emit_borrow() -> void:
	if _borrow.disabled:
		return
	_clear_status()
	borrow_requested.emit(int(round(_principal.value)), _selected_term())


func _emit_repay(loan_id: String) -> void:
	if read_only:
		return
	_clear_status()
	repay_requested.emit(loan_id)


func _close() -> void:
	close()


func _heading(parent: Control, text: String) -> Label:
	var heading := Label.new()
	heading.text = text
	heading.add_theme_color_override("font_color", INK)
	heading.add_theme_font_size_override("font_size", 18)
	parent.add_child(heading)
	return heading


func _section(parent: Control, title: String) -> VBoxContainer:
	_heading(parent, title)
	var rows := VBoxContainer.new()
	rows.name = title
	rows.add_theme_constant_override("separation", 4)
	parent.add_child(rows)
	return rows


func _label(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	parent.add_child(label)
	return label


func _add(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)


func _spin(parent: Control, node_name: String, label_text: String, minimum: int,
		maximum: int, value: int) -> SpinBox:
	_label(parent, label_text)
	var spin := SpinBox.new()
	spin.name = node_name
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = 1
	spin.value = value
	parent.add_child(spin)
	return spin


func _button(parent: Node, text: String, width: float) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(width, 40)
	FarmTheme.pointer_focus(button)
	parent.add_child(button)
	return button


func _clear(node: Node) -> void:
	for child: Node in node.get_children():
		node.remove_child(child)
		child.queue_free()
