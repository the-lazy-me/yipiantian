extends RefCounted
## M7-01 commodity set. Pure data: no state, clock, I/O or market behaviour.
##
## The first six are ground-bed crops with a real harvest source and a current
## kitchen or animal eat route. Seeds are absent because the demo hands them out
## without a finite source; building materials are absent because housing has no
## material ledger yet (ADR-006). Luffa is the only trellis crop and has no
## kitchen or animal route, so it stays out of the first price surface. `sell`
## is the M7-02 market sink; it is declared now so the catalog does not need a
## second shape when quotes arrive.

const CURRENCY: String = "COIN"
const SOURCE_GROW: String = "grow"
const SINK_EAT: String = "eat"
const SINK_SELL: String = "sell"
## The six goods cover the four crop groups and the shortest-to-longest growth
## ranges. The other seven crops still feed the kitchen, animals and neighbours;
## they are simply not priced in the first market slice.
const GOODS := {
	"greens": {"name": "青菜", "group": "leaf", "source": SOURCE_GROW, "sinks": [SINK_EAT, SINK_SELL], "base_price": 6},
	"spinach": {"name": "菠菜", "group": "leaf", "source": SOURCE_GROW, "sinks": [SINK_EAT, SINK_SELL], "base_price": 9},
	"radish": {"name": "白萝卜", "group": "root", "source": SOURCE_GROW, "sinks": [SINK_EAT, SINK_SELL], "base_price": 18},
	"carrot": {"name": "胡萝卜", "group": "root", "source": SOURCE_GROW, "sinks": [SINK_EAT, SINK_SELL], "base_price": 24},
	"celery": {"name": "芹菜", "group": "stem", "source": SOURCE_GROW, "sinks": [SINK_EAT, SINK_SELL], "base_price": 20},
	"garlic": {"name": "青蒜", "group": "aromatic", "source": SOURCE_GROW, "sinks": [SINK_EAT, SINK_SELL], "base_price": 14},
}


static func goods_ids() -> Array[String]:
	# Dictionary insertion order is stable and is the catalog's display order.
	var result: Array[String] = []
	result.assign(GOODS.keys())
	return result


static func is_good(good_id: Variant) -> bool:
	return good_id is String and GOODS.has(good_id)


static func definition(good_id: String) -> Dictionary:
	# Unknown ids return an empty definition, like the crop catalog. A deep copy
	# keeps callers from editing the shared data through a view.
	var good: Variant = GOODS.get(good_id)
	return good.duplicate(true) if good is Dictionary else {}


static func base_price(good_id: String) -> int:
	var good: Variant = GOODS.get(good_id)
	return int(good.base_price) if good is Dictionary else 0
