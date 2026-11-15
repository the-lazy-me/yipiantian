extends SceneTree
## M6-02: regional rain, cell moisture and bounded growth.
##
## Pure rule checks use a scripted weather source with the same 6-hour block
## shape NatureState owns. The session check uses the real NatureState through
## HeadlessWorld, proving that weather-block boundaries are advance segments.
## Fixtures stay below .local/verification.

const Farm = preload("res://farm/farm_state.gd")
const Nature = preload("res://farm/nature_state.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")

const START: float = 1800000000.0
const BLOCK: float = 21600.0
const FIRST_INDEX: int = 83333
const FIRST_END: float = 1800014400.0
const SEED: int = 424242

var checks: int = 0
var failures: Array[String] = []
var test_root: String


## A weather source with the same contract NatureState exposes. Only the block
## kind is scripted; boundaries still fall on absolute six-hour UTC marks.
class ScriptedWeather extends RefCounted:
	const BLOCK_SECONDS: float = 21600.0
	var kinds: Dictionary = {}
	var fallback: String = "clear"

	func _init(by_index: Dictionary = {}, default_kind: String = "clear") -> void:
		kinds = by_index.duplicate()
		fallback = default_kind

	func weather_at(utc_seconds: float) -> Dictionary:
		if not is_finite(utc_seconds) or utc_seconds < 0.0:
			return {}
		var index: int = int(floor(utc_seconds / BLOCK_SECONDS))
		var start: float = float(index) * BLOCK_SECONDS
		return {
			"index": index,
			"kind": str(kinds.get(index, fallback)),
			"start_utc": start,
			"end_utc": start + BLOCK_SECONDS,
		}


