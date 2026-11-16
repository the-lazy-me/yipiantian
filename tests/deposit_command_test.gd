extends SceneTree
## M8-17: the deposit rules reachable as real commands.
##
## Drives `FarmCommand` against a real `FarmState`: a member opens an account,
## opens the bank, deposits and withdraws. Every refusal keeps its named reason
## from the rule instead of being collapsed into `invalid_command`, a replayed id
## moves no cash, `total_cash == issued` holds throughout, and a visitor role is
## not allowed to submit either kind. Headless and isolated: no clock, scene,
## network or live save.

const Farm = preload("res://farm/farm_state.gd")
const Command = preload("res://farm/farm_command.gd")
const Economy = preload("res://farm/economy_state.gd")
const Deposits = preload("res://farm/deposit_state.gd")
const Ledger = preload("res://farm/ledger_state.gd")
const WorldInvite = preload("res://world/world_invite.gd")

const START: float = 1800000000.0
const TERM: int = 604800
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"

var checks: int = 0
var failures: Array[String] = []
var commands := Command.new()


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	_test_command_shape()
	_test_deposit_and_withdraw()
	_test_refusals()
	_test_replay_moves_nothing()
	_test_conservation_and_roles()
	for failure: String in failures:
		push_error(failure)
	print("DEPOSIT_COMMAND_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


## The command carries operands only: no identity field may enter, and a
## malformed amount is refused before the rule. Business bounds stay in the
## rule, so an out-of-range amount still reaches a named refusal.
func _test_command_shape() -> void:
	_expect(Command.KINDS.has(Command.BANK_DEPOSIT) and Command.KINDS.has(Command.BANK_WITHDRAW),
		"Both deposit kinds are registered in KINDS")
	_expect(Command.is_economy_kind(Command.BANK_DEPOSIT)
		and Command.is_economy_kind(Command.BANK_WITHDRAW),
		"Both deposit kinds are economy kinds")
	var deposit: Dictionary = Command.make_bank_deposit("d-shape", 100, START)
	var withdraw: Dictionary = Command.make_bank_withdraw("w-shape", 40, START)
	_expect(Command.valid(deposit) and deposit.size() == 4,
		"A deposit command is valid with exactly id, kind, amount and time")
	_expect(Command.valid(withdraw) and withdraw.size() == 4,
		"A withdrawal command is valid with exactly id, kind, amount and time")
	var identity: Array[String] = ["from", "from_id", "owner", "owner_id", "payer", "borrower"]
	for key: String in identity:
		var forged: Dictionary = deposit.duplicate(true)
		forged[key] = "player_x"
		_expect(not Command.valid(forged), "A deposit naming %s is invalid" % key)
	for amount: Variant in [0, -1, 1.5, "100", NAN, INF]:
		var bad: Dictionary = {"id": "d-bad", "kind": Command.BANK_DEPOSIT,
			"amount": amount, "at_utc": START}
		_expect(not Command.valid(bad),
			"A zero, negative, fractional, string or non-finite deposit amount is refused")
	var extra: Dictionary = deposit.duplicate(true)
	extra["player_id"] = PLAYER_A
	_expect(not Command.valid(extra), "An extra identity key breaks the exact key set")
	# The minimum and maximum are the deposit rule's constants, not a second
	# pair: the boundary lets an out-of-range amount through so the rule can
	# answer with its own named reason.
	_expect(Command.valid(Command.make_bank_deposit("d-low", Deposits.MIN_DEPOSIT - 1, START)),
		"The command boundary does not duplicate the deposit minimum")
	_expect(Command.valid(Command.make_bank_deposit("d-high", Deposits.MAX_DEPOSIT + 1, START)),
		"The command boundary does not duplicate the deposit maximum")
	_expect(Command.valid(Command.make_bank_withdraw("w-zero-claim", 1, START)),
		"A one-COIN withdrawal is a valid command shape")


func _test_deposit_and_withdraw() -> void:
	var farm: Farm = _fixture()
	var issued_before: int = farm.economy_issued()
	var total_before: int = farm.economy_total_cash()
	_expect(farm.economy_cash(PLAYER_A) == 120, "The fixture grants the opening cash")

	var deposited: Dictionary = _execute(farm, Command.make_bank_deposit("dep-a", 100, START + 1.0),
		PLAYER_A)
	_expect(deposited.ok and not deposited.duplicate,
		"A member deposits through a command")
	_expect(farm.economy_cash(PLAYER_A) == 20, "The deposit debits the player's cash")
	_expect(int(farm.economy_bank().cash) == Economy.BANK_CAPITAL + 100,
		"The deposit credits the bank's real cash")
	_expect(farm.economy_deposit_principal(PLAYER_A) == 100,
		"The account's claim is recorded")
	_expect(farm.economy_total_cash() == total_before and farm.economy_issued() == issued_before,
		"A deposit moves cash and issues nothing")
	var deposit_entry: Dictionary = _entry(farm, "dep-a")
	_expect(deposit_entry.kind == Ledger.KIND_DEPOSIT_IN and _balanced(deposit_entry),
		"The deposit posts one balanced deposit_in entry")

	var withdrawn: Dictionary = _execute(farm,
		Command.make_bank_withdraw("wd-a", 40, START + 2.0), PLAYER_A)
	_expect(withdrawn.ok and farm.economy_cash(PLAYER_A) == 60,
		"A withdrawal credits the player's cash")
	_expect(int(farm.economy_bank().cash) == Economy.BANK_CAPITAL + 60,
		"The withdrawal debits the bank's real cash")
	_expect(farm.economy_deposit_principal(PLAYER_A) == 60,
		"A partial withdrawal lowers the claim")
	var withdraw_entry: Dictionary = _entry(farm, "wd-a")
	_expect(withdraw_entry.kind == Ledger.KIND_DEPOSIT_OUT and _balanced(withdraw_entry),
		"The withdrawal posts one balanced deposit_out entry")

	var closed: Dictionary = _execute(farm,
		Command.make_bank_withdraw("wd-a-rest", 60, START + 3.0), PLAYER_A)
	_expect(closed.ok and farm.economy_deposit_principal(PLAYER_A) == 0,
		"Withdrawing the rest closes the claim")
	_expect(farm.economy_cash(PLAYER_A) == 120
		and int(farm.economy_bank().cash) == Economy.BANK_CAPITAL,
		"A full round trip restores both balances")
	_expect(farm.economy_reconcile().ok and farm.economy_total_cash() == farm.economy_issued(),
		"The command path leaves the journal and the issue identity intact")


func _test_refusals() -> void:
	var farm: Farm = _fixture()
	var before: Dictionary = farm.economy_snapshot()
	_expect(_refusal(farm, Command.make_bank_deposit("bad-min", 9, START), PLAYER_A)
		== "invalid_amount", "A deposit below the minimum is refused by name")
	_expect(_refusal(farm, Command.make_bank_deposit("bad-max", 1001, START), PLAYER_A)
		== "invalid_amount", "A deposit above the maximum is refused by name")
	_expect(_refusal(farm, Command.make_bank_deposit("too-much", 200, START), PLAYER_A)
		== "insufficient", "A deposit above the player's cash is refused by name")
	_expect(_refusal(farm, Command.make_bank_deposit("no-account", 100, START), PLAYER_B)
		== "unknown_account", "A player without an account cannot deposit")
	_expect(_refusal(farm, Command.make_bank_withdraw("no-claim", 10, START), PLAYER_A)
		== "insufficient", "A withdrawal without a claim is refused by name")
	_expect(farm.economy_snapshot() == before, "Every refused command leaves the economy unchanged")

	var deposited: Dictionary = _execute(farm, Command.make_bank_deposit("dep-a", 50, START + 1.0),
		PLAYER_A)
	_expect(deposited.ok, "The refusal fixture takes one deposit")
	var with_claim: Dictionary = farm.economy_snapshot()
	_expect(_refusal(farm, Command.make_bank_withdraw("over-claim", 51, START + 2.0), PLAYER_A)
		== "insufficient", "A withdrawal above the claim is refused by name")
	_expect(_refusal(farm, Command.make_bank_withdraw("wd-max", 1001, START + 2.0), PLAYER_A)
		== "invalid_amount", "A withdrawal above the principal ceiling is refused by name")
	_expect(_refusal(farm, Command.make_bank_withdraw("wd-b", 10, START + 2.0), PLAYER_B)
		== "unknown_account", "A player without an account cannot withdraw")
	_expect(farm.economy_snapshot() == with_claim,
		"Refused withdrawals leave the claim and both balances unchanged")

	var reserved: Dictionary = _execute(farm,
		Command.make_bank_deposit("trade_1", 10, START + 3.0), PLAYER_A)
	_expect(not reserved.ok and reserved.reason == "invalid_command",
		"A command id in a reserved event namespace is refused")

	var anonymous: Dictionary = _execute(farm,
		Command.make_bank_deposit("anon", 10, START + 3.0), "")
	_expect(not anonymous.ok and anonymous.reason == "invalid_player",
		"A deposit without a connection identity is refused")

	# Capacity needs real cash, so the borrower takes a loan first. The claim is
	# capped at one maximum-sized deposit; the next deposit is refused before the
	# balance is even considered.
	var lender: Farm = _fixture()
	_expect(_execute(lender, Command.make_loan_borrow("seed-loan", 1000, TERM, START), PLAYER_A).ok,
		"The fixture borrows enough cash to reach the principal cap")
	_expect(_execute(lender, Command.make_bank_deposit("cap-1", 1000, START + 1.0), PLAYER_A).ok,
		"A maximum-sized deposit is accepted")
	var capped: Dictionary = _execute(lender,
		Command.make_bank_deposit("cap-2", 10, START + 2.0), PLAYER_A)
	_expect(not capped.ok and capped.reason == "deposit_capacity",
		"A deposit above the per-account cap is refused by name")
	_expect(lender.economy_deposit_principal(PLAYER_A) == Deposits.MAX_PRINCIPAL,
		"The per-account cap stays at the deposit constant")

	var closed_bank: Farm = Farm.new(START)
	_expect(_execute(closed_bank, Command.make_account_open("open-b", START), PLAYER_A).ok,
		"The closed-bank fixture opens an account")
	_expect(_refusal(closed_bank, Command.make_bank_deposit("closed-dep", 10, START + 1.0),
		PLAYER_A) == "not_open", "Depositing into a closed bank is refused by name")
	_expect(_refusal(closed_bank, Command.make_bank_withdraw("closed-wd", 10, START + 1.0),
		PLAYER_A) == "not_open", "Withdrawing from a closed bank is refused by name")


func _test_replay_moves_nothing() -> void:
	var farm: Farm = _fixture()
	var deposit_command: Dictionary = Command.make_bank_deposit("dep-r", 100, START + 1.0)
	var first: Dictionary = _execute(farm, deposit_command, PLAYER_A)
	_expect(first.ok, "The replay fixture takes one deposit")
	var accepted: Dictionary = farm.snapshot()
	var replay: Dictionary = commands.execute(farm, deposit_command, PLAYER_A)
	_expect(replay.ok and replay.duplicate and not replay.has("candidate"),
		"A replayed deposit id returns the first result and no candidate")
	_expect(farm.snapshot() == accepted, "A replayed deposit moves no cash and posts no entry")
	var conflict: Dictionary = commands.execute(farm,
		Command.make_bank_deposit("dep-r", 50, START + 1.0), PLAYER_A)
	_expect(not conflict.ok and conflict.reason == "command_conflict",
		"Reusing a deposit id with another amount is a conflict")
	_expect(farm.snapshot() == accepted, "A conflicting id leaves the state unchanged")

	var withdraw_command: Dictionary = Command.make_bank_withdraw("wd-r", 40, START + 2.0)
	_expect(_execute(farm, withdraw_command, PLAYER_A).ok, "The replay fixture takes one withdrawal")
	var after_withdraw: Dictionary = farm.snapshot()
	var withdraw_replay: Dictionary = commands.execute(farm, withdraw_command, PLAYER_A)
	_expect(withdraw_replay.ok and withdraw_replay.duplicate,
		"A replayed withdrawal id is a duplicate")
	_expect(farm.snapshot() == after_withdraw,
		"A replayed withdrawal pays nothing twice")
	var withdraw_conflict: Dictionary = commands.execute(farm,
		Command.make_bank_withdraw("wd-r", 20, START + 3.0), PLAYER_A)
	_expect(not withdraw_conflict.ok and withdraw_conflict.reason == "command_conflict"
		and farm.snapshot() == after_withdraw,
		"Reusing a withdrawal id with another amount is a conflict")

	# Another connection cannot claim a committed id as its own action: the
	# payload binds the authority-supplied actor.
	var other_actor: Dictionary = commands.execute(farm, deposit_command, PLAYER_B)
	_expect(not other_actor.ok and other_actor.reason == "command_conflict",
		"Another player cannot replay a committed deposit id")


func _test_conservation_and_roles() -> void:
	var farm: Farm = _fixture()
	_expect(_execute(farm, Command.make_bank_deposit("dep-a", 100, START + 1.0), PLAYER_A).ok,
		"The conservation fixture deposits")
	_expect(_execute(farm, Command.make_bank_withdraw("wd-a", 25, START + 2.0), PLAYER_A).ok,
		"The conservation fixture withdraws")
	_expect(farm.economy_total_cash() == farm.economy_issued(),
		"Deposits and withdrawals keep total_cash == issued")
	_expect(farm.economy_reconcile().ok, "The journal reconciles after both commands")
	_expect(int(farm.economy_bank().cash) == Economy.BANK_CAPITAL + 75,
		"The bank holds the remaining principal as real cash")

	_expect(WorldInvite.allows(WorldInvite.MEMBER, Command.BANK_DEPOSIT),
		"A member may deposit")
	_expect(WorldInvite.allows(WorldInvite.MEMBER, Command.BANK_WITHDRAW),
		"A member may withdraw")
	_expect(not WorldInvite.allows(WorldInvite.VISITOR, Command.BANK_DEPOSIT),
		"A visitor may not deposit")
	_expect(not WorldInvite.allows(WorldInvite.VISITOR, Command.BANK_WITHDRAW),
		"A visitor may not withdraw")


func _fixture() -> Farm:
	# Open account A and the bank through the same command boundary members use.
	var farm := Farm.new(START)
	_expect(_execute(farm, Command.make_account_open("open-a", START), PLAYER_A).ok,
		"The fixture opens the member's account")
	_expect(_execute(farm, Command.make_bank_open("bank-open", START), PLAYER_A).ok,
		"The fixture opens the rule bank")
	return farm


func _execute(farm: Farm, command: Dictionary, actor: String) -> Dictionary:
	var execution: Dictionary = commands.execute(farm, command, actor)
	if execution.ok and not execution.duplicate:
		farm.accept(execution.candidate)
	return execution


## Runs a command expected to be refused by the rule and returns its reason.
func _refusal(farm: Farm, command: Dictionary, actor: String) -> String:
	var execution: Dictionary = commands.execute(farm, command, actor)
	return "" if execution.ok else str(execution.reason)


func _entry(farm: Farm, event_id: String) -> Dictionary:
	for entry: Dictionary in farm.economy_ledger_entries():
		if str(entry.event_id) == event_id:
			return entry
	return {}


func _balanced(entry: Dictionary) -> bool:
	if entry.is_empty():
		return false
	var debit: int = 0
	var credit: int = 0
	for line: Dictionary in entry.lines:
		debit += int(line.debit)
		credit += int(line.credit)
	return debit == credit and debit == int(entry.debit) and debit > 0


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
