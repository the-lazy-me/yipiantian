extends RefCounted
## M10-02 deterministic resident roster. Pure rules: no model, clock, disk,
## scene or network access.
##
## The three authored residents keep stable ids and display names. Their five
## personality dimensions are rebuilt through the M10-01 `NpcPersonality` entry
## from `npc_id + world_seed`, and their initial memory document is seeded
## through the M10-01 `NpcMemory` entry. This module never derives traits or
## evicts memories itself.
##
## The roster is derived data, not a save document: the same world id, seed and
## resident ids rebuild exactly the same document. Persisting it would create a
## second copy that could drift from the derivation, so this slice adds no
## store and no farm snapshot key. The seeded memory document remains ordinary
## M10-01 memory state and can use its existing JSON round trip when a caller
## decides to persist it.

const Personality = preload("res://npc/npc_personality.gd")
const Memory = preload("res://npc/npc_memory.gd")

const SCHEMA: int = 1
const NPC_LIN_SHEN: String = "npc_lin_shen"
const NPC_XU_BO: String = "npc_xu_bo"
const NPC_A_ZHOU: String = "npc_a_zhou"
const IDS: Array[String] = [NPC_LIN_SHEN, NPC_XU_BO, NPC_A_ZHOU]

const DISPLAY_NAMES: Dictionary = {
	NPC_LIN_SHEN: "林婶",
	NPC_XU_BO: "许伯",
	NPC_A_ZHOU: "阿舟",
}
const HOMES: Dictionary = {
	NPC_LIN_SHEN: "柳岸",
	NPC_XU_BO: "竹汀",
	NPC_A_ZHOU: "渡口",
}

## Authored baseline from the existing neighbour stories: the three already
## know each other and share meals. Labels are stable identity facts, not a
## seed-derived score; M10-03 can turn them into rules when relationships
## actually affect action choice.
const NEIGHBOR: String = "neighbor"
const RELATIONS: Dictionary = {
	NPC_LIN_SHEN: {NPC_XU_BO: NEIGHBOR, NPC_A_ZHOU: NEIGHBOR},
	NPC_XU_BO: {NPC_LIN_SHEN: NEIGHBOR, NPC_A_ZHOU: NEIGHBOR},
	NPC_A_ZHOU: {NPC_LIN_SHEN: NEIGHBOR, NPC_XU_BO: NEIGHBOR},
}

## Baseline observation per resident. These are authored identity facts, not
## model output and not fabricated transactions. `at_utc` is the fixed epoch
## so initialization stays deterministic and independent of the caller's
## clock; M10-01 memory still validates the document.
const BASELINE_SUMMARIES: Dictionary = {
	NPC_LIN_SHEN: "在柳岸住下，与许伯、阿舟常来常往。",
	NPC_XU_BO: "在竹汀做竹活，与林婶、阿舟相熟。",
	NPC_A_ZHOU: "以渡口为家，常与林婶、许伯同桌吃饭。",
}
const BASELINE_MEMORY_SUFFIX: String = "_init"
const BASELINE_SALIENCE: int = 10
const BASELINE_AT_UTC: float = 0.0

const ROSTER_KEYS: Array[String] = ["schema", "world_id", "world_seed", "npcs"]
const RESIDENT_KEYS: Array[String] = ["display_name", "home", "traits", "relations"]


## Rebuilds the roster for one world seed. The memory document's world-id rule
## is reused as the single authority so a roster cannot name a world the memory
## layer would refuse. An invalid seed is reported by the personality entry.
static func build(world_id: Variant, world_seed: Variant) -> Dictionary:
	var created: Dictionary = Memory.create(world_id)
	if not created.ok:
		return {"ok": false, "reason": str(created.reason), "roster": {}}
	var npcs: Dictionary = {}
	for npc_id: String in IDS:
		var profile: Dictionary = Personality.traits(npc_id, world_seed)
		if not profile.ok:
			return {"ok": false, "reason": str(profile.reason), "roster": {}}
		npcs[npc_id] = {
			"display_name": DISPLAY_NAMES[npc_id],
			"home": HOMES[npc_id],
			"traits": (profile.traits as Dictionary).duplicate(true),
			"relations": (RELATIONS[npc_id] as Dictionary).duplicate(true),
		}
	return {
		"ok": true, "reason": "",
		"roster": {
			"schema": SCHEMA,
			"world_id": str(world_id),
			"world_seed": int(world_seed),
			"npcs": npcs,
		},
	}


## Starts a memory document with one baseline observation per resident. Every
## row is appended through M10-01 `remember()`, so ids stay document-wide
## unique and the regular validation/eviction rules remain the only authority.
static func initial_memory(world_id: Variant) -> Dictionary:
	var created: Dictionary = Memory.create(world_id)
	if not created.ok:
		return {"ok": false, "reason": str(created.reason), "document": {}}
	var document: Dictionary = created.document
	for npc_id: String in IDS:
		var written: Dictionary = Memory.remember(document, npc_id, {
			"id": npc_id + BASELINE_MEMORY_SUFFIX,
			"kind": Memory.KIND_OBSERVATION,
			"participants": [],
			"summary": BASELINE_SUMMARIES[npc_id],
			"salience": BASELINE_SALIENCE,
			"at_utc": BASELINE_AT_UTC,
			"world_id": str(world_id),
			"state_version": 0,
		}, BASELINE_AT_UTC)
		if not written.ok:
			return {"ok": false, "reason": str(written.reason), "document": {}}
	return {"ok": true, "reason": "", "document": document}


## One call for the consumers that need both the roster and its starting
## memory. The two halves are rebuilt together so they cannot name different
## worlds.
static func initialize(world_id: Variant, world_seed: Variant) -> Dictionary:
	var built: Dictionary = build(world_id, world_seed)
	if not built.ok:
		return {
			"ok": false, "reason": str(built.reason), "roster": {}, "memory": {},
		}
	var memory: Dictionary = initial_memory(world_id)
	if not memory.ok:
		return {
			"ok": false, "reason": str(memory.reason), "roster": {}, "memory": {},
		}
	return {
		"ok": true, "reason": "",
		"roster": built.roster, "memory": memory.document,
	}
