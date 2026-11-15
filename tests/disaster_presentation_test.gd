extends SceneTree
## Disaster presentation rules only: deterministic copy for a current disaster
## and a warning, expiry/unknown handling, the HUD visibility decision, and the
## optional visual mood. No rendered frame and no shipped art are needed.

const DisasterMood = preload("res://presentation/disaster_mood.gd")
const Nature = preload("res://farm/nature_state.gd")

const NOW: float = 1800000000.0          # 2027-01-15 08:00 UTC
const BLOCK: float = 21600.0

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_no_event()
	_test_current_disaster()
	_test_warning()
	_test_expiry_and_unknown()
	_test_idempotent()
	_test_visual_mood()
	_test_real_nature_events()
	await process_frame
	for failure: String in failures:
		push_error(failure)
	print("DISASTER_PRESENTATION_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_no_event() -> void:
	var none: Dictionary = DisasterMood.describe({}, {}, NOW)
	_expect(str(none.text).is_empty(), "No event produces no line")
	_expect(str(none.kind).is_empty(), "No event produces no visual kind")
	_expect(int(none.severity) == 0 and not bool(none.warning), "No event has no severity or warning flag")
	_expect(not DisasterMood.hud_visible("", true), "The HUD hides an empty line even when loaded")
	_expect(not DisasterMood.hud_visible("灾害：干旱", false), "The HUD hides every line before loading")
	_expect(DisasterMood.hud_visible("灾害：干旱", true), "The HUD shows a real line once loaded")
	_expect(str(DisasterMood.describe(null, "storm", NOW).text).is_empty(),
		"A non-dictionary current value is treated as empty")
	_expect(str(DisasterMood.describe({}, null, NOW).text).is_empty(),
		"A non-dictionary warning value is treated as empty")
	_expect(str(DisasterMood.describe([], [], NOW).text).is_empty(),
		"Non-dictionary values for both events produce no line")
	_expect(str(DisasterMood.describe({}, {}, -1.0).text).is_empty(),
		"An invalid now value produces no line")
	_expect(str(DisasterMood.describe({}, {}, NAN).text).is_empty(),
		"A non-finite now value produces no line")


func _test_current_disaster() -> void:
	var drought: Dictionary = {
		"kind": "drought", "severity": 2,
		"starts_utc": NOW, "ends_utc": NOW + BLOCK,
	}
	var result: Dictionary = DisasterMood.describe(drought, {}, NOW)
	_expect(str(result.text) == "灾害：干旱（持续至 01-15 14:00 UTC）",
		"A current drought names its kind and end in UTC")
	_expect(str(result.kind) == "drought" and int(result.severity) == 2,
		"A current drought carries its visual kind and severity")
	_expect(not bool(result.warning), "A current disaster is not a warning")

	var storm: Dictionary = {
		"kind": "storm", "severity": 1,
		"starts_utc": NOW, "ends_utc": NOW + BLOCK,
	}
	_expect(str(DisasterMood.describe(storm, {}, NOW).text)
		== "灾害：暴雨（持续至 01-15 14:00 UTC）", "A current storm names its kind")
	_expect(str(DisasterMood.describe(storm, {}, NOW).kind) == "storm",
		"The storm visual kind is distinct from drought")

	var no_end: Dictionary = {"kind": "drought", "starts_utc": NOW}
	_expect(str(DisasterMood.describe(no_end, {}, NOW).text) == "灾害：干旱",
		"A missing end still produces a readable line")

	# The current event wins over a warning; the line stays a single row.
	var warning: Dictionary = {
		"kind": "storm", "starts_utc": NOW + BLOCK, "ends_utc": NOW + 2.0 * BLOCK,
	}
	var both: Dictionary = DisasterMood.describe(drought, warning, NOW)
	_expect(str(both.text).begins_with("灾害：干旱") and not bool(both.warning),
		"A current disaster takes priority over a warning")
	_expect(int(both.severity) == 2, "The current disaster supplies the severity when both exist")


func _test_warning() -> void:
	var warning: Dictionary = {
		"kind": "storm", "severity": 3,
		"starts_utc": NOW + 2.0 * 3600.0, "ends_utc": NOW + 8.0 * 3600.0,
		"lead_seconds": 2.0 * 3600.0,
	}
	var result: Dictionary = DisasterMood.describe({}, warning, NOW)
	_expect(str(result.text) == "预警：暴雨 约 2 小时后", "A future storm warning states its lead in hours")
	_expect(str(result.kind) == "storm", "A warning still names its presentation kind")
	_expect(bool(result.warning) and int(result.severity) == 3,
		"A warning carries its flag and severity, which keep it HUD-only")

	var from_lead: Dictionary = {"kind": "drought", "lead_seconds": 5400.0}
	_expect(str(DisasterMood.describe({}, from_lead, NOW).text) == "预警：干旱 约 2 小时后",
		"A warning without a start can still use its lead seconds")
	var tiny: Dictionary = {"kind": "drought", "lead_seconds": 60.0}
	_expect(str(DisasterMood.describe({}, tiny, NOW).text) == "预警：干旱 约 1 小时后",
		"A sub-hour lead rounds up to one hour")
	var no_lead: Dictionary = {"kind": "storm"}
	_expect(str(DisasterMood.describe({}, no_lead, NOW).text) == "预警：暴雨",
		"A warning without a lead omits the hours clause")
	var prefer_start: Dictionary = {
		"kind": "storm", "starts_utc": NOW + 2.0 * 3600.0, "lead_seconds": 9.0 * 3600.0,
	}
	_expect(str(DisasterMood.describe({}, prefer_start, NOW).text) == "预警：暴雨 约 2 小时后",
		"A start instant wins over a stale lead_seconds value")


func _test_expiry_and_unknown() -> void:
	var expired: Dictionary = {
		"kind": "drought", "starts_utc": NOW - BLOCK, "ends_utc": NOW,
	}
	_expect(str(DisasterMood.describe(expired, {}, NOW).text).is_empty(),
		"A disaster that ended exactly now is expired")
	var long_gone: Dictionary = {
		"kind": "storm", "starts_utc": NOW - BLOCK, "ends_utc": NOW - 1.0,
	}
	_expect(str(DisasterMood.describe(long_gone, {}, NOW).text).is_empty(),
		"A disaster that ended earlier is expired")
	var future_current: Dictionary = {
		"kind": "drought", "starts_utc": NOW + 60.0, "ends_utc": NOW + BLOCK,
	}
	_expect(str(DisasterMood.describe(future_current, {}, NOW).text).is_empty(),
		"A future event passed as current is refused")

	var expired_warning: Dictionary = {
		"kind": "storm", "starts_utc": NOW, "ends_utc": NOW + BLOCK,
	}
	_expect(str(DisasterMood.describe({}, expired_warning, NOW).text).is_empty(),
		"A warning that starts now is stale")
	var old_warning: Dictionary = {
		"kind": "storm", "starts_utc": NOW - BLOCK, "ends_utc": NOW - 1.0,
	}
	_expect(str(DisasterMood.describe({}, old_warning, NOW).text).is_empty(),
		"A warning whose block already ended is stale")

	_expect(str(DisasterMood.describe({"kind": "flood"}, {}, NOW).text).is_empty(),
		"An unknown disaster kind produces no line")
	_expect(str(DisasterMood.describe({}, {"kind": "flood"}, NOW).text).is_empty(),
		"An unknown warning kind produces no line")
	_expect(str(DisasterMood.describe({"kind": "drought", "ends_utc": "later"}, {}, NOW).text).is_empty(),
		"A malformed end time is refused instead of printed")
	_expect(str(DisasterMood.describe({"kind": "drought", "starts_utc": "now"}, {}, NOW).text).is_empty(),
		"A malformed start time is refused instead of printed")


func _test_idempotent() -> void:
	var disaster: Dictionary = {
		"kind": "drought", "severity": 2,
		"starts_utc": NOW, "ends_utc": NOW + BLOCK,
	}
	var warning: Dictionary = {
		"kind": "storm", "severity": 1,
		"starts_utc": NOW + 2.0 * BLOCK, "ends_utc": NOW + 3.0 * BLOCK,
	}
	var before: String = JSON.stringify(disaster) + JSON.stringify(warning)
	var first: String = JSON.stringify(DisasterMood.describe(disaster, warning, NOW))
	var second: String = JSON.stringify(DisasterMood.describe(disaster, warning, NOW))
	_expect(first == second, "The same input produces the same line and kind")
	_expect(JSON.stringify(disaster) + JSON.stringify(warning) == before,
		"Describing an event does not mutate the caller's dictionaries")

	var values: Dictionary = _clock_values(0.0, 1.25)
	var visual_a: String = JSON.stringify(DisasterMood.apply_visual(values.duplicate(), "drought", "clear"))
	var visual_b: String = JSON.stringify(DisasterMood.apply_visual(values.duplicate(), "drought", "clear"))
	_expect(visual_a == visual_b, "The same visual mood produces the same values")


func _test_visual_mood() -> void:
	var base: Dictionary = _clock_values(0.0, 1.25)
	var base_sun: Color = base.sun_color
	var base_backdrop: Color = base.backdrop_tint
	var base_background: Color = base.background
	var drought: Dictionary = DisasterMood.apply_visual(base.duplicate(), "drought", "clear")
	_expect(float(drought.sun_energy) > float(base.sun_energy), "Drought warms and lifts the sun in clear weather")
	var drought_sun: Color = drought.sun_color
	var drought_backdrop: Color = drought.backdrop_tint
	_expect(not drought_sun.is_equal_approx(base_sun), "Drought shifts the sun colour")
	_expect(not drought_backdrop.is_equal_approx(base_backdrop), "Drought dries the backdrop tint")
	_expect(DisasterMood.apply_visual(base.duplicate(), "drought", "rain") == base,
		"Drought adds no warmth under rain")

	var storm: Dictionary = DisasterMood.apply_visual(base.duplicate(), "storm", "rain")
	_expect(float(storm.sun_energy) < float(base.sun_energy), "A storm darkens a rainy scene")
	var storm_background: Color = storm.background
	_expect(not storm_background.is_equal_approx(base_background), "A storm deepens the rainy background")
	_expect(DisasterMood.apply_visual(base.duplicate(), "storm", "clear") == base,
		"A storm adds no tint when the weather is clear")
	_expect(DisasterMood.apply_visual(base.duplicate(), "cloudy_ghost", "rain") == base,
		"An unknown visual kind is a no-op")

	var night: Dictionary = DisasterMood.apply_visual(_clock_values(1.0, 0.0), "drought", "clear")
	_expect(is_finite(float(night.sun_energy)) and float(night.sun_energy) >= 0.0,
		"The drought cue stays finite at night")
	_expect(is_equal_approx(float(night.sun_energy), 0.0),
		"The drought cue is scaled by daylight and leaves the night sun alone")


func _test_real_nature_events() -> void:
	var source := Nature.new(424242)
	var start: float = source.next_disaster_at(NOW)
	_expect(start > 0.0, "The fixture seed derives a future disaster")
	if start <= 0.0:
		return
	var current: Dictionary = source.disaster_at(start)
	var view: Dictionary = {
		"kind": str(current.kind), "severity": int(current.severity),
		"starts_utc": float(current.start_utc), "ends_utc": float(current.end_utc),
	}
	var line: Dictionary = DisasterMood.describe(view, {}, start)
	_expect(str(line.kind) == str(current.kind), "The derived event maps to its visual kind")
	_expect(str(line.text).begins_with("灾害：" + DisasterMood.label(str(current.kind))),
		"The derived event maps to its Chinese label")
	_expect(str(line.text).contains("UTC"), "The derived event prints its end in UTC")

	var warning_start: float = source.next_disaster_at(start - 1.0)
	_expect(is_equal_approx(warning_start, start), "The look-ahead warning names the same start")
	var warning: Dictionary = {
		"kind": str(current.kind), "severity": int(current.severity),
		"starts_utc": start, "ends_utc": float(current.end_utc),
		"lead_seconds": 1.0,
	}
	_expect(str(DisasterMood.describe({}, warning, start - 1.0).text).begins_with("预警："),
		"The same derived event reads as a warning just before it starts")

	var after: float = float(current.end_utc)
	var expired: Dictionary = DisasterMood.describe(view, {}, after)
	_expect(str(expired.text).is_empty(), "The derived event expires at its exact end")


## The keys apply_visual reads, in the shape the clock samples every tick.
func _clock_values(night_weight: float, sun_energy: float) -> Dictionary:
	return {
		"night_weight": night_weight,
		"sun_energy": sun_energy,
		"ambient_energy": 0.115 if night_weight < 0.5 else 0.20,
		"sun_color": Color("fff8ed") if night_weight < 0.5 else Color("a8c5ed"),
		"ambient_color": Color("d8d2bc") if night_weight < 0.5 else Color("8da8cf"),
		"background": Color("dbe2df") if night_weight < 0.5 else Color("465c6c"),
		"sky_top": Color("88acc3") if night_weight < 0.5 else Color("26344d"),
		"sky_horizon": Color("ded8c2") if night_weight < 0.5 else Color("3b485e"),
		"backdrop_tint": Color.WHITE if night_weight < 0.5 else Color("354d69"),
		"water_color": Color("68a4a3") if night_weight < 0.5 else Color("254653"),
	}


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
