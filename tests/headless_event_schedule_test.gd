extends SceneTree
## M3-02: event scheduling, segmented advancement and rollback semantics.
## Fixtures stay below .local/verification.

const Farm = preload("res://farm/farm_state.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const Crops = preload("res://farm/crop_catalog.gd")
const Nature = preload("res://farm/nature_state.gd")
const START: float = 1800000000.0
# Sibling fixtures must see the same weather, so they share one fixed seed
# instead of each created world sampling its own.
const TEST_SEED: int = 20261115

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	test_root = project_root.get_base_dir().path_join(
		".local/verification/headless-event-schedule-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(test_root)
	_run()
	for failure: String in failures:
		push_error(failure)
	print("HEADLESS_EVENT_SCHEDULE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run() -> void:
	_test_next_event_uses_crop_thresholds()
	_test_segmented_matches_continuous()
	_test_long_offline_matches_single_settle()
	_test_backwards_never_shrinks()
	_test_inf_without_future_stage()


func _test_next_event_uses_crop_thresholds() -> void:
	var world := _open_world("next-event")
	# field_04/cell_06 starts as greens at 20% progress; the next stage change is
	# its young threshold (35% of the greens duration). Weather sets the growth
	# factor for the current block, so the boundary moves accordingly.
	var greens: Dictionary = Crops.definition("greens")
	var factor: float = Farm.weather_growth_factor(
		str(world.nature.weather_at(START).kind), Farm.MOISTURE_DEFAULT)
	var expected: float = START + (greens.duration_seconds * Crops.YOUNG_PROGRESS - greens.duration_seconds * 0.2) / factor
	var event: float = world.next_event_utc()
	_expect(absf(event - expected) < 0.001, "The next event is the earliest crop threshold")

	var advanced: Dictionary = world.advance_to(event)
	_expect(advanced.ok and int(advanced.get("segments", 0)) >= 1, "Advancing to the event settles one segment")
	_expect(world.farm.get_cell("field_04", "cell_06").stage == "young",
		"The event boundary moves the crop into the young stage")

	var next_after: float = world.next_event_utc()
	_expect(is_finite(next_after) and next_after > event, "The following event is strictly later")


func _test_segmented_matches_continuous() -> void:
	var direct := _open_world("segment-continuous")
	var stepped := _open_world("segment-stepped")
	for world: RefCounted in [direct, stepped]:
		_expect(world.execute(FarmCommand.make_sow(
			"seg-sow", "field_01", "cell_01", "greens", START)).ok, "Segmented fixture sows")
		_expect(world.execute(FarmCommand.make_water(
			"seg-water", "field_01", "cell_01", START + 60)).ok, "Segmented fixture waters")

	var target: float = START + 1000.0
	var events: int = 0
	var guard: int = 0
	while guard < 64:
		guard += 1
		var event: float = stepped.next_event_utc()
		if not is_finite(event) or event > target:
			break
		_expect(stepped.advance_to(event).ok, "Stepping to an event succeeds")
		events += 1
	var step_result: Dictionary = stepped.advance_to(target)
	var continuous_result: Dictionary = direct.advance_to(target)
	_expect(step_result.ok and continuous_result.ok, "Both advances complete")
	_expect(direct.farm.snapshot() == stepped.farm.snapshot(),
		"One advance and event-by-event advances produce identical snapshots")
	_expect(direct.farm.hud_state() == stepped.farm.hud_state(),
		"One advance and event-by-event advances produce identical inventory")
	_expect(events <= 2 * _crop_cells(direct) + 1, "Segmented stepping terminates within the event bound")


func _test_long_offline_matches_single_settle() -> void:
	var world := _open_world("long-segmented")
	_expect(world.execute(FarmCommand.make_sow("long-sow", "field_01", "cell_01", "greens", START)).ok,
		"Long fixture sows")
	_expect(world.execute(FarmCommand.make_water("long-water", "field_01", "cell_01", START + 60)).ok,
		"Long fixture waters")
	var target: float = START + 30.0 * 86400.0
	var advanced: Dictionary = world.advance_to(target)
	_expect(advanced.ok, "A thirty-day advance completes")
	var crop_cells: int = _crop_cells(world)
	# Growth events plus one weather-block boundary per six hours are the only
	# segmentation points; the session adds the weather ones.
	var weather_steps: int = int(ceilf((target - START) / Nature.WEATHER_SECONDS))
	_expect(int(advanced.get("segments", 0)) <= 2 * crop_cells + weather_steps + 1,
		"The thirty-day advance stops at a bounded number of events")

	var direct := Farm.new(START, {}, world.nature)
	direct.sow("field_01", "cell_01", "greens", START)
	direct.water("field_01", "cell_01", START + 60)
	direct.settle(target)
	var world_rules: Dictionary = world.farm.snapshot()
	var direct_rules: Dictionary = direct.snapshot()
	world_rules.erase("transaction")
	direct_rules.erase("transaction")
	_expect(world_rules == direct_rules,
		"Segmented long advance matches a single FarmState settlement")
	_expect(world.farm.get_cell("field_01", "cell_01").stage == "mature",
		"Growth remains capped at maturity after segmentation")
	_expect(is_inf(world.next_event_utc()),
		"A fully mature world reports no future event")

	# Walk the same interval only by events; it must finish and match.
	var walked := _open_world("long-walked")
	walked.execute(FarmCommand.make_sow("walk-sow", "field_01", "cell_01", "greens", START))
	walked.execute(FarmCommand.make_water("walk-water", "field_01", "cell_01", START + 60))
	var events: int = 0
	var guard: int = 0
	while guard < 512:
		guard += 1
		var event: float = walked.next_event_utc()
		if not is_finite(event) or event > target:
			break
		_expect(walked.advance_to(event).ok, "Long walk event advance succeeds")
		events += 1
	_expect(walked.advance_to(target).ok, "The walk reaches the target")
	_expect(events <= 2 * crop_cells + 1, "The long offline walk uses a bounded event count")
	var walked_rules: Dictionary = walked.farm.snapshot()
	var world_walk_rules: Dictionary = world.farm.snapshot()
	# The two fixtures use different command ids, so compare rule state only.
	walked_rules.erase("transaction")
	world_walk_rules.erase("transaction")
	_expect(walked_rules == world_walk_rules,
		"Walking events and direct segmented advancement agree")


func _test_backwards_never_shrinks() -> void:
	var world := _open_world("backwards")
	_expect(world.execute(FarmCommand.make_sow("back-sow", "field_01", "cell_01", "greens", START)).ok,
		"Rollback fixture sows")
	_expect(world.advance_to(START + 1000.0).ok, "Rollback fixture advances")
	var before: Dictionary = world.farm.snapshot()
	var before_hud: Dictionary = world.farm.hud_state()
	var before_event: float = world.next_event_utc()
	var growth_before: float = float(before.fields.field_01.cells.cell_01.growth_seconds)

	var rejected: Dictionary = world.advance_to(START + 400.0)
	_expect(not rejected.ok and rejected.reason == "time_backwards",
		"A backwards advance is refused by the session")
	_expect(world.farm.snapshot() == before, "A refused backwards advance leaves the state unchanged")
	_expect(world.next_event_utc() == before_event, "A refused backwards advance keeps the next event")

	# FarmState settlement itself ignores an older time instead of rewinding.
	var early: Dictionary = world.farm.settle(START + 100.0)
	_expect(early.ok and early.changed_fields.is_empty(),
		"Settling at an earlier time skips every cell")
	_expect(world.farm.snapshot() == before, "Settling backwards does not reduce growth")
	var after_hud: Dictionary = world.farm.hud_state()
	_expect(after_hud.inventory == before_hud.inventory, "Settling backwards does not reduce inventory")

	_expect(world.advance_to(START + 2000.0).ok, "Forward advancement still works after a rollback")
	var growth_after: float = float(world.farm.get_cell("field_01", "cell_01").growth_seconds)
	_expect(growth_after >= growth_before, "Forward advancement never decreases growth")
	_expect(world.farm.hud_state().inventory == before_hud.inventory,
		"Advancement does not change inventory")


func _test_inf_without_future_stage() -> void:
	var mature := _open_world("mature")
	_expect(mature.advance_to(START + 10000.0).ok, "Mature fixture advances past every duration")
	_expect(is_inf(mature.next_event_utc()), "A mature world has no future event")

	var empty := _open_world("empty")
	_expect(empty.advance_to(START + 10000.0).ok, "Empty fixture advances past every duration")
	for field_id: String in ["field_03", "field_04", "field_05", "field_06"]:
		var harvest: Dictionary = empty.execute(FarmCommand.make(
			"empty-harvest-" + field_id, field_id, "cell_06", START + 10000.0))
		_expect(harvest.ok, "Empty fixture harvests " + field_id)
	_expect(_crop_cells(empty) == 0, "The empty fixture holds no crops")
	_expect(is_inf(empty.next_event_utc()), "A crop-free world has no future event")


func _open_world(name: String) -> RefCounted:
	var world := HeadlessWorld.new()
	var opened: Dictionary = world.open(test_root.path_join(name), START)
	_expect(opened.ok, "World opens: " + name)
	# Pin the seed so sibling fixtures share one weather history.
	world.nature = Nature.new(TEST_SEED)
	world.farm.set_environment(world.nature)
	return world


func _crop_cells(world: RefCounted) -> int:
	var count: int = 0
	var data: Dictionary = world.farm.snapshot()
	for field_id: String in data.fields:
		for cell_id: String in data.fields[field_id].cells:
			if not data.fields[field_id].cells[cell_id].crop_id.is_empty():
				count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS " + message)
	else:
		failures.append(message)
		print("FAIL " + message)
