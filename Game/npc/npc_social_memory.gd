extends RefCounted
## M10-02/M10-04 cross-cut: turn one committed social action or invitation
## decision into a resident memory row. Pure rules: no model, RNG, clock, disk,
## scene or network access; the caller injects `now_utc` and the target
## resident.
##
## Only M10-01's public `NpcMemory.remember()` writes rows, so id uniqueness,
## capacity and eviction stay the single authority. This adapter never mutates
## its inputs: it validates first, works on a deep copy of the memory document
## and returns that copy as `memory`.
##
## Input result (exactly one of the two shapes):
##
##   {ok: bool, act: {id, kind, from, to, expires_utc}}
##   {ok: bool, invitation: {id, from, to, kind, status, decided_utc?}}
##
## `invitation.decided_utc` is required for every decided status and omitted
## for `pending`, matching `npc_invitation.gd`'s seven-key pending row.
##
## Context (strict; unknown keys refused):
##
##   {now_utc: float, world_id: String, resident_id: String, names?: {id: name}}
##
## `names` is an optional read-only display-name projection. It only labels a
## summary; an absent name falls back to the id, and no narrative text is ever
## accepted as a fact.
##
## Facts written (and only these, only for `resident_id`):
##
##   * a social action the resident started (`act.from == resident_id`);
##   * an invitation the resident accepted (`status == accepted`, resident `to`);
##   * an invitation the resident was declined on (`status == declined`,
##     resident `from`);
##   * an invitation withdrawn from the resident (`status == withdrawn`,
##     resident `to`).
##
## Everything else is skipped without a row: failed results, pending or expired
## invitations, and the other party's view. A social `to` is the counterparty
## only, so "someone greeted me" is not written by this slice.
##
## Memory shape: M10-01's record is eight fixed fields (`id`, `kind`,
## `participants`, `summary`, `salience`, `at_utc`, `world_id`, `state_version`).
## It does not have `type`/`importance`; the rule-facing `kind` and `salience`
## are used instead. `salience` is the fixed importance mapping below.
##
## Memory ids are a deterministic FNV-1a hash of (source, event id, resident
## id), so replaying the same act/invitation id for the same resident is
## recognised as `duplicate` and appends nothing. Capacity stays at M10-01's
## 64 rows per resident with its lowest-salience/oldest eviction.

const Memory = preload("res://npc/npc_memory.gd")
const Social = preload("res://npc/npc_social.gd")
const Invitation = preload("res://npc/npc_invitation.gd")
const OwnerIds = preload("res://farm/owner_id.gd")

const SOURCE_SOCIAL: String = "social"
const SOURCE_INVITATION: String = "invitation"
const SOURCES: Array[String] = [SOURCE_SOCIAL, SOURCE_INVITATION]

## Fixed importance per social action kind.
const SALIENCE_GREET: int = 20
const SALIENCE_GIFT: int = 45
const SALIENCE_INVITE: int = 30
const SALIENCE_APOLOGIZE: int = 50

## Fixed importance per invitation outcome. A rejection matters most to the
## initiator; being withdrawn from is a mild personal event.
const SALIENCE_ACCEPTED: int = 40
const SALIENCE_DECLINED: int = 65
const SALIENCE_WITHDRAWN: int = 35

const CONTEXT_KEYS: Array[String] = ["now_utc", "world_id", "resident_id", "names"]
const RESULT_KEYS: Array[String] = ["ok", "act", "invitation"]
const ACT_KEYS: Array[String] = ["id", "kind", "from", "to", "expires_utc"]
const INVITATION_KEYS: Array[String] = [
	"id", "from", "to", "kind", "status", "decided_utc",
]
const INVITATION_REQUIRED_KEYS: Array[String] = ["id", "from", "to", "kind", "status"]

const MAX_EVENT_ID_LENGTH: int = 128
const HASH_OFFSET: int = 2166136261
const HASH_PRIME: int = 16777619
const HASH_MASK: int = 0xFFFFFFFF


