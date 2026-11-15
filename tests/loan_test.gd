extends SceneTree
## M8-02 rule-bank loans: one-time capital, fixed-fee fixed-term contracts,
## full repayment, deterministic overdue status and JSON/disk persistence.
## Headless and isolated; no clock, scene or live save. FarmState wrappers are
## intentionally not touched by this slice, so the tests drive the economy
## candidate directly and restore it through the existing farm boundary.

const Farm = preload("res://farm/farm_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const Loans = preload("res://farm/loan_state.gd")
const Ledger = preload("res://farm/ledger_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")

const START: float = 1800000000.0
const DAY: float = 86400.0
const TERM: int = 604800
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const PLAYER_D: String = "player_00000000000000000000000000000004"
const PLAYER_E: String = "player_00000000000000000000000000000005"

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/loan-%d" % OS.get_process_id()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_quote()
	_test_open_bank()
	_test_borrow()
	_test_repay()
	_test_settle_and_overdue()
	_test_legacy_and_restore()
	_test_review_hardening()
	_test_persistence()
	_test_reconcile_and_reserve()
	_test_tampering()
	_test_ledger_hardening()
	_test_eviction_and_durable_ids()
	for failure: String in failures:
		push_error(failure)
	print("LOAN_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_quote() -> void:
	var quote: Dictionary = Loans.quote(100, TERM, START)
	_expect(quote.ok and quote.principal == 100 and quote.fee == 5 and quote.total == 105,
		"A 100 COIN loan quotes a fixed 5 COIN fee and 105 total")
	_expect(quote.due_utc == START + float(TERM), "The quote puts the due date one term out")
	var later: Dictionary = Loans.quote(100, TERM, START + 365.0 * DAY)
	_expect(later.fee == quote.fee and later.total == quote.total,
		"The fee does not grow with time")
	_expect(later.due_utc == quote.due_utc + 365.0 * DAY,
		"A later quote moves only the due date")
	_expect(Loans.fee_for(10) == 1 and Loans.fee_for(50) == 3 and Loans.fee_for(100) == 5
		and Loans.fee_for(1000) == 50,
		"The fee is a ceiling of five percent with a one COIN minimum")
	for principal: int in [10, 50, 100, 999, 1000]:
		var row: Dictionary = Loans.quote(principal, TERM, START)
		_expect(row.ok and row.total == principal + Loans.fee_for(principal),
			"Every allowed principal quotes principal plus its fixed fee")
	for bad_principal: Variant in [-1, 0, 9, 1001, 1.5, "100", float(Loans.MAX_SAFE_INTEGER)]:
		_expect(not Loans.quote(bad_principal, TERM, START).ok,
			"An out-of-range or non-integer principal is refused")
	for bad_term: Variant in [0, 1, 123, TERM + 1, 1.5]:
		_expect(not Loans.quote(100, bad_term, START).ok,
			"An unlisted term is refused")
	_expect(not Loans.quote(100, TERM, -1.0).ok, "A negative quote time is refused")
	_expect(not Loans.quote(100, TERM, float(Loans.MAX_SAFE_INTEGER)).ok,
		"A due date past the safe integer range is refused")


func _test_open_bank() -> void:
	var economy: Dictionary = _economy_fixture()
	var total_before: int = Economy.total_cash(economy)
	var issued_before: int = Economy.issued(economy)
	var opened: Dictionary = Economy.open_bank(economy, "bank-open", START)
	_expect(opened.ok and not opened.duplicate and opened.amount == Economy.BANK_CAPITAL,
		"The bank opens with its one-time capital")
	var bank: Dictionary = Economy.bank_snapshot(economy)
	_expect(bank.opened and bank.opened_by == "bank-open" and bank.cash == Economy.BANK_CAPITAL
		and bank.capital == Economy.BANK_CAPITAL,
		"The bank row carries its capital and real cash")
	_expect(Economy.issued(economy) == issued_before + Economy.BANK_CAPITAL
		and Economy.total_cash(economy) == total_before + Economy.BANK_CAPITAL,
		"Opening the bank issues exactly one capital, not a second wallet")
	var entry: Dictionary = _event_entry(economy, "bank-open")
	_expect(entry.kind == Ledger.KIND_BANK_OPEN and _balanced(entry),
		"The capital is one balanced bank_open entry")
	_expect(_line(entry, Ledger.BANK) == Economy.BANK_CAPITAL
		and _line(entry, Ledger.ISSUANCE) == -Economy.BANK_CAPITAL,
		"The bank is debited and issuance credited for the capital")
	_expect(Economy.valid(economy) and Economy.reconcile(economy).ok,
		"The opened bank reconciles and validates")
	var accepted: Dictionary = economy.duplicate(true)
	var replay: Dictionary = Economy.open_bank(economy, "bank-open", START)
	_expect(replay.ok and replay.duplicate and replay.amount == Economy.BANK_CAPITAL,
		"Replaying the open command returns the first result")
	_expect(economy == accepted, "A replayed open changes no cash and no journal entry")
	var second: Dictionary = Economy.open_bank(economy, "bank-open-2", START)
	_expect(second.ok and second.duplicate and second.amount == Economy.BANK_CAPITAL,
		"A second open id returns the issued capital instead of issuing twice")
	_expect(economy == accepted and Economy.issued(economy) == issued_before + Economy.BANK_CAPITAL,
		"A second open id leaves the issued total and journal unchanged")
	_expect(not Economy.open_bank(economy, "", START).ok, "An empty bank command id is refused")
	_expect(not Economy.open_bank(economy, "bank-bad", -1.0).ok, "A negative bank time is refused")


func _test_borrow() -> void:
	var economy: Dictionary = _opened_bank()
	var total_before: int = Economy.total_cash(economy)
	var issued_before: int = Economy.issued(economy)
	var quoted: Dictionary = Loans.quote(50, TERM, START)
	var borrowed: Dictionary = _borrow(economy, PLAYER_A, 50, TERM, "loan-a", START)
	_expect(borrowed.ok and not borrowed.duplicate and borrowed.amount == 50
		and borrowed.fee == quoted.fee and borrowed.total == quoted.total
		and borrowed.due_utc == quoted.due_utc,
		"A permitted borrower receives the quoted principal")
	_expect(Economy.bank_snapshot(economy).cash == Economy.BANK_CAPITAL - 50
		and Economy.cash(economy, PLAYER_A) == 170,
		"The bank cash falls and the borrower cash rises by the principal")
	_expect(Economy.issued(economy) == issued_before
		and Economy.total_cash(economy) == total_before,
		"Borrowing moves cash and issues nothing")
	var contract: Dictionary = Economy.loan(economy, "loan-a")
	_expect(contract.id == "loan-a" and contract.borrower == PLAYER_A
		and contract.principal == 50 and contract.fee == 3
		and contract.status == Loans.STATUS_OPEN and contract.paid == 0
		and contract.repaid_utc == 0.0 and str(contract.repay_id).is_empty(),
		"The contract row records the borrower, principal, fee and open status")
	_expect(contract.opened_utc == START and contract.due_utc == START + float(TERM),
		"The contract records its opening and due times")
	var entry: Dictionary = _event_entry(economy, "loan-a")
	_expect(entry.kind == Ledger.KIND_LOAN_ISSUE and _balanced(entry),
		"Borrowing posts one balanced loan_issue entry")
	_expect(_line(entry, Ledger.owner_code(PLAYER_A)) == 50
		and _line(entry, Ledger.BANK) == -50,
		"The borrower account is debited and the bank credited by the principal")
	_expect_valid(economy, "a loan issue")

	var accepted: Dictionary = economy.duplicate(true)
	var replay: Dictionary = _borrow(economy, PLAYER_A, 50, TERM, "loan-a", START)
	_expect(replay.ok and replay.duplicate and replay.amount == 50
		and replay.fee == 3 and replay.total == 53,
		"Replaying the borrow id returns the first quote result")
	_expect(economy == accepted, "A replayed borrow issues no second principal")
	var conflict: Dictionary = _borrow(economy, PLAYER_A, 100, TERM, "loan-a", START)
	_expect(not conflict.ok and conflict.reason == "command_conflict"
		and economy == accepted,
		"A reused borrow id with another principal is a conflict")
	var active: Dictionary = _borrow(economy, PLAYER_A, 10, TERM, "loan-a-2", START)
	_expect(not active.ok and active.reason == "loan_active" and economy == accepted,
		"A borrower with an open loan cannot take a second one")
	var unknown: Dictionary = _borrow(economy, PLAYER_E, 50, TERM, "loan-e", START)
	_expect(not unknown.ok and unknown.reason == "unknown_account" and economy == accepted,
		"An unopened account cannot borrow")
	for bad_principal: Variant in [-1, 9, 1001, 1.5, "50"]:
		_expect(not _borrow(economy, PLAYER_E, bad_principal, TERM, "loan-bad", START).ok
			and economy == accepted, "An out-of-range principal is refused")
	for bad_term: Variant in [0, 123, 1.5]:
		_expect(not _borrow(economy, PLAYER_E, 50, bad_term, "loan-bad", START).ok
			and economy == accepted, "An unlisted borrow term is refused")
	_expect(not _borrow(economy, PLAYER_E, 50, TERM, "loan-bad", -1.0).ok
		and economy == accepted, "A negative borrow time is refused")
	_expect(not _borrow(economy, PLAYER_E, 50, TERM, "loan-bad",
		float(Loans.MAX_SAFE_INTEGER)).ok and economy == accepted,
		"A borrow whose due date overflows is refused")

	# Two more loans leave only 50 COIN in the bank; a later borrower sees the
	# real cash limit instead of a loan the bank cannot fund.
	_expect(_borrow(economy, PLAYER_B, 1000, TERM, "loan-b", START).ok,
		"The bank funds the first large loan")
	_expect(_borrow(economy, PLAYER_C, 900, TERM, "loan-c", START).ok,
		"The bank funds the second large loan")
	_expect(Economy.bank_snapshot(economy).cash == 50, "The bank cash is nearly exhausted")
	var before_poor: Dictionary = economy.duplicate(true)
	var poor: Dictionary = _borrow(economy, PLAYER_D, 100, TERM, "loan-d", START)
	_expect(not poor.ok and poor.reason == "bank_insufficient" and economy == before_poor,
		"A loan above the bank's available cash is refused")
	_expect(_borrow(economy, PLAYER_D, 50, TERM, "loan-d-small", START).ok,
		"A loan within the remaining bank cash is allowed")


func _test_repay() -> void:
	var economy: Dictionary = _opened_bank()
	_borrow(economy, PLAYER_A, 50, TERM, "loan-a", START)
	var total_before: int = Economy.total_cash(economy)
	var issued_before: int = Economy.issued(economy)
	var wrong: Dictionary = Economy.repay_loan(economy, PLAYER_B, "loan-a", "repay-wrong", START)
	_expect(not wrong.ok and wrong.reason == "not_borrower",
		"Only the contract borrower may repay")
	var missing: Dictionary = Economy.repay_loan(economy, PLAYER_A, "loan-x", "repay-x", START)
	_expect(not missing.ok and missing.reason == "loan_not_found",
		"An unknown loan id cannot be repaid")
	var early: Dictionary = Economy.repay_loan(economy, PLAYER_A, "loan-a", "repay-early", START - 1.0)
	_expect(not early.ok and early.reason == "invalid_time",
		"A repayment before opening is refused")
	var paid: Dictionary = Economy.repay_loan(economy, PLAYER_A, "loan-a", "repay-a", START + 1.0)
	_expect(paid.ok and not paid.duplicate and paid.amount == 53 and paid.fee == 3,
		"A borrower with enough cash settles principal plus fee once")
	_expect(Economy.bank_snapshot(economy).cash == Economy.BANK_CAPITAL + 3
		and Economy.cash(economy, PLAYER_A) == 117,
		"The bank receives the fee and the borrower pays the full total")
	_expect(Economy.issued(economy) == issued_before
		and Economy.total_cash(economy) == total_before,
		"Repayment transfers cash and conserves the issued total")
	var contract: Dictionary = Economy.loan(economy, "loan-a")
	_expect(contract.status == Loans.STATUS_REPAID and contract.paid == 53
		and contract.repaid_utc == START + 1.0 and contract.repay_id == "repay-a",
		"The contract records full payment and the accepted command id")
	var entry: Dictionary = _event_entry(economy, "repay-a")
	_expect(entry.kind == Ledger.KIND_LOAN_REPAY and _balanced(entry),
		"Repayment posts one balanced loan_repay entry")
	_expect(_line(entry, Ledger.BANK) == 53
		and _line(entry, Ledger.owner_code(PLAYER_A)) == -53,
		"The bank is debited and the borrower credited by the total")
	_expect_valid(economy, "a full repayment")

	var accepted: Dictionary = economy.duplicate(true)
	var replay: Dictionary = Economy.repay_loan(economy, PLAYER_A, "loan-a", "repay-a", START + 1.0)
	_expect(replay.ok and replay.duplicate and replay.amount == 53 and economy == accepted,
		"Replaying the repayment id debits nothing twice")
	var again: Dictionary = Economy.repay_loan(economy, PLAYER_A, "loan-a", "repay-a-2", START + 2.0)
	_expect(not again.ok and again.reason == "already_repaid" and economy == accepted,
		"A repaid contract cannot be charged again")

	# A borrower without the full total cannot settle.
	var poor: Dictionary = _opened_bank()
	_borrow(poor, PLAYER_A, 50, TERM, "loan-poor", START)
	_expect(Economy.pay(poor, PLAYER_A, PLAYER_B, 118, "drain-a", START).ok,
		"The borrower spends most of its cash")
	var before_poor: Dictionary = poor.duplicate(true)
	var refused: Dictionary = Economy.repay_loan(poor, PLAYER_A, "loan-poor", "repay-poor", START + 1.0)
	_expect(not refused.ok and refused.reason == "insufficient" and poor == before_poor,
		"Repayment below the total is refused without partial payment")


func _test_settle_and_overdue() -> void:
	var economy: Dictionary = _opened_bank()
	_borrow(economy, PLAYER_A, 50, TERM, "loan-a", START)
	var total_before: int = Economy.total_cash(economy)
	var early: Dictionary = Economy.settle_loans(economy, START + float(TERM) - 1.0)
	_expect(early.ok and early.count == 0
		and Economy.loan(economy, "loan-a").status == Loans.STATUS_OPEN,
		"A contract stays open before its due time")
	var due: Dictionary = Economy.settle_loans(economy, START + float(TERM))
	_expect(due.ok and due.count == 1 and due.overdue == ["loan-a"]
		and Economy.loan(economy, "loan-a").status == Loans.STATUS_OVERDUE,
		"The due sweep marks the contract overdue")
	_expect(Economy.bank_snapshot(economy).cash == Economy.BANK_CAPITAL - 50
		and Economy.total_cash(economy) == total_before,
		"Overdue changes no cash")
	var fee_before: int = int(Economy.loan(economy, "loan-a").fee)
	var repeat: Dictionary = Economy.settle_loans(economy, START + float(TERM) + 1.0)
	_expect(repeat.ok and repeat.count == 0,
		"A repeated sweep does not re-mark the same contract")
	var year_later: Dictionary = Economy.settle_loans(economy, START + 365.0 * DAY)
	_expect(year_later.ok and year_later.count == 0
		and Economy.loan(economy, "loan-a").status == Loans.STATUS_OVERDUE,
		"A year offline leaves the contract overdue, not compounded")
	var overdue_contract: Dictionary = Economy.loan(economy, "loan-a")
	_expect(overdue_contract.fee == fee_before and overdue_contract.principal == 50
		and Loans.outstanding_principal(economy) == 50,
		"The overdue fee and principal are unchanged after a long offline gap")
	_expect_valid(economy, "an overdue contract")
	var blocked: Dictionary = _borrow(economy, PLAYER_A, 10, TERM, "loan-overdue", START + 365.0 * DAY)
	_expect(not blocked.ok and blocked.reason == "loan_active",
		"An overdue borrower cannot take a new loan before settling")
	var settled: Dictionary = Economy.repay_loan(economy, PLAYER_A, "loan-a", "repay-overdue",
		START + 365.0 * DAY)
	_expect(settled.ok and settled.amount == 53
		and Economy.loan(economy, "loan-a").status == Loans.STATUS_REPAID,
		"An overdue contract can still be settled normally")
	var renewed: Dictionary = _borrow(economy, PLAYER_A, 10, TERM, "loan-renewed",
		START + 365.0 * DAY)
	_expect(renewed.ok and renewed.amount == 10 and Economy.loan(economy, "loan-renewed").status == Loans.STATUS_OPEN,
		"After settlement the borrower may borrow again")
	_expect(not Economy.settle_loans(economy, -1.0).ok, "A negative sweep time is refused")


func _test_legacy_and_restore() -> void:
	var farm: Farm = _account_farm()
	var legacy_snapshot: Dictionary = farm.snapshot()
	legacy_snapshot.economy.erase("bank")
	legacy_snapshot.economy.erase("loans")
	_expect(Economy.valid(legacy_snapshot.economy),
		"An economy written before the bank and loans stays valid")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(legacy_snapshot),
		"The pre-bank snapshot restores without a migration")
	var state: Dictionary = restored.economy_snapshot()
	_expect(state.bank.opened == false and state.bank.cash == 0 and state.bank.capital == 0
		and state.loans is Dictionary and state.loans.is_empty(),
		"A pre-bank economy reads as closed, zero cash and zero capital")
	_expect(Economy.open_bank(state, "legacy-bank", START).ok,
		"The restored bank opens normally")
	_expect(Economy.borrow_loan(state, PLAYER_A, 50, TERM, "legacy-loan", START).ok,
		"A restored pre-bank economy can issue a loan")
	_expect(_commit(restored, state), "The opened bank commits through the farm boundary")
	_expect_valid(restored.economy_snapshot(), "a restored and opened bank")

	var m7: Dictionary = farm.economy_snapshot()
	m7.erase("market")
	m7.erase("ledger")
	m7.erase("bank")
	m7.erase("loans")
	_expect(Economy.valid(m7), "A full M7 economy remains readable")
	Economy.adopt_ledger(m7)
	_expect(m7.ledger.opening == m7.ledger.balances,
		"Adoption sets the opening checkpoint equal to the empty-log balances")
	_expect(Economy.open_bank(m7, "m7-bank", START).ok,
		"An adopted pre-ledger economy can open the bank")
	_expect_valid(m7, "an adopted pre-ledger bank")


## Hardening from the M8-02 review: a missing journal cannot skip reconciliation
## once a bank exists, system event namespaces are not user command ids, the
## term is stored instead of re-derived, and contract/repay ids cannot overlap.
func _test_review_hardening() -> void:
	var farm: Farm = _account_farm()
	var state: Dictionary = farm.economy_snapshot()
	_expect(Economy.open_bank(state, "bank-open", START).ok, "The bank opens for hardening")
	var journal_less: Dictionary = state.duplicate(true)
	journal_less.erase("ledger")
	_expect(not Economy.valid(journal_less),
		"A document with a bank but no journal is refused instead of skipping reconciliation")

	_expect(not Economy.open_account(state, PLAYER_E, "trade_1", START).ok,
		"A command id in the trade event namespace is refused")
	_expect(not _borrow(state, PLAYER_A, 50, TERM, "expire_2", START).ok,
		"A command id in the expiry namespace is refused")
	_expect(not _borrow(state, PLAYER_A, 50, TERM, "merchant_quote_3", START).ok,
		"A command id in the merchant quote namespace is refused")

	var far: float = 2147108927.8187392
	var late: Dictionary = _account_farm().economy_snapshot()
	_expect(Economy.open_bank(late, "bank-far", far).ok, "The bank opens at the far epoch")
	_expect(_borrow(late, PLAYER_A, 50, TERM, "loan-far", far).ok,
		"A loan opens at the far epoch")
	_expect(int(late.loans["loan-far"].term) == TERM, "The contract stores the chosen term")
	var far_snapshot: Dictionary = _account_farm().snapshot()
	far_snapshot.economy = late
	var far_farm := Farm.new()
	_expect(far_farm.restore_snapshot(far_snapshot),
		"A far-epoch contract restores instead of failing a float derivation")
	_expect(far_farm.economy_loans().size() == 1, "The far-epoch contract survives the reload")

	var overlap: Dictionary = state.duplicate(true)
	_expect(_borrow(overlap, PLAYER_A, 50, TERM, "loan-x", START).ok,
		"A loan opens for the id overlap case")
	overlap.loans["loan-x"].repay_id = "loan-x"
	_expect(not Loans.valid(overlap.loans),
		"A contract whose repay id equals a contract id is refused")
	overlap.loans["loan-x"].repay_id = ""
	_expect(_borrow(overlap, PLAYER_B, 50, TERM, "loan-y", START).ok,
		"A second borrower opens a loan")
	_expect(not Economy.repay_loan(overlap, PLAYER_A, "loan-x", "loan-y",
		START + DAY).ok, "A repayment may not reuse another contract's id")


func _test_persistence() -> void:
	var farm: Farm = _account_farm()
	var state: Dictionary = farm.economy_snapshot()
	_expect(Economy.open_bank(state, "bank-open", START).ok, "The bank opens for persistence")
	_expect(_borrow(state, PLAYER_A, 50, TERM, "loan-a", START).ok, "A loan opens for persistence")
	_expect(Economy.settle_loans(state, START + float(TERM)).ok, "The loan becomes overdue before saving")
	_expect(_commit(farm, state), "The bank and contract snapshot commits")
	var original: Dictionary = farm.snapshot()
	var json_value: Dictionary = JSON.parse_string(JSON.stringify(original))
	var restored := Farm.new()
	_expect(restored.restore_snapshot(json_value), "A JSON snapshot with bank and loans restores")
	var restored_state: Dictionary = restored.economy_snapshot()
	_expect(restored_state.bank.cash is int and restored_state.bank.cash == Economy.BANK_CAPITAL - 50,
		"JSON cash normalizes back to an integer")
	_expect(restored_state.loans["loan-a"].principal is int
		and restored_state.loans["loan-a"].fee is int
		and restored_state.loans["loan-a"].paid is int
		and restored_state.loans["loan-a"].due_utc is float,
		"JSON contract amounts normalize back to the right number types")
	_expect(restored_state == original.economy,
		"The bank, contracts and journal are identical after the JSON round trip")
	_expect_valid(restored_state, "a JSON restart")
	var store := FarmStore.new(test_root.path_join("store"))
	_expect(store.load_state().kind == "missing", "The isolated save directory is admitted")
	_expect(store.save(original, Decorations.new().snapshot()).ok,
		"A farm with a bank and contract saves")
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok, "The saved farm loads")
	var reopened := Farm.new()
	_expect(reopened.restore_snapshot(loaded.farm), "The saved farm restores")
	_expect(reopened.economy_snapshot() == original.economy,
		"The bank, contracts and journal survive the disk round trip")
	var restored_repay: Dictionary = reopened.economy_snapshot()
	var settled: Dictionary = Economy.repay_loan(restored_repay, PLAYER_A, "loan-a",
		"repay-restored", START + 365.0 * DAY)
	_expect(settled.ok, "The restored borrower can settle the overdue contract")
	_expect(_commit(reopened, restored_repay), "The restored repayment commits")
	var accepted: Dictionary = reopened.snapshot()
	var replay: Dictionary = Economy.repay_loan(reopened.economy_snapshot(), PLAYER_A,
		"loan-a", "repay-restored", START + 365.0 * DAY)
	_expect(replay.ok and replay.duplicate and reopened.snapshot() == accepted,
		"Replaying the restored repayment changes nothing")


