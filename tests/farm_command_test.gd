extends SceneTree
## M0-02: harvest command equivalence and batch idempotency.

const Farm = preload("res://farm/farm_state.gd")
const Command = preload("res://farm/farm_command.gd")
const Loans = preload("res://farm/loan_state.gd")
const START: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run()
	for failure: String in failures:
		push_error(failure)
	print("FARM_COMMAND_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run() -> void:
	_test_direct_equivalence()
	_test_same_id_replays_once()
	_test_id_survives_resow()
	_test_distinct_ids_reward_twice()
	_test_payload_conflict()
	_test_invalid_commands_are_atomic()
	_test_tidy_is_idempotent()
	_test_economy_command_shapes()


func _test_direct_equivalence() -> void:
	var direct := Farm.new(START)
	_expect(direct.harvest("field_03", "cell_06", START).ok, "Direct harvest succeeds")
	var through := Farm.new(START)
	var commands := Command.new()
	var command: Dictionary = Command.make("c1", "field_03", "cell_06", START)
	var execution: Dictionary = commands.execute(through, command)
	_expect(execution.ok and not execution.duplicate, "Command harvest succeeds once")
	through.accept(execution.candidate)
	var compared: Dictionary = through.snapshot()
	var direct_snapshot: Dictionary = direct.snapshot()
	# The command path additionally carries the durable transaction ledger.
	_expect(compared.transaction.command_results.has("c1") and compared.transaction.sequence == 1,
		"Accepted command records its result and event sequence in the state")
	compared.erase("transaction")
	direct_snapshot.erase("transaction")
	_expect(compared == direct_snapshot, "Command harvest matches direct harvest")
	_expect(through.snapshot().inventory.greens == 1, "Command harvest adds exactly one")


func _test_same_id_replays_once() -> void:
	var farm := Farm.new(START)
	var commands := Command.new()
	var command: Dictionary = Command.make("same", "field_03", "cell_06", START)
	var first: Dictionary = commands.execute(farm, command)
	farm.accept(first.candidate)
	var snapshot: Dictionary = farm.snapshot()
	var replay: Dictionary = commands.execute(farm, command)
	_expect(replay.ok and replay.duplicate, "Replayed id reports duplicate")
	_expect(not replay.has("candidate"), "Replayed id produces no candidate to accept")
	_expect(farm.snapshot() == snapshot, "Replayed id leaves authoritative state unchanged")
	_expect(farm.snapshot().inventory.greens == 1, "Replayed id does not mint a second reward")


func _test_id_survives_resow() -> void:
	var farm := Farm.new(START)
	var commands := Command.new()
	var command: Dictionary = Command.make("resow", "field_03", "cell_06", START)
	var first: Dictionary = commands.execute(farm, command)
	farm.accept(first.candidate)
	_expect(farm.sow("field_03", "cell_06", "radish", START + 1).ok, "The harvested cell can be sown again")
	farm.mature_all_crops(START + 9000)
	var replay: Dictionary = commands.execute(farm, command)
	_expect(replay.duplicate, "A replayed id is still rejected after the cell changes")
	_expect(farm.snapshot().inventory.radish == 0, "Replay cannot harvest the later crop")


func _test_distinct_ids_reward_twice() -> void:
	var farm := Farm.new(START)
	var commands := Command.new()
	var first: Dictionary = commands.execute(farm, Command.make("a", "field_03", "cell_06", START))
	farm.accept(first.candidate)
	_expect(farm.sow("field_03", "cell_06", "greens", START + 1).ok, "Sow the second crop")
	farm.mature_all_crops(START + 9000)
	var second: Dictionary = commands.execute(farm, Command.make("b", "field_03", "cell_06", START + 9000))
	_expect(second.ok and not second.duplicate, "A distinct id executes the later harvest")
	farm.accept(second.candidate)
	_expect(farm.snapshot().inventory.greens == 2, "Two distinct commands reward twice")
	_expect(farm.event_sequence() == 2, "Each committed command advances the event sequence once")


func _test_payload_conflict() -> void:
	var farm := Farm.new(START)
	var commands := Command.new()
	var command: Dictionary = Command.make("x", "field_03", "cell_06", START)
	var first: Dictionary = commands.execute(farm, command)
	farm.accept(first.candidate)
	var conflicting: Dictionary = Command.make("x", "field_04", "cell_06", START)
	var result: Dictionary = commands.execute(farm, conflicting)
	_expect(not result.ok and result.reason == "command_conflict", "Reusing an id for another payload is rejected")


func _test_invalid_commands_are_atomic() -> void:
	var farm := Farm.new(START)
	var before: Dictionary = farm.snapshot()
	var commands := Command.new()
	var samples: Array[Dictionary] = [
		{},
		Command.make("", "field_03", "cell_06", START),
		Command.make("m", "field_03", "cell_06", -1.0),
		Command.make("n", "field_03", "cell_06", NAN),
		{"id": "k", "kind": "harvest", "field_id": "field_03", "cell_id": "cell_06", "at_utc": START, "extra": true},
	]
	for sample: Dictionary in samples:
		var execution: Dictionary = commands.execute(farm, sample)
		_expect(not execution.ok and not execution.duplicate, "Invalid command is rejected")
		_expect(farm.snapshot() == before, "Invalid command leaves state unchanged")
	_expect(farm.committed_command_count() == 0, "Invalid commands never enter the replay set")
	_expect(farm.event_sequence() == 0, "Invalid commands do not advance the event sequence")
	_test_transaction_survives_restore()


func _test_transaction_survives_restore() -> void:
	var farm := Farm.new(START)
	var commands := Command.new()
	var command: Dictionary = Command.make("durable", "field_03", "cell_06", START)
	var execution: Dictionary = commands.execute(farm, command)
	farm.accept(execution.candidate)
	var restored := Farm.new()
	_expect(restored.restore_snapshot(farm.snapshot()), "A snapshot with its transaction restores")
	var replay: Dictionary = commands.execute(restored, command)
	_expect(replay.duplicate and replay.ok, "A restarted world replays the committed id from the ledger")
	_expect(restored.snapshot().inventory.greens == 1, "Replay after restore does not mint a second reward")
	var damaged: Dictionary = restored.snapshot()
	damaged.transaction.sequence = -1.0
	_expect(not Farm.new().restore_snapshot(damaged), "A negative event sequence is rejected as corrupt")
	damaged = restored.snapshot()
	damaged.transaction.command_results.durable.result.ok = "yes"
	_expect(not Farm.new().restore_snapshot(damaged), "A malformed recorded result is rejected as corrupt")


func _test_tidy_is_idempotent() -> void:
	var farm := Farm.new(START)
	var commands := Command.new()
	# field_06 cells 11–12 start rough and 13–16 weedy.
	var weed: Dictionary = Command.make_tidy("weed-1", Command.WEED, "field_06", "cell_13", START)
	var before: Dictionary = farm.snapshot()
	var first: Dictionary = commands.execute(farm, weed)
	_expect(first.ok and not first.duplicate, "Weed command succeeds on weedy ground")
	_expect(farm.snapshot() == before, "The weed result stays in the candidate until accepted")
	farm.accept(first.candidate)
	_expect(farm.get_cell("field_06", "cell_13").ground == "rough", "Weed turns weedy ground to rough")
	_expect(farm.snapshot().transaction.command_results.has("weed-1"), "Weed records its result in the ledger")
	var replay: Dictionary = commands.execute(farm, weed)
	_expect(replay.ok and replay.duplicate, "A replayed weed id is a duplicate")
	var again: Dictionary = commands.execute(farm, Command.make_tidy(
		"weed-2", Command.WEED, "field_06", "cell_13", START))
	_expect(not again.ok and again.reason == "wrong_ground", "A second weed with a new id is refused by the rules")
	_expect(farm.event_sequence() == 1, "Only the committed weed advanced the event sequence")
	var till: Dictionary = commands.execute(farm, Command.make_tidy(
		"till-1", Command.TILL, "field_06", "cell_13", START))
	_expect(till.ok, "Till succeeds on the roughed cell")
	farm.accept(till.candidate)
	_expect(farm.get_cell("field_06", "cell_13").ground == "ready", "Till prepares the soil")
	_expect(not commands.execute(farm, Command.make_tidy(
		"till-unknown", "rake", "field_06", "cell_13", START)).ok, "An unknown tidy action is rejected")
	_expect(farm.event_sequence() == 2, "Weed and till each advanced the sequence once")


## The client only names operands. Identity is bound by the authority, so the
## exact key set must keep every identity field out while preserving the values
## the player chose.
func _test_economy_command_shapes() -> void:
	var identity: Array[String] = ["from", "from_id", "owner", "owner_id", "payer", "borrower"]
	var samples: Array[Dictionary] = [
		Command.make_account_open("acc-1", START),
		Command.make_market_open("merchant-1", START),
		Command.make_market_deliver("deliver-1", START),
		Command.make_bank_open("bank-1", START),
		Command.make_pay("pay-1", "player_b", 25, 7, START),
		Command.make_market_place("place-1", "sell", "greens", 17, 3, START + 600.0, START),
		Command.make_market_cancel("cancel-1", "order-1", START),
		Command.make_market_ship("ship-1", "farm_market", "harbor_market", "radish", 2, START),
		Command.make_loan_borrow("loan-1", 250, Loans.TERMS[1], START),
		Command.make_loan_repay("repay-1", "loan-1", START),
	]
	var sizes: Array[int] = [3, 3, 3, 3, 6, 8, 4, 7, 5, 4]
	for index: int in samples.size():
		var command: Dictionary = samples[index]
		var kind: String = str(command.get("kind", ""))
		_expect(Command.valid(command), "Economy %s command is valid" % kind)
		_expect(command.size() == sizes[index], "Economy %s command has the exact key set" % kind)
		for key: String in identity:
			_expect(not command.has(key), "Economy %s command carries no %s" % [kind, key])
	var pay: Dictionary = samples[4]
	_expect(str(pay.to_id) == "player_b" and int(pay.amount) == 25 and int(pay.seq) == 7,
		"pay keeps the recipient, amount and payment sequence")
	var place: Dictionary = samples[5]
	_expect(str(place.side) == "sell" and str(place.good_id) == "greens"
		and int(place.price) == 17 and int(place.quantity) == 3
		and is_equal_approx(float(place.expires_utc), START + 600.0),
		"market_place keeps side, good, price, quantity and expiry")
	var ship: Dictionary = samples[7]
	_expect(str(ship.origin) == "farm_market" and str(ship.destination) == "harbor_market"
		and str(ship.good_id) == "radish" and int(ship.quantity) == 2,
		"market_ship keeps route, good and quantity")
	var borrow: Dictionary = samples[8]
	_expect(int(borrow.principal) == 250 and int(borrow.term) == Loans.TERMS[1],
		"loan_borrow keeps principal and term")
	# A client-claimed identity is malformed, not an ignored extra.
	var forged: Dictionary = Command.make_pay("pay-2", "player_b", 25, 1, START)
	forged["payer"] = "player_c"
	_expect(not Command.valid(forged), "A pay payload naming a payer is invalid")
	for key: String in identity:
		var tampered: Dictionary = Command.make_account_open("acc-2", START)
		tampered[key] = "player_c"
		_expect(not Command.valid(tampered), "account_open with %s is invalid" % key)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS " + message)
	else:
		failures.append(message)
		print("FAIL " + message)
