extends RefCounted
## The sole mutable owner of planting state. No scene, clock reading or disk I/O.
##
## M6-02 adds one bounded environment input: an injected natural source that
## answers `weather_at(utc_seconds)` with the same 6-hour block shape
## NatureState owns. M6-03 optionally also calls `disaster_at(utc_seconds)`;
## an older source without that method simply contributes no disaster layer.
## FarmState never reads a global, a store or the system clock; the session
## (HeadlessWorld) passes its NatureState in. Without an injected source the
## additive pre-environment rules apply unchanged.

const Trellis=preload("res://layout/trellis_slots.gd")
const Crops = preload("res://farm/crop_catalog.gd")
const Plan = preload("res://layout/courtyard_plan.gd")
const Neighbors = preload("res://farm/neighbor_catalog.gd")
const Kitchen = preload("res://farm/kitchen.gd")
const Companions = preload("res://farm/animal_companions.gd")
const Memories = preload("res://farm/garden_memories.gd")
const Seasons = preload("res://farm/season_catalog.gd")
const Buildings = preload("res://farm/building_catalog.gd")
const FIELD_IDS: Array[String] = Plan.FIELD_IDS
# Row-major: columns run along +X and rows along +Z in the presentation layer.
const CELL_IDS: Array[String] = ["cell_01", "cell_02", "cell_03", "cell_04", "cell_05", "cell_06", "cell_07", "cell_08", "cell_09", "cell_10", "cell_11", "cell_12", "cell_13", "cell_14", "cell_15", "cell_16"]
# JSON numbers remain exact only up to this bound.
const MAX_HARVEST_COUNT: int = 9007199254740991
# One gift moves at most this many baskets of a single crop. Keeping it small
# also bounds one command's effect when replaying on a client.
const MAX_GIFT: int = 99
# Opt-in theft: at most this many baskets may leave one owner's cells in one UTC
# day, and the same neighbour cannot take from that owner again before the
# cooldown elapses. Both are decided in the same commit as the harvest, so a
# refusal never leaves a half-applied loss behind.
const MAX_THEFT_PER_DAY: int = 3
const THEFT_COOLDOWN_SECONDS: float = 600.0
# A durable idempotency window, not an audit log: recent command results travel
# with the state so a restarted world answers a retried id from the committed
# transaction instead of re-deriving it from cell state.
const MAX_COMMAND_RESULTS: int = 64
const MAX_COMMAND_ID_LENGTH: int = 128
const MAX_COMMAND_PAYLOAD_LENGTH: int = 512
# M6-02 limited environment. One persisted soil-moisture value per cell; the
# weather itself stays owned by NatureState and is only queried by settlement.
# Moisture changes once per completed 6-hour weather block, so a split inside a
# block cannot change the result. Growth factors are 1 or 1/2, so whole-second
# segments (the only real ones) sum to the same exact value however they split.
const MOISTURE_MAX: float = 1.0
const MOISTURE_DEFAULT: float = 0.5
const MOISTURE_WET: float = 0.75
const MOISTURE_GROWTH_THRESHOLD: float = 0.5
const RAIN_MOISTURE_GAIN: float = 0.25
const CLOUDY_MOISTURE_LOSS: float = 0.0625
const CLEAR_MOISTURE_LOSS: float = 0.125
# M6-03 gentle mode: a disaster only shifts moisture on top of the weather
# delta of the same completed block. It never touches crops, yield, bags,
# inventory or buildings, and severity is display metadata, not a multiplier.
const DROUGHT_MOISTURE_LOSS: float = 0.125
const STORM_MOISTURE_GAIN: float = 0.25
const GROWTH_FACTOR_NORMAL: float = 1.0
const GROWTH_FACTOR_DRY: float = 0.5
# The provider contract guarantees 6-hour blocks that advance; this bound only
# stops a malformed provider from looping forever. Years offline stay far below.
const MAX_WEATHER_BLOCKS_PER_SETTLE: int = 1000000

var _data: Dictionary
var _environment: RefCounted = null


func _init(now_utc_seconds: float = 0.0, layout: Dictionary = {}, environment: RefCounted = null) -> void:
	assert(_valid_time(now_utc_seconds), "Farm initialization requires finite nonnegative UTC seconds")
	var plan: RefCounted = Plan.new() if layout.is_empty() else Plan.from_snapshot(layout)
	assert(plan != null, "Farm initialization requires a valid layout")
	_environment = environment
	_data = {"fields": {}, "harvested": {}, "inventory":{}, "bags":{}, "theft":{}, "buildings":{}, "neighbors":Neighbors.initial_state(), "layout":plan.snapshot(), "kitchen":Kitchen.initial_state(),"animals":Companions.initial_state(),"memories":Memories.initial_state(),"season":"daily","transaction":{"sequence":0,"command_results":{}}}
	Companions.include_flocks(_data.animals,plan.construction.flocks)
	for crop_id: String in Crops.crop_ids():
		_data.harvested[crop_id] = 0
		_data.inventory[crop_id] = 0
	for definition: Dictionary in _planting_areas(plan):
		var field_id: String = definition.id
		_data.fields[field_id] = {"cells": {}}
		for cell_id: String in definition.cells:
			_data.fields[field_id].cells[cell_id] = _empty_cell(now_utc_seconds)
	_set_initial_crop("field_03", "greens", 1.0)
	_set_initial_crop("field_04", "greens", 0.2)
	_set_initial_crop("field_05", "radish", 0.1)
	_set_initial_crop("field_06", "radish", 0.6)
	# A small optional corner, not a recurring chore or a gate on the whole garden.
	for id: String in ["cell_11","cell_12","cell_13","cell_14","cell_15","cell_16"]:
		if _data.fields.has("field_06") and _data.fields.field_06.cells.has(id):
			_data.fields.field_06.cells[id].ground = "rough" if id in ["cell_11","cell_12"] else "weedy"


func snapshot() -> Dictionary:
	return _data.duplicate(true)

func copy() -> RefCounted:
	# This owner's state has already passed admission or gameplay rules. Copy
	# it privately for a transaction; external snapshots still use restore.
	var result: RefCounted=new()
	result._data=_data.duplicate(true)
	# The environment owner is read-only weather, not player state. A candidate
	# must resolve the same blocks for its own settlement.
	result._environment=_environment
	return result


