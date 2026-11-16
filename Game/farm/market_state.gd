extends RefCounted
## M7-02 limit orders, escrowed reservations, rule-merchant quotes, cancel and
## expiry; M7-03 price-time matching, partial fills, fees and settlement. Pure
## rules: no clock, disk, scene or network access.
##
## Reservations are escrow, not a second balance. A sell order moves goods out
## of the owner's bag, a buy order moves cash out of the owner's account, and
## the order row carries the escrowed amount. Available balance plus escrow is
## the original balance, so gifts, payments and later orders cannot spend the
## same resource twice. Everything is mutated on one farm candidate and the
## caller commits it only after success.
##
## M7-03 adds one deterministic sweep, `match(data, now_utc)`. The authority
## calls it after the commands it wants to settle; placing an order does not
## match implicitly, so commands stay pure book operations and the same sweep
## is the only settlement path. Matches are price priority with the receive
## sequence as the same-price tie-breaker. Each fill is one trade: both order
## rows, the buyer's goods, the seller's cash and the fee burn change on the
## same candidate, so a failure cannot deliver one side only. The maker (the
## earlier order) sets the unit price. A fixed 1 COIN fee is deducted from the
## seller and burned, which lowers both `issued` and `total_cash` by the same
## amount and keeps `total_cash == issued`.
##
## Every fill keeps a durable trade record under `market.trades` with a stable
## `trade_<sequence>` id. The bounded command window is not needed for
## settlement idempotency: `filled`/`remaining` on the durable order rows make
## a repeated sweep a no-op, and the trade log is bounded evidence rather than
## the double-spend guard.
##
## M7-04 adds two fixed market locations and a bounded shipment ledger. Shipping
## moves goods out of the owner's bag into the shipment row (in transit), so the
## same goods cannot be escrowed by a sell order or shipped again; delivery
## moves them back into the bag and writes a durable `delivery_<sequence>`
## event. The flat fee is paid from the sender's cash and burned, exactly like
## the trade fee, so `total_cash == issued` stays one equation. This is not a
## regional transport network: no route graph, carrier, risk or cancellation.
##
## M7-07 makes the rule merchant a real counterparty. Opening it grants a
## one-time, explicit 20 units of every catalog good recorded in
## `merchant.granted` (zero for a legacy market without the field). It then
## keeps one stable bid and one stable ask per good, both escrowed from the
## merchant's own cash/stock. `match()` refreshes a missing, closed or expired
## side in place: the same `merchant_bid_<good>` / `merchant_ask_<good>` row is
## reused, so the table never grows by more than 12 merchant rows and no random
## or clock source is involved beyond the supplied `now_utc`.
##
## M7-09 keeps the 256-row order and shipment tables usable in a long-lived
## world by archiving only durable evidence. Placing an order when the table is
## full evicts the earliest closed player order; shipping when the shipment
## table is full evicts the earliest terminal shipment (delivered or lost). Open
## orders and in-transit goods still own escrow, and merchant quote rows are
## reused by the rolling rule, so none of those can be evicted. Closing or
## delivering already returned the escrow, so archiving moves no cash or goods.
## A monotonic `archived_orders` / `archived_shipments` counter records that
## evidence was lost; no copy of an evicted row is kept. Trades and deliveries
## may therefore point at a missing order/shipment row. A present row is still
## cross-checked field by field, while a missing row is trusted through the
## evidence row that `_valid_trade` / `_valid_delivery` already validate on its
## own. The delivery table follows the same rule: `deliver` evicts the oldest
## delivery event when its 256-row bound is reached, because every delivery row
## is terminal evidence. A delivered shipment whose event was archived is
## trusted through the shipment row, and a shipment whose event is still present
## is trusted through the event. All three archive counts are monotonic and
## optional as a group.
##
## M8-03a adds declared transport risk and a durable loss ledger. A shipment may
## be declared `risk = "declared"`; at the same deterministic arrival sweep a
## declared shipment either delivers or becomes the terminal `lost` state. The
## loss decision is a pure function of persisted shipment fields (never the
## command id, clock or RNG), so a reload or an offline catch-up reaches the same
## verdict and a repeated sweep cannot re-adjudicate it. A loss destroys the
## in-transit goods and writes one `transport_loss` event under `economy.losses`
## with the victim, ship id, good, quantity, route, reason window, locked unit
## reference value and rule version. It changes no cash, so `total_cash ==
## issued` still holds; the goods invariant gains the `lost` endpoint. Loss
## events are bounded evidence for a later insurance slice: this module never
## pays a claim and never invents compensation.

const Catalog = preload("res://farm/economy_catalog.gd")
const OwnerIds = preload("res://farm/owner_id.gd")
const Ledger = preload("res://farm/ledger_state.gd")

## Two fixed markets are enough to prove in-transit ownership and delivery.
const LOCATION_FARM: String = "farm_market"
const LOCATION_HARBOR: String = "harbor_market"
const LOCATIONS: Array[String] = [LOCATION_FARM, LOCATION_HARBOR]
## Experiment values: one flat fee per shipment and a fixed UTC travel time.
## The fee has no carrier recipient in this slice, so it is burned. M7-05 must
## re-evaluate both once real supply and demand exist.
const SHIPMENT_FEE: int = 2
const DELIVERY_SECONDS: float = 600.0
const MAX_SHIPMENTS: int = 256
const MAX_DELIVERIES: int = 256
const SHIPMENT_STATUS_TRANSIT: String = "in_transit"
const SHIPMENT_STATUS_DELIVERED: String = "delivered"
## Terminal loss state. It replaces delivery: the goods are destroyed, not
## returned to a bag, and no delivery event is written.
const SHIPMENT_STATUS_LOST: String = "lost"
const SHIPMENT_STATUSES: Array[String] = [
	SHIPMENT_STATUS_TRANSIT, SHIPMENT_STATUS_DELIVERED, SHIPMENT_STATUS_LOST,
]
const DELIVERY_ID_PREFIX: String = "delivery_"

## Declared risk is explicit at ship time. A `safe` shipment always delivers;
## only `declared` shipments can reach the `lost` state.
const SHIPMENT_RISK_SAFE: String = "safe"
const SHIPMENT_RISK_DECLARED: String = "declared"
const SHIPMENT_RISKS: Array[String] = [SHIPMENT_RISK_SAFE, SHIPMENT_RISK_DECLARED]
## Experiment value: one declared shipment in four is lost. The roll is a pure
## hash of persisted shipment fields, so the probability is reproducible and no
## RNG or clock is involved. M8-03 (insurance) must revisit both the value and
## how a risk declaration is priced before any premium is charged.
const RISK_LOSS_PERMILLE: int = 250
const TRANSPORT_LOSS_TAG: String = "transport_loss_v1"
const TRANSPORT_LOSS_KIND: String = "transport_loss"
const TRANSPORT_LOSS_RULE_VERSION: int = 1
const LOSS_ID_PREFIX: String = "loss_"
const MAX_LOSSES: int = 256
const LOSSES_KEYS: Array[String] = ["sequence", "events", "archived"]
const LOSS_EVENT_KEYS: Array[String] = [
	"id", "sequence", "kind", "at_utc", "cause_start_utc", "cause_end_utc",
	"victim", "shipment_id", "good", "quantity", "unit_value", "value",
	"rule_version",
]

const MERCHANT: String = "@merchant"
## One-time merchant stock issuance per catalog good. It is recorded in
## `merchant.granted`, so the snapshot explains where the goods came from.
const MERCHANT_GRANT_PER_GOOD: int = 20
## Fixed rolling quote size. A quote is reopened only when it is missing,
## closed or due, so a partially filled resting row keeps its remainder.
const MERCHANT_QUOTE_QUANTITY: int = 4
## Experiment value: one UTC hour per rolling quote. Expiry only triggers a
## refresh; it does not change the deterministic price or quantity.
const MERCHANT_QUOTE_SECONDS: float = 3600.0
const MERCHANT_BID_PREFIX: String = "merchant_bid_"
const MERCHANT_ASK_PREFIX: String = "merchant_ask_"
const MERCHANT_QUOTE_EVENT_PREFIX: String = "merchant_quote_"
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
## Experiment value: one fixed COIN per fill, paid by the seller and burned.
## One trade always closes at least one order (`quantity = min(remaining)`), so
## the current 256-order table can never produce more than 256 trades; this
## bound leaves headroom and is not expected to evict in a valid world.
const TRADE_FEE: int = 1
const MAX_TRADES: int = 512
const TRADE_ID_PREFIX: String = "trade_"

const MARKET_KEYS: Array[String] = [
	"merchant", "orders", "sequence", "trades", "trade_sequence",
	"shipments", "deliveries", "shipment_sequence", "delivery_sequence",
	"archived_orders", "archived_shipments", "archived_deliveries",
]
const LOGISTICS_KEYS: Array[String] = [
	"shipments", "deliveries", "shipment_sequence", "delivery_sequence",
]
## Monotonic count of evicted evidence rows. A market written before M7-09 has
## none of these keys; all are then treated as zero, so no archived row can be
## claimed. A document with only some of them is broken.
const ARCHIVE_KEYS: Array[String] = [
	"archived_orders", "archived_shipments", "archived_deliveries",
]
const MERCHANT_KEYS: Array[String] = ["opened", "opened_by", "opened_utc", "cash", "goods", "granted"]
const ORDER_KEYS: Array[String] = [
	"id", "owner", "side", "good", "price", "quantity", "remaining", "filled",
	"reserved", "sequence", "created_utc", "expires_utc", "status", "released",
	"closed_by", "closed_utc",
]
const TRADE_KEYS: Array[String] = [
	"id", "sequence", "good", "price", "quantity", "notional", "fee",
	"buy_id", "sell_id", "buy_owner", "sell_owner", "buy_price", "sell_price",
	"buy_refund", "sell_credit", "at_utc",
]
const SHIPMENT_KEYS: Array[String] = [
	"id", "sequence", "owner", "good", "quantity", "origin", "destination",
	"fee", "depart_utc", "arrive_utc", "status", "delivered_utc", "delivery_id",
	"risk", "lost_utc", "loss_id",
]
const DELIVERY_KEYS: Array[String] = [
	"id", "sequence", "shipment_id", "owner", "good", "quantity",
	"origin", "destination", "at_utc",
]


static func initial_state() -> Dictionary:
	var goods: Dictionary = {}
	var granted: Dictionary = {}
	for good_id: String in Catalog.goods_ids():
		goods[good_id] = 0
		granted[good_id] = 0
	return {
		"merchant": {
			"opened": false,
			"opened_by": "",
			"opened_utc": 0.0,
			"cash": 0,
			"goods": goods,
			"granted": granted,
		},
		"orders": {},
		"sequence": 0,
		"trades": {},
		"trade_sequence": 0,
		"shipments": {},
		"deliveries": {},
		"shipment_sequence": 0,
		"delivery_sequence": 0,
		"archived_orders": 0,
		"archived_shipments": 0,
		"archived_deliveries": 0,
	}


## Loss evidence lives beside the market because it is produced by the same
## arrival sweep, but it is not part of `market`: a world without losses must not
## read as a broken market. `archived` is the monotonic count of evicted events;
## `sequence` is the only source of loss ids.
static func initial_losses() -> Dictionary:
	return {"sequence": 0, "events": {}, "archived": 0}


