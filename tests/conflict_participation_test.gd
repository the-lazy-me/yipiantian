extends SceneTree
## M12-02 conflict participation: pure, headless rule tests. No scene, no clock,
## no RNG, no network, no save document. Every command gets an explicit UTC time.
## The final line is the CI evidence.

const Participation = preload("res://conflict/participation_state.gd")

const START: float = 1800000000.0
const HOUR: float = 3600.0
const WORLD: String = "world-conflict-a"
const OTHER_WORLD: String = "world-conflict-b"
const HOST: String = "player_00000000000000000000000000000001"
const ATTACKER: String = "player_00000000000000000000000000000002"
const DEFENDER: String = "player_00000000000000000000000000000003"
const OUTSIDER: String = "player_00000000000000000000000000000004"
const NEIGHBOR: String = "player_00000000000000000000000000000005"

const AREA_A_ID: String = "zone_a"
const AREA_B_ID: String = "zone_b"
const WINDOW_1_ID: String = "window_1"
const WINDOW_2_ID: String = "window_2"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_peace_default()
	_test_declaration_validation()
	_test_declaration_durability()
	_test_scoped_engagement_checks()
	_test_consent()
	_test_offline_loss_cap()
	_test_revision_resets_consent_and_losses()
	_test_withdrawal_delay()
	_test_idempotency_and_durable_replay()
	_test_document_validity()
	_test_serialization_and_forgery()
	_test_determinism_and_bounds()
	for failure: String in failures:
		push_error(failure)
	print("CONFLICT_PARTICIPATION_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_peace_default() -> void:
	var state: Dictionary = Participation.initial_state(WORLD, HOST)
	_expect(Participation.valid(state), "The default peace document is valid")
	_expect(state.regime.tier == Participation.TIER_PEACE, "A new room defaults to peace")
	_expect(state.regime.revision == 0 and state.regime.declaration_id.is_empty(),
		"A default peace room has no declaration and revision zero")
	_expect(state.regime.higher_risk == false and state.regime.loss_cap == 0
		and state.regime.offline_loss_cap == 0, "A default room declares no risk or budget")
	_expect(state.areas.is_empty() and state.windows.is_empty(),
		"A default room declares no area and no window")

	var before: Dictionary = state.duplicate(true)
	var result: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START, 10, false, "engage-in-peace")
	_expect(not result.ok and result.reason == "peace",
		"The same attack is refused in a peace room")
	_expect(state == before, "A peace refusal changes nothing")
	var consent: Dictionary = Participation.declare_participation(state, WORLD, ATTACKER,
		Participation.ROLE_ATTACKER, "consent-in-peace", START)
	_expect(not consent.ok and consent.reason == "peace",
		"Participation cannot be declared in a peace room")
	_expect(Participation.area_at(state, 1, 1).is_empty(), "A peace room has no declared area")
	_expect(Participation.window_at(state, START).is_empty(), "A peace room has no window")
	_expect(not Participation.consent_active(state, ATTACKER, Participation.ROLE_ATTACKER,
		START), "No one has consent in a peace room")
	_expect(not Participation.withdraw(state, WORLD, ATTACKER, "withdraw-in-peace",
		START).ok, "A peace-only visitor cannot withdraw")


