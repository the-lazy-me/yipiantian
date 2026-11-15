extends SceneTree
## Package format v4: the `sidecars` document. Pure rules only: no scene,
## network or live save directory. Fixtures are in .local/verification.

const Farm = preload("res://farm/farm_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const World = preload("res://farm/world_package.gd")
const SocialState = preload("res://social/social_state.gd")
const SocialStore = preload("res://social/social_store.gd")
const NatureState = preload("res://farm/nature_state.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const TerritoryState = preload("res://world/territory_state.gd")
const OrganizationState = preload("res://world/organization_state.gd")
const PublicFund = preload("res://world/public_fund.gd")
const PublicWorks = preload("res://world/public_works.gd")
const UnitState = preload("res://conflict/unit_state.gd")
const ParticipationState = preload("res://conflict/participation_state.gd")
const ConflictSettlement = preload("res://world/conflict_settlement.gd")
const DisputeState = preload("res://world/dispute_state.gd")
const ResidentsStore = preload("res://world/residents_store.gd")
const IntentState = preload("res://npc/npc_intent_state.gd")
const ResolutionState = preload("res://world/resolution_state.gd")
const ResolutionEffects = preload("res://world/resolution_effects.gd")

const START: float = 1800000000.0
const WORLD: String = "world_alpha"
const OTHER_WORLD: String = "world_beta"
const HOST: String = "player_00000000000000000000000000000001"
const NATURE_SEED: int = 424242

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/world-package-sidecars-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_whitelist_and_limits()
	_test_v4_roundtrip()
	_test_old_versions_upgrade_without_sidecars()
	_test_unknown_and_mismatched()
	_test_corrupt_documents()
	_test_resident_envelopes()
	_test_size_boundaries()
	_report()


func _test_whitelist_and_limits() -> void:
	_expect(World.FORMAT_VERSION == 4, "The package format is version 4")
	_expect(World.MIN_FORMAT_VERSION == 1, "Versions 1 through 3 still parse")
	var expected: Array[String] = [
		"territory.json", "organizations.json", "public_funds.json",
		"public_works.json", "units.json", "participation.json", "conflicts.json",
		"disputes.json", "residents.json", "npc_intents.json", "resolutions.json",
		"resolution_effects.json",
	]
	_expect(World.SIDECAR_FILES == expected, "The whitelist is the exact sidecar file set")
	_expect(not World.SIDECAR_FILES.has("farm.json"), "The farm document is not a sidecar")
	_expect(not World.SIDECAR_FILES.has("social.json"), "The social document is not a sidecar")
	_expect(not World.SIDECAR_FILES.has("nature.json"), "The natural document is not a sidecar")
	_expect(World.MAX_BYTES == 16777216, "The package byte cap is 16 MiB")
	for name: String in expected:
		var limit: int = World.sidecar_limit(name)
		_expect(limit >= 65536 and limit <= 1048576, "Sidecar cap is bounded: " + name)
	_expect(World.sidecar_limit("world.json") == 0, "A non-sidecar name has no cap")
	# The package cap must be reachable by legal documents only through its
	# own bound: if every store's cap summed above it, an export the save path
	# accepts could be refused here. The 1 MiB slack covers the envelope, the
	# natural document, the farm's pretty-printed overhead and JSON escaping.
	var total: int = FarmStore.MAX_BYTES + SocialStore.MAX_BYTES + NatureStore.MAX_BYTES
	for name: String in expected:
		total += World.sidecar_limit(name)
	_expect(total + 1048576 <= World.MAX_BYTES,
		"All store caps plus 1 MiB of envelope slack fit under MAX_BYTES")


func _test_v4_roundtrip() -> void:
	var package: Dictionary = _package()
	var before: Dictionary = package.duplicate(true)
	var serialized: Dictionary = World.serialize(package)
	_expect(serialized.ok and serialized.kind == "serialized", "A v4 package with sidecars serializes")
	_expect(package == before, "Validation does not mutate the caller's package")
	if not serialized.ok:
		return
	var parsed: Dictionary = World.parse(serialized.text)
	_expect(parsed.ok and parsed.kind == "parsed", "A v4 package parses back")
	if not parsed.ok:
		return
	_expect(parsed.package.sidecars.keys().size() == World.SIDECAR_FILES.size(),
		"Every carried sidecar survives the roundtrip")
	for name: String in World.SIDECAR_FILES:
		# Sidecars are carried verbatim, so the package must not add, drop or
		# rewrite a field. Both sides are compared after the same JSON decode,
		# which is also what the live export supplies (parsed file contents).
		var expected: Variant = JSON.parse_string(World.canonical_text(package.sidecars[name]))
		_expect(World.canonical_text(parsed.package.sidecars[name])
				== World.canonical_text(expected),
			"Sidecar content survives the roundtrip: " + name)
	# Sidecars are opaque documents carried verbatim, not rule state the parser
	# normalizes. JSON reads every number back as a float, so the first roundtrip
	# can differ from an in-memory integer fixture. What the export/import path
	# needs is convergence: once a package has been parsed, every later
	# serialize/parse cycle is byte-identical.
	var second: Dictionary = World.serialize(parsed.package)
	_expect(second.ok, "A parsed package reserializes")
	if second.ok:
		var third: Dictionary = World.serialize(World.parse(second.text).package)
		_expect(third.ok and third.text == second.text,
			"Canonical serialization is stable after the first parse")
	_expect(World.parse(JSON.stringify(package)).ok, "Compact JSON with sidecars parses")
	var world: Dictionary = World.sidecar_world(package.sidecars)
	_expect(world.ok and world.world_id == WORLD, "Every world-bearing sidecar names the package world")


func _test_old_versions_upgrade_without_sidecars() -> void:
	var v3: Dictionary = _package()
	v3.format_version = 3
	v3.erase("sidecars")
	var upgraded: Dictionary = World.serialize(v3)
	_expect(upgraded.ok and upgraded.package.format_version == World.FORMAT_VERSION,
		"A version 3 package still parses and upgrades to 4")
	_expect(upgraded.ok and upgraded.package.sidecars.is_empty(),
		"A version 3 package is read as having no sidecars, not as empty documents")
	var v1: Dictionary = _package()
	v1.format_version = 1
	v1.erase("social")
	v1.erase("nature")
	v1.erase("sidecars")
	var upgraded_v1: Dictionary = World.serialize(v1)
	_expect(upgraded_v1.ok and upgraded_v1.package.sidecars.is_empty(),
		"A version 1 package still parses with no sidecars")
	var v3_with_sidecars: Dictionary = _package()
	v3_with_sidecars.format_version = 3
	_expect(World.serialize(v3_with_sidecars).kind == "corrupt",
		"A version 3 package cannot carry sidecars")
	var missing_key: Dictionary = _package()
	missing_key.erase("sidecars")
	_expect(World.serialize(missing_key).kind == "corrupt",
		"A version 4 package requires the sidecar key")
	var empty_sidecars: Dictionary = _package()
	empty_sidecars.sidecars = {}
	_expect(World.serialize(empty_sidecars).ok,
		"An empty sidecar dictionary is a legal package")


func _test_unknown_and_mismatched() -> void:
	var unknown: Dictionary = _package()
	unknown.sidecars["farm.json"] = _package()["sidecars"]["territory.json"]
	_expect(World.serialize(unknown).kind == "unknown_sidecar",
		"An unknown sidecar file name is refused")
	var wrong_world: Dictionary = _package()
	wrong_world.sidecars["territory.json"] = {"version": 1,
		"state": TerritoryState.default_state(OTHER_WORLD)}
	_expect(World.serialize(wrong_world).kind == "sidecar_world_mismatch",
		"A sidecar naming another world is refused")
	var mixed_worlds: Dictionary = _package()
	(mixed_worlds.sidecars["units.json"]["state"]).world_id = OTHER_WORLD
	_expect(World.serialize(mixed_worlds).kind == "sidecar_world_mismatch",
		"Sidecars naming different worlds are refused")
	var wrong_dispute_world: Dictionary = _package()
	wrong_dispute_world.sidecars["disputes.json"]["world_id"] = OTHER_WORLD
	_expect(World.serialize(wrong_dispute_world).kind == "sidecar_world_mismatch",
		"A disputes envelope naming another world is refused")
	var non_object: Dictionary = _package()
	non_object.sidecars["territory.json"] = []
	_expect(World.serialize(non_object).kind == "invalid_sidecar",
		"A non-object sidecar document is refused")
	var bad_container: Dictionary = _package()
	bad_container.sidecars = []
	_expect(World.serialize(bad_container).kind == "invalid_sidecars",
		"A non-object sidecar dictionary is refused")
	var helper: Dictionary = World.sidecar_world({
		"territory.json": {"version": 1, "state": TerritoryState.default_state(WORLD)},
		"units.json": {"version": 1, "state": UnitState.initial_state(OTHER_WORLD)},
	})
	_expect(not helper.ok and helper.kind == "sidecar_world_mismatch",
		"The world-identity helper refuses mixed worlds")
	_expect(World.sidecar_world({"organizations.json": {"version": 1,
		"state": OrganizationState.empty()}}).world_id.is_empty(),
		"A sidecar without a world field contributes no identity")


func _test_corrupt_documents() -> void:
	var bad_version: Dictionary = _package()
	bad_version.sidecars["territory.json"]["version"] = 2
	_expect(World.serialize(bad_version).kind == "unsupported_sidecar",
		"A newer sidecar version is refused by name")
	var bad_state: Dictionary = _package()
	bad_state.sidecars["territory.json"]["state"] = {"world_id": WORLD}
	_expect(World.serialize(bad_state).kind == "invalid_sidecar",
		"A sidecar state that fails its rules is refused")
	var extra_state_key: Dictionary = _package()
	extra_state_key.sidecars["organizations.json"]["state"]["future"] = {}
	_expect(World.serialize(extra_state_key).kind == "invalid_sidecar",
		"An unknown state key is refused")
	var extra_envelope_key: Dictionary = _package()
	extra_envelope_key.sidecars["npc_intents.json"]["future"] = true
	_expect(World.serialize(extra_envelope_key).kind == "invalid_sidecar",
		"An unknown envelope key is refused")
	var bad_journal: Dictionary = _package()
	bad_journal.sidecars["resolutions.json"]["commands"] = [{"command_id": ""}]
	_expect(World.serialize(bad_journal).kind == "invalid_sidecar",
		"A malformed replay journal is refused")
	var bad_dispute_journal: Dictionary = _package()
	bad_dispute_journal.sidecars["disputes.json"]["enforcement"] = {"case_1": {}}
	_expect(World.serialize(bad_dispute_journal).kind == "invalid_sidecar",
		"A malformed dispute enforcement record is refused")
	var bad_applied: Dictionary = _package()
	bad_applied.sidecars["conflicts.json"]["applied"] = {"missing": {"applied": true}}
	_expect(World.serialize(bad_applied).kind == "invalid_sidecar",
		"A settlement applied record without a consumed command is refused")
	var missing_version: Dictionary = _package()
	missing_version.sidecars["public_funds.json"].erase("version")
	_expect(World.serialize(missing_version).kind == "invalid_sidecar",
		"A sidecar without a version is refused")
	var mismatched_effects: Dictionary = _package()
	mismatched_effects.sidecars["resolution_effects.json"]["state"] = {
		"applied_version": 1,
		"applied": [{
			"resolution_id": "res_1", "version": 1,
			"kind": ResolutionState.KIND_TAX, "at_utc": 1800000000.0,
		}],
	}
	_expect(World.serialize(mismatched_effects).kind == "invalid_sidecar",
		"An effect document that disagrees with the package resolutions is refused")
	var bad_effects_world: Dictionary = _package()
	bad_effects_world.sidecars["resolution_effects.json"]["world_id"] = OTHER_WORLD
	_expect(World.serialize(bad_effects_world).kind == "sidecar_world_mismatch",
		"An effect envelope naming another world is refused")
	var bad_participation_world: Dictionary = _package()
	bad_participation_world.sidecars["participation.json"]["state"]["host"] = ""
	_expect(World.serialize(bad_participation_world).kind == "invalid_sidecar",
		"A participation document with an empty host is refused")


func _test_resident_envelopes() -> void:
	# The residents store accepts the current six-key envelope and the two older
	# shapes. The package must accept all three, otherwise a world exported
	# before invitations or dialogues would be refused on import.
	var base: Dictionary = _package()["sidecars"]["residents.json"]
	_expect(base.has("dialogues") and base.keys().size() == 6,
		"The current residents envelope has six keys")
	var five: Dictionary = base.duplicate(true)
	five.erase("dialogues")
	var package_five: Dictionary = _package()
	package_five.sidecars["residents.json"] = five
	_expect(World.serialize(package_five).ok, "A five-key residents envelope is accepted")
	var four: Dictionary = base.duplicate(true)
	four.erase("dialogues")
	four.erase("invitations")
	var package_four: Dictionary = _package()
	package_four.sidecars["residents.json"] = four
	_expect(World.serialize(package_four).ok, "A four-key residents envelope is accepted")
	var bad_sixth: Dictionary = base.duplicate(true)
	bad_sixth["future"] = {}
	var package_bad: Dictionary = _package()
	package_bad.sidecars["residents.json"] = bad_sixth
	_expect(World.serialize(package_bad).kind == "invalid_sidecar",
		"An unknown residents envelope key is refused")
	var bad_memories: Dictionary = base.duplicate(true)
	bad_memories["memories"]["world_id"] = OTHER_WORLD
	var package_memories: Dictionary = _package()
	package_memories.sidecars["residents.json"] = bad_memories
	_expect(World.serialize(package_memories).kind == "invalid_sidecar",
		"Resident memories naming another world are refused")
	_expect(ResidentsStore.valid_invitations({}), "An empty invitation table is legal")


func _test_size_boundaries() -> void:
	# A document larger than its store's read cap could never be loaded after
	# import, so the writer refuses it as `sidecar_too_large` before shape checks.
	var huge: Dictionary = _package()
	var row: Dictionary = {
		"command_id": "c1", "payload": "x".repeat(70000),
		"result": {"ok": true},
	}
	huge.sidecars["resolutions.json"]["commands"] = [row]
	_expect(World.serialize(huge).kind == "sidecar_too_large",
		"A sidecar above its store's byte cap is refused")
	_expect(World.sidecar_limit("resolutions.json") == 65536,
		"The resolutions cap matches the store's 64 KiB read limit")
	_expect(World.sidecar_limit("resolution_effects.json") == 65536,
		"The effect document cap matches the store's 64 KiB read limit")
	# The whole package is checked before parsing so a hostile or oversized
	# document never reaches the JSON parser.
	_expect(World.parse("x".repeat(World.MAX_BYTES + 1)).kind == "too_large",
		"Input above the package cap is refused before parsing")
	_expect(World.parse("x".repeat(World.MAX_BYTES)).kind == "corrupt",
		"Input exactly at the package cap reaches the parser")
	var directory: String = test_root.path_join("bytes")
	DirAccess.make_dir_recursive_absolute(directory)
	var path: String = directory.path_join("oversized.json")
	_write(path, "x".repeat(World.MAX_BYTES + 1))
	var before_hash: String = FileAccess.get_sha256(path)
	_expect(World.parse(FileAccess.get_file_as_string(path)).kind == "too_large",
		"An oversized package on disk is refused")
	_expect(FileAccess.get_sha256(path) == before_hash,
		"A refused oversized package leaves its bytes untouched")


func _package() -> Dictionary:
	var farm := Farm.new(START)
	farm.harvest("field_03", "cell_06", START)
	var decorations := Decorations.new()
	decorations.unlock(farm.snapshot().harvested)
	return {
		"format": World.FORMAT,
		"format_version": World.FORMAT_VERSION,
		"rules_version": World.RULES_VERSION,
		"world_id": WORLD,
		"farm_id": "farm_home",
		"player_id": "player_lin",
		"device_id": "device_mac_01",
		"exported_at_utc_seconds": 1800000000,
		"committed_sequence": 0,
		"money": {"currency": "COIN", "minor_units": 0},
		"snapshot": farm.snapshot(),
		"decorations": decorations.snapshot(),
		"social": SocialState.initial_state(),
		"nature": {"seed": NATURE_SEED, "rules_version": NatureState.RULES_VERSION},
		"sidecars": _sidecars(),
	}


func _sidecars() -> Dictionary:
	var participation: Dictionary = ParticipationState.initial_state(WORLD, HOST)
	var residents: Dictionary = ResidentsStore.empty_state(WORLD)
	return {
		"territory.json": {"version": 1, "state": TerritoryState.default_state(WORLD)},
		"organizations.json": {"version": 1, "state": OrganizationState.empty()},
		"public_funds.json": {"version": 1, "state": PublicFund.empty()},
		"public_works.json": {"version": 1, "state": PublicWorks.empty()},
		"units.json": {"version": 1, "state": UnitState.initial_state(WORLD)},
		"participation.json": {"version": 1, "state": participation},
		"conflicts.json": {
			"version": 1,
			"state": ConflictSettlement.initial_context(WORLD, participation),
			"applied": {},
		},
		"disputes.json": {
			"version": 1, "world_id": WORLD,
			"state": DisputeState.empty([HOST], []),
			"commands": [], "enforcement": {},
		},
		"residents.json": {
			"version": 1, "world_id": WORLD,
			"social": residents.social, "memories": residents.memories,
			"invitations": {}, "dialogues": {},
		},
		"npc_intents.json": {"version": 1, "state": IntentState.empty_state()},
		"resolutions.json": {
			"version": 1, "world_id": WORLD,
			"state": ResolutionState.empty(), "commands": [],
		},
		"resolution_effects.json": {
			"version": 1, "world_id": WORLD, "state": ResolutionEffects.empty(),
		},
	}


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null, "Fixture must be writable")
	file.store_string(text)
	file.close()


func _report() -> void:
	for failure: String in failures:
		push_error(failure)
	print("WORLD_PACKAGE_SIDECARS_TEST checks=%d failures=%d root=%s"
		% [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