class BrokenWeather extends RefCounted:
	func weather_at(_utc_seconds: float) -> Dictionary:
		return {}


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	test_root = project_root.get_base_dir().path_join(
		".local/verification/rain-moisture-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(test_root)
	_expect(is_equal_approx(BLOCK, Nature.WEATHER_SECONDS), "The scripted block matches NatureState")
	_expect(Farm.MOISTURE_DEFAULT >= Farm.MOISTURE_GROWTH_THRESHOLD,
		"A fresh cell is not immediately penalised")
	_test_rain_and_clear_growth()
	_test_moisture_across_blocks()
	_test_watering_changes_local_moisture()
	_test_segmented_equals_one_shot()
	_test_long_offline_and_no_death()
	_test_session_weather_boundaries()
	_test_critical_watering_and_yield()
	_test_legacy_cell_shape_and_defaults()
	_test_invalid_and_boundary_input()
	_test_environment_without_disaster_support()
	for failure: String in failures:
		push_error(failure)
	print("RAIN_MOISTURE_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_rain_and_clear_growth() -> void:
	# Four clear blocks first dry the default soil, then the measured block is
	# rain for one farm and clear for the other.
	var pattern_rain: Dictionary = {}
	var pattern_clear: Dictionary = {}
	for offset: int in range(0, 4):
		pattern_rain[FIRST_INDEX + offset] = "clear"
		pattern_clear[FIRST_INDEX + offset] = "clear"
	pattern_rain[FIRST_INDEX + 4] = "rain"
	pattern_clear[FIRST_INDEX + 4] = "clear"
	var rain := Farm.new(START, {}, ScriptedWeather.new(pattern_rain))
	var clear := Farm.new(START, {}, ScriptedWeather.new(pattern_clear))
	var sow_at: float = FIRST_END + 3.0 * BLOCK
	for farm: RefCounted in [rain, clear]:
		farm.settle(sow_at)
		_expect(farm.get_cell("field_01", "cell_01").moisture < Farm.MOISTURE_GROWTH_THRESHOLD,
			"Three clear blocks dry the default soil")
		_expect(farm.sow("field_01", "cell_01", "carrot", sow_at).ok, "A carrot is sown for both weather blocks")
	rain.settle(sow_at + 3600.0)
	clear.settle(sow_at + 3600.0)
	var rain_growth: float = rain.get_cell("field_01", "cell_01").growth_seconds
	var clear_growth: float = clear.get_cell("field_01", "cell_01").growth_seconds
	_expect(rain_growth == 3600.0, "A rain block grows at the normal rate")
	_expect(clear_growth == 1800.0, "Clear weather on dry soil grows at half rate")
	_expect(clear.get_cell("field_01", "cell_01").growth_rate == 0.5,
		"The cell view reports the dry growth rate")
	_expect(clear.get_cell("field_01", "cell_01").moisture_label == "dry",
		"The dry soil is labelled for the player")
	_expect(rain.get_cell("field_01", "cell_01").growth_rate == 1.0,
		"Rain restores the normal rate without waiting for the next block")


func _test_moisture_across_blocks() -> void:
	var weather := ScriptedWeather.new({FIRST_INDEX: "clear", FIRST_INDEX + 1: "rain", FIRST_INDEX + 2: "cloudy"})
	var farm := Farm.new(START, {}, weather)
	_expect(farm.get_cell("field_01", "cell_01").moisture == Farm.MOISTURE_DEFAULT,
		"A new cell starts at the default moisture")
	farm.settle(FIRST_END)
	_expect(farm.get_cell("field_01", "cell_01").moisture == 0.375,
		"A completed clear block removes one eighth")
	_expect(farm.get_cell("field_01", "cell_01").moisture_label == "dry",
		"Below the growth threshold the cell reads dry")
	farm.settle(FIRST_END + BLOCK)
	_expect(farm.get_cell("field_01", "cell_01").moisture == 0.625,
		"A completed rain block adds exactly one quarter")
	_expect(farm.get_cell("field_01", "cell_01").moisture_label == "damp",
		"Half to three quarters is labelled damp")
	farm.settle(FIRST_END + 2.0 * BLOCK)
	_expect(farm.get_cell("field_01", "cell_01").moisture == 0.5625,
		"A completed cloudy block removes one sixteenth")
	farm.settle(FIRST_END + 2.0 * BLOCK + 1000.0)
	_expect(farm.get_cell("field_01", "cell_01").moisture == 0.5625,
		"A settlement inside a block does not change moisture")
	for label: String in ["dry", "damp", "wet"]:
		_expect(Farm.moisture_label({"dry": 0.0, "damp": 0.5, "wet": 1.0}[label]) == label,
			"Moisture labels are ordered and bounded: " + label)


func _test_watering_changes_local_moisture() -> void:
	var weather := ScriptedWeather.new({}, "clear")
	var watered := Farm.new(START, {}, weather)
	var untouched := Farm.new(START, {}, weather)
	# Empty cells lose moisture too, so a full dry block happens before sowing.
	watered.settle(FIRST_END)
	untouched.settle(FIRST_END)
	_expect(watered.get_cell("field_01", "cell_01").moisture == 0.375,
		"A full clear block dries the cell below the default")
	_expect(watered.get_cell("field_01", "cell_01").moisture_label == "dry",
		"Below the growth threshold the cell reads dry")
	_expect(watered.sow("field_01", "cell_01", "carrot", FIRST_END).ok, "The watering fixture sows a carrot")
	_expect(untouched.sow("field_01", "cell_01", "carrot", FIRST_END).ok, "The dry fixture sows a carrot")
	var action: Dictionary = watered.water("field_01", "cell_01", FIRST_END)
	_expect(action.ok, "Watering a growing dry crop is accepted")
	_expect(watered.get_cell("field_01", "cell_01").moisture == Farm.MOISTURE_MAX,
		"Watering saturates only that cell")
	_expect(watered.get_cell("field_01", "cell_01").moisture_label == "wet",
		"The watered cell reads wet")
	_expect(untouched.get_cell("field_01", "cell_01").moisture == 0.375,
		"A neighbouring fixture keeps its own moisture")
	var before: float = watered.get_cell("field_01", "cell_01").growth_seconds
	var dry_before: float = untouched.get_cell("field_01", "cell_01").growth_seconds
	watered.settle(FIRST_END + 3600.0)
	untouched.settle(FIRST_END + 3600.0)
	var wet_gain: float = watered.get_cell("field_01", "cell_01").growth_seconds - before
	var dry_gain: float = untouched.get_cell("field_01", "cell_01").growth_seconds - dry_before
	_expect(wet_gain == 3600.0, "Watered soil grows at the normal rate")
	_expect(dry_gain == 1800.0, "Dry soil grows at the half rate")
	_expect(wet_gain > dry_gain, "Watering is visible as faster growth without changing yield")
	_expect(watered.get_cell("field_01", "cell_01").growth_rate == 1.0
		and untouched.get_cell("field_01", "cell_01").growth_rate == 0.5,
		"The cell views explain the current growth rate")


func _test_segmented_equals_one_shot() -> void:
	var pattern: Dictionary = {
		FIRST_INDEX: "rain",
		FIRST_INDEX + 1: "clear",
		FIRST_INDEX + 2: "cloudy",
		FIRST_INDEX + 3: "rain",
	}
	var one_shot := Farm.new(START, {}, ScriptedWeather.new(pattern))
	var stepped := Farm.new(START, {}, ScriptedWeather.new(pattern))
	for farm: RefCounted in [one_shot, stepped]:
		_expect(farm.sow("field_01", "cell_01", "celery", START).ok, "The segmented fixture sows celery")
		_expect(farm.water("field_01", "cell_01", START + 900.0).ok, "The segmented fixture waters early")
	var target: float = FIRST_END + 3.0 * BLOCK + 1234.0
	one_shot.settle(target)
	var at: float = START + 700.0
	while at < target:
		stepped.settle(at)
		at += 700.0
	stepped.settle(target)
	_expect(one_shot.snapshot() == stepped.snapshot(),
		"One settlement and 700-second segments produce an identical snapshot")
	_expect(one_shot.get_cell("field_01", "cell_01") == stepped.get_cell("field_01", "cell_01"),
		"Growth, moisture and derived labels agree item by item")
	_expect(one_shot.snapshot().fields.size() == 7 and one_shot.get_cell("field_01", "cell_01").moisture >= 0.0,
		"The whole farm including empty cells settles through the weather")


func _test_long_offline_and_no_death() -> void:
	var weather := ScriptedWeather.new({}, "clear")
	var one_shot := Farm.new(START, {}, weather)
	var stepped := Farm.new(START, {}, weather)
	for farm: RefCounted in [one_shot, stepped]:
		_expect(farm.sow("field_01", "cell_01", "radish", START).ok, "A radish is sown for the long offline fixture")
	var target: float = START + 30.0 * 86400.0
	one_shot.settle(target)
	var at: float = START
	while at < target:
		at = minf(at + BLOCK, target)
		stepped.settle(at)
	_expect(one_shot.snapshot() == stepped.snapshot(),
		"Thirty days of clear weather settle identically one-shot and in blocks")
	var cell: Dictionary = one_shot.get_cell("field_01", "cell_01")
	_expect(cell.moisture == 0.0, "Long clear weather reaches the bounded dry floor")
	_expect(cell.moisture_label == "dry", "The dry floor is explained to the player")
	_expect(cell.stage == "mature", "Dry weather slows but never kills a crop")
	_expect(cell.growth_rate == 0.5, "Dry weather caps the slowdown at half rate")
	_expect(one_shot.harvest("field_01", "cell_01", target).ok,
		"A crop that matured slowly under dry weather still yields one basket")


func _test_session_weather_boundaries() -> void:
	var folder: String = test_root.path_join("session")
	var world := HeadlessWorld.new()
	var opened: Dictionary = world.open(folder, START)
	_expect(opened.ok, "A headless session opens")
	# Remove growth events so the only remaining segmentation is weather.
	world.farm.mature_all_crops(START)
	var advanced: Dictionary = world.advance_to(START + 86400.0)
	var boundaries: int = int(ceilf((START + 86400.0 - START) / BLOCK))
	_expect(advanced.ok and world.now_utc == START + 86400.0,
		"The session reaches a target beyond several weather blocks")
	_expect(int(advanced.get("segments", 0)) == boundaries + 1,
		"The session settles once per weather boundary and once at the target")
	_expect(world.farm.get_cell("field_01", "cell_01").moisture >= 0.0
		and world.farm.get_cell("field_01", "cell_01").moisture <= 1.0,
		"The empty cells' moisture stays bounded across the session advance")

	# The same interval advanced in arbitrary chunks must land on the same
	# restorable state: the session splits at weather boundaries itself.
	var direct := HeadlessWorld.new()
	var stepped := HeadlessWorld.new()
	_expect(direct.open(test_root.path_join("session-direct"), START).ok, "The direct session opens")
	_expect(stepped.open(test_root.path_join("session-stepped"), START).ok, "The stepped session opens")
	for session: RefCounted in [direct, stepped]:
		session.nature = Nature.new(SEED)
		session.farm.set_environment(session.nature)
		session.farm.mature_all_crops(START)
		_expect(session.execute(FarmCommand.make_sow(
			"rain-sow", "field_01", "cell_01", "carrot", START)).ok, "The session fixture sows a carrot")
		_expect(session.execute(FarmCommand.make_water(
			"rain-water", "field_01", "cell_01", START + 60)).ok, "The session fixture waters at the start")
	var target: float = START + 2.0 * 86400.0 + 777.0
	_expect(direct.advance_to(target).ok, "The direct session advances once")
	var cursor: float = START + 500.0
	while cursor < target:
		cursor = minf(cursor + 500.0, target)
		if not stepped.advance_to(cursor).ok:
			break
	_expect(stepped.now_utc == target, "The stepped session reaches the same target")
	_expect(direct.farm.snapshot() == stepped.farm.snapshot(),
		"One advance and 500-second advances produce identical farm state")
	_expect(JSON.stringify(direct.summary().fields) == JSON.stringify(stepped.summary().fields),
		"Both session paths expose the same growth and moisture view")


func _test_critical_watering_and_yield() -> void:
	var weather := ScriptedWeather.new({FIRST_INDEX: "rain"})
	var farm := Farm.new(START, {}, weather)
	_expect(farm.sow("field_01", "cell_01", "greens", START).ok, "The maturity fixture sows greens")
	farm.settle(START + 1700.0)
	var near: Dictionary = farm.get_cell("field_01", "cell_01")
	_expect(near.stage == "young", "Greens are young just before maturity")
	_expect(farm.water("field_01", "cell_01", START + 1700.0).ok, "Watering at the maturity boundary is accepted")
	var mature: Dictionary = farm.get_cell("field_01", "cell_01")
	_expect(mature.stage == "mature" and mature.growth_seconds == 1800.0,
		"Watering caps at the crop duration instead of overgrowing")
	_expect(mature.moisture == Farm.MOISTURE_MAX, "The boundary watering still saturates the cell")
	_expect(not farm.water("field_01", "cell_01", START + 1700.0).ok,
		"A mature cell refuses a second watering")
	var harvest: Dictionary = farm.harvest("field_01", "cell_01", START + 1700.0)
	_expect(harvest.ok and harvest.reward_amount == 1, "The mature crop yields exactly one basket")
	_expect(not farm.harvest("field_01", "cell_01", START + 1700.0).ok,
		"Repeating the harvest cannot mint a second basket")


func _test_legacy_cell_shape_and_defaults() -> void:
	var farm := Farm.new(START, {}, ScriptedWeather.new())
	var canonical: Dictionary = farm.snapshot()
	var legacy: Dictionary = canonical.duplicate(true)
	var cell: Dictionary = legacy.fields.field_01.cells.cell_01
	cell.erase("moisture")
	cell.erase("planted_by")
	_expect(cell.size() == 5, "The fixture cell has the v27 five-key shape")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(legacy), "A v27 five-key cell still restores")
	var normalized: Dictionary = restored.snapshot().fields.field_01.cells.cell_01
	_expect(normalized.size() == 7 and normalized.moisture == Farm.MOISTURE_DEFAULT,
		"Restore gives the legacy cell brand ownership and default moisture")
	_expect(normalized.planted_by == "" and not normalized.has("moisture_label"),
		"The legacy cell becomes nobody's and stores no derived label")
	var six_key: Dictionary = canonical.duplicate(true)
	six_key.fields.field_01.cells.cell_01.erase("moisture")
	_expect(Farm.new().restore_snapshot(six_key), "The six-key shape with ownership still restores")
	var moisture_only: Dictionary = canonical.duplicate(true)
	moisture_only.fields.field_01.cells.cell_01.erase("planted_by")
	moisture_only.fields.field_01.cells.cell_01.moisture = 0.25
	var moisture_restored := Farm.new()
	_expect(moisture_restored.restore_snapshot(moisture_only),
		"A v27 cell carrying only the new moisture key still restores")
	_expect(moisture_restored.get_cell("field_01", "cell_01").moisture == 0.25
		and moisture_restored.owner_of("field_01", "cell_01") == "",
		"The stored moisture is kept and the owner defaults to nobody")
	var broken: Dictionary = canonical.duplicate(true)
	broken.fields.field_01.cells.cell_01.erase("moisture")
	broken.fields.field_01.cells.cell_01.legacy = 1
	_expect(not Farm.new().restore_snapshot(broken), "An unknown cell key is still refused")


func _test_invalid_and_boundary_input() -> void:
	var farm := Farm.new(START, {}, ScriptedWeather.new({FIRST_INDEX: "rain"}))
	var before: Dictionary = farm.snapshot()
	for invalid: float in [NAN, INF, -1.0]:
		_expect(not farm.settle(invalid).ok, "Invalid settlement time is refused")
	_expect(farm.snapshot() == before, "Invalid times leave the whole farm untouched")
	# The block boundary itself belongs to the completed block; repeating it is
	# idempotent and applies the rain gain once.
	farm.settle(FIRST_END)
	var at_boundary: Dictionary = farm.snapshot()
	_expect(farm.get_cell("field_01", "cell_01").moisture == 0.75, "The boundary applies the completed block")
	farm.settle(FIRST_END)
	_expect(farm.snapshot() == at_boundary, "Re-settling at the same boundary is idempotent")

	for moisture: Variant in [-0.1, 1.1, NAN, "wet"]:
		var corrupt: Dictionary = before.duplicate(true)
		corrupt.fields.field_01.cells.cell_01.moisture = moisture
		_expect(not Farm.new().restore_snapshot(corrupt), "Invalid moisture is refused: " + str(moisture))

	var broken := Farm.new(START, {}, BrokenWeather.new())
	var broken_before: Dictionary = broken.snapshot()
	_expect(broken.settle(START + 3600.0).ok, "An unavailable weather block does not stall settlement")
	_expect(broken.get_cell("field_01", "cell_01").growth_seconds == 0.0
		and broken.get_cell("field_01", "cell_01").moisture == Farm.MOISTURE_DEFAULT,
		"An unavailable block behaves like the legacy additive rules")
	var unknown := Farm.new(START, {}, ScriptedWeather.new({FIRST_INDEX: "snow"}))
	unknown.sow("field_01", "cell_01", "carrot", START)
	unknown.settle(START + 3600.0)
	_expect(unknown.get_cell("field_01", "cell_01").growth_seconds == 3600.0,
		"An unknown weather kind keeps the normal growth rate")
	_expect(unknown.get_cell("field_01", "cell_01").moisture == Farm.MOISTURE_DEFAULT,
		"An unknown weather kind does not change moisture")
	_expect(Farm.weather_growth_factor("rain", 0.0) == 1.0
		and Farm.weather_growth_factor("clear", 0.0) == 0.5
		and Farm.weather_growth_factor("clear", 1.0) == 1.0,
		"Growth stays between half and the normal rate")
	_expect(broken.snapshot() != {} and broken_before.size() == broken.snapshot().size(),
		"Broken weather never changes the snapshot shape")


func _test_environment_without_disaster_support() -> void:
	# M6-02 sources have only weather_at(). M6-03 must keep them working and
	# must not invent a disaster penalty: a clear block still removes 1/8.
	_expect(Nature.RULES_VERSION >= 2, "The rain fixture runs under the disaster-era rules version")
	_expect(Nature.new(SEED).has_method("disaster_at"),
		"The current nature owner exposes the disaster layer")
	var weather := ScriptedWeather.new({FIRST_INDEX: "clear"})
	var farm := Farm.new(START, {}, weather)
	_expect(not weather.has_method("disaster_at"), "The fixture source predates the disaster layer")
	_expect(farm.settle(FIRST_END).ok, "An older source still settles")
	_expect(farm.get_cell("field_01", "cell_01").moisture == 0.375,
		"Without disaster_at only the weather delta is applied")
	_expect(farm.get_cell("field_01", "cell_01").moisture_label == "dry",
		"The player-facing label still explains the dry cell")


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS " + message)
	else:
		failures.append(message)
		print("FAIL " + message)
