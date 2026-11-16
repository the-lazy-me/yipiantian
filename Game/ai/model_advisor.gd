extends RefCounted
## M9 模型建议组合层（缺口 G1）。把三个既有纯模块串成一条只产建议的管线：
##
##   1. model_fallback.choose_backend 决定本次请求能落到哪个后端；
##   2. model_budget.authorize 只对云端调用预留额度；
##   3. model_scheduler.submit / poll 把任务交给调用方注入的后端。
##
## 边界：
## - 不读磁盘、不读引擎时钟、不联网、不写任何世界文档。时间由 `now_utc`
##   传入，可用性与费用由调用方给出。
## - 本层不创建、不下载、不调用真实模型。真实后端由调用方通过 `Callable`
##   注入；provider 每次只返回一个对象，构造它应当无副作用。
## - 返回的 `suggestion` 已经过 `ModelTask.accept`，只可能是意图或文本，永远
##   不含可执行命令。它是否被接受、是否写成权威事件，完全由调用方决定。
## - 本层不调用 `settle`：一次请求只做“回退选择 -> 预算授权 -> 调度提交 ->
##   一次轮询”。`budget.state` 是预算文档的候选副本（只有预留变化），由调用
##   方决定是否保存；调用方拿到真实结果后再自行结算。
##
## 为什么先选择后端再授权：回退规则本身要读预算文档与可用性，并且只有云端
## 路径需要预留额度。若先无条件 `authorize`，本地或规则路径会留下无法解释的
## 云端预留。因此顺序固定为 choose -> authorize (cloud only) -> submit -> poll。

const Budget = preload("res://ai/model_budget.gd")
const Fallback = preload("res://ai/model_fallback.gd")
const ModelTask = preload("res://ai/model_task.gd")
const Scheduler = preload("res://ai/model_scheduler.gd")

const PREFERENCE_AUTO: String = "auto"
const PREFERENCE_LOCAL_FIRST: String = "local_first"
const PREFERENCES: Array[String] = [PREFERENCE_AUTO, PREFERENCE_LOCAL_FIRST]

const STATUS_PROPOSED: String = "proposed"
const STATUS_NO_SUGGESTION: String = "no_suggestion"
const STATUS_REJECTED: String = "rejected"

const REASON_INVALID_REQUEST: String = "invalid_request"
const REASON_INVALID_BUDGET: String = "invalid_budget"
const REASON_BUDGET_DENIED: String = "budget_denied"
const REASON_DUPLICATE_REQUEST: String = "duplicate_request"
const REASON_NO_BACKEND: String = "no_backend"
const REASON_BACKEND_UNAVAILABLE: String = "backend_unavailable"
const REASON_CLOUD_DISABLED: String = "cloud_disabled"
const REASON_BUDGET_EXHAUSTED: String = "budget_exhausted"
const REASON_CONCURRENCY_FULL: String = "concurrency_full"
const REASON_PERIOD_ELAPSED: String = "period_elapsed"
const REASON_SCHEDULER_REJECTED: String = "scheduler_rejected"
const REASON_SCHEDULER_DISABLED: String = "scheduler_disabled"
const REASON_SCHEDULER_LOAD_FAILED: String = "scheduler_load_failed"
const REASON_SCHEDULER_BACKEND_ERROR: String = "scheduler_backend_error"
const REASON_SCHEDULER_WAITING: String = "scheduler_waiting"

const REQUEST_KEYS: Array[String] = [
	"id", "type", "prompt", "context", "world_id", "state_version",
	"deadline_utc", "budget", "estimate", "cloud_available",
	"local_available", "backend_preference", "scheduler_options",
]
const OPTIONAL_REQUEST_KEYS: Array[String] = [
	"context", "backend_preference", "scheduler_options",
]
const SCHEDULER_OPTION_KEYS: Array[String] = [
	"enabled", "queue_limit", "idle_unload_seconds", "max_cancelled_ids",
]
## Authorization defects that mean the request itself is malformed, not that
## the budget is short.
const BUDGET_REQUEST_DEFECTS: Array[String] = [
	"invalid_state", "invalid_request", "invalid_estimate", "invalid_time",
]

