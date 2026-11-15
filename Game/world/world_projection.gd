extends RefCounted
## ADR-027: per-recipient projection of the authoritative world.
##
## The authority keeps the complete FarmState, its ledger, every bag and every
## account. This module decides only which fields appear in the document a
## particular member receives. It never mutates the authority, never recomputes
## a rule and never changes a balance: rows are copied, identities are replaced
## by `owner_scope`, and tables with no current consumer are omitted.
##
## Every projected document still travels through WorldHost._encode_document()
## and the ADR-026 48 KiB budget; the projection must not bypass that seam.
## A projected snapshot is deliberately not a restorable authority snapshot:
## Economy.valid_view() checks its shape but cannot reconcile the ledger, so
## FarmState.restore_snapshot() refuses it and FarmState.restore_view() is the
## only way to adopt it.

const FarmCommand = preload("res://farm/farm_command.gd")
const Market = preload("res://farm/market_state.gd")
const Loans = preload("res://farm/loan_state.gd")

const VIEW_VERSION: int = 1
const MEMBER_ROLE: String = "member"
## A third party's theft record keeps only the opt-in switch. `day/lost/last`
## are that player's own loss history, so they are replaced by this neutral
## shape instead of being sent.
const NEUTRAL_THEFT_DAY: int = -1

const PUBLIC_FARM_KEYS: Array[String] = [
	"fields", "harvested", "inventory", "layout", "kitchen", "animals",
	"memories", "season", "neighbors", "buildings",
]
const PUBLIC_SUMMARY_KEYS: Array[String] = [
	"now_utc", "inventory", "harvested", "buildings", "fields",
	"committed_commands", "committed_sequence", "next_event_utc", "nature",
]
const MARKET_ORDER_KEYS: Array[String] = [
	"id", "side", "good", "price", "quantity", "remaining", "filled",
	"reserved", "sequence", "status",
]
const MARKET_SHIPMENT_KEYS: Array[String] = [
	"id", "sequence", "good", "quantity", "origin", "destination",
	"depart_utc", "arrive_utc", "status",
]
const MARKET_DELIVERY_KEYS: Array[String] = [
	"id", "sequence", "good", "quantity", "origin", "destination", "at_utc",
]


static func view_marker(viewer: String, role: String) -> Dictionary:
	return {"version": VIEW_VERSION, "viewer": viewer, "role": role}


## The display document a member restores from and reads its own wallet from.
## `world_id` and `run_generation` are added by the host, which owns them.
static func project_summary(world: RefCounted, viewer: String, role: String,
		sequence: int) -> Dictionary:
	if world == null or world.farm == null:
		return {}
	var source: Dictionary = world.summary()
	var result: Dictionary = {}
	for key: String in PUBLIC_SUMMARY_KEYS:
		if source.has(key):
			result[key] = source[key]
	result["bags"] = _viewer_bags(source.get("bags"), viewer)
	result["sequence"] = sequence
	result["role"] = role
	result["view"] = view_marker(viewer, role)
	result["snapshot"] = project_snapshot(world, viewer, role)
	return result


## The restorable part of a summary. `view` marks it as a projection so the
## member selects restore_view() and can never mistake it for an authority
## document.
static func project_snapshot(world: RefCounted, viewer: String, role: String) -> Dictionary:
	if world == null or world.farm == null:
		return {}
	var source: Dictionary = world.state_snapshot()
	var result: Dictionary = {
		"view": view_marker(viewer, role),
	}
	if source.has("now_utc"):
		result["now_utc"] = source.now_utc
	if source.has("decorations"):
		result["decorations"] = source.decorations
	if source.has("nature"):
		result["nature"] = source.nature
	result["farm"] = _project_farm(source.get("farm", {}), viewer, role)
	return result


## One event for the change/catch-up channel. An economy command is reduced to
## an opaque sequence marker: its amount, order parameters and contract terms
## are not broadcast, and the client never replays it locally. The sequence is
## preserved so catch-up continuity and last_sequence bookkeeping are unchanged.
static func project_change(entry: Dictionary, _viewer: String) -> Dictionary:
	if _is_economy_entry(entry):
		return {"sequence": int(entry.get("sequence", 0)), "kind": "economy"}
	return entry.duplicate(true)


static func project_tail(events: Array, viewer: String) -> Array:
	var result: Array = []
	for entry: Variant in events:
		if entry is Dictionary:
			result.append(project_change(entry, viewer))
	return result