func _test_declaration_validation() -> void:
	var state: Dictionary = Participation.initial_state(WORLD, HOST)
	_expect(Participation.declare_regime(state, WORLD, ATTACKER, _limited("d-1", START),
		"declare-1", START).reason == "not_host", "Only the room host may declare a regime")
	_expect(Participation.declare_regime(state, OTHER_WORLD, HOST, _limited("d-1", START),
		"declare-2", START).reason == "wrong_world", "A declaration must carry this world")
	_expect(Participation.declare_regime(state, WORLD, HOST, _limited("d-1", START),
		"", START).reason == "invalid_command", "An empty declaration command id is refused")
	_expect(Participation.declare_regime(state, WORLD, HOST, _limited("d-1", START),
		"declare-3", -1.0).reason == "invalid_time", "A negative declaration time is refused")
	_expect(Participation.declare_regime(state, WORLD, HOST, _limited("d-1", START),
		"declare-4", INF).reason == "invalid_time", "A non-finite declaration time is refused")
	_expect(Participation.declare_regime(state, WORLD, HOST, "not a declaration",
		"declare-5", START).reason == "invalid_declaration", "A non-dictionary declaration is refused")

	var no_risk: Dictionary = _declaration("d-no-risk", Participation.TIER_LIMITED, START,
		false, [_area(AREA_A_ID, 0, 0, 9, 9)], [_window(WINDOW_1_ID, START, START + HOUR)],
		100, 30)
	_expect(Participation.declare_regime(state, WORLD, HOST, no_risk, "declare-6", START)
		.reason == "risk_not_declared", "Limited conflict without a higher-risk declaration is refused")

	var no_scope: Dictionary = _declaration("d-no-scope", Participation.TIER_LIMITED, START,
		true, [], [_window(WINDOW_1_ID, START, START + HOUR)], 100, 30)
	_expect(Participation.declare_regime(state, WORLD, HOST, no_scope, "declare-7", START)
		.reason == "invalid_regime", "Higher risk without declared areas is refused")
	var no_window: Dictionary = _declaration("d-no-window", Participation.TIER_LIMITED, START,
		true, [_area(AREA_A_ID, 0, 0, 9, 9)], [], 100, 30)
	_expect(Participation.declare_regime(state, WORLD, HOST, no_window, "declare-8", START)
		.reason == "invalid_regime", "Higher risk without a declared window is refused")
	var zero_cap: Dictionary = _declaration("d-zero", Participation.TIER_LIMITED, START,
		true, [_area(AREA_A_ID, 0, 0, 9, 9)], [_window(WINDOW_1_ID, START, START + HOUR)],
		0, 0)
	_expect(Participation.declare_regime(state, WORLD, HOST, zero_cap, "declare-9", START)
		.reason == "invalid_regime", "Higher risk without a loss cap is refused")
	var offline_above: Dictionary = _declaration("d-offline", Participation.TIER_LIMITED, START,
		true, [_area(AREA_A_ID, 0, 0, 9, 9)], [_window(WINDOW_1_ID, START, START + HOUR)],
		30, 100)
	_expect(Participation.declare_regime(state, WORLD, HOST, offline_above, "declare-10", START)
		.reason == "invalid_regime", "An offline cap above the total cap is refused")
	var overlapping_areas: Dictionary = _declaration("d-overlap-area",
		Participation.TIER_LIMITED, START, true,
		[_area(AREA_A_ID, 0, 0, 9, 9), _area(AREA_B_ID, 9, 0, 19, 9)],
		[_window(WINDOW_1_ID, START, START + HOUR)], 100, 30)
	_expect(Participation.declare_regime(state, WORLD, HOST, overlapping_areas,
		"declare-11", START).reason == "overlapping_areas",
		"Declared areas may not overlap, not even on a shared edge")
	var touching_areas: Dictionary = _declaration("d-touch-area",
		Participation.TIER_LIMITED, START, true,
		[_area(AREA_A_ID, 0, 0, 9, 9), _area(AREA_B_ID, 10, 0, 19, 9)],
		[_window(WINDOW_1_ID, START, START + HOUR)], 100, 30)
	_expect(Participation.declare_regime(state, WORLD, HOST, touching_areas,
		"declare-touch", START).ok,
		"Touching but non-overlapping rectangles are accepted")
	var rejected_after_accept: Dictionary = _declaration("d-bad-window",
		Participation.TIER_LIMITED, START + 1.0, true,
		[_area("zone_c", 100, 100, 109, 109)],
		[_window("window_x", START, START + 2.0 * HOUR),
		_window("window_y", START + HOUR, START + 3.0 * HOUR)], 100, 30)
	_expect(Participation.declare_regime(state, WORLD, HOST, rejected_after_accept,
		"declare-bad-window", START + 1.0).reason == "overlapping_windows",
		"A declaration is all-or-nothing: a bad window rejects the whole change")
	_expect(state.regime.declaration_id == "d-touch-area" and state.regime.revision == 1,
		"A rejected declaration changes no regime")
	_expect(not state.areas.has("zone_c") and not state.windows.has("window_x"),
		"A rejected declaration adds no new area or window row")

	var own_area_overlap: Dictionary = _declaration("d-own-overlap",
		Participation.TIER_LIMITED, START + 2.0, true,
		[_area("zone_c", 0, 0, 9, 9), _area("zone_d", 5, 5, 14, 14)],
		[_window("window_x", START, START + HOUR)], 100, 30)
	_expect(Participation.declare_regime(state, WORLD, HOST, own_area_overlap,
		"declare-own-overlap", START + 2.0).reason == "overlapping_areas",
		"One declaration cannot declare two overlapping areas")
	_expect(Participation.valid(state), "The state after the rejections is still valid")

	var overlapping_windows: Dictionary = _declaration("d-overlap-window",
		Participation.TIER_LIMITED, START, true,
		[_area(AREA_A_ID, 0, 0, 9, 9)],
		[_window(WINDOW_1_ID, START, START + HOUR),
		_window(WINDOW_2_ID, START + HOUR - 1.0, START + 2.0 * HOUR)], 100, 30)
	_expect(Participation.declare_regime(state, WORLD, HOST, overlapping_windows,
		"declare-13", START).reason == "overlapping_windows",
		"Declared windows may not overlap")
	var empty_window: Dictionary = _declaration("d-empty-window",
		Participation.TIER_LIMITED, START, true,
		[_area(AREA_A_ID, 0, 0, 9, 9)],
		[_window(WINDOW_1_ID, START, START)], 100, 30)
	_expect(Participation.declare_regime(state, WORLD, HOST, empty_window,
		"declare-14", START).reason == "invalid_window", "A half-open zero-length window is refused")
	var bad_coord: Dictionary = _declaration("d-coord", Participation.TIER_LIMITED, START,
		true, [_area(AREA_A_ID, 0, 0, Participation.MAX_COORD + 1, 9)],
		[_window(WINDOW_1_ID, START, START + HOUR)], 100, 30)
	_expect(Participation.declare_regime(state, WORLD, HOST, bad_coord, "declare-15", START)
		.reason == "invalid_area", "An out-of-range coordinate is refused")
	var reversed: Dictionary = _declaration("d-reversed", Participation.TIER_LIMITED, START,
		true, [_area(AREA_A_ID, 9, 9, 0, 0)], [_window(WINDOW_1_ID, START, START + HOUR)],
		100, 30)
	_expect(Participation.declare_regime(state, WORLD, HOST, reversed, "declare-16", START)
		.reason == "invalid_area", "A reversed rectangle is refused")
	var duplicate_area: Dictionary = _declaration("d-dupe", Participation.TIER_LIMITED, START,
		true, [_area(AREA_A_ID, 0, 0, 9, 9), _area(AREA_A_ID, 10, 0, 19, 9)],
		[_window(WINDOW_1_ID, START, START + HOUR)], 100, 30)
	_expect(Participation.declare_regime(state, WORLD, HOST, duplicate_area,
		"declare-17", START).reason == "duplicate_area", "Duplicate area ids are refused")
	var early_effective: Dictionary = _declaration("d-early", Participation.TIER_LIMITED,
		START, true, [_area(AREA_A_ID, 0, 0, 9, 9)],
		[_window(WINDOW_1_ID, START, START + HOUR)], 100, 30)
	early_effective.effective_utc = START - 1.0
	_expect(Participation.declare_regime(state, WORLD, HOST, early_effective,
		"declare-18", START).reason == "invalid_declaration",
		"A declaration cannot take effect before it is declared")

	var peace_with_scope: Dictionary = _declaration("d-peace-scope", Participation.TIER_PEACE,
		START, false, [_area(AREA_A_ID, 0, 0, 9, 9)], [], 0, 0)
	_expect(Participation.declare_regime(state, WORLD, HOST, peace_with_scope,
		"declare-19", START).reason == "invalid_regime",
		"A peace declaration cannot carry a risk scope")


