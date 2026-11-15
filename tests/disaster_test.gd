extends SceneTree
## M6-03: deterministic drought/storm, gentle-mode moisture effects and views.
##
## Pure rule checks use a scripted environment with the same 6-hour block shape
## NatureState owns; session checks use the real NatureState through
## HeadlessWorld. Fixtures stay below .local/verification.

const Farm = preload("res://farm/farm_state.gd")
const Nature = preload("res://farm/nature_state.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")

const START: float = 1800000000.0
const BLOCK: float = 21600.0
const DAY: float = 86400.0
const FIRST_INDEX: int = 83333
const FIRST_END: float = 1800014400.0
const SEED: int = 424242
const OTHER_SEED: int = 20261115
# Frozen before M6-03: the weather hash inputs must not change when the rules
# version is bumped, so a v1 document keeps exactly the same weather history.
const FROZEN_WEATHER: Array[String] = ["rain", "clear", "cloudy", "rain", "rain", "clear", "clear", "rain"]

var checks: int = 0
var failures: Array[String] = []
var test_root: String


class ScriptedEnvironment extends RefCounted:
	const BLOCK_SECONDS: float = 21600.0
	var weather: Dictionary = {}
	var disasters: Dictionary = {}
	var fallback: String = "clear"

	func _init(weather_by_index: Dictionary = {}, disasters_by_index: Dictionary = {},
			default_kind: String = "clear") -> void:
		weather = weather_by_index.duplicate(true)
		disasters = disasters_by_index.duplicate(true)
		fallback = default_kind

	func weather_at(utc_seconds: float) -> Dictionary:
		if not is_finite(utc_seconds) or utc_seconds < 0.0:
			return {}
		var index: int = int(floor(utc_seconds / BLOCK_SECONDS))
		var start: float = float(index) * BLOCK_SECONDS
		return {
			"index": index,
			"kind": str(weather.get(index, fallback)),
			"start_utc": start,
			"end_utc": start + BLOCK_SECONDS,
		}

	func disaster_at(utc_seconds: float) -> Dictionary:
		if not is_finite(utc_seconds) or utc_seconds < 0.0:
			return {}
		var index: int = int(floor(utc_seconds / BLOCK_SECONDS))
		var event: Variant = disasters.get(index)
		if not event is Dictionary:
			return {}
		var start: float = float(index) * BLOCK_SECONDS
		return {
			"kind": str(event.get("kind", "")),
			"start_utc": start,
			"end_utc": start + BLOCK_SECONDS,
			"severity": int(event.get("severity", 1)),
		}


## An M6-02-era source: weather only, no disaster method at all.
class WeatherOnly extends RefCounted:
	const BLOCK_SECONDS: float = 21600.0
	var kind: String = "clear"

	func _init(default_kind: String = "clear") -> void:
		kind = default_kind

	func weather_at(utc_seconds: float) -> Dictionary:
		if not is_finite(utc_seconds) or utc_seconds < 0.0:
			return {}
		var index: int = int(floor(utc_seconds / BLOCK_SECONDS))
		var start: float = float(index) * BLOCK_SECONDS
		return {
			"index": index, "kind": kind,
			"start_utc": start, "end_utc": start + BLOCK_SECONDS,
		}


class WeatherOnlyNature extends RefCounted:
	var nature: RefCounted

	func _init(source: RefCounted) -> void:
		nature = source

	func weather_at(utc_seconds: float) -> Dictionary:
		return nature.weather_at(utc_seconds)


