extends RefCounted
## M11-01 minimal land cadastre rules. Pure rules: no RNG, clock, disk, scene,
## network or `FarmState` access.
##
## This slice owns land ownership only. A parcel decides who may build and who
## may cross it; it does not own or move the building on top of it. Buildings
## remain governed by the existing `FarmState.build` / `demolish` rules and are
## deliberately not coupled here (see ADR-023).
##
## A world's territory document is small and self-contained:
##
##   {
##     "world_id": "world-...",
##     "sequence": 0,
##     "parcels": {
##       "parcel_id": {
##         "id": "parcel_id",
##         "rect": {"min_x": 0, "min_z": 0, "max_x": 3, "max_z": 3},
##         "owner": "player id" | "public" | "",
##         "status": "unclaimed" | "claimed" | "public",
##         "claimed_utc": 0.0,
##         "claim_id": "",
##       }
##     },
##     "command_results": {
##       "command_id": {"payload": "[...]", "result": {...}},
##     },
##   }
##
## Rectangles are inclusive integer grid cells. `valid()` rejects overlapping
## rectangles, stale ownership fields, unknown keys, out-of-range numbers and
## cross-world command payloads. The command window is bounded, exactly like
## the rule bank: replay returns the first result while it is present, and the
## parcel's `claim_id` remains a durable guard for claim/transfer when the
## window has evicted the original row.

const OwnerIds = preload("res://farm/owner_id.gd")
# ADR-028 maps build slots to the fixed parcels by ordinal. This is a pure data
# catalog, so the land rules still never depend on FarmState or the farm document.
const Buildings = preload("res://farm/building_catalog.gd")

const PUBLIC_OWNER: String = "public"

const STATUS_UNCLAIMED: String = "unclaimed"
const STATUS_CLAIMED: String = "claimed"
const STATUS_PUBLIC: String = "public"
const STATUSES: Array[String] = [STATUS_UNCLAIMED, STATUS_CLAIMED, STATUS_PUBLIC]

const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_PARCELS: int = 256
const MAX_COMMAND_RESULTS: int = 64
const MAX_COMMAND_ID_LENGTH: int = 128
const MAX_PAYLOAD_LENGTH: int = 512
const MAX_REASON_LENGTH: int = 64
const MAX_WORLD_ID_LENGTH: int = 128
const MAX_PARCEL_ID_LENGTH: int = 64
## Bound for an inclusive grid coordinate. Keeps every rectangle far inside
## the safe integer range and makes a malformed document cheap to reject.
const MAX_COORD: int = 4096
## A land time crosses JSON as decimal text, so a sub-second instant can return
## one unit in the last place away from the double it was written with. The
## parcel row and its command payload must name the same instant, not the same
## bits; anything beyond this bound is a real disagreement.
const LAND_TIME_TOLERANCE: float = 0.001

const STATE_KEYS: Array[String] = ["world_id", "sequence", "parcels", "command_results"]
const PARCEL_KEYS: Array[String] = ["id", "rect", "owner", "status", "claimed_utc", "claim_id"]
const RECT_KEYS: Array[String] = ["min_x", "min_z", "max_x", "max_z"]
const RESULT_KEYS: Array[String] = ["ok", "reason", "parcel_id", "owner", "status", "duplicate"]

const KIND_CLAIM: String = "territory_claim"
const KIND_TRANSFER: String = "territory_transfer"
const KIND_RELEASE: String = "territory_release"


static func initial_state(world_id: String) -> Dictionary:
	return {
		"world_id": world_id,
		"sequence": 0,
		"parcels": {},
		"command_results": {},
	}


## The default cadastre a world gets when it has no territory document yet.
## Six non-overlapping 8x8 parcels in a 3x2 grid: the real map is not connected
## to cadastre coordinates yet, so this layout is a deterministic stand-in that
## gives the authority claimable land. Adjacent inclusive rectangles (7 and 8)
## do not overlap.
static func default_state(world_id: String) -> Dictionary:
	var state: Dictionary = initial_state(world_id)
	var rects: Array = [
		[0, 0, 7, 7], [8, 0, 15, 7], [16, 0, 23, 7],
		[0, 8, 7, 15], [8, 8, 15, 15], [16, 8, 23, 15],
	]
	for index: int in rects.size():
		var rect: Array = rects[index]
		var parcel_id: String = "parcel_%02d" % (index + 1)
		state.parcels[parcel_id] = {
			"id": parcel_id,
			"rect": {
				"min_x": int(rect[0]), "min_z": int(rect[1]),
				"max_x": int(rect[2]), "max_z": int(rect[3]),
			},
			"owner": "",
			"status": STATUS_UNCLAIMED,
			"claimed_utc": 0.0,
			"claim_id": "",
		}
	return state


