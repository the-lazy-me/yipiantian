extends SceneTree
## M0-02: harvest command equivalence and batch idempotency.

const Farm = preload("res://farm/farm_state.gd")
const Command = preload("res://farm/farm_command.gd")
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


func _test_direct_equivalence() -> void:
	var direct := Farm.new(START)
	_expect(direct.harvest("field_03", "cell_06", START).ok, "Direct harvest succeeds")
	var through := Farm.new(START)
	var commands := Command.new()
	var command: Dictionary = Command.make("c1", "field_03", "cell_06", START)
	var execution: Dictionary = commands.execute(through, command)
	_expect(execution.ok and not execution.duplicate, "Command harvest succeeds once")
	through.accept(execution.candidate)
	commands.commit(command, execution.result)
	_expect(through.snapshot() == direct.snapshot(), "Command harvest matches direct harvest")
	_expect(through.snapshot().inventory.greens == 1, "Command harvest adds exactly one")


func _test_same_id_replays_once() -> void:
	var farm := Farm.new(START)
	var commands := Command.new()
	var command: Dictionary = Command.make("same", "field_03", "cell_06", START)
	var first: Dictionary = commands.execute(farm, command)
	farm.accept(first.candidate)
	commands.commit(command, first.result)
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
	commands.commit(command, first.result)
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
	commands.commit(Command.make("a", "field_03", "cell_06", START), first.result)
	_expect(farm.sow("field_03", "cell_06", "greens", START + 1).ok, "Sow the second crop")
	farm.mature_all_crops(START + 9000)
	var second: Dictionary = commands.execute(farm, Command.make("b", "field_03", "cell_06", START + 9000))
	_expect(second.ok and not second.duplicate, "A distinct id executes the later harvest")
	farm.accept(second.candidate)
	commands.commit(Command.make("b", "field_03", "cell_06", START + 9000), second.result)
	_expect(farm.snapshot().inventory.greens == 2, "Two distinct commands reward twice")


func _test_payload_conflict() -> void:
	var farm := Farm.new(START)
	var commands := Command.new()
	var command: Dictionary = Command.make("x", "field_03", "cell_06", START)
	var first: Dictionary = commands.execute(farm, command)
	farm.accept(first.candidate)
	commands.commit(command, first.result)
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
	_expect(commands.committed_count() == 0, "Invalid commands never enter the replay set")


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS " + message)
	else:
		failures.append(message)
		print("FAIL " + message)
