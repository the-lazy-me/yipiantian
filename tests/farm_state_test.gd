extends SceneTree

const Farm = preload("res://farm/farm_state.gd")
const Crops = preload("res://farm/crop_catalog.gd")
const Command = preload("res://farm/farm_command.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const START: float = 1800000000.0
const PLAYER: String = "player_00000000000000000000000000000001"
const OTHER: String = "player_00000000000000000000000000000002"

var failures: Array[String] = []
var checks: int = 0


func _initialize() -> void:
	_test_initial_state_and_isolation()
	_test_copy_isolation()
	_test_mixed_cells()
	_test_stages_and_actions()
	_test_elapsed_time_equivalence()
	_test_clock_rollback_and_jump()
	_test_invalid_actions_are_atomic()
	_test_snapshot_validation()
	_test_time_bounds()
	_test_legacy_snapshot_round_trip()
	_test_variable_fields()
	_test_gift_replay_outlives_command_window()
	for failure: String in failures:
		push_error(failure)
	print("FARM_STATE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_initial_state_and_isolation() -> void:
	var farm := Farm.new(START)
	var initial: Dictionary = farm.snapshot()
	_expect(initial.fields.size() == 7 and farm.field_ids().size() == 6, "Six beds and one trellis planting area")
	_expect(Crops.total_harvested(initial.harvested) == 0 and initial.harvested.size() == 13, "Tutorial crops do not award baskets automatically")
	_expect(farm.get_cell("field_01", "cell_06").stage == "empty" and farm.get_cell("field_02", "cell_06").stage == "empty", "Two initial empty fields")
	_expect(farm.get_cell("field_03", "cell_06").stage == "mature", "First harvest available immediately")
	_expect(is_equal_approx(farm.get_cell("field_04", "cell_06").progress, 0.2), "Initial greens progress")
	_expect(is_equal_approx(farm.get_cell("field_05", "cell_06").progress, 0.1) and is_equal_approx(farm.get_cell("field_06", "cell_06").progress, 0.6), "Initial radish progress")
	for id: String in farm.field_ids():
		var field: Dictionary=initial.fields[id]
		_expect(field.cells.size() == 16, "Sixteen stable cells in every ground bed")
		for cell: Dictionary in field.cells.values():
			_expect(not cell.watered and cell.last_settled_utc_seconds == START, "Fresh cells share injected baseline and are unwatered")
	initial.fields.field_03.cells.cell_06.crop_id = "invalid"
	initial.harvested.greens = 999
	var view: Dictionary = farm.get_cell("field_03", "cell_06")
	view.growth_seconds = 0.0
	_expect(farm.get_cell("field_03", "cell_06").stage == "mature" and farm.snapshot().harvested.greens == 0, "Returned views cannot mutate authority")
	var definition: Dictionary = Crops.definition("greens")
	definition.duration_seconds = 1.0
	farm.harvest("field_03", "cell_06", START)
	farm.sow("field_03", "cell_06", "greens", START)
	farm.water("field_03", "cell_06", START)
	_expect(Crops.definition("greens").duration_seconds == 1800.0 and is_equal_approx(farm.get_cell("field_03", "cell_06").progress, 0.2), "Definition edits and player actions cannot rewrite crop configuration")


func _test_copy_isolation() -> void:
	var source:=Farm.new(START)
	_expect(source.harvest("field_03","cell_06",START).ok,"Copy fixture has a real harvested basket")
	var before: Dictionary=source.snapshot()
	var candidate: RefCounted=source.copy()
	_expect(candidate!=source and candidate.snapshot()==before,"Copy retains the entire current state without reinitializing it")
	var bird: String=Farm.Companions.IDS[0]
	_expect(candidate.settle(START+300).ok,"Candidate advances its own crop clocks")
	_expect(candidate.animal_action(bird,"feed","greens",before.animals[bird].revision).ok,"Candidate feeding updates its own animal and inventory")
	_expect(candidate.remember("arrange",START+300),"Candidate records its own construction memory")
	_expect(source.snapshot()==before,"Uncommitted crop, inventory, animal and memory changes cannot leak into the source")
	var candidate_before: Dictionary=candidate.snapshot()
	_expect(source.animal_action(bird,"name","小团",before.animals[bird].revision).ok,"Source changes remain possible after copying")
	_expect(candidate.snapshot()==candidate_before,"Later source edits cannot change the private candidate")
	var layout: Dictionary=candidate.snapshot().layout
	var field: Dictionary=layout.fields[0]
	field.position[0]+=.5
	_expect(candidate.apply_layout(layout,START+300).ok and source.snapshot().layout==before.layout,"A candidate layout edit preserves the source layout")
	var invalid: Dictionary=candidate.snapshot();invalid.inventory.greens=-1
	var valid: Dictionary=candidate.snapshot()
	_expect(not candidate.restore_snapshot(invalid) and candidate.snapshot()==valid,"Copy does not bypass validation of later external snapshots")
	source.accept(candidate)
	_expect(source.snapshot() == candidate.snapshot(), "Accepted transaction retains every state field")
	candidate.harvest("field_06", "cell_06", START+99999)
	_expect(source.snapshot() == valid, "Later candidate edits cannot alter accepted live state")
	var gradual := Farm.new(START)
	_expect(gradual.settle(START + 1).visual_changed.is_empty(), "Sub-stage growth does not request a scene rebuild")
	var advanced: Dictionary = gradual.settle(START + 99999)
	_expect(advanced.visual_changed.size() == 3 and not advanced.visual_changed.has("field_03"), "Only crops crossing a visual stage refresh")

func _test_mixed_cells() -> void:
	var farm := Farm.new(START)
	_expect(Farm.CELL_IDS.size() == 16 and Farm.CELL_IDS[0] == "cell_01" and Farm.CELL_IDS[15] == "cell_16", "Stable row-major cell IDs")
	_expect(farm.get_field("field_01").cells.cell_01 == farm.get_cell("field_01", "cell_01"), "Field view contains full derived cell views")
	_expect(farm.get_cell("field_01", "cell_01").field_id == "field_01", "Cell view retains parent field identity")
	for cell_id: String in Farm.CELL_IDS:
		var crop_id: String = "greens" if Farm.CELL_IDS.find(cell_id) % 2 == 0 else "radish"
		_expect(farm.sow("field_01", cell_id, crop_id, START).ok, "All sixteen cells can be planted independently")
	var before: Dictionary = farm.snapshot()
	_expect(farm.water("field_01", "cell_01", START).ok, "Water selected mixed crop cell")
	for cell_id: String in Farm.CELL_IDS:
		if cell_id != "cell_01":
			_expect(farm.snapshot().fields.field_01.cells[cell_id] == before.fields.field_01.cells[cell_id], "Water does not change neighbouring cells")
	farm.settle(START + 1800.0)
	_expect(farm.get_cell("field_01", "cell_01").stage == "mature" and farm.get_cell("field_01", "cell_02").stage != "mature", "Mixed durations are independent")
	before = farm.snapshot()
	var harvested: Dictionary = farm.harvest("field_01", "cell_01", START + 1800.0)
	_expect(harvested.ok and harvested.reward_amount == 1 and harvested.changed_fields == ["field_01"], "One cell gives one basket and one field refresh")
	for cell_id: String in Farm.CELL_IDS:
		if cell_id != "cell_01":
			_expect(farm.snapshot().fields.field_01.cells[cell_id] == before.fields.field_01.cells[cell_id], "Harvest preserves neighbouring crops")
	before = farm.snapshot()
	_expect(farm.sow("field_01", "cell_17", "greens", START).reason == "invalid_cell", "Unknown cell rejected")
	_expect(farm.water("field_01", "", START).reason == "invalid_cell", "No implicit whole-field watering")
	_expect(farm.harvest("field_01", "", START).reason == "invalid_cell" and farm.snapshot() == before, "No implicit whole-field harvesting")
	_expect(farm.get_field("missing").is_empty() and farm.get_cell("field_01", "missing").is_empty(), "Missing views are empty")
	var view: Dictionary = farm.get_field("field_01")
	view.cells.cell_02.crop_id = "greens"
	_expect(farm.get_cell("field_01", "cell_02").crop_id == "radish", "Field view is deeply isolated")
	var settled: Dictionary = farm.settle(START + 86400.0)
	_expect(settled.changed_fields.size() == 7, "Changed clocks include the trellis planting area")


func _test_stages_and_actions() -> void:
	for crop_id: String in Crops.seeds(false):
		var farm := Farm.new(START)
		var duration: float = Crops.definition(crop_id).duration_seconds
		_expect(farm.sow("field_01", "cell_06", crop_id, START).ok, "Sow %s with unlimited seeds" % crop_id)
		_expect(farm.get_cell("field_01", "cell_06").stage == "sprout", "Zero progress is sprout")
		farm.settle(START + duration * 0.35 - 0.01)
		_expect(farm.get_cell("field_01", "cell_06").stage == "sprout", "Below 35 percent stays sprout")
		farm.settle(START + duration * 0.35)
		_expect(farm.get_cell("field_01", "cell_06").stage == "young", "35 percent is young")
		farm.settle(START + duration - 0.01)
		_expect(farm.get_cell("field_01", "cell_06").stage == "young", "Just before maturity stays young")
		var result: Dictionary = farm.harvest("field_01", "cell_06", START + duration)
		_expect(result.ok and result.reward_crop_id == crop_id and result.reward_amount == 1, "Harvest settles exactly to maturity and awards one basket")
		_expect(farm.get_cell("field_01", "cell_06").stage == "empty" and farm.snapshot().harvested[crop_id] == 1, "Harvest clears selected cell")
		_expect(not farm.harvest("field_01", "cell_06", START + duration).ok and farm.snapshot().harvested[crop_id] == 1, "Repeated harvest cannot duplicate rewards")
		_expect(farm.sow("field_01", "cell_06", crop_id, START + duration).ok and not farm.get_cell("field_01", "cell_06").watered, "Next round starts cleanly")
		var moist := Farm.new(START)
		moist.sow("field_01", "cell_01", crop_id, START)
		moist.water("field_01", "cell_01", START + 60.0)
		var benefit: float = Crops.definition(crop_id).water_progress
		_expect(is_equal_approx(moist.get_cell("field_01", "cell_01").growth_seconds, 60.0 + duration * benefit), "Species water benefit applied after old-time settlement")
		var dry := Farm.new(START)
		dry.sow("field_01", "cell_01", crop_id, START)
		moist.settle(START + duration * (1.0 - benefit))
		dry.settle(START + duration * (1.0 - benefit))
		_expect(moist.get_cell("field_01", "cell_01").stage == "mature" and dry.get_cell("field_01", "cell_01").stage != "mature", "Water cuts the configured duration for " + crop_id)
	var watered := Farm.new(START)
	watered.sow("field_01", "cell_06", "greens", START)
	_expect(watered.water("field_01", "cell_06", START + 900.0).ok, "Water action settles old progress first")
	_expect(is_equal_approx(watered.get_cell("field_01", "cell_06").progress, 0.7), "Water adds 20 percent of full duration")
	var before_repeat: Dictionary = watered.snapshot()
	_expect(not watered.water("field_01", "cell_06", START + 1000.0).ok and watered.snapshot() == before_repeat, "Repeated water is a total no-op")
	watered.settle(START + 1440.0)
	_expect(watered.get_cell("field_01", "cell_06").stage == "mature", "One watering reduces greens wait to 24 minutes")
	var near_mature := Farm.new(START)
	near_mature.sow("field_01", "cell_06", "greens", START)
	near_mature.water("field_01", "cell_06", START + 1700.0)
	_expect(near_mature.get_cell("field_01", "cell_06").progress == 1.0, "Water crossing maturity caps at full progress")
	_expect(near_mature.snapshot().harvested.greens == 0, "Maturity never auto-harvests")


func _test_elapsed_time_equivalence() -> void:
	var online := Farm.new(START)
	var offline := Farm.new(START)
	online.sow("field_01", "cell_06", "radish", START)
	offline.sow("field_01", "cell_06", "radish", START)
	for second: int in range(1, 2401):
		online.settle(START + float(second))
	offline.settle(START + 2400.0)
	_expect(online.snapshot() == offline.snapshot(), "2400 online settlements equal one offline settlement")
	online.water("field_01", "cell_06", START + 2400.0)
	offline.water("field_01", "cell_06", START + 2400.0)
	var restored := Farm.new(0.0)
	_expect(restored.restore_snapshot(offline.snapshot()), "Restore saved crop and watering state")
	for second: int in range(2401, 4321):
		online.settle(START + float(second))
	restored.settle(START + 4320.0)
	_expect(online.snapshot() == restored.snapshot(), "Restored offline state matches continued online watering growth")
	_expect(restored.get_cell("field_01", "cell_06").stage == "mature", "Watered radish matures after 72 minutes")
	var once: Dictionary = restored.snapshot()
	restored.settle(START + 4320.0)
	_expect(restored.snapshot() == once, "Repeated settlement at same timestamp is idempotent")


func _test_clock_rollback_and_jump() -> void:
	var farm := Farm.new(START)
	farm.sow("field_01", "cell_06", "greens", START)
	farm.settle(START + 300.0)
	var latest: Dictionary = farm.snapshot()
	farm.settle(START - 3600.0)
	farm.settle(START + 299.0)
	farm.settle(START + 300.0)
	_expect(farm.snapshot() == latest, "Rollback and catch-up preserve newer baseline without extra growth")
	_expect(farm.sow("field_02", "cell_06", "radish", START - 1000.0).ok, "Sowing during rollback is accepted")
	_expect(farm.get_cell("field_02", "cell_06").last_settled_utc_seconds == START + 300.0, "Rollback sowing retains newer empty-field baseline")
	farm.settle(START + 301.0)
	_expect(farm.get_cell("field_01", "cell_06").growth_seconds == 301.0 and farm.get_cell("field_02", "cell_06").growth_seconds == 1.0, "Only time after newer baseline counts")
	var far_future: float = START + 86400.0 * 365.0
	farm.settle(far_future)
	_expect(farm.get_cell("field_01", "cell_06").progress == 1.0 and farm.get_cell("field_02", "cell_06").progress == 1.0, "One-year forward jump caps each current round")
	_expect(Crops.total_harvested(farm.snapshot().harvested) == 0, "Forward jump never awards automatic baskets")
	farm.harvest("field_01", "cell_06", START)
	farm.sow("field_01", "cell_06", "greens", START)
	farm.settle(far_future)
	_expect(farm.get_cell("field_01", "cell_06").growth_seconds == 0.0 and farm.snapshot().harvested.greens == 1, "Harvest and resow under rollback cannot reuse the prior round's time")
	farm.settle(far_future + 1.0)
	_expect(farm.get_cell("field_01", "cell_06").growth_seconds == 1.0, "Clock resumes after catching newer baseline")


func _test_invalid_actions_are_atomic() -> void:
	var farm := Farm.new(START)
	var before: Dictionary = farm.snapshot()
	_expect(not farm.sow("field_01", "cell_06", "unknown", START + 99.0).ok, "Reject invalid crop")
	_expect(not farm.sow("missing", "cell_06", "greens", START + 99.0).ok, "Reject invalid field")
	_expect(not farm.sow("field_04", "cell_06", "greens", START + 99.0).ok, "Reject occupied field")
	_expect(not farm.water("field_01", "cell_06", START + 99.0).ok, "Reject empty-field watering")
	_expect(not farm.water("field_03", "cell_06", START + 99.0).ok, "Reject mature watering")
	_expect(not farm.harvest("field_01", "cell_06", START + 99.0).ok, "Reject empty-field harvest")
	_expect(not farm.harvest("field_04", "cell_06", START + 99.0).ok, "Reject immature harvest")
	_expect(not farm.water("field_04", "cell_06", START + 1800.0).ok, "Water is rejected if old-state settlement already reaches maturity")
	_expect(farm.snapshot() == before, "All failed actions preserve complete authority including timestamps")
	for invalid_time: float in [-1.0, INF, NAN]:
		_expect(not farm.settle(invalid_time).ok and not farm.sow("field_01", "cell_06", "greens", invalid_time).ok, "Reject nonfinite or negative UTC")
	_expect(farm.snapshot() == before and farm.get_cell("missing", "cell_06").is_empty(), "Invalid input cannot mutate farm")


func _test_snapshot_validation() -> void:
	var farm := Farm.new(START)
	var original: Dictionary = farm.snapshot()
	var json_value: Dictionary = JSON.parse_string(JSON.stringify(original))
	_expect(farm.restore_snapshot(json_value), "JSON numeric representation restores valid farm")
	json_value.fields.field_04.cells.cell_06.growth_seconds = 999.0
	_expect(farm.get_cell("field_04", "cell_06").growth_seconds == 360.0, "Restore deep copies nested data")
	var corruptions: Array[Dictionary] = []
	var candidate: Dictionary = original.duplicate(true)
	candidate.fields.erase("field_06")
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.fields.field_04.cells.cell_06.crop_id = "missing"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.fields.field_04.cells.cell_06.growth_seconds = 1800.1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.fields.field_01.cells.cell_06.watered = true
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.fields.field_05.cells.cell_06.watered = true
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.fields.field_04.cells.cell_06.last_settled_utc_seconds = INF
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.harvested.greens = 0.5
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.harvested.greens = -1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.harvested.greens = "2"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.harvested.greens = 9007199254740992
	corruptions.append(candidate)
	for malformed_cell: String in ["missing", "extra", "renamed", "extra_field_key", "legacy_shape"]:
		candidate = original.duplicate(true)
		match malformed_cell:
			"missing": candidate.fields.field_01.cells.erase("cell_16")
			"extra": candidate.fields.field_01.cells.cell_17 = candidate.fields.field_01.cells.cell_01.duplicate()
			"renamed":
				candidate.fields.field_01.cells.unknown = candidate.fields.field_01.cells.cell_16
				candidate.fields.field_01.cells.erase("cell_16")
			"extra_field_key": candidate.fields.field_01.crop_id = "greens"
			"legacy_shape": candidate.fields.field_01 = candidate.fields.field_01.cells.cell_06
		corruptions.append(candidate)
	for broken: Dictionary in corruptions:
		_expect(not farm.restore_snapshot(broken) and farm.snapshot() == original, "Malformed restore preserves prior valid farm")
	candidate = original.duplicate(true)
	candidate.harvested.greens = Farm.MAX_HARVEST_COUNT
	_expect(farm.restore_snapshot(candidate), "Maximum exact count is valid")
	var before_harvest: Dictionary = farm.snapshot()
	_expect(not farm.harvest("field_03", "cell_06", START).ok and farm.snapshot() == before_harvest, "Count overflow cannot lose mature crop")


## Every persisted time field goes through `_valid_time`. An unbounded baseline
## such as 1e300 is finite but no real clock would ever pass it, so the cell
## settles never again and a building's done_utc holds its slot forever. The
## exact-JSON bound is the same one NatureState and the world envelope use.
func _test_time_bounds() -> void:
	var farm := Farm.new(START)
	var live: Dictionary = farm.snapshot()
	var far_future: float = 1.0e300

	var bad_cell: Dictionary = live.duplicate(true)
	bad_cell.fields.field_01.cells.cell_01.last_settled_utc_seconds = far_future
	_expect(not farm.restore_snapshot(bad_cell),
		"A cell baseline beyond the time bound is rejected")

	var bad_building: Dictionary = live.duplicate(true)
	bad_building.buildings = {"yard_a": {
		"blueprint": "cottage", "owner": PLAYER,
		"started_utc": START, "done_utc": far_future}}
	_expect(not farm.restore_snapshot(bad_building),
		"A building finish beyond the time bound is rejected")

	var bad_theft: Dictionary = live.duplicate(true)
	bad_theft.theft = {PLAYER: {
		"enabled": false, "day": -1, "lost": 0, "last": {OTHER: far_future}}}
	_expect(not farm.restore_snapshot(bad_theft),
		"A theft cooldown beyond the time bound is rejected")

	# The upper bound itself is a valid, JSON-exact timestamp and can form a
	# legal snapshot in every one of those fields.
	var boundary: Dictionary = live.duplicate(true)
	boundary.fields.field_01.cells.cell_01.last_settled_utc_seconds = Farm.MAX_TIME_SECONDS
	boundary.buildings = {"yard_a": {
		"blueprint": "cottage", "owner": PLAYER,
		"started_utc": Farm.MAX_TIME_SECONDS, "done_utc": Farm.MAX_TIME_SECONDS}}
	boundary.theft = {PLAYER: {
		"enabled": false, "day": -1, "lost": 0, "last": {OTHER: Farm.MAX_TIME_SECONDS}}}
	_expect(farm.restore_snapshot(boundary),
		"The exact-JSON time bound is accepted in cells, buildings and theft")
	_expect(farm.snapshot() == boundary,
		"The accepted boundary snapshot becomes the authoritative state")


## A pre-economy v27 document has no bags/theft/buildings/economy table and its
## cells carry the original five keys. Restore adds the canonical fields; the
## restored snapshot must still pass the same strict validation, because the
## authority re-validates it on every restart and save. A property-style write
## on an absent key used to create a StringName key, which the cell validator
## rejects, so the world could be written but never loaded again.
func _test_legacy_snapshot_round_trip() -> void:
	var origin := Farm.new(START)
	var legacy: Dictionary = origin.snapshot()
	for key: String in ["bags", "theft", "buildings", "economy"]:
		legacy.erase(key)
	# A v27 transaction carries only sequence and command_results.
	legacy.transaction.erase("gift_ids")
	for field_id: String in legacy.fields:
		for cell_id: String in legacy.fields[field_id].cells:
			var cell: Dictionary = legacy.fields[field_id].cells[cell_id]
			cell.erase("planted_by")
			cell.erase("moisture")
	_expect(legacy.size() == 10, "The legacy fixture is the ten-key pre-economy farm")
	var restored := Farm.new(START)
	_expect(restored.restore_snapshot(legacy), "A ten-key legacy farm restores")
	_expect(restored.snapshot().transaction.gift_ids.is_empty(),
		"A v27 transaction without a gift id set restores it empty")
	var again: Dictionary = restored.snapshot()
	for field_id: String in again.fields:
		for cell_id: String in again.fields[field_id].cells:
			var cell: Dictionary = again.fields[field_id].cells[cell_id]
			for key: Variant in cell.keys():
				_expect(key is String, "Restored cells carry only String keys")
				break
	_expect(Farm.new(START).restore_snapshot(again),
		"A restored legacy snapshot passes the same validation again")
	var legacy_json: Dictionary = JSON.parse_string(JSON.stringify(legacy))
	var from_json := Farm.new(START)
	_expect(from_json.restore_snapshot(legacy_json)
			and Farm.new(START).restore_snapshot(from_json.snapshot()),
		"A legacy document read back from JSON also round trips")


func _test_variable_fields() -> void:
	var farm := Farm.new(START)
	farm.sow("field_01","cell_06","spinach",START)
	farm.water("field_01","cell_06",START)
	var before: Dictionary = farm.get_cell("field_01","cell_06")
	var plan := Farm.Plan.new()
	plan.fields[0] = Farm.Plan.resized_field(plan.fields[0],5,3,Vector2(3.2,1.61))
	plan.fields[0].yaw = 17.0
	plan.fields[0].position += Vector3(.1,0,.15)
	_expect(plan.fields[0].cells[6]=="cell_06", "New column preserves the occupied row/column ID")
	_expect(farm.apply_layout(plan.snapshot(),START).ok,"Variable rows/columns and moved field accepted")
	_expect(farm.get_cell("field_01","cell_06")==before,"Resizing preserves crop species, water, growth and identity")
	_expect(farm.cell_ids("field_01").size()==15 and farm.get_cell("field_01","cell_17").stage=="empty", "New column starts empty")
	_expect(farm.sow("field_01","cell_17","lettuce",START).ok, "Added IDs are actionable")
	var occupied: Dictionary = farm.snapshot()
	var shrink := Farm.Plan.new()
	_expect(farm.apply_layout(shrink.snapshot(),START+500).reason=="occupied_cell_removed" and farm.snapshot()==occupied,"Shrinking cannot erase a planted new column or advance time")
	plan.fields.reverse()
	_expect(farm.apply_layout(plan.snapshot(),START).ok and farm.field_ids()[5]=="field_01" and farm.get_cell("field_01","cell_06")==before,"Reordering uses IDs, never array indices, for crops")
	var extra: Dictionary = plan.fields[5].duplicate(true)
	extra.id = "field_07"
	extra.position = Vector3(-3.3,.2,6.9)
	plan.fields.append(extra)
	_expect(farm.apply_layout(plan.snapshot(),START).ok and farm.field_ids().size()==7,"Additional field gets independent planting cells")
	_expect(farm.get_cell("field_07","cell_06").crop_id.is_empty(),"New field does not copy crops sharing local cell ID")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(JSON.parse_string(JSON.stringify(farm.snapshot()))),"Variable layout and state restore through JSON")
	_expect(restored.snapshot()==farm.snapshot(),"JSON restores the same normalized spatial and crop state")
	var valid: Dictionary = farm.snapshot()
	for flaw: String in ["missing_layout","duplicate_field","duplicate_cell","zero_rows","huge_rows","tiny_cells","nonfinite","missing_data","extra_data"]:
		var bad: Dictionary = valid.duplicate(true)
		match flaw:
			"missing_layout": bad.erase("layout")
			"duplicate_field": bad.layout.fields[1].id = bad.layout.fields[0].id
			"duplicate_cell": bad.layout.fields[0].cells[1] = bad.layout.fields[0].cells[0]
			"zero_rows": bad.layout.fields[0].rows = 0
			"huge_rows": bad.layout.fields[0].rows = 1000000000
			"tiny_cells": bad.layout.fields[0].size = [.21,.30]
			"nonfinite": bad.layout.fields[0].yaw = NAN
			"missing_data": bad.fields.field_07.cells.erase("cell_06")
			"extra_data": bad.fields.field_07.cells.cell_999 = bad.fields.field_07.cells.cell_06.duplicate()
		_expect(not restored.restore_snapshot(bad) and restored.snapshot()==valid,"Reject malformed variable layout atomically: "+flaw)

func _test_gift_replay_outlives_command_window() -> void:
	# ADR-019 §4.2: the command window only covers short-term retries. A gift
	# has no durable business row, so an accepted gift id must also survive the
	# window in the farm document, and a restart must still reject the replay.
	var farm := Farm.new(START)
	var funded: Dictionary = farm.snapshot()
	funded.bags = {PLAYER: {"greens": Farm.MAX_COMMAND_RESULTS + 2}, OTHER: {}}
	_expect(farm.restore_snapshot(funded), "Gift replay fixture restores a funded sender")
	var commands := Command.new()
	var first_id: String = "gift-evict-000"
	var first: Dictionary = Command.make_gift(first_id, OTHER, "greens", 1, START)
	var accepted: Dictionary = commands.execute(farm, first, PLAYER)
	_expect(accepted.ok and not accepted.duplicate, "The first gift command commits")
	farm.accept(accepted.candidate)
	for index: int in range(1, Farm.MAX_COMMAND_RESULTS + 1):
		var command: Dictionary = Command.make_gift(
			"gift-evict-%03d" % index, OTHER, "greens", 1, START)
		var result: Dictionary = commands.execute(farm, command, PLAYER)
		_expect(result.ok and not result.duplicate, "Gift %d commits" % index)
		farm.accept(result.candidate)
	var after_fill: Dictionary = farm.snapshot()
	_expect(not after_fill.transaction.command_results.has(first_id),
		"The 64-entry command window no longer holds the first gift id")
	_expect(after_fill.transaction.gift_ids.has(first_id),
		"The durable gift set still holds the first gift id")
	_expect(int(farm.bag(PLAYER).greens) == 1
			and int(farm.bag(OTHER).greens) == Farm.MAX_COMMAND_RESULTS + 1,
		"The fixture leaves the sender one basket after 65 gifts")
	var replay: Dictionary = commands.execute(farm, first, PLAYER)
	_expect(replay.ok and replay.duplicate and not replay.has("candidate"),
		"A replay after window eviction is still a duplicate")
	_expect(farm.snapshot() == after_fill,
		"The evicted-window replay transfers nothing")

	# The durable set is part of the farm document, so a restart keeps refusing
	# the id without relying on the in-memory window.
	var directory: String = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/gift-replay-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(directory)
	var store := FarmStore.new(directory)
	_expect(store.load_state().kind == "missing",
		"The gift replay fixture directory starts missing")
	_expect(store.save_state(farm, Decorations.new()).ok,
		"The farm with a durable gift id saves")
	var loaded: Dictionary = FarmStore.new(directory).load_state()
	_expect(loaded.ok and loaded.farm.transaction.gift_ids.has(first_id),
		"The durable gift id survives the document round trip")
	var restarted := Farm.new()
	_expect(restarted.restore_snapshot(loaded.farm), "The restarted farm restores")
	var before_restart_replay: Dictionary = restarted.snapshot()
	var after_restart: Dictionary = Command.new().execute(restarted, first, PLAYER)
	_expect(after_restart.ok and after_restart.duplicate and not after_restart.has("candidate"),
		"A restarted world still rejects the evicted gift id as a duplicate")
	_expect(restarted.snapshot() == before_restart_replay,
		"The post-restart replay transfers nothing")

	# The set is bounded: at the cap, the oldest inserted id is dropped first,
	# and a document above the cap is rejected instead of loaded partially.
	var capped := Farm.new(START)
	var capped_data: Dictionary = capped.snapshot()
	capped_data.bags = {PLAYER: {"greens": 1}, OTHER: {}}
	var seeded: Dictionary = {}
	for index: int in range(Farm.MAX_GIFT_IDS):
		seeded["gift-cap-%04d" % index] = JSON.stringify(
			["gift", OTHER, "greens", 1, START, PLAYER])
	capped_data.transaction.gift_ids = seeded
	var over_cap: Dictionary = capped_data.duplicate(true)
	over_cap.transaction.gift_ids["gift-cap-overflow-row"] = JSON.stringify(
		["gift", OTHER, "greens", 1, START, PLAYER])
	_expect(not Farm.new(START).restore_snapshot(over_cap),
		"A gift id set above its cap is rejected")
	_expect(capped.restore_snapshot(capped_data), "A gift id set at its cap is valid")
	var overflow_id: String = "gift-cap-new"
	var overflow: Dictionary = Command.new().execute(capped,
		Command.make_gift(overflow_id, OTHER, "greens", 1, START), PLAYER)
	_expect(overflow.ok and not overflow.duplicate, "A gift at the set cap still commits")
	capped.accept(overflow.candidate)
	var capped_after: Dictionary = capped.snapshot().transaction.gift_ids
	_expect(capped_after.size() == Farm.MAX_GIFT_IDS
			and not capped_after.has("gift-cap-0000") and capped_after.has(overflow_id),
		"The oldest inserted gift id is evicted first")


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