## Injects the natural source. The session owns NatureState and passes it here;
## FarmState only calls `weather_at(utc_seconds)` and, when available,
## `disaster_at(utc_seconds)`, and never reads a global, system clock or store.
## Passing null restores the pre-M6-02 additive rules.
func set_environment(environment: RefCounted) -> void:
	_environment = environment


func accept(candidate: RefCounted) -> void:
	# A transaction built by this state owner already obeys the schema. Keep the
	# live owner's identity for editors, and isolate it from later candidate edits.
	assert(candidate.get_script() == get_script())
	_data = candidate._data.duplicate(true)


func command_result(command_id: String) -> Dictionary:
	# Returns {payload, result} for a durable command id, or {} when unknown.
	var entry: Variant = _data.transaction.command_results.get(command_id)
	return entry.duplicate(true) if entry is Dictionary else {}


func commit_command(command_id: String, payload: String, result: Dictionary) -> bool:
	# The candidate records its own command result before any write, so resource
	# changes, the result and the event sequence are one persisted snapshot.
	# Only accepted actions enter the ledger; failures stay re-derivable.
	if command_id.is_empty() or command_id.length() > MAX_COMMAND_ID_LENGTH:
		return false
	var outcome: Variant = result.get("ok")
	if payload.length() > MAX_COMMAND_PAYLOAD_LENGTH or not outcome is bool or not outcome:
		return false
	var results: Dictionary = _data.transaction.command_results
	# Re-committing the same id is not a second event.
	if not results.has(command_id):
		_data.transaction.sequence = int(_data.transaction.sequence) + 1
	results[command_id] = {"payload": payload, "result": _command_result_record(result)}
	while results.size() > MAX_COMMAND_RESULTS:
		results.erase(results.keys()[0])
	return true


static func _command_result_record(result: Dictionary) -> Dictionary:
	# A fixed, JSON-stable replay record. Extra rule details stay out of storage
	# so the ledger cannot grow arbitrary nested payloads.
	var changed: Array[String] = []
	var visual: Array[String] = []
	for value: Variant in result.get("changed_fields", []):
		if value is String: changed.append(value)
	for value: Variant in result.get("visual_changed", []):
		if value is String: visual.append(value)
	return {
		"ok": bool(result.get("ok", false)),
		"reason": str(result.get("reason", "")),
		"changed_fields": changed,
		"visual_changed": visual,
		"reward_crop_id": str(result.get("reward_crop_id", "")),
		"reward_amount": int(result.get("reward_amount", 0)),
	}


func event_sequence() -> int:
	return int(_data.transaction.sequence)


func committed_command_count() -> int:
	return _data.transaction.command_results.size()


func hud_state() -> Dictionary:
	return {"harvested": _data.harvested.duplicate(), "inventory": _data.inventory.duplicate()}


func bag(player_id: String) -> Dictionary:
	# Every crop is present so consumers never have to distinguish "zero" from
	# "missing"; an unknown player simply has nothing yet.
	var result: Dictionary = {}
	for crop_id: String in Crops.crop_ids():
		result[crop_id] = 0
	var stored: Variant = _data.bags.get(player_id)
	if stored is Dictionary:
		for crop_id: Variant in stored:
			if result.has(crop_id): result[crop_id] = int(stored[crop_id])
	return result

func owner_of(field_id: String, cell_id: String) -> String:
	# Empty means nobody planted it here (an initial crop, an old snapshot or
	# anonymous work): such a cell is free for anyone, exactly as before.
	return str(get_cell(field_id, cell_id).get("planted_by", ""))


func building_state(slot_id: String, now_utc: float) -> String:
	# Construction is decided by comparing timestamps; no timer or settle pass.
	var record: Variant = _data.buildings.get(slot_id)
	if not record is Dictionary:
		return "empty"
	return "done" if now_utc >= float(record.done_utc) else "building"


func buildings_at(now_utc: float) -> Dictionary:
	var result: Dictionary = {}
	for slot_id: String in _data.buildings:
		var record: Dictionary = _data.buildings[slot_id]
		var blueprint_id: String = str(record.blueprint)
		result[slot_id] = {
			"blueprint": blueprint_id,
			"name": str(Buildings.definition(blueprint_id).get("name", "")),
			"owner": str(record.owner),
			"started_utc": float(record.started_utc),
			"done_utc": float(record.done_utc),
			"state": building_state(slot_id, now_utc),
		}
	return result


func build(slot_id: String, blueprint_id: String, now_utc: float, actor: String) -> Dictionary:
	# The builder owns the house; there is no material ledger in this slice.
	# Every refusal happens before the first write, so failures are atomic.
	if not _valid_time(now_utc):
		return _result(false, "invalid_time")
	if not _valid_player_id(actor):
		return _result(false, "invalid_player")
	if slot_id not in Buildings.SLOTS:
		return _result(false, "invalid_slot")
	var blueprint: Dictionary = Buildings.definition(blueprint_id)
	if blueprint.is_empty():
		return _result(false, "invalid_blueprint")
	if _data.buildings.has(slot_id):
		return _result(false, "occupied")
	var done_utc: float = now_utc + float(blueprint.build_seconds)
	if not is_finite(done_utc):
		# A finish time the snapshot cannot store must not enter the live state.
		return _result(false, "invalid_time")
	_data.buildings[slot_id] = {
		"blueprint": blueprint_id,
		"owner": actor,
		"started_utc": now_utc,
		"done_utc": done_utc,
	}
	return _result(true, "")


func demolish(slot_id: String, now_utc: float, actor: String) -> Dictionary:
	# Only the owner may remove the house, whether it is still building or done.
	if not _valid_time(now_utc):
		return _result(false, "invalid_time")
	if not _valid_player_id(actor):
		return _result(false, "invalid_player")
	if slot_id not in Buildings.SLOTS:
		return _result(false, "invalid_slot")
	var record: Variant = _data.buildings.get(slot_id)
	if not record is Dictionary:
		return _result(false, "empty")
	if str(record.owner) != actor:
		return _result(false, "not_owner")
	_data.buildings.erase(slot_id)
	return _result(true, "")


