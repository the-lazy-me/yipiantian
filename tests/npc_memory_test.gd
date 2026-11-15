extends SceneTree
## M10-01 personality and bounded memory rules. Headless and isolated: no
## model, clock, disk or live save. FarmState wrappers, scenes and network are
## intentionally untouched by this slice.

const Personality = preload("res://npc/npc_personality.gd")
const Memory = preload("res://npc/npc_memory.gd")

const WORLD: String = "world-a"
const OTHER_WORLD: String = "world-b"
const NPC: String = "npc_lin_shen"
const NPC_B: String = "npc_xu_bo"
const NPC_C: String = "npc_a_zhou"
const PLAYER: String = "player_00000000000000000000000000000001"
const START: float = 1800000000.0
const DAY: float = 86400.0

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_personality()
	_test_write_and_duplicates()
	_test_capacity_and_eviction()
	_test_retrieval()
	_test_restore()
	_test_no_farm_fields()
	for failure: String in failures:
		push_error(failure)
	print("NPC_MEMORY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_personality() -> void:
	var first: Dictionary = Personality.traits(NPC, 7)
	_expect(first.ok, "A valid id and seed produce a profile")
	_expect(first.traits == Personality.traits(NPC, 7).traits,
		"The same id and seed always produce the same profile")
	_expect(Personality.valid(first.traits), "A generated profile passes the strict check")
	for trait_name: String in Personality.TRAITS:
		var value: Variant = first.traits[trait_name]
		_expect(value is int and int(value) >= 0 and int(value) <= 100,
			"Trait " + trait_name + " is an integer in 0..100")
	var described: Dictionary = Personality.describe(first.traits)
	_expect(described.ok and described.text == Personality.describe(first.traits).text,
		"Description is deterministic")
	_expect(str(described.text).contains("勤勉") and str(described.text).ends_with("。"),
		"Description is a short Chinese sentence naming the dimensions")
	_expect(not Personality.describe({}).ok and Personality.describe({}).text == "",
		"Description refuses a malformed profile")

	var other_seed: Dictionary = Personality.traits(NPC, 8)
	var seed_differs: bool = false
	for trait_name: String in Personality.TRAITS:
		if int(other_seed.traits[trait_name]) != int(first.traits[trait_name]):
			seed_differs = true
	_expect(seed_differs, "Another world seed can produce another profile")
	var other_npc: Dictionary = Personality.traits(NPC_B, 7)
	var id_differs: bool = false
	for trait_name: String in Personality.TRAITS:
		if int(other_npc.traits[trait_name]) != int(first.traits[trait_name]):
			id_differs = true
	_expect(id_differs, "Another id can produce another profile")
	var stable: bool = true
	for index: int in 32:
		var candidate: Dictionary = Personality.traits("npc_sample_" + str(index), 7)
		stable = stable and candidate.traits == Personality.traits(
			"npc_sample_" + str(index), 7).traits
	_expect(stable, "Every sampled id is deterministic across repeated derivations")

	for bad_id: Variant in ["", "bad id", "bad/id", 5, null, "a".repeat(65)]:
		var refused: Dictionary = Personality.traits(bad_id, 7)
		_expect(not refused.ok and refused.reason == "invalid_npc_id",
			"An invalid npc id is refused")
	for bad_seed: Variant in [-1, 1.5, "7", null, NAN, INF,
			float(Personality.MAX_SAFE_INTEGER) + 1.0]:
		var refused: Dictionary = Personality.traits(NPC, bad_seed)
		_expect(not refused.ok and refused.reason == "invalid_seed",
			"An invalid world seed is refused")

	var missing: Dictionary = first.traits.duplicate(true)
	missing.erase(Personality.CURIOSITY)
	_expect(not Personality.valid(missing), "A profile with a missing dimension is refused")
	var extra: Dictionary = first.traits.duplicate(true)
	extra["luck"] = 50
	_expect(not Personality.valid(extra), "A profile with an unknown dimension is refused")
	for bad_value: Variant in [-1, 101, 50.5, "50", true]:
		var profile: Dictionary = first.traits.duplicate(true)
		profile[Personality.WARMTH] = bad_value
		_expect(not Personality.valid(profile),
			"A non-integer or out-of-range dimension is refused")
	var edges: Dictionary = first.traits.duplicate(true)
	edges[Personality.DILIGENCE] = 0
	edges[Personality.WARMTH] = 100
	_expect(Personality.valid(edges), "The 0 and 100 boundaries are valid")


func _test_write_and_duplicates() -> void:
	var created: Dictionary = Memory.create(WORLD)
	_expect(created.ok, "A valid world creates an empty memory document")
	var document: Dictionary = created.document
	_expect(document.keys().size() == 3 and document.schema == 1
		and document.world_id == WORLD and document.npcs.is_empty(),
		"The empty document has the fixed schema and no residents")
	_expect(Memory.valid_document(document, START), "The empty document validates")

	var first: Dictionary = _event("mem_001", Memory.KIND_TRADE, [PLAYER], "买了三份种子",
		70, START)
	var written: Dictionary = Memory.remember(document, NPC, first, START)
	_expect(written.ok and not written.duplicate and written.size == 1
		and written.dropped == 0 and written.evicted.is_empty(),
		"A rule event is appended under its resident")
	var stored: Dictionary = document.npcs[NPC].entries["mem_001"]
	_expect(stored.keys().size() == Memory.RECORD_KEYS.size()
		and stored.id == "mem_001" and stored.kind == Memory.KIND_TRADE
		and stored.participants == [PLAYER] and stored.salience == 70
		and stored.at_utc == START and stored.world_id == WORLD
		and stored.state_version == 0,
		"The stored record carries exactly the declared fields")
	_expect(Memory.valid_document(document, START), "The document validates after a write")

	var before_duplicate: Dictionary = document.duplicate(true)
	var duplicate: Dictionary = Memory.remember(document, NPC, first, START)
	_expect(not duplicate.ok and duplicate.reason == "duplicate"
		and duplicate.duplicate and document == before_duplicate,
		"Rewriting the same id returns duplicate and changes nothing")
	var second: Dictionary = _event("mem_002", Memory.KIND_TRADE, [PLAYER], "买了三份种子",
		70, START)
	_expect(Memory.remember(document, NPC, second, START).ok
		and document.npcs[NPC].entries.size() == 2,
		"Two ids with identical content are two separate events")
	_expect(Memory.remember(document, NPC_B, _event("mem_003", Memory.KIND_WEATHER, [],
		"下了一整天雨", 30, START), START).ok
		and document.npcs[NPC].entries.size() == 2
		and document.npcs[NPC_B].entries.size() == 1,
		"Residents keep separate bounded lists")
	var before_cross: Dictionary = document.duplicate(true)
	_expect(not Memory.remember(document, NPC_B, first, START).ok
		and document == before_cross,
		"A memory id reused under another resident is a document-wide duplicate")

	var before_refused: Dictionary = document.duplicate(true)
	var refused: Array[Dictionary] = []
	refused.append(_event("mem_101", Memory.KIND_TRADE, [PLAYER], "未来", 50, START + 1.0))
	refused.append(_event("mem_102", Memory.KIND_TRADE, [PLAYER], "别处", 50, START,
		OTHER_WORLD))
	var bad_kind: Dictionary = _event("mem_103", Memory.KIND_TRADE, [PLAYER], "未知", 50,
		START)
	bad_kind.kind = "rumour"
	refused.append(bad_kind)
	for salience: Variant in [0, 101, 1.5, "50"]:
		refused.append(_event("mem_104", Memory.KIND_TRADE, [PLAYER], "越界", salience,
			START))
	refused.append(_event("mem_105", Memory.KIND_TRADE, [PLAYER], "长".repeat(201), 50,
		START))
	refused.append(_event("mem_106", Memory.KIND_TRADE, [PLAYER], "", 50, START))
	refused.append(_event("mem_107", Memory.KIND_TRADE,
		[PLAYER, NPC, NPC_B, NPC_C, "npc_extra"], "太多", 50, START))
	refused.append(_event("mem_108", Memory.KIND_TRADE, [PLAYER, PLAYER], "重复", 50,
		START))
	refused.append(_event("mem_109", Memory.KIND_TRADE, ["bad id"], "无效", 50, START))
	var no_world: Dictionary = _event("mem_110", Memory.KIND_TRADE, [PLAYER], "缺世界",
		50, START)
	no_world.erase("world_id")
	refused.append(no_world)
	var no_participants: Dictionary = _event("mem_111", Memory.KIND_TRADE, [PLAYER], "缺人",
		50, START)
	no_participants.erase("participants")
	refused.append(no_participants)
	var unknown_key: Dictionary = _event("mem_112", Memory.KIND_TRADE, [PLAYER], "多键",
		50, START)
	unknown_key["mood"] = "happy"
	refused.append(unknown_key)
	var negative_version: Dictionary = _event("mem_113", Memory.KIND_TRADE, [PLAYER],
		"负版本", 50, START)
	negative_version.state_version = -1
	refused.append(negative_version)
	var bad_summary: Dictionary = _event("mem_114", Memory.KIND_TRADE, [PLAYER], "类型",
		50, START)
	bad_summary.summary = 5
	refused.append(bad_summary)
	var bad_id: Dictionary = _event("", Memory.KIND_TRADE, [PLAYER], "空 id", 50, START)
	refused.append(bad_id)
	for event: Dictionary in refused:
		_expect(not Memory.remember(document, NPC, event, START).ok,
			"A malformed or cross-world event is refused")
	_expect(document == before_refused, "Every refused write leaves the document untouched")
	_expect(not Memory.remember(document, "bad id", first, START).ok,
		"An invalid resident id is refused")
	_expect(not Memory.remember(document, NPC, first, -1.0).ok,
		"A negative time is refused")
	var dirty: Dictionary = document.duplicate(true)
	dirty["economy"] = {}
	_expect(Memory.remember(dirty, NPC, _event("mem_115", Memory.KIND_OBSERVATION, [],
		"脏档", 50, START), START).reason == "unknown_key",
		"A document with an unknown top-level key is refused")


func _test_capacity_and_eviction() -> void:
	var document: Dictionary = Memory.create(WORLD).document
	for index: int in Memory.MAX_ENTRIES:
		var written: Dictionary = Memory.remember(document, NPC,
			_event("mem_%03d" % index, Memory.KIND_OBSERVATION, [], "观察 %d" % index,
				50, START - float(Memory.MAX_ENTRIES - 1 - index)), START)
		_expect(written.ok, "The capacity fixture writes entry %d" % index)
	_expect(document.npcs[NPC].entries.size() == Memory.MAX_ENTRIES,
		"The resident is full at exactly the capacity")
	var overflow: Dictionary = Memory.remember(document, NPC,
		_event("mem_new", Memory.KIND_CONFLICT, [PLAYER], "争执", 60, START), START)
	_expect(overflow.ok and overflow.size == Memory.MAX_ENTRIES
		and overflow.dropped == 1 and overflow.evicted == ["mem_000"],
		"A new event evicts the oldest lowest-salience entry")
	_expect(not document.npcs[NPC].entries.has("mem_000")
		and document.npcs[NPC].entries.has("mem_new"),
		"The evicted id is gone and the new id is stored")
	var next: Dictionary = Memory.remember(document, NPC,
		_event("mem_new_2", Memory.KIND_CONFLICT, [PLAYER], "再争执", 60, START), START)
	_expect(next.ok and next.dropped == 2 and next.evicted == ["mem_001"],
		"The next overflow evicts the next oldest entry")
	_expect(document.npcs[NPC].dropped == 2, "The dropped counter matches the evictions")

	var monotonic: bool = true
	var previous: int = int(document.npcs[NPC].dropped)
	for index: int in 20:
		var result: Dictionary = Memory.remember(document, NPC,
			_event("mem_extra_%02d" % index, Memory.KIND_DIALOGUE, [PLAYER],
				"对话 %d" % index, 40 + index % 10, START), START)
		monotonic = monotonic and result.ok and int(result.dropped) >= previous
		previous = int(result.dropped)
	_expect(monotonic, "dropped never decreases while writing past capacity")

	var keep_document: Dictionary = Memory.create(WORLD).document
	for index: int in Memory.MAX_ENTRIES - 1:
		Memory.remember(keep_document, NPC,
			_event("low_%03d" % index, Memory.KIND_OBSERVATION, [], "琐事", 10,
				START - float(Memory.MAX_ENTRIES - index)), START)
	Memory.remember(keep_document, NPC,
		_event("keep", Memory.KIND_CONFLICT, [PLAYER], "重要冲突", 100, START - 100.0),
		START)
	var low_evictions: int = 0
	for index: int in 5:
		var written: Dictionary = Memory.remember(keep_document, NPC,
			_event("high_%02d" % index, Memory.KIND_GIFT, [PLAYER], "赠礼", 90, START),
			START)
		low_evictions = int(written.dropped)
	_expect(keep_document.npcs[NPC].entries.has("keep")
		and low_evictions == 5,
		"High-salience recent events survive while low-salience rows are evicted")
	var kept: Dictionary = Memory.retrieve(keep_document, NPC,
		{"now_utc": START, "limit": 64})
	_expect(kept.ok and int(kept.entries[0].salience) == 100,
		"The retained high-salience event still ranks first")


func _test_retrieval() -> void:
	var document: Dictionary = Memory.create(WORLD).document
	var rows: Array[Dictionary] = [
		_event("old_high", Memory.KIND_CONFLICT, [PLAYER], "十年前的冲突", 100,
			START - 10.0 * DAY),
		_event("today_mid", Memory.KIND_DIALOGUE, [PLAYER], "今天的闲聊", 50, START),
		_event("old_low", Memory.KIND_OBSERVATION, [], "二十年前的旧事", 60,
			START - 20.0 * DAY),
		_event("tie_a", Memory.KIND_GIFT, [PLAYER], "同分甲", 50, START),
		_event("tie_b", Memory.KIND_GIFT, [PLAYER], "同分乙", 50, START),
		_event("weather", Memory.KIND_WEATHER, [], "晴天", 30, START),
		_event("with_player", Memory.KIND_TRADE, [PLAYER, NPC_B], "与玩家交易", 70,
			START),
	]
	for row: Dictionary in rows:
		_expect(Memory.remember(document, NPC, row, START).ok,
			"Retrieval fixture writes " + str(row.id))

	var all: Dictionary = Memory.retrieve(document, NPC, {"now_utc": START, "limit": 64})
	var order: Array[String] = []
	for entry: Dictionary in all.entries:
		order.append(str(entry.id))
	_expect(order == ["old_high", "with_player", "tie_a", "tie_b", "today_mid",
		"old_low", "weather"],
		"Retrieval sorts by decayed salience, then recent time, then id")
	_expect(all.total == 7, "Total reports every match before the limit")
	_expect(Memory.effective_salience(document.npcs[NPC].entries["old_high"], START) == 90
		and Memory.effective_salience(document.npcs[NPC].entries["old_low"], START) == 40,
		"One point per full day of age, floor one, drives the order")
	_expect(Memory.effective_salience(document.npcs[NPC].entries["old_high"],
		START - 11.0 * DAY) == 100, "A retrieval time before the event uses zero age")

	var limited: Dictionary = Memory.retrieve(document, NPC, {"now_utc": START, "limit": 3})
	_expect(limited.entries.size() == 3 and limited.total == 7
		and limited.entries[0].id == "old_high" and limited.entries[2].id == "tie_a",
		"The limit takes the first N of the deterministic order")

	var by_participant: Dictionary = Memory.retrieve(document, NPC,
		{"now_utc": START, "limit": 64, "participant": PLAYER})
	_expect(by_participant.total == 5
		and not _has_entry(by_participant.entries, "weather"),
		"A participant filter keeps only events naming that participant")
	var by_kind: Dictionary = Memory.retrieve(document, NPC,
		{"now_utc": START, "limit": 64, "kind": Memory.KIND_WEATHER})
	_expect(by_kind.total == 1 and by_kind.entries[0].id == "weather",
		"A kind filter keeps only that event kind")
	var filtered: Dictionary = Memory.retrieve(document, NPC,
		{"now_utc": START, "limit": 64, "participant": PLAYER,
		"kind": Memory.KIND_WEATHER})
	_expect(filtered.ok and filtered.total == 0 and filtered.entries.is_empty(),
		"A participant and kind filter combine with AND")

	var before_decay: Dictionary = document.duplicate(true)
	Memory.retrieve(document, NPC, {"now_utc": START + 365.0 * DAY, "limit": 64})
	_expect(document == before_decay, "Decay affects ordering only and never rewrites records")

	var copy: Dictionary = all.entries[0].duplicate(true)
	copy.summary = "被调用方修改"
	_expect(document.npcs[NPC].entries["old_high"].summary == "十年前的冲突",
		"Retrieved rows are copies, not live entries")
	_expect(Memory.retrieve(document, NPC, {"now_utc": START, "limit": 64}).entries
		== all.entries, "Repeated retrieval returns the same order")

	var empty: Dictionary = Memory.retrieve(document, NPC_C, {"now_utc": START})
	_expect(empty.ok and empty.total == 0 and empty.entries.is_empty(),
		"A resident with no memories retrieves an empty list")
	for options: Variant in [
		{}, {"now_utc": -1.0}, {"now_utc": START, "limit": 0},
		{"now_utc": START, "limit": 65}, {"now_utc": START, "limit": 1.5},
		{"now_utc": START, "mood": "happy"}, {"now_utc": START, "participant": "bad id"},
		{"now_utc": START, "kind": "rumour"}, "now",
	]:
		_expect(not Memory.retrieve(document, NPC, options).ok,
			"A malformed retrieval option is refused")
	_expect(not Memory.retrieve(document, "bad id", {"now_utc": START}).ok,
		"Retrieval refuses an invalid resident id")


func _test_restore() -> void:
	var document: Dictionary = Memory.create(WORLD).document
	Memory.remember(document, NPC, _event("mem_001", Memory.KIND_TRADE, [PLAYER],
		"买了种子", 70, START, WORLD, 42), START)
	Memory.remember(document, NPC, _event("mem_002", Memory.KIND_WEATHER, [],
		"下了一整天雨", 30, START), START)
	Memory.remember(document, NPC_B, _event("mem_003", Memory.KIND_GIFT, [NPC],
		"收到一篮鸡蛋", 80, START, WORLD, 7), START)
	_expect(document.npcs[NPC].entries.mem_001.state_version == 42,
		"The state version is stored as supplied")

	var encoded: Dictionary = Memory.to_json(document, START)
	_expect(encoded.ok, "A valid document serializes to JSON")
	var decoded: Dictionary = Memory.from_json(encoded.json, START)
	_expect(decoded.ok and decoded.document == document,
		"A JSON round trip restores the same document")
	var parsed_back: Dictionary = Memory.from_document(JSON.parse_string(encoded.json), START)
	_expect(parsed_back.ok and parsed_back.document == document,
		"JSON numbers normalize back to integer counters and float times")
	_expect(not Memory.to_json({"schema": 1, "world_id": WORLD, "npcs": [], "extra": 1},
		START).ok, "An invalid document is not serialized")
	for bad_json: Variant in ["", "null", "[]", "5", 5, null]:
		_expect(not Memory.from_json(bad_json, START).ok, "Invalid JSON is refused")

	var extra_document: Dictionary = document.duplicate(true)
	extra_document["economy"] = {}
	_expect(Memory.from_document(extra_document, START).reason == "unknown_key",
		"A farm or economy key in the document is refused")
	var extra_npc: Dictionary = document.duplicate(true)
	extra_npc.npcs[NPC]["mood"] = "happy"
	_expect(Memory.from_document(extra_npc, START).reason == "unknown_key",
		"An unknown resident field is refused")
	var extra_entry: Dictionary = document.duplicate(true)
	extra_entry.npcs[NPC].entries.mem_001["mood"] = "happy"
	_expect(Memory.from_document(extra_entry, START).reason == "unknown_key",
		"An unknown entry field is refused")

	var duplicate_id: Dictionary = _raw_document({
		NPC: {"dropped": 0, "entries": {"mem_same": _raw_entry("mem_same")}},
		NPC_B: {"dropped": 0, "entries": {"mem_same": _raw_entry("mem_same")}},
	})
	_expect(Memory.from_document(duplicate_id, START).reason == "duplicate_id",
		"The same memory id under two residents is refused")
	var mismatched_key: Dictionary = _raw_document({
		NPC: {"dropped": 0, "entries": {"mem_key": _raw_entry("mem_other")}},
	})
	_expect(Memory.from_document(mismatched_key, START).reason == "invalid_entry",
		"An entry whose id differs from its map key is refused")

	var cross_world: Dictionary = _raw_document({
		NPC: {"dropped": 0, "entries": {"mem_x": _raw_entry("mem_x", OTHER_WORLD)}},
	})
	_expect(Memory.from_document(cross_world, START).reason == "cross_world",
		"An entry from another world is refused")
	var future: Dictionary = _raw_document({
		NPC: {"dropped": 0, "entries": {"mem_x": _raw_entry("mem_x", WORLD,
			START + 1.0)}},
	})
	_expect(Memory.from_document(future, START).reason == "future_time",
		"An entry in the future is refused")
	var negative: Dictionary = _raw_document({
		NPC: {"dropped": -1, "entries": {}},
	})
	_expect(Memory.from_document(negative, START).reason == "invalid_dropped",
		"A negative drop counter is refused")
	var bad_salience: Dictionary = _raw_document({
		NPC: {"dropped": 0, "entries": {"mem_x": _raw_entry("mem_x", WORLD, START, 0)}},
	})
	_expect(Memory.from_document(bad_salience, START).reason == "invalid_salience",
		"An out-of-range salience is refused on restore")
	var bad_version: Dictionary = _raw_document({
		NPC: {"dropped": 0, "entries": {"mem_x": _raw_entry("mem_x", WORLD, START, 10,
			-1)}},
	})
	_expect(Memory.from_document(bad_version, START).reason == "invalid_state_version",
		"A negative state version is refused")
	var bad_schema: Dictionary = _raw_document({})
	bad_schema.schema = 2
	_expect(Memory.from_document(bad_schema, START).reason == "invalid_schema",
		"An unknown schema is refused")
	var no_world: Dictionary = _raw_document({})
	no_world.erase("world_id")
	_expect(Memory.from_document(no_world, START).reason == "invalid_world_id",
		"A document without a world id is refused")

	var too_many: Dictionary = {}
	for index: int in Memory.MAX_ENTRIES + 1:
		too_many["mem_%03d" % index] = _raw_entry("mem_%03d" % index)
	var overflow: Dictionary = _raw_document({NPC: {"dropped": 0, "entries": too_many}})
	_expect(Memory.from_document(overflow, START).reason == "too_many_entries",
		"A resident above the capacity is refused")

	var legacy: Dictionary = {
		"world_id": WORLD,
		"npcs": {NPC: {"entries": {
			"mem_legacy": {
				"id": "mem_legacy", "kind": Memory.KIND_WEATHER,
				"summary": "旧档里的晴", "salience": 10, "at_utc": START,
			},
		}}},
	}
	var restored: Dictionary = Memory.from_document(legacy, START)
	_expect(restored.ok and restored.document.schema == 1
		and restored.document.npcs[NPC].dropped == 0,
		"Missing schema, drop counter and entry list read as explicit defaults")
	var legacy_entry: Dictionary = restored.document.npcs[NPC].entries.mem_legacy
	_expect(legacy_entry.world_id == WORLD and legacy_entry.state_version == 0
		and legacy_entry.participants == [],
		"Missing entry world, version and participants read as explicit defaults")
	var minimal: Dictionary = Memory.from_document({"world_id": WORLD}, START)
	_expect(minimal.ok and minimal.document.npcs.is_empty(),
		"A document without residents restores as an empty memory set")


func _test_no_farm_fields() -> void:
	var created: Dictionary = Memory.create(WORLD)
	var document: Dictionary = created.document
	_expect(_same_keys(document, Memory.DOCUMENT_KEYS),
		"The memory document adds no farm or economy top-level key")
	Memory.remember(document, NPC, _event("mem_001", Memory.KIND_TRADE, [PLAYER],
		"交易", 50, START), START)
	var record: Dictionary = document.npcs[NPC].entries.mem_001
	_expect(_same_keys(record, Memory.RECORD_KEYS),
		"Memory records expose only the declared fields")
	for field: String in ["farm", "economy", "cash", "crop", "ledger"]:
		var dirty: Dictionary = document.duplicate(true)
		dirty[field] = {}
		_expect(not Memory.valid_document(dirty, START),
			"A farm or economy field is rejected: " + field)


func _event(id: String, kind: String, participants: Array, summary: String,
		salience: Variant, at_utc: float, world_id: String = WORLD,
		state_version: int = 0) -> Dictionary:
	return {
		"id": id, "kind": kind, "participants": participants.duplicate(),
		"summary": summary, "salience": salience, "at_utc": at_utc,
		"world_id": world_id, "state_version": state_version,
	}


func _raw_document(npcs: Dictionary) -> Dictionary:
	return {"schema": Memory.SCHEMA, "world_id": WORLD, "npcs": npcs}


func _raw_entry(id: String, world_id: String = WORLD, at_utc: float = START,
		salience: int = 10, state_version: int = 0) -> Dictionary:
	return {
		"id": id, "kind": Memory.KIND_WEATHER, "participants": [],
		"summary": "晴", "salience": salience, "at_utc": at_utc,
		"world_id": world_id, "state_version": state_version,
	}


func _has_entry(entries: Array, id: String) -> bool:
	for entry: Dictionary in entries:
		if str(entry.id) == id:
			return true
	return false


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