## Returns the land time recorded for `command_id`, or -1.0 when this document
## has no record of it. A claimed parcel's `claim_id` is durable evidence for a
## claim/transfer even after the bounded command window evicted the row; a
## release only survives while its result row is still present. The authority
## uses this so a retry reuses the original stamp and stays idempotent across a
## restart instead of conflicting on a newer world clock.
static func recorded_time(state: Dictionary, command_id: String) -> float:
	if not _valid_command_id(command_id):
		return -1.0
	var parcels: Variant = state.get("parcels")
	if parcels is Dictionary:
		for parcel_id: Variant in parcels:
			var parcel: Variant = parcels[parcel_id]
			if parcel is Dictionary and str(parcel.get("status", "")) == STATUS_CLAIMED \
					and str(parcel.get("claim_id", "")) == command_id:
				return float(parcel.get("claimed_utc", -1.0))
	var results: Variant = state.get("command_results")
	if not results is Dictionary:
		return -1.0
	var entry: Variant = results.get(command_id)
	if not entry is Dictionary:
		return -1.0
	var parsed: Variant = _parse_payload(str(entry.get("payload", "")))
	if not parsed is Array:
		return -1.0
	var parts: Array = parsed
	if parts.size() < 5:
		return -1.0
	# Claim/release put the time at index 4; transfer appends the receiver first,
	# so its time is at index 5.
	var at_index: int = 5 if str(parts[0]) == KIND_TRANSFER else 4
	if parts.size() <= at_index or not _valid_time(parts[at_index]):
		return -1.0
	return float(parts[at_index])


## Claims an unclaimed parcel for a player. Only the current owner may later
## transfer or release it. A repeated command id replays the first result; a
## different command id against an already claimed parcel is `already_claimed`.
static func claim(state: Dictionary, world_id: String, parcel_id: String, owner: Variant,
		command_id: String, at_utc: float) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", str(parcel_id))
	if not _valid_command_id(command_id):
		return _error("invalid_command", str(parcel_id))
	if not _valid_time(at_utc):
		return _error("invalid_time", str(parcel_id))
	if not _valid_world_id(world_id) or str(state.get("world_id", "")) != world_id:
		return _error("wrong_world", str(parcel_id))
	if not _valid_player(owner):
		return _error("invalid_owner", str(parcel_id))
	var target: String = str(parcel_id)
	if not _valid_parcel_id(target):
		return _error("unknown_parcel", target)
	var payload: String = _claim_payload(world_id, target, str(owner), at_utc)
	var replayed: Dictionary = _replay(state, command_id, payload)
	if not replayed.is_empty():
		return replayed
	var parcels: Dictionary = state.parcels
	if not parcels.has(target):
		return _error("unknown_parcel", target)
	var parcel: Variant = parcels[target]
	if not parcel is Dictionary:
		return _error("invalid_state", target)
	# One command id may only ever describe one land action in this document.
	var used_by: String = _claim_id_parcel(state, command_id)
	if not used_by.is_empty() and used_by != target:
		return _error("command_conflict", target)
	var status: String = str(parcel.get("status", ""))
	if status == STATUS_CLAIMED:
		if str(parcel.get("claim_id", "")) == command_id:
			if str(parcel.get("owner", "")) == str(owner) \
					and float(parcel.get("claimed_utc", 0.0)) == float(at_utc):
				return _success(parcel, true)
			return _error("command_conflict", target)
		return _error("already_claimed", target)
	if status == STATUS_PUBLIC:
		return _error("already_public", target)
	if status != STATUS_UNCLAIMED:
		return _error("invalid_state", target)
	var rect: Variant = parcel.get("rect")
	if not _valid_rect(rect):
		return _error("invalid_state", target)
	# `valid()` rejects overlapping declarations; the command path repeats the
	# check so a malformed document cannot be claimed through.
	if _overlaps_any(parcels, target, rect):
		return _error("overlapping_parcels", target)
	if at_utc < float(parcel.get("claimed_utc", 0.0)):
		return _error("time_regression", target)
	parcel.owner = str(owner)
	parcel.status = STATUS_CLAIMED
	parcel.claimed_utc = float(at_utc)
	parcel.claim_id = command_id
	var result: Dictionary = _success(parcel, false)
	_record_command(state, command_id, payload, result)
	return result


