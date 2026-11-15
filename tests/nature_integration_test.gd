extends SceneTree
## M6 integration acceptance: Q1/Q2/Q4-relevant evidence for the ecology and
## weather slices. Pure rule and session checks run headless with a fixed seed
## and a fixed UTC start; no scene, GPU, audio or wall clock is involved.
##
## Covered here:
## - single-player FarmState settlement vs the HeadlessWorld authority path,
##   compared after every weather block (moisture, growth totals, harvests);
## - one-shot, weather-boundary and one-second tick segmentation equality;
## - repeated cross-season runs (spring -> summer -> autumn -> winter) and a
##   dry-then-rain transition, compared field by field;
## - a 60-day offline span settled once vs block by block, with measured time;
## - a crop maturing exactly on a seeded rain+drought block boundary, harvested
##   one second before, at, and after it;
## - the disaster warning view vs the disaster view after settlement;
## - save/reopen idempotence and a corrupt nature document being refused
##   without overwriting the farm or nature bytes.
##
## Deliberately not covered: Windows execution, scene/window presentation,
## three-mode process equivalence, world-package import and crash-injection.
## Those stay with their own fixtures and records.

const Farm = preload("res://farm/farm_state.gd")
const Nature = preload("res://farm/nature_state.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const Trellis = preload("res://layout/trellis_slots.gd")

const START: float = 1800000000.0
const SEED: int = 424242
const BLOCK: float = 21600.0
const DAY: float = 86400.0
const RULES_VERSION: int = 2
const PLANT_CROPS: Array[String] = ["greens", "radish", "carrot", "spinach", "lettuce"]
# Frozen from the fixed seed. The scan below re-derives it, so a rule change
# that moved the event fails instead of silently moving the fixture.
const RAIN_DISASTER_START: float = 1803384000.0
const RAIN_DISASTER_KIND: String = "drought"

var checks: int = 0
var failures: Array[String] = []
var test_root: String
var fingerprint_parts: Dictionary = {}


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	# Keep the required per-process parent and add a unique child so a reused PID
	# can never inherit a previous run's save files.
	test_root = project_root.get_base_dir().path_join(
		".local/verification/nature-integration-%d/run-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_single_player_matches_authority()
	_test_segmentation_equivalence()
	_test_cross_season_determinism()
	_test_long_offline()
	_test_boundary_maturity_action()
	_test_disaster_warning_matches_settlement()
	_test_storage_recovery()
	for failure: String in failures:
		push_error(failure)
	var fingerprint: String = JSON.stringify(fingerprint_parts).sha256_text()
	print("NATURE_INTEGRATION_TEST checks=%d failures=%d root=%s fingerprint=%s"
		% [checks, failures.size(), test_root, fingerprint])
	quit(0 if failures.is_empty() else 1)


# ---------------------------------------------------------------------------
# 1. Single-player path vs HeadlessWorld authority path, block by block.
# ---------------------------------------------------------------------------

func _test_single_player_matches_authority() -> void:
	var directory: String = _seeded_directory("parity")
	var authority := HeadlessWorld.new()
	var opened: Dictionary = authority.open(directory, START)
	_expect(opened.ok and opened.kind == "created", "The authority opens a fresh farm with a persisted seed")
	# Regression: the create path must adopt nature.json, not sample a new seed.
	_expect(authority.nature.get_seed() == SEED,
		"A missing farm adopts the persisted natural seed instead of drawing a new one")
	var single := Farm.new(START, {}, Nature.new(SEED))
	_expect(_comparable(authority.farm.snapshot()) == _comparable(single.snapshot()),
		"Fresh single-player and authority farms start from the same state")

	var planted_authority: int = _plant_all(authority.farm, START)
	var planted_single: int = _plant_all(single, START)
	_expect(planted_authority == planted_single and planted_authority > 0,
		"The parity fixture plants the same non-empty set on both paths")
	_expect(_comparable(authority.farm.snapshot()) == _comparable(single.snapshot()),
		"Both paths agree after the same planting actions")

	var boundary: float = _next_block_end(START)
	var compared_blocks: int = 0
	var blocks: int = 40
	for index: int in blocks:
		var advanced: Dictionary = authority.advance_to(boundary)
		var settled: Dictionary = single.settle(boundary)
		_expect(advanced.ok and settled.ok, "Block %d settles on both paths" % index)
		_expect(_comparable(authority.farm.snapshot()) == _comparable(single.snapshot()),
			"Block %d farm snapshots stay identical" % index)
		_expect(_cell_views(authority.farm) == _cell_views(single),
			"Block %d moisture and growth views stay identical" % index)
		compared_blocks += 1
		boundary += BLOCK

	_expect(compared_blocks == blocks, "All parity blocks were compared")
	_expect(_growth_summary(authority.farm) == _growth_summary(single),
		"Grown counts and total growth seconds match at the end of the span")
	var harvested_authority: Dictionary = _harvest_mature(authority.farm, boundary)
	var harvested_single: Dictionary = _harvest_mature(single, boundary)
	_expect(harvested_authority == harvested_single,
		"Harvest counts, inventory and harvested totals match between paths")
	_expect(int(harvested_single.count) > 0, "The parity span actually produced mature harvests")
	_expect(_comparable(authority.farm.snapshot()) == _comparable(single.snapshot()),
		"Both paths agree after harvesting the same mature cells")
	fingerprint_parts["parity"] = _comparable(authority.farm.snapshot())


# ---------------------------------------------------------------------------
# 2. The same logical target under one-shot, weather-boundary and 1 Hz ticks.
# ---------------------------------------------------------------------------

func _test_segmentation_equivalence() -> void:
	var target: float = START + 10.0 * DAY
	var one_shot := Farm.new(START, {}, Nature.new(SEED))
	var boundary_stepped := Farm.new(START, {}, Nature.new(SEED))
	var uneven := Farm.new(START, {}, Nature.new(SEED))
	for farm: RefCounted in [one_shot, boundary_stepped, uneven]:
		_expect(_plant_all(farm, START) > 0, "The segmentation fixture plants each path")

	_expect(one_shot.settle(target).ok, "The one-shot path settles ten days at once")
	var cursor: float = _next_block_end(START)
	while cursor < target:
		_expect(boundary_stepped.settle(cursor).ok, "A weather boundary still settles")
		cursor += BLOCK
	boundary_stepped.settle(target)
	_expect(_comparable(one_shot.snapshot()) == _comparable(boundary_stepped.snapshot()),
		"One settlement equals settlement on every weather boundary")

	var uneven_steps: Array[float] = [997.0, 1.0, 7200.0, 17.0, 3600.0, 21599.0, 2.0]
	var uneven_at: float = START
	var uneven_index: int = 0
	while uneven_at < target:
		uneven_at = minf(target, uneven_at + uneven_steps[uneven_index % uneven_steps.size()])
		uneven_index += 1
		_expect(uneven.settle(uneven_at).ok, "An uneven segment still settles")
	_expect(_comparable(one_shot.snapshot()) == _comparable(uneven.snapshot()),
		"Uneven one-second-to-six-hour segments match the one-shot snapshot")

	# One real second at a time across a weather boundary, representing an
	# online idle tick. Compare to the single offline restore settlement.
	var tick_start: float = _next_block_end(START) - 1800.0
	var tick_target: float = tick_start + 3600.0
	var one_shot_tick := Farm.new(tick_start, {}, Nature.new(SEED))
	var per_second := Farm.new(tick_start, {}, Nature.new(SEED))
	_expect(_plant_all(one_shot_tick, tick_start) > 0, "The tick fixture plants the reference path")
	_expect(_plant_all(per_second, tick_start) > 0, "The tick fixture plants the ticking path")
	_expect(one_shot_tick.settle(tick_target).ok, "The reference path settles the tick window once")
	var tick_at: float = tick_start
	while tick_at < tick_target:
		tick_at += 1.0
		per_second.settle(tick_at)
	_expect(_comparable(one_shot_tick.snapshot()) == _comparable(per_second.snapshot()),
		"3600 one-second settlements match one settlement across a block boundary")
	fingerprint_parts["segmentation"] = _comparable(one_shot.snapshot())


# ---------------------------------------------------------------------------
# 3. Repeated cross-season runs and a dry-to-rain transition.
# ---------------------------------------------------------------------------

func _test_cross_season_determinism() -> void:
	var span_days: int = 21
	var nature_a := Nature.new(SEED)
	var nature_b := Nature.new(SEED)
	var run_a := Farm.new(START, {}, nature_a)
	var run_b := Farm.new(START, {}, nature_b)
	_expect(_plant_all(run_a, START) > 0 and _plant_all(run_b, START) > 0,
		"The cross-season fixture plants two identical runs")
	var start_season: String = str(nature_a.season_at(START).id)
	var seasons_seen: Dictionary = {start_season: true}
	var previous_season: String = start_season
	var transitions: int = 0
	var dry_before_rain: bool = false
	var dry_then_rain_at: float = -1.0
	var tracked_moisture: float = float(run_a.get_cell("field_01", "cell_01").moisture)

	var cursor: float = START
	for index: int in span_days * Nature.BLOCKS_PER_DAY:
		var weather: Dictionary = nature_a.weather_at(cursor)
		cursor = float(weather.end_utc)
		_expect(run_a.settle(cursor).ok and run_b.settle(cursor).ok,
			"Cross-season block %d settles on both runs" % index)
		_expect(_comparable(run_a.snapshot()) == _comparable(run_b.snapshot()),
			"Cross-season block %d snapshots are byte-identical" % index)
		var season: String = str(nature_a.season_at(cursor).id)
		seasons_seen[season] = true
		if season != previous_season:
			transitions += 1
			previous_season = season
		var moisture_now: float = float(run_a.get_cell("field_01", "cell_01").moisture)
		if not dry_before_rain and str(weather.kind) == "rain" \
				and tracked_moisture < Farm.MOISTURE_GROWTH_THRESHOLD and moisture_now > tracked_moisture:
			dry_before_rain = true
			dry_then_rain_at = cursor
		tracked_moisture = moisture_now

	_expect(transitions >= 2, "The span crosses at least two season boundaries")
	_expect(seasons_seen.size() >= 3, "At least three season labels appear in the span")
	_expect(str(nature_a.season_at(START + float(span_days) * DAY).id) != start_season,
		"The run does not end in the season it started in")
	_expect(dry_before_rain and dry_then_rain_at > 0.0,
		"A dry cell is rewetted by a later rain block under the fixed seed")
	_expect(_comparable(run_a.snapshot()) == _comparable(run_b.snapshot()),
		"The full cross-season run is reproducible field by field")
	print("CROSS_SEASON span_days=%d transitions=%d seasons=%d dry_rain_at=%.0f final_season=%s"
		% [span_days, transitions, seasons_seen.size(), dry_then_rain_at,
		str(nature_a.season_at(START + float(span_days) * DAY).id)])
	fingerprint_parts["cross_season"] = _comparable(run_a.snapshot())


# ---------------------------------------------------------------------------
# 4. Long offline: one settlement vs block-by-block, measured duration.
# ---------------------------------------------------------------------------

func _test_long_offline() -> void:
	var span_days: int = 60
	var target: float = START + float(span_days) * DAY
	var directory: String = _seeded_directory("long")
	var authority := HeadlessWorld.new()
	_expect(authority.open(directory, START).ok, "The long-offline authority opens")
	_expect(authority.nature.get_seed() == SEED, "The long-offline authority keeps the fixed seed")
	var one_shot := Farm.new(START, {}, Nature.new(SEED))
	var stepped := Farm.new(START, {}, Nature.new(SEED))
	_expect(_plant_all(authority.farm, START) > 0 and _plant_all(one_shot, START) > 0
		and _plant_all(stepped, START) > 0, "The long-offline fixture plants all three paths")
	var planted: int = int(_growth_summary(one_shot).planted)
	var cell_count: int = _cell_count(one_shot)
	var block_count: int = int(floorf(target / BLOCK) - floorf(START / BLOCK))

	var one_start: int = Time.get_ticks_usec()
	_expect(one_shot.settle(target).ok, "Sixty days settle in one call")
	var one_ms: float = float(Time.get_ticks_usec() - one_start) / 1000.0

	var stepped_start: int = Time.get_ticks_usec()
	var cursor: float = _next_block_end(START)
	while cursor < target:
		_expect(stepped.settle(cursor).ok, "A long-offline block still settles")
		cursor += BLOCK
	stepped.settle(target)
	var stepped_ms: float = float(Time.get_ticks_usec() - stepped_start) / 1000.0

	var authority_start: int = Time.get_ticks_usec()
	_expect(authority.advance_to(target).ok, "The authority advances sixty days in one call")
	var authority_ms: float = float(Time.get_ticks_usec() - authority_start) / 1000.0

	_expect(_comparable(one_shot.snapshot()) == _comparable(stepped.snapshot()),
		"A sixty-day one-shot settlement equals block-by-block settlement")
	_expect(_comparable(one_shot.snapshot()) == _comparable(authority.farm.snapshot()),
		"The authority's own segmentation matches the single-player snapshot")
	_expect(one_ms < 60000.0 and stepped_ms < 60000.0 and authority_ms < 60000.0,
		"Sixty days of settlement finish well inside the fixture timeout")
	_expect(_growth_summary(one_shot) == _growth_summary(stepped)
		and _growth_summary(stepped) == _growth_summary(authority.farm),
		"Grown counts and total growth match after sixty offline days")
	_expect(int(_growth_summary(one_shot).planted) == planted,
		"Long offline time neither destroys nor adds planted crops")
	var bounded: bool = true
	for field_id: String in _all_field_ids(one_shot):
		for cell_id: String in one_shot.cell_ids(field_id):
			var cell: Dictionary = one_shot.get_cell(field_id, cell_id)
			if float(cell.moisture) < 0.0 or float(cell.moisture) > 1.0:
				bounded = false
			if not str(cell.crop_id).is_empty():
				var duration: float = Farm.Crops.definition(str(cell.crop_id)).duration_seconds
				if float(cell.growth_seconds) > duration:
					bounded = false
	_expect(bounded, "Every cell keeps moisture in [0, 1] and growth at or below maturity")
	var h_one: Dictionary = _harvest_mature(one_shot, target)
	var h_stepped: Dictionary = _harvest_mature(stepped, target)
	var h_authority: Dictionary = _harvest_mature(authority.farm, target)
	_expect(h_one == h_stepped and h_stepped == h_authority,
		"Sixty-day harvest counts and totals match across all paths")
	_expect(int(h_one.count) > 0, "The sixty-day span actually yields harvests")
	_expect(_comparable(one_shot.snapshot()) == _comparable(stepped.snapshot())
		and _comparable(stepped.snapshot()) == _comparable(authority.farm.snapshot()),
		"All three paths agree after harvesting the long-offline mature cells")
	print("LONG_OFFLINE days=%d blocks=%d cells=%d cell_blocks=%d one_shot_ms=%.1f stepped_ms=%.1f authority_ms=%.1f harvests=%d"
		% [span_days, block_count, cell_count, cell_count * block_count, one_ms, stepped_ms,
		authority_ms, int(h_one.count)])
	fingerprint_parts["long_offline"] = {
		"snapshot": _comparable(one_shot.snapshot()),
		"harvests": h_one,
	}


# ---------------------------------------------------------------------------
# 5. Critical maturity on a seeded rain+drought block boundary.
# ---------------------------------------------------------------------------

func _test_boundary_maturity_action() -> void:
	var nature := Nature.new(SEED)
	var boundary: float = RAIN_DISASTER_START
	var end: float = boundary + BLOCK
	_expect(is_equal_approx(float(nature.weather_at(boundary).start_utc), boundary),
		"The frozen fixture starts on a weather block boundary")
	_expect(str(nature.weather_at(boundary).kind) == "rain",
		"The disaster block completes under rain, so growth runs at the normal rate")
	_expect(str(nature.disaster_at(boundary).kind) == RAIN_DISASTER_KIND,
		"The frozen seed derives a drought in that same block")
	var setup: float = end - 1800.0
	_expect(is_equal_approx(float(nature.weather_at(setup).start_utc), boundary),
		"The critical setup sits inside the disaster block")
	_expect(str(nature.weather_at(setup).kind) == "rain",
		"The critical block uses the normal growth rate")
	var expected_moisture: float = Farm.MOISTURE_DEFAULT + Farm.RAIN_MOISTURE_GAIN
	expected_moisture = clampf(expected_moisture - Farm.DROUGHT_MOISTURE_LOSS, 0.0, 1.0)

	var before := Farm.new(setup, {}, nature)
	_expect(before.sow("field_01", "cell_01", "greens", setup).ok, "The before-boundary crop sows")
	_expect(before.settle(end - 1.0).ok, "The before path settles one second before the boundary")
	var before_cell: Dictionary = before.get_cell("field_01", "cell_01")
	_expect(is_equal_approx(float(before_cell.growth_seconds), 1799.0),
		"One second before the boundary the 30-minute crop has 1799 seconds")
	_expect(before_cell.stage != "mature", "One second before the boundary the crop is not mature")
	var before_snapshot: Dictionary = before.snapshot()
	var refused: Dictionary = before.harvest("field_01", "cell_01", end - 1.0)
	_expect(not refused.ok and str(refused.reason) == "not_mature",
		"Harvesting one second early is refused by the maturity rule")
	_expect(before.snapshot() == before_snapshot,
		"A refused early harvest changes no authoritative state")
	var refused_again: Dictionary = before.harvest("field_01", "cell_01", end - 1.0)
	_expect(not refused_again.ok and str(refused_again.reason) == "not_mature"
		and before.snapshot() == before_snapshot,
		"Repeating the early harvest gives the same refusal and no state change")

	var at := Farm.new(setup, {}, nature)
	_expect(at.sow("field_01", "cell_01", "greens", setup).ok, "The at-boundary crop sows")
	_expect(at.settle(end).ok, "The at-boundary path settles exactly on the boundary")
	var at_cell: Dictionary = at.get_cell("field_01", "cell_01")
	_expect(is_equal_approx(float(at_cell.growth_seconds), 1800.0),
		"The completed block brings the crop to exactly its duration")
	_expect(at_cell.stage == "mature", "The crop is mature at the exact boundary")
	_expect(is_equal_approx(float(at_cell.moisture), expected_moisture),
		"The completed block applies rain then drought moisture exactly once")
	var harvested_at: Dictionary = at.harvest("field_01", "cell_01", end)
	_expect(harvested_at.ok and int(harvested_at.reward_amount) == 1,
		"Harvesting at the exact boundary yields one basket")
	_expect(int(at.hud_state().inventory.greens) == 1, "The at-boundary basket enters the inventory once")
	_expect(is_equal_approx(float(at.get_cell("field_01", "cell_01").moisture), expected_moisture),
		"Harvesting keeps the soil moisture the weather left")
	var repeated_at: Dictionary = at.harvest("field_01", "cell_01", end)
	_expect(not repeated_at.ok and str(repeated_at.reason) == "empty"
		and int(at.hud_state().inventory.greens) == 1,
		"Repeating the boundary harvest cannot mint a second basket")

	var after := Farm.new(setup, {}, nature)
	_expect(after.sow("field_01", "cell_01", "greens", setup).ok, "The after-boundary crop sows")
	_expect(after.settle(end + 1.0).ok, "The after path settles one second past the boundary")
	_expect(after.get_cell("field_01", "cell_01").stage == "mature",
		"The crop stays mature one second after the boundary")
	var harvested_after: Dictionary = after.harvest("field_01", "cell_01", end + 1.0)
	_expect(harvested_after.ok and int(harvested_after.reward_amount) == 1,
		"Harvesting one second late yields one basket")
	_expect(harvested_at.reward_crop_id == harvested_after.reward_crop_id
		and int(harvested_at.reward_amount) == int(harvested_after.reward_amount),
		"The boundary instants decide the same harvest outcome, not two different ones")

	# The two action instants differ by one second of baseline, so future weather
	# settlement must still converge to the same cell state.
	_expect(at.settle(end + BLOCK).ok and after.settle(end + BLOCK).ok,
		"Both post-harvest paths settle to the next weather boundary")
	_expect(at.get_cell("field_01", "cell_01").moisture
		== after.get_cell("field_01", "cell_01").moisture,
		"Post-harvest moisture converges at the next boundary")
	fingerprint_parts["boundary"] = {
		"early_reason": str(refused.reason),
		"at_reward": int(harvested_at.reward_amount),
		"after_reward": int(harvested_after.reward_amount),
		"moisture": expected_moisture,
	}


# ---------------------------------------------------------------------------
# 6. Warning view vs the disaster view after settling the same block.
# ---------------------------------------------------------------------------

func _test_disaster_warning_matches_settlement() -> void:
	var nature := Nature.new(SEED)
	var boundary: float = RAIN_DISASTER_START
	var end: float = boundary + BLOCK
	var directory: String = _seeded_directory("warning")
	var world := HeadlessWorld.new()
	_expect(world.open(directory, boundary - 1800.0).ok, "The warning fixture opens one block early")
	var before: Dictionary = world.summary().nature
	_expect((before.disaster as Dictionary).is_empty(),
		"No disaster covers the instant before the event")
	var warning: Dictionary = before.warning
	_expect(not warning.is_empty(), "The next block's disaster is warned in advance")
	_expect(str(warning.kind) == RAIN_DISASTER_KIND
		and is_equal_approx(float(warning.starts_utc), boundary)
		and is_equal_approx(float(warning.ends_utc), end),
		"The warning names the same kind and block the rules derive")
	_expect(is_equal_approx(float(warning.lead_seconds), 1800.0),
		"The warning reports the exact lead time")
	_expect(world.disaster_view() == {"disaster": {}, "warning": warning},
		"The disaster view helper and the summary share the warning")
	_expect(world.advance_to(boundary - 1.0).ok, "The fixture stops one second before the event")
	var before_moisture: float = float(world.farm.get_cell("field_01", "cell_01").moisture)

	_expect(world.advance_to(boundary).ok, "The fixture settles exactly on the event start")
	var current: Dictionary = world.summary().nature
	_expect(not (current.disaster as Dictionary).is_empty(),
		"The current disaster appears as soon as its block starts")
	_expect(str(current.disaster.kind) == str(warning.kind)
		and int(current.disaster.severity) == int(warning.severity)
		and is_equal_approx(float(current.disaster.starts_utc), float(warning.starts_utc))
		and is_equal_approx(float(current.disaster.ends_utc), float(warning.ends_utc)),
		"The settled disaster record matches the earlier warning field by field")
	_expect(world.disaster_view().disaster == current.disaster,
		"The helper and the summary expose the same current disaster")
	_expect(is_equal_approx(float(world.farm.get_cell("field_01", "cell_01").moisture),
		maxf(0.0, before_moisture - Farm.CLEAR_MOISTURE_LOSS)),
		"Settling the block before the event applies only that block's weather delta")

	var before_event: float = float(world.farm.get_cell("field_01", "cell_01").moisture)
	_expect(world.advance_to(end).ok, "The fixture settles the whole disaster block")
	var after_event: float = float(world.farm.get_cell("field_01", "cell_01").moisture)
	_expect(is_equal_approx(after_event, clampf(before_event + Farm.RAIN_MOISTURE_GAIN
		- Farm.DROUGHT_MOISTURE_LOSS, 0.0, 1.0)),
		"The completed disaster block applies rain and drought in the documented order")
	_expect((world.summary().nature.disaster as Dictionary).is_empty(),
		"The disaster view empties after its single block")
	fingerprint_parts["warning"] = {
		"kind": str(warning.kind),
		"severity": int(warning.severity),
		"starts_utc": float(warning.starts_utc),
		"lead_seconds": float(warning.lead_seconds),
		"moisture_after": after_event,
	}


# ---------------------------------------------------------------------------
# 7. Save/reopen idempotence and corrupt-nature refusal (Q2-relevant).
# ---------------------------------------------------------------------------

func _test_storage_recovery() -> void:
	var directory: String = _seeded_directory("storage")
	var world := HeadlessWorld.new()
	_expect(world.open(directory, START).ok, "The storage fixture opens a seeded world")
	_expect(world.execute(FarmCommand.make_sow("storage-sow", "field_01", "cell_01", "greens", START)).ok,
		"The storage fixture commits a sow")
	_expect(world.execute(FarmCommand.make_water("storage-water", "field_01", "cell_01", START + 60.0)).ok,
		"The storage fixture commits a water")
	_expect(world.advance_to(START + 3600.0).ok, "The storage fixture advances past maturity")
	var harvest_command: Dictionary = FarmCommand.make("storage-harvest", "field_01", "cell_01",
		START + 3600.0)
	var harvested: Dictionary = world.execute(harvest_command)
	_expect(harvested.ok and int(harvested.reward_amount) == 1,
		"The storage fixture commits one harvest")
	_expect(world.save().ok, "The storage fixture saves farm and nature documents")
	var saved_farm: Dictionary = world.farm.snapshot()
	var saved_inventory: Dictionary = world.farm.hud_state().inventory.duplicate()
	var farm_bytes: String = FileAccess.get_file_as_string(directory.path_join(FarmStore.MAIN))
	var nature_bytes: String = FileAccess.get_file_as_string(directory.path_join(NatureStore.MAIN))

	var reopened := HeadlessWorld.new()
	var loaded: Dictionary = reopened.open(directory, START + 3600.0)
	_expect(loaded.ok and loaded.kind == "loaded",
		"A separate session reopens the committed world: " + JSON.stringify(loaded))
	if not loaded.ok:
		# Dependent checks cannot run without an authority; the failure above
		# already fails the fixture instead of turning into a script error.
		return
	_expect(reopened.nature.get_seed() == SEED, "The persisted seed survives the reopen")
	_expect(reopened.farm.snapshot() == saved_farm, "The reopened farm is byte-identical to the save")
	_expect(FileAccess.get_file_as_string(directory.path_join(FarmStore.MAIN)) == farm_bytes
		and FileAccess.get_file_as_string(directory.path_join(NatureStore.MAIN)) == nature_bytes,
		"Reopening rewrites neither the farm nor the nature document")
	var replay: Dictionary = reopened.execute(harvest_command)
	_expect(replay.ok and replay.duplicate, "The reopened world replays the committed harvest id")
	_expect(reopened.farm.hud_state().inventory == saved_inventory,
		"A replayed harvest does not mint a second basket")
	var later: float = START + 30.0 * DAY
	_expect(reopened.advance_to(later).ok, "The reopened world advances through more weather")
	var once: Dictionary = reopened.farm.snapshot()
	_expect(reopened.advance_to(later).ok and reopened.farm.snapshot() == once,
		"Advancing to the same instant twice is idempotent")

	var corrupt_directory: String = _seeded_directory("corrupt")
	var corrupt_world := HeadlessWorld.new()
	_expect(corrupt_world.open(corrupt_directory, START).ok, "The corrupt fixture starts a saved world")
	_expect(corrupt_world.save().ok, "The corrupt fixture writes a valid baseline")
	var corrupt_farm_path: String = corrupt_directory.path_join(FarmStore.MAIN)
	var corrupt_nature_path: String = corrupt_directory.path_join(NatureStore.MAIN)
	var corrupt_farm_bytes: String = FileAccess.get_file_as_string(corrupt_farm_path)
	_write_text(corrupt_nature_path, "{not json")
	var corrupt_bytes: String = FileAccess.get_file_as_string(corrupt_nature_path)
	var refused_world := HeadlessWorld.new()
	var refused: Dictionary = refused_world.open(corrupt_directory, START + 60.0)
	_expect(not refused.ok and str(refused.reason) == "load_nature_corrupt",
		"A corrupt nature document refuses to open instead of drawing a new seed")
	_expect(FileAccess.get_file_as_string(corrupt_nature_path) == corrupt_bytes,
		"A refused open leaves the corrupt nature document untouched")
	_expect(FileAccess.get_file_as_string(corrupt_farm_path) == corrupt_farm_bytes,
		"A refused open leaves the valid farm document untouched")
	fingerprint_parts["storage"] = {
		"inventory": saved_inventory,
		"seed": SEED,
		"replay_duplicate": bool(replay.duplicate),
	}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _all_field_ids(farm: RefCounted) -> Array[String]:
	# Ground beds plus the trellis: every field the authority summary exposes.
	var result: Array[String] = []
	result.assign(farm.field_ids())
	result.append(Trellis.FIELD_ID)
	return result


static func _next_block_end(at_utc: float) -> float:
	return (floorf(at_utc / BLOCK) + 1.0) * BLOCK


func _seeded_directory(name: String) -> String:
	var directory: String = test_root.path_join(name)
	DirAccess.make_dir_recursive_absolute(directory)
	var saved: Dictionary = NatureStore.new(directory).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	_expect(saved.ok, "The fixture persists the fixed seed for " + name)
	return directory


func _plant_all(farm: RefCounted, at_utc: float) -> int:
	var planted: int = 0
	var rotation: int = 0
	for field_id: String in _all_field_ids(farm):
		var cells: Array[String] = []
		cells.assign(farm.cell_ids(field_id))
		cells.sort()
		for cell_id: String in cells:
			var cell: Dictionary = farm.get_cell(field_id, cell_id)
			if not str(cell.crop_id).is_empty() or str(cell.ground) != "ready":
				continue
			var crop_id: String = "luffa" if field_id == Trellis.FIELD_ID \
				else PLANT_CROPS[rotation % PLANT_CROPS.size()]
			rotation += 1
			if farm.sow(field_id, cell_id, crop_id, at_utc).ok:
				planted += 1
	return planted


func _growth_summary(farm: RefCounted) -> Dictionary:
	var planted: int = 0
	var mature: int = 0
	var total_growth: float = 0.0
	for field_id: String in _all_field_ids(farm):
		for cell_id: String in farm.cell_ids(field_id):
			var cell: Dictionary = farm.get_cell(field_id, cell_id)
			if str(cell.crop_id).is_empty():
				continue
			planted += 1
			total_growth += float(cell.growth_seconds)
			if str(cell.stage) == "mature":
				mature += 1
	return {"planted": planted, "mature": mature, "total_growth": total_growth}


func _cell_views(farm: RefCounted) -> Dictionary:
	var fields: Dictionary = {}
	for field_id: String in _all_field_ids(farm):
		var cells: Dictionary = {}
		for cell_id: String in farm.cell_ids(field_id):
			var cell: Dictionary = farm.get_cell(field_id, cell_id)
			cells[cell_id] = {
				"crop_id": cell.crop_id,
				"stage": cell.stage,
				"ground": cell.ground,
				"growth_seconds": cell.growth_seconds,
				"watered": cell.watered,
				"moisture": cell.moisture,
				"moisture_label": cell.moisture_label,
				"growth_rate": cell.growth_rate,
			}
		fields[field_id] = cells
	return fields


func _harvest_mature(farm: RefCounted, at_utc: float) -> Dictionary:
	var count: int = 0
	for field_id: String in _all_field_ids(farm):
		var cells: Array[String] = []
		cells.assign(farm.cell_ids(field_id))
		cells.sort()
		for cell_id: String in cells:
			if str(farm.get_cell(field_id, cell_id).stage) != "mature":
				continue
			if farm.harvest(field_id, cell_id, at_utc).ok:
				count += 1
	var hud: Dictionary = farm.hud_state()
	return {
		"count": count,
		"inventory": hud.inventory.duplicate(),
		"harvested": hud.harvested.duplicate(),
	}


func _cell_count(farm: RefCounted) -> int:
	var count: int = 0
	for field_id: String in _all_field_ids(farm):
		count += farm.cell_ids(field_id).size()
	return count


static func _comparable(snapshot: Dictionary) -> Dictionary:
	# The command ledger is commit-boundary state, compared by its own fixtures.
	var copy: Dictionary = snapshot.duplicate(true)
	copy.erase("transaction")
	return copy


func _write_text(path: String, text: String) -> void:
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
