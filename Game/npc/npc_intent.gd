extends RefCounted
## M10-03 居民意图与预算校验（纯规则切片）。无模型、时钟、磁盘、场景或网络；
## 本模块不写入市场、银行或农场状态，也不读取 `FarmState`。
##
## 只读上下文契约（最小形状；调用方从权威状态投影而来，未知键一律拒绝）：
##
##   {
##     "resident": {
##       "id": "npc_a_zhou",              # OwnerIds.valid
##       "cash": 40,                       # 可用现金，非负整数
##       "bag": {"greens": 0},             # 仅经济目录商品 -> 非负整数
##     },
##     "market": {
##       "orders": [                       # 仅公开卖单；调用方已剔除关闭/隐藏行
##         {"good": "greens", "price": 7, "remaining": 3},
##       ],
##     },
##     "cooldowns": {
##       "until_utc": 0.0,                 # 居民下次可行动时刻；0 表示可用
##       "intents": {"intent_123": 1800000000.0},  # 已消费意图 id -> 消费时刻
##     },
##   }
##
## 本切片只实现一种意图：按公开卖单的当前价格买入一种本人袋中缺货的商品。
## 意图里的 `price` 同时是限价上限；数量由现金、卖单剩余和目录上限共同限制，
## 不编造余额。人格与记忆摘要不参与“补一种缺货商品”的选择，因此暂不进入上下
## 文契约；需要它们影响目标时再扩键。
##
## 意图形状：
##   {id, kind: "buy", good, quantity, price, reason: "restock", expires_utc}
##
## id 由 (居民 id, 目标商品, 过期时刻) 经 FNV-1a 确定性派生；同一输入得到同一
## id，不依赖随机数、调用顺序或全局状态。

const Catalog = preload("res://farm/economy_catalog.gd")
const Market = preload("res://farm/market_state.gd")
const OwnerIds = preload("res://farm/owner_id.gd")

const KIND_BUY: String = "buy"
const REASON_RESTOCK: String = "restock"
const INTENT_TTL_SECONDS: float = 120.0
const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_QUANTITY: int = Market.MAX_QUANTITY
const MAX_PRICE: int = Market.MAX_PRICE

const CONTEXT_KEYS: Array[String] = ["resident", "market", "cooldowns"]
const RESIDENT_KEYS: Array[String] = ["id", "cash", "bag"]
const MARKET_KEYS: Array[String] = ["orders"]
const COOLDOWN_KEYS: Array[String] = ["until_utc", "intents"]
const ORDER_KEYS: Array[String] = ["good", "price", "remaining"]
const INTENT_KEYS: Array[String] = [
	"id", "kind", "good", "quantity", "price", "reason", "expires_utc",
]

const HASH_OFFSET: int = 2166136261
const HASH_PRIME: int = 16777619
const HASH_MASK: int = 0xFFFFFFFF


