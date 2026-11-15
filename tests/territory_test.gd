extends SceneTree
## M11-01 minimal land cadastre: pure, headless rule tests. No FarmState, no
## save document, no scene and no clock. The final line is the CI evidence.

const Territory = preload("res://world/territory_state.gd")

const START: float = 1800000000.0
const WORLD_A: String = "world-a"
const WORLD_B: String = "world-b"
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_claim()
	_test_transfer_and_release()
	_test_permissions()
	_test_document_validity()
	_test_world_isolation()
	_test_determinism_and_bounds()
	for failure: String in failures:
		push_error(failure)
	print("TERRITORY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_claim() -> void:
	var state: Dictionary = _state(WORLD_A, [_parcel("p1", 0, 0, 3, 3)])
	_expect(Territory.valid(state), "The empty cadastre is valid")
	var claimed: Dictionary = Territory.claim(state, WORLD_A, "p1", PLAYER_A, "claim-1", START)
	var parcel: Dictionary = state.parcels.p1
	_expect(claimed.ok and not claimed.duplicate and claimed.status == Territory.STATUS_CLAIMED
		and claimed.owner == PLAYER_A and claimed.parcel_id == "p1",
		"An unclaimed parcel is claimed by a legal player")
	_expect(parcel.owner == PLAYER_A and parcel.status == Territory.STATUS_CLAIMED
		and parcel.claimed_utc == START and parcel.claim_id == "claim-1",
		"The parcel row records owner, status, time and claim id")
	_expect(state.sequence == 1 and state.command_results.has("claim-1")
		and Territory.valid(state), "The claim is recorded once and the document stays valid")

	var accepted: Dictionary = state.duplicate(true)
	var replay: Dictionary = Territory.claim(state, WORLD_A, "p1", PLAYER_A, "claim-1", START)
	_expect(replay.ok and replay.duplicate and replay.owner == PLAYER_A,
		"Replaying the claim command returns the first result")
	_expect(state == accepted, "A replayed claim changes no parcel and no sequence")

	var conflict: Dictionary = Territory.claim(state, WORLD_A, "p1", PLAYER_B, "claim-1", START)
	_expect(not conflict.ok and conflict.reason == "command_conflict",
		"The same command id with a different owner is a conflict")
	var later: Dictionary = Territory.claim(state, WORLD_A, "p1", PLAYER_B, "claim-2", START + 1.0)
	_expect(not later.ok and later.reason == "already_claimed",
		"A different command id cannot claim an already claimed parcel")
	_expect(state == accepted, "Refused claims change nothing")

	_expect_result(state, WORLD_A, "p9", PLAYER_A, "claim-9", START, "unknown_parcel",
		"An unknown parcel is refused")
	for bad_owner: Variant in ["", Territory.PUBLIC_OWNER, "@world", "bad owner", 42, null]:
		var refused: Dictionary = Territory.claim(state, WORLD_A, "p1", bad_owner,
			"claim-bad-owner", START)
		_expect(not refused.ok and refused.reason == "invalid_owner",
			"An illegal owner id is refused")
	_expect(not Territory.claim(state, WORLD_A, "p1", PLAYER_A, "", START).ok,
		"An empty command id is refused")
	_expect(not Territory.claim(state, WORLD_A, "p1", PLAYER_A, "x".repeat(129), START).ok,
		"An overlong command id is refused")
	_expect(not Territory.claim(state, WORLD_A, "p1", PLAYER_A, "claim-negative", -1.0).ok,
		"A negative claim time is refused")
	_expect(not Territory.claim(state, WORLD_A, "p1", PLAYER_A, "claim-inf", INF).ok,
		"A non-finite claim time is refused")
	_expect(not Territory.claim(state, WORLD_B, "p1", PLAYER_A, "claim-wrong-world", START).ok,
		"A claim carrying another world id is refused")

	var public_state: Dictionary = _state(WORLD_A, [
		_parcel("open", 10, 10, 12, 12, Territory.STATUS_PUBLIC, Territory.PUBLIC_OWNER),
	])
	var on_public: Dictionary = Territory.claim(public_state, WORLD_A, "open", PLAYER_A,
		"claim-public", START)
	_expect(not on_public.ok and on_public.reason == "already_public",
		"A public parcel cannot be claimed")
	_expect(Territory.valid(public_state), "The public parcel document is valid")

	var malformed: Dictionary = _state(WORLD_A, [_parcel("p1", 0, 0, 3, 3)])
	malformed.command_results = []
	_expect(not Territory.claim(malformed, WORLD_A, "p1", PLAYER_A, "claim-bad", START).ok,
		"A claim on a malformed document is refused")
	_expect(malformed.parcels.p1.status == Territory.STATUS_UNCLAIMED,
		"A refused claim does not mutate the parcel")


func _test_transfer_and_release() -> void:
	var state: Dictionary = _state(WORLD_A, [
		_parcel("p2", 0, 0, 3, 3),
		_parcel("p3", 5, 0, 8, 3),
	])
	Territory.claim(state, WORLD_A, "p2", PLAYER_A, "claim-2", START)
	Territory.claim(state, WORLD_A, "p3", PLAYER_C, "claim-3", START)
	_expect(Territory.valid(state), "Two claimed parcels are valid")

	var not_owner: Dictionary = Territory.transfer(state, "p2", PLAYER_B, PLAYER_C,
		"transfer-1", START + 10.0)
	_expect(not not_owner.ok and not_owner.reason == "not_owner",
		"A non-owner cannot transfer a parcel")
	_expect(state.parcels.p2.owner == PLAYER_A, "A refused transfer changes no owner")
	for bad_to: Variant in ["", Territory.PUBLIC_OWNER, "@world", "bad to", 7, null]:
		var refused: Dictionary = Territory.transfer(state, "p2", PLAYER_A, bad_to,
			"transfer-bad-to", START + 10.0)
		_expect(not refused.ok and refused.reason == "invalid_owner",
			"An illegal receiver is refused")
	_expect(not Territory.transfer(state, "p2", PLAYER_A, PLAYER_A, "transfer-self",
		START + 10.0).ok, "Transferring to the current owner is refused")
	_expect(not Territory.transfer(state, "p2", PLAYER_A, PLAYER_B, "transfer-early",
		START - 1.0).ok, "A transfer time before the claim is refused")
	_expect(not Territory.transfer(state, "p3", PLAYER_A, PLAYER_B, "claim-2",
		START + 10.0).ok,
		"A live claim id cannot be reused as another parcel's transfer command")
	_expect(not Territory.transfer(state, "p2", PLAYER_A, PLAYER_B, "claim-3",
		START + 10.0).ok,
		"Another parcel's claim id cannot be used as a transfer command")

	var transferred: Dictionary = Territory.transfer(state, "p2", PLAYER_A, PLAYER_B,
		"transfer-2", START + 10.0)
	_expect(transferred.ok and not transferred.duplicate and transferred.owner == PLAYER_B
		and transferred.status == Territory.STATUS_CLAIMED,
		"The owner transfers the parcel to another player")
	_expect(state.parcels.p2.owner == PLAYER_B and state.parcels.p2.claimed_utc == START + 10.0
		and state.parcels.p2.claim_id == "transfer-2",
		"The transfer records the new owner, time and command id")
	_expect(Territory.valid(state), "The transferred document stays valid")

	var accepted: Dictionary = state.duplicate(true)
	var replay: Dictionary = Territory.transfer(state, "p2", PLAYER_A, PLAYER_B,
		"transfer-2", START + 10.0)
	_expect(replay.ok and replay.duplicate and replay.owner == PLAYER_B,
		"Replaying the transfer returns the first result")
	_expect(state == accepted, "A replayed transfer changes nothing")
	var reused: Dictionary = Territory.transfer(state, "p2", PLAYER_A, PLAYER_C,
		"transfer-2", START + 10.0)
	_expect(not reused.ok and reused.reason == "command_conflict",
		"Reusing the transfer id with another receiver is a conflict")
	var reverse_time: Dictionary = Territory.transfer(state, "p2", PLAYER_B, PLAYER_C,
		"transfer-reverse", START)
	_expect(not reverse_time.ok and reverse_time.reason == "time_regression",
		"A transfer before the previous land time is refused")

	var non_owner_release: Dictionary = Territory.release(state, "p2", PLAYER_A,
		"release-1", START + 20.0)
	_expect(not non_owner_release.ok and non_owner_release.reason == "not_owner",
		"A non-owner cannot release a parcel")
	_expect(state.parcels.p2.owner == PLAYER_B, "A refused release changes no owner")

	var released: Dictionary = Territory.release(state, "p2", PLAYER_B, "release-2",
		START + 20.0)
	var parcel: Dictionary = state.parcels.p2
	_expect(released.ok and not released.duplicate and released.status == Territory.STATUS_UNCLAIMED
		and released.owner.is_empty(), "The owner releases the parcel")
	_expect(parcel.owner.is_empty() and parcel.status == Territory.STATUS_UNCLAIMED
		and parcel.claimed_utc == 0.0 and parcel.claim_id.is_empty(),
		"Release clears owner, claim time and claim id")
	_expect(Territory.valid(state), "The released document stays valid")
	var release_replay: Dictionary = Territory.release(state, "p2", PLAYER_B, "release-2",
		START + 20.0)
	_expect(release_replay.ok and release_replay.duplicate,
		"Replaying the release returns the first result")
	var release_again: Dictionary = Territory.release(state, "p2", PLAYER_B, "release-3",
		START + 30.0)
	_expect(not release_again.ok and release_again.reason == "not_owned",
		"Releasing an unclaimed parcel with a new command is refused")
	_expect(not Territory.transfer(state, "p2", PLAYER_B, PLAYER_C, "transfer-3",
		START + 30.0).ok, "An unclaimed parcel cannot be transferred")
	_expect(not Territory.release(state, "p2", PLAYER_B, "release-early", START - 1.0).ok,
		"An invalid release time is refused")
	_expect(not Territory.release(state, "p9", PLAYER_B, "release-unknown", START).ok,
		"Releasing an unknown parcel is refused")


func _test_permissions() -> void:
	var state: Dictionary = _state(WORLD_A, [
		_parcel("claimed", 0, 0, 3, 3),
		_parcel("public", 5, 0, 8, 3, Territory.STATUS_PUBLIC, Territory.PUBLIC_OWNER),
		_parcel("unclaimed", 10, 0, 13, 3),
	])
	Territory.claim(state, WORLD_A, "claimed", PLAYER_A, "claim-perm", START)

	var actors: Array = [PLAYER_A, PLAYER_B, Territory.PUBLIC_OWNER, "", "@world", "bad actor", 7]
	var build_expected: Array = [true, false, false, false, false, false, false]
	for actor: Variant in actors:
		_expect(Territory.may_build(state, "claimed", actor) == build_expected[actors.find(actor)],
			"Only the owner may build on claimed land")
		_expect(Territory.may_trespass(state, "claimed", actor) == build_expected[actors.find(actor)],
			"Only the owner may cross claimed land")

	for actor: Variant in [PLAYER_A, PLAYER_B, PLAYER_C]:
		_expect(Territory.may_build(state, "public", actor),
			"Every legal player may build on public land")
		_expect(Territory.may_trespass(state, "public", actor),
			"Every legal player may cross public land")
	for actor: Variant in [Territory.PUBLIC_OWNER, "", "@world", "bad actor", 7, null]:
		_expect(not Territory.may_build(state, "public", actor),
			"A non-player actor may not build on public land")
		_expect(not Territory.may_trespass(state, "public", actor),
			"A non-player actor may not cross public land")

	for actor: Variant in [PLAYER_A, PLAYER_B]:
		_expect(not Territory.may_build(state, "unclaimed", actor),
			"Unclaimed land refuses construction")
		_expect(Territory.may_trespass(state, "unclaimed", actor),
			"Unclaimed land is open to passage")
	_expect(not Territory.may_build(state, "public", null)
		and not Territory.may_trespass(state, "public", null),
		"An invalid actor is refused on every status")
	_expect(not Territory.may_build(state, "missing", PLAYER_A)
		and not Territory.may_trespass(state, "missing", PLAYER_A),
		"An unknown parcel grants neither permission")
	_expect(not Territory.may_build({"parcels": []}, "p", PLAYER_A),
		"A malformed document grants no build permission")


func _test_document_validity() -> void:
	var state: Dictionary = _state(WORLD_A, [
		_parcel("p1", 0, 0, 3, 3),
		_parcel("p2", 5, 0, 8, 3),
	])
	Territory.claim(state, WORLD_A, "p1", PLAYER_A, "claim-1", START)
	Territory.transfer(state, "p1", PLAYER_A, PLAYER_B, "transfer-1", START + 5.0)
	_expect(Territory.valid(state), "A claimed and transferred document is valid")
	_expect(Territory.valid(JSON.parse_string(JSON.stringify(state))),
		"The document remains valid after a JSON round trip")

	var restored: Variant = JSON.parse_string(JSON.stringify(state))
	Territory.normalize(restored)
	_expect(restored == state, "normalize restores JSON numbers to the original document")
	_expect(restored.parcels.p1.claimed_utc is float and restored.parcels.p1.rect.min_x is int
		and restored.sequence is int,
		"normalize restores float times and integer bounds")

	_expect(not Territory.valid(null) and not Territory.valid([]),
		"A non-dictionary document is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void: doc.extra = true),
		"An unknown top-level key is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void: doc.erase("sequence")),
		"A missing top-level key is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void: doc.world_id = ""),
		"An empty world id is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void: doc.world_id = "bad world"),
		"A world id with illegal characters is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void: doc.sequence = -1),
		"A negative sequence is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void: doc.sequence = 1.5),
		"A fractional sequence is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.extra = 1), "An unknown parcel key is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p2.erase("status")), "A parcel missing a key is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.id = "p2"), "A parcel id that disagrees with its key is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.rect.extra = 1), "An unknown rect key is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.rect.erase("max_z")), "A rect missing a bound is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.rect.min_x = -1), "A negative rect bound is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.rect.max_x = Territory.MAX_COORD + 1),
		"A rect bound past the coordinate limit is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.rect.min_x = 4), "A rect with min_x above max_x is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.rect.min_x = 0.5), "A fractional rect bound is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p2.rect.min_x = 3), "Overlapping rect declarations are rejected")
	_expect(not _rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p2.rect.min_x = 4),
		"Adjacent inclusive rects do not overlap and stay valid")

	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.owner = ""), "A claimed parcel with no owner is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.owner = Territory.PUBLIC_OWNER),
		"A claimed parcel owned by public is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.status = Territory.STATUS_PUBLIC),
		"Public status not owned by public is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p2.status = Territory.STATUS_CLAIMED),
		"A claimed parcel with empty claim fields is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p2.status = Territory.STATUS_PUBLIC),
		"Public status with a non-public owner is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p2.owner = PLAYER_A),
		"An unclaimed parcel with an owner is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p2.claimed_utc = 1.0),
		"An unclaimed parcel with a claim time is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p2.claim_id = "claim-x"),
		"An unclaimed parcel with a claim id is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.claimed_utc = -1.0), "A negative claim time is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.claimed_utc = INF), "A non-finite claim time is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.claim_id = ""), "A claimed parcel with an empty claim id is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.status = "unknown"), "An unknown parcel status is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.owner = PLAYER_C),
		"A claimed owner that disagrees with the live command result is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p1.claimed_utc = START + 6.0),
		"A claim time that disagrees with the live command payload is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.parcels.p2.status = Territory.STATUS_CLAIMED
		doc.parcels.p2.owner = PLAYER_C
		doc.parcels.p2.claimed_utc = START
		doc.parcels.p2.claim_id = "transfer-1"),
		"A claim id reused by two parcels is rejected")

	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.command_results["bad"] = {"payload": "{", "result": {}}),
		"A malformed command result row is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.command_results["bad"] = {"payload": "x".repeat(513),
			"result": doc.command_results["claim-1"].result}),
		"An overlong command payload is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.command_results["bad"] = {
			"payload": JSON.stringify(["territory_claim", WORLD_B, "p2", PLAYER_C, START]),
			"result": _result("p2", PLAYER_C, Territory.STATUS_CLAIMED)}),
		"A command payload for another world is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.command_results["bad"] = {
			"payload": JSON.stringify(["territory_unknown", WORLD_A, "p2", PLAYER_C, START]),
			"result": _result("p2", PLAYER_C, Territory.STATUS_CLAIMED)}),
		"An unknown command kind is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.command_results["bad"] = {
			"payload": JSON.stringify(["territory_claim", WORLD_A, "p2", PLAYER_C, START]),
			"result": _result("p2", PLAYER_B, Territory.STATUS_CLAIMED)}),
		"A result owner that disagrees with its payload is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		var stored: Dictionary = doc.command_results["claim-1"].result.duplicate(true)
		stored.duplicate = true
		doc.command_results["bad"] = {"payload": doc.command_results["claim-1"].payload,
			"result": stored}), "A stored duplicate result is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc.command_results["bad"] = "not a row"),
		"A non-dictionary command result is rejected")

	var too_many_results: Dictionary = state.duplicate(true)
	var extra_count: int = Territory.MAX_COMMAND_RESULTS + 1 \
		- too_many_results.command_results.size()
	for index: int in extra_count:
		var command_id: String = "extra-%d" % index
		too_many_results.command_results[command_id] = {
			"payload": JSON.stringify(["territory_claim", WORLD_A, "p2", PLAYER_C, START]),
			"result": _result("p2", PLAYER_C, Territory.STATUS_CLAIMED),
		}
	_expect(not Territory.valid(too_many_results),
		"More command results than the bound are rejected")
	too_many_results.command_results.erase("extra-0")
	_expect(Territory.valid(too_many_results),
		"Exactly the command result bound is accepted")

	var exact: Dictionary = _state(WORLD_A, _non_overlapping_parcels(Territory.MAX_PARCELS))
	_expect(Territory.valid(exact), "The maximum parcel count is accepted")
	var over: Dictionary = _state(WORLD_A,
		_non_overlapping_parcels(Territory.MAX_PARCELS + 1))
	_expect(not Territory.valid(over), "One parcel above the bound is rejected")


