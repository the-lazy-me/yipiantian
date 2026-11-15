extends SceneTree
## M6-03 acceptance gap: the risk disaster mode and its farm loss caps.
##
## "gentle" keeps the exact M6-03 derivation and moisture deltas. "risk" makes
## every five-day window eligible and widens severity; FarmState maps a risk
## drought severity to a bounded moisture loss and enforces per-event, per-day
## and per-settlement caps. Growth is never reset by a disaster, and switching
## back to gentle/off never rewrites already-settled moisture. Fixtures stay
## below .local/verification; no scene, network or real clock is involved.

const Farm = preload("res://farm/farm_state.gd")
const Nature = preload("res://farm/nature_state.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")

const BLOCK: float = 21600.0
const DAY: float = 86400.0
# Block-aligned instants (21600 * 83333 and the next UTC-day boundary).
const BLOCK_START: float = 1799992800.0
const DAY_START: float = 1800057600.0
const SEED: int = 424242
const OTHER_SEED: int = 20261115

var checks: int = 0
var failures: Array[String] = []
var test_root: String


## Scripted environment with the same block contract NatureState exposes. The
## mode is a plain variable so a test can switch it between settlements.
class ScriptedEnvironment extends RefCounted:
	const BLOCK_SECONDS: float = 21600.0
	var weather_kind: String = "clear"
	var droughts: Dictionary = {}
	var mode: String = "gentle"

	func _init(kind: String = "clear", drought_by_index: Dictionary = {},
			initial_mode: String = "gentle") -> void:
		weather_kind = kind
		droughts = drought_by_index.duplicate()
		mode = initial_mode

	func get_disaster_mode() -> String:
		return mode

	func weather_at(utc_seconds: float) -> Dictionary:
		if not is_finite(utc_seconds) or utc_seconds < 0.0:
			return {}
		var index: int = int(floor(utc_seconds / BLOCK_SECONDS))
		var start: float = float(index) * BLOCK_SECONDS
		return {
			"index": index,
			"kind": weather_kind,
			"start_utc": start,
			"end_utc": start + BLOCK_SECONDS,
		}

	func disaster_at(utc_seconds: float) -> Dictionary:
		if not is_finite(utc_seconds) or utc_seconds < 0.0:
			return {}
		var index: int = int(floor(utc_seconds / BLOCK_SECONDS))
		var severity: Variant = droughts.get(index)
		if not severity is int:
			return {}
		var start: float = float(index) * BLOCK_SECONDS
		return {
			"kind": "drought",
			"start_utc": start,
			"end_utc": start + BLOCK_SECONDS,
			"severity": int(severity),
		}


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	test_root = project_root.get_base_dir().path_join(
		".local/verification/nature-disaster-risk-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_mode_enum_and_default()
	_test_legacy_documents_still_load()
	_test_risk_is_stronger_and_deterministic()
	_test_risk_reload_never_rerolls()
	_test_per_event_loss_cap()
	_test_daily_loss_cap()
	_test_settlement_loss_cap()
	_test_growth_is_never_zeroed()
	_test_switch_back_keeps_settled_state()
	_test_invalid_values_rejected()
	_test_snapshot_roundtrip()
	_test_authority_risk_switch()
	for failure: String in failures:
		push_error(failure)
	print("NATURE_DISASTER_RISK_TEST checks=%d failures=%d root=%s"
		% [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_mode_enum_and_default() -> void:
	_expect(Nature.DISASTER_MODES == ["gentle", "risk", "off"],
		"The mode enum lists gentle, risk and off in that order")
	_expect(Nature.DEFAULT_DISASTER_MODE == "gentle", "The default mode stays gentle")
	var nature := Nature.new(SEED)
	_expect(nature.get_disaster_mode() == "gentle", "A new world defaults to gentle")
	_expect(nature.snapshot() == {"seed": SEED, "rules_version": Nature.RULES_VERSION},
		"The default snapshot keeps the exact two-key shape")
	_expect(nature.set_disaster_mode("risk"), "The setter accepts the risk mode")
	_expect(nature.get_disaster_mode() == "risk", "The setter reports the risk mode")
	_expect(nature.snapshot().disaster_mode == "risk",
		"A risk world writes its mode explicitly")
	_expect(Nature.DISASTER_MAX_SEVERITY == 3 and Nature.RISK_MAX_SEVERITY == 4,
		"Risk widens the severity range by exactly one step")


func _test_legacy_documents_still_load() -> void:
	# A document written before the switch existed (two keys) and the one
	# explicit older rules version both read as gentle, unchanged.
	for version: int in [Nature.LEGACY_RULES_VERSION, Nature.RULES_VERSION]:
		var state := Nature.new()
		_expect(state.restore_snapshot({"seed": SEED, "rules_version": version}),
			"A version %d document without a mode is accepted" % version)
		_expect(state.get_disaster_mode() == "gentle",
			"A version %d document reads as gentle" % version)
	var off_doc := Nature.new()
	_expect(off_doc.restore_snapshot({"seed": SEED, "rules_version": 2, "disaster_mode": "off"}),
		"The existing off document still restores")


func _test_risk_is_stronger_and_deterministic() -> void:
	var gentle := Nature.new(SEED)
	var risk_a := Nature.new(SEED)
	risk_a.set_disaster_mode("risk")
	var risk_b := Nature.new(SEED)
	risk_b.set_disaster_mode("risk")
	var other := Nature.new(OTHER_SEED)
	other.set_disaster_mode("risk")
	var gentle_events: Array = _scan(gentle, BLOCK_START, 365)
	var risk_events: Array = _scan(risk_a, BLOCK_START, 365)
	var repeat_events: Array = _scan(risk_b, BLOCK_START, 365)
	var other_events: Array = _scan(other, BLOCK_START, 365)
	_expect(not risk_events.is_empty(), "Risk mode has events over a year")
	_expect(risk_events.size() > gentle_events.size(),
		"Risk mode derives strictly more events than gentle for the same seed")
	_expect(JSON.stringify(risk_events) == JSON.stringify(repeat_events),
		"Two risk owners with the same seed derive the identical sequence")
	_expect(JSON.stringify(risk_events) != JSON.stringify(other_events),
		"A different seed derives a different risk sequence")
	# Every gentle event is still an event at the same block in risk mode: risk
	# adds eligible windows, it does not reshuffle existing ones. Severity may
	# differ because the range widened.
	var risk_by_start: Dictionary = {}
	for event: Dictionary in risk_events:
		risk_by_start[str(event.start_utc)] = event
	var preserved: bool = true
	for event: Dictionary in gentle_events:
		var match_event: Variant = risk_by_start.get(str(event.start_utc))
		if not match_event is Dictionary or str(match_event.kind) != str(event.kind):
			preserved = false
	_expect(preserved, "Every gentle event keeps its block and kind in risk mode")
	var risk_severity: int = 0
	var gentle_severity: int = 0
	for event: Dictionary in risk_events:
		risk_severity = maxi(risk_severity, int(event.severity))
	for event: Dictionary in gentle_events:
		gentle_severity = maxi(gentle_severity, int(event.severity))
	_expect(gentle_severity <= Nature.DISASTER_MAX_SEVERITY,
		"Gentle severity never exceeds its declared bound")
	_expect(risk_severity > Nature.DISASTER_MAX_SEVERITY,
		"Risk severity reaches the widened bound")
	var spaced: bool = true
	var windows: Dictionary = {}
	for event: Dictionary in risk_events:
		var window_index: int = int(floor(float(event.start_utc) / (5.0 * DAY)))
		if windows.has(window_index):
			spaced = false
		windows[window_index] = true
	_expect(spaced, "Risk keeps at most one event per five-day window")
	# The look-ahead must agree with the scan in risk mode too.
	var from: float = BLOCK_START + float(Nature.BLOCKS_PER_DAY) * BLOCK
	var next: float = risk_a.next_disaster_at(from)
	var expected: float = risk_a.disaster_at(next).start_utc if next >= 0.0 else -1.0
	_expect(next >= 0.0 and is_equal_approx(next, expected),
		"The risk look-ahead lands on a real derived event")
	# The stronger derivation must not touch the weather sequence.
	var weather_identical: bool = true
	for offset: int in 200:
		var at: float = BLOCK_START + float(offset) * BLOCK
		if gentle.weather_at(at) != risk_a.weather_at(at):
			weather_identical = false
	_expect(weather_identical, "Risk mode never changes the weather sequence")


func _test_risk_reload_never_rerolls() -> void:
	var risk := Nature.new(SEED)
	risk.set_disaster_mode("risk")
	var before: Array = _scan(risk, BLOCK_START, 180)
	var reloaded := Nature.new()
	_expect(reloaded.restore_snapshot(risk.snapshot()), "A risk snapshot restores")
	_expect(reloaded.get_disaster_mode() == "risk", "The restored mode is risk")
	var after: Array = _scan(reloaded, BLOCK_START, 180)
	_expect(JSON.stringify(before) == JSON.stringify(after),
		"Reloading the seed and mode never rerolls the risk sequence")
	_expect(reloaded.snapshot() == risk.snapshot(),
		"The restored snapshot is byte-identical")
	# A snapshot written before risk existed cannot acquire risk losses.
	var legacy := Nature.new()
	legacy.restore_snapshot({"seed": SEED, "rules_version": 2})
	_expect(legacy.get_disaster_mode() == "gentle",
		"A legacy document reloads as gentle, never risk")


func _test_per_event_loss_cap() -> void:
	# One completed drought block, severity 1 vs 4. Morning weather is cloudy so
	# the moisture drop is exactly the disaster loss on top of a small drain.
	for case: Array in [[1, 0.0625], [4, 0.1875]]:
		var severity: int = int(case[0])
		var expected_loss: float = float(case[1])
		var index: int = int(DAY_START / BLOCK)
		var env := ScriptedEnvironment.new("cloudy", {index: severity}, "risk")
		var reference_env := ScriptedEnvironment.new("cloudy", {}, "risk")
		var farm := Farm.new(DAY_START, {}, env)
		var reference := Farm.new(DAY_START, {}, reference_env)
		for target: RefCounted in [farm, reference]:
			_expect(target.sow("field_01", "cell_01", "radish", DAY_START).ok,
				"The per-event fixture sows a radish")
			_expect(target.water("field_01", "cell_01", DAY_START).ok,
				"The per-event fixture fills the cell's moisture")
		_expect(farm.settle(DAY_START + BLOCK).ok, "One risk drought block settles")
		_expect(reference.settle(DAY_START + BLOCK).ok, "The reference block settles")
		var got: float = float(farm.get_cell("field_01", "cell_01").moisture)
		var base: float = float(reference.get_cell("field_01", "cell_01").moisture)
		_expect(is_equal_approx(base - got, expected_loss),
			"Severity %d takes exactly %.4f moisture" % [severity, expected_loss])
		_expect(expected_loss <= Farm.RISK_DROUGHT_MAX_LOSS,
			"One event never exceeds the per-event cap")


func _test_daily_loss_cap() -> void:
	# Four successive drought blocks inside one UTC day. Uncapped they would take
	# 4 * 0.1875 = 0.75; the day budget stops the total at 0.5.
	var first_index: int = int(DAY_START / BLOCK)
	var droughts: Dictionary = {}
	for offset: int in 4:
		droughts[first_index + offset] = 4
	var env := ScriptedEnvironment.new("cloudy", droughts, "risk")
	var reference_env := ScriptedEnvironment.new("cloudy", {}, "risk")
	var farm := Farm.new(DAY_START, {}, env)
	var reference := Farm.new(DAY_START, {}, reference_env)
	for target: RefCounted in [farm, reference]:
		target.sow("field_01", "cell_01", "radish", DAY_START)
		target.water("field_01", "cell_01", DAY_START)
	_expect(farm.settle(DAY_START + 4.0 * BLOCK).ok, "A full risk day settles in one call")
	_expect(reference.settle(DAY_START + 4.0 * BLOCK).ok, "The full-day reference settles")
	var base: float = float(reference.get_cell("field_01", "cell_01").moisture)
	var got: float = float(farm.get_cell("field_01", "cell_01").moisture)
	_expect(got >= 0.0, "Moisture never goes negative under a drought burst")
	_expect(is_equal_approx(base - got, Farm.RISK_CELL_DAILY_LOSS_MAX),
		"A day of drought bursts loses exactly the daily cap, not the raw sum")
	_expect(base - got <= Farm.RISK_CELL_DAILY_LOSS_MAX,
		"The daily loss never exceeds its cap")


func _test_settlement_loss_cap() -> void:
	# Neutral weather isolates the disaster budget: only the drought moves
	# moisture. Forty severity-4 droughts over ten days would take 7.5 if
	# uncapped; one long catch-up must take at most RISK_SETTLE_LOSS_MAX.
	var first_index: int = int(DAY_START / BLOCK)
	var droughts: Dictionary = {}
	for offset: int in 10 * Nature.BLOCKS_PER_DAY:
		droughts[first_index + offset] = 4
	var one_shot_env := ScriptedEnvironment.new("", droughts, "risk")
	var split_env := ScriptedEnvironment.new("", droughts, "risk")
	var one_shot := Farm.new(DAY_START, {}, one_shot_env)
	var split := Farm.new(DAY_START, {}, split_env)
	for target: RefCounted in [one_shot, split]:
		target.sow("field_01", "cell_01", "radish", DAY_START)
		target.water("field_01", "cell_01", DAY_START)
	var end: float = DAY_START + 10.0 * DAY
	_expect(one_shot.settle(end).ok, "A ten-day risk catch-up settles in one call")
	for day: int in 10:
		_expect(split.settle(DAY_START + float(day + 1) * DAY).ok,
			"Split risk day %d settles" % (day + 1))
	var one_shot_moisture: float = float(one_shot.get_cell("field_01", "cell_01").moisture)
	var split_moisture: float = float(split.get_cell("field_01", "cell_01").moisture)
	_expect(is_equal_approx(1.0 - one_shot_moisture, Farm.RISK_SETTLE_LOSS_MAX),
		"A long catch-up stops at the per-settlement loss cap")
	_expect(one_shot_moisture >= split_moisture - 0.000001,
		"A long offline catch-up is never harsher than the split online path")
	_expect(one_shot_moisture >= 0.0 and split_moisture >= 0.0,
		"No settlement path drains moisture below zero")


func _test_growth_is_never_zeroed() -> void:
	var first_index: int = int(DAY_START / BLOCK)
	var droughts: Dictionary = {}
	for offset: int in 60 * Nature.BLOCKS_PER_DAY:
		droughts[first_index + offset] = 4
	var env := ScriptedEnvironment.new("clear", droughts, "risk")
	var farm := Farm.new(DAY_START, {}, env)
	_expect(farm.sow("field_01", "cell_01", "radish", DAY_START).ok,
		"The growth fixture sows a radish")
	var growth: float = 0.0
	var monotonic: bool = true
	var positive: bool = true
	for day: int in 60:
		_expect(farm.settle(DAY_START + float(day + 1) * DAY).ok,
			"Growth day %d settles" % (day + 1))
		var cell: Dictionary = farm.get_cell("field_01", "cell_01")
		var current: float = float(cell.growth_seconds)
		if current + 0.000001 < growth:
			monotonic = false
		if current <= 0.0:
			positive = false
		if is_equal_approx(float(cell.moisture), 0.0):
			_expect(current > 0.0, "A dry risk cell keeps its accumulated growth")
		growth = current
	_expect(monotonic, "Growth never decreases under repeated risk droughts")
	_expect(positive, "Growth stays above zero; a disaster never resets it")
	_expect(farm.get_cell("field_01", "cell_01").stage == "mature",
		"A risk crop still matures and is not destroyed")
	var harvest: Dictionary = farm.harvest("field_01", "cell_01", DAY_START + 60.0 * DAY)
	_expect(harvest.ok and int(harvest.reward_amount) == 1,
		"A risk crop still yields exactly one basket")
	var mature_before: float = float(farm.get_cell("field_03", "cell_06").growth_seconds)
	_expect(mature_before > 0.0, "The initial mature batch is present")
	_expect(farm.get_cell("field_03", "cell_06").stage == "mature",
		"The initial mature batch survives risk droughts")


func _test_switch_back_keeps_settled_state() -> void:
	var first_index: int = int(DAY_START / BLOCK)
	var env := ScriptedEnvironment.new("", {first_index: 4}, "risk")
	var farm := Farm.new(DAY_START, {}, env)
	farm.sow("field_01", "cell_01", "radish", DAY_START)
	farm.water("field_01", "cell_01", DAY_START)
	_expect(farm.settle(DAY_START + DAY).ok, "A risk day settles before the switch")
	var settled: Dictionary = farm.snapshot()
	var moisture: float = float(farm.get_cell("field_01", "cell_01").moisture)
	var growth: float = float(farm.get_cell("field_01", "cell_01").growth_seconds)
	_expect(moisture < Farm.MOISTURE_MAX, "The risk drought actually moved moisture")
	_expect(growth > 0.0, "The risk day actually advanced growth")
	# Same instant after the switch: already-settled state must not be recomputed.
	env.mode = "gentle"
	_expect(farm.settle(DAY_START + DAY).ok,
		"Settling again at the same instant is a no-op")
	_expect(farm.get_cell("field_01", "cell_01").moisture == moisture,
		"Switching to gentle never recomputes settled moisture")
	_expect(farm.get_cell("field_01", "cell_01").growth_seconds == growth,
		"Switching to gentle never recomputes settled growth")
	_expect(farm.snapshot() == settled,
		"Switching to gentle never rewrites the settled snapshot")
	env.mode = "off"
	_expect(farm.settle(DAY_START + DAY).ok, "The off switch also settles as a no-op")
	_expect(farm.snapshot() == settled,
		"Switching to off never rewrites the settled snapshot")
	# A future off day applies only the weather delta from the settled value;
	# no risk loss is invented retroactively. Unknown weather kind is neutral, so
	# the moisture must not move at all.
	_expect(farm.settle(DAY_START + 2.0 * DAY).ok, "A future off day settles")
	_expect(float(farm.get_cell("field_01", "cell_01").moisture) == moisture,
		"A future off day starts from the settled moisture, not from a re-derivation")
	_expect(float(farm.get_cell("field_01", "cell_01").growth_seconds) >= growth,
		"Growth is never rolled back after the switch")


func _test_invalid_values_rejected() -> void:
	for bad: Variant in [true, 1, 0.0, "", "harsh", "RISK", null, ["risk"]]:
		_expect(not Nature.valid_disaster_mode(bad),
			"Invalid mode is rejected: " + str(bad))
		var state: Dictionary = {"seed": SEED, "rules_version": 2, "disaster_mode": bad}
		_expect(not Nature.new().restore_snapshot(state),
			"A snapshot with an invalid mode is refused: " + str(bad))
	var guard := Nature.new(SEED)
	_expect(not guard.set_disaster_mode("harsh"), "The setter rejects an unknown mode")
	_expect(guard.get_disaster_mode() == "gentle",
		"A rejected setter leaves the mode unchanged")
	for mode: String in Nature.DISASTER_MODES:
		_expect(Nature.valid_disaster_mode(mode), "The declared mode is accepted: " + mode)


func _test_snapshot_roundtrip() -> void:
	for mode: String in ["risk", "off", "gentle"]:
		var source := Nature.new(SEED)
		_expect(source.set_disaster_mode(mode), "The fixture switches to " + mode)
		var snapshot: Dictionary = source.snapshot()
		var restored := Nature.new()
		_expect(restored.restore_snapshot(snapshot), "The %s snapshot restores" % mode)
		_expect(restored.get_disaster_mode() == mode,
			"The %s mode survives the roundtrip" % mode)
		_expect(restored.snapshot() == snapshot,
			"The %s snapshot stays byte-identical" % mode)
		# A JSON roundtrip mirrors a real save document.
		var json_snapshot: Variant = JSON.parse_string(JSON.stringify(snapshot))
		_expect(json_snapshot is Dictionary and restored.restore_snapshot(json_snapshot),
			"The %s snapshot survives JSON" % mode)


func _test_authority_risk_switch() -> void:
	# The authority already accepted any valid mode; this pins that "risk" is one
	# of them, that it survives a save, and that an authoritative risk world
	# settles exactly like a single-player farm on the same mode and seed.
	var directory: String = test_root.path_join("authority-risk")
	var world := HeadlessWorld.new()
	_expect(world.open(directory, BLOCK_START).ok, "The authority opens an isolated world")
	world.nature = Nature.new(SEED)
	world.farm.set_environment(world.nature)
	var switched: Dictionary = world.set_disaster_mode("risk")
	_expect(switched.ok and str(switched.kind) == "saved",
		"The authority accepts and persists the risk mode")
	_expect(world.nature.get_disaster_mode() == "risk",
		"The authority state holds the risk mode")
	_expect(str(world.nature_view().disaster_mode) == "risk",
		"The nature summary exposes the authoritative risk mode")
	_expect(world.set_disaster_mode("harsh").reason == "invalid_mode",
		"The authority still refuses an unknown mode")
	_expect(str(world.set_disaster_mode("risk").kind) == "unchanged",
		"Setting risk twice is an honest no-op")

	var events: Array = _scan(world.nature, BLOCK_START, 120)
	var top: int = 0
	for event: Dictionary in events:
		top = maxi(top, int(event.get("severity", 0)))
	_expect(top == Nature.RISK_MAX_SEVERITY,
		"The authoritative risk sequence reaches severity %d" % Nature.RISK_MAX_SEVERITY)

	var single := Farm.new(BLOCK_START, {}, world.nature)
	_expect(world.farm.sow("field_01", "cell_01", "carrot", BLOCK_START).ok,
		"The authority sows a carrot under risk")
	_expect(single.sow("field_01", "cell_01", "carrot", BLOCK_START).ok,
		"The single-player fixture sows the same carrot")
	var target: float = BLOCK_START + 20.0 * DAY
	_expect(world.advance_to(target).ok, "The authority advances a 20-day risk span")
	_expect(single.settle(target).ok, "The single-player farm settles the same span")
	var authority_cell: Dictionary = world.farm.get_cell("field_01", "cell_01")
	var single_cell: Dictionary = single.get_cell("field_01", "cell_01")
	_expect(is_equal_approx(float(authority_cell.moisture), float(single_cell.moisture)),
		"Authority and single-player risk moisture agree")
	_expect(world.farm.snapshot() == single.snapshot(),
		"Authority and single-player risk worlds settle identically")
	_expect(float(authority_cell.moisture) >= 0.0 and float(authority_cell.moisture) <= 1.0,
		"Risk moisture stays inside 0-1")
	_expect(float(authority_cell.growth_seconds) >= 0.0,
		"Risk never produces negative growth")
	_expect(world.save().ok, "The authority commits the risk world")

	var reopened := HeadlessWorld.new()
	_expect(reopened.open(directory, target).ok, "The authority risk world reopens")
	_expect(reopened.nature.get_disaster_mode() == "risk",
		"Reopening keeps the persisted risk mode")
	_expect(reopened.farm.snapshot() == world.farm.snapshot(),
		"Reopening keeps the exact risk farm state")
	var kept: Dictionary = reopened.farm.snapshot()
	_expect(str(reopened.set_disaster_mode("gentle").kind) == "saved",
		"The reopened world can switch back to gentle")
	_expect(reopened.farm.snapshot() == kept,
		"Switching risk back to gentle never rewrites settled state")


func _scan(nature: RefCounted, from_utc: float, days: int) -> Array:
	var result: Array = []
	var first_index: int = int(floorf(from_utc / BLOCK))
	for offset: int in days * Nature.BLOCKS_PER_DAY:
		var at: float = float(first_index + offset) * BLOCK
		var event: Dictionary = nature.disaster_at(at)
		if not event.is_empty():
			result.append(event)
	return result


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		print("PASS " + message)
	else:
		failures.append(message)
		print("FAIL " + message)
