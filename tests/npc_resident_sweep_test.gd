extends SceneTree
## M10-03 居民意图接入世界权威的可玩切片。无头、隔离：临时目录写在
## `.local/verification` 下，使用真实的 `HeadlessWorld`、真实经济账户、真实
## 市场卖单与真实撮合，不使用假余额或假成交。
##
## 覆盖：
##   - 默认关闭：经济扫描与居民结算都不建居民账户、不产生交易；
##   - 启用后阿舟用真实预算从公开卖单买入，现金减少、货物增加、卖单余量减少；
##   - 同一时刻重复扫描不重复买；
##   - 过期意图被 `validate` 拒绝且不成交；
##   - 重启后账本仍在，同一 intent id 再次校验返回已消费；
##   - 账本损坏/版本不支持时 `open()` 返回 `load_residents_*`；
##   - 现金与货物总量仍符合既有市场规则。

const World = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Market = preload("res://farm/market_state.gd")
const Catalog = preload("res://farm/economy_catalog.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")
const NpcIntent = preload("res://npc/npc_intent.gd")
const ResidentLedger = preload("res://npc/npc_resident_ledger.gd")

const START: float = 1800000000.0
const AT: float = START + 10.0
const COOLDOWN: float = 300.0
const A_ZHOU: String = "npc_a_zhou"
const SELLER_ASK_PREFIX: String = "merchant_ask_"

var checks: int = 0
var failures: Array[String] = []
var test_root: String = ""

