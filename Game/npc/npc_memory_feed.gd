extends RefCounted
## M10-03 input layer: turn committed world events into resident memories.
##
## This adapter is pure rules. It never reads the clock, RNG, disk, scene,
## network or a model; the caller injects `now_utc` and the world roster. Only
## M10-01's public `NpcMemory.remember()` writes rows, so id uniqueness,
## capacity and eviction stay the single authority.
##
## Input is the smallest projection of a committed event:
##
##   {
##     "kind": "harvest" | "sow" | "water" | "gift" | "theft" | "build"
##           | "trade" | "territory_claim",
##     "id": "<committed command/event id>",
##     "actor": "<resolved player or npc id>" | "",
##     "target": "<locator, counterparty or victim id>" | "",
##     "ok": true | false,
##   }
##
## `target` is read per kind: a field/slot/parcel locator for farm and land
## actions, the recipient for `gift`, the harmed resident for `theft`, and the
## counterparty for `trade`.
##
## Only `ok == true` events write. Rejected or failed events, and events from an
## anonymous actor, are reported as skipped with no rows. A resident named in
## the roster is the only possible subject; an id outside the roster never gets
## a memory row. A committed event is remembered by its direct residents
## (own action, own land, receiving, losing, trading) at a factual salience;
## every other roster resident gets one low-salience observation. Observers are
## written in resident-id order so a replay produces the same document.
##
## Memory ids are a deterministic hash of (event id, resident id), because
## M10-01 fixes the record at eight fields and reserves the id as the only
## place a caller can make a replay idempotent. The returned row also carries
## `source_event_id` for callers and tests; the document itself has no separate
## source field by design.

const Memory = preload("res://npc/npc_memory.gd")
const OwnerIds = preload("res://farm/owner_id.gd")

const KIND_HARVEST: String = "harvest"
const KIND_SOW: String = "sow"
const KIND_WATER: String = "water"
const KIND_GIFT: String = "gift"
const KIND_THEFT: String = "theft"
const KIND_BUILD: String = "build"
const KIND_TRADE: String = "trade"
const KIND_TERRITORY_CLAIM: String = "territory_claim"

const KINDS: Array[String] = [
	KIND_HARVEST, KIND_SOW, KIND_WATER, KIND_GIFT, KIND_THEFT, KIND_BUILD,
	KIND_TRADE, KIND_TERRITORY_CLAIM,
]

const EVENT_KEYS: Array[String] = ["kind", "id", "actor", "target", "ok"]
const CONTEXT_KEYS: Array[String] = ["now_utc", "world_id", "roster"]
const MAX_TARGET_LENGTH: int = 128

## Direct factual salience. Receiving and losing outrank a routine action, and
## an observer's row is low enough that M10-01's capacity rule evicts it first.
const SALIENCE_ACTION: int = 40
const SALIENCE_BUILD: int = 55
const SALIENCE_LAND: int = 70
const SALIENCE_GIFT_GIVEN: int = 45
const SALIENCE_GIFT_RECEIVED: int = 60
const SALIENCE_THEFT_VICTIM: int = 85
const SALIENCE_THEFT_ACTOR: int = 55
const SALIENCE_TRADE: int = 60
const SALIENCE_OBSERVER: int = 5

const HASH_OFFSET: int = 2166136261
const HASH_PRIME: int = 16777619
const HASH_MASK: int = 0xFFFFFFFF
const GENERIC_VISITOR: String = "来客"


## Applies one committed event to `document` in place. Returns the rows written
## (or already present) for each affected resident. Validation happens before
## the first write, so an invalid call leaves the document untouched.
static func apply(document: Variant, projection: Variant,
		context: Variant) -> Dictionary:
	var checked_context: Dictionary = _check_context(context)
	if not checked_context.ok:
		return _error(str(checked_context.reason))
	if not document is Dictionary:
		return _error("invalid_document")
	var stored: Dictionary = document
	var settings: Dictionary = checked_context.context
	var checked_document: Dictionary = Memory.validate_document(stored, settings.now_utc)
	if not checked_document.ok:
		return _error(str(checked_document.reason))
	if str(stored.world_id) != str(settings.world_id):
		return _error("world_mismatch")
	var checked_event: Dictionary = _check_event(projection)
	if not checked_event.ok:
		return _error(str(checked_event.reason))
	var event: Dictionary = checked_event.event
	if not bool(event.ok):
		return _skipped(str(event.id), "not_committed")
	if str(event.actor).is_empty():
		return _skipped(str(event.id), "anonymous_actor")
	return _write_event(stored, event, settings)


