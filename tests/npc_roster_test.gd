extends SceneTree
## M10-02 deterministic resident roster. Headless and isolated: no model,
## clock, disk or live save. The farm, scene and network modules are untouched
## by this slice.

const Roster = preload("res://npc/npc_roster.gd")
const Personality = preload("res://npc/npc_personality.gd")
const Memory = preload("res://npc/npc_memory.gd")

const WORLD: String = "world-a"
const OTHER_WORLD: String = "world-b"
const SEED: int = 7
const OTHER_SEED: int = 8
const NPC_LIN: String = "npc_lin_shen"
const NPC_XU: String = "npc_xu_bo"
const NPC_ZHOU: String = "npc_a_zhou"
const NAMES: Dictionary = {
	NPC_LIN: "林婶",
	NPC_XU: "许伯",
	NPC_ZHOU: "阿舟",
}
const HOMES: Dictionary = {
	NPC_LIN: "柳岸",
	NPC_XU: "竹汀",
	NPC_ZHOU: "渡口",
}

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_roster()
	_test_seed_variation()
	_test_initial_memory()
	_test_boundaries()
	for failure: String in failures:
		push_error(failure)
	print("NPC_ROSTER_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_roster() -> void:
	var built: Dictionary = Roster.build(WORLD, SEED)
	_expect(built.ok and str(built.reason).is_empty(), "A valid world and seed build a roster")
	var roster: Dictionary = built.roster
	_expect(_same_keys(roster, Roster.ROSTER_KEYS),
		"The roster exposes only the declared fields")
	_expect(int(roster.schema) == Roster.SCHEMA and roster.world_id == WORLD
		and int(roster.world_seed) == SEED,
		"The roster carries its schema, world id and seed")
	_expect(_same_keys(roster.npcs, Roster.IDS),
		"The roster holds exactly the three authored residents")
	_expect(roster.npcs.size() == 3, "Exactly three residents are registered")

	for npc_id: String in Roster.IDS:
		var resident: Dictionary = roster.npcs[npc_id]
		_expect(_same_keys(resident, Roster.RESIDENT_KEYS),
			"Resident " + npc_id + " exposes only display, home, traits and relations")
		_expect(resident.display_name == NAMES[npc_id],
			"Resident " + npc_id + " keeps its authored display name")
		_expect(resident.home == HOMES[npc_id],
			"Resident " + npc_id + " keeps its authored home")
		_expect(_same_keys(resident.traits, Personality.TRAITS),
			"Resident " + npc_id + " has exactly the five personality dimensions")
		_expect(Personality.valid(resident.traits),
			"Resident " + npc_id + " has a valid personality profile")
		_expect(resident.traits == Personality.traits(npc_id, SEED).traits,
			"Resident " + npc_id + " reuses the M10-01 personality derivation")
		var in_range: bool = true
		for trait_name: String in Personality.TRAITS:
			var value: Variant = resident.traits[trait_name]
			in_range = in_range and value is int and int(value) >= 0 and int(value) <= 100
		_expect(in_range, "Resident " + npc_id + " traits stay in 0..100")
		var described: Dictionary = Personality.describe(resident.traits)
		_expect(described.ok and not str(described.text).is_empty(),
			"Resident " + npc_id + " has a deterministic Chinese description")

		var expected_relations: Array[String] = []
		for other_id: String in Roster.IDS:
			if other_id != npc_id:
				expected_relations.append(other_id)
		_expect(_same_keys(resident.relations, expected_relations),
			"Resident " + npc_id + " knows exactly the other two residents")
		var labelled: bool = true
		for other_id: String in expected_relations:
			labelled = labelled and resident.relations[other_id] == Roster.NEIGHBOR
		_expect(labelled, "Resident " + npc_id + " starts as a neighbour of both others")

	_expect(Roster.build(WORLD, SEED).roster == roster,
		"Repeated construction with the same world seed is identical")

	# A caller mutating a returned roster must not reach the constant tables or
	# a later build.
	roster.npcs[NPC_LIN].display_name = "改名"
	roster.npcs[NPC_LIN].traits[Personality.DILIGENCE] = 999
	roster.npcs[NPC_LIN].relations[NPC_XU] = "stranger"
	var fresh: Dictionary = Roster.build(WORLD, SEED).roster
	_expect(fresh.npcs[NPC_LIN].display_name == NAMES[NPC_LIN]
		and int(fresh.npcs[NPC_LIN].traits[Personality.DILIGENCE]) != 999
		and fresh.npcs[NPC_LIN].relations[NPC_XU] == Roster.NEIGHBOR,
		"A returned roster is a copy that cannot mutate later derivations")


func _test_seed_variation() -> void:
	var base: Dictionary = Roster.build(WORLD, SEED).roster
	var other: Dictionary = Roster.build(WORLD, OTHER_SEED).roster
	_expect(int(other.world_seed) == OTHER_SEED,
		"A different seed is recorded in the roster")
	_expect(_same_keys(other.npcs, Roster.IDS),
		"Changing the seed keeps the same stable resident ids")

	var stable_identity: bool = true
	var all_valid: bool = true
	var any_trait_differs: bool = false
	for npc_id: String in Roster.IDS:
		var before: Dictionary = base.npcs[npc_id]
		var after: Dictionary = other.npcs[npc_id]
		stable_identity = stable_identity and after.display_name == before.display_name \
			and after.home == before.home and after.relations == before.relations
		all_valid = all_valid and Personality.valid(after.traits)
		for trait_name: String in Personality.TRAITS:
			if int(before.traits[trait_name]) != int(after.traits[trait_name]):
				any_trait_differs = true
	_expect(stable_identity,
		"Display names, homes and baseline relations do not depend on the seed")
	_expect(all_valid, "Every seed-derived profile stays inside the valid range")
	_expect(any_trait_differs,
		"A different world seed produces at least one different personality dimension")

	var other_world: Dictionary = Roster.build(OTHER_WORLD, SEED).roster
	var traits_unchanged: bool = true
	for npc_id: String in Roster.IDS:
		traits_unchanged = traits_unchanged \
			and other_world.npcs[npc_id].traits == base.npcs[npc_id].traits
	_expect(other_world.world_id == OTHER_WORLD and traits_unchanged,
		"Traits derive from id and seed, not from the world id")

	for seed_value: Variant in [0, Personality.MAX_SAFE_INTEGER, 7.0]:
		var accepted: Dictionary = Roster.build(WORLD, seed_value)
		_expect(accepted.ok and int(accepted.roster.world_seed) == int(seed_value),
			"An integral seed in the accepted range builds a roster")
	for bad_seed: Variant in [-1, 1.5, "7", null, NAN, INF,
			float(Personality.MAX_SAFE_INTEGER) + 1.0]:
		var refused: Dictionary = Roster.build(WORLD, bad_seed)
		_expect(not refused.ok and refused.reason == "invalid_seed"
			and refused.roster.is_empty(),
			"An invalid seed is refused without a partial roster")

	for bad_world: Variant in ["", "bad world", "bad/world", 5, null, "a".repeat(256)]:
		var refused: Dictionary = Roster.build(bad_world, SEED)
		_expect(not refused.ok and refused.reason == "invalid_world_id"
			and refused.roster.is_empty(),
			"An invalid world id is refused without a partial roster")


func _test_initial_memory() -> void:
	var initialized: Dictionary = Roster.initialize(WORLD, SEED)
	_expect(initialized.ok and str(initialized.reason).is_empty(),
		"Initialization returns both halves for a valid world")
	var roster: Dictionary = initialized.roster
	var document: Dictionary = initialized.memory
	_expect(not roster.is_empty() and not document.is_empty(),
		"Initialization fills the roster and the memory document")
	_expect(int(document.schema) == Memory.SCHEMA and document.world_id == WORLD
		and _same_keys(document.npcs, Roster.IDS),
		"The seeded memory document names the same world and residents")
	_expect(Memory.valid_document(document, Roster.BASELINE_AT_UTC),
		"The seeded memory document passes the M10-01 strict validation")

	for npc_id: String in Roster.IDS:
		var row: Dictionary = document.npcs[npc_id]
		_expect(row.dropped == 0 and row.entries.size() == 1,
			"Resident " + npc_id + " starts with one baseline memory and no drops")
		var memory_id: String = npc_id + Roster.BASELINE_MEMORY_SUFFIX
		var entry: Dictionary = row.entries[memory_id]
		_expect(entry.id == memory_id and entry.kind == Memory.KIND_OBSERVATION
			and entry.participants == [] and int(entry.salience) == Roster.BASELINE_SALIENCE
			and float(entry.at_utc) == Roster.BASELINE_AT_UTC
			and entry.world_id == WORLD and int(entry.state_version) == 0,
			"Resident " + npc_id + " baseline memory has the fixed shape")
		var retrieved: Dictionary = Memory.retrieve(document, npc_id,
			{"now_utc": Roster.BASELINE_AT_UTC})
		_expect(retrieved.ok and retrieved.total == 1
			and retrieved.entries[0].id == memory_id,
			"Resident " + npc_id + " can retrieve the baseline memory through M10-01")
		var duplicate: Dictionary = Memory.remember(document, npc_id, entry,
			Roster.BASELINE_AT_UTC)
		_expect(not duplicate.ok and duplicate.reason == "duplicate",
			"Re-seeding the same baseline memory is rejected by M10-01 deduplication")

	_expect(Roster.initialize(WORLD, SEED).memory == document,
		"Repeated initialization with the same inputs is identical")
	_expect(Roster.initial_memory(WORLD).document == document,
		"The memory entry alone agrees with initialize()")

	var encoded: Dictionary = Memory.to_json(document, Roster.BASELINE_AT_UTC)
	_expect(encoded.ok, "The seeded memory document serializes with the existing API")
	var decoded: Dictionary = Memory.from_json(encoded.json, Roster.BASELINE_AT_UTC)
	_expect(decoded.ok and decoded.document == document,
		"The seeded memory document round-trips through the existing JSON path")

	for bad_world: Variant in ["", "bad world", 5, null]:
		var refused: Dictionary = Roster.initial_memory(bad_world)
		_expect(not refused.ok and refused.reason == "invalid_world_id"
			and refused.document.is_empty(),
			"An invalid world id is refused without a partial memory document")
	var refused_init: Dictionary = Roster.initialize(WORLD, -1)
	_expect(not refused_init.ok and refused_init.reason == "invalid_seed"
		and refused_init.roster.is_empty() and refused_init.memory.is_empty(),
		"Initialization refuses an invalid seed without partial halves")


func _test_boundaries() -> void:
	var roster: Dictionary = Roster.build(WORLD, SEED).roster
	_expect(not roster.has("farm") and not roster.has("economy")
		and not roster.has("cash") and not roster.has("ledger"),
		"The roster adds no farm, economy or ledger fields")
	for npc_id: String in Roster.IDS:
		var resident: Dictionary = roster.npcs[npc_id]
		_expect(not resident.relations.has("player"),
			"Player-facing relations remain in the existing social/neighbour layer")
		_expect(not resident.has("inventory") and not resident.has("cash")
			and not resident.has("budget"),
			"Resident " + npc_id + " carries identity and preferences only")


func _same_keys(value: Dictionary, keys: Array[String]) -> bool:
	if value.size() != keys.size():
		return false
	for key: String in keys:
		if not value.has(key):
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
