extends RefCounted
## M10-01 bounded episodic memory for residents. Pure rules: no model, clock,
## disk, scene or network access.
##
## A memory document is rule state, not model state:
##
##   {
##     "schema": 1,
##     "world_id": "world-a",
##     "npcs": {
##       "<npc_id>": {
##         "dropped": 0,
##         "entries": {"<memory_id>": <entry>}
##       }
##     }
##   }
##
## An entry records one event that actually happened:
##
##   id, kind, participants, summary, salience, at_utc, world_id, state_version
##
## Writing is explicit: a rule-event caller submits `remember()`; the model may
## read `retrieve()` output as visible context but can never write memory
## directly. Model suggestions must first become accepted world events, and only
## then may their caller append a memory row.
##
## Capacity is 64 entries per resident. When full, the entry with the lowest
## salience is evicted, oldest first on a tie, so high-salience recent events
## survive. `dropped` counts evictions and never decreases.
##
## Retrieval is deterministic. Ordering uses an effective salience that loses
## one point per full day of age (floor 1); decay only affects the order and
## never rewrites stored salience or any other field.

const OwnerIds = preload("res://farm/owner_id.gd")

const SCHEMA: int = 1
const MAX_ENTRIES: int = 64
const MAX_PARTICIPANTS: int = 4
const MAX_SUMMARY_LENGTH: int = 200
const MIN_SALIENCE: int = 1
const MAX_SALIENCE: int = 100
const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_WORLD_ID_LENGTH: int = 255
const SECONDS_PER_DAY: float = 86400.0
const DEFAULT_LIMIT: int = 8

const KIND_TRADE: String = "trade"
const KIND_GIFT: String = "gift"
const KIND_CONFLICT: String = "conflict"
const KIND_WEATHER: String = "weather"
const KIND_DIALOGUE: String = "dialogue"
const KIND_OBSERVATION: String = "observation"

const KINDS: Array[String] = [
	KIND_TRADE, KIND_GIFT, KIND_CONFLICT, KIND_WEATHER, KIND_DIALOGUE,
	KIND_OBSERVATION,
]

const DOCUMENT_KEYS: Array[String] = ["schema", "world_id", "npcs"]
const NPC_KEYS: Array[String] = ["dropped", "entries"]
const RECORD_KEYS: Array[String] = [
	"id", "kind", "participants", "summary", "salience", "at_utc", "world_id",
	"state_version",
]
const OPTION_KEYS: Array[String] = ["now_utc", "limit", "participant", "kind"]


## Empty document for one world.
static func create(world_id: Variant) -> Dictionary:
	if not _valid_world_id(world_id):
		return _document_error("invalid_world_id")
	return {
		"ok": true, "reason": "",
		"document": {"schema": SCHEMA, "world_id": str(world_id), "npcs": {}},
	}


