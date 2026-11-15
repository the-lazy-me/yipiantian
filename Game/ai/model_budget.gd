extends RefCounted
## M9-04 cloud model budget. Pure rules: no system clock, disk, network or RNG.
## Every time and every cost is injected by the caller, so the same command
## sequence always produces the same document.
##
## The caller decides the cost unit. This slice only requires it to be a
## non-negative safe integer. A request is authorized against an estimate,
## settled with real usage, and only an `ok` outcome is charged. Cloud access
## is off by default, matching the "cloud off unless the player opts in" rule.
##
## State shape:
##   {
##     "config": {
##       "enabled": false,            # cloud authorization switch
##       "period_seconds": 86400,     # budget period length
##       "hard_limit": 1000,          # cost cap per period
##       "request_limit": 100,        # cap for one request's estimate
##       "concurrency_limit": 2,      # unsettled reservations
##     },
##     "used": {
##       "period_start_utc": 0.0,     # start of the current budget period
##       "cost": 0,                   # settled charges in this period
##     },
##     "reservations": {              # bounded by concurrency_limit
##       "<request_id>": {
##         "estimate": 10,
##         "period_start_utc": 0.0,   # period the reservation belongs to
##         "created_utc": 1.0,
##       },
##     },
##     "settled": {                   # bounded replay window, oldest evicted
##       "<request_id>": {
##         "estimate": 10,
##         "outcome": "ok",
##         "actual_usage": 0,
##         "actual_cost": 7,
##         "charged": 7,              # 0 unless outcome is "ok"
##         "at_utc": 2.0,
##       },
##     },
##     "events": [                    # bounded tail, oldest evicted
##       {"at_utc": 2.0, "kind": "settle", "request_id": "<id>",
##        "reason": "", "amount": 7},
##     ],
##     "total_cost": 0,               # all settled charges, across periods
##   }
##
## Rejection reasons are stable strings:
##   invalid_state, invalid_request, invalid_time, invalid_estimate,
##   invalid_outcome, invalid_usage, cloud_disabled, over_request_cap,
##   over_budget, over_concurrency, period_elapsed, command_conflict,
##   unknown_request.
##
## Rejections never modify the input. Successful calls return a new document
## under `state`; the input document is never mutated.

const MAX_SAFE_INTEGER: int = 9007199254740991
## A budget period is a bounded experiment value, not an epoch-sized span.
const MAX_PERIOD_SECONDS: int = 31536000
const MAX_CONCURRENCY_LIMIT: int = 64
const MAX_SETTLED: int = 256
const MAX_EVENTS: int = 256
const SNAPSHOT_EVENTS: int = 16
const MAX_REQUEST_ID_LENGTH: int = 128
const MAX_REASON_LENGTH: int = 64

const DEFAULT_PERIOD_SECONDS: int = 86400
const DEFAULT_HARD_LIMIT: int = 1000
const DEFAULT_REQUEST_LIMIT: int = 100
const DEFAULT_CONCURRENCY_LIMIT: int = 2

const OUTCOME_OK: String = "ok"
const OUTCOME_FAILED: String = "failed"
const OUTCOME_TIMEOUT: String = "timeout"
const OUTCOME_OFFLINE: String = "offline"
const OUTCOME_CANCELLED: String = "cancelled"
const OUTCOMES: Array[String] = [
	OUTCOME_OK, OUTCOME_FAILED, OUTCOME_TIMEOUT, OUTCOME_OFFLINE, OUTCOME_CANCELLED,
]

const EVENT_AUTHORIZE: String = "authorize"
const EVENT_SETTLE: String = "settle"
const EVENT_ROLLOVER: String = "rollover"
const EVENT_KINDS: Array[String] = [EVENT_AUTHORIZE, EVENT_SETTLE, EVENT_ROLLOVER]