static func _project_farm(source: Dictionary, viewer: String, role: String) -> Dictionary:
	var farm: Dictionary = {}
	for key: String in PUBLIC_FARM_KEYS:
		if source.has(key):
			farm[key] = source[key]
	# Only the viewer's own pocket crosses the wire. The table itself is always
	# present so local replay keeps a working (empty) pocket; whether the
	# viewer's *entry* exists is the "not synced yet" signal the scene reads.
	var own_bag: Variant = null
	var source_bags: Variant = source.get("bags")
	if not viewer.is_empty() and source_bags is Dictionary:
		own_bag = (source_bags as Dictionary).get(viewer)
	if own_bag is Dictionary:
		farm["bags"] = {viewer: (own_bag as Dictionary).duplicate(true)}
	else:
		farm["bags"] = {}
	farm["theft"] = _project_theft(source.get("theft"), viewer)
	farm["transaction"] = _project_transaction(source.get("transaction"), viewer)
	farm["economy"] = _project_economy(source.get("economy"), viewer, role)
	return farm


static func _project_theft(source: Variant, viewer: String) -> Dictionary:
	var result: Dictionary = {}
	if not source is Dictionary:
		return result
	for player_id: Variant in source:
		var record: Variant = source[player_id]
		if not record is Dictionary:
			continue
		if str(player_id) == viewer and not viewer.is_empty():
			result[str(player_id)] = (record as Dictionary).duplicate(true)
		else:
			result[str(player_id)] = {
				"enabled": bool((record as Dictionary).get("enabled", false)),
				"day": NEUTRAL_THEFT_DAY, "lost": 0, "last": {},
			}
	return result


static func _project_transaction(source: Variant, viewer: String) -> Dictionary:
	var result: Dictionary = {"sequence": 0}
	if not source is Dictionary:
		return result
	result["sequence"] = int((source as Dictionary).get("sequence", 0))
	var results: Dictionary = {}
	var stored: Variant = (source as Dictionary).get("command_results")
	if stored is Dictionary:
		for command_id: Variant in stored:
			var entry: Variant = stored[command_id]
			if not entry is Dictionary:
				continue
			# The client replays only non-economy commands. An economy result is
			# kept only for the player who submitted it; everyone else does not
			# even learn that the command existed.
			if _is_other_economy_result(entry as Dictionary, viewer):
				continue
			results[str(command_id)] = (entry as Dictionary).duplicate(true)
	result["command_results"] = results
	# `gift_ids` is a durable replay guard the client no longer consults; it can
	# hold 1024 payloads and is intentionally dropped from the projection.
	return result


static func _project_economy(source: Variant, viewer: String, role: String) -> Dictionary:
	var economy: Dictionary = {}
	var economy_data: Dictionary = source if source is Dictionary else {}
	economy["currency"] = str(economy_data.get("currency", ""))
	var member: bool = role == MEMBER_ROLE and not viewer.is_empty()
	var accounts: Dictionary = {}
	var stored_accounts: Variant = economy_data.get("accounts")
	if member and stored_accounts is Dictionary and stored_accounts.get(viewer) is Dictionary:
		accounts[viewer] = (stored_accounts[viewer] as Dictionary).duplicate(true)
	economy["accounts"] = accounts
	economy["market"] = _project_market(economy_data.get("market"), viewer)
	var bank: Dictionary = {
		"opened": false, "cash": 0, "capital": 0,
		"outstanding": Loans.outstanding_principal(economy_data),
		"fees": Loans.collected_fees(economy_data),
	}
	var stored_bank: Variant = economy_data.get("bank")
	if stored_bank is Dictionary:
		bank["opened"] = bool((stored_bank as Dictionary).get("opened", false))
		bank["cash"] = int((stored_bank as Dictionary).get("cash", 0))
		bank["capital"] = int((stored_bank as Dictionary).get("capital", 0))
	economy["bank"] = bank
	# ADR-027 §10: other borrowers' contracts are not sent at all. Their
	# aggregate principal/fees remain visible through `bank` above.
	var loans: Dictionary = {}
	var stored_loans: Variant = economy_data.get("loans")
	if member and stored_loans is Dictionary:
		for loan_id: Variant in stored_loans:
			var row: Variant = stored_loans[loan_id]
			if not row is Dictionary:
				continue
			if str((row as Dictionary).get("borrower", "")) != viewer:
				continue
			loans[str(loan_id)] = {
				"id": str((row as Dictionary).get("id", str(loan_id))),
				"principal": int((row as Dictionary).get("principal", 0)),
				"fee": int((row as Dictionary).get("fee", 0)),
				"due_utc": float((row as Dictionary).get("due_utc", 0.0)),
				"status": str((row as Dictionary).get("status", "")),
				"owner_scope": "me",
			}
	economy["loans"] = loans
	return economy