## Appends one accepted rule event. The event must name an existing world; a
## future `at_utc`, duplicate id, cross-world row or malformed field is refused
## without touching the document. Two different ids with identical content are
## two events: deduplication belongs to the caller.
static func remember(document: Variant, npc_id: Variant, event: Variant,
		now_utc: Variant) -> Dictionary:
	if not _valid_id(npc_id):
		return _remember_error("invalid_npc_id")
	if not _valid_time(now_utc):
		return _remember_error("invalid_time")
	if not document is Dictionary:
		return _remember_error("invalid_document")
	var stored: Dictionary = document
	var checked: Dictionary = validate_document(stored, now_utc)
	if not checked.ok:
		return _remember_error(str(checked.reason))
	if not event is Dictionary:
		return _remember_error("invalid_entry")
	var normalized: Dictionary = _normalize_entry(event, str(stored.world_id), now_utc, false)
	if not normalized.ok:
		return _remember_error(str(normalized.reason))
	var entry: Dictionary = normalized.entry
	var npcs: Dictionary = stored.npcs
	# Memory ids are unique across the whole document, not only inside one
	# resident. Otherwise `remember()` could build a document that restore later
	# rejects as a duplicate.
	if _document_has_id(npcs, str(entry.id)):
		var owner_row: Dictionary = npcs.get(str(npc_id), {})
		return {
			"ok": false, "reason": "duplicate", "duplicate": true,
			"size": owner_row.get("entries", {}).size(),
			"dropped": int(owner_row.get("dropped", 0)), "evicted": [],
		}
	var npc_key: String = str(npc_id)
	if not npcs.has(npc_key):
		npcs[npc_key] = {"dropped": 0, "entries": {}}
	var row: Dictionary = npcs[npc_key]
	var entries: Dictionary = row.entries
	entries[entry.id] = entry
	var evicted: Array[String] = []
	while entries.size() > MAX_ENTRIES:
		var victim: String = _eviction_candidate(entries)
		entries.erase(victim)
		row.dropped = int(row.dropped) + 1
		evicted.append(victim)
	return {
		"ok": true, "reason": "", "duplicate": false, "size": entries.size(),
		"dropped": int(row.dropped), "evicted": evicted,
	}


## Deterministic retrieval. `options` requires `now_utc`; optional `limit`
## (1..64, default 8), `participant` and `kind` filters. Each returned row is a
## copy. Decay affects only the effective ordering score.
static func retrieve(document: Variant, npc_id: Variant,
		options: Variant = {}) -> Dictionary:
	if not _valid_id(npc_id):
		return _retrieve_error("invalid_npc_id")
	if not options is Dictionary:
		return _retrieve_error("invalid_options")
	var settings: Dictionary = options
	for key: Variant in settings.keys():
		if not (key is String) or not str(key) in OPTION_KEYS:
			return _retrieve_error("unknown_option")
	if not settings.has("now_utc") or not _valid_time(settings.now_utc):
		return _retrieve_error("invalid_time")
	var now_utc: float = float(settings.now_utc)
	var limit: int = DEFAULT_LIMIT
	if settings.has("limit"):
		if not _is_count(settings.limit) or int(settings.limit) < 1 \
				or int(settings.limit) > MAX_ENTRIES:
			return _retrieve_error("invalid_limit")
		limit = int(settings.limit)
	var participant: String = ""
	if settings.has("participant"):
		if not _valid_id(settings.participant):
			return _retrieve_error("invalid_participant")
		participant = str(settings.participant)
	var kind: String = ""
	if settings.has("kind"):
		if not settings.kind is String or not str(settings.kind) in KINDS:
			return _retrieve_error("invalid_kind")
		kind = str(settings.kind)
	if not document is Dictionary:
		return _retrieve_error("invalid_document")
	var stored: Dictionary = document
	var checked: Dictionary = validate_document(stored, now_utc)
	if not checked.ok:
		return _retrieve_error(str(checked.reason))
	var npcs: Dictionary = stored.npcs
	var row: Dictionary = npcs.get(str(npc_id), {})
	var entries: Dictionary = row.get("entries", {})
	var matched: Array = []
	for entry_id: Variant in entries:
		var entry: Dictionary = entries[entry_id]
		if not participant.is_empty() and not (participant in entry.participants):
			continue
		if not kind.is_empty() and str(entry.kind) != kind:
			continue
		matched.append(entry)
	var total: int = matched.size()
	matched.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _entry_before(a, b, now_utc)
	)
	if total > limit:
		matched = matched.slice(0, limit)
	var result: Array = []
	for entry: Dictionary in matched:
		result.append(entry.duplicate(true))
	return {"ok": true, "reason": "", "entries": result, "total": total}