func theft_enabled(player_id: String) -> bool:
	var record: Variant = _data.theft.get(player_id)
	return record is Dictionary and bool(record.get("enabled", false))


func set_theft(player_id: String, enabled: bool) -> Dictionary:
	# The caller passes the actor resolved from the connection, so a member can
	# only change their own standing, never someone else's.
	if not _valid_player_id(player_id):
		return _result(false, "invalid_player")
	_theft_record(_data, player_id).enabled = enabled
	return _result(true, "")


func set_season(id: String) -> bool:
	if not Seasons.valid(id): return false
	_data.season = id
	return true

func field_ids() -> Array[String]:
	# Ground-bed consumers use this list; the separate trellis view uses FIELD_ID.
	var result: Array[String] = []
	for field: Dictionary in _data.layout.fields: result.append(field.id)
	return result

func cell_ids(field_id: String) -> Array[String]:
	var result: Array[String] = []
	if field_id==Trellis.FIELD_ID:
		result.assign(_data.fields[field_id].cells.keys());return result
	for field: Dictionary in _data.layout.fields:
		if field.id == field_id: result.assign(field.cells)
	return result

func trellis_retains_crops(plan: RefCounted) -> bool:
	var slots: Dictionary=Trellis.slots(plan)
	for id: String in _data.fields[Trellis.FIELD_ID].cells:
		if not slots.has(id) and not _data.fields[Trellis.FIELD_ID].cells[id].crop_id.is_empty(): return false
	return true

func apply_layout(layout: Dictionary, now_utc_seconds: float) -> Dictionary:
	if not _valid_time(now_utc_seconds): return _result(false,"invalid_time")
	var plan: RefCounted = Plan.from_snapshot(layout)
	if plan == null: return _result(false,"invalid_layout")
	var candidate: Dictionary = _data.duplicate(true)
	var fields: Dictionary = {}
	for definition: Dictionary in _planting_areas(plan):
		var previous: Dictionary = _data.fields.get(definition.id,{}).get("cells",{})
		var cells: Dictionary = {}
		for id: String in definition.cells:
			cells[id] = previous[id].duplicate(true) if previous.has(id) else _empty_cell(now_utc_seconds)
		fields[definition.id] = {"cells":cells}
	# A resize/removal may not erase an occupied cell. No partial change or time
	# advancement on rejection; the editor can ask the player to harvest first.
	for field_id: String in _data.fields:
		for cell_id: String in _data.fields[field_id].cells:
			if not _data.fields[field_id].cells[cell_id].crop_id.is_empty() and not fields.get(field_id,{}).get("cells",{}).has(cell_id):
				return _result(false,"occupied_cell_removed")
	candidate.fields = fields
	candidate.layout = plan.snapshot()
	Companions.include_flocks(candidate.animals,plan.construction.flocks)
	if candidate.layout!=_data.layout: Memories.mark(candidate.memories,"arrange",now_utc_seconds)
	var changed: Array[String] = _settle_data(candidate,now_utc_seconds)
	_data = candidate
	return _result(true,"",changed)


func restore_snapshot(data: Dictionary) -> bool:
	# Disk format/version and recovery remain the storage boundary's responsibility.
	# Check the entire candidate before changing any authoritative field.
	if not _valid_snapshot(data):
		return false
	_data = data.duplicate(true)
	_data.layout = Plan.from_snapshot(data.layout).snapshot()
	for id: String in _data.animals:
		for field: String in ["preference","visits","shared","revision"]: _data.animals[id][field]=int(_data.animals[id][field])
	# A snapshot written before bags existed restores as an empty table; the
	# canonical form always carries the key from here on.
	if not _data.has("bags"): _data.bags = {}
	# A world saved before theft existed starts with theft off for everyone.
	if not _data.has("theft"): _data.theft = {}
	# A document written before housing existed has no buildings and starts empty.
	if not _data.has("buildings"): _data.buildings = {}
	for player_id: String in _data.bags:
		for crop_id: String in _data.bags[player_id]:
			_data.bags[player_id][crop_id] = int(_data.bags[player_id][crop_id])
	for player_id: String in _data.theft:
		var record: Dictionary = _data.theft[player_id]
		record.day = int(record.day)
		record.lost = int(record.lost)
		for thief: String in record.last:
			record.last[thief] = float(record.last[thief])
	for slot_id: String in _data.buildings:
		var building: Dictionary = _data.buildings[slot_id]
		building.started_utc = float(building.started_utc)
		building.done_utc = float(building.done_utc)
	# Canonical cells carry ownership and moisture. A v27 cell may have neither;
	# it restores as nobody's and with the default soil moisture instead of
	# failing the current format. No migration branch is added.
	for field_id: String in _data.fields:
		for cell_id: String in _data.fields[field_id].cells:
			var cell: Dictionary = _data.fields[field_id].cells[cell_id]
			if not cell.has("planted_by"):
				cell.planted_by = ""
			if not cell.has("moisture"):
				cell.moisture = MOISTURE_DEFAULT
			cell.moisture = clampf(float(cell.moisture), 0.0, MOISTURE_MAX)
	for crop_id: String in Crops.crop_ids():
		_data.harvested[crop_id] = int(_data.harvested[crop_id])
		_data.inventory[crop_id] = int(_data.inventory[crop_id])
	for id: String in Neighbors.IDS: _data.neighbors[id].round=int(_data.neighbors[id].round)
	_data.kitchen.revision = int(_data.kitchen.revision)
	_data.transaction.sequence = int(_data.transaction.sequence)
	for id: String in _data.transaction.command_results:
		_data.transaction.command_results[id].result.reward_amount = int(_data.transaction.command_results[id].result.reward_amount)
	for recipe: String in Kitchen.RECIPES:
		_data.kitchen.stock[recipe] = int(_data.kitchen.stock[recipe])
		_data.kitchen.records[recipe].made = int(_data.kitchen.records[recipe].made)
		_data.kitchen.records[recipe].shared = int(_data.kitchen.records[recipe].shared)
	for station: String in Kitchen.STATIONS:
		var job: Dictionary = _data.kitchen.jobs[station]
		if not job.is_empty():
			job.start_utc = float(job.start_utc)
			job.finish_utc = float(job.finish_utc)
	return true