## Applies a sequence in order. Every event is shape-checked first, so a
## malformed batch writes nothing at all. A committed event is still written
## through `apply()`, keeping one write path.
static func apply_sequence(document: Variant, events: Variant,
		context: Variant) -> Dictionary:
	if not events is Array:
		return _sequence_error("invalid_events", 0)
	var checked_context: Dictionary = _check_context(context)
	if not checked_context.ok:
		return _sequence_error(str(checked_context.reason), 0)
	if not document is Dictionary:
		return _sequence_error("invalid_document", 0)
	var stored: Dictionary = document
	var settings: Dictionary = checked_context.context
	var checked_document: Dictionary = Memory.validate_document(stored, settings.now_utc)
	if not checked_document.ok:
		return _sequence_error(str(checked_document.reason), 0)
	if str(stored.world_id) != str(settings.world_id):
		return _sequence_error("world_mismatch", 0)
	var normalized: Array[Dictionary] = []
	var raw_events: Array = events
	for index: int in raw_events.size():
		var checked: Dictionary = _check_event(raw_events[index])
		if not checked.ok:
			return _sequence_error(str(checked.reason), index)
		normalized.append(checked.event)
	var results: Array = []
	var written: int = 0
	var duplicates: int = 0
	var skipped: int = 0
	for index: int in normalized.size():
		var result: Dictionary = apply(stored, normalized[index], context)
		if not result.ok:
			return {
				"ok": false, "reason": str(result.reason), "index": index,
				"results": results, "written": written, "duplicates": duplicates,
				"skipped": skipped,
			}
		results.append(result)
		written += int(result.written)
		duplicates += int(result.duplicates)
		if not str(result.skipped).is_empty():
			skipped += 1
	return {
		"ok": true, "reason": "", "results": results, "written": written,
		"duplicates": duplicates, "skipped": skipped,
	}


## Deterministic memory id for one (event, resident) pair. The document-wide id
## rule is M10-01's; this adapter only needs a stable id so a replay is
## recognised as `duplicate` instead of appending a second row.
static func memory_id(event_id: String, npc_id: String) -> String:
	return "m%s%s" % [_token(event_id, "event"), _token(npc_id, "subject")]


static func _write_event(document: Dictionary, event: Dictionary,
		settings: Dictionary) -> Dictionary:
	var roster: Dictionary = settings.roster
	var subjects: Array[Dictionary] = _direct_subjects(event, roster)
	var direct: Dictionary = {}
	for subject: Dictionary in subjects:
		direct[str(subject.npc_id)] = true
	var resident_ids: Array = (roster.npcs as Dictionary).keys()
	resident_ids.sort()
	for npc_id: Variant in resident_ids:
		if direct.has(str(npc_id)):
			continue
		subjects.append({
			"npc_id": str(npc_id), "kind": Memory.KIND_OBSERVATION,
			"salience": SALIENCE_OBSERVER,
			"summary": _observer_summary(event, roster),
		})
	var participants: Array = _participants(event)
	var entries: Array = []
	var duplicates: int = 0
	for subject: Dictionary in subjects:
		var event_id: String = str(event.id)
		var npc_id: String = str(subject.npc_id)
		var snapshot: Dictionary = {
			"npc_id": npc_id,
			"memory_id": memory_id(event_id, npc_id),
			"kind": str(subject.kind),
			"salience": int(subject.salience),
			"summary": _clip(str(subject.summary)),
			"source_event_id": event_id,
			"duplicate": false,
		}
		var written: Dictionary = Memory.remember(document, npc_id, {
			"id": snapshot.memory_id,
			"kind": snapshot.kind,
			"participants": participants,
			"summary": snapshot.summary,
			"salience": snapshot.salience,
			"at_utc": settings.now_utc,
			"world_id": settings.world_id,
			"state_version": 0,
		}, settings.now_utc)
		if not written.ok:
			if str(written.reason) == "duplicate":
				snapshot.duplicate = true
				duplicates += 1
				entries.append(snapshot)
				continue
			return _error(str(written.reason))
		entries.append(snapshot)
	return {
		"ok": true, "reason": "", "event_id": str(event.id), "skipped": "",
		"entries": entries, "written": entries.size() - duplicates,
		"duplicates": duplicates,
	}


