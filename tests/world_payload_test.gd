extends SceneTree
## ADR-026: one wire budget for authority→member documents.
##
## The transport drops an oversized packet and still reports OK, so the only
## place to catch it is before rpc_id. This test proves:
##   - a real schema-cap world exceeds 48 KiB as JSON and its compressed form
##     fits, decodes back byte-for-byte and restores to the same authority;
##   - under-budget documents stay plain;
##   - an incompressible document fails with a named reason instead of a payload;
##   - malformed prefixes, forged lengths and failed decompression each name
##     their own failure;
##   - the host counts and refuses an oversized summary;
##   - the client session node decodes the compressed summary and rejects a
##     damaged one without overwriting its state.

const HeadlessWorld = preload("res://world/headless_world.gd")
const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const WorldClient = preload("res://world/world_client.gd")
const WorldPayload = preload("res://world/world_payload.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const Market = preload("res://farm/market_state.gd")

const START: float = 1800000000.0
const PEER: int = 7

var checks: int = 0
var failures: Array[String] = []
var dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir() \
		.path_join(".local/verification/world-payload-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var caps := HeadlessWorld.new()
	var opened: Dictionary = caps.open(dir.path_join("caps"), START, "world-payload")
	_expect(opened.ok and caps.farm != null, "A schema-cap world opens")
	if not opened.ok or caps.farm == null:
		_finish()
		return
	_fill_to_caps(caps)
	_test_caps_round_trip(_summary_document(caps, "world-payload"))

	# A world built only through the public rules is the restorable case: it is
	# still over 48 KiB, so it really exercises compression, and the decoded
	# document must rebuild the same farm/decorations/nature.
	var normal := HeadlessWorld.new()
	var normal_opened: Dictionary = normal.open(dir.path_join("normal"), START, "world-normal")
	_expect(normal_opened.ok and normal.farm != null, "A normal-size world opens")
	var restorable: Dictionary = _summary_document(caps, "world-payload")
	if normal_opened.ok and normal.farm != null:
		_build_realistic(normal)
		restorable = _summary_document(normal, "world-normal")
		_test_restore_round_trip(restorable, normal)

	_test_plain_and_failures()
	_test_client_node(restorable)
	_test_host_rejection()
	_test_social_budget()
	_test_tail_trim()
	_finish()


## The schema-cap shape is the largest measured document. It is built by direct
## row injection, so it proves the size and byte fidelity path rather than a
## restorable world (the public-rules fixture below covers restore).
func _test_caps_round_trip(document: Dictionary) -> void:
	var json: String = JSON.stringify(document)
	var raw_bytes: int = json.to_utf8_buffer().size()
	_expect(raw_bytes > WorldPayload.WIRE_BUDGET_BYTES,
		"The schema-cap summary exceeds the wire budget as JSON (%d bytes)" % raw_bytes)
	var encoded: Dictionary = WorldPayload.encode(json)
	_expect(bool(encoded.get("ok", false)), "The oversized summary encodes")
	_expect(bool(encoded.get("compressed", false)), "The oversized summary is compressed")
	_expect(int(encoded.get("wire_bytes", -1)) <= WorldPayload.WIRE_BUDGET_BYTES,
		"The compressed summary fits the wire budget (%d bytes)" % int(encoded.get("wire_bytes", -1)))
	_expect(int(encoded.get("wire_bytes", -1)) < raw_bytes,
		"The compressed summary is smaller than the JSON")
	_expect(str(encoded.get("payload", "")).begins_with("z1:"),
		"The wire form carries the z1 prefix")
	var decoded: Dictionary = WorldPayload.decode(str(encoded.get("payload", "")))
	_expect(bool(decoded.get("ok", false)), "The compressed summary decodes")
	_expect(int(decoded.get("raw_bytes", -1)) == raw_bytes,
		"The decoded document reports its original length")
	_expect(str(decoded.get("text", "")) == json,
		"The decoded document is byte-equivalent to the authority JSON")


## A real world over the budget must compress, decode and restore to exactly the
## authority's farm, decorations and nature.
func _test_restore_round_trip(document: Dictionary, world: HeadlessWorld) -> void:
	var json: String = JSON.stringify(document)
	_expect(json.to_utf8_buffer().size() > WorldPayload.WIRE_BUDGET_BYTES,
		"The normal world exceeds the wire budget as JSON (%d bytes)"
		% json.to_utf8_buffer().size())
	var encoded: Dictionary = WorldPayload.encode(json)
	_expect(bool(encoded.get("ok", false)) and bool(encoded.get("compressed", false)),
		"The normal world travels compressed")
	var decoded: Dictionary = WorldPayload.decode(str(encoded.get("payload", "")))
	_expect(bool(decoded.get("ok", false)), "The normal world decodes")
	var restored_doc: Variant = JSON.parse_string(str(decoded.get("text", "")))
	_expect(restored_doc is Dictionary, "The decoded text is valid JSON")
	if not restored_doc is Dictionary:
		return
	var member := WorldMember.new()
	member.snapshot = (restored_doc as Dictionary).get("snapshot", {})
	var restored: Dictionary = member.restore_state()
	_expect(bool(restored.get("ok", false)), "The decoded snapshot restores (%s)"
		% str(restored.get("reason", "")))
	if bool(restored.get("ok", false)):
		_expect((restored.farm as RefCounted).snapshot() == world.farm.snapshot(),
			"The restored farm equals the authority")
		_expect((restored.decorations as RefCounted).snapshot() == world.decorations.snapshot(),
			"The restored decorations equal the authority")
		_expect((restored.nature as RefCounted).snapshot() == world.nature.snapshot(),
			"The restored nature equals the authority")
	member.free()


func _test_plain_and_failures() -> void:
	var small: String = JSON.stringify({"ok": true, "reason": ""})
	var plain: Dictionary = WorldPayload.encode(small)
	_expect(bool(plain.get("ok", false)) and not bool(plain.get("compressed", false)),
		"A small document stays plain JSON")
	_expect(str(plain.get("payload", "")) == small, "The plain document is unchanged")

	var plain_decoded: Dictionary = WorldPayload.decode(small)
	_expect(bool(plain_decoded.get("ok", false)) and str(plain_decoded.text) == small,
		"A plain document decodes to itself")
	var oversize_plain: Dictionary = WorldPayload.decode("x".repeat(WorldPayload.WIRE_BUDGET_BYTES + 1))
	_expect(str(oversize_plain.get("reason", "")) == "payload_too_large",
		"An over-budget plain document is refused")

	# Random bytes do not compress, so this is the real "still over after zstd"
	# case rather than a synthetic size check.
	var incompressible: String = JSON.stringify({
		"ok": false, "reason": "fixture",
		"blob": Crypto.new().generate_random_bytes(80000).hex_encode(),
	})
	var refused: Dictionary = WorldPayload.encode(incompressible)
	_expect(not bool(refused.get("ok", true)), "An incompressible document is refused")
	_expect(str(refused.get("reason", "")) == "payload_too_large",
		"The refusal names payload_too_large")
	_expect(str(refused.get("payload", "not-empty")).is_empty(),
		"The refusal carries no payload to send")
	_expect(bool(refused.get("compressed", false)),
		"The refusal happened after compression was attempted")

	_expect(str(WorldPayload.decode("z1").get("reason", "")) == "payload_invalid_prefix",
		"A prefix without a colon is refused by name")
	_expect(str(WorldPayload.decode("z1:abc:AAAA").get("reason", "")) == "payload_invalid_prefix",
		"A non-numeric declared length is refused by name")
	_expect(str(WorldPayload.decode("z1:%d:AAAA" % (WorldPayload.CONTENT_MAX_BYTES + 1)) \
		.get("reason", "")) == "payload_too_large",
		"A declared length over the content cap is refused")

	var hello: PackedByteArray = "hello".to_utf8_buffer().compress(FileAccess.COMPRESSION_ZSTD)
	var hello64: String = Marshalls.raw_to_base64(hello)
	var too_short: Dictionary = WorldPayload.decode("z1:4:%s" % hello64)
	_expect(str(too_short.get("reason", "")) == "payload_decode_failed",
		"Decompression to a shorter length fails by name")
	var too_long: Dictionary = WorldPayload.decode("z1:6:%s" % hello64)
	_expect(str(too_long.get("reason", "")) == "payload_length_mismatch",
		"A declared length longer than the data is a length mismatch")
	var good: Dictionary = WorldPayload.decode("z1:5:%s" % hello64)
	_expect(bool(good.get("ok", false)) and str(good.text) == "hello",
		"A valid compressed document decodes")

	# An empty document would erase a confirmed state, so it is a named failure
	# on every encoding, including a zero-length compressed one.
	for empty: String in ["", "   ", "\n\t"]:
		_expect(str(WorldPayload.decode(empty).get("reason", "")) == "payload_decode_failed",
			"An empty payload is refused (%s)" % JSON.stringify(empty))
	_expect(str(WorldPayload.decode("z1:0:").get("reason", "")) == "payload_decode_failed",
		"A zero-length compressed document is refused")
	_expect(WorldPayload.is_refusal({"error": "rate_limited"}, "rate_limited")
		and WorldPayload.is_refusal({"reason": "rate_limited"}, "rate_limited")
		and not WorldPayload.is_refusal({"ok": true, "reason": ""}, "rate_limited"),
		"Both spellings of the host refusal are recognised")
	_expect(WorldPayload.is_summary_refusal({"ok": false, "reason": "payload_too_large"})
		and WorldPayload.is_summary_refusal({"ok": false, "error": "rate_limited"})
		and not WorldPayload.is_summary_refusal({"ok": true, "reason": ""}),
		"Both summary refusals are recognised; a real snapshot is not")


## The client session node decodes before the base member parses JSON. It is the
## same node WorldClient creates, not a copy of the logic.
func _test_client_node(document: Dictionary) -> void:
	var json: String = JSON.stringify(document)
	var encoded: Dictionary = WorldPayload.encode(json)
	var wire := WorldClient.WireMember.new()
	var replies: Array = []
	var losses: Array[String] = []
	wire.reply_received.connect(func(request_id: String, payload: Dictionary) -> void:
		replies.append([request_id, payload]))
	wire.authority_lost.connect(func(reason: String) -> void: losses.append(reason))
	wire.command_result("summary", str(encoded.get("payload", "")))
	_expect(replies.size() == 1, "The client node accepts the compressed summary")
	if replies.size() == 1:
		var carried: Dictionary = (replies[0] as Array)[1]
		_expect(str(carried.get("world_id", "")) == str(document.get("world_id", "")),
			"The client node reads the decoded summary")
		_expect((wire.snapshot.get("farm", {}) as Dictionary).size() > 0,
			"The client node keeps the decoded snapshot")
		_expect(wire.restore_state().ok, "The client node restores the decoded snapshot")

	var before: Dictionary = wire.snapshot
	var replies_before: int = replies.size()
	wire.command_result("summary", JSON.stringify({"ok": false,
		"error": "payload_too_large", "reason": "payload_too_large"}))
	_expect(replies.size() == replies_before + 1,
		"The client node surfaces the host's payload refusal")
	_expect(wire.snapshot == before,
		"A host payload refusal keeps the last good snapshot")

	# A rate-limited summary is the second transient refusal: it must not look
	# like a broken snapshot either.
	wire.command_result("summary", JSON.stringify({"ok": false, "reason": "rate_limited"}))
	_expect(replies.size() == replies_before + 2,
		"The client node surfaces a rate-limited summary")
	_expect(wire.snapshot == before,
		"A rate-limited summary keeps the last good snapshot")

	wire.command_result("summary", "z1:6:%s" % Marshalls.raw_to_base64(
		"hello".to_utf8_buffer().compress(FileAccess.COMPRESSION_ZSTD)))
	_expect(losses == ["payload_length_mismatch"],
		"A damaged payload reports its named failure to the client")
	_expect(wire.snapshot == before,
		"A damaged payload does not overwrite the last good snapshot")

	# Valid JSON that is not a document would reach the base as `{}` and erase
	# the snapshot, so it is treated as a damaged payload instead.
	var replies_after: int = replies.size()
	var losses_after: int = losses.size()
	wire.command_result("summary", "null")
	_expect(replies.size() == replies_after and losses.size() == losses_after + 1,
		"A non-object document never reaches the base")
	_expect(wire.snapshot == before, "A non-object document keeps the last good snapshot")

	# Social replies use their own RPC channel and the client node decodes them
	# the same way before the base member parses them.
	var social_rows: Array = []
	for index: int in 256:
		social_rows.append({"id": "msg_%d" % index, "from": "player_%d" % index,
			"from_name": "邻居%d" % index, "to": "", "to_name": "",
			"text": "字".repeat(200), "at": START + float(index), "read": false})
	var social_encoded: Dictionary = WorldPayload.encode(JSON.stringify(
		{"ok": true, "reason": "", "view": {"player_id": "player_self", "inbox": social_rows}}))
	var social_results: Array = []
	wire.social_result.connect(func(request_id: String, payload: Dictionary) -> void:
		social_results.append([request_id, payload]))
	wire._social_reply("state", str(social_encoded.get("payload", "")))
	_expect(bool(social_encoded.get("ok", false)) and social_results.size() == 1,
		"The client node decodes a social reply")
	if social_results.size() == 1:
		var social_reply: Dictionary = (social_results[0] as Array)[1]
		_expect(bool(social_reply.get("ok", false))
			and (social_reply.get("view", {}) as Dictionary).get("inbox", []).size() == 256,
			"The decoded social reply carries the whole inbox")
	wire.free()


## The host refuses instead of calling rpc_id with an impossible document. There
## is no transport peer in this fixture, so the refusal RPC itself is expected to
## be rejected by SceneMultiplayer; the counter and result are what matter.
func _test_host_rejection() -> void:
	var host := WorldHost.new()
	root.add_child(host)
	_expect(host.configure(dir.path_join("reject"), START, "world-reject").ok,
		"The rejection fixture opens its own world")
	host._members[PEER] = WorldInvite.MEMBER
	var giant: Dictionary = {
		"ok": false, "reason": "fixture", "fields": {},
		"blob": Crypto.new().generate_random_bytes(80000).hex_encode(),
	}
	var before: int = host.payload_rejections
	var sent: Dictionary = host._send_summary(PEER, giant)
	_expect(not bool(sent.get("ok", true)), "The host refuses the incompressible summary")
	_expect(str(sent.get("reason", "")) == "payload_too_large",
		"The host refusal names payload_too_large")
	_expect(host.payload_rejections == before + 1,
		"The host counted the rejection")
	host.queue_free()


## Social state replies are the largest variable document after the summary:
## a full inbox of maximum-length messages already exceeds the plain budget, so
## they must be decided on their own RPC channel instead of being handed to the
## transport.
func _test_social_budget() -> void:
	var host := WorldHost.new()
	root.add_child(host)
	_expect(host.configure(dir.path_join("social"), START, "world-social").ok,
		"The social fixture opens its own world")
	host._members[PEER] = WorldInvite.MEMBER
	var rows: Array = []
	for index: int in 256:
		rows.append({"id": "msg_%d" % index, "from": "player_%d" % index,
			"from_name": "邻居%d" % index, "to": "", "to_name": "",
			"text": "字".repeat(200), "at": START + float(index), "read": false})
	var document: Dictionary = {"ok": true, "reason": "",
		"view": {"player_id": "player_self", "inbox": rows}}
	var encoded: Dictionary = WorldPayload.encode(JSON.stringify(document))
	_expect(int(encoded.get("raw_bytes", 0)) > WorldPayload.WIRE_BUDGET_BYTES,
		"A full social inbox is over the plain wire budget")
	_expect((bool(encoded.get("ok", false))
			and int(encoded.get("wire_bytes", 0)) <= WorldPayload.WIRE_BUDGET_BYTES)
		or (not bool(encoded.get("ok", true))
			and str(encoded.get("reason", "")) == "payload_too_large"),
		"A full social reply either fits the budget or is refused by name")
	var before: int = host.payload_rejections
	host._send_social(PEER, "social-refused", {"ok": false,
		"blob": Crypto.new().generate_random_bytes(80000).hex_encode()})
	_expect(host.payload_rejections == before + 1,
		"The social channel counts its own rejection")
	host.queue_free()


## A byte-overflowing tail is a hole if the oldest events are dropped: the host
## names a floor and sends no events rather than a partial list.
func _test_tail_trim() -> void:
	var host := WorldHost.new()
	root.add_child(host)
	_expect(host.configure(dir.path_join("trim"), START, "world-trim").ok,
		"The trim fixture opens its own world")
	host._members[PEER] = WorldInvite.MEMBER
	host._tail.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261115
	for index: int in 300:
		host._tail.append({
			"sequence": index + 1, "stage": "committed", "reward_crop_id": "",
			"reward_amount": 0,
			"from_id": _hex(rng, 64), "from_name": _hex(rng, 72),
			"command": {"id": _hex(rng, 128), "kind": "sow", "noise": _hex(rng, 200)},
		})
	host._tail_floor = 1
	var full: Dictionary = {"ok": true, "reason": "", "events": host._tail.duplicate(true),
		"current": 0}
	_expect(not WorldPayload.fits(JSON.stringify(full)),
		"The injected tail is over budget even after compression")
	var reply: Dictionary = host.tail_since(0)
	_expect(not bool(reply.get("ok", true)), "An over-budget tail is not reported as ok")
	_expect(str(reply.get("reason", "")) == "tail_expired",
		"An over-budget tail asks for a snapshot")
	_expect((reply.get("events", [null]) as Array).is_empty(),
		"An over-budget tail never returns a partial list")
	_expect(int(reply.get("floor", 0)) > 1,
		"The refusal names the first event the budget can carry")
	host.queue_free()


func _summary_document(world: HeadlessWorld, world_id: String) -> Dictionary:
	var document: Dictionary = world.summary()
	document["world_id"] = world_id
	document["run_generation"] = 1
	document["role"] = WorldInvite.MEMBER
	document["snapshot"] = world.state_snapshot()
	return document


## Eight accounts, a market with orders/shipments/deliveries, payments and 64
## sown cells — all through the public rules, so the result restores.
func _build_realistic(world: HeadlessWorld) -> void:
	var farm = world.farm
	var at: float = START
	var players: Array[String] = []
	for index: int in 8:
		players.append("player_%02d" % index)
	for owner: String in players:
		farm.economy_open_account("acct-%s" % owner, owner, at)
		at += 1.0
	farm.economy_open_bank("bank-open", at)
	at += 1.0
	farm.market_open_merchant("market-open", at)
	at += 1.0
	for index: int in 6:
		farm.economy_pay("pay-%02d" % index, players[0],
			players[(index + 1) % players.size()], 11 + index, index + 1, at)
		at += 1.0
	for owner: String in players:
		farm._data.bags[owner] = {"greens": 200, "spinach": 200, "radish": 200,
			"carrot": 200, "celery": 200, "garlic": 200}
	var goods: Array[String] = ["greens", "spinach", "radish", "carrot", "celery", "garlic"]
	for index: int in 24:
		var owner: String = players[index % players.size()]
		var side: String = "buy" if index % 2 == 0 else "sell"
		farm.market_place_order("order-%03d-%s" % [index, "a".repeat(16)], owner, side,
			goods[index % goods.size()], 4 + index, 2, at + 86400.0, at)
		at += 1.0
	for index: int in 8:
		farm.market_ship("ship-%03d-%s" % [index, "b".repeat(16)],
			players[index % players.size()], Market.LOCATION_FARM,
			Market.LOCATION_HARBOR, "greens", 2, at)
		at += 1.0
	at += 1200.0
	world.advance_to(at)
	farm.market_match(at)
	farm.market_deliver(at)
	var planted: int = 0
	for field: Dictionary in farm._data.layout.fields:
		for cell_index: int in 16:
			if planted >= 64:
				break
			var cell_id: String = "cell_%02d" % (cell_index + 1)
			if str(farm._data.fields[field.id].cells[cell_id].ground) != "ready":
				continue
			var actor: String = players[planted % players.size()]
			var result: Dictionary = farm.sow(str(field.id), cell_id,
				"greens" if planted % 2 == 0 else "radish", at, actor)
			if bool(result.get("ok", false)):
				planted += 1
				farm.commit_command("sow-%03d-%s" % [planted, "c".repeat(12)],
					JSON.stringify(["sow", field.id, cell_id, at, "greens"]), result)
				at += 1.0
		if planted >= 64:
			break


func _hex(rng: RandomNumberGenerator, length: int) -> String:
	var text: String = ""
	for _index: int in length:
		text += "0123456789abcdef"[rng.randi() % 16]
	return text


## Builds the measured schema-cap world: 12 × 32 cells, 256 orders/shipments/
## deliveries, 512 trades/ledger rows and 64 recorded command results.
func _fill_to_caps(world: HeadlessWorld) -> void:
	var farm = world.farm
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
	farm.market_place_order("cap-order", "player_00", "sell", "greens", 5, 2, at + 86400.0, at)
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


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("WORLD_PAYLOAD_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
