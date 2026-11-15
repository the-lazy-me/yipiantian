extends RefCounted
## M7-02 limit orders, escrowed reservations, rule-merchant quotes, cancel and
## expiry. Pure rules: no clock, disk, scene or network access.
##
## Reservations are escrow, not a second balance. A sell order moves goods out
## of the owner's bag, a buy order moves cash out of the owner's account, and
## the order row carries the escrowed amount. Available balance plus escrow is
## the original balance, so gifts, payments and later orders cannot spend the
## same resource twice. Everything is mutated on one farm candidate and the
## caller commits it only after success.
##
## M7-03 matching is not implemented. Orders already carry price, side,
## quantity, remaining, filled, receive sequence and expiry so price-time
## priority and partial fills can be added without changing the shape.

const Catalog = preload("res://farm/economy_catalog.gd")
const OwnerIds = preload("res://farm/owner_id.gd")

const MERCHANT: String = "@merchant"
const SIDE_BUY: String = "buy"
const SIDE_SELL: String = "sell"
const SIDES: Array[String] = [SIDE_BUY, SIDE_SELL]

const STATUS_OPEN: String = "open"
const STATUS_CANCELLED: String = "cancelled"
const STATUS_EXPIRED: String = "expired"
const STATUS_FILLED: String = "filled"
const STATUSES: Array[String] = [STATUS_OPEN, STATUS_CANCELLED, STATUS_EXPIRED, STATUS_FILLED]

const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_PRICE: int = 1000000
const MAX_QUANTITY: int = 9999
const MAX_ORDERS: int = 256
const MAX_COMMAND_ID_LENGTH: int = 128
## Experiment value: the merchant can join the first trades but cannot buy the
## whole harvest. M7-05 must re-evaluate it with real supply and demand.
const MERCHANT_BUDGET: int = 600

const MARKET_KEYS: Array[String] = ["merchant", "orders", "sequence"]
const MERCHANT_KEYS: Array[String] = ["opened", "opened_by", "opened_utc", "cash", "goods"]
const ORDER_KEYS: Array[String] = [
	"id", "owner", "side", "good", "price", "quantity", "remaining", "filled",
	"reserved", "sequence", "created_utc", "expires_utc", "status", "released",
	"closed_by", "closed_utc",
]


static func initial_state() -> Dictionary:
	var goods: Dictionary = {}
	for good_id: String in Catalog.goods_ids():
		goods[good_id] = 0
	return {
		"merchant": {
			"opened": false,
			"opened_by": "",
			"opened_utc": 0.0,
			"cash": 0,
			"goods": goods,
		},
		"orders": {},
		"sequence": 0,
	}


static func valid_owner(value: Variant) -> bool:
	return value is String and (value == MERCHANT or OwnerIds.valid(value))


static func valid_command_id(value: Variant) -> bool:
	return value is String and not value.is_empty() and value.length() <= MAX_COMMAND_ID_LENGTH


## Missing `economy.market` is the M7-01 shape: a valid empty market. Every other
## structural problem is rejected rather than silently defaulted.
static func valid(economy: Dictionary) -> bool:
	if not economy.has("market"):
		return true
	var market: Variant = economy.market
	if not market is Dictionary or market.size() != MARKET_KEYS.size():
		return false
	for key: String in MARKET_KEYS:
		if not market.has(key):
			return false
	if not _valid_merchant(market.merchant):
		return false
	if not _is_count(market.sequence) or int(market.sequence) > MAX_SAFE_INTEGER:
		return false
	if not market.orders is Dictionary or market.orders.size() > MAX_ORDERS:
		return false
	var merchant_opened: bool = bool(market.merchant.opened)
	var max_sequence: int = 0
	var sequences: Dictionary = {}
	for order_id: Variant in market.orders:
		var order_value: Variant = market.orders[order_id]
		if not _valid_order(order_id, order_value, int(market.sequence)):
			return false
		var order: Dictionary = order_value
		if str(order.owner) == MERCHANT and not merchant_opened:
			return false
		var sequence: int = int(order.sequence)
		if sequences.has(sequence):
			return false
		sequences[sequence] = true
		max_sequence = maxi(max_sequence, sequence)
	return max_sequence <= int(market.sequence)