## Applies one result to the target resident's memory. Returns a candidate
## document; the input document and result are never modified.
##
## Success:  {ok: true, reason: "", memory, memory_id, duplicate: false,
##            skipped: "", written: true}
## Duplicate:{ok: true, reason: "duplicate", memory, memory_id, duplicate: true,
##            skipped: "", written: false}
## Skipped:  {ok: true, reason: "", memory, memory_id: "", duplicate: false,
##            skipped: <pending|expired|not_committed|counterparty_only|
##                      not_participant|not_subject>, written: false}
## Failure:  {ok: false, reason, memory_id: "", duplicate: false, skipped: "",
##            written: false} and no `memory` key.
static func apply(document: Variant, result: Variant, context: Variant) -> Dictionary:
	var checked_context: Dictionary = _check_context(context)
	if not checked_context.ok:
		return _fail(str(checked_context.reason))
	var settings: Dictionary = checked_context.context
	if not document is Dictionary:
		return _fail("invalid_memory")
	var stored: Dictionary = document
	var checked_document: Dictionary = Memory.validate_document(stored, settings.now_utc)
	if not checked_document.ok:
		return _fail("invalid_memory", str(checked_document.reason))
	if str(stored.world_id) != str(settings.world_id):
		return _fail("world_mismatch")
	var checked_result: Dictionary = _check_result(result)
	if not checked_result.ok:
		return _fail(str(checked_result.reason))
	var event: Dictionary = checked_result.result
	if not bool(event.ok):
		return _skipped(stored.duplicate(true), "not_committed")

	var fact: Dictionary = {}
	if str(event.source) == SOURCE_SOCIAL:
		var checked_act: Dictionary = _check_act(event.body, settings.now_utc)
		if not checked_act.ok:
			return _fail(str(checked_act.reason))
		fact = _social_fact(checked_act.act, settings)
	else:
		var checked_invitation: Dictionary = _check_invitation(
			event.body, settings.now_utc)
		if not checked_invitation.ok:
			return _fail(str(checked_invitation.reason))
		fact = _invitation_fact(checked_invitation.invitation, settings)
	if not bool(fact.ok):
		return _skipped(stored.duplicate(true), str(fact.skipped))

	var candidate: Dictionary = stored.duplicate(true)
	var memory_id_value: String = memory_id(
		str(event.source), str(fact.event_id), str(settings.resident_id))
	var written: Dictionary = Memory.remember(candidate, str(settings.resident_id), {
		"id": memory_id_value,
		"kind": str(fact.kind),
		"participants": fact.participants,
		"summary": _clip(str(fact.summary)),
		"salience": int(fact.salience),
		"at_utc": float(fact.at_utc),
		"world_id": str(settings.world_id),
		"state_version": 0,
	}, settings.now_utc)
	if not written.ok:
		if str(written.reason) == "duplicate":
			return _duplicate(candidate, memory_id_value)
		return _fail("invalid_memory", str(written.reason))
	return _written(candidate, memory_id_value)


## Deterministic memory id for one (source, event id, resident) triple. The
## source domain keeps a social act and an invitation with the same id apart.
static func memory_id(source: String, event_id: String, npc_id: String) -> String:
	return "sm_" + _token([source, event_id, npc_id])


static func _social_fact(act: Dictionary, settings: Dictionary) -> Dictionary:
	var resident: String = str(settings.resident_id)
	var from_id: String = str(act.from)
	var to_id: String = str(act.to)
	if resident == from_id:
		var kind: String = str(act.kind)
		return {
			"ok": true, "skipped": "", "event_id": str(act.id),
			"kind": _social_memory_kind(kind),
			"salience": _social_salience(kind),
			"summary": _social_summary(kind, _display_name(settings, to_id)),
			"participants": _people([from_id, to_id]),
			"at_utc": float(settings.now_utc),
		}
	if resident == to_id:
		return {"ok": false, "skipped": "counterparty_only"}
	return {"ok": false, "skipped": "not_participant"}