## Adds the empty loss table for a pre-M8-03 economy and canonicalizes JSON
## numbers. This is the established restore normalization, not a migration file:
## no loss evidence is invented and no shipment changes state.
static func normalize_losses(economy: Dictionary) -> void:
	if not economy.get("losses") is Dictionary:
		economy.losses = initial_losses()
		return
	var losses: Dictionary = economy.losses
	losses.sequence = int(losses.sequence)
	losses.archived = int(losses.archived)
	if not losses.get("events") is Dictionary:
		return
	for loss_id: Variant in losses.events:
		var event: Variant = losses.events[loss_id]
		if not event is Dictionary:
			continue
		for key: String in ["sequence", "quantity", "unit_value", "value", "rule_version"]:
			if event.has(key):
				event[key] = int(event[key])
		for key: String in ["at_utc", "cause_start_utc", "cause_end_utc"]:
			if event.has(key):
				event[key] = float(event[key])


static func valid_owner(value: Variant) -> bool:
	return value is String and (value == MERCHANT or OwnerIds.valid(value))


static func valid_command_id(value: Variant) -> bool:
	return value is String and not value.is_empty() \
		and value.length() <= MAX_COMMAND_ID_LENGTH \
		and not Ledger.reserved_event_id(value) \
		and not Ledger.internal_event_id(value)


## Missing `economy.market` is the M7-01 shape: a valid empty market. A market
## written by M7-02 has no trade log yet and is read the same way, and an M7-03
## market has no shipment ledger; both restore as the empty shape they would
## have had. Every other structural problem is rejected rather than defaulted.
static func valid(economy: Dictionary) -> bool:
	if not economy.has("market"):
		return true
	var market: Variant = economy.market
	if not market is Dictionary:
		return false
	var legacy_trades: bool = not market.has("trades") and not market.has("trade_sequence")
	var legacy_logistics: bool = true
	for key: String in LOGISTICS_KEYS:
		if market.has(key):
			legacy_logistics = false
			break
	# The two archive counters came together and are both optional, exactly like
	# the trade and shipment shelves. A half-present pair is a broken document.
	var archive_present: int = 0
	for key: String in ARCHIVE_KEYS:
		if market.has(key):
			archive_present += 1
	if archive_present != 0 and archive_present != ARCHIVE_KEYS.size():
		return false
	var legacy_archive: bool = archive_present == 0
	var expected_size: int = MARKET_KEYS.size() \
		- (2 if legacy_trades else 0) - (4 if legacy_logistics else 0) \
		- (ARCHIVE_KEYS.size() if legacy_archive else 0)
	if market.size() != expected_size:
		return false
	for key: String in MARKET_KEYS:
		if legacy_trades and (key == "trades" or key == "trade_sequence"):
			continue
		if legacy_logistics and key in LOGISTICS_KEYS:
			continue
		if legacy_archive and key in ARCHIVE_KEYS:
			continue
		if not market.has(key):
			return false
	if not _valid_merchant(market.merchant):
		return false
	if not _is_count(market.sequence) or int(market.sequence) >= MAX_SAFE_INTEGER:
		return false
	if not legacy_trades and (not _is_count(market.trade_sequence) or int(market.trade_sequence) >= MAX_SAFE_INTEGER):
		return false
	if not legacy_logistics:
		if not _is_count(market.shipment_sequence) or int(market.shipment_sequence) >= MAX_SAFE_INTEGER:
			return false
		if not _is_count(market.delivery_sequence) or int(market.delivery_sequence) >= MAX_SAFE_INTEGER:
			return false
	if not legacy_archive:
		# Archiving only ever removes a row that already consumed a sequence, so
		# each count is bounded by its own monotonic counter.
		if not _is_count(market.archived_orders) or int(market.archived_orders) >= MAX_SAFE_INTEGER \
				or int(market.archived_orders) > int(market.sequence):
			return false
		if not _is_count(market.archived_shipments) or int(market.archived_shipments) >= MAX_SAFE_INTEGER \
				or int(market.archived_shipments) > int(market.get("shipment_sequence", 0)):
			return false
		if not _is_count(market.archived_deliveries) or int(market.archived_deliveries) >= MAX_SAFE_INTEGER \
				or int(market.archived_deliveries) > int(market.get("delivery_sequence", 0)):
			return false
	if not market.orders is Dictionary or market.orders.size() > MAX_ORDERS:
		return false
	var trades: Variant = {} if legacy_trades else market.trades
	if not trades is Dictionary or trades.size() > MAX_TRADES:
		return false
	var shipments: Variant = {} if legacy_logistics else market.shipments
	var deliveries: Variant = {} if legacy_logistics else market.deliveries
	if not shipments is Dictionary or shipments.size() > MAX_SHIPMENTS:
		return false
	if not deliveries is Dictionary or deliveries.size() > MAX_DELIVERIES:
		return false
	var merchant_opened: bool = bool(market.merchant.opened)
	var max_sequence: int = 0
	var sequences: Dictionary = {}
	var quote_rows: int = 0
	for order_id: Variant in market.orders:
		var order_value: Variant = market.orders[order_id]
		if not _valid_order(order_id, order_value, int(market.sequence)):
			return false
		var order: Dictionary = order_value
		if str(order.owner) == MERCHANT and not merchant_opened:
			return false
		if _is_merchant_quote_id(str(order_id)):
			# The rolling rule owns exactly six bids and six asks; more rows
			# would mean a crafted snapshot or a broken refresh.
			if str(order.owner) != MERCHANT:
				return false
			quote_rows += 1
			if quote_rows > Catalog.goods_ids().size() * 2:
				return false
		var sequence: int = int(order.sequence)
		if sequences.has(sequence):
			return false
		sequences[sequence] = true
		max_sequence = maxi(max_sequence, sequence)
	var max_trade_sequence: int = 0
	var trade_sequences: Dictionary = {}
	for trade_id: Variant in trades:
		var trade_value: Variant = trades[trade_id]
		if not _valid_trade(trade_id, trade_value, int(market.get("trade_sequence", 0))):
			return false
		var sequence: int = int(trade_value.sequence)
		if trade_sequences.has(sequence):
			return false
		trade_sequences[sequence] = true
		max_trade_sequence = maxi(max_trade_sequence, sequence)
	# A trade may point at an archived order row. A present row is still
	# cross-checked field by field; a missing row is trusted through the trade
	# row, which `_valid_trade` already checked for owner, good, limits and the
	# maker price rule (`price` equals one of the two limits and stays between
	# them). Merchant quote rows are never archived, so a missing merchant id
	# cannot be explained by archiving. The number of distinct missing ids is
	# bounded by the archive counter, so a crafted log cannot invent arbitrary
	# order references.
	var missing_order_ids: Dictionary = {}
	for trade_id: Variant in trades:
		var trade: Dictionary = trades[trade_id]
		var buy_id: String = str(trade.buy_id)
		var sell_id: String = str(trade.sell_id)
		var buy_row: Variant = market.orders.get(buy_id)
		var sell_row: Variant = market.orders.get(sell_id)
		if buy_row is Dictionary:
			if str(buy_row.owner) != str(trade.buy_owner) or str(buy_row.good) != str(trade.good) \
					or str(buy_row.side) != SIDE_BUY or int(buy_row.price) != int(trade.buy_price):
				return false
		elif _is_merchant_quote_id(buy_id):
			return false
		else:
			missing_order_ids[buy_id] = true
		if sell_row is Dictionary:
			if str(sell_row.owner) != str(trade.sell_owner) or str(sell_row.good) != str(trade.good) \
					or str(sell_row.side) != SIDE_SELL or int(sell_row.price) != int(trade.sell_price):
				return false
		elif _is_merchant_quote_id(sell_id):
			return false
		else:
			missing_order_ids[sell_id] = true
	if missing_order_ids.size() > int(market.get("archived_orders", 0)):
		return false
	var max_shipment_sequence: int = 0
	var shipment_sequences: Dictionary = {}
	for shipment_id: Variant in shipments:
		var shipment_value: Variant = shipments[shipment_id]
		if not _valid_shipment(shipment_id, shipment_value, int(market.get("shipment_sequence", 0))):
			return false
		var sequence: int = int(shipment_value.sequence)
		if shipment_sequences.has(sequence):
			return false
		shipment_sequences[sequence] = true
		max_shipment_sequence = maxi(max_shipment_sequence, sequence)
	var max_delivery_sequence: int = 0
	var delivery_sequences: Dictionary = {}
	var delivered_shipments: Dictionary = {}
	for delivery_id: Variant in deliveries:
		var delivery_value: Variant = deliveries[delivery_id]
		if not _valid_delivery(delivery_id, delivery_value, int(market.get("delivery_sequence", 0))):
			return false
		var sequence: int = int(delivery_value.sequence)
		if delivery_sequences.has(sequence):
			return false
		delivery_sequences[sequence] = true
		max_delivery_sequence = maxi(max_delivery_sequence, sequence)
		var shipment_id: String = str(delivery_value.shipment_id)
		if delivered_shipments.has(shipment_id):
			# One shipment produces one delivery event, so two rows cannot point
			# at the same shipment.
			return false
		delivered_shipments[shipment_id] = str(delivery_id)
	# A delivered shipment must link to its one delivery row, and an in-transit
	# shipment must not claim one. This is the durable guard against a crafted
	# snapshot that would deliver the same goods twice. When the delivery event
	# itself was archived, the delivered shipment row is the remaining evidence;
	# its owner, good, quantity, route and time were already checked by
	# `_valid_shipment`. Distinct missing delivery ids are bounded by the archive
	# counter, so a crafted shipment cannot invent archived events.
	var missing_delivery_ids: Dictionary = {}
	for shipment_id: Variant in shipments:
		var shipment: Dictionary = shipments[shipment_id]
		var delivery_id: String = str(shipment.delivery_id)
		if str(shipment.status) == SHIPMENT_STATUS_DELIVERED:
			if deliveries.has(delivery_id):
				if not delivered_shipments.has(str(shipment_id)) \
						or str(delivered_shipments[str(shipment_id)]) != delivery_id:
					return false
				var delivery: Dictionary = deliveries[delivery_id]
				if str(delivery.owner) != str(shipment.owner) or str(delivery.good) != str(shipment.good) \
						or int(delivery.quantity) != int(shipment.quantity) \
						or str(delivery.origin) != str(shipment.origin) \
						or str(delivery.destination) != str(shipment.destination) \
						or float(delivery.at_utc) != float(shipment.delivered_utc):
					return false
			else:
				if missing_delivery_ids.has(delivery_id):
					# One delivery event settles one shipment; two delivered rows
					# cannot share an archived id to hide a fabricated receipt.
					return false
				missing_delivery_ids[delivery_id] = true
		elif not delivery_id.is_empty() or delivered_shipments.has(str(shipment_id)):
			return false
	if missing_delivery_ids.size() > int(market.get("archived_deliveries", 0)):
		return false
	# A delivered shipment row may itself have been archived. Its delivery event
	# is then the durable evidence: `_valid_delivery` already checked its id,
	# owner, good, quantity, route and time. Present rows were cross-checked
	# against their delivery above. Distinct missing ids are bounded by the
	# archive counter, so a crafted event cannot invent arbitrary shipments.
	var missing_shipment_ids: Dictionary = {}
	for shipment_id: Variant in delivered_shipments:
		if not shipments.has(str(shipment_id)):
			missing_shipment_ids[str(shipment_id)] = true
	if missing_shipment_ids.size() > int(market.get("archived_shipments", 0)):
		return false
	return max_sequence <= int(market.sequence) \
		and max_trade_sequence <= int(market.get("trade_sequence", 0)) \
		and max_shipment_sequence <= int(market.get("shipment_sequence", 0)) \
		and max_delivery_sequence <= int(market.get("delivery_sequence", 0))


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


