extends SceneTree
## M12-01 单位持续现金工资：纯规则无头测试。无场景、无时钟、无随机数、无网络、
## 无存档文档；每条工资结算都显式传入现金总量与 UTC 时间。最后一行是验证证据。

const Units = preload("res://conflict/unit_state.gd")

const START: float = 1800000000.0
const DAY: float = 86400.0
const WORLD: String = "world-wages-a"
const OWNER_A: String = "player_wages_owner_a"
const OWNER_B: String = "player_wages_owner_b"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_initial_fields()
	_test_pay_in_order()
	_test_partial_payment()
	_test_unpaid_capability()
	_test_idempotency()
	_test_multi_day()
	_test_time_regression()
	_test_invalid_inputs()
	_test_document_validation()
	_test_copy_on_write()
	_test_determinism()
	for failure: String in failures:
		push_error(failure)
	print("UNIT_STATE_WAGES_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_initial_fields() -> void:
	var recruited: Dictionary = _recruit(Units.initial_state(WORLD), "unit_a01",
		OWNER_A, "militia", 100, "none", "station_a", START)
	_expect(recruited.ok, "工资测试夹具招募成功")
	var row: Dictionary = recruited.state["units"]["unit_a01"]
	_expect(int(row["unpaid_days"]) == 0, "新单位没有欠付")
	_expect(float(row["last_wage_utc"]) == START, "工资时钟从招募时刻开始")
	_expect(Units.valid(recruited.state), "带工资字段的名册有效")
	var round: Variant = JSON.parse_string(JSON.stringify(recruited.state))
	_expect(round is Dictionary and Units.valid(round), "工资字段 JSON 往返仍有效")
	var power: Dictionary = Units.capability(recruited.state, "unit_a01")
	_expect(power.unpaid_days == 0 and power.penalty_bps == 10000,
		"新单位查询战力带欠付天数与无惩罚")


func _test_pay_in_order() -> void:
	var state: Dictionary = _two_units()
	var before: String = JSON.stringify(state)
	var result: Dictionary = Units.pay_wages(state, 20, START + DAY)
	_expect(result.ok and result.status == "paid", "现金充足时工资足额支付")
	_expect(result.settled_this_tick == false, "新时刻不是同刻回放")
	_expect(result.required == 20 and result.paid == 20 and result.unpaid == 0,
		"两支单位一天工资合计正确")
	_expect(JSON.stringify(state) == before, "工资结算不修改输入文档")
	_expect(Units.valid(result.state), "工资结算后的文档有效")
	_expect(result.state["sequence"] == int(state["sequence"]) + 1,
		"工资结算推进序列")
	_expect(result.state["last_upkeep_utc"] == state["last_upkeep_utc"],
		"工资结算不推进粮草时刻")
	var settlements: Array = result.settlements
	_expect(settlements.size() == 2, "工资结算为每支单位给出明细")
	_expect(settlements[0].unit_id == "unit_a01" and settlements[1].unit_id == "unit_a02",
		"工资明细按 unit id 升序")
	_expect(settlements[0].required == 10 and settlements[0].paid == 10,
		"民兵每人每日一份现金")
	_expect(settlements[1].required == 10 and settlements[1].paid == 10,
		"护卫每人每日两份现金")
	for unit_id: String in ["unit_a01", "unit_a02"]:
		var row: Dictionary = result.state["units"][unit_id]
		_expect(float(row["last_wage_utc"]) == START + DAY,
			"工资时钟推进一天 " + unit_id)
		_expect(int(row["unpaid_days"]) == 0, "足额支付后欠付为零 " + unit_id)
	_expect(result.affected.is_empty(), "足额支付没有受影响单位")


func _test_partial_payment() -> void:
	var state: Dictionary = _two_units()
	var power_before: int = Units.capability(state, "unit_a02").power
	var result: Dictionary = Units.pay_wages(state, 10, START + DAY)
	_expect(result.ok and result.status == "unpaid", "现金不足时标记欠付")
	_expect(result.required == 20 and result.paid == 10 and result.unpaid == 10,
		"只付到可用数量为止")
	_expect(result.affected.size() == 1, "只记录实际欠付的单位")
	_expect(result.affected[0].unit_id == "unit_a02",
		"按 id 升序先付前一单位，后一单位承担缺口")
	_expect(int(result.state["units"]["unit_a01"]["unpaid_days"]) == 0,
		"前一单位足额支付不欠付")
	_expect(int(result.state["units"]["unit_a02"]["unpaid_days"]) == 1,
		"后一单位累计欠付一天")
	var power_after: int = Units.capability(result.state, "unit_a02").power
	_expect(power_after < power_before, "欠付后战力明确下降")
	_expect(Units.capability(result.state, "unit_a02").penalty_bps == 7500,
		"欠付一天复用同一份 25% 惩罚")
	_expect(Units.capability(result.state, "unit_a01").power
		== Units.capability(state, "unit_a01").power,
		"足额支付的单位战力不变")

	var recovered: Dictionary = Units.pay_wages(result.state, 100, START + 2.0 * DAY)
	_expect(recovered.ok and recovered.status == "paid", "下一 tick 现金充足")
	_expect(int(recovered.state["units"]["unit_a02"]["unpaid_days"]) == 0,
		"足额支付清除欠付天数")
	_expect(Units.capability(recovered.state, "unit_a02").power == power_before,
		"补付后战力恢复")


func _test_unpaid_capability() -> void:
	var short: Dictionary = Units.pay_wages(_two_units(), 0, START + DAY)
	_expect(short.ok and short.status == "unpaid", "零现金时仍结算欠付")
	_expect(short.paid == 0 and short.unpaid == 20, "零现金全部记为欠付")
	_expect(Units.capability(short.state, "unit_a01").power == 75,
		"民兵欠付一天战力按 25% 惩罚下降")
	_expect(Units.capability(short.state, "unit_a02").power == 67,
		"护卫欠付一天战力向下取整")
	var once: Dictionary = Units.pay_wages(short.state, 0, START + 2.0 * DAY)
	_expect(Units.capability(once.state, "unit_a01").penalty_bps == 5000,
		"连续欠付两天惩罚累加")
	var twice: Dictionary = Units.pay_wages(once.state, 0, START + 3.0 * DAY)
	var thrice: Dictionary = Units.pay_wages(twice.state, 0, START + 4.0 * DAY)
	_expect(Units.capability(thrice.state, "unit_a01").penalty_bps == 2500,
		"欠付惩罚封顶 75%（保留 25% 系数）")

	# 欠供与欠付共用一份惩罚：一天欠供加一天欠付等于两天短缺。
	var fed: Dictionary = Units.upkeep(once.state, _stock(0, 5), START + 2.0 * DAY)
	_expect(fed.ok and fed.status == "shortfall", "欠付夹具再产生一天欠供")
	var row: Dictionary = fed.state["units"]["unit_a01"]
	_expect(int(row["unfed_days"]) == 1 and int(row["unpaid_days"]) == 2,
		"单位分别记录欠供与欠付天数")
	var combined: Dictionary = Units.capability(fed.state, "unit_a01")
	_expect(combined.penalty_bps == 2500, "两种短缺合计三天，共用同一惩罚公式")
	_expect(combined.power == 10 * int(row["people"]) * 10000 * 2500 / 100000000,
		"合计短缺按同一战力公式派生")


func _test_idempotency() -> void:
	var paid: Dictionary = Units.pay_wages(_two_units(), 100, START + DAY)
	_expect(paid.ok and paid.status == "paid", "幂等夹具首次支付成功")
	var before: String = JSON.stringify(paid.state)
	var same: Dictionary = Units.pay_wages(paid.state, 0, START + DAY)
	_expect(same.ok and same.status == "settled_this_tick",
		"同一时刻重复结算返回 settled_this_tick")
	_expect(same.settled_this_tick, "同刻标记为已结算")
	_expect(same.paid == 0 and same.unpaid == 0 and same.settlements.is_empty(),
		"同刻重复结算不扣现金、不新增欠付")
	_expect(JSON.stringify(paid.state) == before, "同刻重复结算不修改输入")
	_expect(JSON.stringify(same.state) == before, "同刻重复结算返回原文档")

	var empty: Dictionary = Units.pay_wages(Units.initial_state(WORLD), 100, START)
	_expect(empty.ok and empty.status == "settled_this_tick",
		"空名册没有工资可结")


func _test_multi_day() -> void:
	var state: Dictionary = _two_units()
	var result: Dictionary = Units.pay_wages(state, 1000, START + 3.0 * DAY)
	_expect(result.ok and result.status == "paid", "跨多日一次结算成功")
	_expect(result.required == 60 and result.paid == 60,
		"三天工资按每日工资与天数计算")
	_expect(result.settlements[0].days == 3, "明细记录整日数")
	_expect(float(result.state["units"]["unit_a01"]["last_wage_utc"])
		== START + 3.0 * DAY, "工资时钟按整日推进")

	var half: Dictionary = Units.pay_wages(state, 1000, START + DAY + 43200.0)
	_expect(half.ok and half.required == 20, "不足整日不额外计工资")
	_expect(float(half.state["units"]["unit_a01"]["last_wage_utc"]) == START + DAY,
		"工资时钟只推进整日，余量保留")
	var later: Dictionary = Units.pay_wages(half.state, 1000, START + DAY + 43200.0)
	_expect(later.ok and later.status == "settled_this_tick",
		"同一半日重复结算不再计工资")

	var ancient: Dictionary = Units.pay_wages(state, 0,
		START + float(Units.MAX_UNPAID_DAYS + 10) * DAY)
	_expect(ancient.ok and Units.valid(ancient.state),
		"超长欠付候选文档仍通过严格校验")
	_expect(int(ancient.state["units"]["unit_a01"]["unpaid_days"])
		== Units.MAX_UNPAID_DAYS, "欠付天数封顶在文档上限")


func _test_time_regression() -> void:
	var state: Dictionary = _two_units()
	var early: Dictionary = Units.pay_wages(state, 100, START - 1.0)
	_expect(not early.ok and early.reason == "time_regression",
		"工资时间倒退被拒")
	_expect(early.has("state") == false, "时间倒退不返回候选文档")

	var late: Dictionary = _recruit(state, "unit_a03", OWNER_B, "militia", 1, "none",
		"station_c", START + DAY)
	_expect(late.ok, "可以在更晚时刻招募另一支单位")
	var mixed: Dictionary = Units.pay_wages(late.state, 100, START)
	_expect(not mixed.ok and mixed.reason == "time_regression",
		"任一单位工资时钟晚于结算时刻都整批拒绝")


func _test_invalid_inputs() -> void:
	var state: Dictionary = _two_units()
	_expect(Units.pay_wages({}, 100, START + DAY).reason == "invalid_state",
		"非法文档不能结算工资")
	_expect(Units.pay_wages(state, 100, -1.0).reason == "invalid_time",
		"负工资时刻被拒")
	_expect(Units.pay_wages(state, 100, INF).reason == "invalid_time",
		"非有限工资时刻被拒")
	for cash: Variant in [-1, 1.5, "100", null, INF]:
		_expect(Units.pay_wages(state, cash, START + DAY).reason == "invalid_cash",
			"非法现金总量 %s 被拒" % str(cash))
	var refused: Dictionary = Units.pay_wages(state, -1, START + DAY)
	_expect(refused.has("state") == false, "非法现金不返回候选文档")


func _test_document_validation() -> void:
	var state: Dictionary = _two_units()
	_expect(Units.valid(state), "工资校验夹具文档有效")
	for field: String in ["unpaid_days", "last_wage_utc"]:
		var missing: Dictionary = state.duplicate(true)
		missing["units"]["unit_a01"].erase(field)
		_expect(not Units.valid(missing), "缺工资字段 %s 的单位行无效" % field)
	var negative: Dictionary = state.duplicate(true)
	negative["units"]["unit_a01"]["unpaid_days"] = -1
	_expect(not Units.valid(negative), "负欠付天数的单位行无效")
	var fractional: Dictionary = state.duplicate(true)
	fractional["units"]["unit_a01"]["unpaid_days"] = 1.5
	_expect(not Units.valid(fractional), "小数欠付天数的单位行无效")
	var overflow: Dictionary = state.duplicate(true)
	overflow["units"]["unit_a01"]["unpaid_days"] = Units.MAX_UNPAID_DAYS + 1
	_expect(not Units.valid(overflow), "超过欠付天数上限的单位行无效")
	var bad_stamp: Dictionary = state.duplicate(true)
	bad_stamp["units"]["unit_a01"]["last_wage_utc"] = -1.0
	_expect(not Units.valid(bad_stamp), "负工资时钟的单位行无效")
	var past_recruit: Dictionary = state.duplicate(true)
	past_recruit["units"]["unit_a01"]["last_wage_utc"] = START - 1.0
	_expect(not Units.valid(past_recruit), "工资时钟早于招募时刻的单位行无效")
	var null_stamp: Dictionary = state.duplicate(true)
	null_stamp["units"]["unit_a01"]["last_wage_utc"] = null
	_expect(not Units.valid(null_stamp), "非数字工资时钟的单位行无效")


func _test_copy_on_write() -> void:
	var state: Dictionary = _two_units()
	var before: String = JSON.stringify(state)
	var failed: Dictionary = Units.pay_wages(state, -1, START + DAY)
	_expect(not failed.ok and JSON.stringify(state) == before,
		"失败路径逐字节不修改输入")
	var paid: Dictionary = Units.pay_wages(state, 10, START + DAY)
	_expect(paid.ok and JSON.stringify(state) == before, "成功路径也不修改输入")
	_expect(int(state["units"]["unit_a02"]["unpaid_days"]) == 0,
		"输入文档不写入欠付天数")


func _test_determinism() -> void:
	var left: Dictionary = Units.pay_wages(_two_units(), 10, START + DAY)
	var right: Dictionary = Units.pay_wages(_two_units(), 10, START + DAY)
	_expect(JSON.stringify(left) == JSON.stringify(right),
		"同一工资输入得到逐字节相同结果")
	_expect(left.state == right.state and left.settlements == right.settlements,
		"确定性覆盖候选文档与明细")


func _two_units() -> Dictionary:
	var state: Dictionary = Units.initial_state(WORLD)
	state = _recruit(state, "unit_a01", OWNER_A, "militia", 10, "none", "station_a",
		START).state
	return _recruit(state, "unit_a02", OWNER_B, "guard", 5, "none", "station_b",
		START).state


func _recruit(state: Dictionary, unit_id: String, owner: String, kind: String,
		people: int, equipment: String, station: String, now: float) -> Dictionary:
	return Units.recruit(state, _stock(), {
		"id": unit_id,
		"owner": owner,
		"kind": kind,
		"people": people,
		"equipment": equipment,
		"station": station,
	}, now)


func _stock(cash: int = 1000000, supplies: int = 1000000) -> Dictionary:
	return {"cash": cash, "supplies": supplies}


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
