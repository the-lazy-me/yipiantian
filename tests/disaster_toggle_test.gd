extends SceneTree
## M6-04 acceptance gap: the world-level disaster switch.
##
## "gentle" (the default) keeps the M6-03 derivation. "off" must stop every
## future event without changing weather, already-settled moisture or growth.
## The fixture covers the persisted document shape, rejection of bad values,
## a long no-disaster grow/harvest cycle against a never-affected reference,
## resumption without rollback, and authority/single-player parity.

const Farm = preload("res://farm/farm_state.gd")
const Nature = preload("res://farm/nature_state.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")

const START: float = 1800000000.0
const BLOCK: float = 21600.0
const DAY: float = 86400.0
const SEED: int = 424242

var checks: int = 0
var failures: Array[String] = []
var test_root: String


## Same weather sequence, no disaster answer at all: the "never happened" state.
class WeatherOnly extends RefCounted:
	var source: RefCounted

	func _init(value: RefCounted) -> void:
		source = value

	func weather_at(utc_seconds: float) -> Dictionary:
		return source.weather_at(utc_seconds)


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	test_root = project_root.get_base_dir().path_join(
		".local/verification/disaster-toggle-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_default_and_legacy_shape()
	_test_off_stops_future_events()
	_test_long_cycle_without_disasters()
	_test_invalid_values_rejected()
	_test_document_roundtrip()
	_test_authority_and_single_player()
	_test_resume_keeps_settled_state()
	for failure: String in failures:
		push_error(failure)
	print("DISASTER_TOGGLE_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_default_and_legacy_shape() -> void:
	var gentle := Nature.new(SEED)
	_expect(gentle.get_disaster_mode() == "gentle", "A new world defaults to gentle")
	_expect(gentle.snapshot() == {"seed": SEED, "rules_version": 2},
		"The default snapshot keeps the exact pre-switch two-key shape")
	var legacy := Nature.new()
	_expect(legacy.restore_snapshot({"seed": SEED, "rules_version": 2}),
		"A pre-switch document restores unchanged")
	_expect(legacy.get_disaster_mode() == "gentle",
		"A missing disaster_mode reads as the gentle default")
	_expect(legacy.restore_snapshot({"seed": SEED, "rules_version": 1}),
		"A version 1 document also restores with the gentle default")

	var off := Nature.new(SEED)
	_expect(off.set_disaster_mode("off"), "The switch accepts the off mode")
	_expect(off.get_disaster_mode() == "off", "The switch reports the off mode")
	var shape: Dictionary = off.snapshot()
	_expect(shape.size() == 3 and shape.disaster_mode == "off",
		"An off world writes the mode explicitly")
	var restored := Nature.new()
	_expect(restored.restore_snapshot(shape) and restored.get_disaster_mode() == "off",
		"The off mode survives a snapshot roundtrip")
	_expect(restored.snapshot() == shape, "A restored off snapshot stays byte-identical")

	var changed_weather: bool = false
	for offset: int in 400:
		var at: float = START + float(offset) * BLOCK
		if gentle.weather_at(at) != off.weather_at(at):
			changed_weather = true
	_expect(not changed_weather, "Turning disasters off never changes the weather sequence")


func _test_off_stops_future_events() -> void:
	var off := Nature.new(SEED)
	off.set_disaster_mode("off")
	var event_count: int = 0
	var weather_empty: bool = false
	for offset: int in 120 * Nature.BLOCKS_PER_DAY:
		var at: float = START + float(offset) * BLOCK
		if not off.disaster_at(at).is_empty():
			event_count += 1
		if off.weather_at(at).is_empty():
			weather_empty = true
	_expect(event_count == 0, "120 days with disasters off contain no event at any block")
	_expect(not weather_empty, "The weather view stays available with disasters off")
	var next_events: bool = false
	for hours: int in [0, 1, 6, 24, 120, 2400]:
		if off.next_disaster_at(START + float(hours) * 3600.0) != -1.0:
			next_events = true
	_expect(not next_events, "next_disaster_at is always -1 with disasters off")
	# The same seed with the default mode must still produce events, so the
	# empty result above is the switch and not a dead derivation.
	var gentle := Nature.new(SEED)
	_expect(_scan(gentle, START, 30) > 0, "The same seed still has disasters in gentle mode")


func _test_long_cycle_without_disasters() -> void:
	var off := Nature.new(SEED)
	off.set_disaster_mode("off")
	var reference := WeatherOnly.new(Nature.new(SEED))
	var disabled := Farm.new(START, {}, off)
	var never := Farm.new(START, {}, reference)
	for farm: RefCounted in [disabled, never]:
		_expect(farm.sow("field_01", "cell_01", "radish", START).ok,
			"The cycle fixture sows a radish")
	var target: float = START + 120.0 * DAY
	_expect(disabled.settle(target).ok, "A 120-day no-disaster span settles in one call")
	_expect(never.settle(target).ok, "The never-affected reference settles the same span")
	_expect(disabled.snapshot() == never.snapshot(),
		"Disasters off settles exactly like a world that never had one")
	_expect(disabled.get_cell("field_01", "cell_01").stage == "mature",
		"The sown crop matures through the no-disaster span")
	_expect(disabled.get_cell("field_03", "cell_06").stage == "mature",
		"The initial mature batch is untouched")
	var harvest: Dictionary = disabled.harvest("field_01", "cell_01", target)
	_expect(harvest.ok and int(harvest.reward_amount) == 1,
		"Harvest yields exactly one basket")
	_expect(not disabled.harvest("field_01", "cell_01", target).ok,
		"The same harvested cell cannot be harvested twice")
	var bounded: bool = true
	for field_id: String in disabled.snapshot().fields:
		for cell_id: String in disabled.snapshot().fields[field_id].cells:
			var moisture: float = float(disabled.get_cell(field_id, cell_id).moisture)
			if moisture < 0.0 or moisture > 1.0:
				bounded = false
	_expect(bounded, "Moisture stays inside [0, 1] for the whole span")


func _test_invalid_values_rejected() -> void:
	for bad: Variant in [true, 1, 0.0, "", "harsh", null, ["off"]]:
		_expect(not Nature.valid_disaster_mode(bad),
			"Invalid disaster mode is rejected: " + str(bad))
		var state: Dictionary = {"seed": SEED, "rules_version": 2, "disaster_mode": bad}
		_expect(not Nature.new().restore_snapshot(state),
			"A snapshot with an invalid mode is refused: " + str(bad))
	var guard := Nature.new(SEED)
	_expect(not guard.set_disaster_mode("harsh"), "The setter rejects an unknown mode")
	_expect(guard.get_disaster_mode() == "gentle", "A rejected setter leaves the mode unchanged")
	_expect(not guard.restore_snapshot({"seed": SEED, "rules_version": 2, "extra": true}),
		"An unknown extra key is still refused")
	_expect(not guard.restore_snapshot({"seed": SEED, "disaster_mode": "off"}),
		"A mode without a rules version is refused")
	_expect(guard.get_disaster_mode() == "gentle",
		"A refused restore does not leak a partial mode")


func _test_document_roundtrip() -> void:
	var path: String = test_root.path_join("roundtrip")
	var off := Nature.new(SEED)
	off.set_disaster_mode("off")
	var store := NatureStore.new(path)
	var saved: Dictionary = store.save_state(off.snapshot())
	_expect(saved.ok, "A disasters-off document saves")
	var loaded: Dictionary = NatureStore.new(path).load_state()
	_expect(loaded.ok and loaded.kind == "loaded", "The off document reloads")
	_expect(str(loaded.state.get("disaster_mode", "")) == "off",
		"The reloaded document keeps the off mode")
	_expect(Nature.new().restore_snapshot(loaded.state), "The reloaded state restores")
	var document: Variant = JSON.parse_string(FileAccess.get_file_as_string(path.path_join(NatureStore.MAIN)))
	_expect(document is Dictionary and int(document.version) == NatureStore.VERSION
		and int(document.state.rules_version) == Nature.RULES_VERSION,
		"The document keeps the existing version envelope")
	_expect(document.state.has("disaster_mode") and document.state.disaster_mode == "off",
		"The persisted state carries the explicit off mode")

	var gentle := Nature.new(SEED)
	_expect(NatureStore.new(path).save_state(gentle.snapshot()).ok,
		"A gentle document saves over the off one")
	document = JSON.parse_string(FileAccess.get_file_as_string(path.path_join(NatureStore.MAIN)))
	_expect(not document.state.has("disaster_mode") and document.state.size() == 2,
		"Returning to the default writes the pre-switch shape again")
	_expect(str(NatureStore.new(path).load_state().state.get("disaster_mode", "gentle")) == "gentle",
		"The rewritten document reads back as gentle")

	var broken_path: String = test_root.path_join("broken")
	DirAccess.make_dir_recursive_absolute(broken_path)
	var broken: String = JSON.stringify({"version": NatureStore.VERSION,
		"state": {"seed": SEED, "rules_version": 2, "disaster_mode": "harsh"}})
	var file := FileAccess.open(broken_path.path_join(NatureStore.MAIN), FileAccess.WRITE)
	file.store_string(broken)
	file.close()
	var refused: Dictionary = NatureStore.new(broken_path).load_state()
	_expect(not refused.ok and str(refused.kind) == "corrupt",
		"An unknown persisted mode is a corrupt document, not a silent default")
	_expect(FileAccess.get_file_as_string(broken_path.path_join(NatureStore.MAIN)) == broken,
		"A refused document is never rewritten")


func _test_authority_and_single_player() -> void:
	var directory: String = test_root.path_join("authority")
	var world := HeadlessWorld.new()
	_expect(world.open(directory, START).ok, "The authority opens an isolated world")
	world.nature = Nature.new(SEED)
	world.farm.set_environment(world.nature)
	var switched: Dictionary = world.set_disaster_mode("off")
	_expect(switched.ok, "The authority accepts the off mode")
	_expect(world.nature.get_disaster_mode() == "off", "The authority state holds the off mode")
	_expect(world.disaster_view() == {"disaster": {}, "warning": {}},
		"The authority disaster view is empty with disasters off")
	_expect(str(world.nature_view().disaster_mode) == "off",
		"The nature summary exposes the authoritative mode")
	_expect(world.set_disaster_mode("harsh").reason == "invalid_mode",
		"The authority refuses an unknown mode")
	_expect(world.set_disaster_mode("off").kind == "unchanged",
		"Setting the same mode is an honest no-op")

	var off := Nature.new(SEED)
	off.set_disaster_mode("off")
	var single := Farm.new(START, {}, off)
	_expect(single.sow("field_01", "cell_01", "carrot", START).ok,
		"The single-player fixture sows a carrot")
	_expect(world.farm.sow("field_01", "cell_01", "carrot", START).ok,
		"The authority fixture sows the same carrot")
	var target: float = START + 30.0 * DAY
	_expect(world.advance_to(target).ok, "The authority advances the span")
	_expect(single.settle(target).ok, "The single-player farm settles the same span")
	_expect(world.farm.snapshot() == single.snapshot(),
		"Authority and single-player settle identically with disasters off")
	_expect(world.save().ok, "The authority commits the no-disaster world")

	var reopened := HeadlessWorld.new()
	_expect(reopened.open(directory, target).ok, "The authority world reopens")
	_expect(reopened.nature.get_disaster_mode() == "off",
		"Reopening keeps the persisted off mode")
	_expect(reopened.disaster_view() == {"disaster": {}, "warning": {}},
		"The reopened authority still reports no disaster")
	_expect(reopened.farm.snapshot() == world.farm.snapshot(),
		"Reopening keeps the exact no-disaster farm state")


func _test_resume_keeps_settled_state() -> void:
	var off := Nature.new(SEED)
	off.set_disaster_mode("off")
	var farm := Farm.new(START, {}, off)
	farm.sow("field_01", "cell_01", "radish", START)
	var target: float = START + 10.0 * DAY
	_expect(farm.settle(target).ok, "The resume fixture settles ten no-disaster days")
	var settled: Dictionary = farm.snapshot()
	var moisture: float = float(farm.get_cell("field_01", "cell_01").moisture)

	var resumed := Nature.new()
	_expect(resumed.restore_snapshot(off.snapshot()), "The off document restores")
	_expect(resumed.set_disaster_mode("gentle"), "The world can be switched back to gentle")
	_expect(_scan(resumed, target, 30) > 0, "Future disasters resume from the same seed")
	farm.set_environment(resumed)
	_expect(farm.snapshot() == settled,
		"Re-enabling disasters does not roll back already-settled moisture or growth")
	_expect(farm.get_cell("field_01", "cell_01").moisture == moisture,
		"The settled moisture value is unchanged after resuming")
	_expect(farm.settle(target).ok and farm.snapshot() == settled,
		"Re-settling the same instant stays idempotent after resuming")


func _scan(nature: RefCounted, from_utc: float, days: int) -> int:
	var count: int = 0
	var blocks: int = days * Nature.BLOCKS_PER_DAY
	for index: int in blocks:
		if not nature.disaster_at(from_utc + float(index) * BLOCK).is_empty():
			count += 1
	return count


func _expect(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures.append(description)