func _test_declaration_durability() -> void:
	var state: Dictionary = Participation.initial_state(WORLD, HOST)
	var declaration: Dictionary = _limited("d-limited-1", START)
	var accepted: Dictionary = Participation.declare_regime(state, WORLD, HOST,
		declaration, "declare-main", START)
	_expect(accepted.ok and not accepted.duplicate and accepted.subject == "d-limited-1",
		"The host publishes the limited higher-risk declaration")
	_expect(state.regime.revision == 1, "The first declaration bumps the regime revision")
	_expect(state.regime.declaration_id == "d-limited-1", "The declaration id is durable")
	_expect(state.regime.declared_by == HOST, "The declaration records who declared it")
	_expect(state.regime.declared_utc == START, "The declaration records when it was declared")
	_expect(state.regime.higher_risk and state.regime.loss_cap == 100
		and state.regime.offline_loss_cap == 30, "The declaration records the risk and caps")
	_expect(state.regime.area_ids == [AREA_A_ID, AREA_B_ID], "The declaration records its areas")
	_expect(state.regime.window_ids == [WINDOW_1_ID, WINDOW_2_ID],
		"The declaration records its windows")
	_expect(state.areas.has(AREA_A_ID) and state.windows.has(WINDOW_1_ID),
		"Areas and windows are stored as durable rows")
	_expect(Participation.valid(state), "The declared document is valid")
	_expect(Participation.area_at(state, 0, 0) == AREA_A_ID, "Area lookup is inclusive")
	_expect(Participation.area_at(state, 19, 9) == AREA_B_ID, "The second area is addressable")
	_expect(Participation.area_at(state, 10, 10).is_empty(), "A point outside every area is refused")
	_expect(Participation.window_at(state, START) == WINDOW_1_ID, "A window includes its start")
	_expect(Participation.window_at(state, START + 2.0 * HOUR).is_empty(),
		"A window excludes its end")
	_expect(Participation.window_at(state, START + HOUR) == WINDOW_2_ID,
		"Touching windows do not overlap")

	var snapshot: Dictionary = state.duplicate(true)
	var replay: Dictionary = Participation.declare_regime(state, WORLD, HOST, declaration,
		"declare-main", START)
	_expect(replay.ok and replay.duplicate, "Replaying the declaration returns the first result")
	_expect(state == snapshot, "A replayed declaration changes nothing")
	var conflict: Dictionary = Participation.declare_regime(state, WORLD, HOST,
		_limited("d-limited-1b", START), "declare-main", START)
	_expect(not conflict.ok and conflict.reason == "command_conflict",
		"Reusing a declaration command id for another declaration is a conflict")
	var reused_declaration: Dictionary = Participation.declare_regime(state, WORLD, HOST,
		declaration, "declare-new-id", START)
	_expect(not reused_declaration.ok and reused_declaration.reason == "declaration_conflict",
		"The same declaration id cannot be republished under a new command")
	var regressed: Dictionary = Participation.declare_regime(state, WORLD, HOST,
		_limited("d-limited-2", START - 10.0), "declare-early", START - 10.0)
	_expect(not regressed.ok and regressed.reason == "time_regression",
		"A declaration before the current one is refused")


func _test_scoped_engagement_checks() -> void:
	var state: Dictionary = _active_state()
	_expect(Participation.valid(state), "The prepared limited document is valid")
	_expect(Participation.consent_active(state, ATTACKER, Participation.ROLE_ATTACKER, START),
		"The attacker consent is active")
	_expect(Participation.consent_active(state, DEFENDER, Participation.ROLE_DEFENDER, START),
		"The defender consent is active")

	var before_effective: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER,
		1, 1, START - 1.0, 10, true, "engage-before")
	_expect(not before_effective.ok and before_effective.reason == "regime_not_effective",
		"An engagement before the regime takes effect is refused")
	var outside: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER,
		50, 50, START + 10.0, 10, true, "engage-outside-area")
	_expect(not outside.ok and outside.reason == "area_not_declared",
		"An engagement outside every declared area is refused")
	var before_window: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER,
		1, 1, START - 1.0, 10, true, "engage-before-window")
	_expect(not before_window.ok and before_window.reason == "regime_not_effective",
		"The regime gate is checked before the window gate")
	var after_window: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER,
		1, 1, START + 2.0 * HOUR, 10, true, "engage-after-window")
	_expect(not after_window.ok and after_window.reason == "outside_window",
		"An engagement after the declared window is refused")
	var at_end: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER,
		1, 1, START + HOUR, 10, true, "engage-window-end")
	_expect(at_end.ok and at_end.window_id == WINDOW_2_ID,
		"A half-open boundary belongs to the next declared window")
	_expect(not Participation.engage(state, WORLD, OUTSIDER, DEFENDER, 1, 1,
		START + 10.0, 10, true, "engage-not-attacker").ok,
		"A player without attacker consent cannot attack")
	_expect(not Participation.engage(state, WORLD, ATTACKER, OUTSIDER, 1, 1,
		START + 10.0, 10, true, "engage-not-target").ok,
		"A player who never consented is not a legal target")
	_expect(Participation.engage(state, OTHER_WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 10.0, 10, true, "engage-wrong-world").reason == "wrong_world",
		"An engagement carrying another world id is refused")
	_expect(Participation.engage(state, WORLD, ATTACKER, ATTACKER, 1, 1,
		START + 10.0, 10, true, "engage-self").reason == "same_player",
		"A player cannot attack themselves")
	_expect(Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 10.0, 0, true, "engage-zero").reason == "invalid_amount",
		"A zero loss is not an engagement")
	_expect(Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 10.0, -5, true, "engage-negative").reason == "invalid_amount",
		"A negative loss is refused")
	# `engage()` takes a typed int, so a fractional amount can only enter through
	# a forged document; the validator must still reject it.
	_expect(not Participation.valid(_with_amount(state, "engage-window-end", 10.5)),
		"A document with a fractional engagement amount is refused")
	_expect(Participation.engage(state, WORLD, ATTACKER, DEFENDER, -1, 1,
		START + 10.0, 10, true, "engage-neg-pos").reason == "invalid_position",
		"A negative position is refused")
	_expect(Participation.engage(state, WORLD, ATTACKER, DEFENDER,
		Participation.MAX_COORD + 1, 1, START + 10.0, 10, true, "engage-big-pos")
		.reason == "invalid_position", "A position beyond the grid bound is refused")
	_expect(not Participation.valid(_with_presence(state, "yes")),
		"A document whose engagement presence flag is not a boolean is refused")

	var first: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER, 2, 3,
		START + 10.0, 25, true, "engage-1")
	_expect(first.ok and not first.duplicate, "A fully scoped engagement settles")
	_expect(first.window_id == WINDOW_1_ID and first.loss_total == 25 and first.cap == 100,
		"The settlement reports the window, running total and cap")
	_expect(state.losses[DEFENDER + "|" + WINDOW_1_ID].amount == 25,
		"The loss row records the cumulative loss")
	_expect(state.engagements.has("engage-1") and state.engagements["engage-1"].area_id == AREA_A_ID,
		"The engagement is a durable row naming its area")
	_expect(Participation.valid(state), "The settled document is valid")