static func _project_market(source: Variant, viewer: String) -> Dictionary:
	var result: Dictionary = {
		"merchant": {"opened": false, "opened_utc": 0.0, "cash": 0, "goods": {}},
		"orders": {}, "shipments": {}, "deliveries": {},
	}
	if not source is Dictionary:
		return result
	var market: Dictionary = source
	var merchant: Variant = market.get("merchant")
	if merchant is Dictionary:
		result["merchant"] = {
			"opened": bool((merchant as Dictionary).get("opened", false)),
			"opened_utc": float((merchant as Dictionary).get("opened_utc", 0.0)),
			"cash": int((merchant as Dictionary).get("cash", 0)),
			"goods": ((merchant as Dictionary).get("goods") as Dictionary).duplicate(true) \
				if (merchant as Dictionary).get("goods") is Dictionary else {},
		}
	var orders: Dictionary = {}
	var stored_orders: Variant = market.get("orders")
	if stored_orders is Dictionary:
		for order_id: Variant in stored_orders:
			var order: Variant = stored_orders[order_id]
			if not order is Dictionary:
				continue
			var row: Dictionary = {}
			for key: String in MARKET_ORDER_KEYS:
				row[key] = (order as Dictionary).get(key)
			row["owner_scope"] = _owner_scope(str((order as Dictionary).get("owner", "")), viewer)
			orders[str(order_id)] = row
	result["orders"] = orders
	var shipments: Dictionary = {}
	var stored_shipments: Variant = market.get("shipments")
	if stored_shipments is Dictionary:
		for shipment_id: Variant in stored_shipments:
			var shipment: Variant = stored_shipments[shipment_id]
			if not shipment is Dictionary:
				continue
			var row: Dictionary = {}
			for key: String in MARKET_SHIPMENT_KEYS:
				row[key] = (shipment as Dictionary).get(key)
			row["owner_scope"] = _owner_scope(
				str((shipment as Dictionary).get("owner", "")), viewer)
			shipments[str(shipment_id)] = row
	result["shipments"] = shipments
	var deliveries: Dictionary = {}
	var stored_deliveries: Variant = market.get("deliveries")
	if stored_deliveries is Dictionary:
		for delivery_id: Variant in stored_deliveries:
			var delivery: Variant = stored_deliveries[delivery_id]
			if not delivery is Dictionary:
				continue
			var row: Dictionary = {}
			for key: String in MARKET_DELIVERY_KEYS:
				row[key] = (delivery as Dictionary).get(key)
			row["owner_scope"] = _owner_scope(
				str((delivery as Dictionary).get("owner", "")), viewer)
			deliveries[str(delivery_id)] = row
	result["deliveries"] = deliveries
	return result


static func _owner_scope(owner: String, viewer: String) -> String:
	if not viewer.is_empty() and owner == viewer:
		return "me"
	if owner == Market.MERCHANT:
		return "merchant"
	return "other"


static func _viewer_bags(source: Variant, viewer: String) -> Dictionary:
	if viewer.is_empty() or not source is Dictionary:
		return {}
	var bag: Variant = (source as Dictionary).get(viewer)
	return {viewer: (bag as Dictionary).duplicate(true)} if bag is Dictionary else {}


static func _is_economy_entry(entry: Dictionary) -> bool:
	var command: Variant = entry.get("command")
	if not command is Dictionary:
		return false
	return FarmCommand.is_economy_kind(str((command as Dictionary).get("kind", "")))


static func _is_other_economy_result(entry: Dictionary, viewer: String) -> bool:
	var payload: Variant = entry.get("payload")
	if not payload is String:
		return false
	var parsed: Variant = JSON.parse_string(payload)
	if not parsed is Array or (parsed as Array).is_empty():
		return false
	var parts: Array = parsed
	var kind: String = str(parts[0])
	if not FarmCommand.is_economy_kind(kind):
		return false
	if viewer.is_empty():
		return true
	return _economy_actor(parts, kind) != viewer


## The committed payload binds the actor at a position that depends on the
## command kind (see FarmCommand._economy_payload). Projection reads that one
## position to keep only the submitter's own economy result.
static func _economy_actor(parts: Array, kind: String) -> String:
	match kind:
		FarmCommand.PAY, FarmCommand.LOAN_BORROW:
			return str(parts[4]) if parts.size() > 4 else ""
		FarmCommand.MARKET_PLACE:
			return str(parts[7]) if parts.size() > 7 else ""
		FarmCommand.MARKET_SHIP:
			return str(parts[6]) if parts.size() > 6 else ""
		FarmCommand.MARKET_CANCEL, FarmCommand.LOAN_REPAY:
			return str(parts[3]) if parts.size() > 3 else ""
	return str(parts[2]) if parts.size() > 2 else ""