## A malformed optional layer must be ignored, not trusted.
class WrongDisasterType extends WeatherOnly:
	func disaster_at(_utc_seconds: float) -> Variant:
		return "not a dictionary"


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	test_root = project_root.get_base_dir().path_join(
		".local/verification/disaster-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(test_root)
	_expect(is_equal_approx(BLOCK, Nature.WEATHER_SECONDS), "The scripted block matches NatureState")
	_test_weather_derivation_unchanged()
	_test_disaster_derivation()
	_test_spacing()
	_test_rules_version_upgrade()
	_test_moisture_deltas_at_boundaries()
	_test_split_invariance()
	_test_offline_bounds_and_mature_batch()
	_test_watering_mitigates_drought()
	_test_no_produce_change()
	_test_environment_variants()
	_test_summary_views()
	for failure: String in failures:
		push_error(failure)
	print("DISASTER_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_weather_derivation_unchanged() -> void:
	var nature := Nature.new(SEED)
	for offset: int in FROZEN_WEATHER.size():
		var event: Dictionary = nature.weather_at(START + float(offset) * BLOCK)
		_expect(str(event.kind) == FROZEN_WEATHER[offset],
			"Weather stays byte-identical to its pre-disaster derivation at block " + str(offset))
	_expect(nature.snapshot().size() == 2 and nature.snapshot().rules_version == 2,
		"The natural document still carries only the seed and the rules version")


func _test_disaster_derivation() -> void:
	var a := Nature.new(SEED)
	var b := Nature.new(SEED)
	var other := Nature.new(OTHER_SEED)
	var events_a: Array = _scan(a, START, 365)
	var events_b: Array = _scan(b, START, 365)
	_expect(JSON.stringify(events_a) == JSON.stringify(events_b),
		"Two owners with the same seed derive the same disaster sequence")
	_expect(events_a.size() >= 10, "A year of world history contains disasters")
	var kinds: Dictionary = {}
	for event: Dictionary in events_a:
		kinds[str(event.kind)] = true
	_expect(kinds.size() == 2 and kinds.has("drought") and kinds.has("storm"),
		"Both drought and storm are reachable")
	var differs: bool = false
	for event: Dictionary in _scan(other, START, 365):
		if not events_a.has(event):
			differs = true
	_expect(differs, "A different persisted seed derives a different disaster sequence")

	var at: float = float(events_a[0].start_utc)
	_expect(a.disaster_at(at) == a.disaster_at(at) and JSON.stringify(a.disaster_at(at)) == JSON.stringify(a.disaster_at(at)),
		"Repeated evaluation at the same instant is identical")
	var restored := Nature.new()
	_expect(restored.restore_snapshot({"seed": SEED, "rules_version": 2}),
		"A current snapshot restores")
	_expect(JSON.stringify(_scan(restored, START, 365)) == JSON.stringify(events_a),
		"Reloading the seed never rerolls the disaster sequence")
	_expect(is_equal_approx(a.next_disaster_at(START), float(events_a[0].start_utc))
		if int(events_a[0].start_utc) > int(START) else true,
		"The next disaster points at a derived block start")


func _test_spacing() -> void:
	var events: Array = _scan(Nature.new(SEED), START, 365)
	var windows: Dictionary = {}
	var previous_start: float = -1.0
	for event: Dictionary in events:
		var start: float = float(event.start_utc)
		var end: float = float(event.end_utc)
		_expect(is_equal_approx(end - start, BLOCK), "A disaster lasts exactly one 6-hour block")
		_expect(str(event.kind) in ["drought", "storm"], "Only the two declared kinds appear")
		_expect(int(event.severity) >= 1 and int(event.severity) <= Nature.DISASTER_MAX_SEVERITY,
			"Severity is a small display integer")
		var day_index: int = int(floor(start / DAY))
		var window_index: int = day_index / Nature.DISASTER_WINDOW_DAYS
		_expect(not windows.has(window_index),
			"No two disasters share a five-day window at " + str(window_index))
		windows[window_index] = true
		if previous_start >= 0.0:
			_expect(start - previous_start >= 5.0 * DAY,
				"Consecutive disasters stay at least five days apart")
		previous_start = start
	_expect(not events.is_empty(), "The spacing fixture contains real events")

	_expect(Nature.new(SEED).next_disaster_at(-1.0) == -1.0
		and Nature.new(SEED).next_disaster_at(INF) == -1.0,
		"Invalid look-ahead input returns -1")


func _test_rules_version_upgrade() -> void:
	var legacy := Nature.new()
	_expect(legacy.restore_snapshot({"seed": SEED, "rules_version": 1}),
		"A version 1 seed document is accepted")
	_expect(legacy.snapshot() == {"seed": SEED, "rules_version": 2},
		"The legacy seed is carried as the current version in memory")
	var current := Nature.new(SEED)
	var weather_same: bool = true
	for index: int in 400:
		var at: float = START + float(index) * BLOCK
		if JSON.stringify(legacy.weather_at(at)) != JSON.stringify(current.weather_at(at)):
			weather_same = false
	_expect(weather_same, "The same seed derives byte-identical weather before and after the upgrade")
	_expect(not legacy.restore_snapshot({"seed": SEED, "rules_version": 0})
		and not legacy.restore_snapshot({"seed": SEED, "rules_version": 3}),
		"Version 0 and newer versions are still refused")

	var folder: String = test_root.path_join("upgrade")
	DirAccess.make_dir_recursive_absolute(folder)
	var path: String = folder.path_join(NatureStore.MAIN)
	_write(path, JSON.stringify({"version": 1, "state": {"seed": SEED, "rules_version": 1}}))
	var loaded: Dictionary = NatureStore.new(folder).load_state()
	_expect(loaded.ok and loaded.kind == "loaded", "A version 1 document loads")
	_expect(loaded.state == {"seed": SEED, "rules_version": 2},
		"The loaded document is carried as version 2")
	_expect(NatureStore.new(folder).save_state(loaded.state).ok, "The upgraded document saves")
	var document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_expect(int(document.version) == 2 and int(document.state.rules_version) == 2,
		"The next save rewrites both the envelope and the state as version 2")
	_expect(NatureStore.new(folder).load_state().state == loaded.state,
		"The rewritten document reloads with the same seed")

	# Already-settled farm state must not be recomputed. Build a cell through
	# the old weather-only rules, restore it under the upgraded seed, and apply
	# exactly the one disaster block that starts afterwards.
	var nature := Nature.new(SEED)
	var event_start: float = nature.next_disaster_at(START)
	_expect(event_start >= 0.0, "The upgrade fixture finds a future disaster")
	if event_start < 0.0:
		return
	var event_weather: Dictionary = nature.weather_at(event_start)
	var event_disaster: Dictionary = nature.disaster_at(event_start)
	var pre := Farm.new(START, {}, WeatherOnlyNature.new(Nature.new(SEED)))
	pre.sow("field_01", "cell_01", "carrot", START)
	_expect(pre.settle(event_start).ok, "The pre-upgrade fixture settles through old blocks")
	var before_moisture: float = float(pre.get_cell("field_01", "cell_01").moisture)
	var upgraded := Farm.new()
	_expect(upgraded.restore_snapshot(pre.snapshot()), "The pre-upgrade farm restores")
	upgraded.set_environment(legacy)
	_expect(upgraded.get_cell("field_01", "cell_01").moisture == before_moisture,
		"Restoring an upgraded seed does not recompute already-settled blocks")
	var expected: float = clampf(before_moisture
		+ _weather_delta(str(event_weather.kind)) + _disaster_delta(str(event_disaster.kind)), 0.0, 1.0)
	_expect(upgraded.settle(float(event_disaster.end_utc)).ok, "The upgraded farm settles the disaster block")
	_expect(upgraded.get_cell("field_01", "cell_01").moisture == expected,
		"Only the block settled after the upgrade applies the disaster layer")
	var settled: Dictionary = upgraded.snapshot()
	upgraded.settle(float(event_disaster.end_utc))
	_expect(upgraded.snapshot() == settled, "Re-settling the same boundary is idempotent")


func _test_moisture_deltas_at_boundaries() -> void:
	var drought_clear := Farm.new(START, {},
		ScriptedEnvironment.new({FIRST_INDEX: "clear"}, {FIRST_INDEX: {"kind": "drought"}}))
	_expect(drought_clear.settle(FIRST_END - 1.0).ok, "The boundary fixture settles before the block end")
	_expect(drought_clear.get_cell("field_01", "cell_01").moisture == 0.5,
		"Settling inside the block does not apply the disaster")
	_expect(drought_clear.settle(FIRST_END).ok, "The boundary fixture settles at the exact block end")
	_expect(drought_clear.get_cell("field_01", "cell_01").moisture == 0.25,
		"Drought adds -1/8 on top of a clear block's -1/8")
	var applied: Dictionary = drought_clear.snapshot()
	drought_clear.settle(FIRST_END)
	_expect(drought_clear.snapshot() == applied, "The completed disaster applies once")

	var storm_rain := Farm.new(START, {},
		ScriptedEnvironment.new({FIRST_INDEX: "rain"}, {FIRST_INDEX: {"kind": "storm"}}))
	storm_rain.settle(FIRST_END)
	_expect(storm_rain.get_cell("field_01", "cell_01").moisture == 1.0,
		"Storm gain is capped at full moisture after the rain gain")

	var storm_clear := Farm.new(START, {},
		ScriptedEnvironment.new({FIRST_INDEX: "clear"}, {FIRST_INDEX: {"kind": "storm"}}))
	storm_clear.settle(FIRST_END)
	_expect(storm_clear.get_cell("field_01", "cell_01").moisture == 0.625,
		"Storm adds +1/4 on top of a clear block's -1/8")

	var drought_rain := Farm.new(START, {},
		ScriptedEnvironment.new({FIRST_INDEX: "rain"}, {FIRST_INDEX: {"kind": "drought"}}))
	drought_rain.settle(FIRST_END)
	_expect(drought_rain.get_cell("field_01", "cell_01").moisture == 0.625,
		"Drought subtracts 1/8 from the rain gain")

	var floor_env := ScriptedEnvironment.new(
		{FIRST_INDEX: "clear", FIRST_INDEX + 1: "clear"},
		{FIRST_INDEX: {"kind": "drought"}, FIRST_INDEX + 1: {"kind": "drought"}})
	var floor_farm := Farm.new(START, {}, floor_env)
	floor_farm.settle(FIRST_END + BLOCK)
	_expect(floor_farm.get_cell("field_01", "cell_01").moisture == 0.0,
		"Repeated drought stops at the dry floor instead of going negative")


func _test_split_invariance() -> void:
	var direct := HeadlessWorld.new()
	var stepped := HeadlessWorld.new()
	_expect(direct.open(test_root.path_join("direct"), START).ok, "The direct session opens")
	_expect(stepped.open(test_root.path_join("stepped"), START).ok, "The stepped session opens")
	for session: RefCounted in [direct, stepped]:
		session.nature = Nature.new(SEED)
		session.farm.set_environment(session.nature)
		_expect(session.farm.sow("field_01", "cell_01", "carrot", START).ok,
			"The split fixture sows a carrot")
		_expect(session.farm.water("field_01", "cell_01", START + 60.0).ok,
			"The split fixture waters early")
	var target: float = START + 30.0 * DAY
	_expect(_scan(direct.nature, START, 30).size() > 0,
		"The split fixture's month contains at least one disaster")
	_expect(direct.advance_to(target).ok, "The direct session advances once")
	var guard: int = 0
	while stepped.now_utc < target and guard < 1000:
		guard += 1
		var at: float = minf(stepped.nature.next_weather_at(stepped.now_utc), target)
		if at <= stepped.now_utc or not stepped.advance_to(at).ok:
			break
	_expect(stepped.now_utc == target, "The stepped session reaches the same target")
	_expect(direct.farm.snapshot() == stepped.farm.snapshot(),
		"One advance and weather-boundary steps produce an identical farm snapshot")
	_expect(JSON.stringify(direct.summary().fields) == JSON.stringify(stepped.summary().fields),
		"Both session paths expose the same moisture view")


func _test_offline_bounds_and_mature_batch() -> void:
	var farm := Farm.new(START, {}, Nature.new(SEED))
	farm.sow("field_01", "cell_01", "radish", START)
	var target: float = START + 365.0 * DAY
	var settled: Dictionary = farm.settle(target)
	_expect(settled.ok, "A year of offline time settles in one call")
	var bounded: bool = true
	for field_id: String in farm.snapshot().fields:
		for cell_id: String in farm.snapshot().fields[field_id].cells:
			var moisture: float = float(farm.get_cell(field_id, cell_id).moisture)
			if moisture < 0.0 or moisture > 1.0:
				bounded = false
	_expect(bounded, "Every cell's moisture stays inside [0, 1] across a year of disasters")
	var mature: Dictionary = farm.get_cell("field_03", "cell_06")
	_expect(str(mature.crop_id) == "greens" and mature.stage == "mature"
		and mature.growth_seconds == Farm.Crops.definition("greens").duration_seconds,
		"A mature batch survives long offline disasters intact")
	_expect(farm.get_cell("field_01", "cell_01").stage == "mature",
		"A crop keeps growing through disasters instead of dying")
	var harvest: Dictionary = farm.harvest("field_03", "cell_06", target)
	_expect(harvest.ok and int(harvest.reward_amount) == 1,
		"The protected mature batch still yields exactly one basket")


func _test_watering_mitigates_drought() -> void:
	var weather: Dictionary = {
		FIRST_INDEX: "clear", FIRST_INDEX + 1: "clear", FIRST_INDEX + 2: "clear",
	}
	var disasters: Dictionary = {FIRST_INDEX + 2: {"kind": "drought"}}
	var watered := Farm.new(START, {}, ScriptedEnvironment.new(weather, disasters))
	var dry := Farm.new(START, {}, ScriptedEnvironment.new(weather, disasters))
	for farm: RefCounted in [watered, dry]:
		_expect(farm.settle(FIRST_END + BLOCK).ok, "The drought fixture settles two clear blocks")
		_expect(farm.get_cell("field_01", "cell_01").moisture == 0.25,
			"Two clear blocks leave the cell dry")
		_expect(farm.sow("field_01", "cell_01", "carrot", FIRST_END + BLOCK).ok,
			"The drought fixture sows a carrot")
	_expect(watered.water("field_01", "cell_01", FIRST_END + BLOCK).ok,
		"Watering at the drought block start is accepted")
	_expect(watered.get_cell("field_01", "cell_01").moisture == 1.0
		and watered.get_cell("field_01", "cell_01").growth_rate == 1.0,
		"Watering immediately restores full moisture and the normal growth rate")
	_expect(dry.get_cell("field_01", "cell_01").growth_rate == 0.5,
		"The unwatered dry cell still grows at half rate")
	var wet_before: float = float(watered.get_cell("field_01", "cell_01").growth_seconds)
	var dry_before: float = float(dry.get_cell("field_01", "cell_01").growth_seconds)
	watered.settle(FIRST_END + BLOCK + 3600.0)
	dry.settle(FIRST_END + BLOCK + 3600.0)
	_expect(float(watered.get_cell("field_01", "cell_01").growth_seconds) - wet_before == 3600.0,
		"The watered cell grows normally through the drought block")
	_expect(float(dry.get_cell("field_01", "cell_01").growth_seconds) - dry_before == 1800.0,
		"The dry cell only reaches half growth in the same block")
	watered.settle(FIRST_END + 2.0 * BLOCK)
	dry.settle(FIRST_END + 2.0 * BLOCK)
	_expect(watered.get_cell("field_01", "cell_01").moisture == 0.75,
		"Watering leaves the cell at 3/4 after the drought block's deltas")
	_expect(dry.get_cell("field_01", "cell_01").moisture == 0.0,
		"The unwatered dry cell falls to the moisture floor")


func _test_no_produce_change() -> void:
	var nature := Nature.new(SEED)
	var farm := Farm.new(START, {}, nature)
	farm.sow("field_01", "cell_01", "radish", START)
	var before: Dictionary = farm.snapshot()
	var before_crops: String = _crop_map(before)
	var disposed: bool = _scan(nature, START, 30).size() > 0
	_expect(disposed, "The no-loss fixture's month actually contains disasters")
	_expect(farm.settle(START + 30.0 * DAY).ok, "The no-loss fixture advances a month")
	var after: Dictionary = farm.snapshot()
	_expect(after.inventory == before.inventory and after.harvested == before.harvested,
		"Disasters never change inventory or harvest totals")
	_expect(_crop_map(after) == before_crops, "Disasters never remove or replace a planted crop")
	_expect(farm.get_cell("field_04", "cell_06").stage == "mature",
		"An initial mature batch is not destroyed by a disaster")
	_expect(farm.harvest("field_04", "cell_06", START + 30.0 * DAY).ok,
		"The untouched mature batch can still be harvested once")


func _test_environment_variants() -> void:
	var legacy := Farm.new(START)
	legacy.sow("field_01", "cell_01", "carrot", START)
	_expect(legacy.settle(START + 3600.0).ok, "A farm without an environment still settles")
	_expect(legacy.get_cell("field_01", "cell_01").growth_seconds == 3600.0
		and legacy.get_cell("field_01", "cell_01").moisture == Farm.MOISTURE_DEFAULT,
		"No environment keeps the legacy additive rules and the stored moisture")

	var weather_only := Farm.new(START, {}, WeatherOnly.new("clear"))
	weather_only.settle(FIRST_END)
	_expect(weather_only.get_cell("field_01", "cell_01").moisture == 0.375,
		"A weather-only source applies only the weather delta")

	var empty_disaster := Farm.new(START, {},
		ScriptedEnvironment.new({FIRST_INDEX: "clear"}, {}))
	empty_disaster.settle(FIRST_END)
	_expect(empty_disaster.get_cell("field_01", "cell_01").moisture == 0.375,
		"An empty disaster answer applies no disaster delta")

	var wrong_type := Farm.new(START, {}, WrongDisasterType.new("clear"))
	wrong_type.settle(FIRST_END)
	_expect(wrong_type.get_cell("field_01", "cell_01").moisture == 0.375,
		"A non-dictionary disaster answer is ignored instead of trusted")

	var unknown := Farm.new(START, {},
		ScriptedEnvironment.new({FIRST_INDEX: "clear"}, {FIRST_INDEX: {"kind": "hail"}}))
	unknown.settle(FIRST_END)
	_expect(unknown.get_cell("field_01", "cell_01").moisture == 0.375,
		"An unknown disaster kind does not invent a second loss")


func _test_summary_views() -> void:
	var nature := Nature.new(SEED)
	var warning_start: float = nature.next_disaster_at(START)
	_expect(warning_start > 0.0, "The view fixture finds a future warning")
	if warning_start <= 0.0:
		return
	var world := HeadlessWorld.new()
	_expect(world.open(test_root.path_join("view"), warning_start - 10.0).ok,
		"The view session opens one block before the disaster")
	world.nature = Nature.new(SEED)
	world.farm.set_environment(world.nature)
	var view: Dictionary = world.summary().nature
	for key: String in ["weather", "next_weather_utc", "season", "daylight", "disaster", "warning"]:
		_expect(view.has(key), "The nature summary keeps the key: " + key)
	_expect((view.disaster as Dictionary).is_empty(), "No disaster covers the instant before it starts")
	var warning: Dictionary = view.warning
	_expect(not warning.is_empty(), "A disaster starting in the next block is warned")
	var expected_kind: String = str(nature.disaster_at(warning_start).kind)
	_expect(str(warning.kind) == expected_kind, "The warning carries the derived kind")
	_expect(is_equal_approx(float(warning.starts_utc), warning_start)
		and is_equal_approx(float(warning.ends_utc), warning_start + BLOCK),
		"The warning carries the exact block start and end")
	_expect(is_equal_approx(float(warning.lead_seconds), 10.0),
		"The warning carries the lead time to its start")
	_expect(world.disaster_view() == {"disaster": {}, "warning": warning},
		"The disaster view helper exposes the same warning")

	_expect(world.advance_to(warning_start).ok, "The session advances to the disaster start")
	var current: Dictionary = world.summary().nature
	_expect(not (current.disaster as Dictionary).is_empty(), "The current disaster appears in the summary")
	_expect(str(current.disaster.kind) == expected_kind, "The current disaster carries its kind")
	_expect(is_equal_approx(float(current.disaster.starts_utc), warning_start)
		and is_equal_approx(float(current.disaster.ends_utc), warning_start + BLOCK),
		"The current disaster carries the exact block range")
	_expect(int(current.disaster.severity) >= 1, "The current disaster carries its severity")
	_expect((current.warning as Dictionary).is_empty(), "No warning outside the preceding block")

	_expect(world.advance_to(warning_start + BLOCK + 1.0).ok, "The session advances past the disaster")
	_expect((world.summary().nature.disaster as Dictionary).is_empty(),
		"The disaster view empties after its one block")


func _scan(nature: RefCounted, from_utc: float, days: int) -> Array:
	var result: Array = []
	var blocks: int = days * Nature.BLOCKS_PER_DAY
	for index: int in blocks:
		var event: Dictionary = nature.disaster_at(from_utc + float(index) * BLOCK)
		if not event.is_empty():
			result.append(event)
	return result


func _crop_map(snapshot: Dictionary) -> String:
	var result: Dictionary = {}
	for field_id: String in snapshot.fields:
		for cell_id: String in snapshot.fields[field_id].cells:
			var crop_id: String = str(snapshot.fields[field_id].cells[cell_id].crop_id)
			if not crop_id.is_empty():
				result[field_id + "/" + cell_id] = crop_id
	return JSON.stringify(result)


static func _weather_delta(kind: String) -> float:
	match kind:
		"rain": return Farm.RAIN_MOISTURE_GAIN
		"cloudy": return -Farm.CLOUDY_MOISTURE_LOSS
		"clear": return -Farm.CLEAR_MOISTURE_LOSS
	return 0.0


static func _disaster_delta(kind: String) -> float:
	match kind:
		"drought": return -Farm.DROUGHT_MOISTURE_LOSS
		"storm": return Farm.STORM_MOISTURE_GAIN
	return 0.0


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