## Transfers a claimed parcel between players. Only the current owner may start
## it and the receiver must be a different legal player. Ground buildings are
## intentionally untouched: this module records land, not what stands on it.
static func transfer(state: Dictionary, parcel_id: String, from: Variant, to: Variant,
		command_id: String, at_utc: float) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", str(parcel_id))
	if not _valid_command_id(command_id):
		return _error("invalid_command", str(parcel_id))
	if not _valid_time(at_utc):
		return _error("invalid_time", str(parcel_id))
	if not _valid_player(from) or not _valid_player(to):
		return _error("invalid_owner", str(parcel_id))
	if str(from) == str(to):
		return _error("same_owner", str(parcel_id))
	var target: String = str(parcel_id)
	if not _valid_parcel_id(target):
		return _error("unknown_parcel", target)
	var payload: String = _transfer_payload(str(state.world_id), target, str(from), str(to), at_utc)
	var replayed: Dictionary = _replay(state, command_id, payload)
	if not replayed.is_empty():
		return replayed
	var parcels: Dictionary = state.parcels
	if not parcels.has(target):
		return _error("unknown_parcel", target)
	var parcel: Variant = parcels[target]
	if not parcel is Dictionary:
		return _error("invalid_state", target)
	var used_by: String = _claim_id_parcel(state, command_id)
	if not used_by.is_empty():
		if used_by != target:
			return _error("command_conflict", target)
		# The transfer's command id was stored on the parcel, so the durable row
		# can still replay after the bounded command window evicted the result.
		if str(parcel.get("owner", "")) == str(to) \
				and float(parcel.get("claimed_utc", 0.0)) == float(at_utc):
			return _success(parcel, true)
		return _error("command_conflict", target)
	if str(parcel.get("status", "")) != STATUS_CLAIMED:
		return _error("not_owned", target)
	if str(parcel.get("owner", "")) != str(from):
		return _error("not_owner", target)
	if at_utc < float(parcel.get("claimed_utc", 0.0)):
		return _error("time_regression", target)
	parcel.owner = str(to)
	parcel.claimed_utc = float(at_utc)
	parcel.claim_id = command_id
	var result: Dictionary = _success(parcel, false)
	_record_command(state, command_id, payload, result)
	return result


## Releases a claimed parcel back to `unclaimed`. Only the owner may do it, and
## a successful release clears the claim fields so the land is free again.
static func release(state: Dictionary, parcel_id: String, actor: Variant,
		command_id: String, at_utc: float) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", str(parcel_id))
	if not _valid_command_id(command_id):
		return _error("invalid_command", str(parcel_id))
	if not _valid_time(at_utc):
		return _error("invalid_time", str(parcel_id))
	if not _valid_player(actor):
		return _error("invalid_owner", str(parcel_id))
	var target: String = str(parcel_id)
	if not _valid_parcel_id(target):
		return _error("unknown_parcel", target)
	var payload: String = _release_payload(str(state.world_id), target, str(actor), at_utc)
	var replayed: Dictionary = _replay(state, command_id, payload)
	if not replayed.is_empty():
		return replayed
	var parcels: Dictionary = state.parcels
	if not parcels.has(target):
		return _error("unknown_parcel", target)
	var parcel: Variant = parcels[target]
	if not parcel is Dictionary:
		return _error("invalid_state", target)
	# A live claim/transfer id may not be reused as a release id in the same
	# document; it already names another land action.
	if not _claim_id_parcel(state, command_id).is_empty():
		return _error("command_conflict", target)
	if str(parcel.get("status", "")) != STATUS_CLAIMED:
		return _error("not_owned", target)
	if str(parcel.get("owner", "")) != str(actor):
		return _error("not_owner", target)
	if at_utc < float(parcel.get("claimed_utc", 0.0)):
		return _error("time_regression", target)
	parcel.owner = ""
	parcel.status = STATUS_UNCLAIMED
	parcel.claimed_utc = 0.0
	parcel.claim_id = ""
	var result: Dictionary = _success(parcel, false)
	_record_command(state, command_id, payload, result)
	return result