const STATE_KEYS: Array[String] = [
	"config", "used", "reservations", "settled", "events", "total_cost",
]
const CONFIG_KEYS: Array[String] = [
	"enabled", "period_seconds", "hard_limit", "request_limit",
	"concurrency_limit",
]
const USED_KEYS: Array[String] = ["period_start_utc", "cost"]
const RESERVATION_KEYS: Array[String] = [
	"estimate", "period_start_utc", "created_utc",
]
const SETTLED_KEYS: Array[String] = [
	"estimate", "outcome", "actual_usage", "actual_cost", "charged", "at_utc",
]
const EVENT_KEYS: Array[String] = [
	"at_utc", "kind", "request_id", "reason", "amount",
]
const OPTION_KEYS: Array[String] = [
	"enabled", "period_seconds", "hard_limit", "request_limit",
	"concurrency_limit", "period_start_utc",
]


## Builds the initial document. Missing options keep the defaults; an unknown or
## malformed option returns `{}` (fail closed) rather than a partially applied
## configuration.
static func initial_state(options: Dictionary = {}) -> Dictionary:
	var config: Dictionary = {
		"enabled": false,
		"period_seconds": DEFAULT_PERIOD_SECONDS,
		"hard_limit": DEFAULT_HARD_LIMIT,
		"request_limit": DEFAULT_REQUEST_LIMIT,
		"concurrency_limit": DEFAULT_CONCURRENCY_LIMIT,
	}
	var period_start: Variant = 0.0
	for key: Variant in options:
		if not key is String:
			return {}
		var name: String = str(key)
		if name == "period_start_utc":
			period_start = options[key]
			continue
		if not config.has(name):
			return {}
		config[name] = options[name]
	if not _valid_config(config) or not valid_time(period_start):
		return {}
	config["period_seconds"] = int(config.period_seconds)
	config["hard_limit"] = int(config.hard_limit)
	config["request_limit"] = int(config.request_limit)
	config["concurrency_limit"] = int(config.concurrency_limit)
	return {
		"config": config,
		"used": {"period_start_utc": float(period_start), "cost": 0},
		"reservations": {},
		"settled": {},
		"events": [],
		"total_cost": 0,
	}


## Reserves budget for one cloud call. The estimate is charged only as a hold:
## it reduces the room left for later requests until `settle` records the real
## outcome. `period_elapsed` asks the caller to roll over first so a reservation
## is always attributed to the period it was really created in.
static func authorize(state: Dictionary, request_id: Variant, estimate: Variant,
		now_utc: float) -> Dictionary:
	if not valid(state):
		return _authorize_error("invalid_state", request_id)
	if not _valid_request_id(request_id):
		return _authorize_error("invalid_request", request_id)
	var rid: String = str(request_id)
	if not valid_time(now_utc):
		return _authorize_error("invalid_time", rid)
	if not _valid_estimate(estimate):
		return _authorize_error("invalid_estimate", rid)
	var est: int = int(estimate)
	# Replays resolve before authorization gates so a retried id stays
	# idempotent even if the budget or the cloud switch changed meanwhile.
	var settled_rows: Dictionary = state.settled
	if settled_rows.has(rid):
		var row: Dictionary = settled_rows[rid]
		if int(row.estimate) != est:
			return _authorize_error("command_conflict", rid)
		return _authorize_success(rid, int(row.estimate), true)
	var reservations: Dictionary = state.reservations
	if reservations.has(rid):
		var held: Dictionary = reservations[rid]
		if int(held.estimate) != est:
			return _authorize_error("command_conflict", rid)
		return _authorize_success(rid, int(held.estimate), true)
	var config: Dictionary = state.config
	if not bool(config.enabled):
		return _authorize_error("cloud_disabled", rid)
	var used: Dictionary = state.used
	var period_start: float = float(used.period_start_utc)
	var period_end: float = period_start + float(int(config.period_seconds))
	if now_utc < period_start:
		return _authorize_error("invalid_time", rid)
	if now_utc >= period_end:
		return _authorize_error("period_elapsed", rid)
	var request_limit: int = int(config.request_limit)
	if est > request_limit:
		return _authorize_error("over_request_cap", rid)
	var used_cost: int = int(used.cost)
	var reserved: int = _reserved_total(state)
	if used_cost + reserved + est > int(config.hard_limit):
		return _authorize_error("over_budget", rid)
	if reservations.size() >= int(config.concurrency_limit):
		return _authorize_error("over_concurrency", rid)
	var candidate: Dictionary = state.duplicate(true)
	var candidate_reservations: Dictionary = candidate["reservations"]
	candidate_reservations[rid] = {
		"estimate": est,
		"period_start_utc": period_start,
		"created_utc": now_utc,
	}
	_append_event(candidate, now_utc, EVENT_AUTHORIZE, rid, "", est)
	return _authorize_success(rid, est, false, candidate)