static func _direct_subjects(event: Dictionary, roster: Dictionary) -> Array[Dictionary]:
	var subjects: Array[Dictionary] = []
	var kind: String = str(event.kind)
	var actor: String = str(event.actor)
	var target: String = str(event.target)
	var actor_resident: bool = _resident(roster, actor)
	var target_resident: bool = _resident(roster, target)
	var actor_name: String = _display_name(roster, actor)
	var target_name: String = _display_name(roster, target)
	match kind:
		KIND_GIFT:
			if actor_resident:
				subjects.append({
					"npc_id": actor, "kind": Memory.KIND_GIFT,
					"salience": SALIENCE_GIFT_GIVEN,
					"summary": "%s把作物送给了%s。" % [actor_name, target_name],
				})
			if target_resident and target != actor:
				subjects.append({
					"npc_id": target, "kind": Memory.KIND_GIFT,
					"salience": SALIENCE_GIFT_RECEIVED,
					"summary": "%s送来了作物。" % actor_name,
				})
		KIND_THEFT:
			if target_resident:
				subjects.append({
					"npc_id": target, "kind": Memory.KIND_CONFLICT,
					"salience": SALIENCE_THEFT_VICTIM,
					"summary": "%s拿走了地里的作物。" % actor_name,
				})
			if actor_resident and actor != target:
				subjects.append({
					"npc_id": actor, "kind": Memory.KIND_CONFLICT,
					"salience": SALIENCE_THEFT_ACTOR,
					"summary": "从%s的地里拿走了作物。" % target_name,
				})
		KIND_TRADE:
			if actor_resident:
				subjects.append({
					"npc_id": actor, "kind": Memory.KIND_TRADE,
					"salience": SALIENCE_TRADE,
					"summary": "与%s做成了一笔交易。" % target_name,
				})
			if target_resident and target != actor:
				subjects.append({
					"npc_id": target, "kind": Memory.KIND_TRADE,
					"salience": SALIENCE_TRADE,
					"summary": "与%s做成了一笔交易。" % actor_name,
				})
		_:
			if actor_resident:
				subjects.append({
					"npc_id": actor, "kind": Memory.KIND_OBSERVATION,
					"salience": _action_salience(kind),
					"summary": "%s%s。" % [actor_name, _action_text(kind)],
				})
	return subjects


static func _observer_summary(event: Dictionary, roster: Dictionary) -> String:
	var kind: String = str(event.kind)
	var actor_name: String = _display_name(roster, str(event.actor))
	var target_name: String = _display_name(roster, str(event.target))
	match kind:
		KIND_GIFT:
			return "看见%s把作物送给%s。" % [actor_name, target_name]
		KIND_THEFT:
			if str(event.target).is_empty():
				return "看见%s拿走了地里的作物。" % actor_name
			return "看见%s从%s的地里拿走作物。" % [actor_name, target_name]
		KIND_TRADE:
			return "看见%s与%s成交。" % [actor_name, target_name]
		_:
			return "看见%s%s。" % [actor_name, _action_text(kind)]


static func _action_text(kind: String) -> String:
	match kind:
		KIND_HARVEST:
			return "在田里收获了作物"
		KIND_SOW:
			return "在田里播下了种子"
		KIND_WATER:
			return "给田里浇了水"
		KIND_BUILD:
			return "动工建起了一处建筑"
		KIND_TERRITORY_CLAIM:
			return "主张了一块土地"
		_:
			return "做了一件事"


static func _action_salience(kind: String) -> int:
	match kind:
		KIND_BUILD:
			return SALIENCE_BUILD
		KIND_TERRITORY_CLAIM:
			return SALIENCE_LAND
		_:
			return SALIENCE_ACTION


## Only people belong in `participants`; locators (field, slot, parcel) must not
## leak into the person list.
static func _participants(event: Dictionary) -> Array:
	var kind: String = str(event.kind)
	if kind not in [KIND_GIFT, KIND_THEFT, KIND_TRADE]:
		return _people([str(event.actor)])
	return _people([str(event.actor), str(event.target)])


static func _people(values: Array) -> Array:
	var people: Array = []
	for value: Variant in values:
		var person: String = str(value)
		if OwnerIds.valid(person) and not person in people:
			people.append(person)
	return people


static func _check_context(context: Variant) -> Dictionary:
	if not context is Dictionary:
		return {"ok": false, "reason": "invalid_context", "context": {}}
	var source: Dictionary = context
	for key: Variant in source.keys():
		if not (key is String) or not str(key) in CONTEXT_KEYS:
			return {"ok": false, "reason": "unknown_context_key", "context": {}}
	for key: String in CONTEXT_KEYS:
		if not source.has(key):
			return {"ok": false, "reason": "invalid_context", "context": {}}
	if not _valid_time(source.now_utc):
		return {"ok": false, "reason": "invalid_time", "context": {}}
	var created: Dictionary = Memory.create(source.world_id)
	if not created.ok:
		return {"ok": false, "reason": "invalid_world_id", "context": {}}
	if not source.roster is Dictionary:
		return {"ok": false, "reason": "invalid_roster", "context": {}}
	var roster: Dictionary = source.roster
	if not roster.get("npcs") is Dictionary:
		return {"ok": false, "reason": "invalid_roster", "context": {}}
	if not roster.get("world_id") is String \
			or str(roster.world_id) != str(source.world_id):
		return {"ok": false, "reason": "roster_world_mismatch", "context": {}}
	var npcs: Dictionary = roster.npcs
	for npc_id: Variant in npcs.keys():
		if not _valid_id(npc_id) or not npcs[npc_id] is Dictionary:
			return {"ok": false, "reason": "invalid_roster", "context": {}}
	return {
		"ok": true, "reason": "",
		"context": {
			"now_utc": float(source.now_utc), "world_id": str(source.world_id),
			"roster": roster,
		},
	}