func _test_consent() -> void:
	var state: Dictionary = Participation.initial_state(WORLD, HOST)
	Participation.declare_regime(state, WORLD, HOST, _limited("d-consent", START),
		"declare-consent", START)
	var bad_role: Dictionary = Participation.declare_participation(state, WORLD, ATTACKER,
		"raider", "consent-bad-role", START)
	_expect(not bad_role.ok and bad_role.reason == "invalid_role",
		"An unknown participation role is refused")
	_expect(Participation.declare_participation(state, WORLD, "public",
		Participation.ROLE_ATTACKER, "consent-public", START).reason == "invalid_player",
		"The public pseudo-owner cannot participate")
	_expect(Participation.declare_participation(state, WORLD, ATTACKER,
		Participation.ROLE_ATTACKER, "consent-attacker", START).ok,
		"An attacker can explicitly declare participation")
	_expect(state.participants[ATTACKER].attacker and not state.participants[ATTACKER].defender,
		"The attacker consent records the attacker role")
	_expect(state.participants[ATTACKER].consent_revision == state.regime.revision,
		"Consent is bound to the current regime revision")
	_expect(Participation.valid(state), "The consented document is valid")

	var target_missing: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER,
		1, 1, START + 10.0, 10, true, "engage-target-missing")
	_expect(not target_missing.ok and target_missing.reason == "target_not_participating",
		"A defender who never consented cannot be attacked")
	var no_attacker: Dictionary = Participation.engage(state, WORLD, OUTSIDER, DEFENDER,
		1, 1, START + 10.0, 10, true, "engage-attacker-missing")
	_expect(not no_attacker.ok and no_attacker.reason == "attacker_not_consented",
		"An attacker without consent is refused")
	_expect(not Participation.consent_active(state, DEFENDER, Participation.ROLE_DEFENDER,
		START), "An absent player has no active defender consent")
	_expect(Participation.declare_participation(state, WORLD, DEFENDER,
		Participation.ROLE_DEFENDER, "consent-defender", START + 5.0).ok,
		"The defender can accept being a legal target")
	_expect(Participation.consent_active(state, DEFENDER, Participation.ROLE_DEFENDER,
		START + 5.0), "The defender consent becomes active at its declared time")
	_expect(not Participation.consent_active(state, DEFENDER, Participation.ROLE_DEFENDER,
		START + 4.0), "The defender consent is not backdated")
	_expect(not Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 1.0, 10, true, "engage-before-consent").ok,
		"An engagement before the target consent is refused")
	_expect(Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 10.0, 10, true, "engage-consented").ok,
		"Both parties consenting lets one scoped engagement settle")
	_expect(Participation.valid(state), "The consented engagement document is valid")
	var replay: Dictionary = Participation.declare_participation(state, WORLD, ATTACKER,
		Participation.ROLE_ATTACKER, "consent-attacker", START)
	_expect(replay.ok and replay.duplicate, "Replaying a participation command is idempotent")
	_expect(Participation.declare_participation(state, WORLD, ATTACKER,
		Participation.ROLE_ATTACKER, "consent-attacker", START - 1.0).reason
		== "command_conflict", "Reusing a consent command id with another time is a conflict")
	_expect(Participation.declare_participation(state, WORLD, ATTACKER,
		Participation.ROLE_DEFENDER, "consent-attacker", START).reason
		== "command_conflict", "Reusing a consent command id with another role is a conflict")


func _test_offline_loss_cap() -> void:
	var state: Dictionary = _active_state()
	var first: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 10.0, 20, false, "offline-1")
	_expect(first.ok and first.cap == 30, "An offline defender uses the offline cap")
	_expect(Participation.loss_total(state, DEFENDER, WINDOW_1_ID) == 20,
		"The cumulative offline loss is recorded")
	var second: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 20.0, 10, false, "offline-2")
	_expect(second.ok and second.loss_total == 30,
		"An offline defender can be brought up to the offline cap")
	_expect(Participation.consent_active(state, DEFENDER,
		Participation.ROLE_DEFENDER, START + 20.0),
		"Consent and presence are independent: consent is still active")
	var snapshot: Dictionary = state.duplicate(true)
	var over: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 30.0, 1, false, "offline-3")
	_expect(not over.ok and over.reason == "loss_cap_exceeded",
		"An offline defender cannot be drained past the offline cap")
	_expect(over.cap == 30 and over.loss_total == 30,
		"The refusal reports the stable cap and the saturated total")
	_expect(state == snapshot, "An over-cap refusal changes no loss and no engagement")
	var offline_large: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER,
		1, 1, START + 30.0, 71, false, "offline-large")
	_expect(not offline_large.ok and offline_large.reason == "loss_cap_exceeded",
		"A single oversized offline loss is refused")

	var online: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 40.0, 70, true, "online-1")
	_expect(online.ok and online.cap == 100 and online.loss_total == 100,
		"An online defender may reach the overall cap, never beyond it")
	var beyond: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 50.0, 1, true, "online-2")
	_expect(not beyond.ok and beyond.reason == "loss_cap_exceeded",
		"The same target and window cannot exceed the cap across online and offline attacks")
	_expect(Participation.loss_total(state, DEFENDER, WINDOW_1_ID) == 100,
		"The cumulative total is the sum of settled engagements only")
	_expect(Participation.valid(state), "The saturated document is still valid")

	var other_window: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER,
		1, 1, START + HOUR + 10.0, 40, true, "window-2-attack")
	_expect(other_window.ok and other_window.window_id == WINDOW_2_ID,
		"A different declared window has its own budget")
	_expect(Participation.loss_total(state, DEFENDER, WINDOW_2_ID) == 40,
		"The second window tracks its own cumulative loss")
	_expect(Participation.loss_total(state, NEIGHBOR, WINDOW_2_ID) == 0,
		"Another target has no losses")
	_expect(Participation.engage(state, WORLD, ATTACKER, NEIGHBOR, 1, 1,
		START + HOUR + 20.0, 25, true, "neighbor-1").ok,
		"Another legal target is not capped by the first target's losses")


