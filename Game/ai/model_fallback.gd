extends RefCounted
## M9-04 backend fallback. One pure function: given a budget document, the
## injected time and two availability flags from the caller, choose which
## backend should serve the next task. It reads no global, clock, disk or
## network, and it never mutates the budget document.
##
## Precedence is fixed so the same inputs always yield the same backend:
##   1. invalid budget document or time -> "rules"
##   2. cloud authorization off       -> "rules"
##   3. cloud unreachable             -> "local" when the caller says local is
##                                       available, otherwise "rules"
##   4. budget period already elapsed -> local/rules (rollover is the caller's
##                                       next step; a stale period cannot spend)
##   5. no remaining room or all
##      concurrency slots taken       -> local/rules
##   6. otherwise                     -> "cloud"
##
## `reason` is a stable string: invalid_state, invalid_time, cloud_disabled,
## cloud_unavailable, period_elapsed, budget_exhausted, concurrency_full, or
## empty for cloud.

const Budget = preload("res://ai/model_budget.gd")

const BACKEND_CLOUD: String = "cloud"
const BACKEND_LOCAL: String = "local"
const BACKEND_RULES: String = "rules"

const REASON_INVALID_STATE: String = "invalid_state"
const REASON_INVALID_TIME: String = "invalid_time"
const REASON_CLOUD_DISABLED: String = "cloud_disabled"
const REASON_CLOUD_UNAVAILABLE: String = "cloud_unavailable"
const REASON_PERIOD_ELAPSED: String = "period_elapsed"
const REASON_BUDGET_EXHAUSTED: String = "budget_exhausted"
const REASON_CONCURRENCY_FULL: String = "concurrency_full"


static func choose_backend(budget_state: Dictionary, now_utc: float,
		cloud_available: bool, local_available: bool = false) -> Dictionary:
	if not Budget.valid(budget_state):
		return _result(BACKEND_RULES, REASON_INVALID_STATE)
	if not Budget.valid_time(now_utc):
		return _result(BACKEND_RULES, REASON_INVALID_TIME)
	if not bool(budget_state.config.enabled):
		return _result(BACKEND_RULES, REASON_CLOUD_DISABLED)
	# An unreachable cloud is a transport fact, so it outranks a budget fact:
	# the caller learns "offline", not "out of money", when both are true.
	if not cloud_available:
		return _degraded(local_available, REASON_CLOUD_UNAVAILABLE)
	var used: Dictionary = budget_state.used
	var start: float = float(used.period_start_utc)
	var end: float = start + float(int(budget_state.config.period_seconds))
	if now_utc < start:
		return _result(BACKEND_RULES, REASON_INVALID_TIME)
	if now_utc >= end:
		return _degraded(local_available, REASON_PERIOD_ELAPSED)
	var reserved: int = 0
	for row: Variant in (budget_state.reservations as Dictionary).values():
		reserved += int((row as Dictionary).estimate)
	if int(used.cost) + reserved >= int(budget_state.config.hard_limit):
		return _degraded(local_available, REASON_BUDGET_EXHAUSTED)
	if (budget_state.reservations as Dictionary).size() >= int(budget_state.config.concurrency_limit):
		return _degraded(local_available, REASON_CONCURRENCY_FULL)
	return _result(BACKEND_CLOUD, "")


static func _degraded(local_available: bool, reason: String) -> Dictionary:
	return _result(BACKEND_LOCAL if local_available else BACKEND_RULES, reason)


static func _result(backend: String, reason: String) -> Dictionary:
	return {"backend": backend, "reason": reason}
