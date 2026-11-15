extends SceneTree
## M10-03 memory feed. Headless and isolated: no model, clock, disk, scene or
## live save. World events are minimal projections handed in by the test.

const Feed = preload("res://npc/npc_memory_feed.gd")
const Roster = preload("res://npc/npc_roster.gd")
const Memory = preload("res://npc/npc_memory.gd")

const WORLD: String = "world-a"
const OTHER_WORLD: String = "world-b"
const SEED: int = 7
const NPC_LIN: String = "npc_lin_shen"
const NPC_XU: String = "npc_xu_bo"
const NPC_ZHOU: String = "npc_a_zhou"
const LIN_NAME: String = "林婶"
const XU_NAME: String = "许伯"
const ZHOU_NAME: String = "阿舟"
const PLAYER: String = "player_00000000000000000000000000000001"
const START: float = 1800000000.0
const DAY: float = 86400.0

var checks: int = 0
var failures: Array[String] = []
var roster: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	roster = Roster.build(WORLD, SEED).roster
	_test_direct_mapping()
	_test_observers()
	_test_rejections_and_anonymous()
	_test_replay()
	_test_sequence_and_determinism()
	_test_capacity()
	_test_round_trip()
	_test_boundaries()
	for failure: String in failures:
		push_error(failure)
	print("NPC_MEMORY_FEED_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_direct_mapping() -> void:
	var document: Dictionary = _document()

	# Harvest: the resident who worked owns the factual row, everyone else only
	# observes it at low salience.
	var harvest: Dictionary = _apply(document, {
		"kind": Feed.KIND_HARVEST, "id": "cmd_harvest_1", "actor": NPC_LIN,
		"target": "field_1", "ok": true,
	})
	_expect(harvest.ok and harvest.written == 3 and harvest.duplicates == 0,
		"A committed harvest writes one row for every resident")
	var lin_entry: Dictionary = _entry(document, NPC_LIN, "cmd_harvest_1", harvest)
	_expect(lin_entry.ok, "The harvesting resident receives a factual memory")
	_expect(int(lin_entry.entry.salience) == Feed.SALIENCE_ACTION,
		"A routine action uses the action salience")
	_expect(str(lin_entry.entry.summary).contains(LIN_NAME) \
		and str(lin_entry.entry.summary).contains("收获"),
		"The factual summary names the actor and the action")
	_expect(lin_entry.entry.kind == Memory.KIND_OBSERVATION,
		"Farm actions map to the observation kind")
	_expect(int(lin_entry.entry.at_utc) == int(START),
		"The injected world time becomes the memory time")
	_expect(lin_entry.entry.world_id == WORLD,
		"The memory is tied to the injected world")
	var xu_entry: Dictionary = _entry(document, NPC_XU, "cmd_harvest_1", harvest)
	_expect(int(xu_entry.entry.salience) == Feed.SALIENCE_OBSERVER,
		"A bystander only observes a routine action at low salience")
	_expect(str(xu_entry.entry.summary).begins_with("看见"),
		"An observer summary reports the sighting, not the action as its own")

	# Gift: sender gives, recipient receives, the third resident observes.
	var gift: Dictionary = _apply(document, {
		"kind": Feed.KIND_GIFT, "id": "cmd_gift_1", "actor": NPC_LIN,
		"target": NPC_XU, "ok": true,
	}, START + 10.0)
	_expect(gift.ok and gift.written == 3, "A committed gift reaches all residents")
	var gift_sender: Dictionary = _entry(document, NPC_LIN, "cmd_gift_1", gift)
	var gift_receiver: Dictionary = _entry(document, NPC_XU, "cmd_gift_1", gift)
	var gift_observer: Dictionary = _entry(document, NPC_ZHOU, "cmd_gift_1", gift)
	_expect(gift_sender.entry.kind == Memory.KIND_GIFT,
		"The gift is recorded as a gift, not a generic observation")
	_expect(int(gift_receiver.entry.salience) > int(gift_sender.entry.salience),
		"Receiving a gift matters more to the recipient than to the sender")
	_expect(str(gift_receiver.entry.summary).contains(LIN_NAME),
		"The recipient remembers who gave")
	_expect(str(gift_sender.entry.summary).contains(XU_NAME),
		"The sender remembers who received")
	_expect(int(gift_observer.entry.salience) == Feed.SALIENCE_OBSERVER,
		"The uninvolved resident only observes the gift")
	_expect(gift_receiver.entry.participants.size() == 2
		and NPC_LIN in gift_receiver.entry.participants
		and NPC_XU in gift_receiver.entry.participants,
		"A gift names both people as participants")

	# Theft: the victim carries the strongest factual row.
	var theft: Dictionary = _apply(document, {
		"kind": Feed.KIND_THEFT, "id": "cmd_theft_1", "actor": NPC_ZHOU,
		"target": NPC_LIN, "ok": true,
	}, START + 20.0)
	_expect(theft.ok and theft.written == 3, "A committed theft reaches all residents")
	var victim: Dictionary = _entry(document, NPC_LIN, "cmd_theft_1", theft)
	var thief: Dictionary = _entry(document, NPC_ZHOU, "cmd_theft_1", theft)
	_expect(victim.entry.kind == Memory.KIND_CONFLICT,
		"A theft involving a resident is recorded as a conflict")
	_expect(int(victim.entry.salience) == Feed.SALIENCE_THEFT_VICTIM,
		"The victim carries the theft salience")
	_expect(str(victim.entry.summary).contains(ZHOU_NAME),
		"The victim remembers who took from them")
	_expect(thief.entry.kind == Memory.KIND_CONFLICT
		and int(thief.entry.salience) < int(victim.entry.salience),
		"The taker remembers the act less strongly than the victim")

	# Trade: actor and resident counterparty both get the factual row.
	var trade: Dictionary = _apply(document, {
		"kind": Feed.KIND_TRADE, "id": "cmd_trade_1", "actor": NPC_ZHOU,
		"target": NPC_LIN, "ok": true,
	}, START + 30.0)
	var trade_actor: Dictionary = _entry(document, NPC_ZHOU, "cmd_trade_1", trade)
	var trade_other: Dictionary = _entry(document, NPC_LIN, "cmd_trade_1", trade)
	_expect(trade_actor.entry.kind == Memory.KIND_TRADE
		and trade_other.entry.kind == Memory.KIND_TRADE,
		"Both sides of a completed trade remember it as a trade")
	_expect(int(trade_actor.entry.salience) == Feed.SALIENCE_TRADE
		and int(trade_other.entry.salience) == Feed.SALIENCE_TRADE,
		"A completed trade uses the trade salience for both sides")

	# A trade against a player gives the resident the row; the player id never
	# becomes a memory subject.
	var player_trade: Dictionary = _apply(document, {
		"kind": Feed.KIND_TRADE, "id": "cmd_trade_2", "actor": NPC_LIN,
		"target": PLAYER, "ok": true,
	}, START + 40.0)
	_expect(player_trade.written == 3,
		"A trade with a player still gives every resident one row")
	_expect(not (document.npcs as Dictionary).has(PLAYER),
		"A player id outside the roster never gets a memory row")
	var player_trade_row: Dictionary = _entry(document, NPC_LIN, "cmd_trade_2", player_trade)
	_expect(player_trade_row.entry.kind == Memory.KIND_TRADE,
		"The resident side of a player trade is a factual trade row")
	_expect(str(player_trade_row.entry.summary).contains(Feed.GENERIC_VISITOR),
		"An unnamed counterparty is described as a visitor, not invented as a person")

	# Land and building rows belong to the acting resident and carry no locator
	# in `participants`.
	var land: Dictionary = _apply(document, {
		"kind": Feed.KIND_TERRITORY_CLAIM, "id": "cmd_land_1", "actor": NPC_XU,
		"target": "parcel_01", "ok": true,
	}, START + 50.0)
	var land_row: Dictionary = _entry(document, NPC_XU, "cmd_land_1", land)
	_expect(land_row.entry.kind == Memory.KIND_OBSERVATION
		and int(land_row.entry.salience) == Feed.SALIENCE_LAND,
		"A land claim is a high-salience factual observation")
	_expect(land_row.entry.participants == [NPC_XU],
		"A land claim names the resident, not the parcel, as participant")
	var built: Dictionary = _apply(document, {
		"kind": Feed.KIND_BUILD, "id": "cmd_build_1", "actor": NPC_ZHOU,
		"target": "slot_1", "ok": true,
	}, START + 60.0)
	var built_row: Dictionary = _entry(document, NPC_ZHOU, "cmd_build_1", built)
	_expect(int(built_row.entry.salience) == Feed.SALIENCE_BUILD,
		"Building uses the construction salience")
	_expect(built_row.entry.participants == [NPC_ZHOU],
		"Building names the builder, not the slot, as participant")

	_expect(Memory.valid_document(document, START + 60.0),
		"Every feed document passes the M10-01 strict validation")
	_expect(document.npcs[NPC_LIN].entries.size() == 7
		and document.npcs[NPC_XU].entries.size() == 7
		and document.npcs[NPC_ZHOU].entries.size() == 7,
		"Each resident receives exactly one row per committed event")


func _test_observers() -> void:
	var document: Dictionary = _document()
	var applied: Dictionary = _apply(document, {
		"kind": Feed.KIND_HARVEST, "id": "cmd_harvest_player", "actor": PLAYER,
		"target": "field_1", "ok": true,
	})
	_expect(applied.ok and applied.written == 3,
		"An action by a player is observed by every resident")
	for npc_id: String in Roster.IDS:
		var row: Dictionary = _entry(document, npc_id, "cmd_harvest_player", applied)
		_expect(row.ok and int(row.entry.salience) == Feed.SALIENCE_OBSERVER,
			"Resident " + npc_id + " only observes another player's action")
		_expect(row.entry.kind == Memory.KIND_OBSERVATION,
			"A player action never becomes a factual row for a bystander")
	_expect(not (document.npcs as Dictionary).has(PLAYER),
		"The acting player is not turned into a resident")
	_expect(applied.entries.size() == 3, "One row per resident and no extra subject")
	for entry: Dictionary in applied.entries:
		_expect(entry.has("source_event_id") and entry.source_event_id == "cmd_harvest_player",
			"The returned row names its source event for the caller")
		_expect(not (document.npcs[entry.npc_id].entries as Dictionary)[entry.memory_id].has("source_event_id"),
			"The stored record keeps the fixed eight M10-01 fields")


func _test_rejections_and_anonymous() -> void:
	var document: Dictionary = _document()
	var before: Dictionary = document.duplicate(true)

	for bad_ok: Variant in [0, "yes", null]:
		var malformed: Dictionary = _apply(document, {
			"kind": Feed.KIND_HARVEST, "id": "cmd_failed", "actor": NPC_LIN,
			"target": "field_1", "ok": bad_ok,
		})
		_expect(not malformed.ok and malformed.reason == "invalid_ok",
			"A non-boolean result is refused as a malformed event")
	_expect(document == before, "Malformed events leave the document untouched")

	var rejected: Dictionary = _apply(document, {
		"kind": Feed.KIND_HARVEST, "id": "cmd_rejected", "actor": NPC_LIN,
		"target": "field_1", "ok": false,
	})
	_expect(rejected.ok and rejected.skipped == "not_committed"
		and rejected.written == 0 and rejected.entries.is_empty(),
		"A rejected world event is skipped without a memory")
	_expect(document == before, "A rejected event writes nothing")

	var anonymous: Dictionary = _apply(document, {
		"kind": Feed.KIND_HARVEST, "id": "cmd_anonymous", "actor": "",
		"target": "field_1", "ok": true,
	})
	_expect(anonymous.ok and anonymous.skipped == "anonymous_actor"
		and anonymous.written == 0 and anonymous.entries.is_empty(),
		"An empty actor is skipped rather than recorded as a person")
	_expect(document == before, "An anonymous event writes nothing")
	var omitted_actor: Dictionary = _apply(document, {
		"kind": Feed.KIND_HARVEST, "id": "cmd_anonymous_2", "target": "field_1", "ok": true,
	})
	_expect(omitted_actor.skipped == "anonymous_actor",
		"A missing actor is treated as anonymous")
	_expect(document == before, "An event without an actor writes nothing")
	var null_actor: Dictionary = _apply(document, {
		"kind": Feed.KIND_HARVEST, "id": "cmd_null_actor", "actor": null,
		"target": "field_1", "ok": true,
	})
	_expect(not null_actor.ok and null_actor.reason == "invalid_actor",
		"A non-string actor is a malformed event, not an anonymous one")
	_expect(document == before, "A malformed actor writes nothing")

	var bad_kind: Dictionary = _apply(document, {
		"kind": "earthquake", "id": "cmd_bad_kind", "actor": NPC_LIN, "target": "", "ok": true,
	})
	_expect(not bad_kind.ok and bad_kind.reason == "invalid_kind",
		"An unknown event kind is refused")
	var unknown_key: Dictionary = _apply(document, {
		"kind": Feed.KIND_HARVEST, "id": "cmd_extra", "actor": NPC_LIN,
		"target": "field_1", "ok": true, "cash": 10,
	})
	_expect(not unknown_key.ok and unknown_key.reason == "unknown_event_key",
		"An unknown event key is refused so no farm field can ride along")
	var missing_id: Dictionary = _apply(document, {
		"kind": Feed.KIND_HARVEST, "actor": NPC_LIN, "target": "field_1", "ok": true,
	})
	_expect(not missing_id.ok and missing_id.reason == "invalid_event",
		"An event without a command id is refused")
	var bad_id: Dictionary = _apply(document, {
		"kind": Feed.KIND_HARVEST, "id": "bad id", "actor": NPC_LIN, "target": "field_1",
		"ok": true,
	})
	_expect(not bad_id.ok and bad_id.reason == "invalid_event_id",
		"An event id outside the owner-id format is refused")
	_expect(document == before, "Every refused event leaves the document untouched")


func _test_replay() -> void:
	var document: Dictionary = _document()
	var event: Dictionary = {
		"kind": Feed.KIND_GIFT, "id": "cmd_replay", "actor": NPC_LIN,
		"target": NPC_XU, "ok": true,
	}
	var first: Dictionary = _apply(document, event)
	var after_first: Dictionary = document.duplicate(true)
	_expect(first.written == 3, "The first application writes every row")
	var second: Dictionary = _apply(document, event, START + DAY)
	_expect(second.ok and second.written == 0 and second.duplicates == 3,
		"A replay is reported as duplicates and writes nothing new")
	_expect(document == after_first,
		"Replaying the same event leaves the document byte-identical")
	for entry: Dictionary in second.entries:
		_expect(bool(entry.duplicate), "Each replayed row is marked duplicate")
	var different: Dictionary = _apply(document, {
		"kind": Feed.KIND_GIFT, "id": "cmd_other", "actor": NPC_LIN,
		"target": NPC_XU, "ok": true,
	}, START + DAY)
	_expect(different.written == 3 and document.npcs[NPC_LIN].entries.size() == 2,
		"A second event with the same content but another id is a distinct memory")

	# The same event id for a second subject uses a different memory id, because
	# the resident is part of the derived id.
	_expect(Feed.memory_id("cmd_replay", NPC_LIN) != Feed.memory_id("cmd_replay", NPC_XU),
		"One event can be remembered by several residents without an id clash")
	_expect(Feed.memory_id("cmd_replay", NPC_LIN) == Feed.memory_id("cmd_replay", NPC_LIN),
		"The memory id is deterministic")


func _test_sequence_and_determinism() -> void:
	var events: Array = [
		{"kind": Feed.KIND_SOW, "id": "cmd_seq_1", "actor": NPC_LIN, "target": "field_1", "ok": true},
		{"kind": Feed.KIND_WATER, "id": "cmd_seq_2", "actor": NPC_XU, "target": "field_1", "ok": true},
		{"kind": Feed.KIND_HARVEST, "id": "cmd_seq_3", "actor": NPC_ZHOU, "target": "field_1", "ok": false},
		{"kind": Feed.KIND_HARVEST, "id": "cmd_seq_4", "actor": NPC_ZHOU, "target": "field_1", "ok": true},
		{"kind": Feed.KIND_THEFT, "id": "cmd_seq_5", "actor": NPC_LIN, "target": NPC_ZHOU, "ok": true},
	]
	var context: Dictionary = _context(START + 100.0)
	var first_document: Dictionary = _document()
	var first: Dictionary = Feed.apply_sequence(first_document, events, context)
	_expect(first.ok and first.written == 12 and first.skipped == 1,
		"A sequence writes committed events and skips the rejected one")
	_expect((first_document.npcs[NPC_LIN].entries as Dictionary).size() == 4,
		"Only committed events become memories")
	var second_document: Dictionary = _document()
	var second: Dictionary = Feed.apply_sequence(second_document, events, context)
	_expect(second.ok and second_document == first_document,
		"Processing the same sequence twice yields the same document")

	# The rejected event has no memory for anyone.
	for npc_id: String in Roster.IDS:
		_expect(not (first_document.npcs[npc_id].entries as Dictionary).has(
			Feed.memory_id("cmd_seq_3", npc_id)),
			"A rejected event leaves no memory id behind")

	var bad_events: Array = [
		{"kind": Feed.KIND_SOW, "id": "cmd_ok", "actor": NPC_LIN, "target": "field_1", "ok": true},
		{"kind": Feed.KIND_SOW, "id": "cmd_bad", "actor": NPC_LIN, "target": "field_1"},
	]
	var untouched: Dictionary = _document()
	var before: Dictionary = untouched.duplicate(true)
	var refused: Dictionary = Feed.apply_sequence(untouched, bad_events, context)
	_expect(not refused.ok and refused.index == 1,
		"A malformed event in the batch reports its index")
	_expect(untouched == before, "A refused batch writes nothing at all")
	var not_array: Dictionary = Feed.apply_sequence(untouched, "events", context)
	_expect(not not_array.ok and not_array.reason == "invalid_events",
		"A non-array batch is refused")


func _test_capacity() -> void:
	var document: Dictionary = _document()
	var base: float = START + 200.0 * DAY
	var now: float = base
	var all_written: bool = true
	for index: int in 70:
		now = base + float(index) * 60.0
		var applied: Dictionary = _apply(document, {
			"kind": Feed.KIND_HARVEST, "id": "cmd_cap_%03d" % index, "actor": NPC_LIN,
			"target": "field_1", "ok": true,
		}, now)
		all_written = all_written and applied.written == 3
	_expect(all_written, "Every capacity event writes one row per resident")
	for npc_id: String in Roster.IDS:
		var row: Dictionary = document.npcs[npc_id]
		_expect(row.entries.size() == Memory.MAX_ENTRIES,
			"Resident " + npc_id + " never exceeds the M10-01 capacity")
		_expect(int(row.dropped) == 70 - Memory.MAX_ENTRIES,
			"Resident " + npc_id + " records one drop per evicted row")
	_expect(Memory.valid_document(document, now),
		"A full document still passes M10-01 validation")
	var total_rows: int = 0
	for npc_id: String in document.npcs.keys():
		total_rows += (document.npcs[npc_id].entries as Dictionary).size()
	_expect(total_rows == Memory.MAX_ENTRIES * Roster.IDS.size(),
		"Capacity is isolated per resident, so the document stays bounded")
	# cmd_cap_000 was evicted; the same id is no longer in the document, so a
	# replay appends and evicts again. That is M10-01's documented behaviour and
	# stays bounded.
	var replayed: Dictionary = _apply(document, {
		"kind": Feed.KIND_HARVEST, "id": "cmd_cap_000", "actor": NPC_LIN,
		"target": "field_1", "ok": true,
	}, now)
	_expect(replayed.ok and document.npcs[NPC_LIN].entries.size() == Memory.MAX_ENTRIES,
		"A replay after eviction stays within capacity")
	_expect(int(document.npcs[NPC_LIN].dropped) == 70 - Memory.MAX_ENTRIES + 1,
		"An evicted replay increments the drop counter once")
	_expect(Memory.valid_document(document, now),
		"The document remains valid after an evicted replay")


func _test_round_trip() -> void:
	var now: float = START + 10.0
	var document: Dictionary = _document()
	_apply(document, {
		"kind": Feed.KIND_GIFT, "id": "cmd_rt_1", "actor": NPC_LIN,
		"target": NPC_XU, "ok": true,
	}, now)
	var encoded: Dictionary = Memory.to_json(document, now)
	_expect(encoded.ok, "A feed document serializes through M10-01")
	var decoded: Dictionary = Memory.from_json(encoded.json, now)
	_expect(decoded.ok and decoded.document == document,
		"A feed document round-trips through M10-01 JSON")
	var later: float = now + DAY
	var restored: Dictionary = decoded.document
	_apply(restored, {
		"kind": Feed.KIND_THEFT, "id": "cmd_rt_2", "actor": NPC_ZHOU,
		"target": NPC_LIN, "ok": true,
	}, later)
	var direct: Dictionary = document.duplicate(true)
	_apply(direct, {
		"kind": Feed.KIND_THEFT, "id": "cmd_rt_2", "actor": NPC_ZHOU,
		"target": NPC_LIN, "ok": true,
	}, later)
	_expect(restored == direct,
		"Writing after a JSON restore yields the same document")


func _test_boundaries() -> void:
	var document: Dictionary = _document()
	var before: Dictionary = document.duplicate(true)
	var other_roster: Dictionary = Roster.build(OTHER_WORLD, SEED).roster
	var cross_world: Dictionary = Feed.apply(document, {
		"kind": Feed.KIND_GIFT, "id": "cmd_world", "actor": NPC_LIN,
		"target": NPC_XU, "ok": true,
	}, {"now_utc": START, "world_id": OTHER_WORLD, "roster": other_roster})
	_expect(not cross_world.ok and cross_world.reason == "world_mismatch",
		"An event for another world is refused")
	_expect(document == before, "A cross-world event writes nothing")

	var mismatched_roster: Dictionary = Feed.apply(document, {
		"kind": Feed.KIND_GIFT, "id": "cmd_roster", "actor": NPC_LIN,
		"target": NPC_XU, "ok": true,
	}, {"now_utc": START, "world_id": WORLD, "roster": other_roster})
	_expect(not mismatched_roster.ok and mismatched_roster.reason == "roster_world_mismatch",
		"A roster from another world is refused")
	for bad_context: Variant in [{}, [], {"now_utc": START, "world_id": WORLD},
			{"now_utc": -1.0, "world_id": WORLD, "roster": roster},
			{"now_utc": START, "world_id": "bad world", "roster": roster},
			{"now_utc": START, "world_id": WORLD, "roster": {"npcs": []}},
			{"now_utc": START, "world_id": WORLD, "roster": roster, "extra": 1}]:
		var checked: Dictionary = Feed.apply(document, {}, bad_context)
		_expect(not checked.ok, "A malformed context is refused")
	_expect(document == before, "No malformed context writes a row")

	var missing_document: Dictionary = Feed.apply({}, {
		"kind": Feed.KIND_GIFT, "id": "cmd_doc", "actor": NPC_LIN,
		"target": NPC_XU, "ok": true,
	}, _context(START))
	_expect(not missing_document.ok and missing_document.reason == "invalid_document",
		"The feed cannot write into an unvalidated document")

	# A roster that lacks the actor cannot create a subject for them.
	var short_roster: Dictionary = roster.duplicate(true)
	(short_roster.npcs as Dictionary).erase(NPC_LIN)
	var short_document: Dictionary = _document()
	var short_applied: Dictionary = Feed.apply(short_document, {
		"kind": Feed.KIND_GIFT, "id": "cmd_short", "actor": NPC_LIN,
		"target": NPC_XU, "ok": true,
	}, {"now_utc": START, "world_id": WORLD, "roster": short_roster})
	_expect(short_applied.ok, "An event naming a resident outside the roster is accepted")
	_expect(not (short_document.npcs as Dictionary).has(NPC_LIN),
		"A resident absent from the roster never receives a memory")
	_expect(short_applied.written == 2,
		"Only the residents present in the roster observe the event")


func _document() -> Dictionary:
	return Memory.create(WORLD).document


func _context(now_utc: float) -> Dictionary:
	return {"now_utc": now_utc, "world_id": WORLD, "roster": roster}


func _apply(document: Dictionary, projection: Dictionary,
		now_utc: float = START) -> Dictionary:
	return Feed.apply(document, projection, _context(now_utc))


## The applied result reports the memory id it derived, so the test reads the
## stored row through the same id the production path wrote.
func _entry(document: Dictionary, npc_id: String, event_id: String,
		applied: Dictionary) -> Dictionary:
	var found: Dictionary = {}
	for row: Dictionary in applied.get("entries", []):
		if str(row.npc_id) == npc_id and str(row.source_event_id) == event_id:
			found = row
			break
	if found.is_empty():
		return {"ok": false, "entry": {}}
	var entries: Variant = document.npcs.get(npc_id, {}).get("entries", {})
	if not entries is Dictionary or not (entries as Dictionary).has(found.memory_id):
		return {"ok": false, "entry": {}}
	return {"ok": true, "entry": entries[found.memory_id]}


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