func _test_world_isolation() -> void:
	var state_a: Dictionary = _state(WORLD_A, [_parcel("p1", 0, 0, 3, 3)])
	var state_b: Dictionary = _state(WORLD_B, [_parcel("p1", 0, 0, 3, 3)])
	var claim_a: Dictionary = Territory.claim(state_a, WORLD_A, "p1", PLAYER_A, "same-id", START)
	var claim_b: Dictionary = Territory.claim(state_b, WORLD_B, "p1", PLAYER_B, "same-id", START)
	_expect(claim_a.ok and claim_b.ok and claim_a.owner == PLAYER_A and claim_b.owner == PLAYER_B,
		"The same command id in two worlds resolves independently")
	_expect(state_a.parcels.p1.owner == PLAYER_A and state_b.parcels.p1.owner == PLAYER_B,
		"One world's claim never mutates the other")
	_expect(not Territory.claim(state_a, WORLD_B, "p1", PLAYER_C, "cross-world", START).ok,
		"A claim carrying the other world id is refused by this document")
	_expect(Territory.valid(state_a) and Territory.valid(state_b),
		"Both isolated documents are valid")
	var replay_b: Dictionary = Territory.claim(state_b, WORLD_B, "p1", PLAYER_B, "same-id", START)
	_expect(replay_b.ok and replay_b.duplicate, "Replay stays inside its own world")
	_expect(state_a.parcels.p1.owner == PLAYER_A, "A replay in world B leaves world A alone")
	var crossed: Dictionary = state_a.duplicate(true)
	crossed.command_results["same-id"].payload = \
		crossed.command_results["same-id"].payload.replace(WORLD_A, WORLD_B)
	_expect(not Territory.valid(crossed),
		"A stored payload from another world invalidates the document")
	_expect(state_a.parcels.p1.owner == PLAYER_A,
		"Validating a modified copy leaves the original world unchanged")


