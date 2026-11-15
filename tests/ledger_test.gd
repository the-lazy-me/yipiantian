extends SceneTree
## M8-01 double-entry ledger: every cash event posts a balanced journal entry,
## the journal reconciles with the existing cash authorities, replay never posts
## twice, a restart preserves the journal and a pre-ledger document adopts an
## opening checkpoint. Headless, isolated; no clock, scene or player save.

const Farm = preload("res://farm/farm_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const Market = preload("res://farm/market_state.gd")
const Ledger = preload("res://farm/ledger_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")

const START: float = 1800000000.0
const ARRIVE: float = START + Market.DELIVERY_SECONDS
const HOUR: float = 3600.0
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/ledger-%d" % OS.get_process_id()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_initial_state()
	_test_opening_and_transfer()
	_test_escrow_and_funds()
	_test_merchant_budget_and_trade()
	_test_shipping_fee()
	_test_duplicate_commands()
	_test_persistence_and_legacy_adoption()
	_test_invalid_entries()
	_test_eviction_keeps_checkpoint()
	for failure: String in failures:
		push_error(failure)
	print("LEDGER_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_initial_state() -> void:
	var farm := Farm.new(START)
	var ledger: Dictionary = farm.economy_ledger()
	_expect(ledger.sequence == 0 and ledger.entries.is_empty() and ledger.balances.is_empty(),
		"A new farm starts with an empty journal and no checkpoint")
	_expect(Ledger.valid(ledger), "The empty journal is valid")
	_expect(farm.economy_ledger_entries().is_empty(), "No entries exist before the first cash event")
	_expect(farm.economy_reconcile().ok, "An empty economy reconciles")
	var statement: Dictionary = farm.economy_reserve_statement()
	_expect(statement.ok and statement.total_cash == 0 and statement.issued == 0
		and statement.claims == 0 and statement.covered,
		"An empty reserve statement holds nothing and covers no claims")
	var funds: Dictionary = farm.economy_funds(PLAYER_A)
	_expect(funds.available == 0 and funds.frozen == 0 and funds.total == 0,
		"An unopened account has no available or frozen cash")
	_expect(farm.economy_funds(Market.MERCHANT).available == 0,
		"The merchant starts with no cash but is a valid funds view")


func _test_opening_and_transfer() -> void:
	var farm := Farm.new(START)
	_expect(farm.economy_open_account("open-a", PLAYER_A, START).ok, "A receives the opening grant")
	_expect(farm.economy_open_account("open-b", PLAYER_B, START).ok, "B receives the opening grant")
	var entries: Array = farm.economy_ledger_entries()
	_expect(entries.size() == 2 and farm.economy_ledger().sequence == 2,
		"Each opening grant is one journal entry")
	_expect(entries[0].kind == Ledger.KIND_OPEN_ACCOUNT
		and _event(entries[0]) == "open-a" and _event(entries[1]) == "open-b",
		"Opening entries bind to their business command ids")
	_expect(_entry_balanced(entries[0]) and _entry_balanced(entries[1]),
		"Opening entries debit the account and credit issuance by the same grant")
	_expect(Ledger.balance(farm.economy_ledger(), Ledger.owner_code(PLAYER_A)) == 120
		and Ledger.balance(farm.economy_ledger(), Ledger.ISSUANCE) == -240,
		"The checkpoint mirrors account cash and the issuance equity")
	_expect_reconciled(farm, "two opening grants")

	_expect(farm.economy_pay("pay-1", PLAYER_A, PLAYER_B, 50, START).ok, "A transfers 50 to B")
	var pay_entry: Dictionary = _event_entry(farm, "pay-1")
	_expect(not pay_entry.is_empty() and pay_entry.kind == Ledger.KIND_PAY,
		"A payment records one durable pay entry")
	_expect(_entry_balanced(pay_entry), "The payment entry is balanced")
	_expect(_line(pay_entry, Ledger.owner_code(PLAYER_B)) == 50
		and _line(pay_entry, Ledger.owner_code(PLAYER_A)) == -50,
		"The receiver is debited and the payer credited for the same amount")
	_expect(farm.economy_cash(PLAYER_A) == 70 and farm.economy_cash(PLAYER_B) == 170,
		"The authoritative balances moved exactly once")
	_expect(farm.economy_issued() == 240 and farm.economy_total_cash() == 240,
		"A transfer leaves net issuance and total cash unchanged")
	_expect_reconciled(farm, "a transfer")

	var accepted: Dictionary = farm.snapshot()
	var replay: Dictionary = farm.economy_pay("pay-1", PLAYER_A, PLAYER_B, 50, START)
	_expect(replay.ok and replay.duplicate and farm.snapshot() == accepted,
		"A replayed payment returns its original result and posts no second entry")
	_expect(farm.economy_ledger_entries().size() == 3,
		"The replayed payment leaves the journal size unchanged")
	_expect(not farm.economy_pay("pay-1", PLAYER_A, PLAYER_B, 51, START).ok
		and farm.snapshot() == accepted,
		"A reused payment id with another amount is a conflict, not a second entry")


func _test_escrow_and_funds() -> void:
	var farm := Farm.new(START)
	farm.economy_open_account("open-a", PLAYER_A, START)
	_expect(farm.market_place_order("hold-a", PLAYER_A, "buy", "greens", 10, 1,
		START + HOUR, START).ok, "A places a 10-COIN buy order")
	var hold_entry: Dictionary = _event_entry(farm, "hold-a")
	_expect(hold_entry.kind == Ledger.KIND_ESCROW_HOLD and _entry_balanced(hold_entry),
		"Placing a buy order records a balanced escrow hold")
	_expect(_line(hold_entry, Ledger.ESCROW) == 10
		and _line(hold_entry, Ledger.owner_code(PLAYER_A)) == -10,
		"Escrow is debited while the payer account is credited")
	var funds: Dictionary = farm.economy_funds(PLAYER_A)
	_expect(funds.available == 110 and funds.frozen == 10 and funds.total == 120,
		"Available plus frozen cash equals the pre-order balance")
	_expect_reconciled(farm, "a buy-order hold")

	_expect(farm.market_cancel_order("cancel-hold", PLAYER_A, "hold-a", START + 1.0).ok,
		"A cancels the order before expiry")
	var release_entry: Dictionary = _event_entry(farm, "cancel-hold")
	_expect(release_entry.kind == Ledger.KIND_ESCROW_RELEASE and _entry_balanced(release_entry),
		"Cancelling records a balanced escrow release")
	_expect(_line(release_entry, Ledger.owner_code(PLAYER_A)) == 10
		and _line(release_entry, Ledger.ESCROW) == -10,
		"The release debits the account and credits escrow")
	_expect(farm.economy_cash(PLAYER_A) == 120
		and farm.economy_funds(PLAYER_A).frozen == 0,
		"The full escrow returns to the available balance")
	_expect_reconciled(farm, "a cancel release")

	_expect(farm.market_place_order("hold-expire", PLAYER_A, "buy", "greens", 10, 1,
		START + HOUR, START).ok, "A places a buy order that will expire")
	_expect(farm.market_expire(START + HOUR).expired == 1, "Expiry closes the open buy order")
	var expire_entry: Dictionary = _event_entry(farm, "expire_2")
	_expect(expire_entry.kind == Ledger.KIND_ESCROW_RELEASE and _entry_balanced(expire_entry),
		"Expiry releases the escrow with a balanced entry")
	_expect(farm.economy_funds(PLAYER_A).available == 120
		and farm.economy_funds(PLAYER_A).frozen == 0, "Expiry returns all escrow")
	_expect_reconciled(farm, "an expiry release")


func _test_merchant_budget_and_trade() -> void:
	var farm: Farm = _fixture()
	_expect(farm.market_open_merchant("merchant-budget", START).ok, "The merchant receives its budget")
	var budget_entry: Dictionary = _event_entry(farm, "merchant-budget")
	_expect(budget_entry.kind == Ledger.KIND_MERCHANT_BUDGET and _entry_balanced(budget_entry),
		"The merchant budget is one balanced issuance entry")
	_expect(_line(budget_entry, Ledger.MERCHANT) == 600
		and _line(budget_entry, Ledger.ISSUANCE) == -600,
		"The merchant cash is debited and issuance credited")
	_expect(farm.economy_issued() == 960 and farm.economy_total_cash() == 960,
		"Three grants plus the merchant budget equal net issuance")
	_expect_reconciled(farm, "the merchant budget")

	_expect(farm.market_place_order("sell-a", PLAYER_A, "sell", "greens", 10, 1,
		START + HOUR, START).ok, "A rests one green at 10")
	_expect(farm.market_place_order("buy-b", PLAYER_B, "buy", "greens", 10, 1,
		START + HOUR, START).ok, "B bids one green at 10")
	var trade: Dictionary = farm.market_match(START)
	_expect(trade.count == 1, "One fill settles the crossed orders")
	var trade_entry: Dictionary = _event_entry(farm, "trade_1")
	_expect(trade_entry.kind == Ledger.KIND_TRADE and _entry_balanced(trade_entry),
		"The settlement is one balanced trade entry")
	_expect(_line(trade_entry, Ledger.owner_code(PLAYER_A)) == 9
		and _line(trade_entry, Ledger.BURN) == 1
		and _line(trade_entry, Ledger.ESCROW) == -10,
		"Seller credit plus burned fee equal the escrow the buyer held")
	_expect(farm.economy_cash(PLAYER_A) == 129 and farm.economy_cash(PLAYER_B) == 110,
		"Seller receives 9 after the fee; buyer pays its 10 bid")
	_expect(farm.economy_issued() == 959 and farm.economy_total_cash() == 959,
		"One COIN fee lowers both net issuance and total cash")
	var report: Dictionary = farm.economy_reconcile()
	_expect(report.issuance == 960 and report.burned == 1 and report.total_cash == 959,
		"The ledger reports gross issuance, burned fees and the resulting cash")
	_expect_reconciled(farm, "a settled trade")


func _test_shipping_fee() -> void:
	var farm: Farm = _fixture()
	_expect(farm.market_ship("ship-a", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 1, START).ok, "A ships one green")
	var fee_entry: Dictionary = _event_entry(farm, "ship-a")
	_expect(fee_entry.kind == Ledger.KIND_SHIPPING_FEE and _entry_balanced(fee_entry),
		"A shipment records one balanced fee entry")
	_expect(_line(fee_entry, Ledger.BURN) == Market.SHIPMENT_FEE
		and _line(fee_entry, Ledger.owner_code(PLAYER_A)) == -Market.SHIPMENT_FEE,
		"The flat freight fee is burned from the sender account")
	_expect(farm.economy_issued() == 358 and farm.economy_total_cash() == 358,
		"The freight fee lowers issue and cash by the same amount")
	_expect_reconciled(farm, "a shipment fee")
	var entries_before: int = farm.economy_ledger_entries().size()
	_expect(farm.market_deliver(ARRIVE).count == 1, "The shipment arrives and delivers")
	_expect(farm.economy_ledger_entries().size() == entries_before,
		"Delivery moves goods only and adds no cash entry")
	_expect_reconciled(farm, "a delivery")


func _test_duplicate_commands() -> void:
	var farm: Farm = _fixture()
	var accepted: Dictionary = farm.snapshot()
	var entries_before: int = farm.economy_ledger_entries().size()
	var opened: Dictionary = farm.economy_open_account("open-a", PLAYER_A, START)
	_expect(opened.ok and opened.duplicate and farm.snapshot() == accepted,
		"A replayed opening grant changes no cash and no journal entry")
	_expect(farm.economy_ledger_entries().size() == entries_before,
		"Replay does not append another opening entry")

	_expect(farm.market_place_order("dup-sell", PLAYER_A, "sell", "greens", 10, 1,
		START + HOUR, START).ok, "A rests a sell order")
	_expect(farm.market_place_order("dup-buy", PLAYER_B, "buy", "greens", 10, 1,
		START + HOUR, START).ok, "B places a buy order")
	var placed: Dictionary = farm.snapshot()
	var place_entries: int = farm.economy_ledger_entries().size()
	var place_replay: Dictionary = farm.market_place_order("dup-buy", PLAYER_B, "buy",
		"greens", 10, 1, START + HOUR, START)
	_expect(place_replay.ok and place_replay.duplicate and farm.snapshot() == placed,
		"A replayed buy order returns the original result")
	_expect(farm.economy_ledger_entries().size() == place_entries,
		"A replayed buy order does not hold a second escrow entry")

	_expect(farm.market_match(START, "dup-match").ok, "A match sweep accepts a command id")
	var matched: Dictionary = farm.snapshot()
	var match_entries: int = farm.economy_ledger_entries().size()
	var match_replay: Dictionary = farm.market_match(START, "dup-match")
	_expect(match_replay.ok and match_replay.duplicate and farm.snapshot() == matched,
		"A replayed match sweep returns the original count")
	_expect(farm.economy_ledger_entries().size() == match_entries,
		"A replayed match sweep posts no second settlement entry")


func _test_persistence_and_legacy_adoption() -> void:
	var farm: Farm = _fixture()
	farm.market_open_merchant("persist-merchant", START)
	farm.economy_pay("persist-pay", PLAYER_A, PLAYER_B, 7, START)
	farm.market_place_order("persist-buy", PLAYER_B, "buy", "greens", 10, 1,
		START + HOUR, START)
	farm.market_ship("persist-ship", PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 1, START)
	var original: Dictionary = farm.snapshot()
	var json_value: Dictionary = JSON.parse_string(JSON.stringify(original))
	var restored := Farm.new()
	_expect(restored.restore_snapshot(json_value), "A JSON snapshot with a journal restores")
	_expect(restored.economy_ledger() == farm.economy_ledger(),
		"The journal sequence, entries and checkpoint survive the JSON round trip")
	_expect(Ledger.valid(restored.economy_ledger()), "The restored journal is valid")
	_expect_reconciled(restored, "a JSON restart")
	var store := FarmStore.new(test_root.path_join("store"))
	_expect(store.load_state().kind == "missing", "The isolated save directory is admitted")
	_expect(store.save(farm.snapshot(), Decorations.new().snapshot()).ok,
		"A farm with a journal saves")
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok, "The saved farm loads")
	var reopened := Farm.new()
	_expect(reopened.restore_snapshot(loaded.farm), "The loaded farm restores")
	_expect(reopened.economy_ledger() == farm.economy_ledger(),
		"The journal is identical after the disk round trip")
	_expect_reconciled(reopened, "a disk restart")

	# A pre-ledger document gets an empty journal plus an opening checkpoint
	# derived from the authorities it already carries.
	var legacy_source: Farm = _fixture()
	legacy_source.economy_pay("legacy-pay", PLAYER_A, PLAYER_B, 5, START)
	var legacy: Dictionary = legacy_source.snapshot()
	var issued_before: int = int(legacy.economy.issued)
	var total_before: int = int(legacy.economy.issued)
	legacy.economy.erase("ledger")
	var adopted := Farm.new()
	_expect(adopted.restore_snapshot(legacy), "An economy without a ledger still restores")
	var adopted_ledger: Dictionary = adopted.economy_ledger()
	_expect(adopted_ledger.sequence == 0 and adopted_ledger.entries.is_empty(),
		"The old document adopts an empty journal, not invented entries")
	_expect(adopted_ledger.balances.has(Ledger.ISSUANCE)
		and int(adopted_ledger.balances[Ledger.ISSUANCE]) == -issued_before,
		"The opening checkpoint puts the whole net issue on the issuance side")
	_expect(adopted.economy_issued() == issued_before
		and adopted.economy_total_cash() == total_before,
		"Adoption does not issue or consume cash")
	var adopted_report: Dictionary = adopted.economy_reconcile()
	_expect(adopted_report.ok and not adopted_report.legacy,
		"The adopted checkpoint reconciles with the existing authorities")
	_expect(adopted.economy_pay("after-adopt", PLAYER_A, PLAYER_B, 1, START).ok,
		"A new command works on the adopted journal")
	_expect(adopted.economy_ledger().sequence == 1
		and adopted.economy_ledger_entries().size() == 1,
		"The first post-adoption command starts the journal at sequence 1")
	_expect_reconciled(adopted, "a post-adoption command")


func _test_invalid_entries() -> void:
	var farm := Farm.new(START)
	farm.economy_open_account("valid-a", PLAYER_A, START)
	var original: Dictionary = farm.economy_ledger().duplicate(true)
	var entry_id: String = str(farm.economy_ledger_entries()[0].id)
	var corruptions: Array[Dictionary] = []
	var candidate: Dictionary = original.duplicate(true)
	candidate.entries[entry_id].credit = int(candidate.entries[entry_id].credit) + 1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.entries[entry_id].kind = "not_a_kind"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.entries[entry_id].lines[0].account = "account:bad id"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.entries[entry_id].lines[0].debit = -1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.entries[entry_id].lines[0].credit = 5
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.entries[entry_id].sequence = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.entries["ledger_999"] = candidate.entries[entry_id]
	candidate.entries.erase(entry_id)
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.balances[Ledger.BURN] = 5
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.balances["mystery"] = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.balances.erase(Ledger.owner_code(PLAYER_A))
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.balances[Ledger.ISSUANCE] = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.entries = []
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.erase("balances")
	corruptions.append(candidate)
	for broken: Dictionary in corruptions:
		_expect(not Ledger.valid(broken), "A malformed journal is rejected")

	var unbalanced: Dictionary = original.duplicate(true)
	var refused: Dictionary = Ledger.post(unbalanced, Ledger.KIND_PAY, "bad-post", START, [
		Ledger.debit_line(Ledger.owner_code(PLAYER_A), 5),
		Ledger.credit_line(Ledger.owner_code(PLAYER_B), 4),
	])
	_expect(not refused.ok and refused.reason == "unbalanced",
		"Posting an unbalanced entry is refused")
	_expect(unbalanced == original, "A refused entry leaves the journal untouched")

	var valid_snapshot: Dictionary = farm.snapshot()
	var broken_snapshot: Dictionary = valid_snapshot.duplicate(true)
	broken_snapshot.economy.ledger.entries[entry_id].credit += 1
	_expect(not farm.restore_snapshot(broken_snapshot) and farm.snapshot() == valid_snapshot,
		"A snapshot with an unbalanced entry is rejected without changing the farm")
	var no_entry: Dictionary = valid_snapshot.duplicate(true)
	no_entry.economy.accounts[PLAYER_A].cash = int(no_entry.economy.accounts[PLAYER_A].cash) + 1
	no_entry.economy.issued = int(no_entry.economy.issued) + 1
	_expect(not Economy.valid(no_entry.economy),
		"A cash change without a journal entry is not a valid economy")
	_expect(not farm.restore_snapshot(no_entry) and farm.snapshot() == valid_snapshot,
		"A same-candidate violation is rejected at the restore boundary")


func _test_eviction_keeps_checkpoint() -> void:
	var farm := Farm.new(START)
	farm.economy_open_account("open-a", PLAYER_A, START)
	farm.economy_open_account("open-b", PLAYER_B, START)
	for index: int in 600:
		var command_id: String = "pay-%03d" % index
		var result: Dictionary
		if index % 2 == 0:
			result = farm.economy_pay(command_id, PLAYER_A, PLAYER_B, 1, START)
		else:
			result = farm.economy_pay(command_id, PLAYER_B, PLAYER_A, 1, START)
		_expect(result.ok, "Transfer " + command_id + " succeeds")
	var entries: Array = farm.economy_ledger_entries()
	var ledger: Dictionary = farm.economy_ledger()
	_expect(ledger.sequence == 602, "The journal sequence counts every accepted entry")
	_expect(entries.size() == Ledger.MAX_ENTRIES,
		"The live journal is bounded at MAX_ENTRIES")
	_expect(int(entries[0].sequence) == 602 - Ledger.MAX_ENTRIES + 1,
		"Eviction removes the lowest sequences first")
	_expect(_event_entry(farm, "pay-000").is_empty(),
		"An evicted command's journal entry is gone from the live log")
	var balance_total: int = 0
	for value: Variant in ledger.balances.values():
		balance_total += int(value)
	_expect(balance_total == 0, "The checkpoint still sums to zero after eviction")
	_expect_reconciled(farm, "600 transfers with eviction")
	_expect(farm.economy_cash(PLAYER_A) == 120 and farm.economy_cash(PLAYER_B) == 120,
		"Six hundred one-COIN round trips leave both balances unchanged")

	var before_replay: Dictionary = farm.snapshot()
	var recent: Dictionary = farm.economy_pay("pay-599", PLAYER_B, PLAYER_A, 1, START)
	_expect(recent.ok and recent.duplicate and farm.snapshot() == before_replay,
		"A recent payment id still replays after older entries were evicted")
	var entries_before: int = farm.economy_ledger_entries().size()
	_expect(farm.economy_pay("pay-after", PLAYER_A, PLAYER_B, 1, START).ok,
		"A new transfer still posts after eviction")
	_expect(farm.economy_ledger_entries().size() == entries_before,
		"The journal stays at its bound after another entry")
	_expect_reconciled(farm, "a transfer after eviction")


func _fixture() -> Farm:
	var farm := Farm.new(START)
	_grow(farm, "field_01", ["cell_01", "cell_02", "cell_03", "cell_04",
		"cell_05", "cell_06", "cell_07", "cell_08"], PLAYER_A)
	_grow(farm, "field_02", ["cell_01", "cell_02", "cell_03", "cell_04",
		"cell_05", "cell_06", "cell_07", "cell_08"], PLAYER_B)
	_grow(farm, "field_01", ["cell_09", "cell_10", "cell_11", "cell_12",
		"cell_13", "cell_14", "cell_15", "cell_16"], PLAYER_C)
	farm.economy_open_account("open-a", PLAYER_A, START)
	farm.economy_open_account("open-b", PLAYER_B, START)
	farm.economy_open_account("open-c", PLAYER_C, START)
	return farm


func _grow(farm: Farm, field_id: String, cells: Array, actor: String) -> void:
	for cell_id: String in cells:
		farm.sow(field_id, cell_id, "greens", START, actor)
	farm.mature_all_crops(START)
	for cell_id: String in cells:
		farm.harvest(field_id, cell_id, START, actor)


func _expect_reconciled(farm: Farm, label: String) -> void:
	var report: Dictionary = farm.economy_reconcile()
	_expect(report.ok, "The journal reconciles after " + label)
	_expect(int(report.issuance) - int(report.burned) == int(report.issued),
		"Gross issuance minus burned fees equals net issue after " + label)
	_expect(farm.economy_total_cash() == farm.economy_issued(),
		"Total cash equals net issue after " + label)
	for entry: Dictionary in farm.economy_ledger_entries():
		_expect(_entry_balanced(entry), "Every live entry is balanced after " + label)


func _entry_balanced(entry: Dictionary) -> bool:
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


func _event(entry: Dictionary) -> String:
	return str(entry.event_id)


func _event_entry(farm: Farm, event_id: String) -> Dictionary:
	for entry: Dictionary in farm.economy_ledger_entries():
		if str(entry.event_id) == event_id:
			return entry
	return {}


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