static func merchant_cash(economy: Dictionary) -> int:
	var market: Variant = economy.get("market")
	if market is Dictionary and market.get("merchant") is Dictionary:
		return int(market.merchant.get("cash", 0))
	return 0


## Cash held by open buy orders. It is no longer in an account but it is still
## issued money, so the world total must include it to stay comparable to
## `issued`.
static func escrowed_cash(economy: Dictionary) -> int:
	var market: Variant = economy.get("market")
	if not market is Dictionary or not market.get("orders") is Dictionary:
		return 0
	var total: int = 0
	for order: Variant in market.orders.values():
		if order is Dictionary and str(order.get("side", "")) == SIDE_BUY \
				and str(order.get("status", "")) == STATUS_OPEN:
			total += int(order.get("reserved", 0))
	return total


## Deterministic quote from the catalog reference price and the merchant's
## current available cash/stock. Capacities are bounded by the order limits.
static func quote(economy: Dictionary, good_id: String) -> Dictionary:
	if not Catalog.is_good(good_id):
		return {}
	var base: int = Catalog.base_price(good_id)
	var bid: int = maxi(1, int(floor(float(base) * 4.0 / 5.0)))
	var ask: int = base + maxi(1, int(floor(float(base) / 4.0)))
	var cash: int = 0
	var stock: int = 0
	var market: Variant = economy.get("market")
	if market is Dictionary and market.get("merchant") is Dictionary:
		var merchant: Dictionary = market.merchant
		cash = int(merchant.get("cash", 0))
		var goods: Variant = merchant.get("goods")
		if goods is Dictionary:
			stock = int(goods.get(good_id, 0))
	return {
		"good": good_id,
		"bid": bid,
		"ask": ask,
		"budget": cash,
		"stock": stock,
		"buy_capacity": mini(MAX_QUANTITY, int(floor(float(cash) / float(bid)))),
		"sell_capacity": mini(MAX_QUANTITY, stock),
	}