func _test_reconcile_and_reserve() -> void:
	var economy: Dictionary = _opened_bank()
	_borrow(economy, PLAYER_A, 50, TERM, "loan-a", START)
	var report: Dictionary = Economy.reconcile(economy)
	_expect(report.ok and report.bank == Economy.BANK_CAPITAL - 50
		and report.total_cash == Economy.issued(economy),
		"Reconciliation includes the bank cash as a real cash holder")
	_expect(report.issuance - report.burned == report.issued,
		"Gross issuance minus burn still equals net issue with a bank")
	var statement: Dictionary = Economy.reserve_statement(economy)
	_expect(statement.ok and statement.bank == Economy.BANK_CAPITAL - 50
		and statement.bank_capital == Economy.BANK_CAPITAL
		and statement.loans_asset == 50 and statement.loans == 1
		and statement.loans_overdue == 0 and statement.loans_repaid == 0,
		"The reserve report shows real loan assets and bank cash")
	_expect(statement.claims == 0 and statement.reserve == statement.total_cash
		and statement.covered, "With no deposits the claim side stays zero")
	Economy.settle_loans(economy, START + float(TERM))
	var overdue_statement: Dictionary = Economy.reserve_statement(economy)
	_expect(overdue_statement.loans_asset == 50 and overdue_statement.loans_overdue == 1,
		"Overdue principal remains a loan asset")
	Economy.repay_loan(economy, PLAYER_A, "loan-a", "repay-a", START + float(TERM))
	var repaid_statement: Dictionary = Economy.reserve_statement(economy)
	_expect(repaid_statement.loans_asset == 0 and repaid_statement.loans_repaid == 1
		and repaid_statement.bank == Economy.BANK_CAPITAL + 3,
		"A repaid contract leaves the bank richer by the fee and off the loan book")
	_expect(repaid_statement.bank
		== repaid_statement.bank_capital - repaid_statement.loans_asset + 3,
		"Bank cash equals capital minus loans plus collected fees")
	_expect_valid(economy, "a repaid loan and reserve report")


