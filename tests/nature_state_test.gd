extends SceneTree
## M6-01: fixed natural time semantics.
##
## Proves that weather is derived from a persisted seed and a UTC instant, not
## sampled on load: identical repeated evaluation, identical segmented and
## one-shot advancement, identical sequences after a save/reload, and identical
## days/seasons/weather across the online and offline paths. Fixtures stay below
## .local/verification.

const Nature = preload("res://farm/nature_state.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Farm = preload("res://farm/farm_state.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const FarmCommand = preload("res://farm/farm_command.gd")

const START: float = 1800000000.0
const SEED_A: int = 424242
const SEED_B: int = 98765

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	test_root = project_root.get_base_dir().path_join(
		".local/verification/nature-state-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_determinism()
	_test_intervals_and_boundaries()
	_test_daylight_and_seasons()
	_test_invalid_inputs()
	_test_snapshot_roundtrip()
	_test_store_roundtrip()
	_test_headless_reload_and_advance_paths()
	_test_first_creation_race_keeps_winner_seed()
	_test_legacy_world_without_nature_document()
	for failure: String in failures:
		push_error(failure)
	print("NATURE_STATE_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_determinism() -> void:
	var a := Nature.new(SEED_A)
	var b := Nature.new(SEED_A)
	var c := Nature.new(SEED_B)
	for offset: float in [0.0, 1.0, 3600.0, Nature.WEATHER_SECONDS, Nature.DAY_SECONDS, Nature.SEASON_SECONDS, 30.0 * Nature.DAY_SECONDS]:
		var at: float = START + offset
		_expect(JSON.stringify(a.weather_at(at)) == JSON.stringify(a.weather_at(at)),
			"Repeated evaluation at the same instant is identical")
		_expect(JSON.stringify(a.weather_at(at)) == JSON.stringify(b.weather_at(at)),
			"Two owners with the same seed derive the same event")
	var kinds: Dictionary = {}
	var differs: bool = false
	for index: int in 64:
		var at: float = START + float(index) * Nature.WEATHER_SECONDS
		var event_a: Dictionary = a.weather_at(at)
		var event_b: Dictionary = c.weather_at(at)
		kinds[event_a.kind] = true
		if event_a != event_b:
			differs = true
	_expect(kinds.size() >= 2, "The weather sequence uses more than one kind")
	_expect(differs, "A different persisted seed derives a different sequence")


func _test_intervals_and_boundaries() -> void:
	var nature := Nature.new(SEED_A)
	var at: float = START + 12345.0
	var event: Dictionary = nature.weather_at(at)
	_expect(not event.is_empty(), "A valid instant has a weather event")
	_expect(float(event.start_utc) <= at and at < float(event.end_utc),
		"The event interval contains its instant")
	_expect(is_equal_approx(float(event.end_utc) - float(event.start_utc), Nature.WEATHER_SECONDS),
		"Every weather block has the fixed length")
	var at_start: Dictionary = nature.weather_at(float(event.start_utc))
	_expect(int(at_start.index) == int(event.index),
		"The start instant belongs to its own event")
	var before_end: Dictionary = nature.weather_at(float(event.end_utc) - 0.001)
	_expect(int(before_end.index) == int(event.index),
		"Just before the end is still the same event")
	var at_end: Dictionary = nature.weather_at(float(event.end_utc))
	_expect(int(at_end.index) == int(event.index) + 1,
		"The end instant starts the next event")
	_expect(is_equal_approx(float(at_end.start_utc), float(event.end_utc)),
		"The next event starts exactly where the previous one ends")
	_expect(is_equal_approx(nature.next_weather_at(at), float(event.end_utc)),
		"The next weather instant is the current event's end")
	_expect(is_equal_approx(nature.next_weather_at(float(event.end_utc)), float(at_end.end_utc)),
		"At a boundary the next weather instant is the following block's end")

	var midnight: float = floorf(START / Nature.DAY_SECONDS) * Nature.DAY_SECONDS + Nature.DAY_SECONDS
	var cross_day: Dictionary = nature.weather_at(midnight - 0.001)
	var cross_day_end: Dictionary = nature.weather_at(midnight)
	_expect(is_equal_approx(float(cross_day.end_utc), midnight) \
			and is_equal_approx(float(cross_day_end.start_utc), midnight),
		"A 6-hour block boundary crosses UTC midnight without a gap or overlap")
	_expect(int(nature.daylight_at(midnight).day_index) == int(nature.daylight_at(midnight - 0.001).day_index) + 1,
		"The real day index advances at UTC midnight")


func _test_daylight_and_seasons() -> void:
	var nature := Nature.new(SEED_A)
	var day_start: float = floorf(START / Nature.DAY_SECONDS) * Nature.DAY_SECONDS
	_expect(nature.daylight_at(day_start + 5.0 * 3600.0).phase == "night",
		"05:00 UTC is night")
	_expect(nature.daylight_at(day_start + 6.0 * 3600.0).phase == "day",
		"06:00 UTC starts the fixed day window")
	_expect(nature.daylight_at(day_start + 17.0 * 3600.0 + 3599.0).phase == "day",
		"Just before 18:00 UTC is still day")
	_expect(nature.daylight_at(day_start + 18.0 * 3600.0).phase == "night",
		"18:00 UTC starts the fixed night window")
	_expect(nature.daylight_at(day_start + 1.0).phase == "night",
		"UTC midnight is night without consulting a system timezone")

	_expect(nature.agricultural_day_at(day_start + Nature.DAY_SECONDS - 1.0) == int(floorf(day_start / Nature.DAY_SECONDS)),
		"Agricultural time keeps the existing 1:1 UTC growth day")
	_expect(nature.agricultural_day_at(day_start + Nature.DAY_SECONDS) == int(floorf(day_start / Nature.DAY_SECONDS)) + 1,
		"Agricultural day advances with UTC, not with a season clock")

	var next_season: float = (floorf(START / Nature.SEASON_SECONDS) + 1.0) * Nature.SEASON_SECONDS
	var before: Dictionary = nature.season_at(next_season - 0.001)
	var at: Dictionary = nature.season_at(next_season)
	_expect(int(at.season_index) == int(before.season_index) + 1,
		"The season advances exactly at the fixed boundary")
	_expect(int(at.day_in_season) == 0, "A season boundary starts at day zero")
	_expect(before.id == Nature.SEASON_IDS[int(before.index)],
		"The season label comes from the fixed cycle")
	var wrapped: Dictionary = nature.season_at(next_season + 4.0 * Nature.SEASON_SECONDS)
	_expect(int(wrapped.index) == int(at.index) and int(wrapped.season_index) == int(at.season_index) + 4,
		"The season label repeats after four seasons")


func _test_invalid_inputs() -> void:
	var nature := Nature.new(SEED_A)
	for value: float in [-1.0, NAN, INF, -INF, 1.0e18]:
		_expect(nature.weather_at(value).is_empty(), "Invalid weather input is rejected")
		_expect(nature.daylight_at(value).is_empty(), "Invalid daylight input is rejected")
		_expect(nature.season_at(value).is_empty(), "Invalid season input is rejected")
		_expect(is_inf(nature.next_weather_at(value)), "Invalid next-weather input returns INF")
		_expect(nature.agricultural_day_at(value) == -1, "Invalid agricultural input returns -1")

	var invalid_states: Array = [
		{},
		{"seed": 1},
		{"rules_version": 1},
		{"seed": -1, "rules_version": 1},
		{"seed": 1.5, "rules_version": 1},
		{"seed": float(Nature.MAX_SEED) + 1.0, "rules_version": 1},
		{"seed": "1", "rules_version": 1},
		{"seed": 1, "rules_version": 0},
		{"seed": 1, "rules_version": 1, "extra": true},
	]
	for state: Dictionary in invalid_states:
		_expect(not Nature.new().restore_snapshot(state),
			"Invalid nature snapshot rejected: " + JSON.stringify(state))
	_expect(Nature.new().restore_snapshot({"seed": 7.0, "rules_version": 1.0}),
		"JSON integral floats are accepted as the same seed and version")


func _test_snapshot_roundtrip() -> void:
	var nature := Nature.new(SEED_A)
	var text: String = JSON.stringify(nature.snapshot())
	var parsed: Variant = JSON.parse_string(text)
	var restored := Nature.new()
	_expect(restored.restore_snapshot(parsed), "A JSON-parsed snapshot restores")
	_expect(JSON.stringify(restored.snapshot()) == text,
		"A snapshot is byte-identical after a JSON roundtrip")
	for offset: float in [0.0, 12345.0, Nature.DAY_SECONDS, 10.0 * Nature.DAY_SECONDS]:
		var at: float = START + offset
		_expect(JSON.stringify(restored.weather_at(at)) == JSON.stringify(nature.weather_at(at)),
			"A restored owner derives the same event")
		_expect(restored.daylight_at(at) == nature.daylight_at(at),
			"A restored owner derives the same daylight")
		_expect(restored.season_at(at) == nature.season_at(at),
			"A restored owner derives the same season")


func _test_store_roundtrip() -> void:
	var folder: String = test_root.path_join("store")
	var store := NatureStore.new(folder)
	var missing: Dictionary = store.load_state()
	_expect(missing.ok and missing.kind == "missing", "A new store has no nature document")
	_expect(missing.state == Nature.default_snapshot(),
		"A missing document yields the fixed default seed, not a random roll")
	var nature := Nature.new(SEED_A)
	_expect(store.save_state(nature.snapshot()).ok, "The nature document saves")
	var path: String = folder.path_join(NatureStore.MAIN)
	_expect(FileAccess.file_exists(path), "The nature document is written beside the farm")
	var loaded: Dictionary = NatureStore.new(folder).load_state()
	_expect(loaded.ok and loaded.kind == "loaded", "The nature document reloads")
	_expect(JSON.stringify(loaded.state) == JSON.stringify(nature.snapshot()),
		"The reloaded seed document is byte-identical")
	var restored := Nature.new()
	_expect(restored.restore_snapshot(loaded.state), "The loaded document restores")
	_expect(restored.weather_at(START + 5000.0) == nature.weather_at(START + 5000.0),
		"The reloaded seed derives the same event")

	var corrupt_text: String = JSON.stringify({"version": NatureStore.VERSION, "state": {"seed": -3, "rules_version": 1}})
	_write(path, corrupt_text)
	var corrupt: Dictionary = NatureStore.new(folder).load_state()
	_expect(not corrupt.ok and corrupt.kind == "corrupt", "A corrupt seed document is refused")
	_expect(FileAccess.get_file_as_string(path) == corrupt_text,
		"A refused nature load preserves the bytes for diagnosis")
	var future_text: String = JSON.stringify({"version": NatureStore.VERSION + 1, "state": nature.snapshot()})
	_write(path, future_text)
	var future: Dictionary = NatureStore.new(folder).load_state()
	_expect(not future.ok and future.kind == "unsupported",
		"A future nature document is distinguished from damage")
	_expect(not NatureStore.new(folder).save_state({"seed": -1, "rules_version": 1}).ok,
		"The store refuses to write an invalid seed")


func _test_headless_reload_and_advance_paths() -> void:
	var folder: String = test_root.path_join("world")
	var world := HeadlessWorld.new()
	var opened: Dictionary = world.open(folder, START)
	_expect(opened.ok and opened.kind == "created", "A new headless world starts")
	_expect(world.nature != null, "The world owns a nature rule owner")
	var seed: int = world.nature.get_seed()
	_expect(Nature.valid_seed(seed), "A created world has a valid persisted seed")
	_expect(world.save().ok, "The first save persists the world")
	_expect(FileAccess.file_exists(folder.path_join(NatureStore.MAIN)),
		"The nature seed is persisted beside the farm save")

	var reopened := HeadlessWorld.new()
	var reloaded: Dictionary = reopened.open(folder, START)
	_expect(reloaded.ok and reloaded.kind == "loaded", "The saved world reopens")
	_expect(reopened.nature.snapshot() == world.nature.snapshot(),
		"Reloading keeps the same seed instead of sampling a new one")
	var sequence_before: Array = _events(world.nature, START, START + 10.0 * Nature.DAY_SECONDS)
	var sequence_after: Array = _events(reopened.nature, START, START + 10.0 * Nature.DAY_SECONDS)
	_expect(sequence_before == sequence_after,
		"The ten-day weather sequence is unchanged across a save and reload")
	_expect(JSON.stringify(world.state_snapshot()) == JSON.stringify(reopened.state_snapshot()),
		"The restorable snapshot is byte-identical after a save and reload")

	var target: float = START + 3.0 * Nature.DAY_SECONDS
	var one_shot := HeadlessWorld.new()
	var stepped := HeadlessWorld.new()
	_expect(one_shot.open(folder, START).ok, "The one-shot path opens the world")
	_expect(stepped.open(folder, START).ok, "The segmented path opens the same world")
	_expect(one_shot.advance_to(target).ok, "One advance reaches the target")
	var step: float = 1800.0
	var guard: int = 0
	while stepped.now_utc < target and guard < 1000:
		guard += 1
		var next: float = minf(stepped.now_utc + step, target)
		if not stepped.advance_to(next).ok:
			break
	_expect(stepped.now_utc == target, "Segmented advancement reaches the target")
	_expect(one_shot.farm.snapshot() == stepped.farm.snapshot(),
		"Online segmented and offline one-shot advancement agree on farm state")
	_expect(JSON.stringify(one_shot.state_snapshot()) == JSON.stringify(stepped.state_snapshot()),
		"Both advancement paths end in the same restorable state")
	_expect(one_shot.nature.weather_at(target) == stepped.nature.weather_at(target),
		"Both advancement paths see the same event at the target")
	_expect(_events(one_shot.nature, START, target) == _events(stepped.nature, START, target),
		"Both advancement paths derive the same event sequence")
	var summary: Dictionary = one_shot.summary()
	_expect(not (summary.get("nature", {}) as Dictionary).is_empty(),
		"The summary exposes the read-only natural-time interpretation")
	_expect(int(summary.nature.weather.index) == int(one_shot.nature.weather_at(target).index),
		"The summary event matches the authoritative instant")
	_expect(is_equal_approx(float(summary.nature.next_weather_utc), one_shot.nature.next_weather_at(target)),
		"The summary's next event is the same derived boundary")


func _test_first_creation_race_keeps_winner_seed() -> void:
	# Two authorities may start from the same missing directory. The farm store
	# refuses the loser's commit; the nature seed must follow the winner instead
	# of being overwritten before that refusal.
	var folder: String = test_root.path_join("race")
	var winner := HeadlessWorld.new()
	var loser := HeadlessWorld.new()
	var winner_opened: Dictionary = winner.open(folder, START)
	_expect(winner_opened.ok and winner_opened.kind == "created",
		"The race winner starts a new world")
	var loser_opened: Dictionary = loser.open(folder, START)
	_expect(loser_opened.ok and loser_opened.kind == "created",
		"The race loser also starts from the same missing directory")
	var winning_command: Dictionary = FarmCommand.make_sow("race-a", "field_01", "cell_01", "greens", START)
	_expect(winner.execute(winning_command).ok, "The first creator commits")
	var winning_seed: int = winner.nature.get_seed()
	var losing_command: Dictionary = FarmCommand.make_sow("race-b", "field_02", "cell_01", "greens", START)
	var stale: Dictionary = loser.execute(losing_command)
	_expect(not stale.ok and stale.reason == "save_changed_on_disk",
		"The stale first creator is refused by the expected-file check")
	_expect(loser.nature.get_seed() == winning_seed,
		"The stale creator adopts the winner's seed instead of writing its own")
	var reopened := HeadlessWorld.new()
	_expect(reopened.open(folder, START).ok and reopened.nature.get_seed() == winning_seed,
		"The persisted seed is still the winner's")


func _test_legacy_world_without_nature_document() -> void:
	var folder: String = test_root.path_join("legacy")
	var store := FarmStore.new(folder)
	_expect(store.load_state().kind == "missing", "The legacy fixture starts empty")
	_expect(store.save(Farm.new(START).snapshot(), Decorations.new().snapshot()).ok,
		"A save without a nature document is committed")
	_expect(not FileAccess.file_exists(folder.path_join(NatureStore.MAIN)),
		"The legacy fixture has no nature document")

	var world := HeadlessWorld.new()
	var opened: Dictionary = world.open(folder, START)
	_expect(opened.ok and opened.kind == "loaded", "A legacy world still opens")
	_expect(world.nature.get_seed() == Nature.DEFAULT_SEED,
		"A missing nature document uses the fixed default seed, never a new roll")
	_expect(world.save().ok, "The legacy world saves again")
	_expect(FileAccess.file_exists(folder.path_join(NatureStore.MAIN)),
		"The default seed is persisted on the next save")
	var reopened := HeadlessWorld.new()
	_expect(reopened.open(folder, START).ok, "The upgraded legacy world reopens")
	_expect(reopened.nature.snapshot() == world.nature.snapshot(),
		"The legacy world keeps the same deterministic sequence after upgrade")
	var command: Dictionary = FarmCommand.make_sow("legacy-sow", "field_01", "cell_01", "greens", START)
	_expect(world.execute(command).ok, "The legacy world still commits commands")
	_expect(world.nature.snapshot() == reopened.nature.snapshot(),
		"A command doesn't alter the persisted nature seed")


func _events(nature: RefCounted, from_utc: float, to_utc: float) -> Array:
	var result: Array = []
	var cursor: float = from_utc
	var guard: int = 0
	while cursor < to_utc and guard < 10000:
		guard += 1
		var event: Dictionary = nature.weather_at(cursor)
		if event.is_empty():
			break
		result.append(event)
		cursor = float(event.end_utc)
	return result


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null)
	file.store_string(text)
	file.close()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS " + message)
	else:
		failures.append(message)
		print("FAIL " + message)