## Effective ordering score: base salience minus one per full day of age, never
## below 1. This is retrieval-only; stored salience is untouched.
static func effective_salience(entry: Variant, now_utc: Variant) -> int:
	if not entry is Dictionary or not _valid_time(now_utc):
		return 0
	var row: Dictionary = entry
	if not _is_count(row.get("salience")) or not _valid_time(row.get("at_utc")):
		return 0
	var age: float = maxf(0.0, float(now_utc) - float(row.at_utc))
	var days: int = int(floorf(age / SECONDS_PER_DAY))
	return maxi(MIN_SALIENCE, int(row.salience) - days)


## Strict validation of a normalized document. Unknown keys, missing keys,
## wrong types, out-of-range values, duplicate ids, cross-world entries, future
## timestamps and negative counters are all refused.
static func validate_document(document: Variant, now_utc: Variant) -> Dictionary:
	if not _valid_time(now_utc):
		return _error("invalid_time")
	if not document is Dictionary:
		return _error("invalid_document")
	var stored: Dictionary = document
	for key: Variant in stored.keys():
		if not (key is String) or not str(key) in DOCUMENT_KEYS:
			return _error("unknown_key")
	for key: String in DOCUMENT_KEYS:
		if not stored.has(key):
			return _error("invalid_document")
	if not _is_count(stored.schema) or int(stored.schema) != SCHEMA:
		return _error("invalid_schema")
	if not _valid_world_id(stored.world_id):
		return _error("invalid_world_id")
	if not stored.npcs is Dictionary:
		return _error("invalid_npcs")
	var seen: Dictionary = {}
	var npcs: Dictionary = stored.npcs
	for npc_key: Variant in npcs:
		if not _valid_id(npc_key):
			return _error("invalid_npc_id")
		var row: Variant = npcs[npc_key]
		if not row is Dictionary:
			return _error("invalid_npc")
		var record: Dictionary = row
		if record.size() != NPC_KEYS.size():
			return _error("invalid_npc")
		for key: Variant in record.keys():
			if not (key is String) or not str(key) in NPC_KEYS:
				return _error("unknown_key")
		if not _is_count(record.dropped):
			return _error("invalid_dropped")
		if not record.entries is Dictionary:
			return _error("invalid_entries")
		var entries: Dictionary = record.entries
		if entries.size() > MAX_ENTRIES:
			return _error("too_many_entries")
		for entry_key: Variant in entries:
			if not _valid_id(entry_key):
				return _error("invalid_entry_id")
			var normalized: Dictionary = _normalize_entry(
				entries[entry_key], str(stored.world_id), now_utc, false)
			if not normalized.ok:
				return _error(str(normalized.reason))
			var entry: Dictionary = normalized.entry
			if str(entry.id) != str(entry_key):
				return _error("invalid_entry")
			if seen.has(entry.id):
				return _error("duplicate_id")
			seen[entry.id] = true
	return {"ok": true, "reason": ""}


static func valid_document(document: Variant, now_utc: Variant) -> bool:
	return bool(validate_document(document, now_utc).ok)


## Restores a document from JSON-like data. Missing `schema`, `npcs`,
## `npcs[*].dropped`, `npcs[*].entries`, and entry `state_version`/`world_id`/
## `participants` are read with explicit defaults. Every other field is
## required, and unknown keys are refused at every level.
static func from_document(raw: Variant, now_utc: Variant) -> Dictionary:
	if not _valid_time(now_utc):
		return _document_error("invalid_time")
	var read: Dictionary = _read_document(raw, float(now_utc))
	if not read.ok:
		return _document_error(str(read.reason))
	return {"ok": true, "reason": "", "document": read.document}


static func to_json(document: Variant, now_utc: Variant) -> Dictionary:
	var checked: Dictionary = validate_document(document, now_utc)
	if not checked.ok:
		return _document_error(str(checked.reason))
	return {
		"ok": true, "reason": "", "json": JSON.stringify(document),
	}


static func from_json(text: Variant, now_utc: Variant) -> Dictionary:
	if not text is String or str(text).is_empty():
		return _document_error("invalid_json")
	var parsed: Variant = JSON.parse_string(str(text))
	if parsed == null:
		return _document_error("invalid_json")
	return from_document(parsed, now_utc)