func _test_revision_resets_consent_and_losses() -> void:
	var state: Dictionary = _active_state()
	Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1, START + 10.0, 20, true,
		"rev-engage-1")
	var bumped: Dictionary = Participation.declare_regime(state, WORLD, HOST,
		_limited("d-limited-2", START + 30.0), "declare-bump", START + 30.0)
	_expect(bumped.ok and state.regime.revision == 2,
		"A second host declaration bumps the revision")
	_expect(state.participants[ATTACKER].consent_revision == 1,
		"Old consent rows stay as durable history")
	_expect(not Participation.consent_active(state, ATTACKER, Participation.ROLE_ATTACKER,
		START + 40.0), "A new declaration makes earlier consent stale")
	_expect(not Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 40.0, 10, true, "rev-stale").ok,
		"The host cannot silently enlarge risk for people who already signed up")
	_expect(state.participants[ATTACKER].consent_revision == 1,
		"A refused stale engagement does not alter consent")
	_expect(Participation.declare_participation(state, WORLD, ATTACKER,
		Participation.ROLE_ATTACKER, "rev-consent-attacker", START + 40.0).ok,
		"The attacker can re-consent to the new regime")
	_expect(Participation.declare_participation(state, WORLD, DEFENDER,
		Participation.ROLE_DEFENDER, "rev-consent-defender", START + 40.0).ok,
		"The defender can re-consent to the new regime")
	_expect(Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 50.0, 10, true, "rev-engage-2").ok,
		"A re-consented pair may engage under the new revision")
	_expect(state.engagements["rev-engage-2"].revision == 2,
		"The engagement records the revision it was settled under")
	_expect(Participation.loss_total(state, DEFENDER, WINDOW_1_ID) == 30,
		"Losses accumulate across revisions inside the same declared window")
	_expect(Participation.valid(state), "The re-declared document is valid")

	# Re-consenting as only a defender must not quietly revive an earlier
	# attacker flag from a previous revision.
	_expect(Participation.declare_participation(state, WORLD, DEFENDER,
		Participation.ROLE_ATTACKER, "rev-defender-was-attacker", START + 45.0).ok,
		"The defender may also declare the attacker role")
	_expect(state.participants[DEFENDER].attacker and state.participants[DEFENDER].defender,
		"Both roles are recorded for the re-consented participant")
	Participation.declare_regime(state, WORLD, HOST, _limited("d-limited-2b", START + 55.0),
		"declare-bump-2", START + 55.0)
	_expect(state.regime.revision == 3, "The room moves to a third revision")
	_expect(Participation.declare_participation(state, WORLD, DEFENDER,
		Participation.ROLE_DEFENDER, "rev-defender-only", START + 65.0).ok,
		"The participant re-consents as a defender under the new revision")
	_expect(not state.participants[DEFENDER].attacker and state.participants[DEFENDER].defender,
		"A stale attacker flag does not revive when the revision changes")
	_expect(Participation.valid(state), "The revision-scoped consent document is valid")

	var same_scope: Dictionary = _limited("d-limited-3", START + 70.0)
	_expect(Participation.declare_regime(state, WORLD, HOST, same_scope,
		"declare-same-scope", START + 70.0).ok,
		"Re-declaring the same scope is allowed but still bumps the revision")
	_expect(state.regime.revision == 4 and not Participation.consent_active(state, ATTACKER,
		Participation.ROLE_ATTACKER, START + 75.0),
		"Even an identical re-declaration requires fresh consent")

	# De-escalating back to peace is a new revision that refuses all attacks.
	var peace: Dictionary = _declaration("d-peace", Participation.TIER_PEACE,
		START + 80.0, false, [], [], 0, 0)
	_expect(Participation.declare_regime(state, WORLD, HOST, peace, "declare-peace",
		START + 80.0).ok, "The host can de-escalate the room back to peace")
	_expect(state.regime.tier == Participation.TIER_PEACE and state.regime.revision == 5,
		"De-escalation is a durable higher revision")
	_expect(Participation.valid(state), "A document de-escalated to peace is valid")
	_expect(not Participation.declare_participation(state, WORLD, ATTACKER,
		Participation.ROLE_ATTACKER, "consent-after-peace", START + 90.0).ok,
		"No participation can be declared after de-escalation")
	_expect(Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 90.0, 5, true, "engage-after-peace").reason == "peace",
		"After de-escalation every attack is refused again")
	_expect(Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 50.0, 10, true, "rev-engage-2").ok,
		"A confirmed engagement replays after de-escalation instead of being refused")
	_expect(state.engagements["rev-engage-2"].revision == 2,
		"The replayed engagement keeps its original revision")
	_expect(Participation.loss_total(state, DEFENDER, WINDOW_1_ID) == 30,
		"Replaying a confirmed engagement after de-escalation does not add loss")
	_expect(Participation.loss_total(state, DEFENDER, WINDOW_1_ID) == 30,
		"De-escalation keeps the already settled losses as durable history")
	_expect(state.areas.has(AREA_A_ID) and state.windows.has(WINDOW_1_ID),
		"An area and window that still explain a settled engagement are retained")
	_expect(!state.areas.has(AREA_B_ID) and !state.windows.has(WINDOW_2_ID),
		"De-escalation drops scope rows that no settled engagement references")
	_expect(Participation.valid(JSON.parse_string(JSON.stringify(state))),
		"A de-escalated document survives a JSON round trip")