static func escrowed_cash_for(economy: Dictionary, owner: String) -> int:
	var market: Variant = economy.get("market")
	if not market is Dictionary or not market.get("orders") is Dictionary:
		return 0
	var total: int = 0
	for order: Variant in market.orders.values():
		if order is Dictionary and str(order.get("side", "")) == SIDE_BUY \
				and str(order.get("status", "")) == STATUS_OPEN \
				and str(order.get("owner", "")) == owner:
			total += int(order.get("reserved", 0))
	return total


## Fixed two-sided quote: one unit below/above the catalog reference price.
## The price never drifts, so a player can reason about the spread and the
## merchant cannot be traded against its own future quote.
static func merchant_bid_price(good_id: String) -> int:
	if not Catalog.is_good(good_id):
		return 0
	return maxi(1, Catalog.base_price(good_id) - 1)


static func merchant_ask_price(good_id: String) -> int:
	if not Catalog.is_good(good_id):
		return 0
	return Catalog.base_price(good_id) + 1


static func merchant_quote_price(good_id: String, side: String) -> int:
	if side == SIDE_BUY:
		return merchant_bid_price(good_id)
	return merchant_ask_price(good_id)


static func merchant_quote_id(good_id: String, side: String) -> String:
	var prefix: String = MERCHANT_BID_PREFIX if side == SIDE_BUY else MERCHANT_ASK_PREFIX
	return prefix + good_id


## Deterministic quote from the catalog reference price and the merchant's
## current available cash/stock. Capacities are bounded by the order limits.
static func quote(economy: Dictionary, good_id: String) -> Dictionary:
	if not Catalog.is_good(good_id):
		return {}
	var bid: int = merchant_bid_price(good_id)
	var ask: int = merchant_ask_price(good_id)
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