static func _invitation_fact(invitation: Dictionary, settings: Dictionary) -> Dictionary:
	var resident: String = str(settings.resident_id)
	var from_id: String = str(invitation.from)
	var to_id: String = str(invitation.to)
	var status: String = str(invitation.status)
	var event_id: String = str(invitation.id)
	var from_name: String = _display_name(settings, from_id)
	var to_name: String = _display_name(settings, to_id)
	var kind_label: String = _invitation_label(str(invitation.kind))
	var participants: Array = _people([from_id, to_id])
	var decided_utc: float = float(invitation.decided_utc)

	if status == Invitation.STATUS_ACCEPTED:
		if resident == to_id:
			return {
				"ok": true, "skipped": "", "event_id": event_id,
				"kind": Memory.KIND_DIALOGUE, "salience": SALIENCE_ACCEPTED,
				"summary": "我接受了%s的%s邀约。" % [from_name, kind_label],
				"participants": participants, "at_utc": decided_utc,
			}
		return {"ok": false, "skipped": "not_subject"}
	if status == Invitation.STATUS_DECLINED:
		if resident == from_id:
			return {
				"ok": true, "skipped": "", "event_id": event_id,
				"kind": Memory.KIND_CONFLICT, "salience": SALIENCE_DECLINED,
				"summary": "%s拒绝了我的%s邀约。" % [to_name, kind_label],
				"participants": participants, "at_utc": decided_utc,
			}
		return {"ok": false, "skipped": "not_subject"}
	if status == Invitation.STATUS_WITHDRAWN:
		if resident == to_id:
			return {
				"ok": true, "skipped": "", "event_id": event_id,
				"kind": Memory.KIND_OBSERVATION, "salience": SALIENCE_WITHDRAWN,
				"summary": "%s撤回了给我的%s邀约。" % [from_name, kind_label],
				"participants": participants, "at_utc": decided_utc,
			}
		return {"ok": false, "skipped": "not_subject"}
	if status == Invitation.STATUS_EXPIRED:
		return {"ok": false, "skipped": "expired"}
	return {"ok": false, "skipped": "pending"}


static func _social_memory_kind(kind: String) -> String:
	if kind == Social.KIND_GIFT:
		return Memory.KIND_GIFT
	return Memory.KIND_DIALOGUE


static func _social_salience(kind: String) -> int:
	if kind == Social.KIND_GIFT:
		return SALIENCE_GIFT
	if kind == Social.KIND_INVITE:
		return SALIENCE_INVITE
	if kind == Social.KIND_APOLOGIZE:
		return SALIENCE_APOLOGIZE
	return SALIENCE_GREET


static func _social_summary(kind: String, target_name: String) -> String:
	if kind == Social.KIND_GREET:
		return "我向%s打了招呼。" % target_name
	if kind == Social.KIND_GIFT:
		return "我向%s送了礼。" % target_name
	if kind == Social.KIND_INVITE:
		return "我邀请%s来做客。" % target_name
	if kind == Social.KIND_APOLOGIZE:
		return "我向%s道了歉。" % target_name
	return "我与%s进行了社交。" % target_name


static func _invitation_label(kind: String) -> String:
	if kind == Invitation.KIND_VISIT:
		return "来访"
	if kind == Invitation.KIND_MEAL:
		return "共餐"
	if kind == Invitation.KIND_TRADE_TALK:
		return "谈交易"
	return "社交"