func _test_withdrawal_delay() -> void:
	var state: Dictionary = _active_state()
	var withdraw_time: float = START + 10.0
	var effective: float = withdraw_time + Participation.WITHDRAWAL_DELAY_SECONDS
	var declared: Dictionary = Participation.withdraw(state, WORLD, ATTACKER,
		"withdraw-attacker", withdraw_time)
	_expect(declared.ok and not declared.duplicate, "A participant can declare withdrawal")
	_expect(state.participants[ATTACKER].withdraw_utc == withdraw_time,
		"The withdrawal time is recorded")
	_expect(state.participants[ATTACKER].withdraw_effective_utc == effective,
		"The withdrawal becomes effective only after the fixed delay")
	_expect(Participation.consent_active(state, ATTACKER, Participation.ROLE_ATTACKER,
		effective - 1.0), "During the delay the participant is still active")
	_expect(Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		effective - 1.0, 10, true, "delay-engage").ok,
		"New commands still settle during the withdrawal delay")
	var pending: Dictionary = Participation.declare_participation(state, WORLD, ATTACKER,
		Participation.ROLE_ATTACKER, "rejoin-pending", effective - 1.0)
	_expect(not pending.ok and pending.reason == "withdrawal_pending",
		"Re-joining cannot cancel a withdrawal already in flight")
	_expect(float(state.participants[ATTACKER].withdraw_utc) == withdraw_time,
		"A refused re-join leaves the pending withdrawal untouched")
	_expect(state.participants[ATTACKER].attacker,
		"A refused re-join leaves the existing consent intact")
	var again: Dictionary = Participation.withdraw(state, WORLD, ATTACKER,
		"withdraw-again", effective - 1.0)
	_expect(not again.ok and again.reason == "withdrawal_pending",
		"A second withdrawal while the first is pending is refused")
	_expect(not Participation.consent_active(state, ATTACKER, Participation.ROLE_ATTACKER,
		effective), "At the delay boundary the participant is inactive")
	var blocked: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		effective, 10, true, "after-withdraw-attacker")
	_expect(not blocked.ok and blocked.reason == "attacker_withdrawn",
		"After the delay the attacker's new commands are refused")
	var accepted_at: float = float(state.engagements["delay-engage"].at_utc)
	_expect(accepted_at == effective - 1.0,
		"The engagement confirmed during the delay keeps its original result")
	_expect(Participation.loss_total(state, DEFENDER, WINDOW_2_ID) == 10,
		"An already confirmed engagement is not rolled back by the withdrawal")
	_expect(Participation.valid(state), "The withdrawn document is valid")

	var rejoin: Dictionary = Participation.declare_participation(state, WORLD, ATTACKER,
		Participation.ROLE_ATTACKER, "rejoin", effective)
	_expect(rejoin.ok and state.participants[ATTACKER].withdraw_utc == 0.0,
		"After the delay a participant can consent again explicitly")
	_expect(Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1,
		effective + 5.0, 5, true, "rejoin-engage").ok,
		"Re-consented participation can settle again")
	_expect(Participation.withdraw(state, WORLD, ATTACKER, "withdraw-again", effective + 10.0)
		.ok, "A participant may withdraw again after the previous one completed")

	var target_state: Dictionary = _active_state()
	var target_withdraw: float = START + 20.0
	var target_effective: float = target_withdraw + Participation.WITHDRAWAL_DELAY_SECONDS
	_expect(Participation.withdraw(target_state, WORLD, DEFENDER, "withdraw-defender",
		target_withdraw).ok, "The defender can also withdraw")
	_expect(Participation.engage(target_state, WORLD, ATTACKER, DEFENDER, 1, 1,
		target_effective - 1.0, 10, true, "target-delay-engage").ok,
		"The defender can still be attacked during the delay")
	var target_blocked: Dictionary = Participation.engage(target_state, WORLD, ATTACKER,
		DEFENDER, 1, 1, target_effective, 10, true, "target-after-withdraw")
	_expect(not target_blocked.ok and target_blocked.reason == "target_withdrawn",
		"After the defender's withdrawal new attacks against them are refused")
	_expect(Participation.loss_total(target_state, DEFENDER, WINDOW_2_ID) == 10,
		"The earlier confirmed loss against the withdrawn defender is retained")
	_expect(not Participation.withdraw(target_state, WORLD, OUTSIDER, "withdraw-outsider",
		START + 30.0).ok, "A non-participant cannot withdraw")


func _test_idempotency_and_durable_replay() -> void:
	var state: Dictionary = _active_state()
	var first: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER, 4, 5,
		START + 15.0, 30, true, "engage-idem")
	_expect(first.ok and first.loss_total == 30, "The first engagement settles once")
	var replayed: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER, 4, 5,
		START + 15.0, 30, true, "engage-idem")
	_expect(replayed.ok and replayed.duplicate, "Replaying the engagement returns duplicate")
	_expect(replayed.loss_total == 30 and Participation.loss_total(state, DEFENDER,
		WINDOW_1_ID) == 30, "Replaying the engagement does not double the loss")
	_expect(state.engagements.size() == 1, "Replaying the engagement does not add a row")
	var forged: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER, 4, 5,
		START + 15.0, 31, true, "engage-idem")
	_expect(not forged.ok and forged.reason == "command_conflict",
		"Reusing an engagement id with another amount is a conflict")

	# Simulate the bounded command-result window having evicted the row: the
	# engagement row itself must still make the retry idempotent.
	state.command_results = {}
	_expect(Participation.valid(state), "The document stays valid after command-window eviction")
	var durable: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER, 4, 5,
		START + 15.0, 30, true, "engage-idem")
	_expect(durable.ok and durable.duplicate,
		"A durable engagement row replays after the command window evicts the result")
	_expect(Participation.loss_total(state, DEFENDER, WINDOW_1_ID) == 30,
		"A durable replay still does not double the loss")
	var durable_conflict: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER,
		4, 6, START + 15.0, 30, true, "engage-idem")
	_expect(not durable_conflict.ok and durable_conflict.reason == "command_conflict",
		"A durable row rejects a retry with different coordinates")
	var next: Dictionary = Participation.engage(state, WORLD, ATTACKER, DEFENDER, 6, 6,
		START + 16.0, 10, true, "engage-next")
	_expect(next.ok and next.loss_total == 40, "A new command id settles normally")
	_expect(state.engagements.size() == 2, "Each command id owns exactly one engagement")

	# An evicted consent id must not be reusable by another player, or the
	# resulting document would fail its own validation.
	var consented: Dictionary = _active_state()
	consented.command_results = {}
	_expect(Participation.declare_participation(consented, WORLD, OUTSIDER,
		Participation.ROLE_ATTACKER, "active-attacker", START + 5.0).reason
		== "command_conflict",
		"An evicted consent command id cannot be reused by another player")
	_expect(not consented.participants.has(OUTSIDER),
		"The refused consent adds no participant row")
	_expect(Participation.valid(consented),
		"A document after the refused consent reuse stays valid")
	var withdrawn: Dictionary = _active_state()
	Participation.withdraw(withdrawn, WORLD, ATTACKER, "withdraw-evicted", START + 5.0)
	withdrawn.command_results = {}
	_expect(Participation.withdraw(withdrawn, WORLD, DEFENDER, "withdraw-evicted",
		START + 6.0).reason == "command_conflict",
		"An evicted withdrawal id cannot be reused by another player")
	_expect(Participation.valid(withdrawn),
		"A document after the refused withdrawal reuse stays valid")
	var collided: Dictionary = _active_state()
	collided.command_results = {}
	_expect(Participation.declare_regime(collided, WORLD, HOST,
		_limited("d-collision", START + 5.0), "active-attacker", START + 5.0).reason
		== "command_conflict",
		"A declaration cannot reuse an evicted consent command id")
	_expect(collided.regime.revision == 1,
		"The refused colliding declaration does not bump the revision")
	_expect(Participation.valid(collided),
		"A document after the refused declaration collision stays valid")