static func quotes(economy: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for good_id: String in Catalog.goods_ids():
		result[good_id] = quote(economy, good_id)
	return result


static func open_merchant(data: Dictionary, command_id: String, now_utc: float) -> Dictionary:
	if not valid_command_id(command_id):
		return error("invalid_command")
	if not _valid_time(now_utc):
		return error("invalid_time")
	var market: Dictionary = _market(data)
	if market.is_empty():
		return error("invalid_market")
	var merchant: Dictionary = market.merchant
	if bool(merchant.opened):
		return error("already_opened")
	if not _is_count(int(merchant.cash) + MERCHANT_BUDGET) \
			or not _is_count(int(data.economy.issued) + MERCHANT_BUDGET):
		return error("invalid_amount")
	merchant.opened = true
	merchant.opened_by = command_id
	merchant.opened_utc = float(now_utc)
	merchant.cash = int(merchant.cash) + MERCHANT_BUDGET
	data.economy.issued = int(data.economy.issued) + MERCHANT_BUDGET
	return {
		"ok": true, "reason": "", "duplicate": false, "amount": MERCHANT_BUDGET,
		"budget": int(merchant.cash),
	}


## Validates the command before the caller builds the replay payload. This keeps
## a malformed retry from being hashed into a different payload and reported as
## a conflict when it should be a plain refusal.
static func validate_place(owner: String, side: String, good_id: String, price: Variant,
		quantity: Variant, expires_utc: float, now_utc: float) -> Dictionary:
	if not valid_owner(owner):
		return error("invalid_owner")
	if side not in SIDES:
		return error("invalid_side")
	if not Catalog.is_good(good_id):
		return error("invalid_good")
	if not _is_positive_count(price) or int(price) > MAX_PRICE:
		return error("invalid_price")
	if not _is_positive_count(quantity) or int(quantity) > MAX_QUANTITY:
		return error("invalid_quantity")
	if not _valid_time(now_utc) or not _valid_time(expires_utc) or float(expires_utc) <= float(now_utc):
		return error("invalid_expiry")
	return {"ok": true, "reason": ""}


static func place(data: Dictionary, command_id: String, owner: String, side: String,
		good_id: String, price: Variant, quantity: Variant, expires_utc: float,
		now_utc: float) -> Dictionary:
	if not valid_command_id(command_id):
		return error("invalid_command")
	var checked: Dictionary = validate_place(owner, side, good_id, price, quantity, expires_utc, now_utc)
	if not checked.ok:
		return checked
	var market: Dictionary = _market(data)
	if market.is_empty():
		return error("invalid_market")
	if not market.orders is Dictionary:
		return error("invalid_market")
	if market.orders.has(command_id):
		# The order id is durable; an evicted command ledger still cannot create
		# a second order with the same id.
		return error("order_exists")
	if market.orders.size() >= MAX_ORDERS:
		return error("order_limit")
	var unit_price: int = int(price)
	var count: int = int(quantity)
	if owner == MERCHANT:
		var merchant: Dictionary = market.merchant
		if not bool(merchant.opened):
			return error("merchant_closed")
		var current: Dictionary = quote(data.economy, good_id)
		var expected: int = int(current.bid) if side == SIDE_BUY else int(current.ask)
		if unit_price != expected:
			return error("invalid_price")
	var reserved: int = count
	if side == SIDE_BUY:
		var cost: int = unit_price * count
		if not _is_count(cost):
			return error("invalid_amount")
		var paid: Dictionary = _deduct_cash(data, owner, cost)
		if not paid.ok:
			return error(str(paid.reason))
		reserved = cost
	else:
		var goods: Dictionary = _goods_for(data, owner)
		if _amount(goods, good_id) < count:
			return error("insufficient_goods")
		goods[good_id] = _amount(goods, good_id) - count
	var sequence: int = int(market.sequence) + 1
	if not _is_count(sequence):
		return error("order_limit")
	market.sequence = sequence
	var order: Dictionary = {
		"id": command_id,
		"owner": owner,
		"side": side,
		"good": good_id,
		"price": unit_price,
		"quantity": count,
		"remaining": count,
		"filled": 0,
		"reserved": reserved,
		"sequence": sequence,
		"created_utc": float(now_utc),
		"expires_utc": float(expires_utc),
		"status": STATUS_OPEN,
		"released": 0,
		"closed_by": "",
		"closed_utc": 0.0,
	}
	market.orders[command_id] = order
	return _order_result(order, false)


static func cancel(data: Dictionary, command_id: String, owner: String, order_id: String,
		now_utc: float) -> Dictionary:
	if not valid_command_id(command_id):
		return error("invalid_command")
	if not _valid_time(now_utc):
		return error("invalid_time")
	if not valid_owner(owner):
		return error("invalid_owner")
	if not valid_command_id(order_id):
		return error("invalid_order")
	var market: Dictionary = _market(data)
	if market.is_empty():
		return error("invalid_market")
	if not market.orders is Dictionary or not market.orders.has(order_id):
		return error("unknown_order")
	var order: Dictionary = market.orders[order_id]
	if str(order.owner) != owner:
		return error("not_owner")
	if str(order.status) != STATUS_OPEN:
		return error("order_closed")
	if float(now_utc) < float(order.created_utc):
		return error("invalid_time")
	# At or after the UTC boundary the order is due for expiry. Refusing the
	# cancel keeps the outcome independent of which call happens first.
	if float(now_utc) >= float(order.expires_utc):
		return error("order_expired")
	var released: Dictionary = _release(data, order)
	if not released.ok:
		return error(str(released.reason))
	var amount: int = int(order.reserved)
	order.reserved = 0
	order.released = amount
	order.status = STATUS_CANCELLED
	order.closed_by = command_id
	order.closed_utc = float(now_utc)
	return _cancel_result(order, false)


static func expire(data: Dictionary, now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return error("invalid_time")
	var market: Dictionary = _market(data)
	if market.is_empty():
		return error("invalid_market")
	var ids: Array = market.orders.keys()
	ids.sort()
	var expired: int = 0
	var released_cash: int = 0
	var released_goods: Dictionary = {}
	for order_id: Variant in ids:
		var order: Dictionary = market.orders[order_id]
		if str(order.status) != STATUS_OPEN:
			continue
		if float(order.expires_utc) > float(now_utc):
			continue
		var released: Dictionary = _release(data, order)
		if not released.ok:
			return error(str(released.reason))
		var amount: int = int(order.reserved)
		order.reserved = 0
		order.released = amount
		order.status = STATUS_EXPIRED
		order.closed_by = ""
		order.closed_utc = float(now_utc)
		expired += 1
		released_cash += int(released.cash)
		for good_id: String in released.goods:
			released_goods[good_id] = int(released_goods.get(good_id, 0)) + int(released.goods[good_id])
	return {
		"ok": true, "reason": "", "duplicate": false, "expired": expired,
		"released_cash": released_cash, "released_goods": released_goods,
	}


## Rebuilds a successful market result from durable order state when the
## bounded economy ledger still holds the id. The caller has already confirmed
## the payload matched, so a place id maps to its order id and a cancel id maps
## to the order it closed.
static func replay(economy: Dictionary, command_id: String, payload: String,
		ledger: Dictionary) -> Dictionary:
	if ledger.is_empty():
		return {}
	if str(ledger.get("reason", "")) == "command_conflict":
		return ledger
	var kind: String = _payload_kind(payload)
	var market: Variant = economy.get("market")
	if market is Dictionary and market.get("orders") is Dictionary:
		if kind == "market_place" and market.orders.get(command_id) is Dictionary:
			var placed: Dictionary = _order_result(market.orders[command_id], true)
			placed.amount = int(ledger.get("amount", placed.amount))
			return placed
		if kind == "market_cancel":
			var ids: Array = market.orders.keys()
			ids.sort()
			for order_id: Variant in ids:
				var order: Dictionary = market.orders[order_id]
				if str(order.closed_by) == command_id:
					return _cancel_result(order, true)
	return ledger


static func place_payload(owner: String, side: String, good_id: String, price: Variant,
		quantity: Variant, expires_utc: float, now_utc: float) -> String:
	return JSON.stringify(["market_place", owner, side, good_id, int(price), int(quantity),
		float(expires_utc), float(now_utc)])


static func cancel_payload(owner: String, order_id: String, now_utc: float) -> String:
	return JSON.stringify(["market_cancel", owner, order_id, float(now_utc)])


static func open_merchant_payload(now_utc: float) -> String:
	return JSON.stringify(["market_open_merchant", float(now_utc)])


static func orders(economy: Dictionary) -> Array:
	var market: Variant = economy.get("market")
	if not market is Dictionary or not market.get("orders") is Dictionary:
		return []
	var result: Array = market.orders.values().duplicate(true)
	result.sort_custom(_order_before)
	return result


static func order(economy: Dictionary, order_id: String) -> Dictionary:
	var market: Variant = economy.get("market")
	if market is Dictionary and market.get("orders") is Dictionary \
			and market.orders.get(order_id) is Dictionary:
		return market.orders[order_id].duplicate(true)
	return {}


static func merchant(economy: Dictionary) -> Dictionary:
	var market: Variant = economy.get("market")
	if market is Dictionary and market.get("merchant") is Dictionary:
		return market.merchant.duplicate(true)
	return {}


static func error(reason: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "duplicate": false, "amount": 0,
		"order_id": "", "owner": "", "side": "", "good": "", "price": 0,
		"quantity": 0, "remaining": 0, "reserved": 0, "status": "", "sequence": 0,
	}


static func _market(data: Dictionary) -> Dictionary:
	if not data.get("economy") is Dictionary:
		return {}
	var market: Variant = data.economy.get("market")
	return market if market is Dictionary else {}


static func _goods_for(data: Dictionary, owner: String) -> Dictionary:
	if owner == MERCHANT:
		var market: Dictionary = _market(data)
		if market.is_empty() or not market.merchant is Dictionary:
			return {}
		return market.merchant.goods
	if data.get("bags") is Dictionary and data.bags.get(owner) is Dictionary:
		return data.bags[owner]
	return {}


static func _ensure_goods(data: Dictionary, owner: String) -> Dictionary:
	if owner == MERCHANT:
		return _market(data).merchant.goods
	if not data.get("bags") is Dictionary:
		data.bags = {}
	if not data.bags.get(owner) is Dictionary:
		data.bags[owner] = {}
	return data.bags[owner]


static func _deduct_cash(data: Dictionary, owner: String, amount: int) -> Dictionary:
	if owner == MERCHANT:
		var market: Dictionary = _market(data)
		if market.is_empty() or not bool(market.merchant.get("opened", false)):
			return {"ok": false, "reason": "merchant_closed"}
		if int(market.merchant.cash) < amount:
			return {"ok": false, "reason": "insufficient_cash"}
		market.merchant.cash = int(market.merchant.cash) - amount
		return {"ok": true}
	var accounts: Variant = data.economy.get("accounts")
	if not accounts is Dictionary or not accounts.get(owner) is Dictionary:
		return {"ok": false, "reason": "unknown_account"}
	if int(accounts[owner].cash) < amount:
		return {"ok": false, "reason": "insufficient_cash"}
	accounts[owner].cash = int(accounts[owner].cash) - amount
	return {"ok": true}


static func _release(data: Dictionary, order: Dictionary) -> Dictionary:
	var amount: int = int(order.reserved)
	if str(order.side) == SIDE_BUY:
		if str(order.owner) == MERCHANT:
			var market: Dictionary = _market(data)
			if market.is_empty():
				return {"ok": false, "reason": "invalid_market"}
			market.merchant.cash = int(market.merchant.cash) + amount
		else:
			var accounts: Variant = data.economy.get("accounts")
			if not accounts is Dictionary:
				return {"ok": false, "reason": "invalid_market"}
			if not accounts.get(order.owner) is Dictionary:
				# Escrow is returning, not issuing; rebuilding the empty account
				# keeps the cash conserved if a crafted snapshot dropped it.
				accounts[order.owner] = {"cash": 0, "granted": false}
			accounts[order.owner].cash = int(accounts[order.owner].cash) + amount
		return {"ok": true, "cash": amount, "goods": {}}
	var goods: Dictionary = _ensure_goods(data, str(order.owner))
	var good_id: String = str(order.good)
	goods[good_id] = _amount(goods, good_id) + amount
	var returned: Dictionary = {good_id: amount}
	return {"ok": true, "cash": 0, "goods": returned}


static func _order_result(order: Dictionary, duplicate: bool) -> Dictionary:
	return {
		"ok": true, "reason": "", "duplicate": duplicate,
		"order_id": str(order.id), "owner": str(order.owner), "side": str(order.side),
		"good": str(order.good), "price": int(order.price), "quantity": int(order.quantity),
		"remaining": int(order.remaining), "reserved": int(order.reserved),
		"status": str(order.status), "sequence": int(order.sequence),
		"amount": int(order.reserved),
	}


static func _cancel_result(order: Dictionary, duplicate: bool) -> Dictionary:
	var result: Dictionary = _order_result(order, duplicate)
	result.amount = int(order.released)
	result.released = int(order.released)
	return result


static func _order_before(a: Variant, b: Variant) -> bool:
	var left: Dictionary = a
	var right: Dictionary = b
	if int(left.sequence) != int(right.sequence):
		return int(left.sequence) < int(right.sequence)
	return str(left.id) < str(right.id)


static func _payload_kind(payload: String) -> String:
	var parsed: Variant = JSON.parse_string(payload)
	if parsed is Array and not parsed.is_empty() and parsed[0] is String:
		return str(parsed[0])
	return ""


static func _valid_merchant(value: Variant) -> bool:
	if not value is Dictionary or value.size() != MERCHANT_KEYS.size():
		return false
	for key: String in MERCHANT_KEYS:
		if not value.has(key):
			return false
	if not value.opened is bool or not value.opened_by is String:
		return false
	if not _is_count(value.opened_utc) or not _is_count(value.cash):
		return false
	if bool(value.opened):
		if not valid_command_id(value.opened_by):
			return false
	else:
		if not str(value.opened_by).is_empty() or int(value.opened_utc) != 0 or int(value.cash) != 0:
			return false
	if not value.goods is Dictionary or value.goods.size() != Catalog.goods_ids().size():
		return false
	for good_id: String in Catalog.goods_ids():
		if not _is_count(value.goods.get(good_id)):
			return false
	return true


static func _valid_order(order_id: Variant, value: Variant, market_sequence: int) -> bool:
	if not value is Dictionary or value.size() != ORDER_KEYS.size():
		return false
	for key: String in ORDER_KEYS:
		if not value.has(key):
			return false
	if not valid_command_id(order_id) or str(value.id) != str(order_id):
		return false
	if not valid_owner(value.owner):
		return false
	if str(value.side) not in SIDES or not Catalog.is_good(value.good):
		return false
	if not _is_positive_count(value.price) or int(value.price) > MAX_PRICE:
		return false
	if not _is_positive_count(value.quantity) or int(value.quantity) > MAX_QUANTITY:
		return false
	for key: String in ["remaining", "filled", "reserved", "sequence", "released"]:
		if not _is_count(value.get(key)):
			return false
	if int(value.remaining) > int(value.quantity) or int(value.filled) > int(value.quantity):
		return false
	if int(value.remaining) + int(value.filled) != int(value.quantity):
		return false
	if int(value.sequence) <= 0 or int(value.sequence) > market_sequence:
		return false
	if not _valid_time(value.created_utc) or not _valid_time(value.expires_utc):
		return false
	if float(value.expires_utc) <= float(value.created_utc):
		return false
	if not value.closed_by is String or str(value.status) not in STATUSES:
		return false
	if not _valid_time(value.closed_utc):
		return false
	var unit: int = int(value.price) if str(value.side) == SIDE_BUY else 1
	# `remaining` is the unfilled quantity even after close, so the order keeps
	# its audit history; `released` is that quantity converted to escrow units.
	var released_value: int = int(value.remaining) * unit
	if str(value.status) == STATUS_OPEN:
		return int(value.remaining) > 0 and int(value.reserved) == int(value.remaining) * unit \
			and int(value.released) == 0 and str(value.closed_by).is_empty() \
			and float(value.closed_utc) == 0.0
	if int(value.reserved) != 0:
		return false
	if float(value.closed_utc) < float(value.created_utc):
		return false
	if str(value.status) == STATUS_FILLED:
		return int(value.filled) == int(value.quantity) and int(value.released) == 0 \
			and str(value.closed_by).is_empty()
	if int(value.released) != released_value:
		return false
	if str(value.status) == STATUS_CANCELLED:
		return valid_command_id(value.closed_by)
	return str(value.closed_by).is_empty()


static func _is_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)


static func _is_positive_count(value: Variant) -> bool:
	return _is_count(value) and float(value) > 0.0


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


static func _amount(goods: Dictionary, good_id: String) -> int:
	var amount: Variant = goods.get(good_id, 0)
	return int(amount) if (amount is int or amount is float) else 0