func _test_tampering() -> void:
	var economy: Dictionary = _opened_bank()
	_borrow(economy, PLAYER_A, 50, TERM, "loan-a", START)
	var original: Dictionary = economy.duplicate(true)
	var corruptions: Array[Dictionary] = []
	var candidate: Dictionary = original.duplicate(true)
	candidate.accounts[PLAYER_A].cash = int(candidate.accounts[PLAYER_A].cash) + 1
	candidate.issued = int(candidate.issued) + 1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.loans["loan-a"].principal = 49
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.loans["loan-a"].principal = 50.5
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.loans["loan-a"].fee = 4
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.loans["loan-a"].status = "unknown"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.loans["loan-a"].due_utc = START - 1.0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.loans["loan-a"].status = Loans.STATUS_REPAID
	candidate.loans["loan-a"].paid = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.loans["loan-a"].repay_id = "repay-unexpected"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.bank.cash = int(candidate.bank.cash) + 1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.ledger.balances[Ledger.BANK] = int(candidate.ledger.balances[Ledger.BANK]) + 1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.loans["loan-b"] = candidate.loans["loan-a"].duplicate(true)
	candidate.loans["loan-b"].id = "loan-b"
	corruptions.append(candidate)
	for broken: Dictionary in corruptions:
		_expect(not Economy.valid(broken),
			"A balance, contract, bank or checkpoint inconsistency is rejected")

	var farm: Farm = _account_farm()
	var committed: Dictionary = farm.economy_snapshot()
	_expect(Economy.open_bank(committed, "bank-open", START).ok, "The tamper fixture opens the bank")
	_expect(_borrow(committed, PLAYER_A, 50, TERM, "loan-a", START).ok, "The tamper fixture borrows")
	_expect(_commit(farm, committed), "The tamper fixture commits")
	var gold: Dictionary = farm.snapshot()
	var no_entry: Dictionary = gold.duplicate(true)
	no_entry.economy.accounts[PLAYER_A].cash = int(no_entry.economy.accounts[PLAYER_A].cash) + 1
	no_entry.economy.issued = int(no_entry.economy.issued) + 1
	_expect(not farm.restore_snapshot(no_entry) and farm.snapshot() == gold,
		"A cash change without its journal entry is rejected at restore")
	var bad_contract: Dictionary = gold.duplicate(true)
	bad_contract.economy.loans["loan-a"].principal = -1
	_expect(not farm.restore_snapshot(bad_contract) and farm.snapshot() == gold,
		"An invalid contract amount is rejected at restore")
	var unbalanced: Dictionary = gold.duplicate(true)
	var issuance_balance: int = int(unbalanced.economy.ledger.balances[Ledger.ISSUANCE])
	unbalanced.economy.ledger.balances[Ledger.ISSUANCE] = issuance_balance + 1
	_expect(not farm.restore_snapshot(unbalanced) and farm.snapshot() == gold,
		"An unbalanced checkpoint is rejected at restore")

	var before_failure: Dictionary = economy.duplicate(true)
	_expect(not Economy.repay_loan(economy, PLAYER_B, "loan-a", "bad-repay", START).ok
		and economy == before_failure, "A refused repayment leaves the candidate untouched")
	_expect(not Economy.borrow_loan(economy, PLAYER_A, 5000, TERM, "bad-borrow", START).ok
		and economy == before_failure, "A refused borrow leaves the candidate untouched")