func share_basket(neighbor: String, round_index: int, basket: Dictionary) -> Dictionary:
	if neighbor not in Neighbors.IDS: return _result(false,"invalid_neighbor")
	var visit: Dictionary = _data.neighbors[neighbor]
	if visit.round!=round_index or visit.pending: return _result(false,"stale_visit")
	if round_index>=2147483646: return _result(false,"inventory_limit")
	var needed: int = Neighbors.wish(neighbor,round_index).amount
	var amount: int = 0
	for crop: Variant in basket:
		if not crop is String or not Neighbors.accepts(neighbor,round_index,crop): return _result(false,"wrong_crop")
		var count: Variant = basket[crop]
		if not _is_number(count) or count<=0 or count>needed or floorf(count)!=count: return _result(false,"invalid_amount")
		if _data.inventory[crop]<count: return _result(false,"insufficient_food")
		amount+=int(count)
	if amount!=needed: return _result(false,"incomplete_basket")
	for crop: String in basket: _data.inventory[crop]-=int(basket[crop])
	visit.pending=true
	return _result(true,"")

func kitchen_action(action: String, request: Dictionary, revision: int, now: float,decorations: Dictionary={}) -> Dictionary:
	return Kitchen.act(_data.kitchen,_data.inventory,action,request,revision,now,decorations)

func animal_action(id: String,action: String,value: Variant,revision: int) -> Dictionary:
	return Companions.act(_data.animals,_data.inventory,id,action,value,revision)

func remember(id: String, now: float) -> bool:
	return Memories.mark(_data.memories,id,now)

func photo_action(action: String, photo: Dictionary) -> bool:
	return Memories.photo_action(_data.memories,action,photo)

func claim_gift(neighbor: String, round_index: int, crop: String) -> Dictionary:
	if neighbor not in Neighbors.IDS: return _result(false,"invalid_neighbor")
	var visit: Dictionary = _data.neighbors[neighbor]
	if visit.round!=round_index or not visit.pending: return _result(false,"stale_visit")
	if crop not in Neighbors.HOMES[neighbor].gifts: return _result(false,"invalid_gift")
	if _data.inventory[crop]>=MAX_HARVEST_COUNT or round_index>=2147483646: return _result(false,"inventory_limit")
	_data.inventory[crop]+=1
	visit.pending=false
	visit.round+=1
	visit.last_gift=crop
	return _result(true,"")


func get_field(field_id: String) -> Dictionary:
	if not _data.fields.has(field_id):
		return {}
	var field: Dictionary = {"id": field_id, "cells": {}}
	for cell_id: String in cell_ids(field_id):
		field.cells[cell_id] = get_cell(field_id, cell_id)
	return field


func get_cell(field_id: String, cell_id: String) -> Dictionary:
	if not _data.fields.has(field_id) or not _data.fields[field_id].cells.has(cell_id):
		return {}
	var cell: Dictionary = _data.fields[field_id].cells[cell_id].duplicate(true)
	cell["id"] = cell_id
	cell["field_id"] = field_id
	cell["progress"] = 0.0
	cell["remaining_seconds"] = 0.0
	cell["stage"] = "empty"
	# A player-facing explanation of the environment: stored moisture, its
	# label, and the growth factor the last settled weather block applies.
	cell["moisture"] = float(cell.get("moisture", MOISTURE_DEFAULT))
	cell["moisture_label"] = moisture_label(cell.moisture)
	cell["growth_rate"] = _view_growth_rate(cell)
	if not cell.crop_id.is_empty():
		var duration: float = Crops.definition(cell.crop_id).duration_seconds
		cell.progress = cell.growth_seconds / duration
		cell.remaining_seconds = duration - cell.growth_seconds
		cell.stage = "mature" if cell.progress >= 1.0 else ("young" if cell.progress >= Crops.YOUNG_PROGRESS else "sprout")
	return cell


func settle(now_utc_seconds: float) -> Dictionary:
	if not _valid_time(now_utc_seconds):
		return _result(false, "invalid_time")
	var visual_changes: Array[String] = []
	var changed: Array[String] = _settle_data(_data, now_utc_seconds, visual_changes)
	var result: Dictionary = _result(true, "", changed)
	result.visual_changed = visual_changes
	return result


func sow(field_id: String, cell_id: String, crop_id: String, now_utc_seconds: float, actor: String = "") -> Dictionary:
	if Crops.definition(crop_id).is_empty():
		return _result(false, "invalid_crop")
	# A named sower owns what grows there; anonymous work belongs to nobody, so
	# a solo game and a headless command keep the old free-for-all.
	return _act("sow", field_id, cell_id, crop_id, now_utc_seconds, actor)


func mature_all_crops(now_utc_seconds: float) -> Dictionary:
	if not _valid_time(now_utc_seconds): return _result(false, "invalid_time")
	var changed: Array[String] = _settle_data(_data, now_utc_seconds)
	for field_id: String in _data.fields:
		for cell: Dictionary in _data.fields[field_id].cells.values():
			if cell.crop_id.is_empty(): continue
			cell.growth_seconds = Crops.definition(cell.crop_id).duration_seconds
			if not changed.has(field_id): changed.append(field_id)
	return _result(true, "", changed)


func water(field_id: String, cell_id: String, now_utc_seconds: float) -> Dictionary:
	return _act("water", field_id, cell_id, "", now_utc_seconds)


func harvest(field_id: String, cell_id: String, now_utc_seconds: float, actor: String = "", authorized: bool = false) -> Dictionary:
	# A named actor takes the basket into their own bag. Anonymous play (single
	# player, headless commands, members without a player id) keeps using the
	# shared inventory, so existing behaviour is unchanged. `authorized` is the
	# owner's grant: work the owner explicitly allowed is not theft.
	return _act("harvest", field_id, cell_id, "", now_utc_seconds, actor, authorized)


