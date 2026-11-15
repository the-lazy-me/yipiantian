extends SceneTree
## ADR-028 build/land authority gate, exercised through a real HeadlessWorld.
##
## Covers: the fixed slot→parcel mapping, building on your own parcel, refusal on
## someone else's parcel with both files byte-identical, an unclaimed parcel
## becoming the builder's on the first build (and surviving a reopen), the
## dormant public parcel path, a slot with no parcel, an unavailable cadastre,
## replays that don't re-claim, and the occupied same-slot second command.

const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const TerritoryState = preload("res://world/territory_state.gd")
const TerritoryStore = preload("res://world/territory_store.gd")
const Buildings = preload("res://farm/building_catalog.gd")

const START: float = 1800000000.0
const WORLD: String = "world-build-gate"
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"

var checks: int = 0
var failures: Array[String] = []
var root_dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = _repo().path_join(
		".local/verification/territory-build-gate-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)
	_test_mapping()
	_test_own_parcel()
	_test_other_parcel_is_refused()
	_test_unclaimed_parcel_claims_on_build()
	_test_public_parcel_allows_build()
	_test_unmapped_slot()
	_test_land_unavailable()
	_test_replay_and_occupied()
	for failure: String in failures:
		push_error(failure)
	print("TERRITORY_BUILD_GATE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_mapping() -> void:
	_expect(Buildings.SLOTS.size() == 6, "There are six build slots")
	var unique: Dictionary = {}
	for index: int in Buildings.SLOTS.size():
		var slot_id: String = Buildings.SLOTS[index]
		var parcel_id: String = TerritoryState.slot_parcel_id(slot_id)
		_expect(parcel_id == "parcel_%02d" % (index + 1),
			"%s maps to parcel_%02d" % [slot_id, index + 1])
		unique[parcel_id] = true
	_expect(unique.size() == Buildings.SLOTS.size(), "The slot→parcel mapping is one-to-one")
	_expect(TerritoryState.slot_parcel_id("yard_z").is_empty(),
		"An unknown slot has no parcel")
	var default_state: Dictionary = TerritoryState.default_state(WORLD)
	for slot_id: String in Buildings.SLOTS:
		_expect(default_state.parcels.has(TerritoryState.slot_parcel_id(slot_id)),
			"%s has a target parcel in the default cadastre" % slot_id)


func _test_own_parcel() -> void:
	var directory: String = root_dir.path_join("own")
	var world: HeadlessWorld = _open(directory)
	var claim: Dictionary = world.claim_territory("parcel_01", PLAYER_A, "claim-a-1")
	_expect(bool(claim.get("ok", false)), "A claims parcel_01 first")
	var land_before: String = _bytes(_territory_path(directory))
	var farm_before: String = _bytes(_farm_path(directory))
	var build: Dictionary = world.execute(
		FarmCommand.make_build("build-a-1", "yard_a", "cottage", START), PLAYER_A)
	_expect(bool(build.get("ok", false)) and str(build.get("stage", "")) == "committed",
		"The owner builds on their own parcel")
	_expect(not bool(build.get("duplicate", true)), "The build is new work")
	var view: Dictionary = world.territory_view()
	_expect(str(view.parcels.parcel_01.owner) == PLAYER_A
		and str(view.parcels.parcel_01.status) == TerritoryState.STATUS_CLAIMED,
		"An owned parcel stays claimed by the builder")
	_expect(int(view.sequence) == 1, "An already-owned parcel writes no implicit claim")
	_expect(_bytes(_territory_path(directory)) == land_before,
		"A build on an owned parcel leaves territory.json byte-identical")
	_expect(_bytes(_farm_path(directory)) != farm_before, "The accepted build is persisted")
	var buildings: Dictionary = world.farm.snapshot().buildings
	_expect(buildings.has("yard_a") and str(buildings.yard_a.owner) == PLAYER_A,
		"The building record belongs to the builder")


func _test_other_parcel_is_refused() -> void:
	var directory: String = root_dir.path_join("other")
	var world: HeadlessWorld = _open(directory)
	# Commit a farm-bearing command so the refusal can be checked against real files.
	var sow: Dictionary = world.execute(
		FarmCommand.make_sow("gate-sow-other", "field_01", "cell_01", "greens", START), PLAYER_A)
	_expect(bool(sow.get("ok", false)), "A sow creates the farm document")
	_expect(bool(world.claim_territory("parcel_02", PLAYER_B, "claim-b-1").get("ok", false)),
		"B claims parcel_02")
	var land_before: String = _bytes(_territory_path(directory))
	var farm_before: String = _bytes(_farm_path(directory))
	var build: Dictionary = world.execute(
		FarmCommand.make_build("build-a-2", "yard_b", "cottage", START), PLAYER_A)
	_expect(not bool(build.get("ok", true)) and str(build.get("reason", "")) == "not_parcel_owner",
		"A build on another player's parcel is refused as not_parcel_owner")
	_expect(_bytes(_farm_path(directory)) == farm_before,
		"The refusal does not touch farm.json")
	_expect(_bytes(_territory_path(directory)) == land_before,
		"The refusal does not touch territory.json")
	_expect(not world.farm.snapshot().buildings.has("yard_b"),
		"No building is created on the refused parcel")
	var view: Dictionary = world.territory_view()
	_expect(str(view.parcels.parcel_02.owner) == PLAYER_B
		and str(view.parcels.parcel_02.claim_id) == "claim-b-1",
		"The other player's claim is unchanged")


func _test_unclaimed_parcel_claims_on_build() -> void:
	var directory: String = root_dir.path_join("unclaimed")
	var world: HeadlessWorld = _open(directory)
	var build: Dictionary = world.execute(
		FarmCommand.make_build("build-c-1", "yard_c", "cottage", START), PLAYER_A)
	_expect(bool(build.get("ok", false)), "A build on an unclaimed parcel is allowed")
	var view: Dictionary = world.territory_view()
	var parcel: Dictionary = view.parcels.parcel_03
	_expect(str(parcel.owner) == PLAYER_A and str(parcel.status) == TerritoryState.STATUS_CLAIMED,
		"The first build claims the parcel for its builder")
	_expect(str(parcel.claim_id) == "build-c-1",
		"The implicit claim records the build command id")
	_expect(float(parcel.claimed_utc) == START,
		"The implicit claim uses the authority clock")
	_expect(int(view.sequence) == 1, "The implicit claim advances the cadastre sequence")
	_expect(_bytes(_territory_path(directory)) != "",
		"The implicit claim is written to territory.json")
	_expect(str(world.farm.snapshot().buildings.yard_c.owner) == PLAYER_A,
		"The building belongs to the same actor as the land")

	var reopened: HeadlessWorld = _open(directory)
	var reopened_view: Dictionary = reopened.territory_view()
	_expect(str(reopened_view.parcels.parcel_03.owner) == PLAYER_A
		and str(reopened_view.parcels.parcel_03.status) == TerritoryState.STATUS_CLAIMED,
		"The implicit claim survives a reopen")
	_expect(str(reopened.farm.snapshot().buildings.yard_c.owner) == PLAYER_A,
		"The building also survives the reopen")

	# A live authority's clock carries sub-second digits. The land time crosses
	# JSON as decimal text, so the parcel row and its payload can differ by
	# rounding noise; that must not make the implicit claim unsavable.
	var fractional: String = root_dir.path_join("fractional")
	var clock: float = 1794747064.16664
	var live: HeadlessWorld = _open_at(fractional, clock)
	var frac_build: Dictionary = live.execute(
		FarmCommand.make_build("build-f-1", "yard_e", "cottage", clock), PLAYER_A)
	_expect(bool(frac_build.get("ok", false)),
		"A build succeeds when the authority clock has sub-second digits (%s)"
			% JSON.stringify(frac_build))
	_expect(str(live.territory_view().parcels.parcel_05.owner) == PLAYER_A,
		"The fractional-clock claim is kept in memory")
	var frac_reopened: HeadlessWorld = _open_at(fractional, clock)
	_expect(str(frac_reopened.territory_view().parcels.parcel_05.owner) == PLAYER_A,
		"The fractional-clock claim survives a reload")


func _test_public_parcel_allows_build() -> void:
	var directory: String = root_dir.path_join("public")
	var state: Dictionary = TerritoryState.default_state(WORLD)
	# No command generates public parcels yet; construct the documented shape
	# directly so the dormant ADR-023 semantics stay covered.
	var parcel: Dictionary = state.parcels.parcel_04
	parcel.owner = TerritoryState.PUBLIC_OWNER
	parcel.status = TerritoryState.STATUS_PUBLIC
	parcel.claimed_utc = 0.0
	parcel.claim_id = ""
	_expect(TerritoryState.valid(state), "A hand-built public parcel is a valid cadastre")
	var saved: Dictionary = TerritoryStore.new(directory).save_state(state)
	_expect(bool(saved.get("ok", false)), "The public cadastre is written before the world opens")
	var world: HeadlessWorld = _open(directory)
	var land_before: String = _bytes(_territory_path(directory))
	var build: Dictionary = world.execute(
		FarmCommand.make_build("build-d-1", "yard_d", "cottage", START), PLAYER_A)
	_expect(bool(build.get("ok", false)), "Building on a public parcel is allowed")
	var view: Dictionary = world.territory_view()
	_expect(str(view.parcels.parcel_04.status) == TerritoryState.STATUS_PUBLIC
		and str(view.parcels.parcel_04.owner) == TerritoryState.PUBLIC_OWNER,
		"A public parcel is not claimed by the build")
	_expect(_bytes(_territory_path(directory)) == land_before,
		"A public build leaves territory.json byte-identical")
	_expect(str(world.farm.snapshot().buildings.yard_d.owner) == PLAYER_A,
		"The public build still creates the building")


func _test_unmapped_slot() -> void:
	var directory: String = root_dir.path_join("unmapped")
	var state: Dictionary = TerritoryState.default_state(WORLD)
	state.parcels.erase("parcel_06")
	_expect(TerritoryState.valid(state), "A cadastre without parcel_06 is still valid")
	_expect(bool(TerritoryStore.new(directory).save_state(state).get("ok", false)),
		"The reduced cadastre is written")
	var world: HeadlessWorld = _open(directory)
	_expect(bool(world.execute(
		FarmCommand.make_sow("gate-sow-unmapped", "field_01", "cell_01", "greens", START),
		PLAYER_A).get("ok", false)), "A sow creates the farm document")
	var land_before: String = _bytes(_territory_path(directory))
	var farm_before: String = _bytes(_farm_path(directory))
	var build: Dictionary = world.execute(
		FarmCommand.make_build("build-f-1", "yard_f", "cottage", START), PLAYER_A)
	_expect(not bool(build.get("ok", true)) and str(build.get("reason", "")) == "slot_unmapped",
		"A slot whose parcel is absent is refused as slot_unmapped")
	_expect(_bytes(_farm_path(directory)) == farm_before
		and _bytes(_territory_path(directory)) == land_before,
		"The unmapped refusal writes no file")
	_expect(not world.farm.snapshot().buildings.has("yard_f"),
		"No building is created for the unmapped slot")


func _test_land_unavailable() -> void:
	var directory: String = root_dir.path_join("unavailable")
	var world: HeadlessWorld = _open(directory)
	_expect(bool(world.execute(
		FarmCommand.make_sow("gate-sow-unavailable", "field_01", "cell_01", "greens", START),
		PLAYER_A).get("ok", false)), "A sow creates the farm document")
	var farm_before: String = _bytes(_farm_path(directory))
	var held: Dictionary = world.territory
	world.territory = {}
	var build: Dictionary = world.execute(
		FarmCommand.make_build("build-a-unavailable", "yard_a", "cottage", START), PLAYER_A)
	_expect(not bool(build.get("ok", true))
		and str(build.get("reason", "")) == "land_unavailable",
		"A build with no loaded cadastre is refused as land_unavailable")
	_expect(_bytes(_farm_path(directory)) == farm_before,
		"The unavailable refusal does not touch farm.json")
	_expect(not world.farm.snapshot().buildings.has("yard_a"),
		"No building is created without a cadastre")
	world.territory = held
	var direct: Dictionary = TerritoryState.build_gate({}, "yard_a", PLAYER_A)
	_expect(not bool(direct.get("ok", true))
		and str(direct.get("reason", "")) == "land_unavailable",
		"The pure gate also reports land_unavailable for an empty document")
	_expect(str(TerritoryState.build_gate(
		TerritoryState.default_state(WORLD), "yard_a", "bad id").get("reason", ""))
		== "invalid_player", "The pure gate refuses an illegal actor")


func _test_replay_and_occupied() -> void:
	var directory: String = root_dir.path_join("replay")
	var world: HeadlessWorld = _open(directory)
	var first: Dictionary = world.execute(
		FarmCommand.make_build("build-e-1", "yard_e", "cottage", START), PLAYER_A)
	_expect(bool(first.get("ok", false)), "The first build on unclaimed land succeeds")
	var view_before: Dictionary = world.territory_view()
	var land_before: String = _bytes(_territory_path(directory))
	var replay: Dictionary = world.execute(
		FarmCommand.make_build("build-e-1", "yard_e", "cottage", START), PLAYER_A)
	_expect(bool(replay.get("duplicate", false)) and str(replay.get("stage", "")) == "duplicate",
		"Retrying the build id replays instead of re-gating")
	_expect(world.territory_view() == view_before,
		"A replay writes no second implicit claim")
	_expect(_bytes(_territory_path(directory)) == land_before,
		"A replay leaves territory.json byte-identical")
	var buildings: Dictionary = world.farm.snapshot().buildings
	_expect(buildings.size() == 1 and str(buildings.yard_e.owner) == PLAYER_A,
		"The replay does not create a second building")

	_expect(bool(world.execute(
		FarmCommand.make_build("build-a-2", "yard_a", "cottage", START), PLAYER_A).get("ok", false)),
		"A second slot is built normally")
	var land_after_second: String = _bytes(_territory_path(directory))
	var occupied: Dictionary = world.execute(
		FarmCommand.make_build("build-a-3", "yard_a", "workshop", START), PLAYER_A)
	_expect(not bool(occupied.get("ok", true))
		and str(occupied.get("reason", "")) == "occupied",
		"A second command on the same slot is refused as occupied")
	_expect(_bytes(_territory_path(directory)) == land_after_second,
		"The occupied refusal leaves the cadastre byte-identical")
	_expect(str(world.farm.snapshot().buildings.yard_a.blueprint) == "cottage",
		"The original building stays in place")


func _open(directory: String) -> HeadlessWorld:
	return _open_at(directory, START)


func _open_at(directory: String, start: float) -> HeadlessWorld:
	var world := HeadlessWorld.new()
	var opened: Dictionary = world.open(directory, start, WORLD)
	_expect(bool(opened.get("ok", false)), "The authority opens %s" % directory.get_file())
	return world


func _territory_path(directory: String) -> String:
	return directory.path_join(TerritoryStore.MAIN)


func _farm_path(directory: String) -> String:
	return directory.path_join(FarmStore.MAIN)


func _bytes(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + message)
	print(("PASS " if condition else "FAIL ") + message)
