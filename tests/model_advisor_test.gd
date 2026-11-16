extends SceneTree
## M9 G1 headless fixture for the advisory composition layer. The fake backend
## is in-process: there is no network, disk, clock, model load or world write.
## Every request carries its own time, cost estimate and availability flags.

const Budget = preload("res://ai/model_budget.gd")
const Fallback = preload("res://ai/model_fallback.gd")
const Advisor = preload("res://ai/model_advisor.gd")

const BASE: float = 1800000000.0
const DIALOGUE_TYPE: String = "dialogue"

const RESULT_KEYS: Array[String] = [
	"ok", "status", "reason", "detail", "backend", "request_id",
	"budget", "scheduler", "suggestion",
]
const BUDGET_KEYS: Array[String] = [
	"authorized", "estimate", "charged", "remaining", "state",
]
const SCHEDULER_KEYS: Array[String] = ["status", "task_id"]
const INTENT_KEYS: Array[String] = [
	"intent", "confidence", "reason", "state_version",
]
const TEXT_KEYS: Array[String] = ["text"]
## Keys that would imply this layer can execute or persist something. None may
## appear anywhere in any result.
const FORBIDDEN_KEYS: Array[String] = [
	"command", "commands", "action", "actions", "apply", "mutate",
	"mutation", "world_state", "write", "writes", "save", "file", "path",
]

var checks: int = 0
var failures: Array[String] = []


class FakeBackend:
	var load_calls: int = 0
	var generate_calls: int = 0
	var unload_calls: int = 0
	var is_loaded: bool = false
	var mode: String = "intent"
	var generated_tasks: Array = []

	func load() -> bool:
		load_calls += 1
		is_loaded = true
		return true

	func generate(task: Dictionary) -> Dictionary:
		generate_calls += 1
		generated_tasks.append(task.duplicate(true))
		if mode == "error":
			return {"ok": false, "reason": "boom"}
		if mode == "pending":
			return {"ok": true, "pending": true}
		if str(task.type) == "intent":
			return {"ok": true, "response": {
				"intent": "greet", "confidence": 0.5, "reason": "",
				"state_version": str(task.state_version),
			}}
		return {"ok": true, "response": "好的"}

	func unload() -> void:
		unload_calls += 1
		is_loaded = false

	func loaded() -> bool:
		return is_loaded