func gift(from_id: String, to_id: String, crop_id: String, amount: Variant) -> Dictionary:
	# Sender and recipient change in one assignment to the authoritative data:
	# there is no state in which the sender paid but the recipient did not receive.
	if not _valid_player_id(from_id) or not _valid_player_id(to_id) or from_id == to_id:
		return _result(false, "invalid_player")
	if Crops.definition(crop_id).is_empty():
		return _result(false, "invalid_crop")
	if not _is_number(amount) or floorf(float(amount)) != float(amount) \
			or float(amount) < 1.0 or float(amount) > float(MAX_GIFT):
		return _result(false, "invalid_amount")
	var count: int = int(amount)
	if _bag_amount(_data.bags, from_id, crop_id) < count:
		return _result(false, "insufficient")
	if _bag_amount(_data.bags, to_id, crop_id) > MAX_HARVEST_COUNT - count:
		return _result(false, "inventory_limit")
	_add_to_bag(_data.bags, from_id, crop_id, -count)
	_add_to_bag(_data.bags, to_id, crop_id, count)
	return _result(true, "")


func tidy(action: String, field_id: String, cell_id: String, now: float) -> Dictionary:
	if action not in ["weed","till"]: return _result(false,"invalid_tool")
	return _act(action,field_id,cell_id,"",now)


func _act(action: String, field_id: String, cell_id: String, crop_id: String, now_utc_seconds: float, actor: String = "", authorized: bool = false) -> Dictionary:
	if not _valid_time(now_utc_seconds):
		return _result(false, "invalid_time")
	if not _data.fields.has(field_id):
		return _result(false, "invalid_field")
	if not _data.fields[field_id].cells.has(cell_id):
		return _result(false, "invalid_cell")
	# Failed actions are atomic no-ops, including time. Periodic settle() is independent.
	var candidate: Dictionary = _data.duplicate(true)
	var visual_changes: Array[String] = []
	var changed: Array[String] = _settle_data(candidate, now_utc_seconds, visual_changes)
	var field: Dictionary = candidate.fields[field_id].cells[cell_id]
	var reward_crop: String = ""
	if action in ["weed","till"]:
		if not field.crop_id.is_empty(): return _result(false,"occupied")
		if field.ground != ("weedy" if action=="weed" else "rough"):
			return _result(false,"wrong_ground")
		field.ground = "rough" if action=="weed" else "ready"
	elif action == "sow":
		if not Crops.supports(crop_id,field_id==Trellis.FIELD_ID): return _result(false,"wrong_support")
		if field.ground != "ready": return _result(false,"unprepared")
		if not field.crop_id.is_empty():
			return _result(false, "occupied")
		if not actor.is_empty() and not _valid_player_id(actor):
			return _result(false, "invalid_player")
		field.crop_id = crop_id
		field.planted_by = actor
	elif field.crop_id.is_empty():
		return _result(false, "empty")
	else:
		var duration: float = Crops.definition(field.crop_id).duration_seconds
		if action == "water":
			if field.growth_seconds >= duration:
				return _result(false, "mature")
			if field.watered:
				return _result(false, "already_watered")
			field.growth_seconds = minf(duration, field.growth_seconds + duration * Crops.definition(field.crop_id).water_progress)
			field.watered = true
			# Local irrigation saturates this cell; the surrounding weather
			# still drains it at the next completed blocks.
			field.moisture = MOISTURE_MAX
		else:
			if field.growth_seconds < duration:
				return _result(false, "not_mature")
			reward_crop = field.crop_id
			var into_bag: bool = not actor.is_empty()
			if into_bag and not _valid_player_id(actor):
				return _result(false, "invalid_player")
			# Taking from someone else's cell is theft unless the owner granted
			# this actor the harvest. A thief without a player id could not be
			# cooled down or counted, so it is refused like an unconsenting owner.
			var owner: String = str(field.get("planted_by", ""))
			var stealing: bool = not owner.is_empty() and owner != actor and not authorized
			var theft_record: Dictionary = {}
			if stealing:
				if not into_bag or not theft_enabled(owner):
					# Distinct from demolition's `not_owner`: the player needs to
					# hear that the owner has not opened theft, not who owns what.
					return _result(false, "theft_disabled")
				theft_record = _theft_record(candidate, owner)
				var day: int = _day_index(now_utc_seconds)
				if int(theft_record.day) != day:
					theft_record.day = day
					theft_record.lost = 0
					theft_record.last = {}
				if int(theft_record.lost) >= MAX_THEFT_PER_DAY:
					return _result(false, "theft_limit")
				if now_utc_seconds - float(theft_record.last.get(actor, -1.0e12)) < THEFT_COOLDOWN_SECONDS:
					return _result(false, "theft_cooldown")
			# The limit applies to the cell that is actually credited: the actor's
			# bag when named, the shared inventory otherwise.
			var credited: int = _bag_amount(candidate.bags, actor, reward_crop) if into_bag else int(candidate.inventory[reward_crop])
			if candidate.harvested[reward_crop] >= MAX_HARVEST_COUNT or credited >= MAX_HARVEST_COUNT:
				return _result(false, "harvest_limit")
			candidate.harvested[reward_crop] += 1
			if into_bag:
				_add_to_bag(candidate.bags, actor, reward_crop, 1)
			else:
				candidate.inventory[reward_crop] += 1
			if stealing:
				# Booked on the owner's record in the same candidate that is about
				# to be committed, so a refused harvest never counts as a loss.
				theft_record.lost = int(theft_record.lost) + 1
				theft_record.last[actor] = now_utc_seconds
			var emptied: Dictionary = _empty_cell(field.last_settled_utc_seconds)
			# Harvesting does not irrigate: the soil keeps the moisture the
			# weather left in it rather than resetting to the new-cell default.
			emptied.moisture = clampf(float(field.get("moisture", MOISTURE_DEFAULT)), 0.0, MOISTURE_MAX)
			candidate.fields[field_id].cells[cell_id] = emptied
	if not changed.has(field_id):
		changed.append(field_id)
	_data = candidate
	if not visual_changes.has(field_id): visual_changes.append(field_id)
	var result: Dictionary = _result(true, "", changed, reward_crop)
	result.visual_changed = visual_changes
	return result


