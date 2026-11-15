extends SceneTree
## M10-02/M10-04 cross-cut: social actions and invitation decisions become
## bounded resident memory. Headless and isolated: no model, clock, disk, scene
## or live save. Every event is a minimal structured projection handed in by
## the test.

const SocialMemory = preload("res://npc/npc_social_memory.gd")
const Memory = preload("res://npc/npc_memory.gd")

const WORLD: String = "world-a"
const OTHER_WORLD: String = "world-b"
const NPC_LIN: String = "npc_lin_shen"
const NPC_XU: String = "npc_xu_bo"
const NPC_ZHOU: String = "npc_a_zhou"
const LIN_NAME: String = "林婶"
const XU_NAME: String = "许伯"
const ZHOU_NAME: String = "阿舟"
const START: float = 1800000000.0
const DAY: float = 86400.0

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_social_actions()
	_test_invitations()
	_test_skips()
	_test_duplicates()
	_test_rejections()
	_test_capacity()
	_test_copy_on_write()
	_test_round_trip()
	_test_determinism_shape_and_names()
	for failure: String in failures:
		push_error(failure)
	print("NPC_SOCIAL_MEMORY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_social_actions() -> void:
	var document: Dictionary = _document()
	var act: Dictionary = _act("social_greet_1", "greet", NPC_LIN, NPC_XU)
	var applied: Dictionary = _apply(document, act, NPC_LIN)
	_expect(applied.ok and applied.written and applied.reason == "",
		"An initiated greet writes one memory row")
	_expect(not (document.npcs as Dictionary).has(NPC_LIN),
		"apply() leaves the input document untouched")
	var entry: Dictionary = _entry(applied.memory, NPC_LIN, applied)
	_expect(not entry.is_empty(), "The candidate document carries the row")
	_expect(entry.kind == Memory.KIND_DIALOGUE, "A greet is a dialogue memory")
	_expect(int(entry.salience) == SocialMemory.SALIENCE_GREET,
		"A greet uses the fixed greet importance")
	_expect(entry.summary == "我向许伯打了招呼。",
		"A greet summary is the fixed first-person template")
	_expect(int(entry.at_utc) == int(START),
		"The injected now_utc becomes the social memory time")
	_expect(entry.world_id == WORLD and int(entry.state_version) == 0,
		"The row carries the world and the default state version")
	_expect(entry.participants.size() == 2 and NPC_LIN in entry.participants \
		and NPC_XU in entry.participants,
		"Both people are named as participants")
	_expect(Memory.valid_document(applied.memory, START),
		"The candidate passes M10-01 strict validation")
	_expect(Memory.retrieve(applied.memory, NPC_LIN, {"now_utc": START}).total == 1,
		"The written row is visible through M10-01 retrieval")

	var counterpart: Dictionary = _apply(document, act, NPC_XU)
	_expect(counterpart.ok and counterpart.skipped == "counterparty_only" \
		and not counterpart.written,
		"The greeted resident does not write the initiator's memory")
	_expect(not (counterpart.memory.npcs as Dictionary).has(NPC_XU),
		"A counterparty view leaves no row for the recipient")
	var third: Dictionary = _apply(document, act, NPC_ZHOU)
	_expect(third.ok and third.skipped == "not_participant" and not third.written,
		"A third resident does not remember someone else's social action")
	_expect(not (third.memory.npcs as Dictionary).has(NPC_ZHOU),
		"A third-party view writes nothing")

	var gift: Dictionary = _apply(document, _act(
		"social_gift_1", "gift", NPC_LIN, NPC_XU), NPC_LIN)
	var gift_entry: Dictionary = _entry(gift.memory, NPC_LIN, gift)
	_expect(gift_entry.kind == Memory.KIND_GIFT \
		and int(gift_entry.salience) == SocialMemory.SALIENCE_GIFT,
		"A gift maps to the gift kind and gift importance")
	_expect(gift_entry.summary == "我向许伯送了礼。", "A gift has a fixed summary")
	var invite: Dictionary = _apply(document, _act(
		"social_invite_1", "invite", NPC_LIN, NPC_XU), NPC_LIN)
	var invite_entry: Dictionary = _entry(invite.memory, NPC_LIN, invite)
	_expect(invite_entry.kind == Memory.KIND_DIALOGUE \
		and int(invite_entry.salience) == SocialMemory.SALIENCE_INVITE,
		"A social invite maps to dialogue with invite importance")
	_expect(invite_entry.summary == "我邀请许伯来做客。", "An invite has a fixed summary")
	var apology: Dictionary = _apply(document, _act(
		"social_apology_1", "apologize", NPC_LIN, NPC_XU), NPC_LIN)
	var apology_entry: Dictionary = _entry(apology.memory, NPC_LIN, apology)
	_expect(apology_entry.kind == Memory.KIND_DIALOGUE \
		and int(apology_entry.salience) == SocialMemory.SALIENCE_APOLOGIZE,
		"An apology maps to dialogue with apology importance")
	_expect(apology_entry.summary == "我向许伯道了歉。", "An apology has a fixed summary")


func _test_invitations() -> void:
	var document: Dictionary = _document()
	var accepted: Dictionary = _invitation(
		"inv_1", NPC_LIN, NPC_XU, "visit", "accepted", START - 10.0)
	var accepted_for_recipient: Dictionary = _apply(document, accepted, NPC_XU)
	_expect(accepted_for_recipient.ok and accepted_for_recipient.written,
		"The recipient remembers accepting an invitation")
	var entry: Dictionary = _entry(
		accepted_for_recipient.memory, NPC_XU, accepted_for_recipient)
	_expect(entry.kind == Memory.KIND_DIALOGUE \
		and int(entry.salience) == SocialMemory.SALIENCE_ACCEPTED,
		"An acceptance is a dialogue memory with acceptance importance")
	_expect(entry.summary == "我接受了林婶的来访邀约。",
		"An acceptance summary names the initiator and the invite kind")
	_expect(int(entry.at_utc) == int(START - 10.0),
		"The invitation row uses decided_utc, not the later injection time")
	_expect(entry.participants.size() == 2 and NPC_LIN in entry.participants \
		and NPC_XU in entry.participants,
		"An invitation names both people as participants")
	var accepted_for_initiator: Dictionary = _apply(document, accepted, NPC_LIN)
	_expect(accepted_for_initiator.ok \
		and accepted_for_initiator.skipped == "not_subject" \
		and not accepted_for_initiator.written,
		"The initiator does not write someone else's acceptance")

	var declined: Dictionary = _invitation(
		"inv_2", NPC_LIN, NPC_XU, "meal", "declined", START - 5.0)
	var declined_for_initiator: Dictionary = _apply(document, declined, NPC_LIN)
	_expect(declined_for_initiator.ok and declined_for_initiator.written,
		"The initiator remembers being declined")
	var declined_entry: Dictionary = _entry(
		declined_for_initiator.memory, NPC_LIN, declined_for_initiator)
	_expect(declined_entry.kind == Memory.KIND_CONFLICT \
		and int(declined_entry.salience) == SocialMemory.SALIENCE_DECLINED,
		"A rejection is a higher-importance conflict memory")
	_expect(declined_entry.summary == "许伯拒绝了我的共餐邀约。",
		"A rejection summary names the recipient and the invite kind")
	var declined_for_recipient: Dictionary = _apply(document, declined, NPC_XU)
	_expect(declined_for_recipient.ok \
		and declined_for_recipient.skipped == "not_subject",
		"The recipient of a rejection does not write it")

	var withdrawn: Dictionary = _invitation(
		"inv_3", NPC_LIN, NPC_XU, "trade_talk", "withdrawn", START - 5.0)
	var withdrawn_for_recipient: Dictionary = _apply(document, withdrawn, NPC_XU)
	_expect(withdrawn_for_recipient.ok and withdrawn_for_recipient.written,
		"The recipient remembers a withdrawn invitation")
	var withdrawn_entry: Dictionary = _entry(
		withdrawn_for_recipient.memory, NPC_XU, withdrawn_for_recipient)
	_expect(withdrawn_entry.kind == Memory.KIND_OBSERVATION \
		and int(withdrawn_entry.salience) == SocialMemory.SALIENCE_WITHDRAWN,
		"A withdrawal is a low-importance observation memory")
	_expect(withdrawn_entry.summary == "林婶撤回了给我的谈交易邀约。",
		"A withdrawal summary names the initiator and the invite kind")
	var withdrawn_for_initiator: Dictionary = _apply(document, withdrawn, NPC_LIN)
	_expect(withdrawn_for_initiator.ok \
		and withdrawn_for_initiator.skipped == "not_subject",
		"The withdrawing initiator does not write a memory")


func _test_skips() -> void:
	var document: Dictionary = _document()
	var act: Dictionary = _act("social_failed", "greet", NPC_LIN, NPC_XU)
	var failed: Dictionary = _apply(
		document, {"ok": false, "act": act.act}, NPC_LIN)
	_expect(failed.ok and failed.skipped == "not_committed" and not failed.written,
		"A failed social action is skipped")
	_expect(not (failed.memory.npcs as Dictionary).has(NPC_LIN),
		"A failed action writes no memory")

	var pending: Dictionary = _invitation(
		"inv_pending", NPC_LIN, NPC_XU, "visit", "pending")
	var pending_from: Dictionary = _apply(document, pending, NPC_LIN)
	var pending_to: Dictionary = _apply(document, pending, NPC_XU)
	_expect(pending_from.ok and pending_from.skipped == "pending" \
		and not pending_from.written,
		"A pending invitation is not a fact for the initiator")
	_expect(pending_to.ok and pending_to.skipped == "pending" \
		and not pending_to.written,
		"A pending invitation is not a fact for the recipient")
	_expect(not (pending_to.memory.npcs as Dictionary).has(NPC_XU),
		"A pending invitation leaves no row")

	var pending_with_time: Dictionary = _invitation(
		"inv_pending_2", NPC_LIN, NPC_XU, "visit", "pending", START)
	_expect(_apply(document, pending_with_time, NPC_XU).skipped == "pending",
		"A pending row that carries a time is still not a fact")

	var expired: Dictionary = _invitation(
		"inv_expired", NPC_LIN, NPC_XU, "visit", "expired", START)
	var expired_from: Dictionary = _apply(document, expired, NPC_LIN)
	var expired_to: Dictionary = _apply(document, expired, NPC_XU)
	_expect(expired_from.skipped == "expired" and expired_to.skipped == "expired",
		"An expired invitation is not written for either party")

	var failed_invitation: Dictionary = {
		"ok": false,
		"invitation": _invitation(
			"inv_failed", NPC_LIN, NPC_XU, "visit", "accepted", START).invitation,
	}
	var failed_decision: Dictionary = _apply(document, failed_invitation, NPC_XU)
	_expect(failed_decision.ok and failed_decision.skipped == "not_committed",
		"A failed decision result is skipped even when it names an acceptance")


func _test_duplicates() -> void:
	var document: Dictionary = _document()
	var act: Dictionary = _act("social_dup", "gift", NPC_LIN, NPC_XU)
	var first: Dictionary = _apply(document, act, NPC_LIN)
	var snapshot: Dictionary = first.memory.duplicate(true)
	var second: Dictionary = _apply(first.memory, act, NPC_LIN, START + 60.0)
	_expect(second.ok and second.reason == "duplicate" and bool(second.duplicate) \
		and not second.written,
		"A replayed act id is reported as duplicate")
	_expect(second.memory == snapshot,
		"A replayed act leaves the memory document byte-identical")
	_expect(first.memory == snapshot,
		"Replaying does not mutate the previous candidate")
	_expect((first.memory.npcs[NPC_LIN].entries as Dictionary).size() == 1,
		"A replay adds no second row")

	var other_act: Dictionary = _act("social_dup_2", "gift", NPC_LIN, NPC_XU)
	var third: Dictionary = _apply(first.memory, other_act, NPC_LIN, START + 60.0)
	_expect(third.ok and third.written \
		and (third.memory.npcs[NPC_LIN].entries as Dictionary).size() == 2,
		"The same content under another id is a distinct memory")

	var accepted: Dictionary = _invitation(
		"inv_dup", NPC_LIN, NPC_XU, "visit", "accepted", START)
	var first_invite: Dictionary = _apply(document, accepted, NPC_XU)
	var invite_snapshot: Dictionary = first_invite.memory.duplicate(true)
	var second_invite: Dictionary = _apply(
		first_invite.memory, accepted, NPC_XU, START + 30.0)
	_expect(second_invite.reason == "duplicate" \
		and second_invite.memory == invite_snapshot,
		"A replayed invitation id is idempotent")

	_expect(SocialMemory.memory_id("social", "social_dup", NPC_LIN) \
		== first.memory_id,
		"The memory id is deterministic and exposed for callers")
	_expect(SocialMemory.memory_id("social", "social_dup", NPC_LIN) \
		!= SocialMemory.memory_id("invitation", "social_dup", NPC_LIN),
		"Social actions and invitations do not share an id domain")
	_expect(SocialMemory.memory_id("social", "social_dup", NPC_LIN) \
		!= SocialMemory.memory_id("social", "social_dup", NPC_XU),
		"Each resident derives a distinct memory id")


func _test_rejections() -> void:
	var document: Dictionary = _document()
	var valid_act: Dictionary = _act("social_ok", "greet", NPC_LIN, NPC_XU)
	var document_before: String = JSON.stringify(document)
	var act_before: String = JSON.stringify(valid_act)

	for bad_memory: Variant in [null, [], {}, "document"]:
		var refused: Dictionary = SocialMemory.apply(
			bad_memory, valid_act, _context(NPC_LIN))
		_expect(not refused.ok and refused.reason == "invalid_memory" \
			and not refused.has("memory"),
			"A malformed memory document is refused as invalid_memory")

	for bad_context: Variant in [
			null, [], {},
			{"now_utc": START, "world_id": WORLD},
			{"now_utc": -1.0, "world_id": WORLD, "resident_id": NPC_LIN},
			{"now_utc": START, "world_id": "bad world", "resident_id": NPC_LIN},
			{"now_utc": START, "world_id": WORLD, "resident_id": "bad id"},
			{"now_utc": START, "world_id": WORLD, "resident_id": NPC_LIN, "names": []},
			{"now_utc": START, "world_id": WORLD, "resident_id": NPC_LIN, "extra": 1},
		]:
		var refused: Dictionary = SocialMemory.apply(document, valid_act, bad_context)
		_expect(not refused.ok and not refused.has("memory"),
			"A malformed context is refused without a memory")
	var wrong_world: Dictionary = SocialMemory.apply(document, valid_act, {
		"now_utc": START, "world_id": OTHER_WORLD, "resident_id": NPC_LIN,
	})
	_expect(not wrong_world.ok and wrong_world.reason == "world_mismatch",
		"A context world that differs from the document is refused")

	for bad_result: Variant in [null, [], {}, {"ok": true},
			{"ok": "yes", "act": valid_act.act},
			{"ok": true, "act": valid_act.act, "invitation": {}},
			{"ok": true, "act": valid_act.act, "cash": 1}]:
		var refused: Dictionary = SocialMemory.apply(
			document, bad_result, _context(NPC_LIN))
		_expect(not refused.ok and not refused.has("memory"),
			"A malformed result is refused without a memory")
	_expect(SocialMemory.apply(document, {}, _context(NPC_LIN)).reason == "invalid_ok",
		"A result without ok is refused as invalid_ok")

	var act_cases: Array = [
		[{"id": "a", "kind": "dance", "from": NPC_LIN, "to": NPC_XU,
			"expires_utc": START + 120.0}, "invalid_kind"],
		[{"id": "", "kind": "greet", "from": NPC_LIN, "to": NPC_XU,
			"expires_utc": START + 120.0}, "invalid_act_id"],
		[{"id": 5, "kind": "greet", "from": NPC_LIN, "to": NPC_XU,
			"expires_utc": START + 120.0}, "invalid_act_id"],
		[{"id": "a", "kind": "greet", "from": "bad id", "to": NPC_XU,
			"expires_utc": START + 120.0}, "invalid_from"],
		[{"id": "a", "kind": "greet", "from": NPC_LIN, "to": NPC_LIN,
			"expires_utc": START + 120.0}, "invalid_target"],
		[{"id": "a", "kind": "greet", "from": NPC_LIN, "to": NPC_XU,
			"expires_utc": -1.0}, "invalid_expiry"],
		[{"id": "a", "kind": "greet", "from": NPC_LIN, "to": NPC_XU,
			"expires_utc": START}, "expired"],
		[{"id": "a", "kind": "greet", "from": NPC_LIN, "to": NPC_XU}, "invalid_act"],
		[{"id": "a", "kind": "greet", "from": NPC_LIN, "to": NPC_XU,
			"expires_utc": START + 120.0, "cash": 1}, "invalid_act"],
	]
	for entry_case: Array in act_cases:
		var refused: Dictionary = SocialMemory.apply(document, {
			"ok": true, "act": entry_case[0],
		}, _context(NPC_LIN))
		_expect(not refused.ok and refused.reason == str(entry_case[1]) \
			and not refused.has("memory"),
			"A malformed act is refused with its named reason: " + str(entry_case[1]))

	var invitation_cases: Array = [
		[{"id": "", "from": NPC_LIN, "to": NPC_XU, "kind": "visit",
			"status": "accepted", "decided_utc": START}, "invalid_invitation_id"],
		[{"id": "i", "from": "bad id", "to": NPC_XU, "kind": "visit",
			"status": "accepted", "decided_utc": START}, "invalid_from"],
		[{"id": "i", "from": NPC_LIN, "to": NPC_LIN, "kind": "visit",
			"status": "accepted", "decided_utc": START}, "invalid_target"],
		[{"id": "i", "from": NPC_LIN, "to": NPC_XU, "kind": "picnic",
			"status": "accepted", "decided_utc": START}, "invalid_kind"],
		[{"id": "i", "from": NPC_LIN, "to": NPC_XU, "kind": "visit",
			"status": "maybe", "decided_utc": START}, "invalid_status"],
		[{"id": "i", "from": NPC_LIN, "to": NPC_XU, "kind": "visit",
			"status": "accepted", "decided_utc": -1.0}, "invalid_decided_utc"],
		[{"id": "i", "from": NPC_LIN, "to": NPC_XU, "kind": "visit",
			"status": "accepted", "decided_utc": START + 1.0}, "future_time"],
		[{"id": "i", "from": NPC_LIN, "to": NPC_XU, "kind": "visit",
			"status": "accepted"}, "invalid_invitation"],
		[{"id": "i", "from": NPC_LIN, "to": NPC_XU, "kind": "visit",
			"status": "pending", "decided_utc": -1.0}, "invalid_decided_utc"],
		[{"id": "i", "from": NPC_LIN, "kind": "visit",
			"status": "pending"}, "invalid_invitation"],
		[{"id": "i", "from": NPC_LIN, "to": NPC_XU, "kind": "visit",
			"status": "pending", "cash": 1}, "invalid_invitation"],
	]
	for entry_case: Array in invitation_cases:
		var refused: Dictionary = SocialMemory.apply(document, {
			"ok": true, "invitation": entry_case[0],
		}, _context(NPC_XU))
		_expect(not refused.ok and refused.reason == str(entry_case[1]) \
			and not refused.has("memory"),
			"A malformed invitation is refused with its named reason: "
				+ str(entry_case[1]))

	_expect(JSON.stringify(document) == document_before,
		"Every rejected result leaves the memory document byte-identical")
	_expect(JSON.stringify(valid_act) == act_before,
		"Rejections never modify the result projection")


func _test_capacity() -> void:
	var document: Dictionary = _document()
	var base: float = START + 100.0 * DAY
	var all_written: bool = true
	for index: int in 70:
		var now: float = base + float(index) * 60.0
		var applied: Dictionary = _apply(document, _act(
			"social_cap_%03d" % index, "greet", NPC_LIN, NPC_XU, now), NPC_LIN, now)
		all_written = all_written and bool(applied.written)
		document = applied.memory
	_expect(all_written, "Every social action within capacity writes a row")
	var row: Dictionary = document.npcs[NPC_LIN]
	_expect((row.entries as Dictionary).size() == Memory.MAX_ENTRIES,
		"Social memory stays at the M10-01 capacity")
	_expect(int(row.dropped) == 70 - Memory.MAX_ENTRIES,
		"Each eviction increments the drop counter")
	_expect(Memory.valid_document(document, base + 69.0 * 60.0),
		"A full social-memory document passes M10-01 validation")
	var last_id: String = SocialMemory.memory_id(
		"social", "social_cap_069", NPC_LIN)
	_expect((row.entries as Dictionary).has(last_id),
		"The newest row survives eviction")
	var first_id: String = SocialMemory.memory_id(
		"social", "social_cap_000", NPC_LIN)
	_expect(not (row.entries as Dictionary).has(first_id),
		"The lowest-salience oldest row is evicted first")

	var apology_now: float = base + 70.0 * 60.0
	var apology: Dictionary = _apply(document, _act(
		"social_cap_apology", "apologize", NPC_LIN, NPC_XU, apology_now),
		NPC_LIN, apology_now)
	_expect(apology.ok and apology.written, "A new high-importance row is written")
	_expect((apology.memory.npcs[NPC_LIN].entries as Dictionary).size() \
		== Memory.MAX_ENTRIES,
		"Capacity is still bounded after a new row")
	var apology_id: String = SocialMemory.memory_id(
		"social", "social_cap_apology", NPC_LIN)
	_expect((apology.memory.npcs[NPC_LIN].entries as Dictionary).has(apology_id),
		"The higher-importance apology survives")
	_expect(int(apology.memory.npcs[NPC_LIN].dropped) \
		== 70 - Memory.MAX_ENTRIES + 1,
		"The extra eviction is counted once")
	_expect(Memory.valid_document(apology.memory, apology_now),
		"The bounded document remains valid")
	_expect((apology.memory.npcs as Dictionary).has(NPC_XU) == false,
		"No row is written for the untouched counterparty")


func _test_copy_on_write() -> void:
	var document: Dictionary = _document()
	var seeded: Dictionary = _apply(document, _act(
		"social_seed", "greet", NPC_LIN, NPC_XU), NPC_LIN).memory
	var act: Dictionary = _act("social_cow", "gift", NPC_LIN, NPC_XU)
	var context: Dictionary = _context(NPC_LIN)
	var document_before: String = JSON.stringify(seeded)
	var act_before: String = JSON.stringify(act)
	var context_before: String = JSON.stringify(context)
	var applied: Dictionary = SocialMemory.apply(seeded, act, context)
	_expect(applied.ok and applied.written, "The copy-on-write probe writes")
	_expect(JSON.stringify(seeded) == document_before,
		"The memory document is byte-identical after apply")
	_expect(JSON.stringify(act) == act_before, "The result projection is not modified")
	_expect(JSON.stringify(context) == context_before, "The context is not modified")
	var entry: Dictionary = _entry(applied.memory, NPC_LIN, applied)
	entry["summary"] = "tampered"
	_expect(JSON.stringify(seeded) == document_before,
		"Mutating the candidate does not reach the input document")

	var skip: Dictionary = SocialMemory.apply(seeded, act, _context(NPC_XU))
	_expect(skip.ok and skip.skipped == "counterparty_only",
		"The skip probe is skipped")
	var skipped_memory: Dictionary = skip.memory
	skipped_memory["schema"] = 999
	_expect(JSON.stringify(seeded) == document_before,
		"Mutating a skipped candidate does not reach the input")
	var refused: Dictionary = SocialMemory.apply(seeded, {"ok": "yes"}, context)
	_expect(not refused.ok and not refused.has("memory"),
		"A failure returns no memory candidate")


func _test_round_trip() -> void:
	var document: Dictionary = _document()
	var now: float = START + 100.0
	var applied: Dictionary = SocialMemory.apply(document, _act(
		"social_rt_1", "gift", NPC_LIN, NPC_XU, now), _context(NPC_LIN, now))
	_expect(applied.ok and applied.written, "The round-trip probe writes")
	var encoded: Dictionary = Memory.to_json(applied.memory, now)
	_expect(encoded.ok, "The social-memory document serializes through M10-01")
	var decoded: Dictionary = Memory.from_json(str(encoded.json), now)
	_expect(decoded.ok and decoded.document == applied.memory,
		"The social-memory document round-trips through M10-01 JSON")
	var later: float = now + DAY
	var restored: Dictionary = SocialMemory.apply(decoded.document, _act(
		"social_rt_2", "greet", NPC_LIN, NPC_XU, later), _context(NPC_LIN, later))
	var direct: Dictionary = SocialMemory.apply(applied.memory, _act(
		"social_rt_2", "greet", NPC_LIN, NPC_XU, later), _context(NPC_LIN, later))
	_expect(restored.ok and direct.ok and restored.memory == direct.memory,
		"Writing after a JSON restore matches a direct write")


func _test_determinism_shape_and_names() -> void:
	var first_document: Dictionary = _document()
	var second_document: Dictionary = _document()
	var now: float = START
	for index: int in 10:
		now = START + float(index) * 60.0
		var act: Dictionary = _act(
			"social_det_%02d" % index, "greet", NPC_LIN, NPC_XU, now)
		first_document = _apply(first_document, act, NPC_LIN, now).memory
		second_document = _apply(second_document, act, NPC_LIN, now).memory
	_expect(first_document == second_document,
		"The same sequence produces the same document")
	_expect((first_document.npcs[NPC_LIN].entries as Dictionary).size() == 10,
		"Ten distinct acts produce ten rows")

	var expected_record_keys: Array = Memory.RECORD_KEYS.duplicate()
	expected_record_keys.sort()
	var entries: Dictionary = first_document.npcs[NPC_LIN].entries
	for memory_id_value: Variant in entries:
		var row: Dictionary = entries[memory_id_value]
		var stored_keys: Array = row.keys()
		stored_keys.sort()
		_expect(stored_keys == expected_record_keys,
			"A social-memory row keeps exactly the eight M10-01 fields")
		_expect(not row.has("relations") and not row.has("cash") \
			and not row.has("ownership"),
			"No relationship, cash or authority field leaks into memory")
	var document_keys: Array = first_document.keys()
	document_keys.sort()
	var expected_document_keys: Array = Memory.DOCUMENT_KEYS.duplicate()
	expected_document_keys.sort()
	_expect(document_keys == expected_document_keys,
		"The document keeps exactly the three M10-01 fields")

	var unnamed: Dictionary = SocialMemory.apply(_document(), _act(
		"social_unnamed", "greet", NPC_LIN, NPC_XU), {
			"now_utc": START, "world_id": WORLD, "resident_id": NPC_LIN,
		})
	var unnamed_entry: Dictionary = _entry(unnamed.memory, NPC_LIN, unnamed)
	_expect(unnamed_entry.summary == "我向npc_xu_bo打了招呼。",
		"Without a name projection the summary falls back to the id")
	var partial: Dictionary = SocialMemory.apply(_document(), _act(
		"social_partial", "greet", NPC_LIN, NPC_ZHOU), {
			"now_utc": START, "world_id": WORLD, "resident_id": NPC_LIN,
			"names": {NPC_ZHOU: ZHOU_NAME},
		})
	var partial_entry: Dictionary = _entry(partial.memory, NPC_LIN, partial)
	_expect(partial_entry.summary == "我向阿舟打了招呼。",
		"A partial name projection labels only the known id")


func _document() -> Dictionary:
	return Memory.create(WORLD).document


func _context(resident_id: String, now_utc: float = START) -> Dictionary:
	return {
		"now_utc": now_utc, "world_id": WORLD, "resident_id": resident_id,
		"names": {NPC_LIN: LIN_NAME, NPC_XU: XU_NAME, NPC_ZHOU: ZHOU_NAME},
	}


func _apply(document: Dictionary, result: Dictionary, resident_id: String,
		now_utc: float = START) -> Dictionary:
	return SocialMemory.apply(document, result, _context(resident_id, now_utc))


func _act(id: String, kind: String, from_id: String, to_id: String,
		now_utc: float = START) -> Dictionary:
	return {
		"ok": true,
		"act": {
			"id": id, "kind": kind, "from": from_id, "to": to_id,
			"expires_utc": now_utc + 120.0,
		},
	}


func _invitation(id: String, from_id: String, to_id: String, kind: String,
		status: String, decided_utc: float = -1.0) -> Dictionary:
	var row: Dictionary = {
		"id": id, "from": from_id, "to": to_id, "kind": kind, "status": status,
	}
	if decided_utc >= 0.0:
		row["decided_utc"] = decided_utc
	return {"ok": true, "invitation": row}


func _entry(document: Dictionary, npc_id: String, applied: Dictionary) -> Dictionary:
	var memory_id_value: String = str(applied.get("memory_id", ""))
	if memory_id_value.is_empty():
		return {}
	var entries_value: Variant = document.get("npcs", {}).get(
		npc_id, {}).get("entries", {})
	if not entries_value is Dictionary:
		return {}
	var entries: Dictionary = entries_value
	if not entries.has(memory_id_value):
		return {}
	return entries[memory_id_value]


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
