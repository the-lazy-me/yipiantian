extends SceneTree
## 银行面板作为视图：它只根据银行与贷款视图决定显示什么，并把点击变成开市、
## 借款、还款和刷新意图；现金、余额、在贷笔数与报价是否合法由权威规则决定。
##
## 没有网络和存档：视图直接构造，面板不在这里修改任何规则状态。报价由面板
## 调用 `Loans.quote`，因此可以逐项对照规则模块的结果。

const BankPanel = preload("res://ui/bank_panel.gd")
const Loans = preload("res://farm/loan_state.gd")

const NOW: float = 1800000000.0
const ALICE: String = "player_00000000000000000000000000000001"
const BOB: String = "player_00000000000000000000000000000002"

var panel: BankPanel
var events: Array = []
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 720)
	panel = BankPanel.new()
	panel.name = "Bank"
	root.add_child(panel)
	panel.open_requested.connect(func() -> void: events.append({"action": "open"}))
	panel.borrow_requested.connect(func(principal: int, term: int) -> void:
		events.append({"action": "borrow", "principal": principal, "term": term}))
	panel.repay_requested.connect(func(loan_id: String) -> void:
		events.append({"action": "repay", "loan_id": loan_id}))
	panel.refresh_requested.connect(func() -> void: events.append({"action": "refresh"}))
	panel.closed.connect(func() -> void: events.append({"action": "closed"}))
	await process_frame
	_expect(not panel.is_open(), "The panel starts closed until the player opens it")

	var closed_view: Dictionary = _view(false)
	panel.present(closed_view)
	var summary: Label = panel.find_child("Summary", true, false) as Label
	_expect(summary != null and summary.text.contains("尚未开市"),
		"A closed bank says so in the summary")
	_expect(summary != null and summary.text.contains("现金 0 COIN")
		and summary.text.contains("资本 0 COIN"),
		"A closed bank shows zero cash and zero capital")
	var open_bank: Button = panel.find_child("OpenBank", true, false) as Button
	_expect(open_bank != null and open_bank.visible and not open_bank.disabled,
		"A closed bank offers the open command")
	var borrow: Button = panel.find_child("Borrow", true, false) as Button
	_expect(borrow != null and borrow.disabled,
		"A closed bank disables borrowing")
	open_bank.pressed.emit()
	_expect(events.size() == 1 and events[0].action == "open",
		"Opening the bank is one intent signal")

	var view: Dictionary = _view(true)
	panel.present(view)
	_expect(summary != null and summary.text.contains("已开市")
		and summary.text.contains("现金 1905 COIN") and summary.text.contains("资本 2000 COIN"),
		"An open bank shows its real cash and capital")
	_expect(summary != null and summary.text.contains("未结清本金 100 COIN")
		and summary.text.contains("已收费用 5 COIN"),
		"The summary shows outstanding principal and collected fees from the view")
	_expect(summary != null and summary.text.contains("我的现金 200 COIN"),
		"The summary shows the player's own available cash")
	_expect(not borrow.disabled, "An open bank enables borrowing")
	_expect(not open_bank.visible, "An open bank hides the open command")

	var mine: Label = panel.find_child("Contract_loan-a", true, false) as Label
	_expect(mine != null and mine.text.contains("我") and mine.text.contains("本金 100 COIN")
		and mine.text.contains("费用 5 COIN") and mine.text.contains("合计 105 COIN")
		and mine.text.contains("到期") and mine.text.contains("进行中"),
		"My open contract shows principal, fee, total, due and status")
	var repay: Button = panel.find_child("Repay_loan-a", true, false) as Button
	_expect(repay != null and not repay.disabled, "My open contract offers repayment")
	var theirs: Label = panel.find_child("Contract_loan-b", true, false) as Label
	_expect(theirs != null and theirs.text.contains("他人") and theirs.text.contains("已结清"),
		"Another player's repaid contract is listed without an action")
	_expect(panel.find_child("Repay_loan-b", true, false) == null,
		"Another player's contract offers me no repayment")

	var principal: SpinBox = panel.find_child("Principal", true, false) as SpinBox
	var term: OptionButton = panel.find_child("Term", true, false) as OptionButton
	var quote: Label = panel.find_child("Quote", true, false) as Label
	_expect(principal != null and term != null and quote != null,
		"The borrow form carries a principal field, a term choice and a quote")
	_expect(term.item_count == Loans.TERMS.size()
		and int(term.get_item_metadata(0)) == Loans.TERMS[0]
		and int(term.get_item_metadata(1)) == Loans.TERMS[1]
		and int(term.get_item_metadata(2)) == Loans.TERMS[2],
		"The term choice offers exactly the rule module's 7, 14 and 30 days")

	principal.value = 250
	term.select(1)
	term.item_selected.emit(1)
	var fourteen: Dictionary = Loans.quote(250, Loans.TERMS[1], NOW)
	_expect(fourteen.ok and quote.text.contains("本金 250 COIN")
		and quote.text.contains("费用 %d COIN" % int(fourteen.fee))
		and quote.text.contains("合计 %d COIN" % int(fourteen.total))
		and quote.text.contains(_due_text(float(fourteen.due_utc))),
		"The quote follows the rule module for a 250 COIN fourteen-day loan")
	term.select(0)
	term.item_selected.emit(0)
	var seven: Dictionary = Loans.quote(250, Loans.TERMS[0], NOW)
	_expect(seven.ok and quote.text.contains("费用 %d COIN" % int(seven.fee))
		and quote.text.contains(_due_text(float(seven.due_utc)))
		and _due_text(float(seven.due_utc)) != _due_text(float(fourteen.due_utc)),
		"Changing the term moves the quoted due date without changing the fee")
	principal.value = 1000
	var large: Dictionary = Loans.quote(1000, Loans.TERMS[0], NOW)
	_expect(large.ok and quote.text.contains("费用 %d COIN" % int(large.fee))
		and quote.text.contains("合计 %d COIN" % int(large.total)),
		"Changing the principal changes the quoted fee and total")

	principal.value = 250
	term.select(0)
	term.item_selected.emit(0)
	var before: String = summary.text + "|" + quote.text
	borrow.pressed.emit()
	_expect(events.size() == 2 and events[1].action == "borrow"
		and events[1].principal == 250 and events[1].term == Loans.TERMS[0],
		"Borrowing carries the chosen principal and term in one intent")
	_expect(summary.text + "|" + quote.text == before,
		"The panel does not change its own displayed state when borrowing")

	before = summary.text + "|" + quote.text
	repay.pressed.emit()
	_expect(events.size() == 3 and events[2].action == "repay"
		and events[2].loan_id == "loan-a",
		"Repaying names the contract it belongs to")
	_expect(summary.text + "|" + quote.text == before,
		"The panel does not change its own displayed state when repaying")

	var status: Label = panel.find_child("Status", true, false) as Label
	panel.show_status("现金不够还清本金和费用。")
	_expect(status != null and status.text.contains("现金不够"),
		"An authority refusal is shown as a Chinese reason")
	_expect(summary.text + "|" + quote.text == before,
		"A refusal message does not change the displayed balances")

	var refresh: Button = panel.find_child("Refresh", true, false) as Button
	refresh.pressed.emit()
	_expect(events.size() == 4 and events[3].action == "refresh",
		"The panel can ask for a fresh view")

	# A member in the shared world writes through intents; the panel itself still
	# changes nothing until the authority replies.
	panel.present(_view(true, true, true))
	var member_read_only: Label = panel.find_child("ReadOnly", true, false) as Label
	_expect(member_read_only != null and not member_read_only.visible,
		"A member sees no read-only banner in the shared bank")
	_expect(not borrow.disabled, "A member may borrow in the shared bank")
	_expect(principal.editable and not term.disabled,
		"A member may edit principal and term in the shared bank")
	var member_repay: Button = panel.find_child("Repay_loan-a", true, false) as Button
	_expect(member_repay != null and not member_repay.disabled,
		"A member may repay their own shared-world loan")
	var before_member: String = summary.text + "|" + quote.text
	borrow.pressed.emit()
	_expect(events.size() == 5 and events[4].action == "borrow"
		and events[4].principal == 250 and events[4].term == Loans.TERMS[0],
		"A member's borrow click emits one intent with the chosen terms")
	member_repay = panel.find_child("Repay_loan-a", true, false) as Button
	member_repay.pressed.emit()
	_expect(events.size() == 6 and events[5].action == "repay"
		and events[5].loan_id == "loan-a",
		"A member's repay click names their own contract")
	_expect(summary.text + "|" + quote.text == before_member,
		"The shared bank does not change its own displayed balances on click")

	# A visitor keeps read access and is told why every write is disabled.
	panel.present(_view(true, true, false))
	var read_only: Label = panel.find_child("ReadOnly", true, false) as Label
	_expect(read_only != null and read_only.visible and read_only.text.contains("访客"),
		"A visitor sees why the shared bank is read-only")
	_expect(borrow.disabled, "Read-only mode disables borrowing")
	_expect(not principal.editable and term.disabled,
		"Read-only mode stops principal and term edits")
	_expect(not open_bank.visible, "Read-only mode offers no open command")
	_expect(panel.find_child("Repay_loan-a", true, false) == null,
		"Read-only mode offers no repayment")

	panel.show()
	_expect(panel.is_open(), "Showing the panel makes it open")
	var close: Button = panel.find_child("Close", true, false) as Button
	close.pressed.emit()
	_expect(not panel.is_open() and events.back().action == "closed",
		"Closing hides the panel and emits one closed event")
	_finish()