func _test_determinism_and_bounds() -> void:
	var first: Dictionary = _state(WORLD_A, [
		_parcel("a", 0, 0, 2, 2),
		_parcel("b", 4, 0, 6, 2),
	])
	var second: Dictionary = _state(WORLD_A, [
		_parcel("a", 0, 0, 2, 2),
		_parcel("b", 4, 0, 6, 2),
	])
	for state: Dictionary in [first, second]:
		Territory.claim(state, WORLD_A, "a", PLAYER_A, "det-claim", START)
		Territory.transfer(state, "a", PLAYER_A, PLAYER_B, "det-transfer", START + 10.0)
		Territory.release(state, "a", PLAYER_B, "det-release", START + 20.0)
		Territory.claim(state, WORLD_A, "b", PLAYER_C, "det-claim-b", START)
	_expect(JSON.stringify(first) == JSON.stringify(second),
		"The same input sequence produces the same document and results")
	var replay_first: Dictionary = Territory.transfer(first, "a", PLAYER_A, PLAYER_B,
		"det-transfer", START + 10.0)
	var replay_second: Dictionary = Territory.transfer(second, "a", PLAYER_A, PLAYER_B,
		"det-transfer", START + 10.0)
	_expect(replay_first == replay_second and replay_first.duplicate,
		"The bounded-window replay result is deterministic")
	_expect(first == second, "A replay leaves both deterministic documents equal")
	_expect(first.sequence == 4 and second.sequence == 4,
		"Every successful command advances the sequence exactly once")

	var bounded: Dictionary = _state(WORLD_A, [_parcel("0", 0, 0, 0, 0)])
	var all_accepted: bool = true
	for index: int in 70:
		var result: Dictionary
		if index % 2 == 0:
			result = Territory.claim(bounded, WORLD_A, "0", PLAYER_A,
				"cycle-%d-claim" % index, START + index)
		else:
			result = Territory.release(bounded, "0", PLAYER_A,
				"cycle-%d-release" % index, START + index)
		all_accepted = all_accepted and result.ok and not result.duplicate
	_expect(all_accepted, "Seventy alternating claim/release commands are accepted")
	_expect(bounded.command_results.size() == Territory.MAX_COMMAND_RESULTS,
		"The command window evicts down to its bound")
	_expect(bounded.sequence == 70,
		"The sequence counts every accepted command, evicted or not")
	_expect(bounded.parcels["0"].status == Territory.STATUS_UNCLAIMED,
		"The rolling cycle ends released")
	_expect(Territory.valid(bounded), "A bounded rolling command window stays valid")