static func _check_event(projection: Variant) -> Dictionary:
	if not projection is Dictionary:
		return {"ok": false, "reason": "invalid_event", "event": {}}
	var source: Dictionary = projection
	for key: Variant in source.keys():
		if not (key is String) or not str(key) in EVENT_KEYS:
			return {"ok": false, "reason": "unknown_event_key", "event": {}}
	for key: String in ["kind", "id", "ok"]:
		if not source.has(key):
			return {"ok": false, "reason": "invalid_event", "event": {}}
	if not source.kind is String or not str(source.kind) in KINDS:
		return {"ok": false, "reason": "invalid_kind", "event": {}}
	if not _valid_id(source.id):
		return {"ok": false, "reason": "invalid_event_id", "event": {}}
	if not source.ok is bool:
		return {"ok": false, "reason": "invalid_ok", "event": {}}
	for key: String in ["actor", "target"]:
		if source.has(key) and not source[key] is String:
			return {"ok": false, "reason": "invalid_" + key, "event": {}}
	var actor: String = str(source.get("actor", ""))
	if not actor.is_empty() and not _valid_id(actor):
		return {"ok": false, "reason": "invalid_actor", "event": {}}
	var target: String = str(source.get("target", ""))
	if target.length() > MAX_TARGET_LENGTH:
		return {"ok": false, "reason": "invalid_target", "event": {}}
	return {
		"ok": true, "reason": "",
		"event": {
			"kind": str(source.kind), "id": str(source.id), "actor": actor,
			"target": target, "ok": bool(source.ok),
		},
	}


static func _resident(roster: Dictionary, npc_id: String) -> bool:
	if npc_id.is_empty():
		return false
	var npcs: Dictionary = roster.npcs
	return npcs.has(npc_id) and npcs[npc_id] is Dictionary


static func _display_name(roster: Dictionary, npc_id: String) -> String:
	if _resident(roster, npc_id):
		var resident: Dictionary = roster.npcs[npc_id]
		var name: String = str(resident.get("display_name", ""))
		if not name.is_empty():
			return name
	return GENERIC_VISITOR


static func _clip(text: String) -> String:
	return text if text.length() <= Memory.MAX_SUMMARY_LENGTH \
		else text.left(Memory.MAX_SUMMARY_LENGTH)


## FNV-1a over UTF-8 bytes, masked to 32 bits. Two domains give each id 64 bits
## of event identity and 64 bits of subject identity, so distinct events or
## residents do not collide in practice while the id stays inside M10-01's
## 64-character owner-id limit.
static func _token(value: String, domain: String) -> String:
	return "%08x%08x" % [
		_hash32([domain, "0", value]), _hash32([domain, "1", value]),
	]


static func _hash32(parts: Array[String]) -> int:
	var digest: int = HASH_OFFSET
	for part: String in parts:
		for byte: int in part.to_utf8_buffer():
			digest = (digest ^ byte) & HASH_MASK
			digest = (digest * HASH_PRIME) & HASH_MASK
		digest = (digest ^ 0xFF) & HASH_MASK
		digest = (digest * HASH_PRIME) & HASH_MASK
	return digest


static func _valid_id(value: Variant) -> bool:
	return OwnerIds.valid(value)


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) >= 0.0 and float(value) <= float(Memory.MAX_SAFE_INTEGER)


static func _error(reason: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "event_id": "", "skipped": "",
		"entries": [], "written": 0, "duplicates": 0,
	}


static func _skipped(event_id: String, reason: String) -> Dictionary:
	return {
		"ok": true, "reason": "", "event_id": event_id, "skipped": reason,
		"entries": [], "written": 0, "duplicates": 0,
	}


static func _sequence_error(reason: String, index: int) -> Dictionary:
	return {
		"ok": false, "reason": reason, "index": index, "results": [],
		"written": 0, "duplicates": 0, "skipped": 0,
	}