func _settle_data(data: Dictionary, now_utc_seconds: float, visual_changes: Array[String] = []) -> Array[String]:
	var changed: Array[String] = []
	var use_environment: bool = _environment != null
	for field_id: String in data.fields:
		for cell_id: String in data.fields[field_id].cells:
			var cell: Dictionary = data.fields[field_id].cells[cell_id]
			if now_utc_seconds <= cell.last_settled_utc_seconds:
				continue
			var baseline: float = float(cell.last_settled_utc_seconds)
			if use_environment:
				_settle_cell_environment(cell, baseline, now_utc_seconds, visual_changes, field_id)
			else:
				_settle_cell_elapsed(cell, baseline, now_utc_seconds, visual_changes, field_id)
			# Empty and mature cells also keep their latest rollback-safe baseline.
			cell.last_settled_utc_seconds = now_utc_seconds
			if not changed.has(field_id):
				changed.append(field_id)
	return changed


func _settle_cell_elapsed(cell: Dictionary, baseline: float, now_utc_seconds: float,
		visual_changes: Array[String], field_id: String) -> void:
	# The pre-environment rule: elapsed UTC seconds become growth directly.
	var elapsed: float = now_utc_seconds - baseline
	if not cell.crop_id.is_empty():
		var duration: float = Crops.definition(cell.crop_id).duration_seconds
		var before: int = _stage_rank(float(cell.growth_seconds), duration)
		cell.growth_seconds = minf(duration, cell.growth_seconds + elapsed)
		var after: int = _stage_rank(float(cell.growth_seconds), duration)
		if before != after and not visual_changes.has(field_id):
			visual_changes.append(field_id)


func _settle_cell_environment(cell: Dictionary, baseline: float, now_utc_seconds: float,
		visual_changes: Array[String], field_id: String) -> void:
	# Weather blocks tile the interval, so each segment has one kind and one
	# growth factor. Moisture changes only when a block completes, at an
	# absolute UTC boundary shared by every settlement path. Growth factors are
	# 1 or 1/2, so whole-second segments sum to the same exact value however the
	# caller splits the interval.
	var crop_id: String = str(cell.crop_id)
	var duration: float = Crops.definition(crop_id).duration_seconds if not crop_id.is_empty() else 0.0
	var growth: float = float(cell.growth_seconds)
	var moisture: float = float(cell.get("moisture", MOISTURE_DEFAULT))
	var before: int = _stage_rank(growth, duration) if not crop_id.is_empty() else 0
	var cursor: float = baseline
	var blocks: int = 0
	while cursor < now_utc_seconds and blocks < MAX_WEATHER_BLOCKS_PER_SETTLE:
		blocks += 1
		var block_start: float = cursor
		var weather: Variant = _environment.weather_at(cursor)
		if not weather is Dictionary or weather.is_empty():
			break
		var block_end_value: Variant = weather.get("end_utc")
		if not (block_end_value is int or block_end_value is float) \
				or not is_finite(float(block_end_value)) or float(block_end_value) <= cursor:
			break
		var block_end: float = float(block_end_value)
		var segment_end: float = minf(now_utc_seconds, block_end)
		var elapsed: float = segment_end - cursor
		if elapsed > 0.0 and not crop_id.is_empty() and growth < duration:
			growth = minf(duration, growth + elapsed * weather_growth_factor(str(weather.get("kind", "")), moisture))
		cursor = segment_end
		if cursor < block_end:
			# Reached `now` inside the block; its moisture change is not due yet.
			break
		# The completed block applies the weather delta first, then the disaster
		# layer of that same block. Both use absolute boundaries, so any split of
		# the interval produces the same moisture sequence.
		moisture = _moisture_after_block(moisture, str(weather.get("kind", "")))
		var disaster: Dictionary = _disaster_at(block_start)
		if not disaster.is_empty():
			moisture = _moisture_after_disaster(moisture, str(disaster.get("kind", "")))
	# A provider that cannot answer must not stall growth; finish the remainder
	# with the legacy additive rate. NatureState always answers valid times.
	if cursor < now_utc_seconds:
		if not crop_id.is_empty() and growth < duration:
			growth = minf(duration, growth + (now_utc_seconds - cursor))
	if not crop_id.is_empty():
		var after: int = _stage_rank(growth, duration)
		if before != after and not visual_changes.has(field_id):
			visual_changes.append(field_id)
	cell.growth_seconds = growth
	cell.moisture = clampf(moisture, 0.0, MOISTURE_MAX)


static func weather_growth_factor(kind: String, moisture: float) -> float:
	# Bounded weather effect: while the soil is not dry the crop grows at the
	# normal rate; clear/cloudy weather on dry soil halves it. A crop can only
	# take longer to mature; its harvest cap and one-basket yield never change.
	if kind == "clear" or kind == "cloudy":
		return GROWTH_FACTOR_DRY if moisture < MOISTURE_GROWTH_THRESHOLD else GROWTH_FACTOR_NORMAL
	return GROWTH_FACTOR_NORMAL


static func moisture_label(moisture: float) -> String:
	if moisture < MOISTURE_GROWTH_THRESHOLD:
		return "dry"
	if moisture >= MOISTURE_WET:
		return "wet"
	return "damp"


static func _moisture_after_block(moisture: float, kind: String) -> float:
	match kind:
		"rain":
			return minf(MOISTURE_MAX, moisture + RAIN_MOISTURE_GAIN)
		"cloudy":
			return maxf(0.0, moisture - CLOUDY_MOISTURE_LOSS)
		"clear":
			return maxf(0.0, moisture - CLEAR_MOISTURE_LOSS)
	return moisture


func _disaster_at(utc_seconds: float) -> Dictionary:
	# An older injected source (M6-02) has no disaster layer. Treat that as no
	# event instead of inventing a mode or a second environment contract.
	if _environment == null or not _environment.has_method("disaster_at"):
		return {}
	var event: Variant = _environment.disaster_at(utc_seconds)
	return event if event is Dictionary else {}


static func _moisture_after_disaster(moisture: float, kind: String) -> float:
	# Gentle mode only moves already-clamped soil moisture. Unknown kinds are
	# ignored so a future event kind cannot become an unexplained second loss.
	match kind:
		"drought":
			return maxf(0.0, moisture - DROUGHT_MOISTURE_LOSS)
		"storm":
			return minf(MOISTURE_MAX, moisture + STORM_MOISTURE_GAIN)
	return moisture