## Memory ids are document-wide unique.
static func _document_has_id(npcs: Dictionary, memory_id: String) -> bool:
	for npc_key: Variant in npcs:
		var row: Variant = npcs[npc_key]
		if row is Dictionary:
			var entries: Variant = row.get("entries", {})
			if entries is Dictionary and entries.has(memory_id):
				return true
	return false


## Lowest salience first, then oldest `at_utc`, then id ascending. Deterministic
## on every platform because ids break the final tie.
static func _eviction_candidate(entries: Dictionary) -> String:
	var candidate: String = ""
	for entry_id: Variant in entries:
		if candidate.is_empty():
			candidate = str(entry_id)
			continue
		var row: Dictionary = entries[str(entry_id)]
		var current: Dictionary = entries[candidate]
		if int(row.salience) < int(current.salience):
			candidate = str(entry_id)
		elif int(row.salience) == int(current.salience):
			if float(row.at_utc) < float(current.at_utc):
				candidate = str(entry_id)
			elif float(row.at_utc) == float(current.at_utc) \
					and str(entry_id) < candidate:
				candidate = str(entry_id)
	return candidate


static func _entry_before(a: Dictionary, b: Dictionary, now_utc: float) -> bool:
	var score_a: int = effective_salience(a, now_utc)
	var score_b: int = effective_salience(b, now_utc)
	if score_a != score_b:
		return score_a > score_b
	var time_a: float = float(a.at_utc)
	var time_b: float = float(b.at_utc)
	if time_a != time_b:
		return time_a > time_b
	return str(a.id) < str(b.id)


static func _read_document(raw: Variant, now_utc: float) -> Dictionary:
	if not raw is Dictionary:
		return _document_error("invalid_document")
	var source: Dictionary = raw
	for key: Variant in source.keys():
		if not (key is String) or not str(key) in DOCUMENT_KEYS:
			return _document_error("unknown_key")
	if not source.has("world_id") or not _valid_world_id(source.world_id):
		return _document_error("invalid_world_id")
	if source.has("schema") and (not _is_count(source.schema) or int(source.schema) != SCHEMA):
		return _document_error("invalid_schema")
	var npcs_raw: Variant = source.get("npcs", {})
	if not npcs_raw is Dictionary:
		return _document_error("invalid_npcs")
	var npcs: Dictionary = {}
	var seen: Dictionary = {}
	var raw_npcs: Dictionary = npcs_raw
	for npc_key: Variant in raw_npcs:
		if not _valid_id(npc_key):
			return _document_error("invalid_npc_id")
		var row_raw: Variant = raw_npcs[npc_key]
		if not row_raw is Dictionary:
			return _document_error("invalid_npc")
		var row: Dictionary = row_raw
		for key: Variant in row.keys():
			if not (key is String) or not str(key) in NPC_KEYS:
				return _document_error("unknown_key")
		var dropped: int = 0
		if row.has("dropped"):
			if not _is_count(row.dropped):
				return _document_error("invalid_dropped")
			dropped = int(row.dropped)
		var entries_raw: Variant = row.get("entries", {})
		if not entries_raw is Dictionary:
			return _document_error("invalid_entries")
		var raw_entries: Dictionary = entries_raw
		if raw_entries.size() > MAX_ENTRIES:
			return _document_error("too_many_entries")
		var entries: Dictionary = {}
		for entry_key: Variant in raw_entries:
			var normalized: Dictionary = _normalize_entry(
				raw_entries[entry_key], str(source.world_id), now_utc, true)
			if not normalized.ok:
				return _document_error(str(normalized.reason))
			var entry: Dictionary = normalized.entry
			if str(entry.id) != str(entry_key):
				return _document_error("invalid_entry")
			if seen.has(entry.id):
				return _document_error("duplicate_id")
			seen[entry.id] = true
			entries[entry.id] = entry
		npcs[str(npc_key)] = {"dropped": dropped, "entries": entries}
	var document: Dictionary = {
		"schema": SCHEMA, "world_id": str(source.world_id), "npcs": npcs,
	}
	var checked: Dictionary = validate_document(document, now_utc)
	if not checked.ok:
		return _document_error(str(checked.reason))
	return {"ok": true, "reason": "", "document": document}