func _state(world_id: String, parcels: Array) -> Dictionary:
	var state: Dictionary = Territory.initial_state(world_id)
	for parcel: Dictionary in parcels:
		state.parcels[str(parcel.id)] = parcel.duplicate(true)
	return state


func _parcel(parcel_id: String, min_x: int, min_z: int, max_x: int, max_z: int,
		status: String = Territory.STATUS_UNCLAIMED, owner: String = "",
		claimed_utc: float = 0.0, claim_id: String = "") -> Dictionary:
	return {
		"id": parcel_id,
		"rect": {"min_x": min_x, "min_z": min_z, "max_x": max_x, "max_z": max_z},
		"owner": owner,
		"status": status,
		"claimed_utc": claimed_utc,
		"claim_id": claim_id,
	}


func _non_overlapping_parcels(count: int) -> Array:
	var parcels: Array = []
	for index: int in count:
		var x: int = index % 64
		var z: int = index / 64
		parcels.append(_parcel("parcel_%d" % index, x, z, x, z))
	return parcels


func _result(parcel_id: String, owner: String, status: String) -> Dictionary:
	return {
		"ok": true, "reason": "", "parcel_id": parcel_id, "owner": owner,
		"status": status, "duplicate": false,
	}


func _rejects(state: Dictionary, mutate: Callable) -> bool:
	var copy: Dictionary = state.duplicate(true)
	mutate.call(copy)
	return not Territory.valid(copy)


func _expect_result(state: Dictionary, world_id: String, parcel_id: String, owner: Variant,
		command_id: String, at_utc: float, reason: String, label: String) -> void:
	var result: Dictionary = Territory.claim(state, world_id, parcel_id, owner, command_id, at_utc)
	_expect(result.reason == reason, label)


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
