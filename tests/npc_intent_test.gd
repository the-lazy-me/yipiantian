extends SceneTree
## M10-03 居民意图与预算校验。无头、隔离：不读真实时钟、不接模型/网络/磁盘，
## 也不触碰农场、场景或存档。

const Intent = preload("res://npc/npc_intent.gd")

const NPC: String = "npc_a_zhou"
const START: float = 1800000000.0
const EXPIRY: float = START + 120.0

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_plan_budget_and_quantity()
	_test_no_cash()
	_test_no_supply()
	_test_nothing_needed()
	_test_cooldown()
	_test_validate_expiry()
	_test_validate_duplicate()
	_test_validate_shape()
	_test_validate_budget_and_market()
	_test_deterministic_plan()
	_test_invalid_context()
	for failure: String in failures:
		push_error(failure)
	print("NPC_INTENT_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_plan_budget_and_quantity() -> void:
	var context: Dictionary = _context(25, {"greens": 0}, [
		{"good": "greens", "price": 10, "remaining": 10},
	])
	var planned: Dictionary = Intent.plan(context, START)
	_expect(planned.ok, "有现金、有缺货供给时给出意图")
	var intent: Dictionary = planned.intent
	_expect(int(intent.quantity) == 2, "数量受现金预算约束（25 // 10 = 2）")
	_expect(int(intent.price) == 10, "限价取公开卖单的真实价格")
	_expect(str(intent.kind) == "buy" and str(intent.good) == "greens",
		"意图是买入缺货商品")
	_expect(str(intent.reason) == "restock" and str(intent.id).begins_with("intent_"),
		"意图带稳定原因和确定性前缀 id")
	_expect(is_equal_approx(float(intent.expires_utc), EXPIRY), "过期时刻由显式时间加固定寿命得出")
	var checked: Dictionary = Intent.validate(intent, context, START)
	_expect(checked.ok and str(checked.reason) == "", "刚生成的意图可以通过执行前校验")

	var capped: Dictionary = Intent.plan(_context(100, {"greens": 0}, [
		{"good": "greens", "price": 10, "remaining": 3},
	]), START)
	_expect(capped.ok and int(capped.intent.quantity) == 3, "数量也受卖单剩余约束")

	var cheapest: Dictionary = Intent.plan(_context(100, {"greens": 0, "spinach": 0}, [
		{"good": "greens", "price": 10, "remaining": 5},
		{"good": "spinach", "price": 7, "remaining": 20},
	]), START)
	_expect(cheapest.ok and str(cheapest.intent.good) == "spinach",
		"多个缺货目标时选最便宜的卖单")
	_expect(int(cheapest.intent.price) == 7 and int(cheapest.intent.quantity) == 14,
		"选中目标后仍按该卖单价计算预算数量")

	var tied: Dictionary = Intent.plan(_context(100, {"greens": 0, "spinach": 0}, [
		{"good": "spinach", "price": 9, "remaining": 5},
		{"good": "greens", "price": 9, "remaining": 5},
	]), START)
	_expect(tied.ok and str(tied.intent.good) == "greens",
		"同价时按商品 id 升序选择，不依赖卖单传入顺序")


func _test_no_cash() -> void:
	var broke: Dictionary = Intent.plan(_context(0, {"greens": 0}, [
		{"good": "greens", "price": 10, "remaining": 10},
	]), START)
	_expect(not broke.ok and str(broke.reason) == "no_cash", "无现金返回 no_cash")
	var short: Dictionary = Intent.plan(_context(9, {"greens": 0}, [
		{"good": "greens", "price": 10, "remaining": 10},
	]), START)
	_expect(not short.ok and str(short.reason) == "no_cash", "不足一份价格返回 no_cash")


func _test_no_supply() -> void:
	var empty: Dictionary = Intent.plan(_context(50, {"greens": 0}, []), START)
	_expect(not empty.ok and str(empty.reason) == "no_supply", "没有公开卖单返回 no_supply")


func _test_nothing_needed() -> void:
	var stocked: Dictionary = Intent.plan(_context(50, {"greens": 1}, [
		{"good": "greens", "price": 10, "remaining": 10},
	]), START)
	_expect(not stocked.ok and str(stocked.reason) == "nothing_needed",
		"卖单商品本人口袋已有货时返回 nothing_needed")


func _test_cooldown() -> void:
	var cooling: Dictionary = Intent.plan(
		_context(50, {"greens": 0}, [{"good": "greens", "price": 10, "remaining": 1}],
			START + 10.0), START)
	_expect(not cooling.ok and str(cooling.reason) == "cooldown",
		"冷却未结束时返回 cooldown")
	var ready: Dictionary = Intent.plan(
		_context(50, {"greens": 0}, [{"good": "greens", "price": 10, "remaining": 1}],
			START), START)
	_expect(ready.ok, "冷却边界时刻不再拦截")

	var planned: Dictionary = Intent.plan(_context(50, {"greens": 0}, [
		{"good": "greens", "price": 10, "remaining": 1},
	]), START)
	var cooling_validate: Dictionary = Intent.validate(planned.intent,
		_context(50, {"greens": 0}, [{"good": "greens", "price": 10, "remaining": 1}],
			START + 30.0), START)
	_expect(not cooling_validate.ok and str(cooling_validate.reason) == "cooldown",
		"执行前校验同样拒绝冷却中的居民")


func _test_validate_expiry() -> void:
	var context: Dictionary = _context(50, {"greens": 0}, [
		{"good": "greens", "price": 10, "remaining": 5},
	])
	var intent: Dictionary = Intent.plan(context, START).intent
	var before: Dictionary = Intent.validate(intent, context, EXPIRY - 1.0)
	_expect(before.ok, "过期前一秒仍可执行")
	var boundary: Dictionary = Intent.validate(intent, context, EXPIRY)
	_expect(not boundary.ok and str(boundary.reason) == "expired",
		"到达过期时刻即拒绝")
	var late: Dictionary = Intent.validate(intent, context, EXPIRY + 1.0)
	_expect(not late.ok and str(late.reason) == "expired", "过期后的意图被拒绝")


func _test_validate_duplicate() -> void:
	var context: Dictionary = _context(50, {"greens": 0}, [
		{"good": "greens", "price": 10, "remaining": 5},
	])
	var intent: Dictionary = Intent.plan(context, START).intent
	var consumed: Dictionary = {str(intent.id): START + 1.0}
	var duplicate: Dictionary = Intent.validate(intent,
		_context(50, {"greens": 0}, [{"good": "greens", "price": 10, "remaining": 5}],
			0.0, consumed), START + 2.0)
	_expect(not duplicate.ok and str(duplicate.reason) == "duplicate_intent",
		"同一 intent.id 已在冷却表中消费过时拒绝再次执行")


func _test_validate_shape() -> void:
	var context: Dictionary = _context(50, {"greens": 0}, [
		{"good": "greens", "price": 10, "remaining": 5},
	])
	var base: Dictionary = Intent.plan(context, START).intent

	var zero_quantity: Dictionary = base.duplicate(true)
	zero_quantity["quantity"] = 0
	_expect(str(Intent.validate(zero_quantity, context, START).reason) == "invalid_quantity",
		"数量为 0 被拒绝")
	var negative_quantity: Dictionary = base.duplicate(true)
	negative_quantity["quantity"] = -1
	_expect(str(Intent.validate(negative_quantity, context, START).reason) == "invalid_quantity",
		"负数量被拒绝")
	var float_quantity: Dictionary = base.duplicate(true)
	float_quantity["quantity"] = 1.5
	_expect(str(Intent.validate(float_quantity, context, START).reason) == "invalid_quantity",
		"小数数量被拒绝")
	var huge_quantity: Dictionary = base.duplicate(true)
	huge_quantity["quantity"] = Intent.MAX_QUANTITY + 1
	_expect(str(Intent.validate(huge_quantity, context, START).reason) == "invalid_quantity",
		"超过目录数量上限被拒绝")
	var zero_price: Dictionary = base.duplicate(true)
	zero_price["price"] = 0
	_expect(str(Intent.validate(zero_price, context, START).reason) == "invalid_price",
		"零价格被拒绝")
	var bad_kind: Dictionary = base.duplicate(true)
	bad_kind["kind"] = "sell"
	_expect(str(Intent.validate(bad_kind, context, START).reason) == "invalid_kind",
		"非买入意图被拒绝")
	var bad_good: Dictionary = base.duplicate(true)
	bad_good["good"] = "gold"
	_expect(str(Intent.validate(bad_good, context, START).reason) == "invalid_good",
		"目录外商品被拒绝")
	var bad_expiry: Dictionary = base.duplicate(true)
	bad_expiry["expires_utc"] = -1.0
	_expect(str(Intent.validate(bad_expiry, context, START).reason) == "invalid_expiry",
		"非法过期时刻被拒绝")
	var bad_id: Dictionary = base.duplicate(true)
	bad_id["id"] = "intent_0"
	_expect(str(Intent.validate(bad_id, context, START).reason) == "invalid_intent_id",
		"被篡改的意图 id 被拒绝")
	var extra_key: Dictionary = base.duplicate(true)
	extra_key["owner"] = NPC
	_expect(str(Intent.validate(extra_key, context, START).reason) == "invalid_intent",
		"意图出现额外键被拒绝")


func _test_validate_budget_and_market() -> void:
	var context: Dictionary = _context(25, {"greens": 0}, [
		{"good": "greens", "price": 10, "remaining": 10},
	])
	var base: Dictionary = Intent.plan(context, START).intent

	var over_budget: Dictionary = base.duplicate(true)
	over_budget["quantity"] = 3
	_expect(str(Intent.validate(over_budget, context, START).reason) == "insufficient_cash",
		"数量乘以限价超过现金时拒绝")

	var below_market: Dictionary = base.duplicate(true)
	below_market["price"] = 9
	_expect(str(Intent.validate(below_market, context, START).reason) == "price_above_market",
		"限价低于全部卖单时拒绝")

	var thin_context: Dictionary = _context(25, {"greens": 0}, [
		{"good": "greens", "price": 10, "remaining": 1},
	])
	_expect(str(Intent.validate(base, thin_context, START).reason) == "insufficient_supply",
		"数量超过限价内剩余供给时拒绝")

	var gone_context: Dictionary = _context(25, {"greens": 0}, [])
	_expect(str(Intent.validate(base, gone_context, START).reason) == "no_supply",
		"目标商品已无公开卖单时拒绝")


func _test_deterministic_plan() -> void:
	var first_context: Dictionary = _context(25, {"greens": 0}, [
		{"good": "greens", "price": 10, "remaining": 10},
	])
	var first: Dictionary = Intent.plan(first_context, START)
	var second: Dictionary = Intent.plan(first_context, START)
	_expect(first.ok and second.ok, "同一输入两次规划都成功")
	_expect(str(first.intent.id) == str(second.intent.id), "同一输入得到同一意图 id")
	_expect(int(first.intent.quantity) == int(second.intent.quantity)
		and int(first.intent.price) == int(second.intent.price)
		and str(first.intent.good) == str(second.intent.good)
		and is_equal_approx(float(first.intent.expires_utc), float(second.intent.expires_utc)),
		"同一输入得到同一意图内容")

	var reordered: Dictionary = Intent.plan(_context(100, {"greens": 0, "spinach": 0}, [
		{"good": "greens", "price": 10, "remaining": 5},
		{"good": "spinach", "price": 7, "remaining": 5},
	]), START)
	_expect(str(reordered.intent.good) == "spinach"
		and int(reordered.intent.price) == 7,
		"卖单顺序变化不改变确定性选择结果")

	var later: Dictionary = Intent.plan(first_context, START + 1.0)
	_expect(str(later.intent.id) != str(first.intent.id),
		"不同规划时刻得到不同意图 id")

	var replay: Dictionary = Intent.validate(first.intent, first_context, START)
	_expect(replay.ok, "确定性生成的意图能被同一上下文校验通过")


func _test_invalid_context() -> void:
	_expect(str(Intent.plan({}, START).reason) == "invalid_context", "空上下文被拒绝")
	var extra: Dictionary = _context(50, {}, [])
	extra["world_id"] = "world-a"
	_expect(str(Intent.plan(extra, START).reason) == "invalid_context", "上下文额外键被拒绝")
	var negative_cash: Dictionary = _context(50, {}, [])
	negative_cash["resident"]["cash"] = -1
	_expect(str(Intent.plan(negative_cash, START).reason) == "invalid_resident",
		"负现金被拒绝")
	var foreign_bag: Dictionary = _context(50, {"gold": 0}, [])
	_expect(str(Intent.plan(foreign_bag, START).reason) == "invalid_bag",
		"口袋里出现目录外商品被拒绝")
	var bad_order: Dictionary = _context(50, {"greens": 0}, [
		{"good": "greens", "price": 0, "remaining": 1},
	])
	_expect(str(Intent.plan(bad_order, START).reason) == "invalid_market",
		"零价卖单被拒绝")
	var bad_cooldown: Dictionary = _context(50, {"greens": 0}, [])
	bad_cooldown["cooldowns"]["until_utc"] = -1.0
	_expect(str(Intent.plan(bad_cooldown, START).reason) == "invalid_cooldowns",
		"负冷却时刻被拒绝")
	var bad_time: Dictionary = Intent.plan(_context(50, {}, []), -1.0)
	_expect(not bad_time.ok and str(bad_time.reason) == "invalid_time",
		"负规划时刻被拒绝")


func _context(cash: int, bag: Dictionary, orders: Array,
		until_utc: float = 0.0, consumed: Dictionary = {}) -> Dictionary:
	return {
		"resident": {"id": NPC, "cash": cash, "bag": bag},
		"market": {"orders": orders},
		"cooldowns": {"until_utc": until_utc, "intents": consumed},
	}


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
