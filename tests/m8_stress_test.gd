extends SceneTree
## M8-05 stress fixture. Pure rules only: no scene, renderer, network or live
## save. Every scenario builds its own FarmState from the public rule entry
## points and asserts actual balances, contract rows, order rows and goods.
##
## Covered: bad debt against the one-time bank capital, concentrated spending
## of escrowed cash, a poor harvest with merchant inventory/cash exhaustion and
## recovery, a 60-day offline catch-up against day-by-day sweeps, a household
## that never opens the bank or market, and the current absence of any
## insurance payout or compensatory issuance.
##
## The executable rule surface is the one the authority uses: FarmState's
## candidate-committing wrappers plus Economy/Loans/Market query functions.

const Farm = preload("res://farm/farm_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const Loans = preload("res://farm/loan_state.gd")
const Market = preload("res://farm/market_state.gd")
const Ledger = preload("res://farm/ledger_state.gd")

const START: float = 1800000000.0
const HOUR: float = 3600.0
const DAY: float = 86400.0
const TERM: float = 604800.0
const PLAYER_A: String = "player_stress_a"
const PLAYER_B: String = "player_stress_b"
const PLAYER_C: String = "player_stress_c"
const PLAYER_D: String = "player_stress_d"
const PLAYER_E: String = "player_stress_e"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_scenario_bad_debt()
	_scenario_concentrated_withdrawal()
	_scenario_poor_harvest()
	_scenario_long_offline()
	_scenario_no_finance()
	_scenario_no_payout()
	for failure: String in failures:
		push_error(failure)
	print("M8_STRESS_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


## 1. Bad debt and the bank reserve. Five borrowers open at one instant. A and
## B take near-limit loans, C repays to produce a real fee, D takes the last
## cash, and A/B/D default at term. The bank cannot fund E and no compensation
## or fresh issuance appears when the contracts go overdue.
func _scenario_bad_debt() -> void:
	var farm: Farm = _open_accounts([PLAYER_A, PLAYER_B, PLAYER_C, PLAYER_D, PLAYER_E])
	_expect_ok(farm.economy_open_bank("bank-open", START), "bad debt: open bank")
	_expect_ok(farm.economy_borrow_loan("loan-a", PLAYER_A, 1000, TERM, START),
		"bad debt: A borrows 1000")
	_expect_ok(farm.economy_borrow_loan("loan-b", PLAYER_B, 900, TERM, START),
		"bad debt: B borrows 900")
	_expect_ok(farm.economy_borrow_loan("loan-c", PLAYER_C, 100, TERM, START),
		"bad debt: C borrows 100")
	_eq_int(farm.economy_bank().cash, 0, "bad debt: bank cash after three issues")
	_expect_ok(farm.economy_repay_loan("repay-c", PLAYER_C, "loan-c", START + DAY),
		"bad debt: C repays principal plus fee")
	_eq_int(int(farm.economy_loan("loan-c").paid), 105, "bad debt: C pays 100 + 5")
	_expect_ok(farm.economy_borrow_loan("loan-d", PLAYER_D, 100, TERM, START + DAY),
		"bad debt: D takes the last affordable principal")
	var issued_before: int = farm.economy_issued()
	var total_before: int = farm.economy_total_cash()
	_eq_int(issued_before, 2600, "bad debt: 5 grants + 2000 capital are the only issuance")
	_eq_int(total_before, issued_before, "bad debt: total cash equals issued before defaults")
	_eq_int(farm.economy_bank().cash, 5, "bad debt: bank keeps 105 - 100 cash")
	_eq_int(Loans.outstanding_principal(farm.economy_snapshot()), 2000,
		"bad debt: outstanding principal is A+B+D")
	_eq_int(Loans.collected_fees(farm.economy_snapshot()), 5,
		"bad debt: C's 5 COIN fee is the only collected fee")
	_eq_int(_bank_identity(farm), 0,
		"bad debt: bank.cash == capital - outstanding + fees")

	var refused_snapshot: Dictionary = farm.snapshot()
	var no_cash: Dictionary = farm.economy_borrow_loan("loan-e", PLAYER_E, 10, TERM, START + DAY)
	_expect_refused(no_cash, "bank_insufficient", farm, refused_snapshot,
		"bad debt: a 10 COIN loan is refused when the bank holds 5")

	var default_time: float = START + DAY + TERM
	var settled: Dictionary = farm.economy_settle_loans(default_time)
	_expect_ok(settled, "bad debt: the term sweep runs")
	_eq_int(int(settled.get("count", -1)), 3, "bad debt: A, B and D become overdue")
	for loan_id: String in ["loan-a", "loan-b", "loan-d"]:
		_expect(str(farm.economy_loan(loan_id).status) == Loans.STATUS_OVERDUE,
			"bad debt: %s is overdue, got %s" % [loan_id, str(farm.economy_loan(loan_id).status)])
		_eq_int(int(farm.economy_loan(loan_id).paid), 0, "bad debt: %s paid nothing" % loan_id)
	_expect(str(farm.economy_loan("loan-c").status) == Loans.STATUS_REPAID,
		"bad debt: C stays repaid")
	_eq_int(farm.economy_issued(), issued_before, "bad debt: overdue issues no money")
	_eq_int(farm.economy_total_cash(), total_before, "bad debt: overdue destroys no money")
	_eq_int(farm.economy_bank().cash, 5, "bad debt: overdue leaves the bank cash at 5")
	_eq_int(Loans.outstanding_principal(farm.economy_snapshot()), 2000,
		"bad debt: overdue principal is still 2000")
	_eq_int(Loans.collected_fees(farm.economy_snapshot()), 5,
		"bad debt: overdue adds no fee")
	_eq_int(_bank_identity(farm), 0,
		"bad debt: after default bank.cash == capital - outstanding + fees")
	_eq_int(_cash_holders_total(farm), farm.economy_issued(),
		"bad debt: accounts + bank + merchant + escrow equals issued")

	var after_default: Dictionary = farm.snapshot()
	var refused_again: Dictionary = farm.economy_borrow_loan("loan-e2", PLAYER_E, 10, TERM,
		default_time)
	_expect_refused(refused_again, "bank_insufficient", farm, after_default,
		"bad debt: a defaulted bank still refuses an unaffordable loan")
	_eq_int(farm.economy_cash(PLAYER_A), 1120, "bad debt: A keeps its 1120")
	_eq_int(farm.economy_cash(PLAYER_B), 1020, "bad debt: B keeps its 1020")
	_eq_int(farm.economy_cash(PLAYER_C), 115, "bad debt: C keeps 115 after repayment")
	_eq_int(farm.economy_cash(PLAYER_D), 220, "bad debt: D keeps its 220")
	_eq_int(farm.economy_cash(PLAYER_E), 120, "bad debt: E keeps its untouched grant")
	_expect_economy_valid(farm, "bad debt after three defaults")
	_row(("SCENARIO bad_debt issued=%d total_cash=%d bank=%d outstanding=%d fees=%d "
		+ "overdue=3 refused=bank_insufficient negative=no") % [
			farm.economy_issued(), farm.economy_total_cash(), farm.economy_bank().cash,
			2000, 5])


## 2. Concentrated withdrawal. One account escrows its whole cash and then the
## borrowed bank cash is fully lent out. Available balance never goes negative,
## an over-order and a further loan are refused, and both refusals leave the
## cash, escrow and snapshot untouched.
func _scenario_concentrated_withdrawal() -> void:
	var farm: Farm = _open_accounts([PLAYER_A, PLAYER_B, PLAYER_C])
	_expect_ok(farm.economy_open_bank("bank-open", START), "withdrawal: open bank")
	_expect_ok(farm.economy_borrow_loan("loan-a", PLAYER_A, 1000, TERM, START),
		"withdrawal: A borrows 1000")
	_expect_ok(farm.market_place_order("withdraw-buy-a", PLAYER_A, "buy", "greens", 10, 112,
		START + 6.0 * HOUR, START), "withdrawal: A escrows all 1120 cash")
	_eq_int(farm.economy_cash(PLAYER_A), 0, "withdrawal: A available cash is 0")
	_eq_int(int(farm.economy_funds(PLAYER_A).frozen), 1120,
		"withdrawal: A has 1120 frozen in the buy order")
	_eq_int(int(farm.economy_funds(PLAYER_A).available), 0,
		"withdrawal: A available+frozen = 1120, available = 0")
	_eq_int(int(farm.economy_funds(PLAYER_A).total), 1120,
		"withdrawal: A total funds stay 1120")

	var before_over: Dictionary = farm.snapshot()
	var over: Dictionary = farm.market_place_order("withdraw-buy-a2", PLAYER_A, "buy",
		"greens", 1, 1, START + 6.0 * HOUR, START)
	_expect_refused(over, "insufficient_cash", farm, before_over,
		"withdrawal: a 1 COIN buy is refused after all cash is escrowed")
	_eq_int(farm.economy_cash(PLAYER_A), 0, "withdrawal: A cash stays 0 after refusal")
	_eq_int(int(farm.economy_funds(PLAYER_A).frozen), 1120,
		"withdrawal: A escrow stays 1120 after refusal")

	var before_loan: Dictionary = farm.snapshot()
	var active: Dictionary = farm.economy_borrow_loan("loan-a2", PLAYER_A, 10, TERM, START)
	_expect_refused(active, "loan_active", farm, before_loan,
		"withdrawal: A cannot borrow again while its loan is active")
	_eq_int(farm.economy_cash(PLAYER_A), 0, "withdrawal: refused loan leaves A cash 0")

	_expect_ok(farm.economy_borrow_loan("loan-b", PLAYER_B, 1000, TERM, START),
		"withdrawal: B takes the remaining bank cash")
	_eq_int(farm.economy_bank().cash, 0, "withdrawal: the bank is fully lent out")
	_expect_ok(farm.market_place_order("withdraw-buy-b", PLAYER_B, "buy", "greens", 10, 112,
		START + 6.0 * HOUR, START), "withdrawal: B escrows all 1120 cash")
	_eq_int(farm.economy_cash(PLAYER_B), 0, "withdrawal: B available cash is 0")
	_eq_int(int(farm.economy_funds(PLAYER_B).frozen), 1120,
		"withdrawal: B has 1120 frozen")
	var before_bank: Dictionary = farm.snapshot()
	var no_bank_cash: Dictionary = farm.economy_borrow_loan("loan-c", PLAYER_C, 10, TERM, START)
	_expect_refused(no_bank_cash, "bank_insufficient", farm, before_bank,
		"withdrawal: C cannot borrow from an empty bank")
	_eq_int(farm.economy_cash(PLAYER_C), 120, "withdrawal: refused C keeps its 120")
	_eq_int(_cash_holders_total(farm), farm.economy_issued(),
		"withdrawal: accounts + escrow + bank + merchant equals issued")
	_eq_int(farm.economy_total_cash(), 2360,
		"withdrawal: 360 grants + 2000 capital stay conserved")
	for owner: String in [PLAYER_A, PLAYER_B, PLAYER_C]:
		_expect(farm.economy_cash(owner) >= 0,
			"withdrawal: %s cash is not negative" % owner)

	_expect_ok(farm.market_cancel_order("withdraw-cancel-a", PLAYER_A, "withdraw-buy-a", START),
		"withdrawal: A cancels and releases its escrow")
	_eq_int(farm.economy_cash(PLAYER_A), 1120, "withdrawal: A gets its 1120 back")
	_eq_int(int(farm.economy_funds(PLAYER_A).frozen), 0,
		"withdrawal: A has no remaining escrow")
	_eq_int(farm.economy_total_cash(), 2360, "withdrawal: cancel issues or burns nothing")
	_expect_economy_valid(farm, "concentrated withdrawal")
	_row("SCENARIO concentrated_withdrawal issued=2360 total_cash=2360 bank=0 " \
		+ "a_cash=0 a_frozen=1120 over_order=insufficient_cash over_loan=loan_active " \
		+ "negative=no")


## 3. Poor harvest and merchant liquidity. A sell above the bag is refused; the
## merchant's greens inventory is sold out and its rolling ask stops; a player
## sale restores it. The merchant then spends its cash on rolling bids until it
## can no longer fund one, and a player purchase restores the bid.
func _scenario_poor_harvest() -> void:
	# 3a. Selling more than the bag holds changes nothing.
	var small: Farm = _open_accounts([PLAYER_A])
	_eq_int(_grow_named(small, "field_01", 1, 2, "greens", PLAYER_A, START), 2,
		"poor harvest: two greens grow")
	var small_before: Dictionary = small.snapshot()
	var over_sell: Dictionary = small.market_place_order("poor-over-sell", PLAYER_A, "sell",
		"greens", 10, 3, START + 6.0 * HOUR, START)
	_expect_refused(over_sell, "insufficient_goods", small, small_before,
		"poor harvest: selling 3 of 2 greens is refused")
	_eq_int(small.economy_cash(PLAYER_A), 120, "poor harvest: refused sell keeps cash")
	_eq_int(_goods_total(small, "greens"), 2, "poor harvest: refused sell keeps both greens")
	_expect_ok(small.market_place_order("poor-sell-ok", PLAYER_A, "sell", "greens", 10, 2,
		START + 6.0 * HOUR, START), "poor harvest: a sell within the bag is accepted")
	_eq_int(_goods_total(small, "greens"), 2, "poor harvest: escrow keeps goods conserved")
	_expect_ok(small.market_cancel_order("poor-cancel", PLAYER_A, "poor-sell-ok", START),
		"poor harvest: the sell is cancelled")
	_eq_int(_bag_amount(small, PLAYER_A, "greens"), 2, "poor harvest: both greens return")

	# 3b. Merchant inventory exhaustion and recovery.
	var farm: Farm = _open_accounts([PLAYER_A, PLAYER_B, PLAYER_C])
	_expect_ok(farm.market_open_merchant("merchant-open", START), "poor harvest: open merchant")
	var granted: int = int(Market.merchant_granted(farm.economy_snapshot()).get("greens", 0))
	_eq_int(granted, 20, "poor harvest: the merchant is granted 20 greens")
	_eq_int(int(farm.market_merchant().cash), 260, "poor harvest: merchant spends 340 on bids")
	for index: int in 4:
		_expect_ok(farm.market_place_order("poor-buy-a-%d" % index, PLAYER_A, "buy",
			"greens", 7, 4, START + 6.0 * HOUR, START),
			"poor harvest: A buys four merchant greens")
		_expect_ok(farm.market_match(START), "poor harvest: A's buy matches")
		_eq_int(int(farm.market_merchant().goods.greens), 16 - 4 * index,
			"poor harvest: merchant free stock after A's buy %d" % index)
	_expect_ok(farm.market_place_order("poor-buy-b", PLAYER_B, "buy", "greens", 7, 4,
		START + 6.0 * HOUR, START), "poor harvest: B buys the last four merchant greens")
	_expect_ok(farm.market_match(START), "poor harvest: B's buy matches")
	_eq_int(int(farm.market_merchant().goods.greens), 0,
		"poor harvest: the merchant has no free greens")
	_eq_int(int(farm.market_quote("greens").sell_capacity), 0,
		"poor harvest: the merchant ask stops at zero stock")
	_expect(str(farm.market_order(Market.merchant_quote_id("greens", "sell")).status)
		== Market.STATUS_FILLED, "poor harvest: the greens ask row is filled, not reopened")
	var before_empty_match: Dictionary = farm.snapshot()
	var empty_match: Dictionary = farm.market_match(START)
	_expect_ok(empty_match, "poor harvest: the empty-stock sweep runs")
	_eq_int(int(empty_match.get("count", -1)), 0,
		"poor harvest: no trade is invented from empty stock")
	_eq_int(_bag_amount(farm, PLAYER_A, "greens"), 16, "poor harvest: A holds 16 greens")
	_eq_int(_bag_amount(farm, PLAYER_B, "greens"), 4, "poor harvest: B holds 4 greens")
	_eq_int(int(farm.market_merchant().cash), 395,
		"poor harvest: five merchant sells add 27 each")

	# 3c. A player sells back four greens; the ask reopens from the returned stock.
	_expect_ok(farm.market_place_order("poor-sell-back", PLAYER_A, "sell", "greens", 5, 4,
		START + 6.0 * HOUR, START), "poor harvest: A sells four greens back")
	_expect_ok(farm.market_match(START), "poor harvest: the sell-back fills")
	_eq_int(int(farm.market_merchant().goods.greens), 4,
		"poor harvest: the merchant receives four free greens")
	_expect(str(farm.market_order(Market.merchant_quote_id("greens", "sell")).status)
		== Market.STATUS_FILLED, "poor harvest: the filled ask has not refreshed yet")
	_expect_ok(farm.market_match(START), "poor harvest: the rolling sweep refreshes the ask")
	_expect(str(farm.market_order(Market.merchant_quote_id("greens", "sell")).status)
		== Market.STATUS_OPEN, "poor harvest: the ask reopens")
	_eq_int(int(farm.market_quote("greens").sell_capacity), 0,
		"poor harvest: the reopened ask reserves all four free greens")
	_eq_int(int(farm.market_merchant().goods.greens), 0,
		"poor harvest: the reopened ask reserves the returned stock")

	# 3d. Merchant cash exhaustion. Each successful buy by the merchant reopens a
	# 20 COIN bid from cash, so 19 cycles leave 15 COIN and no affordable bid.
	var grown: int = 0
	for index: int in 19:
		grown += _grow_named(farm, "field_01", 1, 4, "greens", PLAYER_A, START)
		_expect_ok(farm.market_place_order("poor-drain-%02d" % index, PLAYER_A, "sell",
			"greens", 5, 4, START + 6.0 * HOUR, START),
			"poor harvest: drain sell %d is accepted" % index)
		_expect_ok(farm.market_match(START), "poor harvest: drain sell %d fills" % index)
	_eq_int(grown, 76, "poor harvest: nineteen cycles grow 76 greens")
	_eq_int(int(farm.market_merchant().cash), 15,
		"poor harvest: the merchant is left with 15 COIN")
	_eq_int(int(farm.market_quote("greens").buy_capacity), 3,
		"poor harvest: the bid capacity falls to three units")
	_expect(str(farm.market_order(Market.merchant_quote_id("greens", "buy")).status)
		== Market.STATUS_FILLED, "poor harvest: the cash-starved bid stays filled")
	var starved_snapshot: Dictionary = farm.snapshot()
	var starved_match: Dictionary = farm.market_match(START)
	_expect_ok(starved_match, "poor harvest: the cash-starved sweep runs")
	_eq_int(int(starved_match.get("count", -1)), 0,
		"poor harvest: no bid is reopened without 20 COIN")
	_expect(farm.snapshot() == starved_snapshot,
		"poor harvest: the starved sweep changes nothing")

	# 3e. Cash recovery via the ask restores the bid.
	_expect_ok(farm.market_place_order("poor-recover-buy", PLAYER_C, "buy", "greens", 7, 4,
		START + 6.0 * HOUR, START), "poor harvest: C buys four greens from the ask")
	_expect_ok(farm.market_match(START), "poor harvest: C's purchase fills")
	_eq_int(int(farm.market_merchant().cash), 42,
		"poor harvest: the merchant receives 27 from the ask")
	_expect_ok(farm.market_match(START), "poor harvest: the rolling sweep refreshes the bid")
	_eq_int(int(farm.market_quote("greens").buy_capacity), 4,
		"poor harvest: the bid reopens with four units")
	_eq_int(int(farm.market_merchant().cash), 22,
		"poor harvest: reopening spends 20 of the recovered cash")

	_eq_int(int(farm.market_orders().size()), _count_trades(farm) + 12,
		"poor harvest: twelve rolling quote rows plus one row per trade")
	_eq_int(_count_trades(farm), 26, "poor harvest: 5 + 1 + 19 + 1 = 26 filled trades")
	_eq_int(_fees(farm), 26, "poor harvest: every fill burns exactly one COIN")
	_eq_int(farm.economy_total_cash(), farm.economy_issued(),
		"poor harvest: total cash equals issued")
	_eq_int(farm.economy_issued(), 934,
		"poor harvest: 960 issued minus 26 burned fees")
	_eq_int(_goods_total(farm, "greens"), granted + grown,
		"poor harvest: granted 20 + grown 76 = bag + merchant + escrow")
	_eq_int(_goods_total(farm, "greens"), 96,
		"poor harvest: 96 greens are still accounted for")
	_eq_int(_bag_amount(farm, PLAYER_A, "greens"), 12, "poor harvest: A ends with 12 greens")
	_eq_int(_bag_amount(farm, PLAYER_B, "greens"), 4, "poor harvest: B ends with 4 greens")
	_eq_int(_bag_amount(farm, PLAYER_C, "greens"), 4, "poor harvest: C ends with 4 greens")
	_eq_int(int(farm.market_merchant().goods.greens), 72,
		"poor harvest: the merchant holds 72 free greens")
	_eq_int(int(farm.market_order(Market.merchant_quote_id("greens", "sell")).reserved), 4,
		"poor harvest: the ask holds four greens in escrow")
	_expect_economy_valid(farm, "poor harvest with merchant exhaustion")
	_row("SCENARIO poor_harvest granted=20 grown=76 goods_total=96 trades=26 fees=26 " \
		+ "issued=934 total_cash=934 merchant_cash=22 ask_capacity=72 bid_capacity=4 " \
		+ "negative=no")


## 4. A 60-day offline window. The same base state is advanced once and once
## per day. Loan overdue, order expiry, shipment delivery and rolling merchant
## quote refresh all land in the same economic state. The projection below
## intentionally drops observation-time fields (`closed_utc`, `delivered_utc`,
## delivery `at_utc`, rolling quote rows and the live journal window), because
## the authority records the sweep instant rather than the due instant; that
## difference is asserted explicitly and recorded as a boundary finding.
func _scenario_long_offline() -> void:
	var base: Farm = _open_accounts([PLAYER_A, PLAYER_B])
	_expect_ok(base.economy_open_bank("bank-open", START), "offline: open bank")
	_expect_ok(base.economy_borrow_loan("loan-offline", PLAYER_A, 50, TERM, START),
		"offline: A borrows 50 for seven days")
	_expect_ok(base.market_open_merchant("merchant-open", START), "offline: open merchant")
	_eq_int(_grow_named(base, "field_02", 1, 8, "greens", PLAYER_B, START), 8,
		"offline: B grows eight greens")
	_expect_ok(base.market_place_order("offline-sell", PLAYER_B, "sell", "greens", 10, 2,
		START + 2.0 * DAY, START), "offline: B rests a sell expiring on day 2")
	_expect_ok(base.market_place_order("offline-buy", PLAYER_A, "buy", "greens", 4, 2,
		START + 3.0 * DAY, START), "offline: A rests a buy below the merchant bid, expiring on day 3")
	_expect_ok(base.market_ship("offline-ship", PLAYER_B, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 3, START), "offline: B ships three greens")

	var source: Dictionary = base.snapshot()
	var once := Farm.new()
	var daily := Farm.new()
	_expect(once.restore_snapshot(source), "offline: the one-shot candidate restores")
	_expect(daily.restore_snapshot(source), "offline: the daily candidate restores")

	var target: float = START + 60.0 * DAY
	_expect_ok(once.settle(target), "offline: one-shot crop settlement")
	_run_sweeps(once, target)
	for day: int in range(1, 61):
		var now: float = START + float(day) * DAY
		_expect_ok(daily.settle(now), "offline: day %d crop settlement" % day)
		_run_sweeps(daily, now)

	for label: String in ["one-shot", "daily"]:
		var farm: Farm = once if label == "one-shot" else daily
		_expect(str(farm.economy_loan("loan-offline").status) == Loans.STATUS_OVERDUE,
			"offline %s: the 7-day loan is overdue, got %s" % [
				label, str(farm.economy_loan("loan-offline").status)])
		_eq_int(int(farm.economy_loan("loan-offline").paid), 0,
			"offline %s: the overdue loan paid nothing" % label)
		_expect(str(farm.market_order("offline-sell").status) == Market.STATUS_EXPIRED,
			"offline %s: the day-2 sell expired" % label)
		_expect(str(farm.market_order("offline-buy").status) == Market.STATUS_EXPIRED,
			"offline %s: the day-3 buy expired" % label)
		_eq_int(farm.market_shipments().size(), 1, "offline %s: one shipment" % label)
		_eq_int(farm.market_deliveries().size(), 1, "offline %s: one delivery event" % label)
		_expect(str(farm.market_shipment("offline-ship").status) == Market.SHIPMENT_STATUS_DELIVERED,
			"offline %s: the shipment is delivered" % label)
		_expect(str(farm.market_shipment("offline-ship").delivery_id)
			== str(farm.market_deliveries()[0].id),
			"offline %s: the shipment links to its one delivery" % label)
		_eq_int(_bag_amount(farm, PLAYER_B, "greens"), 8,
			"offline %s: B ends with eight greens (2 expired sell + 3 delivered + 3 held)" % label)
		_eq_int(int(farm.economy_funds(PLAYER_A).available), 170,
			"offline %s: A's expired buy returns all 18 COIN" % label)
		_expect(farm.market_quote("greens").has("bid"),
			"offline %s: the rolling quote is present" % label)
		_eq_int(farm.economy_total_cash(), farm.economy_issued(),
			"offline %s: total cash equals issued" % label)
		for owner: String in [PLAYER_A, PLAYER_B]:
			_expect(farm.economy_cash(owner) >= 0,
				"offline %s: %s cash is not negative" % [label, owner])
		_expect(farm.economy_bank().cash >= 0, "offline %s: bank cash is not negative" % label)
		_expect(int(farm.market_merchant().cash) >= 0,
			"offline %s: merchant cash is not negative" % label)
		_expect_economy_valid(farm, "offline " + label)

	# Observation time is the sweep instant, not the due instant. This is the
	# readable replay boundary behind the projection, not an economic mismatch.
	_eq_float(float(once.market_order("offline-sell").closed_utc), target,
		"offline: the one-shot expiry is stamped at the sweep time")
	_eq_float(float(daily.market_order("offline-sell").closed_utc), START + 2.0 * DAY,
		"offline: the daily expiry is stamped on day 2")
	_eq_float(float(once.market_deliveries()[0].at_utc), target,
		"offline: the one-shot delivery is stamped at the sweep time")
	_eq_float(float(daily.market_deliveries()[0].at_utc), START + DAY,
		"offline: the daily delivery is stamped on day 1")
	_expect(once.snapshot() != daily.snapshot(),
		"offline: raw snapshots differ only through observation-time bookkeeping")

	var once_projection: Dictionary = _economic_projection(once)
	var daily_projection: Dictionary = _economic_projection(daily)
	_expect(once_projection == daily_projection,
		"offline: the one-shot and daily economic projections are identical")
	_eq_int(Economy.issued(daily_projection.economy),
		Economy.issued(once_projection.economy),
		"offline: both paths issue the same amount")
	_eq_int(Economy.total_cash(daily_projection.economy),
		Economy.total_cash(once_projection.economy),
		"offline: both paths hold the same total cash")
	_eq_int(int(once_projection.economy.accounts[PLAYER_A].cash),
		int(daily_projection.economy.accounts[PLAYER_A].cash),
		"offline: A ends with the same cash in both paths")
	_eq_int(int(once_projection.economy.accounts[PLAYER_B].cash),
		int(daily_projection.economy.accounts[PLAYER_B].cash),
		"offline: B ends with the same cash in both paths")
	_eq_int(int(once_projection.economy.bank.cash),
		int(daily_projection.economy.bank.cash),
		"offline: the bank ends with the same cash in both paths")

	# Repeating the terminal sweeps is a no-op: no second delivery, expiry,
	# overdue transition or payout.
	for farm: Farm in [once, daily]:
		var settled: Dictionary = farm.snapshot()
		var issued_before_repeat: int = farm.economy_issued()
		_eq_int(int(farm.market_expire(target).get("expired", -1)), 0,
			"offline repeat: expiry finds no due order")
		_eq_int(int(farm.market_match(target).get("count", -1)), 0,
			"offline repeat: matching fills nothing")
		_eq_int(int(farm.market_deliver(target).get("count", -1)), 0,
			"offline repeat: delivery finds no in-transit shipment")
		_eq_int(int(farm.economy_settle_loans(target).get("count", -1)), 0,
			"offline repeat: no second overdue transition")
		_expect(farm.snapshot() == settled,
			"offline repeat: the repeated terminal sweeps change nothing")
		_eq_int(farm.market_deliveries().size(), 1,
			"offline repeat: exactly one delivery event remains")
		_eq_int(farm.economy_issued(), issued_before_repeat,
			"offline repeat: repeated sweeps issue no cash")
	_row("SCENARIO long_offline days=60 loan=overdue orders=expired delivered=1 " \
		+ "delivery_events=1 once_daily_projection_equal=yes raw_snapshot_equal=no " \
		+ "observation_time_gap=expiry/delivery stamps use sweep time duplicate_work=no")


## 5. Refusing finance. No bank, no account and no order: sowing, harvesting
## and the kitchen still work, and the economy document remains uninitialized.
func _scenario_no_finance() -> void:
	var farm := Farm.new(START)
	_expect_ok(farm.sow("field_01", "cell_01", "greens", START, ""),
		"no finance: anonymous sowing works")
	_expect_ok(farm.mature_all_crops(START), "no finance: crops mature without cash")
	_expect_ok(farm.harvest("field_01", "cell_01", START, ""),
		"no finance: anonymous harvest fills the kitchen")
	_eq_int(int(farm.pantry().get("greens", 0)), 1,
		"no finance: the kitchen has one green")
	var revision: int = int(farm.snapshot().kitchen.revision)
	_expect_ok(farm.kitchen_action("start", {"recipe": "leaf_stir", "crop": "greens"},
		revision, START), "no finance: cooking starts without cash")
	revision = int(farm.snapshot().kitchen.revision)
	_expect_ok(farm.kitchen_action("collect", {"station": "stove"}, revision,
		START + 20.0), "no finance: the meal completes on its clock")
	_eq_int(int(farm.snapshot().kitchen.stock.leaf_stir), 1,
		"no finance: one meal is cooked")
	_eq_int(int(farm.snapshot().inventory.greens), 0,
		"no finance: the meal consumed the green")

	var economy: Dictionary = farm.economy_snapshot()
	_eq_int(int(economy.issued), 0, "no finance: nothing is issued")
	_eq_int(farm.economy_total_cash(), 0, "no finance: no cash exists")
	_expect(economy.accounts.is_empty(), "no finance: no account was opened")
	_expect(economy.conversion.is_empty(), "no finance: no conversion was recorded")
	_expect(not bool(economy.bank.opened), "no finance: the bank stays closed")
	_expect(economy.loans.is_empty(), "no finance: no loan exists")
	_expect(economy.market.orders.is_empty(), "no finance: no order exists")
	_expect(not bool(economy.market.merchant.opened), "no finance: the merchant stays closed")
	_expect(Economy.valid(economy), "no finance: the untouched economy document is valid")
	_eq_int(int(farm.economy_settle_loans(START + DAY).get("count", -1)), 0,
		"no finance: the loan sweep has no work")
	_eq_int(int(farm.market_match(START).get("count", -1)), 0,
		"no finance: the market sweep has no work")
	_row("SCENARIO no_finance issued=0 total_cash=0 accounts=0 bank=closed loans=0 " \
		+ "orders=0 meal=1 harvest=1")


## 6. Payout peak boundary. Insurance is not implemented. An overdue bank book
## has no automatic compensation: the only journal kinds are the existing ten
## business events, the loan rows have no claim field, and a 60-day default
## changes only the contract status. This is a boundary confirmation, not a
## passing insurance feature.
func _scenario_no_payout() -> void:
	var farm: Farm = _open_accounts([PLAYER_A, PLAYER_B])
	_expect_ok(farm.economy_open_bank("bank-open", START), "no payout: open bank")
	_expect_ok(farm.economy_borrow_loan("stress-loan-a", PLAYER_A, 1000, TERM, START),
		"no payout: A borrows 1000")
	_expect_ok(farm.economy_borrow_loan("stress-loan-b", PLAYER_B, 900, TERM, START),
		"no payout: B borrows 900")
	var before: Dictionary = farm.economy_snapshot()
	var entries_before: int = Economy.ledger_entries(before).size()
	_eq_int(entries_before, 5, "no payout: five business entries before default")
	_expect_ok(farm.economy_settle_loans(START + 60.0 * DAY),
		"no payout: the 60-day default sweep runs")
	var after: Dictionary = farm.economy_snapshot()
	_eq_int(Economy.ledger_entries(after).size(), entries_before,
		"no payout: default writes no new journal entry")
	_eq_int(Economy.issued(after), Economy.issued(before),
		"no payout: default issues no compensation")
	_eq_int(Economy.total_cash(after), Economy.total_cash(before),
		"no payout: default creates no cash")
	_eq_int(Economy.cash(after, PLAYER_A), Economy.cash(before, PLAYER_A),
		"no payout: A receives no compensation")
	_eq_int(Economy.cash(after, PLAYER_B), Economy.cash(before, PLAYER_B),
		"no payout: B receives no compensation")
	_eq_int(Economy.bank_cash(after), Economy.bank_cash(before),
		"no payout: the bank pays no claim")
	var status_only: Dictionary = after.duplicate(true)
	for loan_id: Variant in status_only.loans:
		status_only.loans[loan_id].status = Loans.STATUS_OPEN
	_expect(status_only == before,
		"no payout: default changes only the contract status, nothing else")
	_expect(bool(after.bank.opened), "no payout: the bank row is still the only cash holder")
	_expect(not after.has("insurance"), "no payout: the economy has no insurance subdocument")
	_expect(not after.has("claims"), "no payout: the economy has no claims subdocument")
	for loan_id: Variant in after.loans:
		var contract: Dictionary = after.loans[loan_id]
		_eq_int(contract.size(), Loans.CONTRACT_KEYS.size(),
			"no payout: contract %s has exactly the business fields" % str(loan_id))
		for key: String in Loans.CONTRACT_KEYS:
			_expect(contract.has(key),
				"no payout: contract %s has no payout field beyond %s" % [str(loan_id), key])
	_eq_int(after.size(), Economy.STATE_KEYS.size(),
		"no payout: the economy document has exactly its known top-level keys")
	for key: String in Economy.STATE_KEYS:
		_expect(after.has(key), "no payout: the known economy key %s is present" % key)
	for entry: Dictionary in Economy.ledger_entries(after):
		_expect(str(entry.kind) in Ledger.KINDS,
			"no payout: journal kind %s is a known business event" % str(entry.kind))
		_expect(_no_payout_text(str(entry.kind)) and _no_payout_text(str(entry.event_id)),
			"no payout: journal entry %s is not an insurance/compensation event" % str(entry.id))
		_expect(_balanced(entry),
			"no payout: journal entry %s stays balanced" % str(entry.id))
		for line: Dictionary in entry.lines:
			_expect(Ledger.valid_account_code(str(line.account)),
				"no payout: entry %s has only known accounts" % str(entry.id))
	var statement: Dictionary = Economy.reserve_statement(after)
	_expect(bool(statement.ok), "no payout: the reserve statement reconciles")
	_eq_int(int(statement.claims), 0, "no payout: the claim side is still zero")
	_expect(bool(statement.covered), "no payout: reserves cover the zero claim side")
	_expect_economy_valid(farm, "a 60-day default with no insurance")
	_row("SCENARIO no_payout insurance=absent claims=0 payout_entries=0 " \
		+ "new_entries_on_default=0 issued_delta=0 cash_delta=0 status_only=yes")


# --- fixtures and assertions -------------------------------------------------

func _open_accounts(owners: Array) -> Farm:
	var farm := Farm.new(START)
	for owner: String in owners:
		var result: Dictionary = farm.economy_open_account("open-" + owner, owner, START)
		_expect_ok(result, "open account " + owner)
	return farm


func _grow_named(farm: Farm, field_id: String, first_cell: int, last_cell: int,
		crop_id: String, actor: String, now: float) -> int:
	var cells: Array[String] = []
	for index: int in range(first_cell, last_cell + 1):
		cells.append("cell_%02d" % index)
	for cell_id: String in cells:
		_expect_ok(farm.sow(field_id, cell_id, crop_id, now, actor),
			"sow %s/%s" % [field_id, cell_id])
	_expect_ok(farm.mature_all_crops(now), "mature crops at %.0f" % now)
	var produced: int = 0
	for cell_id: String in cells:
		var harvested: Dictionary = farm.harvest(field_id, cell_id, now, actor)
		_expect_ok(harvested, "harvest %s/%s" % [field_id, cell_id])
		if bool(harvested.ok):
			produced += 1
	return produced


func _run_sweeps(farm: Farm, now: float) -> void:
	_expect_ok(farm.market_expire(now), "expiry sweep at %.0f" % now)
	_expect_ok(farm.market_match(now), "matching sweep at %.0f" % now)
	_expect_ok(farm.market_deliver(now), "delivery sweep at %.0f" % now)
	_expect_ok(farm.economy_settle_loans(now), "loan sweep at %.0f" % now)


## Drops sweep-observation fields and rolling quote rows so the one-shot and
## day-by-day runs can be compared for economic equality. Business rows,
## balances, contracts, goods and crops remain.
func _economic_projection(farm: Farm) -> Dictionary:
	var state: Dictionary = farm.snapshot()
	var ledger: Dictionary = state.economy.ledger
	state.economy.ledger = {"balances": ledger.balances.duplicate(true)}
	var market: Dictionary = state.economy.market
	var player_orders: Dictionary = {}
	for order_id: Variant in market.orders:
		var id: String = str(order_id)
		if id.begins_with(Market.MERCHANT_BID_PREFIX) \
				or id.begins_with(Market.MERCHANT_ASK_PREFIX):
			continue
		var order: Dictionary = market.orders[order_id].duplicate(true)
		order.closed_utc = 0.0
		player_orders[id] = order
	market.orders = player_orders
	market.erase("sequence")
	market.trades = {}
	for shipment_id: Variant in market.shipments:
		market.shipments[shipment_id].delivered_utc = 0.0
	for delivery_id: Variant in market.deliveries:
		market.deliveries[delivery_id].at_utc = 0.0
	return state


func _bank_identity(farm: Farm) -> int:
	var economy: Dictionary = farm.economy_snapshot()
	return Economy.bank_cash(economy) \
		- (Economy.BANK_CAPITAL - Loans.outstanding_principal(economy) \
			+ Loans.collected_fees(economy))


func _cash_holders_total(farm: Farm) -> int:
	return farm.economy_total_cash()


func _fees(farm: Farm) -> int:
	var total: int = 0
	for trade: Dictionary in farm.market_trades():
		total += int(trade.fee)
	return total


func _count_trades(farm: Farm) -> int:
	return farm.market_trades().size()


func _bag_amount(farm: Farm, owner: String, good_id: String) -> int:
	return int(farm.bag(owner).get(good_id, 0))


## bags + merchant stock + open sell escrow + in-transit. Buy escrow is cash,
## not goods, and completed trades already moved their baskets into a bag.
func _goods_total(farm: Farm, good_id: String) -> int:
	var total: int = _bag_amount(farm, PLAYER_A, good_id) \
		+ _bag_amount(farm, PLAYER_B, good_id) + _bag_amount(farm, PLAYER_C, good_id)
	var merchant: Dictionary = farm.market_merchant()
	if merchant.get("goods") is Dictionary:
		total += int(merchant.goods.get(good_id, 0))
	for order: Dictionary in farm.market_orders():
		if str(order.side) == "sell" and str(order.good) == good_id \
				and str(order.status) == Market.STATUS_OPEN:
			total += int(order.reserved)
	for shipment: Dictionary in farm.market_shipments():
		if str(shipment.status) == Market.SHIPMENT_STATUS_TRANSIT \
				and str(shipment.good) == good_id:
			total += int(shipment.quantity)
	return total


func _no_payout_text(value: String) -> bool:
	for token: String in ["insurance", "insur", "claim", "payout", "compensat", "subsid"]:
		if value.find(token) >= 0:
			return false
	return true


func _balanced(entry: Dictionary) -> bool:
	var debit: int = 0
	var credit: int = 0
	for raw_line: Dictionary in entry.lines:
		debit += int(raw_line.debit)
		credit += int(raw_line.credit)
	return debit == credit and debit == int(entry.debit) \
		and credit == int(entry.credit) and debit > 0


func _expect_economy_valid(farm: Farm, label: String) -> void:
	var economy: Dictionary = farm.economy_snapshot()
	_expect(Economy.valid(economy), "%s: expected a valid economy, got invalid" % label)
	_expect(bool(Economy.reconcile(economy).ok),
		"%s: expected the ledger to reconcile, got %s" % [
			label, str(Economy.reconcile(economy).reason)])
	_eq_int(Economy.total_cash(economy), Economy.issued(economy),
		"%s: total cash must equal issued" % label)
	_expect(Economy.issued(economy) >= 0, "%s: issued is nonnegative" % label)
	_expect(Loans.valid(economy.get("loans", {})),
		"%s: every contract is valid" % label)


func _expect_ok(result: Dictionary, label: String) -> void:
	_expect(bool(result.get("ok", false)),
		"%s: expected ok, got reason=%s" % [label, str(result.get("reason", ""))])


func _expect_refused(result: Dictionary, reason: String, farm: Farm,
		snapshot_before: Dictionary, label: String) -> void:
	_expect(not bool(result.get("ok", true)) and str(result.get("reason", "")) == reason,
		"%s: expected reason=%s, got ok=%s reason=%s" % [
			label, reason, str(result.get("ok", true)), str(result.get("reason", ""))])
	_expect(farm.snapshot() == snapshot_before,
		"%s: expected the rejected command to change nothing, actual snapshot differs" % label)


func _eq_int(actual: int, expected: int, label: String) -> void:
	_expect(actual == expected, "%s: expected %d, got %d" % [label, expected, actual])


func _eq_float(actual: float, expected: float, label: String) -> void:
	_expect(actual == expected, "%s: expected %.6f, got %.6f" % [label, expected, actual])


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _row(line: String) -> void:
	print(line)