const RESULT_KEYS: Array[String] = [
	"ok", "status", "reason", "detail", "backend", "request_id",
	"budget", "scheduler", "suggestion",
]
const BUDGET_KEYS: Array[String] = [
	"authorized", "estimate", "charged", "remaining", "state",
]
const SCHEDULER_KEYS: Array[String] = ["status", "task_id"]

var backend_provider: Callable


func _init(provider: Callable = Callable()) -> void:
	backend_provider = provider


func advise(request: Variant, now_utc: float) -> Dictionary:
	if not request is Dictionary:
		return _rejected(REASON_INVALID_REQUEST, "invalid_task", "", "")
	var value: Dictionary = request
	var id: String = str(value.get("id", "")) if value.get("id") is String else ""
	var keys_reason: String = _request_keys_reason(value)
	if not keys_reason.is_empty():
		return _rejected(REASON_INVALID_REQUEST, keys_reason, "", id)
	if not ModelTask.valid_time(now_utc):
		return _rejected(REASON_INVALID_REQUEST, "invalid_time", "", id)
	var prompt_reason: String = _prompt_reason(value)
	if not prompt_reason.is_empty():
		return _rejected(REASON_INVALID_REQUEST, prompt_reason, "", id)
	var context: Dictionary = (value.get("context", {}) as Dictionary)
	if context.has("message"):
		return _rejected(REASON_INVALID_REQUEST, "duplicate_message", "", id)
	if not value.get("cloud_available") is bool \
			or not value.get("local_available") is bool:
		return _rejected(REASON_INVALID_REQUEST, "invalid_availability", "", id)
	var estimate: Variant = value.get("estimate")
	if not estimate is int or int(estimate) < 1 \
			or int(estimate) > Budget.MAX_SAFE_INTEGER:
		return _rejected(REASON_INVALID_REQUEST, "invalid_estimate", "", id)
	var preference: Variant = value.get("backend_preference", PREFERENCE_AUTO)
	if not preference is String or not PREFERENCES.has(str(preference)):
		return _rejected(REASON_INVALID_REQUEST, "invalid_backend_preference", "", id)
	var options_reason: String = _scheduler_options_reason(
		value.get("scheduler_options", {}))
	if not options_reason.is_empty():
		return _rejected(REASON_INVALID_REQUEST, options_reason, "", id)
	if not Budget.valid(value.get("budget")):
		return _rejected(REASON_INVALID_BUDGET, "invalid_state", "", id)
	var budget_doc: Dictionary = value.get("budget")

	var visible_context: Dictionary = context.duplicate(true)
	visible_context["message"] = str(value.get("prompt"))
	var created: Dictionary = ModelTask.create({
		"id": value.get("id"),
		"type": value.get("type"),
		"world_id": value.get("world_id"),
		"state_version": value.get("state_version"),
		"visible_context": visible_context,
		"deadline_utc": value.get("deadline_utc"),
	}, now_utc)
	if not created.ok:
		return _rejected(REASON_INVALID_REQUEST, str(created.reason), "", id)
	var task: Dictionary = created.task

	var choice: Dictionary = _choose_backend(budget_doc, now_utc,
		bool(value.get("cloud_available")), bool(value.get("local_available")),
		str(preference))
	var backend_kind: String = str(choice.backend)
	var remaining: int = Budget.snapshot(budget_doc).remaining
	if backend_kind == Fallback.BACKEND_RULES:
		var rules_reason: String = _rules_reason(str(choice.reason))
		if rules_reason == REASON_INVALID_BUDGET:
			return _rejected(REASON_INVALID_BUDGET, str(choice.reason), "", id)
		var refused: Dictionary = _base(STATUS_NO_SUGGESTION, rules_reason,
			str(choice.reason), backend_kind, id)
		refused["budget"] = _budget_block(false, 0, remaining, {})
		return refused

	var state_after: Dictionary = {}
	var authorized: bool = false
	var held: int = 0
	if backend_kind == Fallback.BACKEND_CLOUD:
		var auth: Dictionary = Budget.authorize(
			budget_doc, value.get("id"), estimate, now_utc)
		if not auth.ok:
			var auth_reason: String = str(auth.reason)
			if BUDGET_REQUEST_DEFECTS.has(auth_reason):
				return _rejected(REASON_INVALID_REQUEST, auth_reason, "", id)
			return _rejected(REASON_BUDGET_DENIED, auth_reason, backend_kind, id)
		if bool(auth.get("duplicate", false)):
			return _rejected(REASON_DUPLICATE_REQUEST, "authorized_before",
				backend_kind, id)
		authorized = true
		held = int(auth.estimate)
		state_after = auth.get("state", {})
		remaining = Budget.snapshot(state_after).remaining
	var budget_block: Dictionary = _budget_block(
		authorized, held, remaining, state_after)

	var scheduler_options: Dictionary = (value.get(
		"scheduler_options", {}) as Dictionary).duplicate(true)
	if scheduler_options.get("enabled", true) == false:
		var off: Dictionary = _base(STATUS_REJECTED, REASON_SCHEDULER_DISABLED,
			"disabled", backend_kind, id)
		off["budget"] = budget_block
		return off

	var backend_value: Variant = _provide(backend_kind, value)
	if not _backend_ok(backend_value):
		var missing: Dictionary = _base(STATUS_REJECTED,
			REASON_BACKEND_UNAVAILABLE, backend_kind, backend_kind, id)
		missing["budget"] = budget_block
		return missing

	var scheduler := Scheduler.new(backend_value, str(value.get("world_id")),
		str(value.get("state_version")), scheduler_options)
	var submitted: Dictionary = scheduler.submit(task, now_utc)
	if not submitted.ok:
		var submit_reason: String = str(submitted.reason)
		var submit_named: String = REASON_SCHEDULER_DISABLED \
			if submit_reason == "disabled" else REASON_SCHEDULER_REJECTED
		var submit_result: Dictionary = _base(STATUS_REJECTED, submit_named,
			submit_reason, backend_kind, id)
		submit_result["budget"] = budget_block
		submit_result["scheduler"] = {
			"status": str(submitted.status), "task_id": str(submitted.get("task_id", "")),
		}
		return submit_result

	var polled: Dictionary = scheduler.poll(now_utc)
	var poll_status: String = str(polled.get("status", ""))
	if poll_status == "completed":
		var suggestion: Variant = polled.get("suggestion", {})
		if not suggestion is Dictionary or (suggestion as Dictionary).is_empty():
			var empty: Dictionary = _base(STATUS_REJECTED,
				REASON_SCHEDULER_REJECTED, "empty_suggestion", backend_kind, id)
			empty["budget"] = budget_block
			empty["scheduler"] = _scheduler_block(polled, id)
			return empty
		var proposed: Dictionary = _base(STATUS_PROPOSED, "", "", backend_kind, id)
		proposed["budget"] = budget_block
		proposed["scheduler"] = _scheduler_block(polled, id)
		proposed["suggestion"] = (suggestion as Dictionary).duplicate(true)
		return proposed

	var named: String = _scheduler_reason(poll_status)
	var outcome: Dictionary = _base(
		STATUS_NO_SUGGESTION if named == REASON_SCHEDULER_WAITING else STATUS_REJECTED,
		named, str(polled.get("detail", polled.get("reason", poll_status))),
		backend_kind, id)
	outcome["budget"] = budget_block
	outcome["scheduler"] = _scheduler_block(polled, id)
	return outcome