func _test_document_validity() -> void:
	var state: Dictionary = _active_state()
	Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1, START + 10.0, 20, true,
		"valid-engage")
	_expect(Participation.valid(state), "The reference document is valid")
	_expect(not Participation.valid([]), "A non-dictionary document is refused")
	_expect(not Participation.valid({}), "An empty document is refused")
	for key: String in Participation.STATE_KEYS:
		_expect(_rejects(state, func(copy: Dictionary) -> void: copy.erase(key)),
			"Removing the %s key is refused" % key)
	_expect(_rejects(state, func(copy: Dictionary) -> void: copy.extra = true),
		"An unknown top-level key is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void: copy.world_id = "bad world"),
		"An illegal world id is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void: copy.host = "public"),
		"An illegal host is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void: copy.sequence = -1),
		"A negative sequence is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void: copy.sequence = 0),
		"A sequence below the engagement count is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void: copy.regime.tier = "war"),
		"An unknown regime tier is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void: copy.regime.higher_risk = false),
		"A limited regime without an active higher-risk declaration is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void: copy.regime.loss_cap = 0),
		"A limited regime without a loss cap is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.regime.offline_loss_cap = copy.regime.loss_cap + 1),
		"An offline cap above the total cap is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void: copy.regime.area_ids = []),
		"A higher-risk regime must list its areas")
	_expect(_rejects(state, func(copy: Dictionary) -> void: copy.regime.area_ids.append("ghost")),
		"A regime area id must resolve to a stored row")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		var regimes: Dictionary = copy.regime
		regimes.declared_utc = 0.0
		regimes.effective_utc = 0.0
		regimes.declaration_id = ""
		regimes.revision = 0
		regimes.higher_risk = false
		regimes.area_ids = []
		regimes.window_ids = []
		regimes.loss_cap = 0
		regimes.offline_loss_cap = 0
		regimes.declared_by = ""
		regimes.command_id = ""
		copy.areas = {}
		copy.windows = {}
		copy.participants = {}
		copy.engagements = {}
		copy.losses = {}
		copy.command_results = {}), "A peace regime carrying rooms is refused")
	var extra_area: Dictionary = state.duplicate(true)
	extra_area.areas["extra"] = {"id": "extra", "min_x": 100, "min_z": 100,
		"max_x": 101, "max_z": 101}
	_expect(Participation.valid(extra_area),
		"An unlisted historical area outside the live scope is allowed")
	_expect(_rejects(state, func(copy: Dictionary) -> void: copy.areas.erase(AREA_A_ID)),
		"A missing live area row is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.areas[AREA_A_ID].max_x = 99),
		"A live area that would overlap another live area is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.windows[WINDOW_1_ID].end_utc = copy.windows[WINDOW_1_ID].start_utc),
		"A zero-length window row is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.windows[WINDOW_1_ID].start_utc = START + HOUR + 10.0),
		"A window row that excludes its own engagement is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.participants[ATTACKER].consent_revision = copy.regime.revision + 1),
		"A participant cannot consent to a future revision")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.participants[ATTACKER].attacker = false), "A participant with no role is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.participants[ATTACKER].withdraw_utc = START + 1.0),
		"A withdrawal without a matching effective time is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		var p: Dictionary = copy.participants[ATTACKER]
		p.withdraw_utc = START + 1.0
		p.withdraw_effective_utc = START + 2.0), "A withdrawal with a wrong delay is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.participants[ATTACKER].consent_utc = START - 5.0),
		"A consent before the declaration is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.engagements["valid-engage"].revision = 0),
		"An engagement must name a real regime revision")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.engagements["valid-engage"].x = 50),
		"An engagement outside its recorded area is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.engagements["valid-engage"].at_utc = START - 100.0),
		"An engagement outside its recorded window is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.engagements["valid-engage"].amount = 21),
		"An engagement that disagrees with the loss row is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.engagements["valid-engage"].cap = 10),
		"An engagement whose amount exceeds its recorded cap is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.engagements["valid-engage"].loss_total_after = 999),
		"An engagement whose running total exceeds the cap is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.losses[DEFENDER + "|" + WINDOW_1_ID].amount = 21),
		"A loss row that disagrees with the engagement sum is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.losses["ghost|" + WINDOW_1_ID] = {"target": "ghost",
			"window_id": WINDOW_1_ID, "amount": 1}),
		"A loss row for an unknown target is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.command_results["forged"] = {"payload": "[]", "result": {}}),
		"A forged command result is refused")
	_expect(_rejects(state, func(copy: Dictionary) -> void:
		copy.command_results["engage-forged"] = {
			"payload": JSON.stringify(["conflict_engage", WORLD, ATTACKER, DEFENDER,
				1, 1, START + 10.0, 20, true]),
			"result": {"ok": true, "reason": "", "duplicate": false,
				"subject": DEFENDER, "window_id": WINDOW_1_ID,
				"loss_total": 20, "cap": 100},
		}), "A command result without a durable engagement row is refused")


func _test_serialization_and_forgery() -> void:
	var state: Dictionary = _active_state()
	Participation.withdraw(state, WORLD, ATTACKER, "serial-withdraw", START + 10.0)
	Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1, START + 11.0, 20, false,
		"serial-engage")
	_expect(Participation.valid(state), "The serialization reference document is valid")
	var encoded: String = JSON.stringify(state)
	var decoded: Variant = JSON.parse_string(encoded)
	_expect(decoded is Dictionary, "The document survives JSON encoding")
	_expect(Participation.valid(decoded), "The decoded document passes validation")
	Participation.normalize(decoded)
	_expect(decoded == state, "normalize restores JSON numbers to the original document")
	_expect(decoded.regime.loss_cap == 100 and decoded.engagements["serial-engage"].amount == 20,
		"normalize restores integer caps and amounts")
	_expect(decoded.regime.declared_utc == START and decoded.participants[ATTACKER]
		.withdraw_effective_utc == START + 10.0 + Participation.WITHDRAWAL_DELAY_SECONDS,
		"normalize restores float times")

	var forged: Dictionary = JSON.parse_string(JSON.stringify(state))
	forged.regime.loss_cap = 1000
	_expect(not Participation.valid(forged),
		"A document that raises the declared cap after the fact is refused")
	var forged_scope: Dictionary = JSON.parse_string(JSON.stringify(state))
	forged_scope.areas[AREA_A_ID].max_x = 4000
	_expect(not Participation.valid(forged_scope),
		"A document that quietly enlarges a declared area is refused")
	var forged_presence: Dictionary = JSON.parse_string(JSON.stringify(state))
	forged_presence.engagements["serial-engage"].defender_online = true
	_expect(not Participation.valid(forged_presence),
		"A document that rewrites offline protection is refused")
	var forged_consent: Dictionary = JSON.parse_string(JSON.stringify(state))
	forged_consent.participants[DEFENDER] = {"participant": DEFENDER, "attacker": false,
		"defender": true, "consent_revision": 1, "consent_utc": START,
		"withdraw_utc": 0.0, "withdraw_effective_utc": 0.0}
	_expect(not Participation.valid(forged_consent),
		"A document that adds a consent no one declared is refused")
	var forged_window: Dictionary = JSON.parse_string(JSON.stringify(state))
	forged_window.windows[WINDOW_1_ID].start_utc = START + HOUR
	_expect(not Participation.valid(forged_window),
		"A document that shortens a declared window is refused")