class Provider:
	var calls: Array = []
	var backend: Variant = null

	func provide(kind: String, request: Dictionary) -> Variant:
		calls.append({"kind": kind, "request": request.duplicate(true)})
		return backend


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_cloud_proposal()
	_test_local_proposal()
	_test_budget_shortfalls()
	_test_no_backend()
	_test_scheduler_rejection()
	_test_concurrent_requests()
	_test_strict_shapes_and_no_world_keys()
	for failure: String in failures:
		push_error(failure)
	print("MODEL_ADVISOR_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_cloud_proposal() -> void:
	var provider := Provider.new()
	var backend := FakeBackend.new()
	provider.backend = backend
	var advisor := Advisor.new(Callable(provider, "provide"))
	var result: Dictionary = advisor.advise(_request("req-1"), BASE + 1.0)
	_expect_shape(result)
	_expect(result.ok and result.status == Advisor.STATUS_PROPOSED, "云端正常路径返回提案")
	_expect(result.reason == "" and result.detail == "", "成功路径原因为空")
	_expect(result.backend == Fallback.BACKEND_CLOUD, "云端授权后选择 cloud")
	_expect(result.request_id == "req-1", "回显请求 id")
	_expect(provider.calls.size() == 1, "只向 provider 要一次后端")
	_expect(str(provider.calls[0].kind) == Fallback.BACKEND_CLOUD, "provider 收到 cloud")
	_expect(backend.load_calls == 1 and backend.generate_calls == 1, "懒加载一次并生成一次")
	_expect(result.budget.authorized and int(result.budget.estimate) == 30
		and int(result.budget.charged) == 0, "云端预留 30 且不结算")
	_expect(int(result.budget.remaining) == 970, "剩余额度扣除预留")
	_expect(Budget.valid(result.budget.state), "返回的预算候选文档合法")
	_expect(result.budget.state.reservations.has("req-1"), "候选文档只含本次预留")
	_expect(result.budget.state.reservations.size() == 1, "候选文档预留数为 1")
	_expect(_same_keys(result.suggestion, INTENT_KEYS), "意图建议键集精确")
	_expect(str(result.suggestion.intent) == "greet"
		and str(result.suggestion.state_version) == "state-v1", "建议来自协议解析")
	_expect(result.scheduler.status == "completed"
		and result.scheduler.task_id == "req-1", "调度块记录完成与任务 id")
	var task: Dictionary = backend.generated_tasks[0]
	_expect(str(task.visible_context.message) == "你好", "提示进入可见上下文")
	_expect(not task.has("prompt"), "请求自身的字段不会泄漏到协议任务")

	var text_provider := Provider.new()
	var text_backend := FakeBackend.new()
	text_backend.mode = "text"
	text_provider.backend = text_backend
	var text_advisor := Advisor.new(Callable(text_provider, "provide"))
	var text_result: Dictionary = text_advisor.advise(
		_request("req-text", DIALOGUE_TYPE), BASE + 1.0)
	_expect_shape(text_result)
	_expect(text_result.status == Advisor.STATUS_PROPOSED
		and _same_keys(text_result.suggestion, TEXT_KEYS)
		and str(text_result.suggestion.text) == "好的", "对话建议只有文本键")


func _test_local_proposal() -> void:
	var provider := Provider.new()
	var backend := FakeBackend.new()
	backend.mode = "text"
	provider.backend = backend
	var advisor := Advisor.new(Callable(provider, "provide"))
	var request: Dictionary = _request("req-local", DIALOGUE_TYPE)
	request["cloud_available"] = false
	request["local_available"] = true
	var result: Dictionary = advisor.advise(request, BASE + 1.0)
	_expect_shape(result)
	_expect(result.status == Advisor.STATUS_PROPOSED
		and result.backend == Fallback.BACKEND_LOCAL, "断网且本地可用时选择 local")
	_expect(not result.budget.authorized and int(result.budget.estimate) == 0
		and result.budget.state.is_empty(), "本地路径不预留云端额度")
	_expect(int(result.budget.remaining) == 1000, "本地路径剩余额度不变")
	_expect(str(provider.calls[0].kind) == Fallback.BACKEND_LOCAL, "provider 收到 local")

	var preferred: Dictionary = _request("req-pref", DIALOGUE_TYPE)
	preferred["backend_preference"] = Advisor.PREFERENCE_LOCAL_FIRST
	var pref_result: Dictionary = advisor.advise(preferred, BASE + 1.0)
	_expect_shape(pref_result)
	_expect(pref_result.backend == Fallback.BACKEND_LOCAL
		and not pref_result.budget.authorized, "本地优先时不碰云端预算")


func _test_budget_shortfalls() -> void:
	var provider := Provider.new()
	var backend := FakeBackend.new()
	provider.backend = backend
	var advisor := Advisor.new(Callable(provider, "provide"))

	# 预留已占满硬上限：回退规则判定耗尽，本地不可用则没有建议。
	var spent: Dictionary = _budget(100, 100, 4, true)
	spent = Budget.authorize(spent, "req-0", 100, BASE).state
	var exhausted: Dictionary = _request("req-exhausted")
	exhausted["budget"] = spent
	exhausted["cloud_available"] = true
	exhausted["local_available"] = false
	var no_money: Dictionary = advisor.advise(exhausted, BASE + 1.0)
	_expect_shape(no_money)
	_expect(no_money.status == Advisor.STATUS_NO_SUGGESTION
		and no_money.reason == Advisor.REASON_BUDGET_EXHAUSTED,
		"额度耗尽返回没有建议而非拒绝")
	_expect(no_money.suggestion.is_empty() and provider.calls.is_empty(),
		"额度耗尽不请求后端")

	# 本请求预留值超过剩余：授权返回 over_budget，归入预算拒绝。
	var tight: Dictionary = _request("req-over")
	tight["budget"] = _budget(50, 100, 4, true)
	tight["estimate"] = 51
	var over: Dictionary = advisor.advise(tight, BASE + 1.0)
	_expect_shape(over)
	_expect(over.status == Advisor.STATUS_REJECTED
		and over.reason == Advisor.REASON_BUDGET_DENIED
		and over.detail == "over_budget", "预留值超过上限时具名拒绝")
	_expect(not over.budget.authorized and provider.calls.is_empty(),
		"预算拒绝不请求后端")

	# 单请求值超过单请求上限。
	var capped: Dictionary = _request("req-cap")
	capped["budget"] = _budget(1000, 100, 4, true)
	capped["estimate"] = 150
	var cap: Dictionary = advisor.advise(capped, BASE + 1.0)
	_expect_shape(cap)
	_expect(cap.reason == Advisor.REASON_BUDGET_DENIED
		and cap.detail == "over_request_cap", "超过单请求上限具名拒绝")

	# 周期已过：规则回退要求调用方先 rollover。
	var stale: Dictionary = _request("req-stale")
	stale["budget"] = Budget.initial_state({
		"enabled": true, "hard_limit": 1000, "request_limit": 100,
		"concurrency_limit": 4, "period_start_utc": BASE - 90000.0,
		"period_seconds": 86400,
	})
	stale["cloud_available"] = true
	stale["local_available"] = false
	var elapsed: Dictionary = advisor.advise(stale, BASE + 1.0)
	_expect_shape(elapsed)
	_expect(elapsed.status == Advisor.STATUS_NO_SUGGESTION
		and elapsed.reason == Advisor.REASON_PERIOD_ELAPSED,
		"过期周期返回没有建议且原因具名")


func _test_no_backend() -> void:
	var provider := Provider.new()
	provider.backend = null
	var advisor := Advisor.new(Callable(provider, "provide"))

	# 规则回退：没有本地后端也没有云端。
	var request: Dictionary = _request("req-rules")
	request["budget"] = _budget(1000, 100, 4)
	request["cloud_available"] = false
	request["local_available"] = false
	var rules: Dictionary = advisor.advise(request, BASE + 1.0)
	_expect_shape(rules)
	_expect(rules.status == Advisor.STATUS_NO_SUGGESTION
		and rules.reason == Advisor.REASON_CLOUD_DISABLED
		and rules.backend == Fallback.BACKEND_RULES, "云未授权时回退规则且没有建议")
	_expect(provider.calls.is_empty(), "规则回退不请求后端")

	var offline: Dictionary = _request("req-offline")
	offline["budget"] = _budget(1000, 100, 4, true)
	offline["cloud_available"] = false
	offline["local_available"] = false
	var no_route: Dictionary = advisor.advise(offline, BASE + 1.0)
	_expect_shape(no_route)
	_expect(no_route.status == Advisor.STATUS_NO_SUGGESTION
		and no_route.reason == Advisor.REASON_NO_BACKEND, "云断网且无本地时没有回退后端")

	# 外部注入缺失：即使云端已授权，也拒绝并保留已验证的预留候选。
	var missing: Dictionary = Advisor.new().advise(_request("req-missing"), BASE + 1.0)
	_expect_shape(missing)
	_expect(missing.status == Advisor.STATUS_REJECTED
		and missing.reason == Advisor.REASON_BACKEND_UNAVAILABLE,
		"没有注入后端时拒绝")
	_expect(missing.budget.authorized and Budget.valid(missing.budget.state),
		"拒绝时已产生的预留候选仍合法，由调用方结算或丢弃")
	_expect(provider.calls.is_empty(), "空 provider 不被调用")

	# 注入对象不满足调度器鸭子类型。
	var wrong := Provider.new()
	wrong.backend = RefCounted.new()
	var wrong_result: Dictionary = Advisor.new(
		Callable(wrong, "provide")).advise(_request("req-wrong"), BASE + 1.0)
	_expect_shape(wrong_result)
	_expect(wrong_result.reason == Advisor.REASON_BACKEND_UNAVAILABLE,
		"缺少后端接口的对象被拒绝")


func _test_scheduler_rejection() -> void:
	var provider := Provider.new()
	var backend := FakeBackend.new()
	provider.backend = backend
	var advisor := Advisor.new(Callable(provider, "provide"))

	var off: Dictionary = _request("req-off")
	off["scheduler_options"] = {"enabled": false}
	var disabled: Dictionary = advisor.advise(off, BASE + 1.0)
	_expect_shape(disabled)
	_expect(disabled.status == Advisor.STATUS_REJECTED
		and disabled.reason == Advisor.REASON_SCHEDULER_DISABLED,
		"关闭调度器返回调度拒绝")
	_expect(provider.calls.is_empty() and backend.generate_calls == 0,
		"关闭调度器不请求后端")

	var invalid_options: Dictionary = _request("req-opt")
	invalid_options["scheduler_options"] = {"unknown": 1}
	var bad_options: Dictionary = advisor.advise(invalid_options, BASE + 1.0)
	_expect(bad_options.reason == Advisor.REASON_INVALID_REQUEST
		and bad_options.detail == "unknown_scheduler_option", "未知调度选项被拒绝")

	backend.mode = "error"
	var error_result: Dictionary = advisor.advise(_request("req-error"), BASE + 1.0)
	_expect_shape(error_result)
	_expect(error_result.status == Advisor.STATUS_REJECTED
		and error_result.reason == Advisor.REASON_SCHEDULER_BACKEND_ERROR
		and error_result.detail == "boom", "后端错误映射为具名调度拒绝")
	_expect(error_result.scheduler.status == "backend_error"
		and error_result.scheduler.task_id == "req-error", "调度块记录失败状态")

	backend.mode = "pending"
	var pending_result: Dictionary = advisor.advise(_request("req-pending"), BASE + 1.0)
	_expect_shape(pending_result)
	_expect(pending_result.status == Advisor.STATUS_NO_SUGGESTION
		and pending_result.reason == Advisor.REASON_SCHEDULER_WAITING,
		"异步未完成视为没有建议，调用方需继续轮询")
	_expect(pending_result.suggestion.is_empty(), "等待状态没有建议")


func _test_concurrent_requests() -> void:
	var provider := Provider.new()
	var backend := FakeBackend.new()
	provider.backend = backend
	var advisor := Advisor.new(Callable(provider, "provide"))
	var shared: Dictionary = _budget(1000, 100, 2, true)
	var first_request: Dictionary = _request("req-a")
	first_request["budget"] = shared
	var second_request: Dictionary = _request("req-b")
	second_request["budget"] = shared
	second_request["estimate"] = 40

	var first: Dictionary = advisor.advise(first_request, BASE + 1.0)
	var second: Dictionary = advisor.advise(second_request, BASE + 1.0)
	_expect_shape(first)
	_expect_shape(second)
	_expect(first.status == Advisor.STATUS_PROPOSED
		and second.status == Advisor.STATUS_PROPOSED, "两个并发请求都得到提案")
	_expect(first.budget.state.reservations.has("req-a")
		and not first.budget.state.reservations.has("req-b"),
		"第一个候选只含自己的预留")
	_expect(second.budget.state.reservations.has("req-b")
		and not second.budget.state.reservations.has("req-a"),
		"第二个候选只含自己的预留")
	_expect(int(first.budget.remaining) == 970 and int(second.budget.remaining) == 960,
		"共享输入文档时两次请求互不扣减对方的剩余")

	# 调用方沿用第一份候选：第二个请求必须看见两份预留。
	var chained_request: Dictionary = _request("req-c")
	chained_request["budget"] = first.budget.state
	chained_request["estimate"] = 40
	var chained: Dictionary = advisor.advise(chained_request, BASE + 1.0)
	_expect_shape(chained)
	_expect(chained.status == Advisor.STATUS_PROPOSED
		and int(chained.budget.remaining) == 930
		and chained.budget.state.reservations.size() == 2,
		"沿用候选文档时预算按顺序累计")

	# 调用方修改返回值不会污染后续调用：先拿一份重新生成的候选，再改坏它。
	var replay: Dictionary = advisor.advise(first_request, BASE + 1.0)
	_expect(replay.status == Advisor.STATUS_PROPOSED
		and replay.budget.state.reservations.has("req-a"),
		"重复请求得到新的合法候选")

	# 同一个 id 第二次授权是重放，不能当成新建议。这里用只含 req-a 预留的
	# 候选文档，且云端可用、本地不可用，确保走到授权而不是回退。
	var duplicate_request: Dictionary = _request("req-a")
	duplicate_request["budget"] = replay.budget.state
	duplicate_request["local_available"] = false
	var duplicate: Dictionary = advisor.advise(duplicate_request, BASE + 1.0)
	_expect(duplicate.status == Advisor.STATUS_REJECTED
		and duplicate.reason == Advisor.REASON_DUPLICATE_REQUEST,
		"重复 id 的重放授权被拒绝，避免重复生成")

	first.budget.state.reservations.clear()
	var after_mutation: Dictionary = advisor.advise(first_request, BASE + 1.0)
	_expect(after_mutation.status == Advisor.STATUS_PROPOSED
		and after_mutation.budget.state.reservations.has("req-a"),
		"修改返回的候选不影响后续请求")


func _test_strict_shapes_and_no_world_keys() -> void:
	var provider := Provider.new()
	var backend := FakeBackend.new()
	provider.backend = backend
	var advisor := Advisor.new(Callable(provider, "provide"))
	var results: Array[Dictionary] = []
	results.append(advisor.advise(_request("shape-1"), BASE + 1.0))
	results.append(advisor.advise({"id": "shape-2"}, BASE + 1.0))
	results.append(advisor.advise("not a dictionary", BASE + 1.0))
	var stale: Dictionary = _request("shape-3")
	stale["budget"] = _budget(50, 100, 4, true)
	stale["estimate"] = 51
	results.append(advisor.advise(stale, BASE + 1.0))
	var broken: Dictionary = _request("shape-4")
	broken["budget"] = {"config": {}}
	var broken_result: Dictionary = advisor.advise(broken, BASE + 1.0)
	_expect(broken_result.status == Advisor.STATUS_REJECTED
		and broken_result.reason == Advisor.REASON_INVALID_BUDGET,
		"非法预算文档具名拒绝")
	results.append(broken_result)
	for result: Dictionary in results:
		_expect(_same_keys(result, RESULT_KEYS), "每条返回键集精确")
		_expect(_same_keys(result.budget, BUDGET_KEYS), "预算块键集精确")
		_expect(_same_keys(result.scheduler, SCHEDULER_KEYS), "调度块键集精确")
		_expect(not result.has("state"), "顶层没有世界文档式 state")
		for key: String in _all_keys(result):
			_expect(not FORBIDDEN_KEYS.has(key.to_lower()),
				"返回不含可执行或落盘键：" + key)
		var suggestion: Dictionary = result.suggestion
		if not suggestion.is_empty():
			_expect(_same_keys(suggestion, INTENT_KEYS)
				or _same_keys(suggestion, TEXT_KEYS),
				"建议只能是意图或文本形状")


func _request(id: String, type: String = "intent") -> Dictionary:
	return {
		"id": id,
		"type": type,
		"prompt": "你好",
		"context": {"npc_id": "npc-lin"},
		"world_id": "world-a",
		"state_version": "state-v1",
		"deadline_utc": BASE + 100.0,
		"budget": _budget(1000, 100, 4, true),
		"estimate": 30,
		"cloud_available": true,
		"local_available": true,
	}


func _budget(hard_limit: int, request_limit: int, concurrency: int,
		enabled: bool = false) -> Dictionary:
	return Budget.initial_state({
		"enabled": enabled, "hard_limit": hard_limit,
		"request_limit": request_limit, "concurrency_limit": concurrency,
		"period_start_utc": BASE,
	})


func _expect_shape(result: Dictionary) -> void:
	_expect(_same_keys(result, RESULT_KEYS), "返回键集精确")
	_expect(result.budget is Dictionary and _same_keys(result.budget, BUDGET_KEYS),
		"预算块键集精确")
	_expect(result.scheduler is Dictionary
		and _same_keys(result.scheduler, SCHEDULER_KEYS), "调度块键集精确")
	_expect(result.suggestion is Dictionary, "建议始终为字典")


func _keys(value: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for key: Variant in value:
		keys.append(str(key))
	keys.sort()
	return keys


func _same_keys(value: Dictionary, expected: Array[String]) -> bool:
	var wanted: Array[String] = expected.duplicate()
	wanted.sort()
	return _keys(value) == wanted


func _all_keys(value: Variant) -> Array[String]:
	var keys: Array[String] = []
	if value is Dictionary:
		for key: Variant in value:
			keys.append(str(key))
			keys.append_array(_all_keys(value[key]))
	elif value is Array:
		for item: Variant in value:
			keys.append_array(_all_keys(item))
	return keys


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