func _request_keys_reason(request: Dictionary) -> String:
	for key: Variant in request:
		if not key is String or not REQUEST_KEYS.has(str(key)):
			return "unknown_field"
	for key: String in REQUEST_KEYS:
		if OPTIONAL_REQUEST_KEYS.has(key):
			continue
		if not request.has(key):
			return "missing_field"
	return ""


func _prompt_reason(request: Dictionary) -> String:
	var prompt: Variant = request.get("prompt")
	if not prompt is String or str(prompt).strip_edges().is_empty():
		return "invalid_prompt"
	var context: Variant = request.get("context", {})
	if not context is Dictionary:
		return "invalid_context"
	return ""


func _scheduler_options_reason(raw: Variant) -> String:
	if not raw is Dictionary:
		return "invalid_scheduler_options"
	var options: Dictionary = raw
	for key: Variant in options:
		if not key is String or not SCHEDULER_OPTION_KEYS.has(str(key)):
			return "unknown_scheduler_option"
	if options.has("enabled") and not options.enabled is bool:
		return "invalid_scheduler_options"
	return ""


func _choose_backend(budget_doc: Dictionary, now_utc: float,
		cloud_available: bool, local_available: bool,
		preference: String) -> Dictionary:
	if preference == PREFERENCE_LOCAL_FIRST and local_available:
		return {"backend": Fallback.BACKEND_LOCAL, "reason": "preferred_local"}
	return Fallback.choose_backend(budget_doc, now_utc, cloud_available,
		local_available)