## True when `actor` may build on the parcel. A claimed parcel belongs to its
## owner; a public parcel is open to any legal player; an unclaimed parcel
## refuses construction until it is claimed (ADR-023).
static func may_build(state: Dictionary, parcel_id: String, actor: Variant) -> bool:
	var parcel: Variant = _parcel_or_null(state, parcel_id)
	if not parcel is Dictionary or not _valid_player(actor):
		return false
	var status: String = str(parcel.get("status", ""))
	if status == STATUS_CLAIMED:
		return str(parcel.get("owner", "")) == str(actor)
	if status == STATUS_PUBLIC:
		return true
	return false


## Fixed slot→parcel convention (ADR-028 §2): `Buildings.SLOTS[i]` maps to
## `parcel_%02d % (i + 1)`, exactly the order `default_state()` lays out its
## rectangles in. The mapping is a code contract, not a persisted field; an
## unknown slot has no parcel and returns "".
static func slot_parcel_id(slot_id: String) -> String:
	var index: int = Buildings.SLOTS.find(slot_id)
	if index < 0:
		return ""
	return "parcel_%02d" % (index + 1)


## Reverse of `slot_parcel_id()`: the yard slot a parcel is displayed at, or ""
## for a parcel this world's building layout has no slot for.
static func parcel_slot_id(parcel_id: String) -> String:
	for slot_id: String in Buildings.SLOTS:
		if slot_parcel_id(slot_id) == parcel_id:
			return slot_id
	return ""


## Build admission for one slot (ADR-028 §3). This differs from `may_build()` in
## one deliberate way: an unclaimed parcel is allowed and reports `claim=true`,
## so the authority can write the "first build claims the land" claim inside the
## same transaction. Claimed land for someone else is the only ownership refusal;
## a missing parcel, an unusable document and an illegal actor stay distinct.
## The caller gates only new BUILD candidates; replays must not re-gate.
static func build_gate(state: Dictionary, slot_id: String, actor: Variant) -> Dictionary:
	if not valid(state):
		return {"ok": false, "reason": "land_unavailable", "parcel_id": "", "claim": false}
	if not _valid_player(actor):
		return {"ok": false, "reason": "invalid_player", "parcel_id": "", "claim": false}
	var parcel_id: String = slot_parcel_id(str(slot_id))
	if parcel_id.is_empty():
		return {"ok": false, "reason": "slot_unmapped", "parcel_id": "", "claim": false}
	var parcel: Variant = _parcel_or_null(state, parcel_id)
	if not parcel is Dictionary:
		return {"ok": false, "reason": "slot_unmapped", "parcel_id": parcel_id, "claim": false}
	var status: String = str(parcel.get("status", ""))
	if status == STATUS_CLAIMED:
		if str(parcel.get("owner", "")) != str(actor):
			return {"ok": false, "reason": "not_parcel_owner", "parcel_id": parcel_id, "claim": false}
		return {"ok": true, "reason": "", "parcel_id": parcel_id, "claim": false}
	if status == STATUS_PUBLIC:
		return {"ok": true, "reason": "", "parcel_id": parcel_id, "claim": false}
	if status == STATUS_UNCLAIMED:
		return {"ok": true, "reason": "", "parcel_id": parcel_id, "claim": true}
	# `valid()` already restricts status to the three known values.
	return {"ok": false, "reason": "land_unavailable", "parcel_id": parcel_id, "claim": false}


## True when `actor` may cross the parcel. Claimed land is owner-only; public
## ground is open to every legal player; unclaimed ground is open because no
## one owns it yet. This is the default ADR-023 records for the first slice.
static func may_trespass(state: Dictionary, parcel_id: String, actor: Variant) -> bool:
	var parcel: Variant = _parcel_or_null(state, parcel_id)
	if not parcel is Dictionary or not _valid_player(actor):
		return false
	var status: String = str(parcel.get("status", ""))
	if status == STATUS_CLAIMED:
		return str(parcel.get("owner", "")) == str(actor)
	if status == STATUS_PUBLIC or status == STATUS_UNCLAIMED:
		return true
	return false