func _test_ledger_hardening() -> void:
	var economy: Dictionary = _opened_bank()
	_borrow(economy, PLAYER_A, 50, TERM, "loan-a", START)
	var original: Dictionary = economy.duplicate(true)
	_expect(original.ledger.opening is Dictionary,
		"A current ledger carries the persistent opening subfield")

	# A fabricated, internally balanced live entry without the matching
	# checkpoint movement must not be accepted.
	var forged: Dictionary = original.ledger.duplicate(true)
	var forged_sequence: int = int(forged.sequence) + 1
	var forged_id: String = "ledger_" + str(forged_sequence)
	forged.entries[forged_id] = _manual_entry(forged_sequence, "forged-event",
		Ledger.KIND_PAY, Ledger.owner_code(PLAYER_B), 5,
		Ledger.owner_code(PLAYER_A))
	forged.sequence = forged_sequence
	_expect(not Ledger.valid(forged),
		"A self-balanced live entry without a checkpoint change is rejected")
	var forged_economy: Dictionary = original.duplicate(true)
	forged_economy.ledger = forged
	_expect(not Economy.valid(forged_economy),
		"The forged live entry is also rejected at the economy boundary")

	# A duplicate live event id is rejected even when the balances do move and
	# the zero-sum and per-account invariants still hold.
	var duplicate: Dictionary = original.ledger.duplicate(true)
	var duplicate_sequence: int = int(duplicate.sequence) + 1
	var duplicate_id: String = "ledger_" + str(duplicate_sequence)
	duplicate.entries[duplicate_id] = _manual_entry(duplicate_sequence, "bank-open",
		Ledger.KIND_PAY, Ledger.owner_code(PLAYER_B), 1,
		Ledger.owner_code(PLAYER_A))
	duplicate.sequence = duplicate_sequence
	var cash_a: int = int(duplicate.balances[Ledger.owner_code(PLAYER_A)])
	var cash_b: int = int(duplicate.balances[Ledger.owner_code(PLAYER_B)])
	duplicate.balances[Ledger.owner_code(PLAYER_A)] = cash_a - 1
	duplicate.balances[Ledger.owner_code(PLAYER_B)] = cash_b + 1
	_expect(not Ledger.valid(duplicate),
		"A balanced live entry reusing an existing event id is rejected")
	var duplicate_economy: Dictionary = original.duplicate(true)
	duplicate_economy.ledger = duplicate
	_expect(not Economy.valid(duplicate_economy),
		"The duplicate event id is also rejected at the economy boundary")
	var posting: Dictionary = original.ledger.duplicate(true)
	var posting_before: Dictionary = posting.duplicate(true)
	var refused: Dictionary = Ledger.post(posting, Ledger.KIND_PAY, "bank-open", START, [
		Ledger.debit_line(Ledger.owner_code(PLAYER_B), 1),
		Ledger.credit_line(Ledger.owner_code(PLAYER_A), 1),
	])
	_expect(not refused.ok and refused.reason == "duplicate_event" and posting == posting_before,
		"Posting a duplicate event id is refused without touching the ledger")

	# A ledger written before `opening` existed is readable and normalizes to the
	# derived history net, not to invented entries.
	var legacy: Dictionary = original.ledger.duplicate(true)
	legacy.erase("opening")
	_expect(Ledger.valid(legacy), "A pre-opening ledger remains readable")
	var normalized: Dictionary = legacy.duplicate(true)
	Ledger.normalize(normalized)
	_expect(normalized.opening is Dictionary and Ledger.valid(normalized),
		"Normalization derives a valid opening subfield")
	_expect(int(normalized.opening[Ledger.owner_code(PLAYER_A)]) == 0
		and int(normalized.opening[Ledger.owner_code(PLAYER_B)]) == 0
		and int(normalized.opening[Ledger.ISSUANCE]) == 0,
		"Nothing has been evicted yet, so the derived opening net is zero")
	var opening_total: int = 0
	for value: Variant in normalized.opening.values():
		_expect(value is int, "Normalized opening amounts are integers")
		opening_total += int(value)
	_expect(opening_total == 0, "The opening checkpoint sums to zero")