static func _stage_rank(growth: float, duration: float) -> int:
	if duration <= 0.0:
		return 0
	return int(growth >= duration * Crops.YOUNG_PROGRESS) + int(growth >= duration)


func _view_growth_rate(cell: Dictionary) -> float:
	if _environment == null:
		return GROWTH_FACTOR_NORMAL
	var weather: Variant = _environment.weather_at(float(cell.last_settled_utc_seconds))
	if not weather is Dictionary or weather.is_empty():
		return GROWTH_FACTOR_NORMAL
	return weather_growth_factor(str(weather.get("kind", "")), float(cell.get("moisture", MOISTURE_DEFAULT)))


func _set_initial_crop(field_id: String, crop_id: String, progress: float) -> void:
	if not _data.fields.has(field_id) or not _data.fields[field_id].cells.has("cell_06"): return
	_data.fields[field_id].cells.cell_06.crop_id = crop_id
	_data.fields[field_id].cells.cell_06.growth_seconds = Crops.definition(crop_id).duration_seconds * progress


static func _empty_cell(now_utc_seconds: float) -> Dictionary:
	return {"crop_id": "", "growth_seconds": 0.0, "last_settled_utc_seconds": now_utc_seconds, "watered": false, "ground":"ready", "planted_by":"", "moisture": MOISTURE_DEFAULT}


static func _result(ok: bool, reason: String, changed: Array[String] = [], reward_crop: String = "") -> Dictionary:
	return {"ok": ok, "reason": reason, "changed_fields": changed, "reward_crop_id": reward_crop, "reward_amount": 0 if reward_crop.is_empty() else 1}


static func _valid_time(value: float) -> bool:
	return is_finite(value) and value >= 0.0


static func _is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _valid_snapshot(data: Dictionary) -> bool:
	# The pre-bag document had ten keys, then bags added an eleventh, theft a
	# twelfth and buildings a thirteenth. Only those may be missing, and when
	# present each must be a valid table, so unknown fields still cannot slip in.
	if not Seasons.valid(data.get("season")) or not data.get("fields") is Dictionary or not data.get("harvested") is Dictionary or not data.get("layout") is Dictionary:
		return false
	var has_bags: bool = data.has("bags")
	var has_theft: bool = data.has("theft")
	var has_buildings: bool = data.has("buildings")
	if data.size() != 10 + int(has_bags) + int(has_theft) + int(has_buildings):
		return false
	if has_bags and not _valid_bags(data.get("bags")): return false
	if has_theft and not _valid_theft(data.get("theft")): return false
	if has_buildings and not _valid_buildings(data.get("buildings")): return false
	if not _valid_transaction(data.get("transaction")): return false
	if not data.get("memories") is Dictionary or not Memories.valid(data.memories): return false
	if not data.get("animals") is Dictionary or not Companions.valid(data.animals): return false
	if not data.get("kitchen") is Dictionary or not Kitchen.valid(data.kitchen): return false
	if not data.get("inventory") is Dictionary or not data.get("neighbors") is Dictionary: return false
	if data.inventory.size()!=Crops.crop_ids().size() or not Neighbors.valid(data.neighbors): return false
	var plan: RefCounted = Plan.from_snapshot(data.layout)
	if plan == null: return false
	for kind: String in Companions.Flocks.KINDS:
		for i: int in int(plan.construction.flocks[kind].count):
			if not data.animals.has(Companions.Flocks.id(kind,i)): return false
	var fields: Dictionary = data.fields
	var harvested: Dictionary = data.harvested
	if fields.size() != plan.fields.size()+1 or harvested.size() != Crops.crop_ids().size():
		return false
	for crop_id: String in Crops.crop_ids():
		var stock: Variant = data.inventory.get(crop_id)
		if not _is_number(stock) or stock<0 or stock>MAX_HARVEST_COUNT or floorf(stock)!=stock: return false
		var count: Variant = harvested.get(crop_id)
		if not _is_number(count) or float(count) < 0.0 or float(count) > MAX_HARVEST_COUNT or float(count) != floorf(float(count)):
			return false
	for definition: Dictionary in _planting_areas(plan):
		var field_id: String = definition.id
		if not fields.get(field_id) is Dictionary:
			return false
		var field: Dictionary = fields[field_id]
		if field.size() != 1 or not field.get("cells") is Dictionary or field.cells.size() != definition.cells.size():
			return false
		for cell_id: String in definition.cells:
			if not field.cells.get(cell_id) is Dictionary or not valid_cell_snapshot(field.cells[cell_id]):
				return false
			var cell: Dictionary=field.cells[cell_id]
			if field_id==Trellis.FIELD_ID and cell.ground!="ready": return false
			if not cell.crop_id.is_empty() and not Crops.supports(cell.crop_id,field_id==Trellis.FIELD_ID): return false
	return true