## `allow_defaults` is true only for restore: missing `world_id` adopts the
## document world, `participants` becomes empty and `state_version` becomes 0.
## Writes require the complete record.
static func _normalize_entry(raw: Variant, world_id: String, now_utc: float,
		allow_defaults: bool) -> Dictionary:
	if not raw is Dictionary:
		return _entry_error("invalid_entry")
	var source: Dictionary = raw
	var required: Array[String] = ["id", "kind", "summary", "salience", "at_utc"]
	if not allow_defaults:
		required.append_array(["participants", "world_id", "state_version"])
	for key: String in required:
		if not source.has(key):
			return _entry_error("invalid_entry")
	for key: Variant in source.keys():
		if not (key is String) or not str(key) in RECORD_KEYS:
			return _entry_error("unknown_key")
	if not _valid_id(source.id):
		return _entry_error("invalid_entry_id")
	if not source.kind is String or not str(source.kind) in KINDS:
		return _entry_error("invalid_kind")
	var participants: Array = []
	if source.has("participants"):
		if not source.participants is Array:
			return _entry_error("invalid_participants")
		var raw_participants: Array = source.participants
		if raw_participants.size() > MAX_PARTICIPANTS:
			return _entry_error("invalid_participants")
		var seen: Dictionary = {}
		for participant: Variant in raw_participants:
			if not _valid_id(participant):
				return _entry_error("invalid_participants")
			if seen.has(str(participant)):
				return _entry_error("invalid_participants")
			seen[str(participant)] = true
			participants.append(str(participant))
	if not source.summary is String:
		return _entry_error("invalid_summary")
	var summary: String = str(source.summary)
	if summary.is_empty() or summary.length() > MAX_SUMMARY_LENGTH:
		return _entry_error("invalid_summary")
	if not _is_count(source.salience) or int(source.salience) < MIN_SALIENCE \
			or int(source.salience) > MAX_SALIENCE:
		return _entry_error("invalid_salience")
	if not _valid_time(source.at_utc):
		return _entry_error("invalid_time")
	if float(source.at_utc) > now_utc:
		return _entry_error("future_time")
	var entry_world: String = world_id
	if source.has("world_id"):
		if not _valid_world_id(source.world_id):
			return _entry_error("invalid_world_id")
		entry_world = str(source.world_id)
	if entry_world != world_id:
		return _entry_error("cross_world")
	var state_version: int = 0
	if source.has("state_version"):
		if not _is_count(source.state_version):
			return _entry_error("invalid_state_version")
		state_version = int(source.state_version)
	return {
		"ok": true, "reason": "",
		"entry": {
			"id": str(source.id), "kind": str(source.kind),
			"participants": participants, "summary": summary,
			"salience": int(source.salience), "at_utc": float(source.at_utc),
			"world_id": entry_world, "state_version": state_version,
		},
	}


static func _valid_id(value: Variant) -> bool:
	return OwnerIds.valid(value)


static func _valid_world_id(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_WORLD_ID_LENGTH:
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		var letter: bool = (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var digit: bool = code >= 48 and code <= 57
		if not letter and not digit and code != 95 and code != 45 and code != 46 \
				and code != 58:
			return false
	return true


static func _is_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) >= 0.0 and float(value) <= float(MAX_SAFE_INTEGER)


static func _error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


static func _document_error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "document": {}}


static func _entry_error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "entry": {}}


static func _remember_error(reason: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "duplicate": false, "size": 0,
		"dropped": 0, "evicted": [],
	}


static func _retrieve_error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "entries": [], "total": 0}