func _test_determinism_and_bounds() -> void:
	var first: Dictionary = _run_scripted()
	var second: Dictionary = _run_scripted()
	_expect(JSON.stringify(first) == JSON.stringify(second),
		"The same command sequence yields byte-identical documents")
	_expect(Participation.valid(first), "The scripted document is valid")
	_expect(Participation.loss_total(first, DEFENDER, WINDOW_1_ID) == 35,
		"The scripted sequence settles exactly the recorded window-one losses")
	_expect(Participation.loss_total(first, DEFENDER, WINDOW_2_ID) == 20,
		"The scripted sequence settles exactly the recorded window-two losses")
	_expect(first.engagements.size() == 3, "The scripted sequence records exactly three engagements")
	_expect(Participation.engage(first, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 2.0 * HOUR, 1, true, "script-engage-new").reason == "outside_window",
		"A new command after the declared window is refused even though earlier ones settled")
	_expect(first.engagements["script-engage-1"].window_id == WINDOW_1_ID,
		"The first scripted engagement stayed in its original window")

	var fresh: Dictionary = Participation.initial_state(WORLD, HOST)
	_expect(Participation.valid(fresh), "A fresh document has no pending state")
	_expect(not Participation.withdraw(fresh, WORLD, HOST, "withdraw-host", START).ok,
		"The host is not a participant until they consent")
	_expect(Participation.declare_regime(fresh, WORLD, HOST, _limited("d-fresh", START),
		"declare-fresh", START).ok, "The host may declare a first limited regime")
	_expect(not Participation.engage(fresh, WORLD, HOST, HOST, 1, 1, START + 1.0, 5, true,
		"fresh-self").ok, "Self-engagement stays refused under a limited regime")
	_expect(not Participation.engage(fresh, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 1.0, 5, true, "fresh-noconsent").ok,
		"A limited regime alone does not authorize an attack")
	var no_total: Dictionary = Participation.initial_state(WORLD, HOST)
	Participation.declare_regime(no_total, WORLD, HOST, _limited("d-fresh", START),
		"declare-fresh", START)
	_expect(not Participation.declare_participation(no_total, WORLD, OUTSIDER,
		Participation.ROLE_ATTACKER, "consent-before-declare", START - 1.0).ok,
		"A consent before the declaration is refused")


func _run_scripted() -> Dictionary:
	var state: Dictionary = _active_state()
	Participation.engage(state, WORLD, ATTACKER, DEFENDER, 1, 1, START + 10.0, 20, true,
		"script-engage-1")
	Participation.engage(state, WORLD, ATTACKER, DEFENDER, 3, 3, START + 20.0, 15, true,
		"script-engage-2")
	Participation.engage(state, WORLD, ATTACKER, DEFENDER, 5, 5, START + HOUR + 30.0, 20,
		true, "script-engage-3")
	return state


func _active_state() -> Dictionary:
	var state: Dictionary = Participation.initial_state(WORLD, HOST)
	var result: Dictionary = Participation.declare_regime(state, WORLD, HOST,
		_limited("d-active", START), "declare-active", START)
	assert(result.ok, "the test fixture declaration must be accepted")
	assert(Participation.declare_participation(state, WORLD, ATTACKER,
		Participation.ROLE_ATTACKER, "active-attacker", START).ok,
		"the test fixture attacker consent must be accepted")
	assert(Participation.declare_participation(state, WORLD, DEFENDER,
		Participation.ROLE_DEFENDER, "active-defender", START).ok,
		"the test fixture defender consent must be accepted")
	assert(Participation.declare_participation(state, WORLD, NEIGHBOR,
		Participation.ROLE_DEFENDER, "active-neighbor", START).ok,
		"the test fixture neighbor consent must be accepted")
	return state


func _limited(declaration_id: String, declared_utc: float) -> Dictionary:
	return _declaration(declaration_id, Participation.TIER_LIMITED, declared_utc,
		true,
		[_area(AREA_A_ID, 0, 0, 9, 9), _area(AREA_B_ID, 10, 0, 19, 9)],
		[_window(WINDOW_1_ID, START, START + HOUR),
		_window(WINDOW_2_ID, START + HOUR, START + 2.0 * HOUR)],
		100, 30)


func _declaration(declaration_id: String, tier: String, effective_utc: float,
		higher_risk: bool, areas: Array, windows: Array, loss_cap: int,
		offline_cap: int) -> Dictionary:
	return {
		"tier": tier,
		"declaration_id": declaration_id,
		"effective_utc": effective_utc,
		"higher_risk": higher_risk,
		"areas": areas,
		"windows": windows,
		"loss_cap": loss_cap,
		"offline_loss_cap": offline_cap,
	}


func _area(area_id: String, min_x: int, min_z: int, max_x: int, max_z: int) -> Dictionary:
	return {"id": area_id, "min_x": min_x, "min_z": min_z, "max_x": max_x, "max_z": max_z}


func _window(window_id: String, start_utc: float, end_utc: float) -> Dictionary:
	return {"id": window_id, "start_utc": start_utc, "end_utc": end_utc}


func _with_amount(state: Dictionary, command_id: String, value: Variant) -> Dictionary:
	var copy: Dictionary = state.duplicate(true)
	if copy.engagements.has(command_id):
		copy.engagements[command_id].amount = value
	return copy


func _with_presence(state: Dictionary, value: Variant) -> Dictionary:
	var copy: Dictionary = state.duplicate(true)
	for command_id: Variant in copy.engagements:
		copy.engagements[command_id].defender_online = value
		break
	return copy


func _rejects(state: Dictionary, mutate: Callable) -> bool:
	var copy: Dictionary = state.duplicate(true)
	mutate.call(copy)
	return not Participation.valid(copy)


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