## 选择一个意图。无合适目标时返回 `{ok:false, reason}`，原因取：
## `cooldown`、`no_supply`、`nothing_needed`、`no_cash`，以及上下文/时间不合法
## 时的 `invalid_*`。挑选顺序固定为“最便宜的缺货商品”，同价按商品 id 升序。
static func plan(context: Variant, now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return _fail("invalid_time")
	var checked: Dictionary = _check_context(context)
	if not checked.ok:
		return _fail(str(checked.reason))
	var cooldowns: Dictionary = checked.cooldowns
	if float(now_utc) < float(cooldowns.until_utc):
		return _fail("cooldown")
	var offers: Array = checked.offers
	if offers.is_empty():
		return _fail("no_supply")
	var bag: Dictionary = checked.resident.bag
	var best: Dictionary = {}
	for offer: Dictionary in offers:
		var good_id: String = str(offer.good)
		if int(bag.get(good_id, 0)) > 0:
			continue
		if best.is_empty() or _better_offer(offer, best):
			best = offer
	if best.is_empty():
		return _fail("nothing_needed")
	var price: int = int(best.price)
	var cash: int = int(checked.resident.cash)
	if cash < price:
		return _fail("no_cash")
	var quantity: int = mini(
		mini(int(floor(float(cash) / float(price))), int(best.remaining)),
		MAX_QUANTITY)
	if quantity <= 0:
		return _fail("no_cash")
	var good: String = str(best.good)
	var expires_utc: float = float(now_utc) + INTENT_TTL_SECONDS
	return {
		"ok": true,
		"intent": {
			"id": _intent_id(str(checked.resident.id), good, expires_utc),
			"kind": KIND_BUY,
			"good": good,
			"quantity": quantity,
			"price": price,
			"reason": REASON_RESTOCK,
			"expires_utc": expires_utc,
		},
	}


## 执行前重新校验同一意图。依次拒绝：形状/时间/上下文、过期、已消费 id、
## 居民冷却、预算不足、限价以下无供给、数量超过可用剩余。成功只返回
## `{ok:true, reason:""}`，不修改任何输入。
static func validate(intent: Variant, context: Variant, now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return _fail("invalid_time")
	var checked: Dictionary = _check_context(context)
	if not checked.ok:
		return _fail(str(checked.reason))
	if not intent is Dictionary:
		return _fail("invalid_intent")
	var wanted: Dictionary = intent
	if not _exact_keys(wanted, INTENT_KEYS):
		return _fail("invalid_intent")
	if not wanted.get("id") is String or str(wanted.id).is_empty():
		return _fail("invalid_intent")
	if not wanted.get("kind") is String or str(wanted.kind) != KIND_BUY:
		return _fail("invalid_kind")
	if not Catalog.is_good(wanted.get("good")):
		return _fail("invalid_good")
	if not _positive_int(wanted.get("quantity"), MAX_QUANTITY):
		return _fail("invalid_quantity")
	if not _positive_int(wanted.get("price"), MAX_PRICE):
		return _fail("invalid_price")
	if not wanted.get("reason") is String or str(wanted.reason).is_empty():
		return _fail("invalid_intent")
	if not _valid_time_value(wanted.get("expires_utc")):
		return _fail("invalid_expiry")
	var resident: Dictionary = checked.resident
	var cooldowns: Dictionary = checked.cooldowns
	var expires_utc: float = float(wanted.expires_utc)
	if str(wanted.id) != _intent_id(str(resident.id), str(wanted.good), expires_utc):
		return _fail("invalid_intent_id")
	if float(now_utc) >= expires_utc:
		return _fail("expired")
	if cooldowns.intents.has(str(wanted.id)):
		return _fail("duplicate_intent")
	if float(now_utc) < float(cooldowns.until_utc):
		return _fail("cooldown")
	var price: int = int(wanted.price)
	var quantity: int = int(wanted.quantity)
	if int(resident.cash) < quantity * price:
		return _fail("insufficient_cash")
	var any_supply: bool = false
	var available: int = 0
	for offer: Dictionary in checked.offers:
		if str(offer.good) != str(wanted.good):
			continue
		any_supply = true
		if int(offer.price) <= price:
			available += int(offer.remaining)
	if not any_supply:
		return _fail("no_supply")
	if available <= 0:
		return _fail("price_above_market")
	if quantity > available:
		return _fail("insufficient_supply")
	return {"ok": true, "reason": ""}


static func _check_context(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _fail("invalid_context")
	var context: Dictionary = value
	if not _exact_keys(context, CONTEXT_KEYS):
		return _fail("invalid_context")

	var resident_value: Variant = context.get("resident")
	if not resident_value is Dictionary:
		return _fail("invalid_resident")
	var resident: Dictionary = resident_value
	if not _exact_keys(resident, RESIDENT_KEYS):
		return _fail("invalid_resident")
	if not OwnerIds.valid(resident.get("id")):
		return _fail("invalid_resident")
	if not _non_negative_int(resident.get("cash"), MAX_SAFE_INTEGER):
		return _fail("invalid_resident")
	var bag_value: Variant = resident.get("bag")
	if not bag_value is Dictionary:
		return _fail("invalid_bag")
	var bag: Dictionary = bag_value
	for good_value: Variant in bag.keys():
		if not Catalog.is_good(good_value):
			return _fail("invalid_bag")
		if not _non_negative_int(bag[good_value], MAX_SAFE_INTEGER):
			return _fail("invalid_bag")

	var market_value: Variant = context.get("market")
	if not market_value is Dictionary:
		return _fail("invalid_market")
	var market: Dictionary = market_value
	if not _exact_keys(market, MARKET_KEYS):
		return _fail("invalid_market")
	var orders_value: Variant = market.get("orders")
	if not orders_value is Array:
		return _fail("invalid_market")
	var offers: Array = []
	for order_value: Variant in orders_value:
		if not order_value is Dictionary:
			return _fail("invalid_market")
		var order: Dictionary = order_value
		if not _exact_keys(order, ORDER_KEYS):
			return _fail("invalid_market")
		if not Catalog.is_good(order.get("good")):
			return _fail("invalid_market")
		if not _positive_int(order.get("price"), MAX_PRICE):
			return _fail("invalid_market")
		if not _positive_int(order.get("remaining"), MAX_QUANTITY):
			return _fail("invalid_market")
		offers.append({
			"good": str(order.good),
			"price": int(order.price),
			"remaining": int(order.remaining),
		})

	var cooldowns_value: Variant = context.get("cooldowns")
	if not cooldowns_value is Dictionary:
		return _fail("invalid_cooldowns")
	var cooldowns: Dictionary = cooldowns_value
	if not _exact_keys(cooldowns, COOLDOWN_KEYS):
		return _fail("invalid_cooldowns")
	if not _valid_time_value(cooldowns.get("until_utc")):
		return _fail("invalid_cooldowns")
	var intents_value: Variant = cooldowns.get("intents")
	if not intents_value is Dictionary:
		return _fail("invalid_cooldowns")
	for intent_value: Variant in intents_value.keys():
		if not intent_value is String or str(intent_value).is_empty():
			return _fail("invalid_cooldowns")
		if not _valid_time_value(intents_value[intent_value]):
			return _fail("invalid_cooldowns")

	return {
		"ok": true, "reason": "", "resident": resident, "offers": offers,
		"cooldowns": cooldowns,
	}


static func _better_offer(candidate: Dictionary, current: Dictionary) -> bool:
	var candidate_price: int = int(candidate.price)
	var current_price: int = int(current.price)
	if candidate_price != current_price:
		return candidate_price < current_price
	var candidate_good: String = str(candidate.good)
	var current_good: String = str(current.good)
	if candidate_good != current_good:
		return candidate_good < current_good
	return int(candidate.remaining) > int(current.remaining)


static func _intent_id(resident_id: String, good_id: String,
		expires_utc: float) -> String:
	var expires_key: int = int(round(expires_utc * 1000.0))
	return "intent_" + str(_hash([
		"npc_intent_v1", resident_id, good_id, str(expires_key),
	]))


static func _hash(parts: Array) -> int:
	var digest: int = HASH_OFFSET
	for part: Variant in parts:
		var bytes: PackedByteArray = str(part).to_utf8_buffer()
		for byte: int in bytes:
			digest = ((digest ^ byte) * HASH_PRIME) & HASH_MASK
	return digest


static func _exact_keys(value: Dictionary, keys: Array[String]) -> bool:
	if value.size() != keys.size():
		return false
	for key: String in keys:
		if not value.has(key):
			return false
	return true


static func _positive_int(value: Variant, limit: int) -> bool:
	return value is int and int(value) >= 1 and int(value) <= limit


static func _non_negative_int(value: Variant, limit: int) -> bool:
	return value is int and int(value) >= 0 and int(value) <= limit


static func _valid_time(value: float) -> bool:
	return is_finite(value) and value >= 0.0 and value <= float(MAX_SAFE_INTEGER)


static func _valid_time_value(value: Variant) -> bool:
	if value is int:
		return int(value) >= 0 and int(value) <= MAX_SAFE_INTEGER
	if value is float:
		return is_finite(float(value)) and float(value) >= 0.0 \
			and float(value) <= float(MAX_SAFE_INTEGER)
	return false


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
