extends SceneTree
## ADR-027: the authority keeps the whole world, each member gets a projection.
##
## Two named members and a visitor share one real WorldHost world. The fixture
## reads the exact documents the host would send and proves:
##   - another player's bag/account/ledger/trade/loss/economy-command result
##     never appears;
##   - the viewer's own bag, account, contract and theft record do appear and
##     equal the authority;
##   - public play fields (fields, layout, kitchen, animals, market rows,
##     houses, roster-facing summary) are unchanged;
##   - order/shipment/delivery/loan identities become owner_scope;
##   - other borrowers' loan rows are absent while bank-wide aggregates remain;
##   - economy events are opaque {sequence, kind:"economy"} markers with an
##     unbroken sequence;
##   - a projected farm passes Economy.valid_view()/restore_view() but is
##     refused by restore_snapshot(); a wrong viewer is refused;
##   - the schema-cap projected document still fits the ADR-026 48 KiB budget.
##
## Last line: WORLD_PROJECTION_TEST checks=N failures=M

const HeadlessWorld = preload("res://world/headless_world.gd")
const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const WorldProjection = preload("res://world/world_projection.gd")
const WorldPayload = preload("res://world/world_payload.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const FarmState = preload("res://farm/farm_state.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Market = preload("res://farm/market_state.gd")
const Loans = preload("res://farm/loan_state.gd")

const START: float = 1800000000.0
const A: String = "player_a"
const B: String = "player_b"
const C: String = "player_c"
const PEER_A: int = 11
const PEER_B: int = 12
const PEER_C: int = 13
const SUMMARY_KEYS: Array[String] = [
	"now_utc", "inventory", "harvested", "buildings", "fields",
	"committed_commands", "committed_sequence", "next_event_utc", "nature",
]
const PUBLIC_FARM_KEYS: Array[String] = [
	"fields", "harvested", "inventory", "layout", "kitchen", "animals",
	"memories", "season", "neighbors", "buildings",
]

var checks: int = 0
var failures: Array[String] = []
var dir: String = ""
var host: WorldHost


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir() \
		.path_join(".local/verification/world-projection-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	host = WorldHost.new()
	host.name = WorldHost.SESSION_NODE_NAME
	root.add_child(host)
	var opened: Dictionary = host.configure(dir.path_join("world"), START, "world-projection")
	_expect(bool(opened.get("ok", false)) and host.world != null, "The authority opens a world")
	if not bool(opened.get("ok", false)) or host.world == null:
		_finish()
		return
	host._members[PEER_A] = WorldInvite.MEMBER
	host._members[PEER_B] = WorldInvite.MEMBER
	host._members[PEER_C] = WorldInvite.VISITOR
	host._players[PEER_A] = {"id": A, "name": "甲"}
	host._players[PEER_B] = {"id": B, "name": "乙"}
	host._players[PEER_C] = {"id": C, "name": "丙"}
	_build_world(host.world)
	var authority: Dictionary = host.world.state_snapshot()
	var authority_summary: Dictionary = host.world.summary()

	var projected: Dictionary = host._summary_document(PEER_A)
	_test_identity(projected)
	_test_private_fields(projected, authority)
	_test_public_fields(projected, authority, authority_summary)
	_test_event_projection()
	_test_roles()
	_test_restore_contract(projected, authority)
	_expect(host.world.state_snapshot() == authority,
		"Projection never mutates the authoritative state")
	_test_budget()
	_finish()


func _build_world(world: HeadlessWorld) -> void:
	var farm: RefCounted = world.farm
	var at: float = START
	for owner: String in [A, B, C]:
		_expect(bool(farm.economy_open_account("acct-" + owner, owner, at).get("ok", false)),
			"The fixture opens %s's account" % owner)
		at += 1.0
	_expect(bool(farm.economy_open_bank("bank-open", at).get("ok", false)),
		"The fixture opens the bank")
	at += 1.0
	_expect(bool(farm.market_open_merchant("market-open", at).get("ok", false)),
		"The fixture opens the merchant")
	at += 1.0
	_expect(bool(farm.economy_pay("pay-1", A, B, 10, at, 1).get("ok", false)),
		"The fixture moves cash from A to B")
	at += 1.0
	farm._data.bags[A] = {"greens": 10}
	_expect(bool(farm.market_place_order("order-a", A, "sell", "greens", 5, 2,
		at + 86400.0, at).get("ok", false)), "A places a sell order")
	at += 1.0
	_expect(bool(farm.market_place_order("order-b", B, "buy", "greens", 5, 2,
		at + 86400.0, at).get("ok", false)), "B places a buy order")
	at += 1.0
	var matched: Dictionary = farm.market_match(at)
	_expect(bool(matched.get("ok", false)) and int(matched.get("count", 0)) >= 1,
		"The fixture produces a trade")
	_expect(bool(farm.market_ship("ship-a", A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 1, at).get("ok", false)),
		"A ships goods across the market route")
	at += 1000.0
	var delivered: Dictionary = farm.market_deliver(at)
	_expect(bool(delivered.get("ok", false)) and int(delivered.get("count", 0)) >= 1,
		"The fixture produces a delivery")
	at += 1.0
	_expect(bool(farm.economy_borrow_loan("loan-a", A, 100, 604800, at).get("ok", false)),
		"A borrows a contract")
	at += 1.0
	_expect(bool(farm.economy_borrow_loan("loan-b", B, 100, 604800, at).get("ok", false)),
		"B borrows a contract")
	at += 1.0
	_expect(bool(farm.set_theft(A, true).get("ok", false)), "A enables theft")
	_expect(bool(farm.set_theft(B, true).get("ok", false)), "B enables theft")
	_expect(bool(farm.set_theft(C, false).get("ok", false)), "C leaves theft disabled")
	# A gift id proves the durable replay guard is present in the authority and
	# absent from the projection.
	farm._data.transaction.gift_ids["gift-1"] = JSON.stringify(
		["gift", B, "greens", 1, at, A])
	# Command-result window: one own economy result, one own non-economy result,
	# one other player's economy result and one other player's farm action.
	farm._data.transaction.sequence = 7
	_inject_result(farm, "own-econ", ["account_open", at, A])
	_inject_result(farm, "own-sow", ["sow", "field_01", "cell_01", at, "greens"])
	_inject_result(farm, "other-econ", ["pay", B, 5, at, B, 2])
	_inject_result(farm, "other-water", ["water", "field_01", "cell_01", at])


static func _inject_result(farm: RefCounted, command_id: String, payload: Array) -> void:
	farm._data.transaction.command_results[command_id] = {
		"payload": JSON.stringify(payload),
		"result": {"ok": true, "reason": "", "changed_fields": [],
			"visual_changed": [], "reward_crop_id": "", "reward_amount": 0},
	}


func _test_identity(projected: Dictionary) -> void:
	_expect(_view_is(projected.get("view"), A, WorldInvite.MEMBER),
		"The summary carries the projection marker for A")
	var snapshot: Dictionary = projected.get("snapshot", {})
	_expect(_view_is(snapshot.get("view"), A, WorldInvite.MEMBER),
		"The snapshot carries the projection marker for A")
	_expect(int(projected.get("sequence", -1)) == host._sequence(),
		"The projection preserves the authority sequence")
	_expect(str(projected.get("role", "")) == WorldInvite.MEMBER,
		"The projection carries the granted role")
	_expect(str(projected.get("world_id", "")) == "world-projection"
		and int(projected.get("run_generation", 0)) == 1,
		"The host adds the world identity around the projection")


func _test_private_fields(projected: Dictionary, authority: Dictionary) -> void:
	var farm: Dictionary = (projected.get("snapshot", {}) as Dictionary).get("farm", {})
	var auth_farm: Dictionary = authority.get("farm", {})
	var bags: Dictionary = farm.get("bags", {})
	_expect(bags.size() == 1 and bags.has(A), "The snapshot carries only A's bag")
	_expect(_dict(farm.get("bags")).get(A) == _dict(auth_farm.get("bags")).get(A),
		"A's bag equals the authoritative record")
	_expect(not (((projected.get("bags", {}) as Dictionary)).has(B)),
		"The summary's display bag block does not carry B")
	_expect((projected.get("bags", {}) as Dictionary).has(A),
		"The summary still carries A's own bag")

	var economy: Dictionary = farm.get("economy", {})
	var auth_economy: Dictionary = auth_farm.get("economy", {})
	var accounts: Dictionary = economy.get("accounts", {})
	_expect(accounts.size() == 1 and accounts.has(A), "Only A's account is sent")
	_expect(accounts.get(A) == _dict(auth_economy.get("accounts")).get(A),
		"A's account equals the authoritative record")
	for key: String in ["ledger", "conversion", "command_results", "losses", "issued",
			"total_cash", "sequence"]:
		_expect(not economy.has(key), "The projected economy omits " + key)
	_expect(not (economy.get("market", {}) as Dictionary).has("trades")
		and not (economy.get("market", {}) as Dictionary).has("trade_sequence"),
		"The market omits trades and their sequence")
	_expect(not (economy.get("market", {}) as Dictionary).has("archived_orders"),
		"The market omits archive counters")
	var merchant: Dictionary = (economy.get("market", {}) as Dictionary).get("merchant", {})
	_expect(merchant.size() == 4 and not merchant.has("opened_by") and not merchant.has("granted"),
		"The merchant keeps only public opening/cash/goods fields")

	var transaction: Dictionary = farm.get("transaction", {})
	_expect(not transaction.has("gift_ids"), "The transaction omits the durable gift set")
	var results: Dictionary = transaction.get("command_results", {})
	_expect(results.has("own-econ") and results.has("own-sow"),
		"Own economy and non-economy results are kept")
	_expect(not results.has("other-econ"), "Another player's economy result is removed")
	_expect(results.has("other-water"), "Another player's non-economy result is kept")

	var theft: Dictionary = farm.get("theft", {})
	_expect(theft.get(A) == _dict(auth_farm.get("theft")).get(A),
		"A's own theft record is complete and equal")
	for other: String in [B, C]:
		_expect(theft.get(other) == {"enabled": other == B, "day": -1, "lost": 0, "last": {}},
			"%s's theft record is the neutral shape" % other)

	var auth_loans: Dictionary = _dict(auth_economy.get("loans"))
	var loans: Dictionary = economy.get("loans", {})
	_expect(loans.size() == 1 and loans.has("loan-a"), "Only A's contract row is sent")
	_expect(not loans.has("loan-b"), "B's contract row is absent")
	var own_loan: Dictionary = loans.get("loan-a", {})
	var auth_loan: Dictionary = _dict(auth_loans.get("loan-a"))
	_expect(str(own_loan.get("owner_scope", "")) == "me"
		and not own_loan.has("borrower") and not own_loan.has("term"),
		"A's contract is scoped and anonymous")
	for key: String in ["id", "principal", "fee", "due_utc", "status"]:
		_expect(own_loan.get(key) == auth_loan.get(key),
			"A's contract keeps its authoritative " + key)
	var bank: Dictionary = economy.get("bank", {})
	_expect(int(bank.get("outstanding", -1)) == Loans.outstanding_principal(auth_economy),
		"The bank carries the bank-wide outstanding aggregate")
	_expect(int(bank.get("fees", -1)) == Loans.collected_fees(auth_economy),
		"The bank carries the bank-wide collected-fee aggregate")

	var market: Dictionary = economy.get("market", {})
	_test_market_rows(market, auth_economy.get("market", {}), "orders", "owner")
	_test_market_rows(market, auth_economy.get("market", {}), "shipments", "owner")
	_test_market_rows(market, auth_economy.get("market", {}), "deliveries", "owner")
	var order_row: Dictionary = _dict(market.get("orders")).values()[0]
	for key: String in ["owner", "closed_by", "released", "created_utc",
			"expires_utc", "closed_utc"]:
		_expect(not order_row.has(key), "An order row omits " + key)
	var shipment_row: Dictionary = _dict(market.get("shipments")).values()[0]
	for key: String in ["owner", "fee", "risk", "lost_utc", "loss_id", "delivery_id",
			"delivered_utc"]:
		_expect(not shipment_row.has(key), "A shipment row omits " + key)
	var delivery_row: Dictionary = _dict(market.get("deliveries")).values()[0]
	_expect(not delivery_row.has("owner") and not delivery_row.has("shipment_id"),
		"A delivery row omits the owner and shipment id")


func _test_market_rows(projected: Dictionary, authority: Dictionary, table: String,
		identity_key: String) -> void:
	var rows: Dictionary = _dict(projected.get(table))
	var auth_rows: Dictionary = _dict(authority.get(table))
	_expect(not rows.is_empty(), "The projected %s table is not empty" % table)
	for row_id: Variant in rows:
		var row: Dictionary = rows[row_id]
		var auth: Dictionary = _dict(auth_rows.get(row_id))
		_expect(row.has("owner_scope") and not row.has(identity_key),
			"The %s row has owner_scope and no raw identity" % table)
		_expect(str(row.get("owner_scope", "")) == _expected_scope(
			str(auth.get(identity_key, ""))), "The %s row scope matches its owner" % table)


func _expected_scope(owner: String) -> String:
	if owner == A:
		return "me"
	if owner == Market.MERCHANT:
		return "merchant"
	return "other"


func _test_public_fields(projected: Dictionary, authority: Dictionary,
		authority_summary: Dictionary) -> void:
	var snapshot: Dictionary = projected.get("snapshot", {})
	var farm: Dictionary = snapshot.get("farm", {})
	var auth_farm: Dictionary = authority.get("farm", {})
	for key: String in PUBLIC_FARM_KEYS:
		_expect(farm.get(key) == auth_farm.get(key), "Public farm field %s is unchanged" % key)
	for key: String in ["now_utc", "decorations", "nature"]:
		_expect(snapshot.get(key) == authority.get(key), "Public snapshot field %s is unchanged" % key)
	for key: String in SUMMARY_KEYS:
		_expect(projected.get(key) == authority_summary.get(key),
			"Public summary field %s is unchanged" % key)


func _test_event_projection() -> void:
	host._tail = [
		{"sequence": 1, "command": {"kind": "pay", "to_id": B, "amount": 50,
			"at_utc": START}, "stage": "committed", "reward_crop_id": "",
			"reward_amount": 0, "from_id": A, "from_name": "甲"},
		{"sequence": 2, "command": {"kind": "sow", "field_id": "field_01",
			"cell_id": "cell_01", "crop_id": "greens", "at_utc": START},
			"stage": "committed", "reward_crop_id": "", "reward_amount": 0,
			"from_id": A, "from_name": "甲"},
	]
	host._tail_floor = 1
	var reply: Dictionary = host.tail_since(0, A)
	_expect(bool(reply.get("ok", false)), "The projected tail is served")
	var events: Array = reply.get("events", [])
	_expect(events.size() == 2, "Both events survive projection")
	if events.size() == 2:
		var economy: Dictionary = events[0]
		_expect(economy.size() == 2 and int(economy.get("sequence", 0)) == 1
			and str(economy.get("kind", "")) == "economy",
			"An economy event is the opaque {sequence, kind} marker")
		_expect(not economy.has("command") and not economy.has("from_id"),
			"The economy marker carries no payload or sender")
		var farm_event: Dictionary = events[1]
		_expect(int(farm_event.get("sequence", 0)) == 2
			and str((farm_event.get("command", {}) as Dictionary).get("kind", "")) == "sow"
			and str(farm_event.get("from_id", "")) == A,
			"A non-economy event keeps its full body")
	_expect(int((reply.get("current", 0))) == host.world.farm.event_sequence(),
		"Projection does not renumber the tail")
	var b_tail: Dictionary = host.tail_since(0, B)
	_expect((b_tail.get("events", []) as Array).size() == 2,
		"The second member sees the same unbroken sequence")
	# A projection of an already-projected placeholder is still a placeholder.
	var projected_change: Dictionary = WorldProjection.project_change(
		{"sequence": 9, "kind": "economy"}, A)
	_expect(int(projected_change.get("sequence", 0)) == 9
		and str(projected_change.get("kind", "")) == "economy",
		"Projection is stable for an opaque marker")


func _test_roles() -> void:
	var visitor: Dictionary = WorldProjection.project_summary(
		host.world, A, WorldInvite.VISITOR, host._sequence())
	var visitor_farm: Dictionary = (visitor.get("snapshot", {}) as Dictionary).get("farm", {})
	var visitor_economy: Dictionary = visitor_farm.get("economy", {})
	_expect(_view_is(visitor.get("view"), A, WorldInvite.VISITOR),
		"The visitor marker names the visitor role")
	_expect((visitor_economy.get("accounts", {}) as Dictionary).is_empty(),
		"A visitor receives no account block")
	_expect((visitor_economy.get("loans", {}) as Dictionary).is_empty(),
		"A visitor receives no contract rows")
	_expect((visitor_farm.get("bags", {}) as Dictionary).has(A),
		"A named visitor still receives their own bag")
	_expect((visitor_economy.get("market", {}) as Dictionary).has("orders"),
		"A visitor still receives the public market")

	var anonymous: Dictionary = WorldProjection.project_summary(
		host.world, "", WorldInvite.MEMBER, host._sequence())
	var anon_farm: Dictionary = (anonymous.get("snapshot", {}) as Dictionary).get("farm", {})
	var anon_economy: Dictionary = anon_farm.get("economy", {})
	_expect(_view_is(anonymous.get("view"), "", WorldInvite.MEMBER),
		"The anonymous marker has an empty viewer")
	_expect((anon_farm.get("bags", {"x": 1}) as Dictionary).is_empty(),
		"An anonymous member gets no private bag entry")
	_expect((anonymous.get("bags", {}) as Dictionary).is_empty(),
		"The anonymous summary bag block is empty")
	_expect((anon_economy.get("accounts", {}) as Dictionary).is_empty()
		and (anon_economy.get("loans", {}) as Dictionary).is_empty(),
		"An anonymous member gets no account or contract block")
	for player_id: Variant in anon_farm.get("theft", {}):
		_expect(_dict(anon_farm.get("theft")).get(player_id) == _neutral_theft(
			_dict(_dict(host.world.farm.snapshot()).get("theft")).get(player_id)),
			"Anonymous theft record %s is neutral" % str(player_id))


static func _neutral_theft(record: Variant) -> Dictionary:
	var enabled: bool = false
	if record is Dictionary:
		enabled = bool((record as Dictionary).get("enabled", false))
	return {"enabled": enabled, "day": -1, "lost": 0, "last": {}}


func _test_restore_contract(projected: Dictionary, authority: Dictionary) -> void:
	var snapshot: Dictionary = projected.get("snapshot", {})
	var farm_data: Dictionary = snapshot.get("farm", {})
	var economy: Dictionary = farm_data.get("economy", {})
	_expect(FarmState.Economy.valid_view(economy, A),
		"The projected economy passes the view validator")
	_expect(not FarmState.Economy.valid(economy),
		"The projected economy is not accepted as an authority document")
	_expect(not FarmState.new().restore_snapshot(farm_data),
		"restore_snapshot refuses a projected farm")
	var restored := FarmState.new()
	_expect(restored.restore_view(farm_data, A), "restore_view accepts the projected farm")
	if restored.restore_view(farm_data, A):
		var restored_farm: Dictionary = restored.snapshot()
		_expect(restored_farm.get("bags", {}) == farm_data.get("bags", {}),
			"restore_view keeps only the viewer's bag")
		_expect(not (restored_farm.get("transaction", {}) as Dictionary).has("gift_ids"),
			"restore_view does not invent the dropped gift set")
		_expect(restored_farm.get("layout") == _dict(authority.get("farm")).get("layout"),
			"restore_view keeps the public layout")

	var tampered_bag: Dictionary = farm_data.duplicate(true)
	tampered_bag.bags[B] = {}
	_expect(not FarmState.new().restore_view(tampered_bag, A),
		"A hand-added other-player bag is refused")
	var tampered_account: Dictionary = farm_data.duplicate(true)
	tampered_account.economy.accounts[B] = {"cash": 1, "granted": true}
	_expect(not FarmState.new().restore_view(tampered_account, A),
		"A hand-added other-player account is refused")

	var member := WorldMember.new()
	member.player_id = B
	member.snapshot = snapshot
	_expect(str(member.restore_state().get("reason", "")) == "view_mismatch",
		"A different viewer is refused")
	member.player_id = A
	var restored_state: Dictionary = member.restore_state()
	_expect(bool(restored_state.get("ok", false)),
		"The matching viewer restores the projection")
	if bool(restored_state.get("ok", false)):
		var farm: RefCounted = restored_state.farm
		_expect(farm.snapshot().get("bags", {}).has(A)
			and not farm.snapshot().get("bags", {}).has(B),
			"The restored local state has only the viewer's bag")
		var sum: Dictionary = farm.snapshot().get("economy", {})
		_expect(not sum.has("ledger") and not sum.has("trades"),
			"The restored local state stays a view, not a ledger copy")
	member.free()


func _test_budget() -> void:
	var caps := HeadlessWorld.new()
	var opened: Dictionary = caps.open(dir.path_join("caps"), START, "world-projection-caps")
	_expect(bool(opened.get("ok", false)) and caps.farm != null, "A schema-cap world opens")
	if not bool(opened.get("ok", false)) or caps.farm == null:
		return
	_fill_to_caps(caps)
	var document: Dictionary = WorldProjection.project_summary(
		caps, "player_00", WorldInvite.MEMBER, 100000)
	var json: String = JSON.stringify(document)
	var raw_bytes: int = json.to_utf8_buffer().size()
	var encoded: Dictionary = WorldPayload.encode(json)
	print("PROJECTION_BUDGET raw=%d wire=%d compressed=%s" % [
		raw_bytes, int(encoded.get("wire_bytes", -1)), str(encoded.get("compressed", false))])
	_expect(bool(encoded.get("ok", false)), "The schema-cap projection encodes")
	_expect(int(encoded.get("wire_bytes", -1)) <= WorldPayload.WIRE_BUDGET_BYTES,
		"The schema-cap projection fits the 48 KiB wire budget")
	_expect(not ((document.get("snapshot", {}) as Dictionary)
		.get("farm", {}) as Dictionary).get("economy", {}).has("ledger"),
		"The schema-cap projection carries no ledger")


## The measured schema-cap world: 12 × 32 cells, 256 orders/shipments/
## deliveries, 512 trades/ledger rows and 64 recorded command results. Copied
## from world_payload_test so the budget probe uses the same shape.
func _fill_to_caps(world: HeadlessWorld) -> void:
	var farm: RefCounted = world.farm
	var at: float = START
	var layout: Dictionary = farm._data.layout
	var source_fields: Array = layout.fields.duplicate(true)
	var fields: Array = []
	var tables: Dictionary = {}
	var index: int = 0
	for source: Dictionary in source_fields:
		for _copy_index: int in 2:
			if index >= 12:
				break
			var field_id: String = "field_%02d" % index
			var cells: Array[String] = []
			var table: Dictionary = {}
			for cell_index: int in 32:
				var cell_id: String = "cell_%02d" % [cell_index + 1]
				cells.append(cell_id)
				var cell: Dictionary = farm._data.fields[source.id].cells[
					"cell_%02d" % [(cell_index % 16) + 1]].duplicate(true)
				if cell_index % 3 != 0:
					cell.crop_id = "greens" if cell_index % 2 == 0 else "radish"
					cell.growth_seconds = 1200.0
					cell.planted_by = "player_%02d" % [index % 8]
				table[cell_id] = cell
			var field: Dictionary = source.duplicate(true)
			field.id = field_id
			field.cells = cells
			field.position = [float(index) * 1.1, 0.2, float(index % 3) * 1.1]
			fields.append(field)
			tables[field_id] = {"cells": table}
			index += 1
		if index >= 12:
			break
	layout.fields = fields
	farm._data.fields = tables
	farm._data.bags = {}
	for player_index: int in 8:
		var bag: Dictionary = {}
		for crop_id: String in farm._data.inventory.keys():
			bag[crop_id] = 100 + player_index
		farm._data.bags["player_%02d" % player_index] = bag
	farm.economy_open_account("cap-acct", "player_00", at)
	farm.market_open_merchant("cap-market", at)
	farm.economy_open_bank("cap-bank", at)
	farm._data.bags["player_00"] = {"greens": 5000}
	farm.market_place_order("cap-order", "player_00", "sell", "greens", 5, 2,
		at + 86400.0, at)
	farm.market_ship("cap-ship", "player_00", Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, "greens", 2, at)
	var market: Dictionary = farm._data.economy.market
	var order_template: Dictionary = market.orders["cap-order"].duplicate(true)
	market.orders = {}
	for order_index: int in 256:
		var order: Dictionary = order_template.duplicate(true)
		order.id = "order-%04d-%s" % [order_index, "o".repeat(24)]
		order.sequence = order_index + 1
		order.owner = "player_%02d" % [order_index % 8]
		order.created_utc = at + order_index
		order.expires_utc = at + 86400.0 + order_index
		market.orders[order.id] = order
	var shipment_template: Dictionary = market.shipments["cap-ship"].duplicate(true)
	market.shipments = {}
	for ship_index: int in 256:
		var shipment: Dictionary = shipment_template.duplicate(true)
		shipment.id = "shipment-%04d-%s" % [ship_index, "s".repeat(24)]
		shipment.sequence = ship_index + 1
		shipment.owner = "player_%02d" % [ship_index % 8]
		market.shipments[shipment.id] = shipment
	market.deliveries = {}
	for delivery_index: int in 256:
		var delivery_id: String = "delivery-%04d-%s" % [delivery_index, "d".repeat(24)]
		market.deliveries[delivery_id] = {
			"id": delivery_id, "sequence": delivery_index + 1,
			"shipment_id": "shipment-%04d-%s" % [delivery_index, "s".repeat(24)],
			"owner": "player_%02d" % [delivery_index % 8], "good": "greens",
			"quantity": 2, "origin": Market.LOCATION_FARM,
			"destination": Market.LOCATION_HARBOR,
			"delivered_utc": at + delivery_index, "fee": 2}
	market.trades = {}
	for trade_index: int in 512:
		var trade_id: String = "trade_%06d" % [trade_index + 1]
		market.trades[trade_id] = {
			"id": trade_id, "sequence": trade_index + 1,
			"buy": "order-%04d-%s" % [trade_index % 256, "o".repeat(24)],
			"sell": "order-%04d-%s" % [(trade_index + 1) % 256, "o".repeat(24)],
			"buyer": "player_%02d" % [trade_index % 8],
			"seller": "player_%02d" % [(trade_index + 1) % 8],
			"good": "greens", "price": 5, "quantity": 1, "fee": 1,
			"at_utc": at + trade_index}
	var accounts: Dictionary = {}
	for account_index: int in 8:
		accounts["player_%02d" % account_index] = {
			"cash": 100000 + account_index, "granted": true,
			"pay_seq": account_index + 1}
	farm._data.economy.accounts = accounts
	var ledger: Dictionary = farm._data.economy.ledger
	var entry_template: Dictionary = (ledger.entries as Dictionary).values()[0].duplicate(true)
	var entries: Dictionary = {}
	for entry_index: int in 512:
		var entry: Dictionary = entry_template.duplicate(true)
		var entry_id: String = "ledger_%06d" % [entry_index + 1]
		entry.id = entry_id
		entry.sequence = entry_index + 1
		entry.event_id = "event-%04d-%s" % [entry_index, "e".repeat(24)]
		entry.kind = "trade"
		entry.at_utc = at + entry_index
		entries[entry_id] = entry
	farm._data.economy.ledger.entries = entries
	farm._data.transaction.command_results = {}
	for result_index: int in 64:
		farm._data.transaction.command_results[
			"command-%03d-%s" % [result_index, "r".repeat(40)]] = {
			"payload": JSON.stringify(["market_place", "player_00", "sell", "greens",
				5, 1, 999999, at, "pad".repeat(80)]),
			"result": {"ok": true, "reason": "", "changed_fields": ["field_01"],
				"visual_changed": [], "reward_crop_id": "", "reward_amount": 0}}
	farm._data.transaction.sequence = 100000


static func _view_is(value: Variant, viewer: String, role: String) -> bool:
	return value is Dictionary and int(value.get("version", 0)) == WorldProjection.VIEW_VERSION \
		and str(value.get("viewer", "absent")) == viewer and str(value.get("role", "")) == role


static func _dict(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("WORLD_PROJECTION_TEST checks=%d failures=%d dir=%s" % [
		checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