func _view(opened: bool, shared: bool = false, writable: bool = true) -> Dictionary:
	var bank: Dictionary = {"opened": opened, "opened_by": "", "opened_utc": 0.0,
		"cash": 0, "capital": 0}
	if opened:
		bank = {"opened": true, "opened_by": "bank-open", "opened_utc": NOW - 3600.0,
			"cash": 1905, "capital": 2000}
	var contracts: Array = [
		{"id": "loan-a", "borrower": ALICE, "principal": 100, "fee": 5,
			"term": Loans.TERMS[0], "due_utc": NOW + float(Loans.TERMS[0]),
			"opened_utc": NOW - 86400.0, "status": Loans.STATUS_OPEN, "paid": 0,
			"repaid_utc": 0.0, "repay_id": ""},
		{"id": "loan-b", "borrower": BOB, "principal": 50, "fee": 3,
			"term": Loans.TERMS[0], "due_utc": NOW + 100.0,
			"opened_utc": NOW - 700000.0, "status": Loans.STATUS_REPAID, "paid": 53,
			"repaid_utc": NOW - 10.0, "repay_id": "repay-b"},
	]
	return {
		"now_utc": NOW,
		"owner": ALICE,
		"cash": 200,
		"bank": bank,
		"loans": contracts,
		"outstanding": 100 if opened else 0,
		"fees": 5 if opened else 0,
		"read_only": shared and not writable,
		"read_only_reason": "访客只能查看市场和银行，不能下单、发货、开市或借贷。" \
			if shared and not writable else "",
	}


func _due_text(due_utc: float) -> String:
	return Time.get_datetime_string_from_unix_time(int(due_utc), true) + " UTC"


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("BANK_PANEL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