## Records the real outcome of an authorized call. Only `ok` charges the
## reported cost; every other outcome releases the hold and charges 0, while the
## reported cost stays in the settled row as reconciliation evidence. A replay
## of an already settled id returns the first result and never charges twice.
static func settle(state: Dictionary, request_id: Variant, actual_usage: Variant,
		actual_cost: Variant, outcome: Variant, now_utc: float) -> Dictionary:
	if not valid(state):
		return _settle_error("invalid_state", request_id, outcome)
	if not _valid_request_id(request_id):
		return _settle_error("invalid_request", request_id, outcome)
	var rid: String = str(request_id)
	if not valid_time(now_utc):
		return _settle_error("invalid_time", rid, outcome)
	if not _valid_outcome(outcome):
		return _settle_error("invalid_outcome", rid, outcome)
	var kind: String = str(outcome)
	if not _is_count(actual_usage) or not _is_count(actual_cost):
		return _settle_error("invalid_usage", rid, kind)
	var usage: int = int(actual_usage)
	var cost: int = int(actual_cost)
	var settled_rows: Dictionary = state.settled
	if settled_rows.has(rid):
		var first: Dictionary = settled_rows[rid]
		return {
			"ok": true, "reason": "", "request_id": rid,
			"outcome": str(first.outcome),
			"actual_usage": int(first.actual_usage),
			"actual_cost": int(first.actual_cost),
			"charged": int(first.charged),
			"duplicate": true,
		}
	var reservations: Dictionary = state.reservations
	if not reservations.has(rid):
		return _settle_error("unknown_request", rid, kind)
	var held: Dictionary = reservations[rid]
	if now_utc < float(held.created_utc):
		return _settle_error("invalid_time", rid, kind)
	# "This period" is the document's current period, so a late completion must
	# roll over first rather than charge a period that is already closed.
	var used: Dictionary = state.used
	var period_end: float = float(used.period_start_utc) \
		+ float(int(state.config.period_seconds))
	if now_utc >= period_end:
		return _settle_error("period_elapsed", rid, kind)
	var charged: int = cost if kind == OUTCOME_OK else 0
	if int(used.cost) + charged > MAX_SAFE_INTEGER \
			or int(state.total_cost) + charged > MAX_SAFE_INTEGER:
		return _settle_error("invalid_usage", rid, kind)
	var candidate: Dictionary = state.duplicate(true)
	var candidate_reservations: Dictionary = candidate["reservations"]
	candidate_reservations.erase(rid)
	var candidate_settled: Dictionary = candidate["settled"]
	candidate_settled[rid] = {
		"estimate": int(held.estimate),
		"outcome": kind,
		"actual_usage": usage,
		"actual_cost": cost,
		"charged": charged,
		"at_utc": now_utc,
	}
	var candidate_used: Dictionary = candidate["used"]
	candidate_used["cost"] = int(candidate_used["cost"]) + charged
	candidate["total_cost"] = int(candidate["total_cost"]) + charged
	_append_event(candidate, now_utc, EVENT_SETTLE, rid, "", charged)
	_evict_settled(candidate)
	return {
		"ok": true, "reason": "", "request_id": rid, "outcome": kind,
		"actual_usage": usage, "actual_cost": cost, "charged": charged,
		"duplicate": false, "state": candidate,
	}