static func _valid_bags(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	for player_id: Variant in value:
		if not _valid_player_id(player_id):
			return false
		var stored: Variant = value[player_id]
		if not stored is Dictionary:
			return false
		for crop_id: Variant in stored:
			if not crop_id is String or Crops.definition(str(crop_id)).is_empty():
				return false
			var amount: Variant = stored[crop_id]
			if not _is_number(amount) or float(amount) < 0.0 or float(amount) > float(MAX_HARVEST_COUNT) \
					or float(amount) != floorf(float(amount)):
				return false
	return true


static func _valid_player_id(value: Variant) -> bool:
	# Player ids match the social identifier format: they are stored as bag keys
	# and delivered over the network, so the farm document validates them itself
	# instead of trusting whoever wrote the snapshot.
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > 64:
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		var letter: bool = (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var digit: bool = code >= 48 and code <= 57
		if not letter and not digit and code != 95 and code != 45 and code != 46 and code != 58:
			return false
	return true


static func _bag_amount(bags: Dictionary, player_id: String, crop_id: String) -> int:
	var stored: Variant = bags.get(player_id)
	if not stored is Dictionary: return 0
	var amount: Variant = stored.get(crop_id)
	return int(amount) if _is_number(amount) else 0


static func _add_to_bag(bags: Dictionary, player_id: String, crop_id: String, amount: int) -> void:
	if not bags.get(player_id) is Dictionary: bags[player_id] = {}
	bags[player_id][crop_id] = _bag_amount(bags, player_id, crop_id) + amount


static func _day_index(now_utc_seconds: float) -> int:
	return int(floor(now_utc_seconds / 86400.0))


static func _theft_record(data: Dictionary, player_id: String) -> Dictionary:
	# One record per player: their own consent plus the loss their cells took
	# today and who last took from them. Created on first write only.
	if not data.theft.get(player_id) is Dictionary:
		data.theft[player_id] = {"enabled": false, "day": -1, "lost": 0, "last": {}}
	return data.theft[player_id]


static func _valid_theft(value: Variant) -> bool:
	if not value is Dictionary: return false
	for player_id: Variant in value:
		if not _valid_player_id(player_id): return false
		var record: Variant = value[player_id]
		if not record is Dictionary or record.size() != 4: return false
		if not record.get("enabled") is bool or not record.get("last") is Dictionary: return false
		var day: Variant = record.get("day")
		var lost: Variant = record.get("lost")
		if not _is_number(day) or float(day) != floorf(float(day)) or float(day) < -1.0: return false
		if not _is_number(lost) or float(lost) != floorf(float(lost)) or float(lost) < 0.0 \
				or float(lost) > float(MAX_THEFT_PER_DAY): return false
		for thief: Variant in record.last:
			if not _valid_player_id(thief): return false
			var at: Variant = record.last[thief]
			if not _is_number(at) or not _valid_time(float(at)): return false
	return true


static func _valid_buildings(value: Variant) -> bool:
	# A slot record is exactly one known blueprint, one named owner and a
	# nonnegative time range; the finish may not precede the start.
	if not value is Dictionary: return false
	for slot_id: Variant in value:
		if not slot_id is String or slot_id not in Buildings.SLOTS: return false
		var record: Variant = value[slot_id]
		if not record is Dictionary or record.size() != 4: return false
		var blueprint: Variant = record.get("blueprint")
		var owner: Variant = record.get("owner")
		var started: Variant = record.get("started_utc")
		var done: Variant = record.get("done_utc")
		if not blueprint is String or Buildings.definition(blueprint).is_empty(): return false
		if not _valid_player_id(owner): return false
		if not _is_number(started) or not _valid_time(float(started)): return false
		if not _is_number(done) or not _valid_time(float(done)): return false
		if float(done) < float(started): return false
	return true


static func _valid_transaction(value: Variant) -> bool:
	if not value is Dictionary or value.size() != 2: return false
	var sequence: Variant = value.get("sequence")
	if not _is_number(sequence) or float(sequence) < 0.0 or float(sequence) > MAX_HARVEST_COUNT or float(sequence) != floorf(float(sequence)):
		return false
	var results: Variant = value.get("command_results")
	if not results is Dictionary or results.size() > MAX_COMMAND_RESULTS: return false
	for id: Variant in results:
		if not id is String or id.is_empty() or id.length() > MAX_COMMAND_ID_LENGTH: return false
		var entry: Variant = results[id]
		if not entry is Dictionary or entry.size() != 2: return false
		var payload: Variant = entry.get("payload")
		var result: Variant = entry.get("result")
		if not payload is String or payload.length() > MAX_COMMAND_PAYLOAD_LENGTH: return false
		if not _valid_command_result(result): return false
	return true


static func _valid_command_result(result: Variant) -> bool:
	if not result is Dictionary or result.size() != 6: return false
	if not result.get("ok") is bool or not result.get("reason") is String: return false
	if not result.get("reward_crop_id") is String: return false
	var amount: Variant = result.get("reward_amount")
	if not _is_number(amount) or float(amount) < 0.0 or float(amount) > MAX_HARVEST_COUNT or float(amount) != floorf(float(amount)):
		return false
	for key: String in ["changed_fields", "visual_changed"]:
		var values: Variant = result.get(key)
		if not values is Array: return false
		for value: Variant in values:
			if not value is String: return false
	return true


static func valid_cell_snapshot(field: Dictionary) -> bool:
	# The required five keys are the original cell. Ownership and moisture were
	# added later, so a cell may carry any subset of them; a v27 cell carries
	# neither and is defaulted on restore. No other key may appear.
	if field.size() < 5 or field.size() > 7:
		return false
	for key: Variant in field:
		if not key is String or key not in ["crop_id", "growth_seconds", "last_settled_utc_seconds",
				"watered", "ground", "planted_by", "moisture"]:
			return false
	if not field.get("crop_id") is String or not field.get("watered") is bool:
		return false
	if field.has("moisture"):
		var moisture: Variant = field.get("moisture")
		if not _is_number(moisture) or float(moisture) < 0.0 or float(moisture) > MOISTURE_MAX:
			return false
	if field.has("planted_by"):
		var planted_by: Variant = field.get("planted_by")
		if not planted_by is String: return false
		if not str(planted_by).is_empty() and not _valid_player_id(planted_by): return false
		if field.crop_id.is_empty() and not str(planted_by).is_empty(): return false
	if field.get("ground") not in ["ready","rough","weedy"]: return false
	if field.ground!="ready" and not field.crop_id.is_empty(): return false
	var growth: Variant = field.get("growth_seconds")
	var baseline: Variant = field.get("last_settled_utc_seconds")
	if not _is_number(growth) or float(growth) < 0.0 or not _is_number(baseline) or not _valid_time(float(baseline)):
		return false
	if field.crop_id.is_empty():
		if float(growth) != 0.0 or field.watered:
			return false
	else:
		var crop: Dictionary = Crops.definition(field.crop_id)
		if crop.is_empty() or float(growth) > crop.duration_seconds:
			return false
		if field.watered and float(growth) < crop.duration_seconds * crop.water_progress:
			return false
	return true

static func _planting_areas(plan: RefCounted) -> Array:
	var result: Array=plan.fields.duplicate()
	result.append(Trellis.definition(plan))
	return result
