extends SceneTree
## M12-01 单位与补给：纯规则无头测试。无场景、无时钟、无随机数、无网络、
## 无存档文档；每条命令都显式传入 UTC 时间。最后一行是验证证据。

const Units = preload("res://conflict/unit_state.gd")

const START: float = 1800000000.0
const DAY: float = 86400.0
const WORLD: String = "world-units-a"
const OWNER_A: String = "player_units_owner_a"
const OWNER_B: String = "player_units_owner_b"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_empty_and_json()
	_test_recruit()
	_test_recruit_errors()
	_test_recruit_limits()
	_test_recruit_idempotency()
	_test_upkeep_fed()
	_test_upkeep_shortfall()
	_test_upkeep_order()
	_test_upkeep_tick()
	_test_disband()
	_test_copy_on_write()
	_test_document_validation()
	_test_determinism()
	for failure: String in failures:
		push_error(failure)
	print("UNIT_STATE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_empty_and_json() -> void:
	var state: Dictionary = Units.initial_state(WORLD)
	_expect(Units.valid(state), "空文档合法")
	_expect(state["last_upkeep_utc"] == -1.0, "新文档尚未结算补给")
	_expect(state["units"].is_empty() and state["commands"].is_empty(),
		"新文档没有单位与命令记录")
	var round: Variant = JSON.parse_string(JSON.stringify(state))
	_expect(round is Dictionary and Units.valid(round), "空文档 JSON 往返仍有效")
	_expect(Units.capability(state, "unit_missing").reason == "unknown_unit",
		"空名册查询未知单位")
	_expect(Units.capability({}, "unit_missing").reason == "invalid_state",
		"非法文档不能查询战力")
	_expect(Units.capability(state, "").reason == "invalid_unit_id",
		"空单位 id 不能查询战力")

	var fed: Dictionary = Units.upkeep(state, _stock(0, 100), START)
	_expect(fed.ok and fed.status == "fed", "空名册也可以推进补给时刻")
	_expect(fed.consumed == 0 and fed.deserters == 0, "空名册不消耗粮草")
	_expect(Units.valid(fed.state), "推进补给后的文档有效")
	_expect(fed.state["last_upkeep_utc"] == START, "补给时刻入库")


func _test_recruit() -> void:
	var state: Dictionary = Units.initial_state(WORLD)
	var before: String = JSON.stringify(state)
	var result: Dictionary = Units.recruit(state, _stock(),
		_recruit("unit_a01", OWNER_A, "militia", 100, "basic", "station_a"), START)
	_expect(result.ok, "合法招募成功")
	_expect(not result.duplicate, "首次招募不是回放")
	_expect(result.cost.cash == 400 and result.cost.supplies == 100,
		"民兵 100 人基础装备成本正确")
	_expect(JSON.stringify(state) == before, "招募不修改输入文档")
	_expect(result.has("state"), "成功返回候选文档")
	_expect(Units.valid(result.state), "招募后的文档有效")
	var unit: Dictionary = result.state["units"]["unit_a01"]
	_expect(unit.owner == OWNER_A and unit.kind == "militia",
		"单位记录所有者与兵种")
	_expect(unit.people == 100 and unit.equipment == "basic",
		"单位记录人数与装备")
	_expect(unit.station == "station_a" and unit.recruited_utc == START,
		"单位记录驻地与招募时刻")
	_expect(unit.unfed_days == 0, "新单位没有欠供")
	_expect(unit.record_command_id == "unit_a01", "单位记录招募命令 id")
	var power: Dictionary = Units.capability(result.state, "unit_a01")
	_expect(power.ok and power.power == 1100, "民兵基础装备战力为 10×100×1.1")
	_expect(power.equipment_bps == 11000 and power.penalty_bps == 10000,
		"战力系数与无欠供惩罚正确")

	var guard: Dictionary = Units.recruit(result.state, _stock(),
		_recruit("unit_b01", OWNER_B, "guard", 100, "none", "station_b"), START)
	_expect(guard.ok, "同文档可以继续招募另一种兵种")
	_expect(guard.cost.cash == 400 and guard.cost.supplies == 200,
		"护卫 100 人每日粮草为 2 倍")
	_expect(Units.capability(guard.state, "unit_b01").power == 1800,
		"护卫基础战力按目录计算")

	var elite: Dictionary = Units.recruit(Units.initial_state(WORLD), _stock(),
		_recruit("unit_c01", OWNER_A, "militia", 100, "elite", "station_c"), START)
	_expect(elite.ok, "精英装备可以招募")
	_expect(elite.cost.cash == 1200, "装备成本计入每人现金成本")
	_expect(Units.capability(elite.state, "unit_c01").power == 1500,
		"精英装备提高战力")


func _test_recruit_errors() -> void:
	var state: Dictionary = Units.initial_state(WORLD)
	var stock: Dictionary = _stock()
	var now: float = START
	_expect(Units.recruit(state, stock, null, now).reason == "invalid_command",
		"非字典招募命令被拒")
	_expect(Units.recruit(state, stock, "nope", now).reason == "invalid_command",
		"字符串招募命令被拒")
	var extra: Dictionary = _recruit("unit_x", OWNER_A, "militia", 10, "none", "station_a")
	extra["surprise"] = 1
	_expect(Units.recruit(state, stock, extra, now).reason == "invalid_command",
		"多出未知键的招募命令被拒")
	var missing: Dictionary = extra.duplicate(true)
	missing.erase("surprise")
	missing.erase("station")
	_expect(Units.recruit(state, stock, missing, now).reason == "invalid_command",
		"缺键的招募命令被拒")
	_expect(Units.recruit(state, stock,
		_recruit("", OWNER_A, "militia", 10, "none", "station_a"), now).reason
		== "invalid_unit_id", "空单位 id 被拒")
	_expect(Units.recruit(state, stock,
		_recruit("x".repeat(129), OWNER_A, "militia", 10, "none", "station_a"),
		now).reason == "invalid_unit_id", "超过长度上限的单位 id 被拒")
	_expect(Units.recruit(state, stock,
		_recruit("unit_x", "", "militia", 10, "none", "station_a"), now).reason
		== "invalid_owner", "空所有者被拒")
	_expect(Units.recruit(state, stock,
		_recruit("unit_x", "public", "militia", 10, "none", "station_a"), now).reason
		== "invalid_owner", "public 不能拥有单位")
	_expect(Units.recruit(state, stock,
		_recruit("unit_x", OWNER_A, "knight", 10, "none", "station_a"), now).reason
		== "invalid_kind", "未知兵种被拒")
	for people: Variant in [0, -1, 1.5, "10", Units.MAX_PEOPLE_PER_UNIT + 1]:
		_expect(Units.recruit(state, stock,
			_recruit("unit_x", OWNER_A, "militia", people, "none", "station_a"),
			now).reason == "invalid_people", "非法人数 %s 被拒" % str(people))
	_expect(Units.recruit(state, stock,
		_recruit("unit_x", OWNER_A, "militia", 10, "magic", "station_a"), now).reason
		== "invalid_equipment", "未知装备被拒")
	_expect(Units.recruit(state, stock,
		_recruit("unit_x", OWNER_A, "militia", 10, "none", ""), now).reason
		== "invalid_station", "空驻地被拒")
	_expect(Units.recruit(state, stock,
		_recruit("unit_x", OWNER_A, "militia", 10, "none", "bad station"), now).reason
		== "invalid_station", "非法驻地字符被拒")
	_expect(Units.recruit(state, stock,
		_recruit("unit_x", OWNER_A, "militia", 10, "none", "s".repeat(65)), now).reason
		== "invalid_station", "超过长度上限的驻地被拒")
	_expect(Units.recruit(state, stock,
		_recruit("unit_x", OWNER_A, "militia", 10, "none", "station_a"), -1.0).reason
		== "invalid_time", "负招募时间被拒")
	_expect(Units.recruit(state, stock,
		_recruit("unit_x", OWNER_A, "militia", 10, "none", "station_a"), INF).reason
		== "invalid_time", "非有限招募时间被拒")

	var command: Dictionary = _recruit("unit_x", OWNER_A, "militia", 100, "basic",
		"station_a")
	_expect(Units.recruit(state, {"cash": 0}, command, now).reason == "invalid_stock",
		"缺粮草字段的库存上下文被拒")
	_expect(Units.recruit(state, {"cash": -1, "supplies": 0}, command, now).reason
		== "invalid_stock", "负现金库存被拒")
	_expect(Units.recruit(state, {"cash": 0, "supplies": 0, "extra": 1}, command,
		now).reason == "invalid_stock", "多出未知键的库存上下文被拒")
	_expect(Units.recruit(state, {"cash": 399, "supplies": 10000}, command, now).reason
		== "insufficient_cash", "现金不足时拒绝招募")
	_expect(Units.recruit(state, {"cash": 10000, "supplies": 99}, command, now).reason
		== "insufficient_supply", "粮草不足时拒绝招募")
	var short_cash: Dictionary = Units.recruit(state, {"cash": 0, "supplies": 10000},
		command, now)
	_expect(short_cash.reason == "insufficient_cash" and not short_cash.has("state"),
		"资源不足失败不返回候选文档")


func _test_recruit_limits() -> void:
	var big: Dictionary = Units.recruit(Units.initial_state(WORLD), _stock(),
		_recruit("unit_big", OWNER_A, "militia", Units.MAX_PEOPLE_PER_UNIT, "none",
			"station_a"), START)
	_expect(big.ok, "单支单位人数上限本身可以招募")
	_expect(Units.capability(big.state, "unit_big").power == 5000,
		"上限人数的战力按公式计算")

	var stock: Dictionary = _stock()
	var state: Dictionary = Units.initial_state(WORLD)
	for index: int in Units.MAX_UNITS:
		var unit_id: String = "unit_%02d" % index
		var recruited: Dictionary = Units.recruit(state, stock,
			_recruit(unit_id, OWNER_A, "militia", 1, "none", "station_a"), START)
		assert(recruited.ok, "测试夹具的 64 支单位必须都能招募")
		state = recruited.state
	_expect(state["units"].size() == Units.MAX_UNITS, "名册达到 64 支上限")
	_expect(Units.valid(state), "满名册文档有效")
	var overflow: Dictionary = Units.recruit(state, stock,
		_recruit("unit_overflow", OWNER_A, "militia", 1, "none", "station_a"), START)
	_expect(not overflow.ok and overflow.reason == "capacity",
		"超过名册上限时拒绝招募而不是淘汰旧单位")
	_expect(overflow.has("state") == false, "容量拒绝不返回候选文档")
	_expect(state["units"].size() == Units.MAX_UNITS, "容量拒绝不修改名册")


func _test_recruit_idempotency() -> void:
	var state: Dictionary = Units.initial_state(WORLD)
	var command: Dictionary = _recruit("unit_a01", OWNER_A, "militia", 100, "basic",
		"station_a")
	var first: Dictionary = Units.recruit(state, _stock(), command, START)
	_expect(first.ok and not first.duplicate, "幂等夹具首次招募成功")
	var before: String = JSON.stringify(first.state)
	var replay: Dictionary = Units.recruit(first.state, _stock(0, 0),
		command.duplicate(true), START)
	_expect(replay.ok and replay.duplicate, "同 id 同 payload 重试回放")
	_expect(replay.cost.cash == 400 and replay.cost.supplies == 100,
		"回放返回首次成本")
	_expect(replay.unit_id == "unit_a01", "回放返回首次单位 id")
	_expect(JSON.stringify(first.state) == before, "回放不修改输入文档")
	_expect(replay.state["units"].size() == 1, "回放不重复招募")
	var conflict: Dictionary = Units.recruit(first.state, _stock(),
		_recruit("unit_a01", OWNER_A, "militia", 99, "basic", "station_a"), START)
	_expect(not conflict.ok and conflict.reason == "command_conflict",
		"同 id 换 payload 返回 command_conflict")
	_expect(conflict.has("state") == false, "命令冲突不返回候选文档")
	var time_conflict: Dictionary = Units.recruit(first.state, _stock(), command,
		START + 1.0)
	_expect(not time_conflict.ok and time_conflict.reason == "command_conflict",
		"同 id 不同招募时间视为不同 payload")
	var fed: Dictionary = Units.upkeep(first.state, _stock(0, 1000), START + DAY)
	_expect(fed.ok, "幂等测试推进补给时刻")
	var late_replay: Dictionary = Units.recruit(fed.state, _stock(0, 0), command, START)
	_expect(late_replay.ok and late_replay.duplicate,
		"补给推进后旧招募命令仍按耐久 id 回放")
	_expect(JSON.stringify(late_replay.state) == JSON.stringify(fed.state),
		"跨补给时刻的招募回放不修改文档")


func _test_upkeep_fed() -> void:
	var recruited: Dictionary = Units.recruit(Units.initial_state(WORLD), _stock(),
		_recruit("unit_a01", OWNER_A, "militia", 100, "none", "station_a"), START)
	var state: Dictionary = recruited.state
	var before: String = JSON.stringify(state)
	var fed: Dictionary = Units.upkeep(state, _stock(0, 1000), START + DAY)
	_expect(fed.ok and fed.status == "fed", "粮草充足时补给成功")
	_expect(fed.settled_this_tick == false, "新时刻不是同刻回放")
	_expect(fed.consumed == 100, "消耗等于人数乘每日粮草")
	_expect(fed.deserters == 0 and fed.affected.is_empty(), "足量补给没有逃兵")
	_expect(JSON.stringify(state) == before, "补给不修改输入文档")
	_expect(Units.valid(fed.state), "补给后的文档有效")
	var unit: Dictionary = fed.state["units"]["unit_a01"]
	_expect(unit.people == 100 and unit.unfed_days == 0,
		"足量补给保持人数并清除欠供")
	_expect(Units.capability(fed.state, "unit_a01").power == 1000,
		"足量补给后战力不变")
	_expect(fed.state["last_upkeep_utc"] == START + DAY, "补给时刻入库")


func _test_upkeep_shortfall() -> void:
	var recruited: Dictionary = Units.recruit(Units.initial_state(WORLD), _stock(),
		_recruit("unit_a01", OWNER_A, "militia", 100, "basic", "station_a"), START)
	var state: Dictionary = recruited.state
	var power_before: int = Units.capability(state, "unit_a01").power
	var short: Dictionary = Units.upkeep(state, _stock(0, 50), START + DAY)
	_expect(short.ok and short.status == "shortfall", "粮草不足时标记欠供")
	_expect(short.consumed == 50, "只扣可用粮草")
	_expect(short.deserters == 50, "缺口按比例产生逃兵")
	_expect(short.affected.size() == 1, "欠供记录受影响单位")
	var row: Dictionary = short.affected[0]
	_expect(row.unit_id == "unit_a01" and row.required == 100,
		"受影响单位记录需求量")
	_expect(row.supplied == 50 and row.shortfall == 50,
		"受影响单位记录实际供给与缺口")
	_expect(row.people_before == 100 and row.people_after == 50,
		"受影响单位记录人数变化")
	_expect(row.unfed_days == 1 and row.removed == false,
		"第一次欠供不会直接解散单位")
	var unit: Dictionary = short.state["units"]["unit_a01"]
	_expect(unit.people == 50 and unit.unfed_days == 1,
		"逃兵写入名册并累计欠供天数")
	var power_after: int = Units.capability(short.state, "unit_a01").power
	_expect(power_after == 412, "欠供后战力按人数与惩罚系数下降")
	_expect(power_after < power_before, "欠供后战力必须明确下降")

	var starved: Dictionary = Units.upkeep(short.state, _stock(0, 0), START + 2.0 * DAY)
	_expect(starved.ok and starved.status == "shortfall", "持续断粮仍是欠供")
	_expect(starved.consumed == 0 and starved.deserters == 50,
		"零粮草时全部剩余人员逃散")
	_expect(starved.affected[0].removed, "人数归零的单位从名册移除")
	_expect(starved.state["units"].is_empty(), "饿散的单位不再占名册")
	_expect(Units.valid(starved.state), "饿散后的文档有效")
	_expect(Units.capability(starved.state, "unit_a01").reason == "unknown_unit",
		"饿散单位无法再查询战力")


func _test_upkeep_order() -> void:
	var first: Dictionary = Units.recruit(Units.initial_state(WORLD), _stock(),
		_recruit("unit_a01", OWNER_A, "militia", 10, "none", "station_a"), START)
	var second: Dictionary = Units.recruit(first.state, _stock(),
		_recruit("unit_a02", OWNER_B, "guard", 5, "none", "station_b"), START)
	var result: Dictionary = Units.upkeep(second.state, _stock(0, 10), START + DAY)
	_expect(result.ok and result.status == "shortfall", "多单位粮草不足时整体欠供")
	_expect(result.consumed == 10, "粮草按升序分配且不超支")
	_expect(result.affected.size() == 1, "只记录实际欠供的单位")
	_expect(result.affected[0].unit_id == "unit_a02",
		"相同 id 前缀按字典序分配，后一单位承担缺口")
	_expect(result.state["units"].has("unit_a01"), "先分配到粮草的单位存活")
	_expect(result.state["units"].has("unit_a02") == false, "断粮单位被移除")


func _test_upkeep_tick() -> void:
	var recruited: Dictionary = Units.recruit(Units.initial_state(WORLD), _stock(),
		_recruit("unit_a01", OWNER_A, "militia", 100, "none", "station_a"), START)
	var first: Dictionary = Units.upkeep(recruited.state, _stock(0, 1000), START + DAY)
	_expect(first.ok and first.status == "fed", "同刻测试夹具首次补给成功")
	var before: String = JSON.stringify(first.state)
	var same: Dictionary = Units.upkeep(first.state, _stock(0, 0), START + DAY)
	_expect(same.ok and same.status == "settled_this_tick",
		"同一时刻重复调用返回 settled_this_tick")
	_expect(same.settled_this_tick, "同刻标记为已结算")
	_expect(same.consumed == 0 and same.deserters == 0,
		"同刻重复调用不重复扣粮或产生逃兵")
	_expect(JSON.stringify(first.state) == before, "同刻重复调用不修改输入")
	_expect(same.state["last_upkeep_utc"] == START + DAY, "同刻不推进补给时刻")

	var regression: Dictionary = Units.upkeep(first.state, _stock(0, 1000), START)
	_expect(not regression.ok and regression.reason == "time_regression",
		"补给时间倒退被拒")
	_expect(regression.has("state") == false, "时间倒退不返回候选文档")

	var next: Dictionary = Units.upkeep(first.state, _stock(0, 1000), START + 2.0 * DAY)
	_expect(next.ok and next.status == "fed", "下一时刻可以继续补给")
	_expect(next.consumed == 100, "下一时刻重新消耗一天粮草")

	var late_recruit: Dictionary = Units.recruit(first.state, _stock(),
		_recruit("unit_late", OWNER_A, "militia", 1, "none", "station_a"), START)
	_expect(not late_recruit.ok and late_recruit.reason == "time_regression",
		"补给之后不能补招募更早的单位")


func _test_disband() -> void:
	var recruited: Dictionary = Units.recruit(Units.initial_state(WORLD), _stock(),
		_recruit("unit_a01", OWNER_A, "militia", 100, "basic", "station_a"), START)
	var state: Dictionary = recruited.state
	var wrong_owner: Dictionary = Units.disband(state,
		_disband("cmd_owner", "unit_a01", OWNER_B), START)
	_expect(not wrong_owner.ok and wrong_owner.reason == "not_owner",
		"非所有者不能解散单位")
	var unknown: Dictionary = Units.disband(state,
		_disband("cmd_unknown", "unit_missing", OWNER_A), START)
	_expect(not unknown.ok and unknown.reason == "unknown_unit",
		"未知单位不能解散")
	var extra: Dictionary = _disband("cmd_extra", "unit_a01", OWNER_A)
	extra["surprise"] = 1
	_expect(Units.disband(state, extra, START).reason == "invalid_command",
		"多出未知键的解散命令被拒")
	var missing: Dictionary = _disband("cmd_missing", "unit_a01", OWNER_A)
	missing.erase("owner")
	_expect(Units.disband(state, missing, START).reason == "invalid_command",
		"缺键的解散命令被拒")

	var before: String = JSON.stringify(state)
	var command: Dictionary = _disband("cmd_disband_01", "unit_a01", OWNER_A)
	var result: Dictionary = Units.disband(state, command, START)
	_expect(result.ok and not result.duplicate, "合法解散成功")
	_expect(JSON.stringify(state) == before, "解散不修改输入文档")
	_expect(result.state["units"].is_empty(), "解散后名册移除单位")
	_expect(result.unit.people == 100, "解散返回被移除单位")
	_expect(Units.valid(result.state), "解散后的文档有效")
	var replay: Dictionary = Units.disband(result.state, command.duplicate(true), START)
	_expect(replay.ok and replay.duplicate, "同 id 同 payload 解散回放")
	_expect(replay.state["units"].is_empty(), "解散回放不重复删除")
	var conflict: Dictionary = Units.disband(result.state,
		_disband("cmd_disband_01", "unit_a01", OWNER_B), START)
	_expect(not conflict.ok and conflict.reason == "command_conflict",
		"同 id 换 owner 解散返回 command_conflict")

	var fed: Dictionary = Units.upkeep(state, _stock(0, 1000), START + DAY)
	var late: Dictionary = Units.disband(fed.state,
		_disband("cmd_disband_late", "unit_a01", OWNER_A), START)
	_expect(not late.ok and late.reason == "time_regression",
		"补给之后不能补解散更早的单位")
	var advanced: Dictionary = Units.upkeep(result.state, _stock(0, 0), START + 2.0 * DAY)
	_expect(advanced.ok, "解散幂等测试推进补给时刻")
	var late_replay: Dictionary = Units.disband(advanced.state, command, START)
	_expect(late_replay.ok and late_replay.duplicate,
		"补给推进后旧解散命令仍按耐久 id 回放")
	_expect(JSON.stringify(late_replay.state) == JSON.stringify(advanced.state),
		"跨补给时刻的解散回放不修改文档")


func _test_copy_on_write() -> void:
	var state: Dictionary = Units.initial_state(WORLD)
	var before: String = JSON.stringify(state)
	var failure: Dictionary = Units.recruit(state, _stock(),
		_recruit("unit_a01", OWNER_A, "militia", 1, "none", "station_a"), -1.0)
	_expect(not failure.ok and failure.has("state") == false,
		"失败路径不返回候选文档")
	_expect(JSON.stringify(state) == before, "失败路径逐字节不修改输入")

	var recruited: Dictionary = Units.recruit(state, _stock(),
		_recruit("unit_a01", OWNER_A, "militia", 100, "none", "station_a"), START)
	var recruited_before: String = JSON.stringify(recruited.state)
	var fed: Dictionary = Units.upkeep(recruited.state, _stock(0, 10), START + DAY)
	_expect(fed.ok and fed.status == "shortfall", "写时复制夹具产生欠供")
	_expect(JSON.stringify(recruited.state) == recruited_before,
		"补给写入不影响调用方文档")
	_expect(recruited.state["units"]["unit_a01"].people == 100,
		"补给写入后输入文档人数不变")

	var disband_before: String = JSON.stringify(fed.state)
	var disbanded: Dictionary = Units.disband(fed.state,
		_disband("cmd_disband_cow", "unit_a01", OWNER_A), START + DAY)
	_expect(disbanded.ok, "写时复制夹具解散成功")
	_expect(JSON.stringify(fed.state) == disband_before, "解散写入不影响调用方文档")
	_expect(fed.state["units"].has("unit_a01"), "解散写入后输入文档仍保留单位")


func _test_document_validation() -> void:
	var recruited: Dictionary = Units.recruit(Units.initial_state(WORLD), _stock(),
		_recruit("unit_a01", OWNER_A, "militia", 100, "basic", "station_a"), START)
	_expect(recruited.ok, "文档校验夹具招募成功")
	var state: Dictionary = recruited.state
	_expect(Units.valid(state), "招募后的文档通过严格校验")
	_expect(Units.valid(JSON.parse_string(JSON.stringify(state))),
		"招募后的文档 JSON 往返有效")

	var extra: Dictionary = state.duplicate(true)
	extra["extra"] = 1
	_expect(not Units.valid(extra), "多出未知文档键时无效")
	var missing: Dictionary = state.duplicate(true)
	missing.erase("commands")
	_expect(not Units.valid(missing), "缺文档键时无效")
	var wrong_world: Dictionary = state.duplicate(true)
	wrong_world["world_id"] = ""
	_expect(not Units.valid(wrong_world), "非法世界 id 时无效")
	var wrong_sequence: Dictionary = state.duplicate(true)
	wrong_sequence["sequence"] = 0
	_expect(not Units.valid(wrong_sequence), "序列小于命令记录数时无效")
	var wrong_upkeep: Dictionary = state.duplicate(true)
	wrong_upkeep["last_upkeep_utc"] = -2.0
	_expect(not Units.valid(wrong_upkeep), "非法补给时刻哨兵时无效")

	var unit_extra: Dictionary = state.duplicate(true)
	unit_extra["units"]["unit_a01"]["extra"] = 1
	_expect(not Units.valid(unit_extra), "单位行多出未知键时无效")
	var unit_missing: Dictionary = state.duplicate(true)
	unit_missing["units"]["unit_a01"].erase("station")
	_expect(not Units.valid(unit_missing), "单位行缺键时无效")
	var id_mismatch: Dictionary = state.duplicate(true)
	id_mismatch["units"]["unit_a01"]["id"] = "unit_other"
	_expect(not Units.valid(id_mismatch), "单位 id 与键不一致时无效")
	var bad_owner: Dictionary = state.duplicate(true)
	bad_owner["units"]["unit_a01"]["owner"] = "public"
	_expect(not Units.valid(bad_owner), "public 单位行无效")
	var bad_kind: Dictionary = state.duplicate(true)
	bad_kind["units"]["unit_a01"]["kind"] = "knight"
	_expect(not Units.valid(bad_kind), "未知兵种单位行无效")
	var zero_people: Dictionary = state.duplicate(true)
	zero_people["units"]["unit_a01"]["people"] = 0
	_expect(not Units.valid(zero_people), "零人数单位行无效")
	var over_people: Dictionary = state.duplicate(true)
	over_people["units"]["unit_a01"]["people"] = Units.MAX_PEOPLE_PER_UNIT + 1
	_expect(not Units.valid(over_people), "超过人数上限的单位行无效")
	var bad_equipment: Dictionary = state.duplicate(true)
	bad_equipment["units"]["unit_a01"]["equipment"] = "magic"
	_expect(not Units.valid(bad_equipment), "未知装备单位行无效")
	var bad_station: Dictionary = state.duplicate(true)
	bad_station["units"]["unit_a01"]["station"] = ""
	_expect(not Units.valid(bad_station), "空驻地的单位行无效")
	var bad_time: Dictionary = state.duplicate(true)
	bad_time["units"]["unit_a01"]["recruited_utc"] = -1.0
	_expect(not Units.valid(bad_time), "负招募时刻的单位行无效")
	var bad_unfed: Dictionary = state.duplicate(true)
	bad_unfed["units"]["unit_a01"]["unfed_days"] = -1
	_expect(not Units.valid(bad_unfed), "负欠供天数的单位行无效")
	var bad_record_id: Dictionary = state.duplicate(true)
	bad_record_id["units"]["unit_a01"]["record_command_id"] = "unit_other"
	_expect(not Units.valid(bad_record_id), "单位记录命令 id 与键不一致时无效")
	var no_record: Dictionary = state.duplicate(true)
	no_record["commands"].erase("unit_a01")
	_expect(not Units.valid(no_record), "单位缺少招募命令记录时无效")

	var record_extra: Dictionary = state.duplicate(true)
	record_extra["commands"]["unit_a01"]["extra"] = 1
	_expect(not Units.valid(record_extra), "命令记录多出未知键时无效")
	var record_missing: Dictionary = state.duplicate(true)
	record_missing["commands"]["unit_a01"].erase("payload")
	_expect(not Units.valid(record_missing), "命令记录缺键时无效")
	var payload_tamper: Dictionary = state.duplicate(true)
	var entry: Dictionary = payload_tamper["commands"]["unit_a01"]
	entry["payload"] = str(entry["payload"]).replace("station_a", "station_b")
	_expect(not Units.valid(payload_tamper), "篡改招募 payload 时无效")
	var cost_tamper: Dictionary = state.duplicate(true)
	cost_tamper["commands"]["unit_a01"]["result"]["cost"]["cash"] = 401
	_expect(not Units.valid(cost_tamper), "篡改招募成本时无效")
	var unit_tamper: Dictionary = state.duplicate(true)
	unit_tamper["units"]["unit_a01"]["station"] = "station_b"
	_expect(not Units.valid(unit_tamper), "单位行与招募 payload 不一致时无效")
	var kind_tamper: Dictionary = state.duplicate(true)
	kind_tamper["commands"]["unit_a01"]["result"]["kind"] = "disband"
	_expect(not Units.valid(kind_tamper), "篡改命令结果类型时无效")
	var result_unit_tamper: Dictionary = state.duplicate(true)
	result_unit_tamper["commands"]["unit_a01"]["result"]["unit_id"] = "unit_other"
	_expect(not Units.valid(result_unit_tamper), "篡改命令结果单位时无效")
	var empty_record: Dictionary = state.duplicate(true)
	empty_record["commands"]["ghost"] = {}
	_expect(not Units.valid(empty_record), "伪造空命令记录时无效")

	var disbanded: Dictionary = Units.disband(state,
		_disband("cmd_disband_valid", "unit_a01", OWNER_A), START)
	_expect(disbanded.ok and Units.valid(disbanded.state), "解散后的文档有效")
	var revived: Dictionary = disbanded.state.duplicate(true)
	revived["units"]["unit_a01"] = state["units"]["unit_a01"].duplicate(true)
	_expect(not Units.valid(revived), "已解散单位重新出现在名册时无效")
	var fake_disband: Dictionary = disbanded.state.duplicate(true)
	fake_disband["commands"]["cmd_fake"] = {
		"payload": JSON.stringify(["cmd_fake", "unit_ghost", OWNER_A]),
		"result": {
			"kind": "disband",
			"unit_id": "unit_ghost",
			"cost": {"cash": 0, "supplies": 0},
		},
	}
	fake_disband["sequence"] = int(fake_disband["sequence"]) + 1
	_expect(not Units.valid(fake_disband), "解散记录没有对应招募记录时无效")

	var round: Variant = JSON.parse_string(JSON.stringify(state))
	_expect(round is Dictionary and Units.valid(round), "校验夹具 JSON 往返有效")
	var continued: Dictionary = Units.recruit(round, _stock(),
		_recruit("unit_a02", OWNER_B, "guard", 10, "standard", "station_b"),
		START + DAY)
	_expect(continued.ok and Units.valid(continued.state),
		"JSON 往返后可以继续招募")


func _test_determinism() -> void:
	var command: Dictionary = _recruit("unit_a01", OWNER_A, "militia", 100, "basic",
		"station_a")
	var left: Dictionary = Units.recruit(Units.initial_state(WORLD), _stock(), command,
		START)
	var right: Dictionary = Units.recruit(Units.initial_state(WORLD), _stock(),
		command.duplicate(true), START)
	_expect(left.ok and right.ok, "确定性夹具招募成功")
	_expect(JSON.stringify(left) == JSON.stringify(right),
		"同一招募输入得到逐字节相同结果")
	_expect(left.state == right.state and left.cost == right.cost,
		"确定性覆盖候选文档与成本")

	var fed_left: Dictionary = Units.upkeep(left.state, _stock(0, 40), START + DAY)
	var fed_right: Dictionary = Units.upkeep(right.state, _stock(0, 40), START + DAY)
	_expect(JSON.stringify(fed_left) == JSON.stringify(fed_right),
		"同一补给输入得到逐字节相同结果")
	_expect(fed_left.affected == fed_right.affected, "确定性覆盖逃兵明细")
	_expect(fed_left.ok and fed_left.status == "shortfall",
		"确定性夹具产生欠供")


func _recruit(unit_id: String, owner: String, kind: String, people: Variant,
		equipment: String, station: String) -> Dictionary:
	return {
		"id": unit_id,
		"owner": owner,
		"kind": kind,
		"people": people,
		"equipment": equipment,
		"station": station,
	}


func _disband(command_id: String, unit_id: String, owner: String) -> Dictionary:
	return {"id": command_id, "unit_id": unit_id, "owner": owner}


func _stock(cash: int = 1000000, supplies: int = 1000000) -> Dictionary:
	return {"cash": cash, "supplies": supplies}


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