func _rules_reason(fallback_reason: String) -> String:
	match fallback_reason:
		Fallback.REASON_CLOUD_DISABLED:
			return REASON_CLOUD_DISABLED
		Fallback.REASON_BUDGET_EXHAUSTED:
			return REASON_BUDGET_EXHAUSTED
		Fallback.REASON_CONCURRENCY_FULL:
			return REASON_CONCURRENCY_FULL
		Fallback.REASON_PERIOD_ELAPSED:
			return REASON_PERIOD_ELAPSED
		Fallback.REASON_INVALID_STATE:
			return REASON_INVALID_BUDGET
		Fallback.REASON_INVALID_TIME:
			return REASON_INVALID_REQUEST
		_:
			return REASON_NO_BACKEND


func _scheduler_reason(poll_status: String) -> String:
	match poll_status:
		"waiting":
			return REASON_SCHEDULER_WAITING
		"disabled":
			return REASON_SCHEDULER_DISABLED
		"load_failed":
			return REASON_SCHEDULER_LOAD_FAILED
		"backend_error":
			return REASON_SCHEDULER_BACKEND_ERROR
		_:
			return REASON_SCHEDULER_REJECTED


func _scheduler_block(polled: Dictionary, fallback_id: String) -> Dictionary:
	return {
		"status": str(polled.get("status", "")),
		"task_id": str(polled.get("task_id", fallback_id)),
	}


func _provide(backend_kind: String, request: Dictionary) -> Variant:
	if not backend_provider.is_valid():
		return null
	return backend_provider.call(backend_kind, request.duplicate(true))


func _backend_ok(value: Variant) -> bool:
	if not value is Object:
		return false
	var backend: Object = value
	return is_instance_valid(backend) and backend.has_method("load") \
		and backend.has_method("generate") and backend.has_method("unload") \
		and backend.has_method("loaded")


func _base(status: String, reason: String, detail: String, backend: String,
		request_id: String) -> Dictionary:
	return {
		"ok": status == STATUS_PROPOSED,
		"status": status,
		"reason": reason,
		"detail": detail,
		"backend": backend,
		"request_id": request_id,
		"budget": _budget_block(false, 0, 0, {}),
		"scheduler": {"status": "skipped", "task_id": ""},
		"suggestion": {},
	}


func _budget_block(authorized: bool, estimate: int, remaining: int,
		state: Dictionary) -> Dictionary:
	return {
		"authorized": authorized,
		"estimate": estimate,
		## 本层从不结算，因此一次建议调用的计费恒为零；真实费用由调用方在
		## 拿到供应商结果后用 `ModelBudget.settle` 记录。
		"charged": 0,
		"remaining": remaining,
		"state": state,
	}


func _rejected(reason: String, detail: String, backend: String,
		request_id: String) -> Dictionary:
	return _base(STATUS_REJECTED, reason, detail, backend, request_id)