## The one-time grant written to the merchant row. A legacy market without the
## field reads as all zeros instead of inventing stock.
static func merchant_granted(economy: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for good_id: String in Catalog.goods_ids():
		result[good_id] = 0
	var market: Variant = economy.get("market")
	if market is Dictionary and market.get("merchant") is Dictionary:
		var granted: Variant = market.merchant.get("granted")
		if granted is Dictionary:
			for good_id: String in result:
				if granted.has(good_id):
					result[good_id] = int(granted[good_id])
	return result


## Grants the one-time opening stock if the merchant row has no grant record
## yet. The field is the durable marker, so a reload can never grant twice and
## a legacy world opened before this rule gains the same stock on its first
## sweep. Returns true only when stock was added.
static func grant_merchant_stock(merchant: Dictionary) -> bool:
	if merchant.has("granted"):
		return false
	var goods: Variant = merchant.get("goods")
	if not goods is Dictionary:
		return false
	var granted: Dictionary = {}
	for good_id: String in Catalog.goods_ids():
		if not _is_count(_amount(goods, good_id) + MERCHANT_GRANT_PER_GOOD):
			return false
		granted[good_id] = MERCHANT_GRANT_PER_GOOD
	for good_id: String in Catalog.goods_ids():
		goods[good_id] = _amount(goods, good_id) + MERCHANT_GRANT_PER_GOOD
	merchant.granted = granted
	return true


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
	var goods: Dictionary = merchant.goods
	var granted_value: Variant = merchant.get("granted")
	var granted: Dictionary = granted_value if granted_value is Dictionary else {}
	for good_id: String in Catalog.goods_ids():
		if not _is_count(int(goods.get(good_id, 0)) + MERCHANT_GRANT_PER_GOOD):
			return error("invalid_amount")
	# The grant is one-time issuance evidence, not a second wallet: the stock
	# and its `granted` record change on the same candidate as the budget.
	var posted: Dictionary = _post(data, Ledger.KIND_MERCHANT_BUDGET, command_id, now_utc, [
		Ledger.debit_line(Ledger.MERCHANT, MERCHANT_BUDGET),
		Ledger.credit_line(Ledger.ISSUANCE, MERCHANT_BUDGET),
	])
	if not posted.ok:
		return error(str(posted.reason))
	merchant.opened = true
	merchant.opened_by = command_id
	merchant.opened_utc = float(now_utc)
	merchant.cash = int(merchant.cash) + MERCHANT_BUDGET
	merchant.granted = granted
	for good_id: String in Catalog.goods_ids():
		goods[good_id] = int(goods.get(good_id, 0)) + MERCHANT_GRANT_PER_GOOD
		granted[good_id] = MERCHANT_GRANT_PER_GOOD
	data.economy.issued = int(data.economy.issued) + MERCHANT_BUDGET
	var quoted: Dictionary = _maintain_merchant_quotes(data, market, now_utc)
	if not quoted.ok:
		return error(str(quoted.reason))
	return {
		"ok": true, "reason": "", "duplicate": false, "amount": MERCHANT_BUDGET,
		"budget": MERCHANT_BUDGET,
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
	# JSON stores epoch-sized doubles with about 15 significant digits, so a
	# sub-microsecond lifetime would save as `expires == created` and be refused
	# on the next load. One second is the smallest lifetime that survives the
	# document round trip.
	if not _valid_time(now_utc) or not _valid_time(expires_utc) \
			or float(expires_utc) - float(now_utc) < 1.0:
		return error("invalid_expiry")
	return {"ok": true, "reason": ""}


static func place(data: Dictionary, command_id: String, owner: String, side: String,
		good_id: String, price: Variant, quantity: Variant, expires_utc: float,
		now_utc: float) -> Dictionary:
	if not valid_command_id(command_id):
		return error("invalid_command")
	# Player orders may not squat on the stable ids the merchant rule reuses.
	if owner != MERCHANT and _is_merchant_quote_id(command_id):
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
	if _trade_references_order(market, command_id):
		# The row is gone but a retained trade still points at this id. Reusing
		# it would make that trade cross-check against a different row, so the
		# durable evidence keeps the id reserved until the trade itself is
		# evicted from the bounded trade log.
		return error("order_exists")
	if market.orders.size() >= MAX_ORDERS:
		# Only closed evidence is evicted; a full table of open orders still has
		# escrow in every row and keeps returning the original limit error.
		if not _archive_closed_order(market):
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
		var posted: Dictionary = _post(data, Ledger.KIND_ESCROW_HOLD, command_id, now_utc, [
			Ledger.debit_line(Ledger.ESCROW, cost),
			Ledger.credit_line(_ledger_code(owner), cost),
		])
		if not posted.ok:
			return error(str(posted.reason))
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
	if str(order.side) == SIDE_BUY and int(order.reserved) > 0:
		var posted: Dictionary = _post(data, Ledger.KIND_ESCROW_RELEASE, command_id, now_utc, [
			Ledger.debit_line(_ledger_code(str(order.owner)), int(order.reserved)),
			Ledger.credit_line(Ledger.ESCROW, int(order.reserved)),
		])
		if not posted.ok:
			return error(str(posted.reason))
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
		if str(order.side) == SIDE_BUY and int(order.reserved) > 0:
			var posted: Dictionary = _post(data, Ledger.KIND_ESCROW_RELEASE,
				"expire_" + str(int(order.sequence)), now_utc, [
					Ledger.debit_line(_ledger_code(str(order.owner)), int(order.reserved)),
					Ledger.credit_line(Ledger.ESCROW, int(order.reserved)),
				])
			if not posted.ok:
				return error(str(posted.reason))
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


## Deterministic matching sweep. The authority calls it with the same UTC
## seconds it uses for every other rule; the function never reads the clock.
## Only orders that are open, already created and not yet due can trade, so at
## one UTC instant `match(now)` and `expire(now)` commute: an order at its own
## expiry never fills, and expiry only releases what matching left open.
##
## The whole sweep runs on the caller's candidate. A later failure discards
## that candidate, so no fill is committed one-sided.
static func match(data: Dictionary, now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return match_error("invalid_time")
	var market: Dictionary = _market(data)
	if market.is_empty() or not market.orders is Dictionary or not market.trades is Dictionary:
		return match_error("invalid_market")
	# Rolling quotes are refreshed before the sweep so one scan can both reopen
	# a side and trade against it. The maintenance is state-driven: given the
	# same data and `now_utc` it produces the same rows and sequences.
	var maintained: Dictionary = _maintain_merchant_quotes(data, market, now_utc)
	if not maintained.ok:
		return match_error(str(maintained.reason))
	var all_trades: Array = []
	var total_fee: int = 0
	var total_notional: int = 0
	for good_id: String in Catalog.goods_ids():
		var matched: Dictionary = _match_good(data, market, good_id, now_utc)
		if not matched.ok:
			return matched
		all_trades.append_array(matched.trades)
		total_fee += int(matched.fee)
		total_notional += int(matched.notional)
	return {
		"ok": true, "reason": "", "duplicate": false, "count": all_trades.size(),
		"trades": all_trades, "fee": total_fee, "notional": total_notional,
		# The caller must persist a sweep that only relisted or expired a
		# merchant quote; otherwise the refreshed rows exist only inside the
		# discarded candidate until the next trade happens to commit.
		"changed": bool(maintained.get("changed", false)),
	}


static func match_error(reason: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "duplicate": false, "count": 0,
		"trades": [], "fee": 0, "notional": 0,
	}


## Command-bound callers may pass an id so a disconnected retry replays the same
## sweep count. The sweep itself is still state-driven; the id only records how
## many fills the accepted call produced, never a second settlement.
static func match_payload(now_utc: float) -> String:
	return JSON.stringify(["market_match", float(now_utc)])


static func match_replay(ledger: Dictionary) -> Dictionary:
	if ledger.is_empty():
		return {}
	return {
		"ok": bool(ledger.get("ok", false)), "reason": str(ledger.get("reason", "")),
		"duplicate": true, "count": int(ledger.get("amount", 0)),
		"trades": [], "fee": 0, "notional": 0,
	}


## M7-04: the two fixed market locations and their single route shape. The
## route is symmetric because this slice only proves in-transit ownership and
## delivery cost, not distance pricing.
static func valid_route(origin: String, destination: String) -> bool:
	return origin in LOCATIONS and destination in LOCATIONS and origin != destination


static func route(origin: String, destination: String) -> Dictionary:
	if not valid_route(origin, destination):
		return {}
	return {
		"origin": origin, "destination": destination, "fee": SHIPMENT_FEE,
		"delivery_seconds": DELIVERY_SECONDS,
	}


static func routes() -> Array:
	return [route(LOCATION_FARM, LOCATION_HARBOR), route(LOCATION_HARBOR, LOCATION_FARM)]


## Deterministic declared-risk roll in 0..999. Only persisted shipment fields
## are hashed; the command id is deliberately excluded so a client cannot grind
## ids for a favorable verdict. The fixed integer time keeps the roll identical
## after a JSON round trip.
static func transport_loss_roll(sequence: int, owner: String, good_id: String,
		quantity: int, origin: String, destination: String, depart_utc: float) -> int:
	return _fnv1a([
		TRANSPORT_LOSS_TAG, str(sequence), owner, good_id, str(quantity), origin,
		destination, str(int(depart_utc)),
	]) % 1000


static func transport_loss_expected(sequence: int, owner: String, good_id: String,
		quantity: int, origin: String, destination: String, depart_utc: float) -> bool:
	return transport_loss_roll(sequence, owner, good_id, quantity, origin, destination,
		depart_utc) < RISK_LOSS_PERMILLE


## Dictionary form used by the arrival sweep and by fixtures. It reads only the
## durable shipment row, so the same row always decides the same way.
static func declared_loss_expected(shipment: Dictionary) -> bool:
	return transport_loss_expected(int(shipment.get("sequence", 0)),
		str(shipment.get("owner", "")), str(shipment.get("good", "")),
		int(shipment.get("quantity", 0)), str(shipment.get("origin", "")),
		str(shipment.get("destination", "")), float(shipment.get("depart_utc", 0.0)))


static func validate_ship(owner: String, origin: String, destination: String, good_id: String,
		quantity: Variant, now_utc: float, risk: String = SHIPMENT_RISK_SAFE) -> Dictionary:
	# Market locations are not owners. The merchant and @world cannot ship: the
	# merchant has rule cash/goods and no bag, and public harvest stock has no
	# player account to pay a fee from.
	if not OwnerIds.valid(owner):
		return error("invalid_owner")
	if not Catalog.is_good(good_id):
		return error("invalid_good")
	if not valid_route(origin, destination):
		return error("invalid_route")
	if not _is_positive_count(quantity) or int(quantity) > MAX_QUANTITY:
		return error("invalid_quantity")
	if risk not in SHIPMENT_RISKS:
		return error("invalid_risk")
	if not _valid_time(now_utc):
		return error("invalid_time")
	return {"ok": true, "reason": ""}


## Shipping is the only way goods enter the in-transit table. The quantity
## leaves the owner's bag in the same candidate that records the shipment row
## and burns the fee, so a sell order (or a second shipment) cannot reach it
## before delivery.
static func ship(data: Dictionary, command_id: String, owner: String, origin: String,
		destination: String, good_id: String, quantity: Variant, now_utc: float,
		risk: String = SHIPMENT_RISK_SAFE) -> Dictionary:
	if not valid_command_id(command_id):
		return error("invalid_command")
	var checked: Dictionary = validate_ship(owner, origin, destination, good_id, quantity,
		now_utc, risk)
	if not checked.ok:
		return checked
	var market: Dictionary = _market(data)
	if market.is_empty() or not market.get("shipments") is Dictionary \
			or not market.get("deliveries") is Dictionary:
		return error("invalid_market")
	if market.shipments.has(command_id):
		# The shipment id is durable; an evicted command ledger cannot move the
		# same goods a second time.
		return error("shipment_exists")
	if _delivery_references_shipment(market, command_id) \
			or _loss_references_shipment(data, command_id):
		# The terminal row was archived, but its delivery or loss event still
		# names this id. Reusing it would make that evidence cross-check against a
		# different shipment, so the evidence keeps the id reserved.
		return error("shipment_exists")
	if market.shipments.size() >= MAX_SHIPMENTS:
		# In-transit rows still own their goods and can never be evicted. A
		# table of nothing but in-transit rows keeps the original limit error.
		if not _archive_terminal_shipment(market):
			return error("shipment_limit")
	var sequence: int = int(market.shipment_sequence) + 1
	if not _is_count(sequence):
		return error("shipment_limit")
	var count: int = int(quantity)
	var goods: Dictionary = _goods_for(data, owner)
	if _amount(goods, good_id) < count:
		return error("insufficient_goods")
	var arrive_utc: float = float(now_utc) + DELIVERY_SECONDS
	if not is_finite(arrive_utc):
		return error("invalid_time")
	if int(data.economy.issued) < SHIPMENT_FEE:
		return error("invalid_market")
	var paid: Dictionary = _deduct_cash(data, owner, SHIPMENT_FEE)
	if not paid.ok:
		return error(str(paid.reason))
	var posted: Dictionary = _post(data, Ledger.KIND_SHIPPING_FEE, command_id, now_utc, [
		Ledger.debit_line(Ledger.BURN, SHIPMENT_FEE),
		Ledger.credit_line(_ledger_code(owner), SHIPMENT_FEE),
	])
	if not posted.ok:
		return error(str(posted.reason))
	goods[good_id] = _amount(goods, good_id) - count
	data.economy.issued = int(data.economy.issued) - SHIPMENT_FEE
	market.shipment_sequence = sequence
	var shipment: Dictionary = {
		"id": command_id,
		"sequence": sequence,
		"owner": owner,
		"good": good_id,
		"quantity": count,
		"origin": origin,
		"destination": destination,
		"fee": SHIPMENT_FEE,
		"depart_utc": float(now_utc),
		"arrive_utc": arrive_utc,
		"status": SHIPMENT_STATUS_TRANSIT,
		"delivered_utc": 0.0,
		"delivery_id": "",
		"risk": risk,
		"lost_utc": 0.0,
		"loss_id": "",
	}
	market.shipments[command_id] = shipment
	return _shipment_result(shipment, false)


## Delivery is a deterministic sweep like expiry and matching. Every shipment
## whose arrival time has been reached is settled at once, in shipment order, on
## the caller's candidate. A `safe` shipment always returns its goods; a
## `declared` shipment is either delivered or lost by the pure roll above, and a
## lost row is skipped for good. A repeated sweep finds no in-transit row and is
## a no-op; the durable status is the double-delivery/double-loss guard.
static func deliver(data: Dictionary, now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return delivery_error("invalid_time")
	var market: Dictionary = _market(data)
	if market.is_empty() or not market.get("shipments") is Dictionary \
			or not market.get("deliveries") is Dictionary:
		return delivery_error("invalid_market")
	if not data.get("economy") is Dictionary or not data.economy.get("losses") is Dictionary:
		return delivery_error("invalid_losses")
	var losses: Dictionary = data.economy.losses
	var due: Array = []
	for shipment_id: Variant in market.shipments:
		var shipment: Variant = market.shipments[shipment_id]
		if not shipment is Dictionary:
			continue
		if str(shipment.get("status", "")) != SHIPMENT_STATUS_TRANSIT:
			continue
		if float(shipment.get("arrive_utc", 0.0)) > float(now_utc):
			continue
		due.append(shipment)
	due.sort_custom(_shipment_before)
	var delivered: Array = []
	var lost: Array = []
	for shipment: Dictionary in due:
		# The verdict uses only the persisted row, so the same arrival reached
		# after a restart or a long offline catch-up is decided identically.
		if str(shipment.get("risk", SHIPMENT_RISK_SAFE)) == SHIPMENT_RISK_DECLARED \
				and declared_loss_expected(shipment):
			var written: Dictionary = _write_transport_loss(losses, shipment)
			if not written.ok:
				return delivery_error(str(written.reason))
			lost.append(written.event)
			continue
		var good_id: String = str(shipment.good)
		var owner: String = str(shipment.owner)
		var count: int = int(shipment.quantity)
		var goods: Dictionary = _ensure_goods(data, owner)
		var current: int = _amount(goods, good_id)
		if current > MAX_SAFE_INTEGER - count:
			return delivery_error("invalid_amount")
		var sequence: int = int(market.delivery_sequence) + 1
		if not _is_count(sequence):
			return delivery_error("delivery_limit")
		if market.deliveries.size() >= MAX_DELIVERIES:
			# Every delivery row is terminal evidence, so the oldest one can be
			# archived without moving goods or cash. The shipment row keeps its
			# own owner/good/quantity/route/time evidence if it is still present.
			if not _archive_delivery(market):
				return delivery_error("delivery_limit")
		market.delivery_sequence = sequence
		var delivery_id: String = DELIVERY_ID_PREFIX + str(sequence)
		var event: Dictionary = {
			"id": delivery_id,
			"sequence": sequence,
			"shipment_id": str(shipment.id),
			"owner": owner,
			"good": good_id,
			"quantity": count,
			"origin": str(shipment.origin),
			"destination": str(shipment.destination),
			"at_utc": float(now_utc),
		}
		goods[good_id] = current + count
		market.deliveries[delivery_id] = event
		shipment.status = SHIPMENT_STATUS_DELIVERED
		shipment.delivered_utc = float(now_utc)
		shipment.delivery_id = delivery_id
		delivered.append(event.duplicate(true))
	return {
		"ok": true, "reason": "", "duplicate": false,
		"count": delivered.size(), "deliveries": delivered,
		"lost": lost.size(), "losses": lost,
	}


## Writes the one durable loss event for an arrived declared shipment and moves
## the row to the terminal `lost` state. Goods are not added anywhere: they left
## the bag at ship time and are now destroyed. Cash is untouched, so the fee
## burned at ship time remains the only money effect. The event stamps the risk
## window (`depart_utc..arrive_utc`), never the sweep instant, so an offline
## catch-up proves when the loss happened.
static func _write_transport_loss(losses: Dictionary, shipment: Dictionary) -> Dictionary:
	if shipment.has("lost_utc") and float(shipment.get("lost_utc", 0.0)) != 0.0:
		return {"ok": false, "reason": "shipment_settled"}
	if str(shipment.get("status", "")) != SHIPMENT_STATUS_TRANSIT:
		return {"ok": false, "reason": "shipment_settled"}
	var sequence: int = int(losses.sequence) + 1
	if not _is_count(sequence) or sequence >= MAX_SAFE_INTEGER:
		return {"ok": false, "reason": "loss_limit"}
	if not losses.get("events") is Dictionary:
		return {"ok": false, "reason": "invalid_losses"}
	var events: Dictionary = losses.events
	if events.size() >= MAX_LOSSES:
		# Every loss row is terminal evidence, so the oldest can be archived
		# without changing any balance. The lost shipment row keeps its own
		# evidence while it is still present; `archived` records the eviction.
		if not _archive_loss(losses):
			return {"ok": false, "reason": "loss_limit"}
	var good_id: String = str(shipment.get("good", ""))
	var quantity: int = int(shipment.get("quantity", 0))
	var unit_value: int = Catalog.base_price(good_id)
	if unit_value <= 0 or not _is_positive_count(quantity):
		return {"ok": false, "reason": "invalid_loss"}
	var value: int = unit_value * quantity
	if not _is_count(value) or value <= 0:
		return {"ok": false, "reason": "invalid_loss"}
	var arrive_utc: float = float(shipment.get("arrive_utc", 0.0))
	var depart_utc: float = float(shipment.get("depart_utc", 0.0))
	var loss_id: String = LOSS_ID_PREFIX + str(sequence)
	var event: Dictionary = {
		"id": loss_id,
		"sequence": sequence,
		"kind": TRANSPORT_LOSS_KIND,
		"at_utc": arrive_utc,
		"cause_start_utc": depart_utc,
		"cause_end_utc": arrive_utc,
		"victim": str(shipment.get("owner", "")),
		"shipment_id": str(shipment.get("id", "")),
		"good": good_id,
		"quantity": quantity,
		"unit_value": unit_value,
		"value": value,
		"rule_version": TRANSPORT_LOSS_RULE_VERSION,
	}
	losses.sequence = sequence
	events[loss_id] = event
	shipment.status = SHIPMENT_STATUS_LOST
	shipment.lost_utc = arrive_utc
	shipment.loss_id = loss_id
	shipment.delivered_utc = 0.0
	shipment.delivery_id = ""
	return {"ok": true, "reason": "", "event": event.duplicate(true)}


static func delivery_error(reason: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "duplicate": false, "count": 0, "deliveries": [],
		"lost": 0, "losses": [],
	}


static func shipments(economy: Dictionary) -> Array:
	var market: Variant = economy.get("market")
	if not market is Dictionary or not market.get("shipments") is Dictionary:
		return []
	var result: Array = market.shipments.values().duplicate(true)
	result.sort_custom(_shipment_before)
	return result


static func shipment(economy: Dictionary, shipment_id: String) -> Dictionary:
	var market: Variant = economy.get("market")
	if market is Dictionary and market.get("shipments") is Dictionary \
			and market.shipments.get(shipment_id) is Dictionary:
		return market.shipments[shipment_id].duplicate(true)
	return {}


static func deliveries(economy: Dictionary) -> Array:
	var market: Variant = economy.get("market")
	if not market is Dictionary or not market.get("deliveries") is Dictionary:
		return []
	var result: Array = market.deliveries.values().duplicate(true)
	result.sort_custom(_delivery_before)
	return result


static func delivery(economy: Dictionary, delivery_id: String) -> Dictionary:
	var market: Variant = economy.get("market")
	if market is Dictionary and market.get("deliveries") is Dictionary \
			and market.deliveries.get(delivery_id) is Dictionary:
		return market.deliveries[delivery_id].duplicate(true)
	return {}


static func losses(economy: Dictionary) -> Array:
	var losses_value: Variant = economy.get("losses")
	if not losses_value is Dictionary or not losses_value.get("events") is Dictionary:
		return []
	var result: Array = losses_value.events.values().duplicate(true)
	result.sort_custom(_loss_before)
	return result


static func loss(economy: Dictionary, loss_id: String) -> Dictionary:
	var losses_value: Variant = economy.get("losses")
	if losses_value is Dictionary and losses_value.get("events") is Dictionary \
			and losses_value.events.get(loss_id) is Dictionary:
		return losses_value.events[loss_id].duplicate(true)
	return {}


## The shipment payload binds the declared risk only when it is not the default,
## so a shipment committed before risk existed still replays its original bytes.
static func ship_payload(owner: String, origin: String, destination: String, good_id: String,
		quantity: Variant, now_utc: float, risk: String = SHIPMENT_RISK_SAFE) -> String:
	var payload: Array = ["market_ship", owner, origin, destination, good_id, int(quantity),
		float(now_utc)]
	if risk != SHIPMENT_RISK_SAFE:
		payload.append(risk)
	return JSON.stringify(payload)


static func deliver_payload(now_utc: float) -> String:
	return JSON.stringify(["market_deliver", float(now_utc)])


static func deliver_replay(ledger: Dictionary) -> Dictionary:
	if ledger.is_empty():
		return {}
	return {
		"ok": bool(ledger.get("ok", false)), "reason": str(ledger.get("reason", "")),
		"duplicate": true, "count": int(ledger.get("amount", 0)), "deliveries": [],
		"lost": 0, "losses": [],
	}


static func _shipment_result(shipment: Dictionary, duplicate: bool) -> Dictionary:
	return {
		"ok": true, "reason": "", "duplicate": duplicate,
		"shipment_id": str(shipment.id), "owner": str(shipment.owner),
		"good": str(shipment.good), "quantity": int(shipment.quantity),
		"origin": str(shipment.origin), "destination": str(shipment.destination),
		"fee": int(shipment.fee), "depart_utc": float(shipment.depart_utc),
		"arrive_utc": float(shipment.arrive_utc), "status": str(shipment.status),
		"delivery_id": str(shipment.delivery_id), "amount": int(shipment.quantity),
		"risk": str(shipment.get("risk", SHIPMENT_RISK_SAFE)),
		"lost_utc": float(shipment.get("lost_utc", 0.0)),
		"loss_id": str(shipment.get("loss_id", "")),
	}


static func _shipment_before(a: Variant, b: Variant) -> bool:
	var left: Dictionary = a
	var right: Dictionary = b
	if int(left.sequence) != int(right.sequence):
		return int(left.sequence) < int(right.sequence)
	return str(left.id) < str(right.id)


static func _delivery_before(a: Variant, b: Variant) -> bool:
	var left: Dictionary = a
	var right: Dictionary = b
	if int(left.sequence) != int(right.sequence):
		return int(left.sequence) < int(right.sequence)
	return str(left.id) < str(right.id)


static func _loss_before(a: Variant, b: Variant) -> bool:
	var left: Dictionary = a
	var right: Dictionary = b
	if int(left.sequence) != int(right.sequence):
		return int(left.sequence) < int(right.sequence)
	return str(left.id) < str(right.id)


static func trades(economy: Dictionary) -> Array:
	var market: Variant = economy.get("market")
	if not market is Dictionary or not market.get("trades") is Dictionary:
		return []
	var result: Array = market.trades.values().duplicate(true)
	result.sort_custom(_trade_before)
	return result


static func trade(economy: Dictionary, trade_id: String) -> Dictionary:
	var market: Variant = economy.get("market")
	if market is Dictionary and market.get("trades") is Dictionary \
			and market.trades.get(trade_id) is Dictionary:
		return market.trades[trade_id].duplicate(true)
	return {}


## Keeps exactly one bid and one ask per good on the merchant's stable rows.
## A live row is left alone; a due row is expired and released, then the same
## id is reopened if the merchant still has the cash (buy) or stock (sell).
## Missing rows are created only while the 256-row table has room, so merchant
## liquidity can never push the table past its bound.
static func _maintain_merchant_quotes(data: Dictionary, market: Dictionary,
		now_utc: float) -> Dictionary:
	if not market.get("merchant") is Dictionary or not market.get("orders") is Dictionary:
		return {"ok": true, "reason": "", "changed": false}
	if not bool(market.merchant.get("opened", false)):
		return {"ok": true, "reason": "", "changed": false}
	var changed: bool = false
	# A world opened before the stock rule has no `granted` field. The first
	# sweep after the rule exists grants the same one-time stock, exactly once:
	# the field itself is the durable marker, so a reload cannot grant twice.
	# This is the rule taking effect, not a document migration; goods and their
	# provenance change together.
	if market.merchant.has("granted"):
		pass
	elif not grant_merchant_stock(market.merchant):
		return {"ok": false, "reason": "invalid_market", "changed": false}
	else:
		changed = true
	for good_id: String in Catalog.goods_ids():
		for side: String in SIDES:
			var stepped: Dictionary = _maintain_merchant_side(data, market, good_id, side, now_utc)
			if not stepped.ok:
				return stepped
			changed = changed or bool(stepped.get("changed", false))
	return {"ok": true, "reason": "", "changed": changed}


static func _maintain_merchant_side(data: Dictionary, market: Dictionary, good_id: String,
		side: String, now_utc: float) -> Dictionary:
	var order_id: String = merchant_quote_id(good_id, side)
	var orders: Dictionary = market.orders
	var existing_value: Variant = orders.get(order_id)
	var existing: Dictionary = existing_value if existing_value is Dictionary else {}
	if not existing.is_empty() and str(existing.get("owner", "")) != MERCHANT:
		# A player order already owns this id. Leave it alone rather than
		# mutating another owner's row or creating a duplicate merchant quote.
		return {"ok": true, "reason": ""}
	var changed: bool = false
	if not existing.is_empty() and str(existing.get("status", "")) == STATUS_OPEN:
		if float(existing.get("expires_utc", 0.0)) > now_utc:
			return {"ok": true, "reason": "", "changed": false}
		var expired: Dictionary = _expire_merchant_quote(data, existing, now_utc)
		if not expired.ok:
			return expired
		changed = true
	var price: int = merchant_quote_price(good_id, side)
	if price <= 0:
		return {"ok": true, "reason": "", "changed": changed}
	var quantity: int = MERCHANT_QUOTE_QUANTITY
	var merchant: Dictionary = market.merchant
	# The refreshed sequence is also the journal event suffix. Live entries keep
	# one line per event id, and a rolling quote reopens many times, so the id
	# must advance with the order sequence while staying a pure function of the
	# input state.
	var sequence: int = int(market.get("sequence", 0)) + 1
	if not _is_count(sequence) or sequence >= MAX_SAFE_INTEGER:
		return {"ok": false, "reason": "order_limit"}
	var reserved: int = 0
	if side == SIDE_BUY:
		var cost: int = price * quantity
		if int(merchant.get("cash", 0)) < cost:
			# The buy side stops replenishing until another fill returns cash.
			return {"ok": true, "reason": "", "changed": changed}
		if existing.is_empty() and orders.size() >= MAX_ORDERS:
			return {"ok": true, "reason": "", "changed": changed}
		merchant.cash = int(merchant.cash) - cost
		var posted: Dictionary = _post(data, Ledger.KIND_ESCROW_HOLD,
			MERCHANT_QUOTE_EVENT_PREFIX + order_id + "_" + str(sequence), now_utc, [
				Ledger.debit_line(Ledger.ESCROW, cost),
				Ledger.credit_line(Ledger.MERCHANT, cost),
			])
		if not posted.ok:
			return {"ok": false, "reason": str(posted.reason)}
		reserved = cost
	else:
		var goods: Variant = merchant.get("goods")
		if not goods is Dictionary:
			return {"ok": false, "reason": "invalid_market"}
		var stock: int = _amount(goods, good_id)
		if stock < quantity:
			# The sell side stops replenishing until a bid fill returns stock.
			return {"ok": true, "reason": "", "changed": changed}
		if existing.is_empty() and orders.size() >= MAX_ORDERS:
			return {"ok": true, "reason": "", "changed": changed}
		goods[good_id] = stock - quantity
		reserved = quantity
	var expires_utc: float = now_utc + MERCHANT_QUOTE_SECONDS
	if not is_finite(expires_utc):
		return {"ok": false, "reason": "invalid_time"}
	market.sequence = sequence
	# Reusing the id resets every field, so a filled or expired row becomes a
	# fresh quote on the same durable line and the row count never grows.
	orders[order_id] = {
		"id": order_id, "owner": MERCHANT, "side": side, "good": good_id,
		"price": price, "quantity": quantity, "remaining": quantity, "filled": 0,
		"reserved": reserved, "sequence": sequence, "created_utc": float(now_utc),
		"expires_utc": expires_utc, "status": STATUS_OPEN, "released": 0,
		"closed_by": "", "closed_utc": 0.0,
	}
	return {"ok": true, "reason": "", "changed": true}


## Expires one due merchant quote exactly like the public expiry sweep: escrow
## is released to the merchant and a balanced journal line records it.
static func _expire_merchant_quote(data: Dictionary, order: Dictionary, now_utc: float) -> Dictionary:
	var amount: int = int(order.reserved)
	var released: Dictionary = _release(data, order)
	if not released.ok:
		return {"ok": false, "reason": str(released.reason)}
	if str(order.side) == SIDE_BUY and amount > 0:
		var posted: Dictionary = _post(data, Ledger.KIND_ESCROW_RELEASE,
			MERCHANT_QUOTE_EVENT_PREFIX + "expire_" + str(order.id) + "_" \
				+ str(int(order.sequence)), now_utc, [
				Ledger.debit_line(Ledger.MERCHANT, amount),
				Ledger.credit_line(Ledger.ESCROW, amount),
			])
		if not posted.ok:
			return {"ok": false, "reason": str(posted.reason)}
	order.reserved = 0
	order.released = amount
	order.status = STATUS_EXPIRED
	order.closed_by = ""
	order.closed_utc = float(now_utc)
	return {"ok": true, "reason": ""}


static func _match_good(data: Dictionary, market: Dictionary, good_id: String,
		now_utc: float) -> Dictionary:
	var buys: Array = _eligible_orders(market, good_id, SIDE_BUY, now_utc)
	var sells: Array = _eligible_orders(market, good_id, SIDE_SELL, now_utc)
	var buy_index: int = 0
	var sell_index: int = 0
	var result_trades: Array = []
	var fee_total: int = 0
	var notional_total: int = 0
	while buy_index < buys.size() and sell_index < sells.size():
		var buy: Dictionary = buys[buy_index]
		var sell: Dictionary = sells[sell_index]
		if int(buy.price) < int(sell.price):
			break
		var quantity: int = mini(int(buy.remaining), int(sell.remaining))
		if quantity <= 0:
			break
		var executed: Dictionary = _execute_trade(data, market, buy, sell, quantity, now_utc)
		if not executed.ok:
			return match_error(str(executed.reason))
		var trade_row: Dictionary = executed.trade
		result_trades.append(trade_row.duplicate(true))
		fee_total += int(trade_row.fee)
		notional_total += int(trade_row.notional)
		# `quantity` is the smaller remaining, so each trade closes at least one
		# order. The other side may continue against the next level.
		if int(buy.remaining) == 0:
			buy_index += 1
		if int(sell.remaining) == 0:
			sell_index += 1
	return {
		"ok": true, "reason": "", "trades": result_trades,
		"fee": fee_total, "notional": notional_total,
	}


static func _eligible_orders(market: Dictionary, good_id: String, side: String,
		now_utc: float) -> Array:
	var result: Array = []
	for order_id: Variant in market.orders:
		var order: Variant = market.orders[order_id]
		if not order is Dictionary:
			continue
		if str(order.get("status", "")) != STATUS_OPEN or str(order.get("side", "")) != side:
			continue
		if str(order.get("good", "")) != good_id or int(order.get("remaining", 0)) <= 0:
			continue
		# A sweep cannot fill an order before it was accepted, and at or after
		# its own expiry boundary the order belongs to the expiry rule instead.
		if float(order.get("created_utc", 0.0)) > now_utc:
			continue
		if now_utc >= float(order.get("expires_utc", 0.0)):
			continue
		result.append(order)
	var comparator: Callable = _buy_before if side == SIDE_BUY else _sell_before
	result.sort_custom(comparator)
	return result


## Executes one fill between an eligible buy and sell. The maker (lower receive
## sequence) sets the unit price, so both sides settle on the same notional.
## The buy's escrow was the limit price; any difference is refunded. The seller
## receives the notional minus the fixed fee, and the fee is burned.
static func _execute_trade(data: Dictionary, market: Dictionary, buy: Dictionary,
		sell: Dictionary, quantity: int, now_utc: float) -> Dictionary:
	var buy_price: int = int(buy.price)
	var sell_price: int = int(sell.price)
	if buy_price < sell_price or quantity <= 0:
		return {"ok": false, "reason": "invalid_market"}
	var price: int = _maker_price(buy, sell)
	if price < sell_price or price > buy_price:
		return {"ok": false, "reason": "invalid_market"}
	var notional: int = price * quantity
	var refund: int = (buy_price - price) * quantity
	var fee: int = mini(TRADE_FEE, notional)
	var credit: int = notional - fee
	if not _is_count(notional) or not _is_count(refund) or not _is_count(credit):
		return {"ok": false, "reason": "invalid_amount"}
	if int(data.economy.issued) < fee:
		return {"ok": false, "reason": "invalid_market"}
	var good_id: String = str(buy.good)
	var buyer_goods: Dictionary = _ensure_goods(data, str(buy.owner))
	buyer_goods[good_id] = _amount(buyer_goods, good_id) + quantity
	if refund > 0:
		var refunded: Dictionary = _credit_cash(data, str(buy.owner), refund)
		if not refunded.ok:
			return {"ok": false, "reason": str(refunded.reason)}
	if credit > 0:
		var credited: Dictionary = _credit_cash(data, str(sell.owner), credit)
		if not credited.ok:
			return {"ok": false, "reason": str(credited.reason)}
	data.economy.issued = int(data.economy.issued) - fee
	buy.filled = int(buy.filled) + quantity
	buy.remaining = int(buy.remaining) - quantity
	buy.reserved = int(buy.remaining) * buy_price
	sell.filled = int(sell.filled) + quantity
	sell.remaining = int(sell.remaining) - quantity
	sell.reserved = int(sell.remaining)
	if int(buy.remaining) == 0:
		_close_filled(buy, now_utc)
	if int(sell.remaining) == 0:
		_close_filled(sell, now_utc)
	var trade_row: Dictionary = {
		"id": "", "sequence": 0, "good": good_id, "price": price,
		"quantity": quantity, "notional": notional, "fee": fee,
		"buy_id": str(buy.id), "sell_id": str(sell.id),
		"buy_owner": str(buy.owner), "sell_owner": str(sell.owner),
		"buy_price": buy_price, "sell_price": sell_price,
		"buy_refund": refund, "sell_credit": credit, "at_utc": now_utc,
	}
	_record_trade(market, trade_row)
	# One settlement entry moves the whole notional out of escrow: the buyer's
	# price improvement returns to its account, the seller receives the notional
	# less the fee, and the fee is the burn line. A self-trade with price
	# improvement touches the same account twice, and the journal accepts only
	# one line per account, so merge debits by account first. A zero net line
	# is omitted because Ledger rejects a line that is both zero debit and zero
	# credit. The escrow credit is the original buyer limit, so the merged
	# entries still balance.
	var debit_by_account: Dictionary = {}
	if refund > 0:
		var buyer_code: String = _ledger_code(str(buy.owner))
		debit_by_account[buyer_code] = int(debit_by_account.get(buyer_code, 0)) + refund
	if credit > 0:
		var seller_code: String = _ledger_code(str(sell.owner))
		debit_by_account[seller_code] = int(debit_by_account.get(seller_code, 0)) + credit
	if fee > 0:
		debit_by_account[Ledger.BURN] = int(debit_by_account.get(Ledger.BURN, 0)) + fee
	var escrow_credit: int = buy_price * quantity
	var lines: Array = []
	var debit_total: int = 0
	for account_code: Variant in debit_by_account:
		var debit_amount: int = int(debit_by_account[account_code])
		if debit_amount <= 0:
			continue
		lines.append(Ledger.debit_line(str(account_code), debit_amount))
		debit_total += debit_amount
	if debit_total != escrow_credit:
		return {"ok": false, "reason": "invalid_amount"}
	lines.append(Ledger.credit_line(Ledger.ESCROW, escrow_credit))
	var posted: Dictionary = _post(data, Ledger.KIND_TRADE, str(trade_row.id), now_utc, lines)
	if not posted.ok:
		return {"ok": false, "reason": str(posted.reason)}
	return {"ok": true, "reason": "", "trade": trade_row}


static func _record_trade(market: Dictionary, trade_row: Dictionary) -> void:
	var sequence: int = int(market.trade_sequence) + 1
	market.trade_sequence = sequence
	trade_row.sequence = sequence
	trade_row.id = TRADE_ID_PREFIX + str(sequence)
	market.trades[str(trade_row.id)] = trade_row
	while market.trades.size() > MAX_TRADES:
		# Evict the lowest trade sequence so the bound survives a JSON round
		# trip. Settlement idempotency does not depend on this log.
		var oldest_id: String = ""
		var oldest_sequence: int = MAX_SAFE_INTEGER + 1
		for candidate_id: Variant in market.trades:
			var candidate_sequence: int = int(market.trades[candidate_id].sequence)
			if candidate_sequence < oldest_sequence:
				oldest_sequence = candidate_sequence
				oldest_id = str(candidate_id)
		market.trades.erase(oldest_id)


## Evicts the earliest closed player order so the 256-row table can accept a new
## order in a long-lived world. Merchant quote rows are reused by the rolling
## rule and open rows still hold escrow, so neither is eligible. A closed order
## has already released everything it reserved; dropping the row therefore
## moves no cash or goods, it only drops audit evidence.
static func _archive_closed_order(market: Dictionary) -> bool:
	var oldest_id: String = ""
	var oldest_sequence: int = MAX_SAFE_INTEGER + 1
	for order_id: Variant in market.orders:
		var order: Variant = market.orders[order_id]
		if not order is Dictionary:
			continue
		if _is_merchant_quote_id(str(order_id)):
			continue
		if str(order.get("status", "")) == STATUS_OPEN:
			continue
		var sequence: int = int(order.get("sequence", 0))
		if sequence < oldest_sequence:
			oldest_sequence = sequence
			oldest_id = str(order_id)
	if oldest_id.is_empty():
		return false
	market.orders.erase(oldest_id)
	market.archived_orders = int(market.get("archived_orders", 0)) + 1
	return true


## Evicts the earliest terminal shipment (delivered or lost). In-transit rows
## own goods that have not reached a final state, so they are never eligible;
## delivery returned the quantity and a loss already destroyed it, so archiving
## either row moves nothing. The delivery or loss event stays as evidence.
static func _archive_terminal_shipment(market: Dictionary) -> bool:
	var oldest_id: String = ""
	var oldest_sequence: int = MAX_SAFE_INTEGER + 1
	for shipment_id: Variant in market.shipments:
		var shipment: Variant = market.shipments[shipment_id]
		if not shipment is Dictionary:
			continue
		if str(shipment.get("status", "")) not in [
				SHIPMENT_STATUS_DELIVERED, SHIPMENT_STATUS_LOST]:
			continue
		var sequence: int = int(shipment.get("sequence", 0))
		if sequence < oldest_sequence:
			oldest_sequence = sequence
			oldest_id = str(shipment_id)
	if oldest_id.is_empty():
		return false
	market.shipments.erase(oldest_id)
	market.archived_shipments = int(market.get("archived_shipments", 0)) + 1
	return true


## Evicts the oldest loss event. Every loss row is terminal: the destroyed goods
## and the cash position never depend on it. A still-present lost shipment then
## references a missing id, which `valid_losses` admits through `archived`.
static func _archive_loss(losses: Dictionary) -> bool:
	if not losses.get("events") is Dictionary:
		return false
	var events: Dictionary = losses.events
	var oldest_id: String = ""
	var oldest_sequence: int = MAX_SAFE_INTEGER + 1
	for loss_id: Variant in events:
		var event: Variant = events[loss_id]
		if not event is Dictionary:
			continue
		var sequence: int = int(event.get("sequence", 0))
		if sequence < oldest_sequence:
			oldest_sequence = sequence
			oldest_id = str(loss_id)
	if oldest_id.is_empty():
		return false
	events.erase(oldest_id)
	losses.archived = int(losses.get("archived", 0)) + 1
	return true


## Evicts the oldest delivery event. Unlike shipments there is no in-transit
## state to protect: a delivery row is written only after the goods returned to
## the owner, so archiving it moves nothing.
static func _archive_delivery(market: Dictionary) -> bool:
	var oldest_id: String = ""
	var oldest_sequence: int = MAX_SAFE_INTEGER + 1
	for delivery_id: Variant in market.deliveries:
		var delivery: Variant = market.deliveries[delivery_id]
		if not delivery is Dictionary:
			continue
		var sequence: int = int(delivery.get("sequence", 0))
		if sequence < oldest_sequence:
			oldest_sequence = sequence
			oldest_id = str(delivery_id)
	if oldest_id.is_empty():
		return false
	market.deliveries.erase(oldest_id)
	market.archived_deliveries = int(market.get("archived_deliveries", 0)) + 1
	return true


static func _trade_references_order(market: Dictionary, order_id: String) -> bool:
	var trades_value: Variant = market.get("trades")
	if not trades_value is Dictionary:
		return false
	for trade_value: Variant in trades_value.values():
		if trade_value is Dictionary and (str(trade_value.get("buy_id", "")) == order_id \
				or str(trade_value.get("sell_id", "")) == order_id):
			return true
	return false


## Only retained deliveries count. Once a delivery row is archived, it no longer
## reserves its shipment id; the missing-reference bounds in `valid()` keep the
## resulting holes from being forged.
static func _delivery_references_shipment(market: Dictionary, shipment_id: String) -> bool:
	var deliveries_value: Variant = market.get("deliveries")
	if not deliveries_value is Dictionary:
		return false
	for delivery_value: Variant in deliveries_value.values():
		if delivery_value is Dictionary \
				and str(delivery_value.get("shipment_id", "")) == shipment_id:
			return true
	return false


## Only retained loss events count. Once a loss row is archived, it no longer
## reserves its shipment id; `valid_losses` bounds the resulting holes with
## `losses.archived`.
static func _loss_references_shipment(data: Dictionary, shipment_id: String) -> bool:
	if not data.get("economy") is Dictionary:
		return false
	var losses_value: Variant = data.economy.get("losses")
	if not losses_value is Dictionary or not losses_value.get("events") is Dictionary:
		return false
	for event_value: Variant in losses_value.events.values():
		if event_value is Dictionary \
				and str(event_value.get("shipment_id", "")) == shipment_id:
			return true
	return false


static func _close_filled(order: Dictionary, now_utc: float) -> void:
	order.status = STATUS_FILLED
	order.reserved = 0
	order.released = 0
	order.closed_by = ""
	order.closed_utc = now_utc


static func _maker_price(buy: Dictionary, sell: Dictionary) -> int:
	if int(buy.sequence) != int(sell.sequence):
		return int(buy.price) if int(buy.sequence) < int(sell.sequence) else int(sell.price)
	return int(buy.price) if str(buy.id) < str(sell.id) else int(sell.price)


static func _credit_cash(data: Dictionary, owner: String, amount: int) -> Dictionary:
	if amount <= 0:
		return {"ok": true}
	if owner == MERCHANT:
		var market: Dictionary = _market(data)
		if market.is_empty() or not market.merchant is Dictionary:
			return {"ok": false, "reason": "invalid_market"}
		market.merchant.cash = int(market.merchant.cash) + amount
		return {"ok": true}
	var accounts: Variant = data.economy.get("accounts")
	if not accounts is Dictionary:
		return {"ok": false, "reason": "invalid_market"}
	if not accounts.get(owner) is Dictionary:
		# Selling does not require an opened account. Proceeds create a
		# granted=false account; opening later still grants the one-time amount.
		accounts[owner] = {"cash": 0, "granted": false}
	accounts[owner].cash = int(accounts[owner].cash) + amount
	return {"ok": true}


static func _buy_before(a: Variant, b: Variant) -> bool:
	var left: Dictionary = a
	var right: Dictionary = b
	if int(left.price) != int(right.price):
		return int(left.price) > int(right.price)
	return _order_before(left, right)


static func _sell_before(a: Variant, b: Variant) -> bool:
	var left: Dictionary = a
	var right: Dictionary = b
	if int(left.price) != int(right.price):
		return int(left.price) < int(right.price)
	return _order_before(left, right)


static func _trade_before(a: Variant, b: Variant) -> bool:
	var left: Dictionary = a
	var right: Dictionary = b
	return int(left.sequence) < int(right.sequence)


static func _valid_trade(trade_id: Variant, value: Variant, market_trade_sequence: int) -> bool:
	if not value is Dictionary or value.size() != TRADE_KEYS.size():
		return false
	for key: String in TRADE_KEYS:
		if not value.has(key):
			return false
	if not _is_positive_count(value.sequence):
		return false
	var sequence: int = int(value.sequence)
	if sequence > market_trade_sequence:
		return false
	if not value.id is String or str(value.id) != str(trade_id):
		return false
	if str(value.id) != TRADE_ID_PREFIX + str(sequence):
		return false
	if not Catalog.is_good(value.good):
		return false
	for key: String in ["price", "quantity", "notional", "fee", "buy_price", "sell_price",
			"buy_refund", "sell_credit"]:
		if not _is_count(value.get(key)):
			return false
	var price: int = int(value.price)
	var quantity: int = int(value.quantity)
	var notional: int = int(value.notional)
	var fee: int = int(value.fee)
	if price <= 0 or price > MAX_PRICE or quantity <= 0 or quantity > MAX_QUANTITY:
		return false
	if int(value.buy_price) <= 0 or int(value.buy_price) > MAX_PRICE \
			or int(value.sell_price) <= 0 or int(value.sell_price) > MAX_PRICE:
		return false
	if notional != price * quantity or notional > MAX_SAFE_INTEGER:
		return false
	if price < int(value.sell_price) or price > int(value.buy_price):
		return false
	if price != int(value.buy_price) and price != int(value.sell_price):
		return false
	if fee > notional or fee != mini(TRADE_FEE, notional) \
			or int(value.sell_credit) != notional - fee:
		return false
	if int(value.buy_refund) != (int(value.buy_price) - price) * quantity:
		return false
	if not valid_command_id(value.buy_id) or not valid_command_id(value.sell_id):
		return false
	if str(value.buy_id) == str(value.sell_id):
		return false
	if not valid_owner(value.buy_owner) or not valid_owner(value.sell_owner):
		return false
	if not _valid_time(value.at_utc):
		return false
	return true


## A shipment written before declared risk has no risk/lost fields. It reads as
## the safe route with no loss and gains the canonical keys on restore; this is
## the same optional-field reading the merchant `granted` record uses, not a
## migration file. When the fields are present they are strict.
static func _valid_shipment(shipment_id: Variant, value: Variant, market_sequence: int) -> bool:
	if not value is Dictionary:
		return false
	var legacy_risk: bool = not value.has("risk") and not value.has("lost_utc") \
		and not value.has("loss_id")
	var expected_size: int = SHIPMENT_KEYS.size() - (3 if legacy_risk else 0)
	if value.size() != expected_size:
		return false
	for key: String in SHIPMENT_KEYS:
		if legacy_risk and key in ["risk", "lost_utc", "loss_id"]:
			continue
		if not value.has(key):
			return false
	if legacy_risk and str(value.status) not in [
			SHIPMENT_STATUS_TRANSIT, SHIPMENT_STATUS_DELIVERED]:
		return false
	if not valid_command_id(shipment_id) or str(value.id) != str(shipment_id):
		return false
	# `valid_owner` includes the rule merchant; shipments are player-only.
	if not OwnerIds.valid(value.owner) or not Catalog.is_good(value.good):
		return false
	if not valid_route(str(value.origin), str(value.destination)):
		return false
	if not _is_positive_count(value.quantity) or int(value.quantity) > MAX_QUANTITY:
		return false
	if not _is_count(value.sequence) or int(value.sequence) <= 0 or int(value.sequence) > market_sequence:
		return false
	if not _is_count(value.fee) or int(value.fee) != SHIPMENT_FEE:
		return false
	if not _valid_time(value.depart_utc) or not _valid_time(value.arrive_utc):
		return false
	if not is_equal_approx(float(value.arrive_utc) - float(value.depart_utc), DELIVERY_SECONDS):
		return false
	if not value.delivery_id is String or str(value.status) not in SHIPMENT_STATUSES:
		return false
	# A legacy row has no risk fields at all; its only possible reading is the
	# safe route that never reached the lost state.
	var risk: String = SHIPMENT_RISK_SAFE if legacy_risk else str(value.risk)
	var lost_utc: float = 0.0 if legacy_risk else float(value.lost_utc)
	var loss_id: String = "" if legacy_risk else str(value.loss_id)
	if (not legacy_risk and not value.risk is String) or risk not in SHIPMENT_RISKS:
		return false
	if (not legacy_risk and not value.lost_utc is int and not value.lost_utc is float) \
			or not _valid_time(lost_utc):
		return false
	if (not legacy_risk and not value.loss_id is String) \
			or not _valid_time(value.delivered_utc):
		return false
	if str(value.status) == SHIPMENT_STATUS_TRANSIT:
		return float(value.delivered_utc) == 0.0 and str(value.delivery_id).is_empty() \
			and lost_utc == 0.0 and loss_id.is_empty()
	if str(value.status) == SHIPMENT_STATUS_LOST:
		# A loss only exists for an explicitly declared risk and is stamped at
		# the end of the cause window, never at the observation instant.
		if risk != SHIPMENT_RISK_DECLARED \
				or not str(value.delivery_id).is_empty() \
				or float(value.delivered_utc) != 0.0 \
				or not is_equal_approx(lost_utc, float(value.arrive_utc)) \
				or not loss_id.begins_with(LOSS_ID_PREFIX):
			return false
		return true
	if float(value.delivered_utc) < float(value.depart_utc):
		return false
	if lost_utc != 0.0 or not loss_id.is_empty():
		return false
	# The exact delivery link is checked against the delivery table after both
	# tables are validated.
	return str(value.delivery_id).begins_with(DELIVERY_ID_PREFIX)


static func _valid_delivery(delivery_id: Variant, value: Variant, market_sequence: int) -> bool:
	if not value is Dictionary or value.size() != DELIVERY_KEYS.size():
		return false
	for key: String in DELIVERY_KEYS:
		if not value.has(key):
			return false
	if not _is_count(value.sequence) or int(value.sequence) <= 0 or int(value.sequence) > market_sequence:
		return false
	var sequence: int = int(value.sequence)
	if not value.id is String or str(value.id) != str(delivery_id):
		return false
	if str(value.id) != DELIVERY_ID_PREFIX + str(sequence):
		return false
	if not valid_command_id(value.shipment_id):
		return false
	if not OwnerIds.valid(value.owner) or not Catalog.is_good(value.good):
		return false
	if not _is_positive_count(value.quantity) or int(value.quantity) > MAX_QUANTITY:
		return false
	if not valid_route(str(value.origin), str(value.destination)):
		return false
	return _valid_time(value.at_utc)


## Validates `economy.losses` and its two-way link with the shipment table. A
## pre-M8-03 economy has no loss key and is admitted only while no shipment
## claims the terminal `lost` state, so a crafted loss cannot appear without its
## evidence table. Present rows are cross-checked field by field; a missing row
## is admitted through the matching event and bounded by the archive counters,
## exactly like trades/deliveries above.
static func valid_losses(economy: Dictionary) -> bool:
	var market_value: Variant = economy.get("market")
	var market: Dictionary = market_value if market_value is Dictionary else {}
	if not economy.has("losses"):
		if market.get("shipments") is Dictionary:
			for shipment_value: Variant in market.shipments.values():
				if shipment_value is Dictionary \
						and str(shipment_value.get("status", "")) == SHIPMENT_STATUS_LOST:
					return false
		return true
	var losses_value: Variant = economy.losses
	if not losses_value is Dictionary:
		return false
	var losses: Dictionary = losses_value
	if losses.size() != LOSSES_KEYS.size():
		return false
	for key: String in LOSSES_KEYS:
		if not losses.has(key):
			return false
	if not _is_count(losses.sequence) or int(losses.sequence) >= MAX_SAFE_INTEGER:
		return false
	if not _is_count(losses.archived) or int(losses.archived) > int(losses.sequence):
		return false
	if not losses.events is Dictionary or losses.events.size() > MAX_LOSSES:
		return false
	var events: Dictionary = losses.events
	# Every generated loss consumes one sequence and is either live or archived,
	# so the counts are exact. That keeps a crafted event or archive count from
	# hiding a fabricated loss.
	if events.size() + int(losses.archived) != int(losses.sequence):
		return false
	var event_by_shipment: Dictionary = {}
	for loss_id: Variant in events:
		var event_value: Variant = events[loss_id]
		if not _valid_loss_event(loss_id, event_value, int(losses.sequence)):
			return false
		var event: Dictionary = event_value
		var shipment_id: String = str(event.shipment_id)
		if event_by_shipment.has(shipment_id):
			# One shipment produces at most one loss event.
			return false
		event_by_shipment[shipment_id] = event
	if not market.get("shipments") is Dictionary:
		# Without a market no shipment can explain a loss event.
		return events.is_empty() and int(losses.sequence) == 0 and int(losses.archived) == 0
	var shipments: Dictionary = market.shipments
	var missing_loss_ids: Dictionary = {}
	for shipment_id: Variant in shipments:
		var row: Variant = shipments[shipment_id]
		if not row is Dictionary or str(row.get("status", "")) != SHIPMENT_STATUS_LOST:
			continue
		var loss_id: String = str(row.get("loss_id", ""))
		var linked: Variant = events.get(loss_id)
		if linked is Dictionary:
			if not _loss_matches_shipment(linked, row):
				return false
		else:
			if missing_loss_ids.has(loss_id):
				return false
			missing_loss_ids[loss_id] = true
	var missing_shipment_ids: Dictionary = {}
	for shipment_id: Variant in event_by_shipment:
		var event: Dictionary = event_by_shipment[shipment_id]
		var row_value: Variant = shipments.get(shipment_id)
		if row_value is Dictionary:
			if str(row_value.get("status", "")) != SHIPMENT_STATUS_LOST \
					or not _loss_matches_shipment(event, row_value):
				return false
		else:
			missing_shipment_ids[str(shipment_id)] = true
	if missing_loss_ids.size() > int(losses.archived):
		return false
	# A lost shipment row can itself be archived. Its loss event then remains the
	# evidence; the archived-shipment counter bounds every missing terminal row,
	# delivered or lost. Count the union of both evidence kinds so a crafted
	# document cannot hide one extra hole behind two separate budgets.
	var terminal_holes: Dictionary = missing_shipment_ids.duplicate()
	if market.get("deliveries") is Dictionary:
		for delivery_value: Variant in market.deliveries.values():
			if delivery_value is Dictionary \
					and not shipments.has(str(delivery_value.get("shipment_id", ""))):
				terminal_holes[str(delivery_value.get("shipment_id", ""))] = true
	return terminal_holes.size() <= int(market.get("archived_shipments", 0))


static func _valid_loss_event(loss_id: Variant, value: Variant, loss_sequence: int) -> bool:
	if not value is Dictionary or value.size() != LOSS_EVENT_KEYS.size():
		return false
	for key: String in LOSS_EVENT_KEYS:
		if not value.has(key):
			return false
	if not _is_positive_count(value.sequence) or int(value.sequence) > loss_sequence:
		return false
	if not value.id is String or str(value.id) != str(loss_id):
		return false
	if str(value.id) != LOSS_ID_PREFIX + str(int(value.sequence)):
		return false
	if str(value.kind) != TRANSPORT_LOSS_KIND:
		return false
	if not _valid_time(value.at_utc) or not _valid_time(value.cause_start_utc) \
			or not _valid_time(value.cause_end_utc):
		return false
	if not is_equal_approx(float(value.cause_end_utc) - float(value.cause_start_utc),
			DELIVERY_SECONDS):
		return false
	if not is_equal_approx(float(value.at_utc), float(value.cause_end_utc)):
		return false
	if not OwnerIds.valid(value.victim) or not valid_command_id(value.shipment_id):
		return false
	if not Catalog.is_good(value.good):
		return false
	if not _is_positive_count(value.quantity) or int(value.quantity) > MAX_QUANTITY:
		return false
	if not _is_positive_count(value.unit_value) \
			or int(value.unit_value) != Catalog.base_price(str(value.good)):
		return false
	if not _is_count(value.value) or int(value.value) != int(value.unit_value) * int(value.quantity):
		return false
	if not _is_count(value.rule_version) or int(value.rule_version) != TRANSPORT_LOSS_RULE_VERSION:
		return false
	return true


## Fields a loss event shares with the shipment row it settles. The loss value
## is derived from the catalog reference price at settlement, not from a
## player-supplied number.
static func _loss_matches_shipment(event: Dictionary, shipment: Dictionary) -> bool:
	if str(shipment.get("status", "")) != SHIPMENT_STATUS_LOST:
		return false
	if str(event.id) != str(shipment.get("loss_id", "")):
		return false
	if str(event.shipment_id) != str(shipment.get("id", "")):
		return false
	if str(event.victim) != str(shipment.get("owner", "")):
		return false
	if str(event.good) != str(shipment.get("good", "")) \
			or int(event.quantity) != int(shipment.get("quantity", 0)):
		return false
	if not is_equal_approx(float(event.cause_start_utc), float(shipment.get("depart_utc", 0.0))) \
			or not is_equal_approx(float(event.cause_end_utc), float(shipment.get("arrive_utc", 0.0))) \
			or not is_equal_approx(float(event.at_utc), float(shipment.get("arrive_utc", 0.0))):
		return false
	return true


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
	if kind == "market_open_merchant":
		# The durable merchant row is the evidence; a ledger entry without it is
		# not a valid retry. The opening result always reports the budget.
		if market is Dictionary and market.get("merchant") is Dictionary \
				and bool(market.merchant.get("opened", false)):
			return {
				"ok": true, "reason": "", "duplicate": true,
				"amount": int(ledger.get("amount", MERCHANT_BUDGET)),
				"budget": MERCHANT_BUDGET,
			}
		return error("unknown_merchant")
	if market is Dictionary and market.get("orders") is Dictionary:
		if kind == "market_place":
			if not market.orders.get(command_id) is Dictionary:
				# A forged or evicted ledger row cannot claim an order exists.
				return error("unknown_order")
			var placed: Dictionary = _order_result(market.orders[command_id], true)
			placed.amount = int(ledger.get("amount", placed.amount))
			return placed
		if kind == "market_ship":
			if not market.get("shipments") is Dictionary \
					or not market.shipments.get(command_id) is Dictionary:
				return error("unknown_shipment")
			var shipped: Dictionary = _shipment_result(market.shipments[command_id], true)
			shipped.amount = int(ledger.get("amount", shipped.amount))
			return shipped
		if kind == "market_cancel":
			var ids: Array = market.orders.keys()
			ids.sort()
			for order_id: Variant in ids:
				var order: Dictionary = market.orders[order_id]
				if str(order.closed_by) == command_id:
					return _cancel_result(order, true)
			return error("order_closed")
	elif kind in ["market_place", "market_ship", "market_cancel"]:
		return error("invalid_market")
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
		"quantity": 0, "remaining": 0, "reserved": 0, "filled": 0,
		"status": "", "sequence": 0,
	}


static func _is_merchant_quote_id(value: String) -> bool:
	return value.begins_with(MERCHANT_BID_PREFIX) or value.begins_with(MERCHANT_ASK_PREFIX)


static func _ledger_code(owner: String) -> String:
	return Ledger.MERCHANT if owner == MERCHANT else Ledger.owner_code(owner)


static func _post(data: Dictionary, kind: String, event_id: String, at_utc: float,
		lines: Array) -> Dictionary:
	if not data.get("economy") is Dictionary or not data.economy.get("ledger") is Dictionary:
		return {"ok": false, "reason": "invalid_ledger", "id": "", "sequence": 0}
	return Ledger.post(data.economy.ledger, kind, event_id, at_utc, lines)


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
		"filled": int(order.filled), "status": str(order.status), "sequence": int(order.sequence),
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
	if not value is Dictionary:
		return false
	# A market written before the merchant stock grant has no `granted` field.
	# Validation stays pure here: it must not write the zero field, because the
	# missing key is the durable marker the first sweep uses to grant the
	# one-time stock exactly once. When the field is present it is strict.
	var legacy_granted: bool = not value.has("granted")
	var expected_size: int = MERCHANT_KEYS.size() - (1 if legacy_granted else 0)
	if value.size() != expected_size:
		return false
	for key: String in MERCHANT_KEYS:
		if key == "granted" and legacy_granted:
			continue
		if not value.has(key):
			return false
	if not value.opened is bool or not value.opened_by is String:
		return false
	# The opening instant comes from the live clock, which is fractional. It is a
	# timestamp, not a count: requiring an integer here made a freshly opened
	# merchant serialize into a document the loader then rejected, so the save
	# succeeded and the next launch demanded recovery.
	if not _valid_time(value.opened_utc) or not _is_count(value.cash):
		return false
	if bool(value.opened):
		if not valid_command_id(value.opened_by):
			return false
	else:
		if not str(value.opened_by).is_empty() or float(value.opened_utc) != 0.0 \
				or int(value.cash) != 0:
			return false
	if not value.goods is Dictionary or value.goods.size() != Catalog.goods_ids().size():
		return false
	for good_id: String in Catalog.goods_ids():
		if not _is_count(value.goods.get(good_id)):
			return false
		value.goods[good_id] = int(value.goods[good_id])
	var granted: Dictionary = {}
	if not legacy_granted:
		if not value.granted is Dictionary \
				or value.granted.size() != Catalog.goods_ids().size():
			return false
		for good_id: String in Catalog.goods_ids():
			if not _is_count(value.granted.get(good_id)):
				return false
			# JSON stores every parsed number as a float; canonicalize this new
			# field here because the farm normalizer predates it.
			value.granted[good_id] = int(value.granted[good_id])
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


## FNV-1a over the exact strings. Godot's int is 64-bit, so the product stays
## exact before masking back to 32 bits; the same rule runs on every platform
## and after a JSON round trip.
static func _fnv1a(parts: Array) -> int:
	var hash: int = 2166136261
	for part: Variant in parts:
		var text: String = str(part)
		for index: int in text.length():
			hash = hash ^ text.unicode_at(index)
			hash = (hash * 16777619) & 0xFFFFFFFF
	return hash


static func _is_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)


static func _is_positive_count(value: Variant) -> bool:
	return _is_count(value) and float(value) > 0.0


static func _valid_time(value: Variant) -> bool:
	# Same bound as FarmState: JSON numbers are exact only up to 2^53-1, and a
	# timestamp beyond the real domain silently never expires or never arrives.
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) >= 0.0 and float(value) <= float(MAX_SAFE_INTEGER)


static func _amount(goods: Dictionary, good_id: String) -> int:
	var amount: Variant = goods.get(good_id, 0)
	return int(amount) if (amount is int or amount is float) else 0