static func _check_context(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _context_error("invalid_context")
	var source: Dictionary = value
	for key: Variant in source.keys():
		if not (key is String) or not str(key) in CONTEXT_KEYS:
			return _context_error("invalid_context")
	for key: String in ["now_utc", "world_id", "resident_id"]:
		if not source.has(key):
			return _context_error("invalid_context")
	if not _valid_time(source.now_utc):
		return _context_error("invalid_time")
	var created: Dictionary = Memory.create(source.world_id)
	if not created.ok:
		return _context_error("invalid_world_id")
	if not _valid_id(source.resident_id):
		return _context_error("invalid_resident")
	var names: Dictionary = {}
	if source.has("names"):
		if not source.names is Dictionary:
			return _context_error("invalid_names")
		names = source.names
		for key: Variant in names.keys():
			if not _valid_id(key) or not names[key] is String \
					or str(names[key]).is_empty():
				return _context_error("invalid_names")
	return {
		"ok": true, "reason": "",
		"context": {
			"now_utc": float(source.now_utc), "world_id": str(source.world_id),
			"resident_id": str(source.resident_id), "names": names,
		},
	}


## Top level only: `ok` plus exactly one event body. Field-level validation of
## the body runs after `ok` is known to be true.
static func _check_result(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _result_error("invalid_result")
	var source: Dictionary = value
	for key: Variant in source.keys():
		if not (key is String) or not str(key) in RESULT_KEYS:
			return _result_error("invalid_result")
	if not source.has("ok") or not source.ok is bool:
		return _result_error("invalid_ok")
	var has_act: bool = source.has("act")
	var has_invitation: bool = source.has("invitation")
	if has_act == has_invitation:
		return _result_error("invalid_result")
	if has_act:
		if not source.act is Dictionary:
			return _result_error("invalid_act")
		return _result_ok(SOURCE_SOCIAL, bool(source.ok), source.act)
	if not source.invitation is Dictionary:
		return _result_error("invalid_invitation")
	return _result_ok(SOURCE_INVITATION, bool(source.ok), source.invitation)


static func _check_act(value: Variant, now_utc: float) -> Dictionary:
	if not value is Dictionary:
		return _fail("invalid_act")
	var act: Dictionary = value
	if not _exact_keys(act, ACT_KEYS):
		return _fail("invalid_act")
	if not _valid_event_id(act.get("id")):
		return _fail("invalid_act_id")
	if not act.get("kind") is String or not str(act.kind) in Social.ACTIONS:
		return _fail("invalid_kind")
	if not _valid_id(act.get("from")):
		return _fail("invalid_from")
	if not _valid_id(act.get("to")):
		return _fail("invalid_to")
	if str(act.from) == str(act.to):
		return _fail("invalid_target")
	if not _valid_time(act.get("expires_utc")):
		return _fail("invalid_expiry")
	if float(now_utc) >= float(act.expires_utc):
		return _fail("expired")
	return {
		"ok": true, "reason": "",
		"act": {
			"id": str(act.id), "kind": str(act.kind), "from": str(act.from),
			"to": str(act.to), "expires_utc": float(act.expires_utc),
		},
	}


## Pending rows carry no decision time in `npc_invitation.gd`, so
## `decided_utc` is optional there and required for a decided status.
static func _check_invitation(value: Variant, now_utc: float) -> Dictionary:
	if not value is Dictionary:
		return _fail("invalid_invitation")
	var invitation: Dictionary = value
	for key: Variant in invitation.keys():
		if not (key is String) or not str(key) in INVITATION_KEYS:
			return _fail("invalid_invitation")
	for key: String in INVITATION_REQUIRED_KEYS:
		if not invitation.has(key):
			return _fail("invalid_invitation")
	if not _valid_event_id(invitation.get("id")):
		return _fail("invalid_invitation_id")
	if not _valid_id(invitation.get("from")):
		return _fail("invalid_from")
	if not _valid_id(invitation.get("to")):
		return _fail("invalid_to")
	if str(invitation.from) == str(invitation.to):
		return _fail("invalid_target")
	if not invitation.get("kind") is String \
			or not str(invitation.kind) in Invitation.KINDS:
		return _fail("invalid_kind")
	if not invitation.get("status") is String \
			or not str(invitation.status) in Invitation.STATUSES:
		return _fail("invalid_status")
	var status: String = str(invitation.status)
	var decided_utc: float = 0.0
	if status == Invitation.STATUS_PENDING:
		if invitation.has("decided_utc"):
			if not _valid_time(invitation.decided_utc):
				return _fail("invalid_decided_utc")
			decided_utc = float(invitation.decided_utc)
	else:
		if not invitation.has("decided_utc"):
			return _fail("invalid_invitation")
		if not _valid_time(invitation.decided_utc):
			return _fail("invalid_decided_utc")
		decided_utc = float(invitation.decided_utc)
		if decided_utc > float(now_utc):
			return _fail("future_time")
	return {
		"ok": true, "reason": "",
		"invitation": {
			"id": str(invitation.id), "from": str(invitation.from),
			"to": str(invitation.to), "kind": str(invitation.kind),
			"status": status, "decided_utc": decided_utc,
		},
	}


static func _display_name(settings: Dictionary, npc_id: String) -> String:
	var names: Dictionary = settings.names
	if names.has(npc_id):
		var name: String = str(names[npc_id])
		if not name.is_empty():
			return name
	return npc_id


static func _people(values: Array) -> Array:
	var people: Array = []
	for value: Variant in values:
		var person: String = str(value)
		if OwnerIds.valid(person) and not person in people:
			people.append(person)
	return people


static func _clip(text: String) -> String:
	return text if text.length() <= Memory.MAX_SUMMARY_LENGTH \
		else text.left(Memory.MAX_SUMMARY_LENGTH)


## FNV-1a over UTF-8 bytes, masked to 32 bits. Each value is separated so
## ("ab", "c") and ("a", "bc") cannot collide. Two domains give 64 bits.
static func _token(parts: Array) -> String:
	return "%08x%08x" % [
		_hash32(parts, "0"), _hash32(parts, "1"),
	]


static func _hash32(parts: Array, domain: String) -> int:
	var digest: int = HASH_OFFSET
	for part: Variant in parts:
		for byte: int in str(part).to_utf8_buffer():
			digest = (digest ^ byte) & HASH_MASK
			digest = (digest * HASH_PRIME) & HASH_MASK
		digest = (digest ^ 0xFF) & HASH_MASK
		digest = (digest * HASH_PRIME) & HASH_MASK
	for byte: int in domain.to_utf8_buffer():
		digest = (digest ^ byte) & HASH_MASK
		digest = (digest * HASH_PRIME) & HASH_MASK
	return digest


static func _valid_id(value: Variant) -> bool:
	return OwnerIds.valid(value)


static func _valid_event_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_EVENT_ID_LENGTH


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) >= 0.0 and float(value) <= float(Memory.MAX_SAFE_INTEGER)


static func _exact_keys(value: Dictionary, keys: Array[String]) -> bool:
	if value.size() != keys.size():
		return false
	for key: String in keys:
		if not value.has(key):
			return false
	return true


static func _written(document: Dictionary, memory_id_value: String) -> Dictionary:
	return {
		"ok": true, "reason": "", "memory": document, "memory_id": memory_id_value,
		"duplicate": false, "skipped": "", "written": true,
	}


static func _duplicate(document: Dictionary, memory_id_value: String) -> Dictionary:
	return {
		"ok": true, "reason": "duplicate", "memory": document,
		"memory_id": memory_id_value, "duplicate": true, "skipped": "",
		"written": false,
	}


static func _skipped(document: Dictionary, reason: String) -> Dictionary:
	return {
		"ok": true, "reason": "", "memory": document, "memory_id": "",
		"duplicate": false, "skipped": reason, "written": false,
	}


static func _context_error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "context": {}}


static func _result_error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "result": {}}


static func _result_ok(source: String, ok: bool, body: Dictionary) -> Dictionary:
	return {
		"ok": true, "reason": "",
		"result": {"ok": ok, "source": source, "body": body},
	}


static func _fail(reason: String, detail: String = "") -> Dictionary:
	var result: Dictionary = {
		"ok": false, "reason": reason, "memory_id": "", "duplicate": false,
		"skipped": "", "written": false,
	}
	if not detail.is_empty():
		result["detail"] = detail
	return result