func _test_eviction_and_durable_ids() -> void:
	var economy: Dictionary = _opened_bank()
	_borrow(economy, PLAYER_A, 50, TERM, "loan-a", START)
	for index: int in 600:
		var command_id: String = "pay-%03d" % index
		var result: Dictionary
		if index % 2 == 0:
			result = Economy.pay(economy, PLAYER_A, PLAYER_B, 1, command_id, START)
		else:
			result = Economy.pay(economy, PLAYER_B, PLAYER_A, 1, command_id, START)
		_expect(result.ok, "Transfer " + command_id + " succeeds")
	_expect(Economy.ledger_entries(economy).size() == Ledger.MAX_ENTRIES,
		"The journal is still bounded after 600 transfers")
	_expect(_event_entry(economy, "bank-open").is_empty()
		and _event_entry(economy, "loan-a").is_empty(),
		"Eviction removed the original bank and loan entries")
	_expect(Economy.loan(economy, "loan-a").status == Loans.STATUS_OPEN
		and Economy.bank_snapshot(economy).cash == Economy.BANK_CAPITAL - 50,
		"Eviction does not remove the contract or change bank cash")
	var live_ledger: Dictionary = Economy.ledger_snapshot(economy)
	_expect(live_ledger.opening is Dictionary and not live_ledger.opening.is_empty(),
		"Eviction moves history into the persistent opening checkpoint")
	var opening_total: int = 0
	for value: Variant in live_ledger.opening.values():
		_expect(value is int, "An evicted opening amount stays an integer")
		opening_total += int(value)
	_expect(opening_total == 0, "The opening checkpoint still sums to zero after eviction")
	var pre_opening: Dictionary = live_ledger.duplicate(true)
	pre_opening.erase("opening")
	_expect(Ledger.valid(pre_opening),
		"A ledger with real evicted history but no opening subfield stays readable")
	var derived: Dictionary = pre_opening.duplicate(true)
	Ledger.normalize(derived)
	_expect(derived.opening == live_ledger.opening,
		"Normalization reconstructs the exact opening net after eviction")
	_expect_valid(economy, "600 transfers after a loan")

	var accepted: Dictionary = economy.duplicate(true)
	var replay: Dictionary = _borrow(economy, PLAYER_A, 50, TERM, "loan-a", START)
	_expect(replay.ok and replay.duplicate and economy == accepted,
		"The durable contract replays a borrow id after its command result was evicted")
	economy.command_results = {}
	var before_conflict: Dictionary = economy.duplicate(true)
	var conflict: Dictionary = _borrow(economy, PLAYER_A, 100, TERM, "loan-a", START)
	_expect(not conflict.ok and conflict.reason == "command_conflict"
		and economy == before_conflict,
		"The durable contract also rejects a reused borrow id with another amount")
	_expect(_borrow(economy, PLAYER_A, 50, TERM, "loan-a", START).duplicate
		and economy == before_conflict,
		"The durable contract still replays the original borrow after the command window is gone")

	var paid: Dictionary = Economy.repay_loan(economy, PLAYER_A, "loan-a", "repay-a",
		START + float(TERM))
	_expect(paid.ok, "The evicted world can still settle the durable contract")
	economy.command_results = {}
	var repaid_state: Dictionary = economy.duplicate(true)
	var repay_replay: Dictionary = Economy.repay_loan(economy, PLAYER_A, "loan-a", "repay-a",
		START + float(TERM))
	_expect(repay_replay.ok and repay_replay.duplicate and economy == repaid_state,
		"The contract's repay id replays without a second debit after eviction")
	var wrong_durable: Dictionary = Economy.repay_loan(economy, PLAYER_B, "loan-a", "repay-a",
		START + float(TERM))
	_expect(not wrong_durable.ok and wrong_durable.reason == "not_borrower"
		and economy == repaid_state,
		"Another player cannot reuse the durable repayment id")
	_expect_valid(economy, "eviction with a durable repayment id")