## Advances the budget period(s) that `now_utc` has reached. Settled cost is
## zeroed; unsettled reservations survive with their own `period_start_utc` and
## keep occupying the new period's room, so a rollover cannot be used to run
## more concurrent work than the cap allows.
static func rollover(state: Dictionary, now_utc: float) -> Dictionary:
	if not valid(state):
		return _rollover_error("invalid_state", 0.0)
	if not valid_time(now_utc):
		return _rollover_error("invalid_time", 0.0)
	var used: Dictionary = state.used
	var start: float = float(used.period_start_utc)
	if now_utc < start:
		return _rollover_error("invalid_time", start)
	var period: int = int(state.config.period_seconds)
	var steps: int = int(floorf((now_utc - start) / float(period)))
	if steps <= 0:
		return {"ok": true, "reason": "", "periods": 0, "period_start_utc": start}
	# floor(elapsed / period) * period can never exceed elapsed, so the product
	# stays inside the safe integer range when `now_utc` does.
	var next_start: float = start + float(steps * period)
	if not valid_time(next_start):
		return _rollover_error("invalid_time", start)
	var candidate: Dictionary = state.duplicate(true)
	candidate["used"] = {"period_start_utc": next_start, "cost": 0}
	_append_event(candidate, now_utc, EVENT_ROLLOVER, "", "", 0)
	return {
		"ok": true, "reason": "", "periods": steps,
		"period_start_utc": next_start, "state": candidate,
	}


## Read-only projection for UI and diagnostics. Invalid documents still return
## a total shape with `valid=false` and zeroed numbers. The event tail is copied.
static func snapshot(state: Dictionary) -> Dictionary:
	if not valid(state):
		return {
			"valid": false, "enabled": false, "period_start_utc": 0.0,
			"period_end_utc": 0.0, "period_seconds": 0, "hard_limit": 0,
			"request_limit": 0, "used": 0, "reserved": 0, "remaining": 0,
			"concurrency_limit": 0, "concurrency_used": 0, "total_cost": 0,
			"events": [],
		}
	var config: Dictionary = state.config
	var used: Dictionary = state.used
	var period: int = int(config.period_seconds)
	var start: float = float(used.period_start_utc)
	var used_cost: int = int(used.cost)
	var reserved: int = _reserved_total(state)
	var events: Array = state.events
	var recent: Array = _recent_events(events, SNAPSHOT_EVENTS)
	return {
		"valid": true, "enabled": bool(config.enabled),
		"period_start_utc": start, "period_end_utc": start + float(period),
		"period_seconds": period,
		"hard_limit": int(config.hard_limit),
		"request_limit": int(config.request_limit),
		"used": used_cost, "reserved": reserved,
		"remaining": maxi(0, int(config.hard_limit) - used_cost - reserved),
		"concurrency_limit": int(config.concurrency_limit),
		"concurrency_used": (state.reservations as Dictionary).size(),
		"total_cost": int(state.total_cost),
		"events": recent,
	}


## Strict document validation. Keys are exact, every number is a non-negative
## safe integer (an integral float is accepted because JSON round-trips whole
## numbers as floats), reservation/settled/event tables are bounded, and a
## settled id can never also hold a reservation.
static func valid(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var state: Dictionary = value
	if state.size() != STATE_KEYS.size():
		return false
	for key: String in STATE_KEYS:
		if not state.has(key):
			return false
	var config_value: Variant = state.get("config")
	if not _valid_config(config_value):
		return false
	var config: Dictionary = config_value
	var used_value: Variant = state.get("used")
	if not _valid_used(used_value):
		return false
	var used: Dictionary = used_value
	if not _is_count(state.get("total_cost")):
		return false
	if int(state.total_cost) < int(used.cost):
		return false
	var reservations_value: Variant = state.get("reservations")
	if not reservations_value is Dictionary:
		return false
	var reservations: Dictionary = reservations_value
	if reservations.size() > int(config.concurrency_limit):
		return false
	for request_id: Variant in reservations:
		if not _valid_request_id(request_id):
			return false
		if not _valid_reservation(reservations[request_id], config, used):
			return false
	var settled_value: Variant = state.get("settled")
	if not settled_value is Dictionary:
		return false
	var settled: Dictionary = settled_value
	if settled.size() > MAX_SETTLED:
		return false
	for request_id: Variant in settled:
		if not _valid_request_id(request_id):
			return false
		if not _valid_settled(settled[request_id], config):
			return false
		if reservations.has(request_id):
			return false
	var events_value: Variant = state.get("events")
	if not events_value is Array:
		return false
	var events: Array = events_value
	if events.size() > MAX_EVENTS:
		return false
	for event: Variant in events:
		if not _valid_event(event):
			return false
	return true


static func valid_time(value: Variant) -> bool:
	if not value is int and not value is float:
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER)