## Strict document check. Ownership, status and time fields must agree with one
## another, rectangles must be non-overlapping and in range, and every stored
## command payload must belong to this world.
static func valid(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	if value.size() != STATE_KEYS.size():
		return false
	for key: String in STATE_KEYS:
		if not value.has(key):
			return false
	if not _valid_world_id(value.world_id):
		return false
	if not _is_count(value.sequence) or int(value.sequence) >= MAX_SAFE_INTEGER:
		return false
	if not value.parcels is Dictionary or value.parcels.size() > MAX_PARCELS:
		return false
	if not value.command_results is Dictionary \
			or value.command_results.size() > MAX_COMMAND_RESULTS:
		return false
	if not _valid_command_results(value):
		return false
	var ids: Array = []
	for parcel_id: Variant in value.parcels:
		ids.append(str(parcel_id))
	ids.sort()
	var claim_ids: Dictionary = {}
	for parcel_id: String in ids:
		var parcel: Variant = value.parcels[parcel_id]
		if not _valid_parcel(parcel_id, parcel):
			return false
		if str(parcel.status) == STATUS_CLAIMED:
			var claim_id: String = str(parcel.claim_id)
			# Two parcels cannot be established by the same command.
			if claim_ids.has(claim_id):
				return false
			claim_ids[claim_id] = true
			# When the establishing command is still in the window, the parcel
			# row must agree with the command's owner and land time.
			var entry: Variant = value.command_results.get(claim_id)
			if entry is Dictionary:
				var parts: Variant = _parse_payload(str(entry.payload))
				if not parts is Array:
					return false
				var at_index: int = 5 if str(parts[0]) == KIND_TRANSFER else 4
				if absf(float(parcel.claimed_utc) - float(parts[at_index])) > LAND_TIME_TOLERANCE:
					return false
				if str(parcel.owner) != str(entry.result.owner):
					return false
	# Inclusive rectangles may not overlap; touching an edge is an overlap.
	for left: int in range(ids.size()):
		var a: Dictionary = value.parcels[ids[left]]
		for right: int in range(left + 1, ids.size()):
			var b: Dictionary = value.parcels[ids[right]]
			if _rects_overlap(a.rect, b.rect):
				return false
	return true


## Converts JSON numbers back to GDScript integers/booleans. Only reached for a
## structurally valid document; absent keys are left for `valid()` to reject.
static func normalize(state: Dictionary) -> void:
	state.world_id = str(state.get("world_id", ""))
	state.sequence = int(state.get("sequence", 0))
	var parcels: Variant = state.get("parcels")
	if parcels is Dictionary:
		for parcel_id: Variant in parcels:
			var parcel: Variant = parcels[parcel_id]
			if not parcel is Dictionary:
				continue
			parcel.id = str(parcel.get("id", ""))
			parcel.owner = str(parcel.get("owner", ""))
			parcel.status = str(parcel.get("status", ""))
			parcel.claimed_utc = float(parcel.get("claimed_utc", 0.0))
			parcel.claim_id = str(parcel.get("claim_id", ""))
			var rect: Variant = parcel.get("rect")
			if rect is Dictionary:
				for key: String in RECT_KEYS:
					rect[key] = int(rect.get(key, 0))
	var results: Variant = state.get("command_results")
	if results is Dictionary:
		for command_id: Variant in results:
			var entry: Variant = results[command_id]
			if not entry is Dictionary or not entry.get("result") is Dictionary:
				continue
			entry.result.ok = bool(entry.result.get("ok", false))
			entry.result.duplicate = bool(entry.result.get("duplicate", false))


static func _valid_command_results(state: Dictionary) -> bool:
	var results: Dictionary = state.command_results
	for command_id: Variant in results:
		if not _valid_command_id(command_id):
			return false
		var entry: Variant = results[command_id]
		if not entry is Dictionary or entry.size() != 2 \
				or not entry.has("payload") or not entry.has("result"):
			return false
		if not entry.payload is String:
			return false
		var payload: String = entry.payload
		if payload.length() > MAX_PAYLOAD_LENGTH:
			return false
		var parsed: Variant = _parse_payload(payload)
		if not parsed is Array:
			return false
		var parts: Array = parsed
		if parts.size() < 4:
			return false
		var kind: String = str(parts[0])
		var expected: int = 6 if kind == KIND_TRANSFER else 5
		if parts.size() != expected:
			return false
		if not _valid_world_id(parts[1]) or str(parts[1]) != str(state.world_id):
			return false
		if not _valid_parcel_id(parts[2]):
			return false
		if not _valid_result(entry.result):
			return false
		var result: Dictionary = entry.result
		if str(result.parcel_id) != str(parts[2]):
			return false
		if kind == KIND_CLAIM:
			if not _valid_player(parts[3]) or not _valid_time(parts[4]):
				return false
			if str(result.owner) != str(parts[3]) or str(result.status) != STATUS_CLAIMED:
				return false
		elif kind == KIND_TRANSFER:
			if not _valid_player(parts[3]) or not _valid_player(parts[4]) \
					or not _valid_time(parts[5]):
				return false
			if str(result.owner) != str(parts[4]) or str(result.status) != STATUS_CLAIMED:
				return false
		elif kind == KIND_RELEASE:
			if not _valid_player(parts[3]) or not _valid_time(parts[4]):
				return false
			if not str(result.owner).is_empty() or str(result.status) != STATUS_UNCLAIMED:
				return false
		else:
			return false
	return true


static func _valid_result(value: Variant) -> bool:
	if not value is Dictionary or value.size() != RESULT_KEYS.size():
		return false
	for key: String in RESULT_KEYS:
		if not value.has(key):
			return false
	if not value.ok is bool or not bool(value.ok):
		return false
	if not value.reason is String or not str(value.reason).is_empty() \
			or str(value.reason).length() > MAX_REASON_LENGTH:
		return false
	if not _valid_parcel_id(value.parcel_id):
		return false
	if not value.duplicate is bool or bool(value.duplicate):
		return false
	if not value.status is String or str(value.status) not in STATUSES:
		return false
	var owner: String = str(value.owner)
	var status: String = str(value.status)
	if status == STATUS_CLAIMED:
		return _valid_player(owner)
	if status == STATUS_PUBLIC:
		return owner == PUBLIC_OWNER
	return owner.is_empty()


static func _valid_parcel(parcel_id: String, value: Variant) -> bool:
	if not _valid_parcel_id(parcel_id):
		return false
	if not value is Dictionary or value.size() != PARCEL_KEYS.size():
		return false
	for key: String in PARCEL_KEYS:
		if not value.has(key):
			return false
	if not value.id is String or str(value.id) != parcel_id:
		return false
	if not _valid_rect(value.rect):
		return false
	if not value.owner is String or not value.status is String:
		return false
	if not _valid_time(value.claimed_utc) or not value.claim_id is String:
		return false
	var owner: String = str(value.owner)
	var status: String = str(value.status)
	var claim_id: String = str(value.claim_id)
	if status == STATUS_CLAIMED:
		return _valid_player(owner) and _valid_command_id(claim_id)
	if status == STATUS_PUBLIC:
		return owner == PUBLIC_OWNER and float(value.claimed_utc) == 0.0 and claim_id.is_empty()
	if status == STATUS_UNCLAIMED:
		return owner.is_empty() and float(value.claimed_utc) == 0.0 and claim_id.is_empty()
	return false


static func _valid_rect(value: Variant) -> bool:
	if not value is Dictionary or value.size() != RECT_KEYS.size():
		return false
	for key: String in RECT_KEYS:
		if not value.has(key):
			return false
		if not _is_count(value[key]) or int(value[key]) < 0 or int(value[key]) > MAX_COORD:
			return false
	return int(value.min_x) <= int(value.max_x) and int(value.min_z) <= int(value.max_z)


static func _rects_overlap(a: Dictionary, b: Dictionary) -> bool:
	return int(a.min_x) <= int(b.max_x) and int(b.min_x) <= int(a.max_x) \
		and int(a.min_z) <= int(b.max_z) and int(b.min_z) <= int(a.max_z)


static func _overlaps_any(parcels: Dictionary, parcel_id: String, rect: Dictionary) -> bool:
	for other_id: Variant in parcels:
		var other_key: String = str(other_id)
		if other_key == parcel_id:
			continue
		var other: Variant = parcels[other_id]
		if other is Dictionary and _valid_rect(other.get("rect")) \
				and _rects_overlap(rect, other.rect):
			return true
	return false


static func _claim_id_parcel(state: Dictionary, command_id: String) -> String:
	var parcels: Variant = state.get("parcels")
	if not parcels is Dictionary:
		return ""
	for parcel_id: Variant in parcels:
		var parcel: Variant = parcels[parcel_id]
		if parcel is Dictionary and str(parcel.get("status", "")) == STATUS_CLAIMED \
				and str(parcel.get("claim_id", "")) == command_id:
			return str(parcel_id)
	return ""


static func _parcel_or_null(state: Dictionary, parcel_id: String) -> Variant:
	var parcels: Variant = state.get("parcels")
	if not parcels is Dictionary or not _valid_parcel_id(parcel_id):
		return null
	return parcels.get(parcel_id)


static func _state_ready(state: Dictionary) -> bool:
	return state.get("parcels") is Dictionary \
		and state.get("command_results") is Dictionary \
		and _is_count(state.get("sequence", -1))


static func _success(parcel: Dictionary, duplicate: bool) -> Dictionary:
	return _result(true, "", str(parcel.get("id", "")), str(parcel.get("owner", "")),
		str(parcel.get("status", "")), duplicate)


static func _error(reason: String, parcel_id: String) -> Dictionary:
	return _result(false, reason, parcel_id, "", "", false)


static func _result(ok: bool, reason: String, parcel_id: String, owner: String,
		status: String, duplicate: bool) -> Dictionary:
	return {
		"ok": ok, "reason": reason, "parcel_id": parcel_id, "owner": owner,
		"status": status, "duplicate": duplicate,
	}


static func _replay(state: Dictionary, command_id: String, payload: String) -> Dictionary:
	var results: Variant = state.get("command_results")
	if not results is Dictionary or not results.has(command_id):
		return {}
	var entry: Variant = results[command_id]
	if not entry is Dictionary or not entry.get("result") is Dictionary:
		return _error("invalid_state", "")
	if str(entry.get("payload", "")) != payload:
		return _error("command_conflict", str(entry.result.get("parcel_id", "")))
	return _copy_result(entry.result, true)


static func _copy_result(value: Dictionary, duplicate: bool) -> Dictionary:
	return _result(bool(value.get("ok", false)), str(value.get("reason", "")),
		str(value.get("parcel_id", "")), str(value.get("owner", "")),
		str(value.get("status", "")), duplicate)


static func _record_command(state: Dictionary, command_id: String, payload: String,
		result: Dictionary) -> void:
	var results: Variant = state.get("command_results")
	if not results is Dictionary:
		return
	state.sequence = int(state.get("sequence", 0)) + 1
	results[command_id] = {"payload": payload, "result": _copy_result(result, false)}
	while results.size() > MAX_COMMAND_RESULTS:
		results.erase(results.keys()[0])


static func _claim_payload(world_id: String, parcel_id: String, owner: String,
		at_utc: float) -> String:
	return JSON.stringify([KIND_CLAIM, world_id, parcel_id, owner, float(at_utc)])


static func _transfer_payload(world_id: String, parcel_id: String, from: String,
		to: String, at_utc: float) -> String:
	return JSON.stringify([KIND_TRANSFER, world_id, parcel_id, from, to, float(at_utc)])


static func _release_payload(world_id: String, parcel_id: String, actor: String,
		at_utc: float) -> String:
	return JSON.stringify([KIND_RELEASE, world_id, parcel_id, actor, float(at_utc)])


static func _parse_payload(text: String) -> Variant:
	# JSON.parse_string logs an engine error for malformed input; the document
	# validator treats that as a normal rejection, so parse quietly instead.
	var json: JSON = JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


static func _valid_player(value: Variant) -> bool:
	return value is String and str(value) != PUBLIC_OWNER and OwnerIds.valid(value)


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
		if not letter and not digit and code != 95 and code != 45 and code != 46 and code != 58:
			return false
	return true


static func _valid_parcel_id(value: Variant) -> bool:
	return value is String and str(value).length() <= MAX_PARCEL_ID_LENGTH \
		and OwnerIds.valid(value)


static func _valid_command_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_COMMAND_ID_LENGTH


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) >= 0.0 and float(value) <= float(MAX_SAFE_INTEGER)


static func _is_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)