func _economy_fixture() -> Dictionary:
	var farm: Farm = _account_farm()
	return farm.economy_snapshot()


func _account_farm() -> Farm:
	var farm := Farm.new(START)
	farm.economy_open_account("open-a", PLAYER_A, START)
	farm.economy_open_account("open-b", PLAYER_B, START)
	farm.economy_open_account("open-c", PLAYER_C, START)
	farm.economy_open_account("open-d", PLAYER_D, START)
	return farm


func _opened_bank() -> Dictionary:
	var economy: Dictionary = _economy_fixture()
	Economy.open_bank(economy, "bank-open", START)
	return economy


func _borrow(economy: Dictionary, borrower: String, principal: Variant, term: Variant,
		command_id: String, now_utc: float) -> Dictionary:
	return Economy.borrow_loan(economy, borrower, principal, term, command_id, now_utc)


func _commit(farm: Farm, economy: Dictionary) -> bool:
	var snapshot: Dictionary = farm.snapshot()
	snapshot.economy = economy
	return farm.restore_snapshot(snapshot)


func _expect_valid(economy: Dictionary, label: String) -> void:
	_expect(Economy.valid(economy), "The economy validates after " + label)
	_expect(Economy.reconcile(economy).ok, "The ledger reconciles after " + label)
	_expect(Economy.total_cash(economy) == Economy.issued(economy),
		"Total cash equals net issue after " + label)
	_expect(Loans.valid(economy.get("loans", {})), "Every contract is valid after " + label)
	for entry: Dictionary in Economy.ledger_entries(economy):
		_expect(_balanced(entry), "Every live entry is balanced after " + label)