static func _valid_config(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var config: Dictionary = value
	if config.size() != CONFIG_KEYS.size():
		return false
	for key: String in CONFIG_KEYS:
		if not config.has(key):
			return false
	if not config.get("enabled") is bool:
		return false
	if not _is_count(config.get("period_seconds")) \
			or int(config.period_seconds) < 1 \
			or int(config.period_seconds) > MAX_PERIOD_SECONDS:
		return false
	if not _is_count(config.get("hard_limit")):
		return false
	if not _is_count(config.get("request_limit")) or int(config.request_limit) < 1:
		return false
	if not _is_count(config.get("concurrency_limit")) \
			or int(config.concurrency_limit) < 1 \
			or int(config.concurrency_limit) > MAX_CONCURRENCY_LIMIT:
		return false
	return true


static func _valid_used(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var used: Dictionary = value
	if used.size() != USED_KEYS.size():
		return false
	for key: String in USED_KEYS:
		if not used.has(key):
			return false
	if not valid_time(used.get("period_start_utc")):
		return false
	return _is_count(used.get("cost"))


static func _valid_reservation(value: Variant, config: Dictionary,
		used: Dictionary) -> bool:
	if not value is Dictionary:
		return false
	var row: Dictionary = value
	if row.size() != RESERVATION_KEYS.size():
		return false
	for key: String in RESERVATION_KEYS:
		if not row.has(key):
			return false
	if not _valid_estimate(row.get("estimate")):
		return false
	if int(row.estimate) > int(config.request_limit):
		return false
	if not valid_time(row.get("period_start_utc")) or not valid_time(row.get("created_utc")):
		return false
	var period_start: float = float(row.period_start_utc)
	if period_start > float(used.period_start_utc):
		return false
	if float(row.created_utc) < period_start:
		return false
	return true


static func _valid_settled(value: Variant, config: Dictionary) -> bool:
	if not value is Dictionary:
		return false
	var row: Dictionary = value
	if row.size() != SETTLED_KEYS.size():
		return false
	for key: String in SETTLED_KEYS:
		if not row.has(key):
			return false
	if not _valid_estimate(row.get("estimate")):
		return false
	if int(row.estimate) > int(config.request_limit):
		return false
	if not _valid_outcome(row.get("outcome")):
		return false
	if not _is_count(row.get("actual_usage")) or not _is_count(row.get("actual_cost")) \
			or not _is_count(row.get("charged")):
		return false
	if not valid_time(row.get("at_utc")):
		return false
	var charged: int = int(row.charged)
	if str(row.outcome) == OUTCOME_OK:
		return charged == int(row.actual_cost)
	return charged == 0


static func _valid_event(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var event: Dictionary = value
	if event.size() != EVENT_KEYS.size():
		return false
	for key: String in EVENT_KEYS:
		if not event.has(key):
			return false
	if not valid_time(event.get("at_utc")):
		return false
	if not event.get("kind") is String or not EVENT_KINDS.has(str(event.kind)):
		return false
	if not event.get("request_id") is String or not event.get("reason") is String:
		return false
	if not _is_count(event.get("amount")):
		return false
	if str(event.reason).length() > MAX_REASON_LENGTH:
		return false
	if str(event.kind) == EVENT_ROLLOVER:
		return str(event.request_id).is_empty() and int(event.amount) == 0
	return _valid_request_id(event.request_id)


static func _reserved_total(state: Dictionary) -> int:
	var total: int = 0
	var reservations: Dictionary = state.reservations
	for row: Variant in reservations.values():
		total += int((row as Dictionary).estimate)
	return total


static func _append_event(state: Dictionary, at_utc: float, kind: String,
		request_id: String, reason: String, amount: int) -> void:
	var events: Array = state.events
	events.append({
		"at_utc": at_utc, "kind": kind, "request_id": request_id,
		"reason": reason, "amount": amount,
	})
	# Evict by time, not by insertion order: a caller with a non-monotonic
	# clock must not be able to push the oldest event out of the log forever.
	while events.size() > MAX_EVENTS:
		var oldest: int = 0
		for index: int in range(1, events.size()):
			if float((events[index] as Dictionary).at_utc) \
					< float((events[oldest] as Dictionary).at_utc):
				oldest = index
		events.remove_at(oldest)


## Newest `limit` events by `at_utc`, returned in their recorded order so the
## caller can print them the way they happened. Equal times keep insertion order.
static func _recent_events(events: Array, limit: int) -> Array:
	var indexed: Array = []
	for index: int in events.size():
		indexed.append({"at": float((events[index] as Dictionary).at_utc), "i": index})
	indexed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.at == b.at:
			return int(a.i) < int(b.i)
		return float(a.at) < float(b.at))
	var start: int = maxi(0, indexed.size() - limit)
	var chosen: Array = []
	for index: int in range(start, indexed.size()):
		chosen.append(int(indexed[index].i))
	chosen.sort()
	var result: Array = []
	for index: int in chosen:
		result.append((events[index] as Dictionary).duplicate(true))
	return result


static func _evict_settled(state: Dictionary) -> void:
	# Same rule as the event log: keep the newest by time, so a caller with a
	# non-monotonic clock cannot pin an old settlement in the replay window.
	var settled: Dictionary = state.settled
	while settled.size() > MAX_SETTLED:
		var oldest_key: Variant = settled.keys()[0]
		var oldest_at: float = float((settled[oldest_key] as Dictionary).at_utc)
		for request_id: Variant in settled:
			var at_utc: float = float((settled[request_id] as Dictionary).at_utc)
			if at_utc < oldest_at:
				oldest_key = request_id
				oldest_at = at_utc
		settled.erase(oldest_key)


static func _valid_estimate(value: Variant) -> bool:
	return _is_count(value) and int(value) > 0


static func _valid_outcome(value: Variant) -> bool:
	return value is String and OUTCOMES.has(str(value))


static func _valid_request_id(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_REQUEST_ID_LENGTH:
		return false
	if text != text.strip_edges():
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		if code < 32 or code == 127:
			return false
	return true


## Accepts an int or an integral float (JSON round-trip), never a fraction.
static func _is_count(value: Variant) -> bool:
	if not value is int and not value is float:
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)


static func _authorize_success(request_id: String, estimate: int, duplicate: bool,
		candidate: Dictionary = {}) -> Dictionary:
	var result: Dictionary = {
		"ok": true, "reason": "", "request_id": request_id,
		"estimate": estimate, "duplicate": duplicate,
	}
	if not candidate.is_empty():
		result["state"] = candidate
	return result


static func _authorize_error(reason: String, request_id: Variant) -> Dictionary:
	return {
		"ok": false, "reason": reason,
		"request_id": str(request_id) if request_id is String else "",
		"estimate": 0, "duplicate": false,
	}


static func _settle_error(reason: String, request_id: Variant, outcome: Variant) -> Dictionary:
	return {
		"ok": false, "reason": reason,
		"request_id": str(request_id) if request_id is String else "",
		"outcome": str(outcome) if outcome is String else "",
		"actual_usage": 0, "actual_cost": 0, "charged": 0, "duplicate": false,
	}


static func _rollover_error(reason: String, period_start_utc: float) -> Dictionary:
	return {
		"ok": false, "reason": reason, "periods": 0,
		"period_start_utc": period_start_utc,
	}
