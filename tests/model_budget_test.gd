extends SceneTree
## M9-04 cloud budget and fallback (pure rules). Headless and isolated: no
## system clock, disk, network, RNG, real vendor or money. Cost units are an
## abstract integer injected by the test; the test calls both modules exactly
## as a future adapter would.

const Budget = preload("res://ai/model_budget.gd")
const Fallback = preload("res://ai/model_fallback.gd")

const START: float = 1800000000.0
const DAY: int = 86400

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_initial_state()
	_test_authorize_and_settle()
	_test_replay_does_not_charge_twice()
	_test_command_conflict()
	_test_named_rejections_leave_state_unchanged()
	_test_cloud_disabled()
	_test_invalid_estimates()
	_test_release_without_charge()
	_test_settle_errors()
	_test_rollover()
	_test_event_log_bounded()
	_test_valid_rejects_malformed()
	_test_snapshot_projection()
	_test_fallback()
	_test_long_run()
	for failure: String in failures:
		push_error(failure)
	print("MODEL_BUDGET_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_initial_state() -> void:
	var state: Dictionary = Budget.initial_state({"period_start_utc": START})
	_expect(Budget.valid(state), "初始文档合法")
	_expect(not state.config.enabled, "云默认关闭")
	_expect(int(state.config.period_seconds) == DAY, "默认周期 24 小时")
	_expect(int(state.config.hard_limit) == 1000, "默认硬上限 1000")
	_expect(int(state.config.request_limit) == 100, "默认单请求上限 100")
	_expect(int(state.config.concurrency_limit) == 2, "默认并发 2")
	_expect(float(state.used.period_start_utc) == START, "周期起点来自调用方")
	_expect(int(state.used.cost) == 0 and int(state.total_cost) == 0, "初始已用为零")
	_expect(state.reservations.is_empty() and state.settled.is_empty(), "初始表为空")
	_expect((state.events as Array).is_empty(), "初始日志为空")
	_expect(Budget.valid_time(Budget.initial_state().used.period_start_utc),
		"默认周期起点为 0")

	_expect(Budget.initial_state({"enabled": true}).config.enabled, "可显式启用云")
	_expect_empty("未知选项失败关闭", Budget.initial_state({"unknown": 1}))
	_expect_empty("负上限拒绝", Budget.initial_state({"hard_limit": -1}))
	_expect_empty("零周期拒绝", Budget.initial_state({"period_seconds": 0}))
	_expect_empty("并发超界拒绝", Budget.initial_state({"concurrency_limit": 65}))
	_expect_empty("小数上限拒绝", Budget.initial_state({"hard_limit": 1.5}))
	_expect_empty("布尔上限拒绝", Budget.initial_state({"hard_limit": true}))
	_expect_empty("非字符串键拒绝", Budget.initial_state({1: 2}))
	_expect_empty("负周期起点拒绝", Budget.initial_state({"period_start_utc": -1.0}))


func _test_authorize_and_settle() -> void:
	var state: Dictionary = _enabled_state()
	var auth: Dictionary = Budget.authorize(state, "req-1", 30, START + 1.0)
	_expect(auth.ok and not auth.duplicate, "首次授权成功")
	_expect(int(auth.estimate) == 30, "授权回显估计值")
	_expect(auth.state.reservations.has("req-1"), "授权写入预留表")
	_expect(int(auth.state.reservations["req-1"].estimate) == 30, "预留记估计值")
	_expect(int(auth.state.used.cost) == 0, "授权不改已用")
	_expect(int(auth.state.total_cost) == 0, "授权不改累计费用")
	var after_auth: Dictionary = auth.state

	var settled: Dictionary = Budget.settle(after_auth, "req-1", 1200, 27, "ok", START + 2.0)
	_expect(settled.ok and not settled.duplicate, "结算成功")
	_expect(int(settled.charged) == 27, "ok 按实际费用计费")
	_expect(int(settled.state.used.cost) == 27, "已用计实际费用")
	_expect(int(settled.state.total_cost) == 27, "累计费用计实际费用")
	_expect(not settled.state.reservations.has("req-1"), "结算释放预留")
	_expect(settled.state.settled.has("req-1"), "结算写入落地表")
	_expect(int(settled.state.settled["req-1"].charged) == 27, "落地表记录实际扣费")
	_expect(int(settled.state.settled["req-1"].actual_usage) == 1200, "落地表记录真实用量")
	_expect(not after_auth.settled.has("req-1"), "结算不改输入文档")

	# 预留占用额度：已用 27 时，另一请求的估计值必须计入剩余空间。
	var roomy: Dictionary = Budget.initial_state({
		"enabled": true, "hard_limit": 200, "request_limit": 100,
		"concurrency_limit": 4, "period_start_utc": START,
	})
	roomy = Budget.authorize(roomy, "req-1", 30, START + 1.0).state
	roomy = Budget.settle(roomy, "req-1", 0, 27, "ok", START + 2.0).state
	var second: Dictionary = Budget.authorize(roomy, "req-2", 80, START + 3.0)
	_expect(second.ok, "剩余额度内授权")
	var third: Dictionary = Budget.authorize(second.state, "req-3", 70, START + 4.0)
	_expect(third.ok, "已预留不计入已用但占用空间")
	# 27 已用 + 80 + 70 预留 = 177，再加 24 越过 200 上限。
	var over: Dictionary = Budget.authorize(third.state, "req-4", 24, START + 5.0)
	_expect(not over.ok and str(over.reason) == "over_budget", "预留与已用合计超限拒绝")

	# 估计值大于实际值只在结算后释放差额。
	var precise: Dictionary = Budget.settle(third.state, "req-2", 10, 10, "ok", START + 6.0)
	_expect(int(precise.state.used.cost) == 37, "多笔 ok 累加实际费用")
	_expect(int(precise.state.total_cost) == 37, "累计费用逐笔相等")

	# 已预留按估计值而非实际值占用额度。
	var small: Dictionary = Budget.initial_state({
		"enabled": true, "hard_limit": 100, "request_limit": 100,
		"concurrency_limit": 4, "period_start_utc": START,
	})
	small = Budget.authorize(small, "a", 60, START + 1.0).state
	small = Budget.settle(small, "a", 0, 10, "ok", START + 2.0).state
	small = Budget.authorize(small, "b", 60, START + 3.0).state
	# 已用 10 + 预留 60 = 70；再要 31 会越过 100。
	var refused: Dictionary = Budget.authorize(small, "c", 31, START + 4.0)
	_expect(not refused.ok and str(refused.reason) == "over_budget",
		"预留按估计值而非实际值占用")


func _test_replay_does_not_charge_twice() -> void:
	var state: Dictionary = _enabled_state()
	state = Budget.authorize(state, "req-1", 20, START + 1.0).state
	state = Budget.settle(state, "req-1", 100, 18, "ok", START + 2.0).state
	var replay_settle: Dictionary = Budget.settle(state, "req-1", 999, 999, "ok", START + 3.0)
	_expect(replay_settle.ok and replay_settle.duplicate, "重复结算返回首次结果")
	_expect(int(replay_settle.charged) == 18, "重复结算不二次计费")
	_expect(int(replay_settle.actual_cost) == 18, "重复结算回放首次实际费用")
	_expect(not replay_settle.has("state"), "重复结算不产生新文档")
	_expect(int(state.used.cost) == 18, "重复结算不改已用")
	_expect(int(state.total_cost) == 18, "重复结算不改累计")

	var replay_auth: Dictionary = Budget.authorize(state, "req-1", 20, START + 4.0)
	_expect(replay_auth.ok and replay_auth.duplicate, "已结算 id 重放授权返回首次结果")
	_expect(int(replay_auth.estimate) == 20, "重放授权回放首次估计值")
	_expect(not replay_auth.has("state"), "重放不产生新文档")

	# 已结算 id 换估计值复用是冲突，不是重放。
	var conflict: Dictionary = Budget.authorize(state, "req-1", 21, START + 5.0)
	_expect(not conflict.ok and str(conflict.reason) == "command_conflict",
		"已结算 id 换估计值拒绝")

	# 预留中的 id 重放同样幂等。
	var held: Dictionary = Budget.authorize(state, "req-2", 5, START + 6.0)
	var held_again: Dictionary = Budget.authorize(held.state, "req-2", 5, START + 7.0)
	_expect(held_again.ok and held_again.duplicate, "预留中 id 重放幂等")
	_expect(not held_again.has("state"), "预留重放不重复预留")
	_expect((held.state.reservations as Dictionary).size() == 1,
		"预留重放不增加表大小")


func _test_command_conflict() -> void:
	var state: Dictionary = _enabled_state()
	var first: Dictionary = Budget.authorize(state, "req-1", 10, START + 1.0)
	var conflict: Dictionary = Budget.authorize(first.state, "req-1", 11, START + 2.0)
	_expect(not conflict.ok and str(conflict.reason) == "command_conflict",
		"同 id 换估计值拒绝")
	_expect(conflict.get("state") == null, "冲突不返回新文档")
	_expect(int(first.state.reservations["req-1"].estimate) == 10, "冲突不改既有预留")


func _test_named_rejections_leave_state_unchanged() -> void:
	# 单请求上限。
	var state: Dictionary = _enabled_state()
	var before: Dictionary = state.duplicate(true)
	var over_cap: Dictionary = Budget.authorize(state, "req-1", 101, START + 1.0)
	_expect(not over_cap.ok and str(over_cap.reason) == "over_request_cap",
		"超单请求上限具名拒绝")
	_expect(state == before, "over_request_cap 不改状态")

	# 周期硬上限（单请求上限内）。
	var tight: Dictionary = Budget.initial_state({
		"enabled": true, "hard_limit": 100, "request_limit": 100,
		"concurrency_limit": 4, "period_start_utc": START,
	})
	tight = Budget.authorize(tight, "req-1", 90, START + 1.0).state
	var before_tight: Dictionary = tight.duplicate(true)
	var over_budget: Dictionary = Budget.authorize(tight, "req-2", 11, START + 2.0)
	_expect(not over_budget.ok and str(over_budget.reason) == "over_budget",
		"超周期硬上限具名拒绝")
	_expect(tight == before_tight, "over_budget 不改状态")
	_expect(not before_tight.has("req-2"), "拒绝不写预留")

	# 并发上限。
	var narrow: Dictionary = Budget.initial_state({
		"enabled": true, "hard_limit": 1000, "request_limit": 100,
		"concurrency_limit": 1, "period_start_utc": START,
	})
	narrow = Budget.authorize(narrow, "req-1", 10, START + 1.0).state
	var before_narrow: Dictionary = narrow.duplicate(true)
	var over_conc: Dictionary = Budget.authorize(narrow, "req-2", 10, START + 2.0)
	_expect(not over_conc.ok and str(over_conc.reason) == "over_concurrency",
		"超并发具名拒绝")
	_expect(narrow == before_narrow, "over_concurrency 不改状态")

	# 已过周期。
	var stale: Dictionary = _enabled_state()
	var elapsed: Dictionary = Budget.authorize(stale, "req-1", 10, START + DAY + 1.0)
	_expect(not elapsed.ok and str(elapsed.reason) == "period_elapsed",
		"未 rollover 的过期周期拒绝授权")
	var early: Dictionary = Budget.authorize(stale, "req-1", 10, START - 1.0)
	_expect(not early.ok and str(early.reason) == "invalid_time", "周期起点前拒绝")


func _test_cloud_disabled() -> void:
	var state: Dictionary = Budget.initial_state({"period_start_utc": START})
	var disabled: Dictionary = Budget.authorize(state, "req-1", 10, START + 1.0)
	_expect(not disabled.ok and str(disabled.reason) == "cloud_disabled",
		"未授权云拒绝")
	_expect(not disabled.has("state"), "拒绝不返回新文档")
	_expect(state.reservations.is_empty(), "拒绝不写预留")
	# 关闭状态下重放已结算 id 仍返回首次结果，便于客户端安全重试。
	var enabled: Dictionary = _enabled_state()
	enabled = Budget.authorize(enabled, "req-1", 10, START + 1.0).state
	enabled = Budget.settle(enabled, "req-1", 5, 3, "ok", START + 2.0).state
	enabled.config.enabled = false
	var replay: Dictionary = Budget.authorize(enabled, "req-1", 10, START + 3.0)
	_expect(replay.ok and replay.duplicate, "关闭后重放已有 id 仍幂等")


func _test_invalid_estimates() -> void:
	var state: Dictionary = _enabled_state()
	for estimate: Variant in [0, -1, 1.5, true, "10", null, 9007199254740992.0]:
		var result: Dictionary = Budget.authorize(state, "req-x", estimate, START + 1.0)
		_expect(not result.ok and str(result.reason) == "invalid_estimate",
			"非法估计值具名拒绝 (%s)" % str(estimate))
	_expect(Budget.authorize(state, 7, 10, START + 1.0).reason == "invalid_request",
		"非字符串 id 拒绝")
	_expect(Budget.authorize(state, "", 10, START + 1.0).reason == "invalid_request",
		"空 id 拒绝")
	_expect(Budget.authorize(state, "x".repeat(129), 10, START + 1.0).reason
		== "invalid_request", "超长 id 拒绝")
	_expect(Budget.authorize(state, "req-1", 10, -1.0).reason == "invalid_time",
		"负时间拒绝")
	_expect(Budget.authorize({}, "req-1", 10, START).reason == "invalid_state",
		"畸形文档拒绝")


func _test_release_without_charge() -> void:
	for outcome: String in ["failed", "timeout", "offline", "cancelled"]:
		var state: Dictionary = _enabled_state()
		state = Budget.authorize(state, "req-1", 40, START + 1.0).state
		var result: Dictionary = Budget.settle(state, "req-1", 300, 35, outcome, START + 2.0)
		_expect(result.ok, "%s 结算成功" % outcome)
		_expect(int(result.charged) == 0, "%s 不扣费" % outcome)
		_expect(int(result.state.used.cost) == 0, "%s 不增加已用" % outcome)
		_expect(int(result.state.total_cost) == 0, "%s 不增加累计" % outcome)
		_expect(not result.state.reservations.has("req-1"), "%s 释放预留" % outcome)
		_expect(int(result.state.settled["req-1"].actual_cost) == 35,
			"%s 保留报告的供应商费用供对账" % outcome)
		_expect(int(result.state.settled["req-1"].charged) == 0,
			"%s 落地表扣费为零" % outcome)
		# 释放后可再授权，额度没有被失败请求吞掉。
		var next: Dictionary = Budget.authorize(result.state, "req-2", 40, START + 3.0)
		_expect(next.ok, "%s 释放后额度可用" % outcome)

	# 混合：先失败后成功，只有成功计费。
	var mixed: Dictionary = _enabled_state()
	mixed = Budget.authorize(mixed, "fail", 20, START + 1.0).state
	mixed = Budget.settle(mixed, "fail", 0, 20, "timeout", START + 2.0).state
	mixed = Budget.authorize(mixed, "ok", 20, START + 3.0).state
	mixed = Budget.settle(mixed, "ok", 50, 12, "ok", START + 4.0).state
	_expect(int(mixed.used.cost) == 12 and int(mixed.total_cost) == 12,
		"超时退款后成功请求只计一次")


func _test_settle_errors() -> void:
	var state: Dictionary = _enabled_state()
	var unknown: Dictionary = Budget.settle(state, "never", 0, 0, "ok", START + 1.0)
	_expect(not unknown.ok and str(unknown.reason) == "unknown_request",
		"结算未授权 id 拒绝")
	state = Budget.authorize(state, "req-1", 10, START + 1.0).state
	var bad_outcome: Dictionary = Budget.settle(state, "req-1", 0, 0, "success", START + 2.0)
	_expect(not bad_outcome.ok and str(bad_outcome.reason) == "invalid_outcome",
		"未知结果枚举拒绝")
	var bad_usage: Dictionary = Budget.settle(state, "req-1", -1, 0, "ok", START + 2.0)
	_expect(not bad_usage.ok and str(bad_usage.reason) == "invalid_usage",
		"负用量拒绝")
	var fractional: Dictionary = Budget.settle(state, "req-1", 1.5, 1, "ok", START + 2.0)
	_expect(not fractional.ok and str(fractional.reason) == "invalid_usage",
		"小数用量拒绝")
	var bad_time: Dictionary = Budget.settle(state, "req-1", 1, 1, "ok", START - 1.0)
	_expect(not bad_time.ok and str(bad_time.reason) == "invalid_time",
		"早于预留时刻拒绝")
	var late_period: Dictionary = Budget.settle(state, "req-1", 1, 1, "ok", START + DAY)
	_expect(not late_period.ok and str(late_period.reason) == "period_elapsed",
		"关闭周期必须先 rollover 才能结算")
	_expect(state.reservations.has("req-1"), "错误结算保留预留")


func _test_rollover() -> void:
	var state: Dictionary = _enabled_state()
	state = Budget.authorize(state, "done", 30, START + 1.0).state
	state = Budget.settle(state, "done", 0, 25, "ok", START + 2.0).state
	# 跨周期保留的未结算预留。
	state = Budget.authorize(state, "carried", 40, START + 3.0).state
	_expect(int(state.used.cost) == 25, "切换前已用 25")

	var same: Dictionary = Budget.rollover(state, START + 10.0)
	_expect(same.ok and int(same.periods) == 0, "周期内 rollover 无操作")
	_expect(same.get("state") == null, "无操作不产生新文档")

	var rolled: Dictionary = Budget.rollover(state, START + DAY + 5.0)
	_expect(rolled.ok and int(rolled.periods) == 1, "跨一个周期切换")
	_expect(int(rolled.state.used.cost) == 0, "周期切换清零已用")
	_expect(float(rolled.state.used.period_start_utc) == START + float(DAY),
		"周期起点按整周期推进")
	_expect(rolled.state.reservations.has("carried"), "未结算预留跨周期保留")
	_expect(float(rolled.state.reservations["carried"].period_start_utc) == START,
		"预留记住所属周期")
	_expect(int(rolled.state.total_cost) == 25, "累计费用跨周期不清零")
	_expect(int(rolled.state.settled.size()) == 1, "落地表跨周期保留")

	# 跨周期预留结算计入新周期已用，但落地行仍可追溯。
	var late: Dictionary = Budget.settle(rolled.state, "carried", 0, 40, "ok", START + DAY + 6.0)
	_expect(late.ok and int(late.state.used.cost) == 40,
		"跨周期预留按实际费用计入当前周期")
	_expect(float(late.state.settled["carried"].at_utc) == START + DAY + 6.0,
		"落地行记录真实结算时刻")
	_expect(int(late.state.total_cost) == 65, "累计费用继续累加")

	# 多个整周期一次跳过。
	var multi: Dictionary = Budget.rollover(state, START + float(DAY * 3) + 1.0)
	_expect(multi.ok and int(multi.periods) == 3, "一次跨三个周期")
	_expect(float(multi.state.used.period_start_utc) == START + float(DAY * 3),
		"多周期推进到最近整周期")
	_expect(multi.state.reservations.has("carried"), "多周期切换也保留预留")

	# 跨周期后旧预留仍占新周期并发与额度。
	var tight: Dictionary = Budget.initial_state({
		"enabled": true, "hard_limit": 50, "request_limit": 50,
		"concurrency_limit": 1, "period_start_utc": START,
	})
	tight = Budget.authorize(tight, "held", 50, START + 1.0).state
	tight = Budget.rollover(tight, START + DAY + 1.0).state
	var blocked: Dictionary = Budget.authorize(tight, "next", 1, START + DAY + 2.0)
	_expect(not blocked.ok and (str(blocked.reason) == "over_concurrency"
		or str(blocked.reason) == "over_budget"), "跨周期预留不被吞掉")
	_expect(tight.reservations.has("held"), "跨周期预留仍在表内")

	_expect(Budget.rollover(state, START - 1.0).reason == "invalid_time",
		"回退时间拒绝 rollover")
	_expect(Budget.rollover({}, START).reason == "invalid_state", "畸形文档拒绝 rollover")


func _test_event_log_bounded() -> void:
	var state: Dictionary = _enabled_state()
	for index: int in 400:
		var rid: String = "req-%d" % index
		state = Budget.authorize(state, rid, 1, START + float(index) * 0.01).state
		state = Budget.settle(state, rid, 0, 1, "ok", START + float(index) * 0.01 + 0.005).state
	_expect((state.events as Array).size() == Budget.MAX_EVENTS,
		"事件日志达到上限后不再增长")
	_expect(Budget.valid(state), "长跑后文档仍然合法")
	var last: Dictionary = state.events[state.events.size() - 1]
	_expect(str(last.kind) == "settle" and str(last.request_id) == "req-399",
		"淘汰最旧、保留最新事件")
	var first: Dictionary = state.events[0]
	_expect(str(first.request_id) != "req-0", "最旧事件已被淘汰")

	# 时间非单调时仍按时刻淘汰最旧，而不是按插入顺序。
	var skewed: Dictionary = Budget.initial_state({
		"enabled": true, "hard_limit": 1000, "request_limit": 100,
		"concurrency_limit": 2, "period_start_utc": START,
	})
	skewed = Budget.authorize(skewed, "newest", 1, START + 100.0).state
	skewed = Budget.settle(skewed, "newest", 0, 1, "ok", START + 101.0).state
	for index: int in 300:
		skewed = Budget.authorize(skewed, "old-%d" % index, 1, START + float(10 + index % 5)).state
		skewed = Budget.settle(skewed, "old-%d" % index, 0, 1, "ok",
			START + float(10 + index % 5) + 0.1).state
	_expect((skewed.events as Array).size() == Budget.MAX_EVENTS, "乱序日志仍有界")
	var kept: Dictionary = {}
	for event: Variant in skewed.events:
		kept[str((event as Dictionary).request_id)] = true
	_expect(not kept.has("old-0"), "较晚插入但时刻更早的事件被淘汰")
	_expect(kept.has("settle") or kept.has("newest"), "时刻最新的事件保留")
	var newest_time: float = 0.0
	for event: Variant in skewed.events:
		newest_time = maxf(newest_time, float((event as Dictionary).at_utc))
	_expect(newest_time == START + 101.0, "最新时刻事件保留")

	# 落地重放窗口也按时刻淘汰。
	var settle_skew: Dictionary = _enabled_state()
	settle_skew = Budget.authorize(settle_skew, "keep", 1, START + 1.0).state
	settle_skew = Budget.settle(settle_skew, "keep", 0, 1, "ok", START + 200.0).state
	for index: int in 300:
		settle_skew = Budget.authorize(settle_skew, "s-%d" % index, 1, START + 2.0).state
		settle_skew = Budget.settle(settle_skew, "s-%d" % index, 0, 1, "ok", START + 2.0).state
	_expect((settle_skew.settled as Dictionary).size() == Budget.MAX_SETTLED,
		"落地表有界")
	_expect(settle_skew.settled.has("keep"), "落地表按时刻保留最新")


func _test_valid_rejects_malformed() -> void:
	var good: Dictionary = _enabled_state()
	_expect(Budget.valid(good), "基线文档合法")

	var missing: Dictionary = good.duplicate(true)
	missing.erase("events")
	_expect(not Budget.valid(missing), "缺键拒绝")

	var extra: Dictionary = good.duplicate(true)
	extra["note"] = 1
	_expect(not Budget.valid(extra), "多键拒绝")

	var negative: Dictionary = good.duplicate(true)
	negative.used.cost = -1
	_expect(not Budget.valid(negative), "负数已用拒绝")

	var fractional: Dictionary = good.duplicate(true)
	fractional.total_cost = 0.5
	_expect(not Budget.valid(fractional), "小数累计拒绝")

	var too_big: Dictionary = good.duplicate(true)
	too_big.config.hard_limit = 9007199254740992
	_expect(not Budget.valid(too_big), "超安全整数拒绝")

	var bad_enabled: Dictionary = good.duplicate(true)
	bad_enabled.config.enabled = 1
	_expect(not Budget.valid(bad_enabled), "非布尔开关拒绝")

	var bad_period: Dictionary = good.duplicate(true)
	bad_period.config.period_seconds = 0
	_expect(not Budget.valid(bad_period), "零周期拒绝")

	var bad_conc: Dictionary = good.duplicate(true)
	bad_conc.config.concurrency_limit = 0
	_expect(not Budget.valid(bad_conc), "零并发拒绝")

	var too_many_events: Dictionary = good.duplicate(true)
	for index: int in 257:
		too_many_events.events.append({
			"at_utc": START, "kind": "rollover", "request_id": "",
			"reason": "", "amount": 0,
		})
	_expect(not Budget.valid(too_many_events), "事件日志超上限拒绝")

	var bad_event: Dictionary = good.duplicate(true)
	bad_event.events.append({
		"at_utc": START, "kind": "authorize", "request_id": "",
		"reason": "", "amount": 1,
	})
	_expect(not Budget.valid(bad_event), "authorize 事件缺 id 拒绝")

	var bad_charged: Dictionary = good.duplicate(true)
	bad_charged.settled["x"] = {
		"estimate": 1, "outcome": "timeout", "actual_usage": 1,
		"actual_cost": 5, "charged": 5, "at_utc": START,
	}
	_expect(not Budget.valid(bad_charged), "非 ok 结果扣费拒绝")

	var both: Dictionary = good.duplicate(true)
	both.reservations["x"] = {
		"estimate": 1, "period_start_utc": START, "created_utc": START,
	}
	both.settled["x"] = {
		"estimate": 1, "outcome": "ok", "actual_usage": 0,
		"actual_cost": 1, "charged": 1, "at_utc": START,
	}
	_expect(not Budget.valid(both), "同一 id 不能既预留又结算")

	var over_estimate: Dictionary = good.duplicate(true)
	over_estimate.reservations["x"] = {
		"estimate": 101, "period_start_utc": START, "created_utc": START,
	}
	_expect(not Budget.valid(over_estimate), "预留估计值超单请求上限拒绝")

	var over_concurrency: Dictionary = good.duplicate(true)
	for index: int in 3:
		over_concurrency.reservations["r%d" % index] = {
			"estimate": 1, "period_start_utc": START, "created_utc": START,
		}
	_expect(not Budget.valid(over_concurrency), "预留数超并发上限拒绝")

	var future_period: Dictionary = good.duplicate(true)
	future_period.reservations["x"] = {
		"estimate": 1, "period_start_utc": START + 1.0, "created_utc": START + 1.0,
	}
	_expect(not Budget.valid(future_period), "预留周期晚于当前周期拒绝")

	var under_total: Dictionary = good.duplicate(true)
	under_total.used.cost = 5
	under_total.total_cost = 4
	_expect(not Budget.valid(under_total), "累计费用小于周期已用拒绝")

	_expect(not Budget.valid([]), "非字典拒绝")
	_expect(not Budget.valid(null), "null 拒绝")


func _test_snapshot_projection() -> void:
	var invalid: Dictionary = Budget.snapshot({})
	_expect(not invalid.valid and int(invalid.remaining) == 0, "畸形文档快照失败关闭")

	var state: Dictionary = _enabled_state()
	state = Budget.authorize(state, "req-1", 30, START + 1.0).state
	state = Budget.settle(state, "req-1", 0, 20, "ok", START + 2.0).state
	state = Budget.authorize(state, "req-2", 10, START + 3.0).state
	var snap: Dictionary = Budget.snapshot(state)
	_expect(snap.valid and snap.enabled, "快照有效且反映开关")
	_expect(int(snap.hard_limit) == 1000 and int(snap.request_limit) == 100,
		"快照带配置")
	_expect(int(snap.used) == 20 and int(snap.reserved) == 10, "快照区分已用与预留")
	_expect(int(snap.remaining) == 970, "快照剩余 = 上限 - 已用 - 预留")
	_expect(int(snap.concurrency_used) == 1, "快照并发占用")
	_expect(int(snap.total_cost) == 20, "快照累计费用")
	_expect(float(snap.period_end_utc) == START + float(DAY), "快照周期终点")
	_expect((snap.events as Array).size() == 3, "快照带最近事件")
	_expect(snap.events[2].kind == "authorize", "快照事件按发生顺序")
	# 快照是副本，改它不影响文档。
	snap.events[0]["amount"] = 999
	_expect(int(state.events[0].amount) == 30, "快照事件是副本")


func _test_fallback() -> void:
	var disabled: Dictionary = Budget.initial_state({"period_start_utc": START})
	var off: Dictionary = Fallback.choose_backend(disabled, START + 1.0, true, true)
	_expect(off.backend == "rules" and off.reason == "cloud_disabled",
		"未启用云回退规则")

	var enabled: Dictionary = _enabled_state()
	var offline: Dictionary = Fallback.choose_backend(enabled, START + 1.0, false, false)
	_expect(offline.backend == "rules" and offline.reason == "cloud_unavailable",
		"断网且无本地回退规则")
	var offline_local: Dictionary = Fallback.choose_backend(enabled, START + 1.0, false, true)
	_expect(offline_local.backend == "local" and offline_local.reason == "cloud_unavailable",
		"断网有本地回退本地")

	# 预算耗尽：已用 + 预留达到上限。
	var spent: Dictionary = Budget.initial_state({
		"enabled": true, "hard_limit": 100, "request_limit": 100,
		"concurrency_limit": 4, "period_start_utc": START,
	})
	spent = Budget.authorize(spent, "req-1", 100, START + 1.0).state
	var no_room: Dictionary = Fallback.choose_backend(spent, START + 2.0, true, false)
	_expect(no_room.backend == "rules" and no_room.reason == "budget_exhausted",
		"额度耗尽回退规则")
	var no_room_local: Dictionary = Fallback.choose_backend(spent, START + 2.0, true, true)
	_expect(no_room_local.backend == "local" and no_room_local.reason == "budget_exhausted",
		"额度耗尽回退本地")

	# 并发占满但还有额度。
	var full: Dictionary = Budget.initial_state({
		"enabled": true, "hard_limit": 1000, "request_limit": 100,
		"concurrency_limit": 1, "period_start_utc": START,
	})
	full = Budget.authorize(full, "req-1", 1, START + 1.0).state
	var full_choice: Dictionary = Fallback.choose_backend(full, START + 2.0, true, true)
	_expect(full_choice.backend == "local" and full_choice.reason == "concurrency_full",
		"并发占满回退本地")

	var normal: Dictionary = Fallback.choose_backend(enabled, START + 1.0, true, true)
	_expect(normal.backend == "cloud" and normal.reason == "", "正常走云端")
	var normal_rules: Dictionary = Fallback.choose_backend(enabled, START + 1.0, true, false)
	_expect(normal_rules.backend == "cloud", "本地不可用不影响云端")

	var elapsed: Dictionary = Fallback.choose_backend(enabled, START + DAY + 1.0, true, true)
	_expect(elapsed.backend == "local" and elapsed.reason == "period_elapsed",
		"过期周期先回退")
	_expect(Fallback.choose_backend({}, START, true, true).reason == "invalid_state",
		"畸形文档回退规则")
	_expect(Fallback.choose_backend(enabled, -1.0, true, true).reason == "invalid_time",
		"非法时间回退规则")
	_expect(Fallback.choose_backend(disabled, START, false, true).backend == "rules",
		"未启用云优先于断网")

	# 确定性：同一输入多次一致。
	for index: int in 20:
		var again: Dictionary = Fallback.choose_backend(enabled, START + 1.0, true, true)
		_expect(again == normal, "回退选择确定性")


func _test_long_run() -> void:
	var state: Dictionary = Budget.initial_state({
		"enabled": true, "hard_limit": 1000000000, "request_limit": 1000,
		"concurrency_limit": 4, "period_start_utc": START,
	})
	var expected: int = 0
	var peak_reservations: int = 0
	var peak_events: int = 0
	var peak_settled: int = 0
	var periods: int = 0
	for index: int in 1000:
		var rid: String = "loop-%d" % index
		var estimate: int = 1 + index % 50
		var actual: int = 1 + index % 7
		# About four days across 1000 steps, so rollover runs several times.
		var at: float = START + float(index) * 345.6
		var rolled: Dictionary = Budget.rollover(state, at)
		if not rolled.ok:
			_expect(false, "长跑 rollover 失败 %s" % str(rolled.reason))
			break
		if rolled.has("state"):
			state = rolled.state
		periods += int(rolled.periods)
		var auth: Dictionary = Budget.authorize(state, rid, estimate, at)
		if not auth.ok:
			_expect(false, "长跑授权失败 %s" % str(auth.reason))
			break
		state = auth.state
		var outcome: String = "ok" if index % 5 != 0 else "timeout"
		var result: Dictionary = Budget.settle(state, rid, actual * 100, actual, outcome, at + 0.1)
		if not result.ok:
			_expect(false, "长跑结算失败 %s" % str(result.reason))
			break
		state = result.state
		if outcome == "ok":
			expected += actual
		peak_reservations = maxi(peak_reservations, (state.reservations as Dictionary).size())
		peak_events = maxi(peak_events, (state.events as Array).size())
		peak_settled = maxi(peak_settled, (state.settled as Dictionary).size())
	_expect(periods >= 3, "长跑确实跨过多个周期 (%d)" % periods)
	_expect(Budget.valid(state), "1000 次循环后文档合法")
	_expect(int(state.total_cost) == expected,
		"累计费用精确等于逐条 ok 费用之和 (%d)" % expected)
	_expect(int(state.used.cost) <= expected, "周期已用不超过累计")
	_expect((state.events as Array).size() <= Budget.MAX_EVENTS, "日志有界")
	_expect(peak_events <= Budget.MAX_EVENTS, "日志峰值有界")
	_expect((state.settled as Dictionary).size() <= Budget.MAX_SETTLED, "落地表有界")
	_expect(peak_settled <= Budget.MAX_SETTLED, "落地表峰值有界")
	_expect((state.reservations as Dictionary).size() <= 4, "预留表受并发限制")
	_expect(peak_reservations <= 4, "预留峰值受并发限制")

	# 长跑后仍可授权。
	var fresh: Dictionary = Budget.authorize(state, "loop-final", 10,
		float(state.used.period_start_utc) + 0.5)
	_expect(fresh.ok, "长跑后仍可授权")


# ---------------------------------------------------------------- helpers

func _enabled_state() -> Dictionary:
	return Budget.initial_state({
		"enabled": true, "hard_limit": 1000, "request_limit": 100,
		"concurrency_limit": 2, "period_start_utc": START,
	})


func _expect_empty(message: String, value: Dictionary) -> void:
	_expect(value.is_empty(), message)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