func _manual_entry(sequence: int, event_id: String, kind: String, debit_code: String,
		amount: int, credit_code: String) -> Dictionary:
	return {
		"id": "ledger_" + str(sequence), "sequence": sequence, "kind": kind,
		"event_id": event_id, "at_utc": START, "debit": amount, "credit": amount,
		"lines": [
			{"account": debit_code, "debit": amount, "credit": 0},
			{"account": credit_code, "debit": 0, "credit": amount},
		],
	}


func _event_entry(economy: Dictionary, event_id: String) -> Dictionary:
	for entry: Dictionary in Economy.ledger_entries(economy):
		if str(entry.event_id) == event_id:
			return entry
	return {}


func _balanced(entry: Dictionary) -> bool:
	var debit: int = 0
	var credit: int = 0
	for raw_line: Dictionary in entry.lines:
		debit += int(raw_line.debit)
		credit += int(raw_line.credit)
	return debit == credit and debit == int(entry.debit) and credit == int(entry.credit) \
		and debit > 0


## Signed line amount: debit is positive, credit negative.
func _line(entry: Dictionary, code: String) -> int:
	for raw_line: Dictionary in entry.lines:
		if str(raw_line.account) == code:
			return int(raw_line.debit) - int(raw_line.credit)
	return 0


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