var world: RefCounted
var purchase_directory: String = ""
var zhou_intent_id: String = ""
var zhou_good: String = ""
var zhou_quantity: int = 0
var zhou_price: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	test_root = project_root.get_base_dir().path_join(
		".local/verification/npc-resident-sweep-%d/run-%d" % [
			OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_disabled_by_default()
	_test_enabled_purchase()
	_test_same_instant_is_idempotent()
	_test_expired_intent_does_not_trade()
	_test_restart_keeps_consumed_intent()
	_test_corrupt_ledger_is_refused()
	_test_ledger_rules()
	for failure: String in failures:
		push_error(failure)
	print("NPC_RESIDENT_SWEEP_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


## 默认关闭时，既有世界行为不变：开市只产生商人报价，不产生任何居民账户或交易。
func _test_disabled_by_default() -> void:
	var directory: String = test_root.path_join("disabled")
	var closed := World.new()
	_expect(bool(closed.open(directory, START).ok), "disabled: world opens")
	_expect(not closed.residents_enabled, "disabled: residents start disabled")
	_expect(closed.residents.has("residents")
		and (closed.residents.residents as Dictionary).is_empty(),
		"disabled: the missing resident ledger loads as an empty document")
	var market: Dictionary = closed.execute(
		FarmCommand.make_market_open("disabled-market", START))
	_expect(bool(market.ok), "disabled: the merchant market opens: "
		+ str(market.get("reason", "")))
	var asks_before: Dictionary = _ask_remaining(closed.farm)
	var swept: Dictionary = closed.settle_economy_now(AT)
	_expect(bool(swept.ok), "disabled: the economy sweep succeeds: "
		+ str(swept.get("reason", "")))
	_expect(_ask_remaining(closed.farm) == asks_before,
		"disabled: the economy sweep changes no merchant ask")
	for npc_id: String in NpcRoster.IDS:
		_expect(not _account_exists(closed.farm, npc_id),
			"disabled: %s has no economy account" % npc_id)
	var settled: Dictionary = closed.settle_residents(AT)
	_expect(bool(settled.ok), "disabled: settle_residents is a benign no-op")
	_expect(str(settled.get("reason", "")) == "disabled",
		"disabled: the resident sweep reports disabled")
	_expect(not bool(settled.get("changed", true)),
		"disabled: the resident sweep changes nothing")
	for npc_id: String in NpcRoster.IDS:
		_expect(not _account_exists(closed.farm, npc_id),
			"disabled: %s still has no account after the resident sweep" % npc_id)
		_expect(_bag_total(closed.farm, npc_id) == 0,
			"disabled: %s still has no goods" % npc_id)
	_expect(closed.farm.market_trades().is_empty(),
		"disabled: no trade was produced")


## 启用后三名居民各开一次户并完成一次真实买入。阿舟用真实预算从公开卖单成交。
func _test_enabled_purchase() -> void:
	purchase_directory = test_root.path_join("purchase")
	world = World.new()
	var opened: Dictionary = world.open(purchase_directory, START)
	_expect(bool(opened.ok), "enabled: world opens")
	var market: Dictionary = world.execute(
		FarmCommand.make_market_open("purchase-market", START))
	_expect(bool(market.ok), "enabled: the merchant market opens with public asks: "
		+ str(market.get("reason", "")))
	var enabled: Dictionary = world.enable_residents()
	_expect(bool(enabled.ok) and bool(enabled.get("enabled", false)),
		"enabled: enable_residents only sets the flag")
	_expect(world.residents_enabled, "enabled: the authority sees residents enabled")
	var asks_before: Dictionary = _ask_remaining(world.farm)
	var settled: Dictionary = world.settle_residents(AT)
	_expect(bool(settled.ok), "enabled: the resident sweep succeeds: "
		+ str(settled.get("reason", "")))
	_expect(bool(settled.get("changed", false)), "enabled: the sweep reports a change")
	_expect(int(settled.counts.get("opened", 0)) == 3,
		"enabled: all three residents opened an account")
	_expect(int(settled.counts.get("purchased", 0)) == 3,
		"enabled: all three residents completed a purchase")
	_expect((settled.failures as Array).is_empty(),
		"enabled: no resident failed: " + str(settled.failures))
	for npc_id: String in NpcRoster.IDS:
		_expect(_account_exists(world.farm, npc_id)
			and world.farm.economy_granted(npc_id),
			"enabled: %s holds a granted account" % npc_id)
		_expect(world.farm.economy_cash(npc_id) > 0,
			"enabled: %s holds real cash" % npc_id)
	_expect(world.farm.economy_cash(A_ZHOU) < 120,
		"enabled: A Zhou spent part of the opening grant")
	var bag: Dictionary = world.farm.economy_goods(A_ZHOU)
	zhou_good = _first_good(bag)
	zhou_quantity = int(bag.get(zhou_good, 0))
	_expect(not zhou_good.is_empty() and zhou_quantity > 0,
		"enabled: A Zhou's bag gained goods")
	_expect(int(asks_before.get(zhou_good, 0)) > 0,
		"enabled: the bought good had a public ask before the sweep")
	_expect(int(asks_before.get(zhou_good, 0))
		> int(_ask_remaining(world.farm).get(zhou_good, 0)),
		"enabled: A Zhou's purchase reduced the remaining public supply")
	_expect(world.farm.market_trades().size() == 3,
		"enabled: three real trades settled")
	# The consumed intent is persisted in the resident ledger.
	var ledger: Dictionary = world.residents
	_expect(ResidentLedger.valid(ledger), "enabled: the resident ledger stays valid")
	_expect((ledger.residents as Dictionary).has(A_ZHOU),
		"enabled: the ledger has an A Zhou entry")
	var zhou_state: Dictionary = ResidentLedger.state_for(ledger, A_ZHOU)
	_expect((zhou_state.intents as Dictionary).size() == 1,
		"enabled: A Zhou consumed exactly one intent")
	for intent_id: Variant in zhou_state.intents:
		zhou_intent_id = str(intent_id)
		_expect(is_equal_approx(float(zhou_state.intents[intent_id]), AT),
			"enabled: the consumed intent is stamped at the sweep instant")
	_expect(is_equal_approx(float(zhou_state.until_utc), AT + COOLDOWN),
		"enabled: the resident cooldown moved forward")
	var row: Dictionary = world.farm.market_order(zhou_intent_id)
	_expect(not row.is_empty() and str(row.get("owner", "")) == A_ZHOU,
		"enabled: the market order id is the intent id")
	_expect(str(row.get("side", "")) == Market.SIDE_BUY
		and str(row.get("status", "")) == Market.STATUS_FILLED,
		"enabled: A Zhou's intent became a filled buy order")
	zhou_price = int(row.get("price", 0))
	_expect(zhou_quantity * zhou_price > 0,
		"enabled: the fill is priced in real COIN")
	_expect(world.farm.economy_cash(A_ZHOU) + zhou_quantity * zhou_price
		<= 120, "enabled: cash plus spend never exceeds the opening grant")
	# Existing market invariants still hold.
	_expect(bool(world.farm.economy_reconcile().ok),
		"enabled: the double-entry ledger reconciles")
	_expect(int(world.farm.economy_issued()) == int(world.farm.economy_total_cash()),
		"enabled: total cash equals issued cash")
	_expect(_goods_total(world.farm) == 120,
		"enabled: goods conservation counts merchant grant and resident bags")


## 同一时刻再扫一次不会重复买：冷却与已消费 id 都拦住。
func _test_same_instant_is_idempotent() -> void:
	var trades_before: int = world.farm.market_trades().size()
	var ledger_before: String = JSON.stringify(world.residents)
	var cash_before: int = world.farm.economy_cash(A_ZHOU)
	var asks_before: Dictionary = _ask_remaining(world.farm)
	var again: Dictionary = world.settle_residents(AT)
	_expect(bool(again.ok), "idempotent: a second sweep succeeds")
	_expect(not bool(again.get("changed", true)),
		"idempotent: a second sweep reports no change")
	_expect(int(again.counts.get("purchased", -1)) == 0,
		"idempotent: no resident buys twice")
	_expect(world.farm.market_trades().size() == trades_before,
		"idempotent: the trade count did not move")
	_expect(JSON.stringify(world.residents) == ledger_before,
		"idempotent: the resident ledger did not move")
	_expect(world.farm.economy_cash(A_ZHOU) == cash_before,
		"idempotent: A Zhou's cash did not move")
	_expect(_ask_remaining(world.farm) == asks_before,
		"idempotent: public supply did not move")
	var sweep: Dictionary = world.settle_economy_now(AT)
	_expect(bool(sweep.ok), "idempotent: the merged economy sweep succeeds")
	_expect(world.farm.market_trades().size() == trades_before,
		"idempotent: the merged sweep produced no resident trade")
	_expect(world.farm.economy_cash(A_ZHOU) == cash_before,
		"idempotent: the merged sweep left A Zhou's cash alone")


## 直接构造一个已过期的意图，`validate` 必须拒绝，市场里也不能出现它的订单。
func _test_expired_intent_does_not_trade() -> void:
	var trades_before: int = world.farm.market_trades().size()
	var intent: Dictionary = _plan_for(A_ZHOU, START - 1000.0)
	_expect(not intent.is_empty(), "expired: a synthetic intent can be planned")
	if intent.is_empty():
		return
	var context: Dictionary = _context_for(world.farm, A_ZHOU, world.residents)
	var refused: Dictionary = NpcIntent.validate(intent, context, AT)
	_expect(not bool(refused.get("ok", true)),
		"expired: validate refuses the expired intent")
	_expect(str(refused.get("reason", "")) == "expired",
		"expired: the refusal is named expired")
	_expect(world.farm.market_order(str(intent.id)).is_empty(),
		"expired: the refused intent created no market order")
	_expect(world.farm.market_trades().size() == trades_before,
		"expired: the refused intent produced no trade")


## 重启后账本仍在；同一 intent id 再校验返回 duplicate_intent，且不会再成交。
func _test_restart_keeps_consumed_intent() -> void:
	_expect(FileAccess.file_exists(purchase_directory.path_join("npc_residents.json")),
		"restart: the resident ledger sidecar exists on disk")
	var ledger_before: String = JSON.stringify(world.residents)
	var trades_before: int = world.farm.market_trades().size()
	var reopened := World.new()
	var opened: Dictionary = reopened.open(purchase_directory, START + 20.0)
	_expect(bool(opened.ok), "restart: the world reopens from disk: "
		+ str(opened.get("reason", "")))
	_expect(JSON.stringify(reopened.residents) == ledger_before,
		"restart: the resident ledger survived the restart")
	_expect(not reopened.residents_enabled,
		"restart: residents stay disabled until explicitly enabled again")
	_expect(ResidentLedger.valid(reopened.residents),
		"restart: the loaded ledger is still valid")
	var zhou_state: Dictionary = ResidentLedger.state_for(reopened.residents, A_ZHOU)
	_expect((zhou_state.intents as Dictionary).has(zhou_intent_id),
		"restart: A Zhou's consumed intent id is still recorded")
	reopened.enable_residents()
	var settled: Dictionary = reopened.settle_residents(START + 20.0)
	_expect(bool(settled.ok), "restart: the resident sweep still runs")
	_expect(not bool(settled.get("changed", true)),
		"restart: the cooldown refuses a second purchase at the same moment")
	_expect(reopened.farm.market_trades().size() == trades_before,
		"restart: no new trade happened after the restart")
	# Reconstruct the same intent payload and validate it against the loaded ledger.
	var intent: Dictionary = {
		"id": zhou_intent_id, "kind": NpcIntent.KIND_BUY, "good": zhou_good,
		"quantity": zhou_quantity, "price": zhou_price,
		"reason": NpcIntent.REASON_RESTOCK,
		"expires_utc": float(AT + NpcIntent.INTENT_TTL_SECONDS),
	}
	var context: Dictionary = _context_for(reopened.farm, A_ZHOU, reopened.residents)
	var refused: Dictionary = NpcIntent.validate(intent, context, START + 20.0)
	_expect(not bool(refused.get("ok", true)),
		"restart: the consumed intent id is refused")
	_expect(str(refused.get("reason", "")) == "duplicate_intent",
		"restart: the refusal is named duplicate_intent")
	_expect(str(reopened.farm.market_order(zhou_intent_id).get("status", ""))
		== Market.STATUS_FILLED,
		"restart: the original filled order is unchanged")


## 账本损坏或版本不支持时拒绝启动；缺失仍然可以打开为空文档。
func _test_corrupt_ledger_is_refused() -> void:
	var corrupt_dir: String = test_root.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	_write_text(corrupt_dir.path_join("npc_residents.json"), "{not json")
	var corrupt := World.new()
	var refused: Dictionary = corrupt.open(corrupt_dir, START)
	_expect(not bool(refused.ok), "corrupt: a corrupt ledger refuses the open")
	_expect(str(refused.get("reason", "")) == "load_residents_corrupt",
		"corrupt: the refusal is named load_residents_corrupt")
	var unsupported_dir: String = test_root.path_join("unsupported")
	DirAccess.make_dir_recursive_absolute(unsupported_dir)
	_write_text(unsupported_dir.path_join("npc_residents.json"),
		JSON.stringify({"version": 2, "state": {"residents": {}}}))
	var unsupported := World.new()
	var refused_version: Dictionary = unsupported.open(unsupported_dir, START)
	_expect(not bool(refused_version.ok),
		"unsupported: a newer ledger version refuses the open")
	_expect(str(refused_version.get("reason", "")) == "load_residents_unsupported",
		"unsupported: the refusal is named load_residents_unsupported")
	var shape_dir: String = test_root.path_join("bad-shape")
	DirAccess.make_dir_recursive_absolute(shape_dir)
	_write_text(shape_dir.path_join("npc_residents.json"), JSON.stringify({
		"version": 1,
		"state": {"residents": {"not_in_roster": {"until_utc": 0.0, "intents": {}}}},
	}))
	var bad_shape := World.new()
	var refused_shape: Dictionary = bad_shape.open(shape_dir, START)
	_expect(not bool(refused_shape.ok),
		"corrupt: a non-roster resident id refuses the open")
	_expect(str(refused_shape.get("reason", "")) == "load_residents_corrupt",
		"corrupt: the shape refusal is named load_residents_corrupt")
	var missing_dir: String = test_root.path_join("missing")
	var missing := World.new()
	var missing_opened: Dictionary = missing.open(missing_dir, START)
	_expect(bool(missing_opened.ok), "missing: a missing ledger opens as a fresh world")
	_expect((missing.residents.residents as Dictionary).is_empty(),
		"missing: the fresh resident ledger has no entries")


## 多居民账本的纯规则：候选写时复制、冷却、重复与名册限制。
func _test_ledger_rules() -> void:
	var empty: Dictionary = ResidentLedger.empty()
	_expect(ResidentLedger.valid(empty), "rules: the empty ledger is valid")
	var recorded: Dictionary = ResidentLedger.record(empty, A_ZHOU, "intent_rules", 100.0, 400.0)
	_expect(bool(recorded.ok), "rules: record returns a candidate document")
	_expect(ResidentLedger.valid(recorded.document),
		"rules: the candidate document is valid")
	_expect((empty.residents as Dictionary).is_empty(),
		"rules: record does not mutate its input")
	var state: Dictionary = ResidentLedger.state_for(recorded.document, A_ZHOU)
	_expect(is_equal_approx(float(state.intents["intent_rules"]), 100.0),
		"rules: the consumption stamp is stored")
	var cooling: Dictionary = ResidentLedger.cooling(recorded.document, A_ZHOU, 200.0)
	_expect(bool(cooling.ok) and bool(cooling.cooling),
		"rules: cooling is true before until_utc")
	var ready: Dictionary = ResidentLedger.cooling(recorded.document, A_ZHOU, 400.0)
	_expect(bool(ready.ok) and not bool(ready.cooling),
		"rules: cooling is false at until_utc")
	var duplicate: Dictionary = ResidentLedger.record(recorded.document, A_ZHOU,
		"intent_rules", 400.0, 700.0)
	_expect(not bool(duplicate.ok) and str(duplicate.get("reason", "")) == "duplicate_intent",
		"rules: a consumed id cannot be recorded twice")
	var outsider: Dictionary = ResidentLedger.record(recorded.document, "npc_unknown",
		"intent_other", 400.0, 700.0)
	_expect(not bool(outsider.ok) and str(outsider.get("reason", "")) == "invalid_resident",
		"rules: residents outside the roster are refused")
	var bad_invariant: Dictionary = {
		"residents": {A_ZHOU: {"until_utc": 10.0, "intents": {"intent_late": 20.0}}},
	}
	_expect(not ResidentLedger.valid(bad_invariant),
		"rules: a consumption later than until_utc is invalid")
	var extra_key: Dictionary = {"residents": {}, "extra": true}
	_expect(not ResidentLedger.valid(extra_key),
		"rules: unknown document keys are refused")
	var empty_state: Dictionary = ResidentLedger.state_for(empty, "npc_lin_shen")
	_expect(ResidentLedger.valid({"residents": {A_ZHOU: empty_state}}),
		"rules: an absent resident projects to an empty valid state")


# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------

func _context_for(farm: RefCounted, npc_id: String, ledger: Dictionary) -> Dictionary:
	return {
		"resident": {
			"id": npc_id,
			"cash": farm.economy_cash(npc_id),
			"bag": farm.economy_goods(npc_id),
		},
		"market": {"orders": _offers(farm)},
		"cooldowns": ResidentLedger.state_for(ledger, npc_id),
	}


func _plan_for(npc_id: String, at_utc: float) -> Dictionary:
	var context: Dictionary = {
		"resident": {"id": npc_id, "cash": 120, "bag": _zero_bag()},
		"market": {"orders": _offers(world.farm)},
		"cooldowns": {"until_utc": 0.0, "intents": {}},
	}
	var planned: Dictionary = NpcIntent.plan(context, at_utc)
	return planned.intent if bool(planned.get("ok", false)) else {}


func _offers(farm: RefCounted) -> Array:
	var result: Array = []
	for row: Variant in farm.market_orders():
		if not row is Dictionary:
			continue
		var order: Dictionary = row
		if str(order.get("side", "")) != Market.SIDE_SELL \
				or str(order.get("status", "")) != Market.STATUS_OPEN:
			continue
		var remaining: int = int(order.get("remaining", 0))
		var price: int = int(order.get("price", 0))
		if remaining <= 0 or price <= 0:
			continue
		result.append({"good": str(order.good), "price": price, "remaining": remaining})
	return result


func _ask_remaining(farm: RefCounted) -> Dictionary:
	var result: Dictionary = {}
	for good_id: String in Catalog.goods_ids():
		var row: Dictionary = farm.market_order(SELLER_ASK_PREFIX + good_id)
		result[good_id] = int(row.get("remaining", 0)) if not row.is_empty() else 0
	return result


func _account_exists(farm: RefCounted, npc_id: String) -> bool:
	var accounts: Variant = farm.economy_snapshot().get("accounts")
	return accounts is Dictionary and (accounts as Dictionary).has(npc_id)


func _bag_total(farm: RefCounted, npc_id: String) -> int:
	var bag: Dictionary = farm.economy_goods(npc_id)
	var total: int = 0
	for good_id: String in Catalog.goods_ids():
		total += int(bag.get(good_id, 0))
	return total


func _first_good(bag: Dictionary) -> String:
	for good_id: String in Catalog.goods_ids():
		if int(bag.get(good_id, 0)) > 0:
			return good_id
	return ""


func _zero_bag() -> Dictionary:
	var bag: Dictionary = {}
	for good_id: String in Catalog.goods_ids():
		bag[good_id] = 0
	return bag


## Goods conservation with the existing market rule: merchant stock + resident
## bags + goods still escrowed in open sell orders + goods in transit.
func _goods_total(farm: RefCounted) -> int:
	var total: int = 0
	var merchant: Dictionary = farm.market_merchant()
	var stock: Variant = merchant.get("goods")
	if stock is Dictionary:
		for good_id: String in Catalog.goods_ids():
			total += int((stock as Dictionary).get(good_id, 0))
	for npc_id: String in NpcRoster.IDS:
		total += _bag_total(farm, npc_id)
	for row: Variant in farm.market_orders():
		if row is Dictionary \
				and str(row.get("side", "")) == Market.SIDE_SELL \
				and str(row.get("status", "")) == Market.STATUS_OPEN:
			total += int(row.get("remaining", 0))
	for shipment: Variant in farm.market_shipments():
		if shipment is Dictionary \
				and str(shipment.get("status", "")) == Market.SHIPMENT_STATUS_TRANSIT:
			total += int(shipment.get("quantity", 0))
	return total


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		return
	failures.append(message)
