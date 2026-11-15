extends SceneTree
## M8 bank deposits: player principal moves into real bank cash, the liability
## shows up in the reserve report, and a bank without cash refuses a payout by
## name. Headless and isolated: no clock, scene or live save. FarmState wrappers
## are intentionally not touched by this slice, so the test drives the economy
## candidate directly and restores it through the existing farm boundary.

const Farm = preload("res://farm/farm_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const Loans = preload("res://farm/loan_state.gd")
const Deposits = preload("res://farm/deposit_state.gd")
const Ledger = preload("res://farm/ledger_state.gd")

const START: float = 1800000000.0
const DAY: float = 86400.0
const TERM: int = 604800
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const PLAYER_D: String = "player_00000000000000000000000000000004"
const PLAYER_E: String = "player_00000000000000000000000000000005"
const PLAYER_F: String = "player_00000000000000000000000000000006"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_deposit_moves_real_cash()
	_test_withdraw_restores()
	_test_two_depositors()
	_test_replay_and_conflict()
	_test_refusals()
	_test_reserve_statement()
	_test_bank_run()
	_test_legacy_document()
	_test_restore_and_persistence()
	_test_tampering()
	for failure: String in failures:
		push_error(failure)
	print("DEPOSIT_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_deposit_moves_real_cash() -> void:
	var economy: Dictionary = _opened_bank()
	var total_before: int = Economy.total_cash(economy)
	var issued_before: int = Economy.issued(economy)
	var result: Dictionary = _deposit(economy, PLAYER_A, 100, "dep-a", START + 1.0)
	_expect(result.ok and not result.duplicate and result.amount == 100
		and result.principal == 100, "A player deposits 100 COIN of principal")
	_expect(Economy.cash(economy, PLAYER_A) == 120 - 100,
		"Depositing debits the player's account")
	_expect(Economy.bank_cash(economy) == Economy.BANK_CAPITAL + 100,
		"Depositing credits the bank's real cash")
	_expect(Economy.deposit_principal(economy, PLAYER_A) == 100
		and Economy.deposits_liability(economy) == 100,
		"The deposit table records the 100 COIN claim")
	_expect(Economy.total_cash(economy) == total_before
		and Economy.issued(economy) == issued_before,
		"Depositing moves cash and issues nothing")
	var entry: Dictionary = _event_entry(economy, "dep-a")
	_expect(entry.kind == Ledger.KIND_DEPOSIT_IN and _balanced(entry),
		"A deposit posts one balanced deposit_in entry")
	_expect(_line(entry, Ledger.BANK) == 100
		and _line(entry, Ledger.owner_code(PLAYER_A)) == -100,
		"The bank is debited and the depositor credited by the principal")
	_expect_valid(economy, "a deposit")
	var report: Dictionary = Economy.reconcile(economy)
	_expect(report.ok and report.deposits == 100 and report.bank == Economy.BANK_CAPITAL + 100,
		"Reconciliation reports the bank cash and the deposit liability")
	_expect(int(economy.deposits.accounts[PLAYER_A].principal) == 100
		and float(economy.deposits.accounts[PLAYER_A].deposited_utc) == START + 1.0,
		"The account row carries the principal and the deposit instant")


func _test_withdraw_restores() -> void:
	var economy: Dictionary = _opened_bank()
	_deposit(economy, PLAYER_A, 100, "dep-a", START + 1.0)
	var taken: Dictionary = _withdraw(economy, PLAYER_A, 40, "wd-a", START + 2.0)
	_expect(taken.ok and taken.amount == 40 and taken.principal == 60,
		"A partial withdrawal pays 40 and leaves 60")
	_expect(Economy.cash(economy, PLAYER_A) == 60 and Economy.bank_cash(economy)
		== Economy.BANK_CAPITAL + 60,
		"Withdrawing credits the player and debits the bank")
	var entry: Dictionary = _event_entry(economy, "wd-a")
	_expect(entry.kind == Ledger.KIND_DEPOSIT_OUT and _balanced(entry)
		and _line(entry, Ledger.owner_code(PLAYER_A)) == 40
		and _line(entry, Ledger.BANK) == -40,
		"A withdrawal posts one balanced deposit_out entry")
	var rest: Dictionary = _withdraw(economy, PLAYER_A, 60, "wd-a-rest", START + 3.0)
	_expect(rest.ok and rest.principal == 0
		and not economy.deposits.accounts.has(PLAYER_A),
		"Withdrawing the rest closes the claim and drops the row")
	_expect(Economy.cash(economy, PLAYER_A) == 120
		and Economy.bank_cash(economy) == Economy.BANK_CAPITAL,
		"A full round trip restores both balances exactly")
	_expect_valid(economy, "a full withdrawal")


func _test_two_depositors() -> void:
	var economy: Dictionary = _opened_bank()
	_deposit(economy, PLAYER_A, 50, "dep-a", START + 1.0)
	_deposit(economy, PLAYER_B, 70, "dep-b", START + 2.0)
	_expect(Economy.deposit_principal(economy, PLAYER_A) == 50
		and Economy.deposit_principal(economy, PLAYER_B) == 70
		and Economy.deposits_liability(economy) == 120,
		"Two depositors keep independent claims")
	_expect(Economy.cash(economy, PLAYER_A) == 70 and Economy.cash(economy, PLAYER_B) == 50,
		"Each depositor's cash falls by its own principal")
	var paid: Dictionary = _withdraw(economy, PLAYER_A, 50, "wd-a", START + 3.0)
	_expect(paid.ok and Economy.deposit_principal(economy, PLAYER_B) == 70
		and Economy.deposits_liability(economy) == 70,
		"One depositor's withdrawal does not touch another's claim")
	_expect(Economy.cash(economy, PLAYER_A) == 120 and Economy.cash(economy, PLAYER_B) == 50,
		"Only the withdrawing depositor's cash rises")
	_expect_valid(economy, "two depositors")


func _test_replay_and_conflict() -> void:
	var economy: Dictionary = _opened_bank()
	_deposit(economy, PLAYER_A, 100, "dep-a", START + 1.0)
	var accepted: Dictionary = economy.duplicate(true)
	var replay: Dictionary = _deposit(economy, PLAYER_A, 100, "dep-a", START + 1.0)
	_expect(replay.ok and replay.duplicate and replay.amount == 100,
		"Replaying a deposit id returns the first result")
	_expect(economy == accepted, "A replayed deposit moves no cash and adds no entry")
	var conflict: Dictionary = _deposit(economy, PLAYER_A, 90, "dep-a", START + 1.0)
	_expect(not conflict.ok and conflict.reason == "command_conflict"
		and economy == accepted,
		"Reusing a deposit id with another amount is a conflict")
	var shared: Dictionary = Economy.pay(economy, PLAYER_A, PLAYER_B, 5, "shared-id", START + 2.0)
	_expect(shared.ok, "A payment uses a command id before the deposit")
	var reused: Dictionary = _deposit(economy, PLAYER_A, 20, "shared-id", START + 2.0)
	_expect(not reused.ok and reused.reason == "command_conflict"
		and Economy.deposit_principal(economy, PLAYER_A) == 100,
		"Deposits share the economy command namespace with payments")
	# The live journal is the second guard: with the command window forgotten,
	# a retained deposit_in entry still refuses a duplicate event id.
	economy.command_results = {}
	var before: Dictionary = economy.duplicate(true)
	var guard: Dictionary = _deposit(economy, PLAYER_A, 100, "dep-a", START + 1.0)
	_expect(not guard.ok and guard.reason == "duplicate_event" and economy == before,
		"While the journal retains the event, the same id is refused without moving cash")
	var withdraw_replay: Dictionary = _withdraw(economy, PLAYER_A, 10, "wd-a", START + 3.0)
	_expect(withdraw_replay.ok, "A withdrawal succeeds")
	var withdraw_state: Dictionary = economy.duplicate(true)
	var again: Dictionary = _withdraw(economy, PLAYER_A, 10, "wd-a", START + 3.0)
	_expect(again.ok and again.duplicate and economy == withdraw_state,
		"Replaying a withdrawal id pays nothing twice")
	var withdraw_conflict: Dictionary = _withdraw(economy, PLAYER_A, 20, "wd-a", START + 4.0)
	_expect(not withdraw_conflict.ok and withdraw_conflict.reason == "command_conflict"
		and economy == withdraw_state,
		"Reusing a withdrawal id with another amount is a conflict")


func _test_refusals() -> void:
	var economy: Dictionary = _opened_bank()
	_expect(_deposit(economy, PLAYER_A, 9, "bad-min", START).reason == "invalid_amount",
		"A deposit below the minimum is refused")
	_expect(_deposit(economy, PLAYER_A, 1001, "bad-max", START).reason == "invalid_amount",
		"A deposit above the single-command maximum is refused")
	for bad: Variant in [0, -1, 1.5, "100", float(Deposits.MAX_SAFE_INTEGER)]:
		_expect(_deposit(economy, PLAYER_A, bad, "bad-amount", START).reason == "invalid_amount",
			"A zero, negative, fractional string or huge deposit is refused")
	_expect(_deposit(economy, "@world", 100, "bad-world", START).reason == "invalid_player",
		"The public inventory owner cannot deposit")
	_expect(_deposit(economy, "org_team", 100, "bad-org", START).reason == "invalid_player",
		"An organization cash account cannot deposit out of band")
	_expect(_deposit(economy, "bad id", 100, "bad-player", START).reason == "invalid_player",
		"An invalid player id is refused")
	_expect(_deposit(economy, PLAYER_A, 200, "too-much", START).reason == "insufficient",
		"A deposit above the player's cash is refused")
	var frozen: Dictionary = economy.duplicate(true)
	_expect(_deposit(economy, PLAYER_A, 100, "trade_1", START).reason == "invalid_command",
		"A command id in a reserved event namespace is refused")
	_expect(economy == frozen, "Every refused deposit leaves the candidate untouched")

	var closed: Dictionary = _accounts_only()
	_expect(_deposit(closed, PLAYER_A, 100, "closed-dep", START).reason == "not_open",
		"Depositing into a closed bank is refused")
	_expect(_withdraw(closed, PLAYER_A, 100, "closed-wd", START).reason == "not_open",
		"Withdrawing from a closed bank is refused")

	var economy2: Dictionary = _borrowed_bank()
	_expect(_deposit(economy2, PLAYER_A, 1000, "cap-1", START + 1.0).ok,
		"A maximum deposit is accepted")
	_expect(Economy.deposit_principal(economy2, PLAYER_A) == Deposits.MAX_PRINCIPAL,
		"The per-account principal cap can be reached exactly")
	var capped: Dictionary = _deposit(economy2, PLAYER_A, 10, "cap-3", START + 2.0)
	_expect(not capped.ok and capped.reason == "deposit_capacity",
		"A deposit above the per-account principal cap is refused")

	var economy3: Dictionary = _opened_bank()
	_expect(_withdraw(economy3, PLAYER_A, 10, "no-claim", START).reason == "insufficient",
		"Withdrawing without a claim is refused")
	_deposit(economy3, PLAYER_A, 50, "dep-a", START)
	_expect(_withdraw(economy3, PLAYER_A, 51, "over-claim", START).reason == "insufficient",
		"Withdrawing above the claim is refused")
	for bad: Variant in [0, -1, 1.5, "50", float(Deposits.MAX_SAFE_INTEGER)]:
		_expect(_withdraw(economy3, PLAYER_A, bad, "bad-wd", START).reason == "invalid_amount",
			"A zero, negative, fractional string or huge withdrawal is refused")
	_expect(Economy.deposit_principal(economy3, PLAYER_A) == 50
		and Economy.cash(economy3, PLAYER_A) == 70,
		"Refused withdrawals leave the claim and cash unchanged")


func _test_reserve_statement() -> void:
	var economy: Dictionary = _opened_bank()
	var empty: Dictionary = Economy.reserve_statement(economy)
	_expect(empty.claims == 0 and empty.reserve == Economy.bank_cash(economy) and empty.covered,
		"Without deposits the claim side is zero and the bank covers it")
	_deposit(economy, PLAYER_A, 100, "dep-a", START)
	_deposit(economy, PLAYER_B, 100, "dep-b", START + 1.0)
	var statement: Dictionary = Economy.reserve_statement(economy)
	_expect(statement.ok and statement.claims == 200 and statement.deposits == 200
		and statement.deposit_accounts == 2,
		"The reserve report's claim side is the real deposit liability")
	_expect(statement.reserve == Economy.bank_cash(economy)
		and statement.reserve == statement.bank,
		"The reserve is the bank's own cash, not every holder's cash")
	_expect(statement.covered and statement.reserve >= statement.claims,
		"A bank holding more cash than its deposits is covered")
	_expect(statement.total_cash == statement.issued,
		"Deposits never break total_cash == issued")
	# Drain the bank by lending most of its cash: the same claims are no longer
	# covered, and the report says so instead of hiding it.
	_expect(Economy.borrow_loan(economy, PLAYER_D, 1000, TERM, "loan-d", START + 2.0).ok,
		"The bank lends out most of its cash")
	_expect(Economy.borrow_loan(economy, PLAYER_E, 900, TERM, "loan-e", START + 2.0).ok,
		"The bank lends out more of its cash")
	_expect(Economy.borrow_loan(economy, PLAYER_F, 300, TERM, "loan-f", START + 2.0).ok,
		"The bank lends the rest it can")
	var drained: Dictionary = Economy.reserve_statement(economy)
	_expect(Economy.bank_cash(economy) == 0,
		"After lending out its cash the bank holds nothing")
	_expect(drained.reserve < drained.claims and not drained.covered,
		"Covered flips to false when bank cash falls below the deposit claims")
	_expect(Economy.total_cash(economy) == Economy.issued(economy),
		"Lending and deposits together still conserve the issued total")
	_expect_valid(economy, "an under-reserved bank")


func _test_bank_run() -> void:
	# Three depositors of 100 COIN against a bank that lent out most of its cash:
	# the first two payouts succeed, the third is refused by name.
	var economy: Dictionary = _opened_bank()
	for player: String in [PLAYER_A, PLAYER_B, PLAYER_C]:
		_expect(_deposit(economy, player, 100, "dep-" + player, START).ok,
			"Depositor " + player + " deposits 100")
	_expect(Economy.borrow_loan(economy, PLAYER_D, 1000, TERM, "loan-d", START + 1.0).ok,
		"The bank lends 1000 to D")
	_expect(Economy.borrow_loan(economy, PLAYER_E, 900, TERM, "loan-e", START + 1.0).ok,
		"The bank lends 900 to E")
	_expect(Economy.borrow_loan(economy, PLAYER_F, 140, TERM, "loan-f", START + 1.0).ok,
		"The bank lends 140 to F")
	_expect(Economy.bank_cash(economy) == 260 and Economy.deposits_liability(economy) == 300,
		"The bank holds 260 COIN against 300 COIN of claims")
	var refused_at: int = -1
	var payouts: Array = [PLAYER_A, PLAYER_B, PLAYER_C]
	for index: int in payouts.size():
		var player: String = payouts[index]
		var before: Dictionary = economy.duplicate(true)
		var result: Dictionary = _withdraw(economy, player, 100, "wd-" + player, START + 2.0)
		if result.ok:
			continue
		_expect(result.reason == "insufficient_reserve" and economy == before,
			"Depositor %d is refused by name and the state is unchanged" % (index + 1))
		if refused_at < 0:
			refused_at = index
	_expect(refused_at == 2, "The third depositor in arrival order is the one refused")
	_expect(Economy.bank_cash(economy) == 60
		and Economy.deposits_liability(economy) == 100,
		"After the run, bank cash 60 and remaining claims 100 still agree")
	_expect(Economy.deposits_liability(economy) > Economy.bank_cash(economy),
		"The remaining depositor's claim is larger than the cash left")
	_expect_valid(economy, "a completed bank run")
	# The bound is real cash, not a rate limiter: the remaining depositor can
	# still take exactly what the bank holds.
	var partial: Dictionary = _withdraw(economy, PLAYER_C, 60, "wd-c-part", START + 3.0)
	_expect(partial.ok and partial.principal == 40
		and Economy.bank_cash(economy) == 0,
		"A withdrawal equal to the remaining bank cash is paid")
	var stuck: Dictionary = _withdraw(economy, PLAYER_C, 40, "wd-c-rest", START + 4.0)
	_expect(not stuck.ok and stuck.reason == "insufficient_reserve"
		and Economy.deposit_principal(economy, PLAYER_C) == 40,
		"The unbacked remainder stays a claim instead of overdrawing the bank")
	_expect_valid(economy, "an exhausted bank")


func _test_legacy_document() -> void:
	# A legal pre-deposit document is one that never took a deposit. Its bank
	# equation has no liability term, so erasing the key must read back as the
	# empty table instead of failing.
	var farm: Farm = _account_farm()
	var economy: Dictionary = farm.economy_snapshot()
	_expect(Economy.open_bank(economy, "bank-open", START).ok, "The bank opens for the legacy case")
	_expect(_commit(farm, economy), "The pre-deposit bank commits through the farm boundary")
	var snapshot: Dictionary = farm.snapshot()
	_expect(snapshot.economy.deposits.accounts.is_empty(),
		"An opened bank with no deposit carries an empty claim table")
	var legacy: Dictionary = snapshot.duplicate(true)
	legacy.economy.erase("deposits")
	_expect(Economy.valid(legacy.economy),
		"An economy written before deposits stays valid")
	_expect(Deposits.liability(legacy.economy.get("deposits")) == 0,
		"A missing deposit table reads as a zero liability")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(legacy),
		"The pre-deposit snapshot restores without a migration")
	var restored_state: Dictionary = restored.economy_snapshot()
	_expect(restored_state.deposits is Dictionary and restored_state.deposits.accounts.is_empty(),
		"A pre-deposit economy restores as an empty claim table")
	_expect(Economy.deposits_liability(restored_state) == 0
		and Economy.bank_cash(restored_state) == Economy.BANK_CAPITAL,
		"Restoring invents no deposit and no cash")
	var statement: Dictionary = Economy.reserve_statement(restored_state)
	_expect(statement.claims == 0 and statement.covered,
		"The restored report has no claim side")
	_expect(_deposit(restored_state, PLAYER_A, 100, "legacy-dep", START + 1.0).ok
		and restored.restore_snapshot(_with_economy(restored.snapshot(), restored_state)),
		"A restored pre-deposit world accepts its first deposit")
	# Erasing the key from a document that really holds a deposit would hide a
	# liability, so that shape is refused instead of being read as zero.
	var dishonest: Dictionary = restored.snapshot().duplicate(true)
	dishonest.economy.erase("deposits")
	_expect(not Economy.valid(dishonest.economy),
		"A bank holding a real deposit cannot drop the table to hide the liability")
	# A full pre-bank economy has neither bank, loans nor deposits.
	var m7: Dictionary = _accounts_only()
	m7.erase("bank")
	m7.erase("loans")
	m7.erase("deposits")
	_expect(Economy.valid(m7), "A full pre-bank economy remains readable")
	var restored_m7 := Farm.new()
	var m7_snapshot: Dictionary = Farm.new(START).snapshot()
	m7_snapshot.economy = m7
	_expect(restored_m7.restore_snapshot(m7_snapshot),
		"A pre-bank economy without deposits restores")
	_expect(restored_m7.economy_snapshot().deposits.accounts.is_empty()
		and restored_m7.economy_snapshot().loans.is_empty(),
		"A pre-bank economy restores empty loans and deposits")


func _test_restore_and_persistence() -> void:
	var farm: Farm = _account_farm()
	var economy: Dictionary = farm.economy_snapshot()
	_expect(Economy.open_bank(economy, "bank-open", START).ok, "The bank opens for persistence")
	_deposit(economy, PLAYER_A, 120, "dep-a", START + 1.0)
	_deposit(economy, PLAYER_B, 60, "dep-b", START + 2.0)
	_expect(_withdraw(economy, PLAYER_A, 20, "wd-a", START + 3.0).ok, "A withdrawal precedes the save")
	_expect(_commit(farm, economy), "The deposited economy commits")
	var original: Dictionary = farm.snapshot()
	var json_value: Dictionary = JSON.parse_string(JSON.stringify(original))
	var restored := Farm.new()
	_expect(restored.restore_snapshot(json_value), "A JSON snapshot with deposits restores")
	var restored_state: Dictionary = restored.economy_snapshot()
	_expect(restored_state.deposits == original.economy.deposits,
		"Deposit rows are identical after the JSON round trip")
	_expect(restored_state.deposits.accounts[PLAYER_A].principal is int
		and restored_state.deposits.accounts[PLAYER_A].deposited_utc is float,
		"JSON deposit amounts normalize back to the right number types")
	_expect_valid(restored_state, "a JSON restart")
	var accepted: Dictionary = restored.snapshot()
	var replay: Dictionary = _deposit(restored.economy_snapshot(), PLAYER_A, 120,
		"dep-a", START + 1.0)
	_expect(replay.ok and replay.duplicate and restored.snapshot() == accepted,
		"Replaying a restored deposit changes nothing")
	var later: Dictionary = _withdraw(restored.economy_snapshot(), PLAYER_B, 60, "wd-b", START + 4.0)
	_expect(later.ok and later.principal == 0, "The restored claimant can withdraw the rest")


func _test_tampering() -> void:
	var economy: Dictionary = _opened_bank()
	_deposit(economy, PLAYER_A, 100, "dep-a", START)
	_expect_valid(economy, "the tamper fixture")
	var original: Dictionary = economy.duplicate(true)
	var corruptions: Array[Dictionary] = []
	var candidate: Dictionary = original.duplicate(true)
	candidate.deposits.accounts[PLAYER_A].principal = 90
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.deposits.accounts[PLAYER_A].principal = 100.5
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.deposits.accounts[PLAYER_A].principal = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.deposits.accounts["@world"] = {"principal": 100, "deposited_utc": START}
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.deposits.accounts[PLAYER_B] = {"principal": 100, "deposited_utc": START}
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.deposits.accounts[PLAYER_A].extra = 1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.deposits.accounts = {}
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.bank.cash = int(candidate.bank.cash) - 1
	corruptions.append(candidate)
	for broken: Dictionary in corruptions:
		_expect(not Economy.valid(broken),
			"A tampered deposit row, extra key or bank cash is rejected")


func _accounts_only() -> Dictionary:
	return _account_farm().economy_snapshot()


func _account_farm() -> Farm:
	var farm := Farm.new(START)
	for player: String in [PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D, PLAYER_E, PLAYER_F]:
		farm.economy_open_account("open-" + player, player, START)
	return farm


func _opened_bank() -> Dictionary:
	var economy: Dictionary = _accounts_only()
	Economy.open_bank(economy, "bank-open", START)
	return economy


## An opened bank whose cash was partly lent to A, so A can deposit the maximum.
func _borrowed_bank() -> Dictionary:
	var economy: Dictionary = _opened_bank()
	Economy.borrow_loan(economy, PLAYER_A, 1000, TERM, "seed-loan", START)
	return economy


func _with_economy(snapshot: Dictionary, economy: Dictionary) -> Dictionary:
	snapshot.economy = economy
	return snapshot


func _deposit(economy: Dictionary, player: String, amount: Variant, command_id: String,
		now_utc: float) -> Dictionary:
	var result: Dictionary = Deposits.deposit(economy, player, amount, command_id, now_utc)
	if result.ok and not result.duplicate:
		economy.clear()
		economy.merge(result.document, true)
	return result


func _withdraw(economy: Dictionary, player: String, amount: Variant, command_id: String,
		now_utc: float) -> Dictionary:
	var result: Dictionary = Deposits.withdraw(economy, player, amount, command_id, now_utc)
	if result.ok and not result.duplicate:
		economy.clear()
		economy.merge(result.document, true)
	return result


func _commit(farm: Farm, economy: Dictionary) -> bool:
	var snapshot: Dictionary = farm.snapshot()
	snapshot.economy = economy
	return farm.restore_snapshot(snapshot)


func _expect_valid(economy: Dictionary, label: String) -> void:
	_expect(Economy.valid(economy), "The economy validates after " + label)
	_expect(Economy.reconcile(economy).ok, "The ledger reconciles after " + label)
	_expect(Economy.total_cash(economy) == Economy.issued(economy),
		"Total cash equals net issue after " + label)
	_expect(Deposits.valid(economy.get("deposits", Deposits.initial_state())),
		"Every deposit row is valid after " + label)
	var bank: Dictionary = Economy.bank_snapshot(economy)
	_expect(int(bank.cash) == int(bank.capital) - Loans.outstanding_principal(economy)
		+ Loans.collected_fees(economy) + Economy.deposits_liability(economy),
		"Bank cash equals capital - loans + fees + deposits after " + label)
	for entry: Dictionary in Economy.ledger_entries(economy):
		_expect(_balanced(entry), "Every live entry is balanced after " + label)


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
