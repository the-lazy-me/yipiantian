extends SceneTree
## M12-01 / M12-03 交叉：单位 -> 交战结算 -> 单位损失。纯规则无头测试。
## 无场景、无时钟、无随机数、无网络、无存档文档；命令都显式传入 UTC 时间。
## 最后一行是验证证据。

const Units = preload("res://conflict/unit_state.gd")
const UnitConflict = preload("res://conflict/unit_conflict.gd")
const Participation = preload("res://conflict/participation_state.gd")
const Settlement = preload("res://world/conflict_settlement.gd")

const START: float = 1800000000.0
const HOUR: float = 3600.0
const WORLD: String = "world-unit-conflict-a"
const HOST: String = "player_unit_conflict_host"
const ATTACKER: String = "player_unit_conflict_a"
const DEFENDER: String = "player_unit_conflict_d"
const PARCEL: String = "parcel_uc"
const TARGET: String = DEFENDER + "|" + PARCEL
const ZONE: String = "zone_uc"
const WINDOW_1: String = "window_uc_1"
const WINDOW_2: String = "window_uc_2"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_normal_engagement()
	_test_wipe_out()
	_test_defender_loss()
	_test_defender_without_capability()
	_test_defender_loss_cap()
	_test_defender_determinism_and_replay()
	_test_guards()
	_test_rejections_passthrough()
	_test_idempotency()
	_test_determinism()
	_test_json_round_trip()
	for failure: String in failures:
		push_error(failure)
	print("UNIT_CONFLICT_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_normal_engagement() -> void:
	var units: Dictionary = _units()
	var participation: Dictionary = _participation()
	var context: Dictionary = _context(participation)
	var request: Dictionary = _request()
	var units_before: String = JSON.stringify(units)
	var context_before: String = JSON.stringify(context)
	var participation_before: String = JSON.stringify(participation)
	var request_before: String = JSON.stringify(request)

	var result: Dictionary = UnitConflict.engage(units, participation, context, request,
		START + 20.0)
	_expect(result.ok, "合法交战可以结算")
	_expect(not result.duplicate, "第一次交战不是回放")
	_expect(JSON.stringify(units) == units_before, "交战不修改输入单位文档")
	_expect(JSON.stringify(context) == context_before, "交战不修改输入结算上下文")
	_expect(JSON.stringify(participation) == participation_before,
		"交战不修改输入参与制度")
	_expect(JSON.stringify(request) == request_before, "交战不修改输入请求")

	var outcome: Dictionary = result.outcome
	_expect(outcome.losses == 100, "结算损失受参与窗口上限约束")
	_expect(outcome.troops == 150, "结算兵力等于进攻方参战单位人数之和")
	_expect(result.projection.attacker.people == 150,
		"投影记录进攻方参战人数")
	_expect(result.projection.attacker.power == 1500,
		"投影用 capability 汇总进攻方战力")
	_expect(result.projection.defender.people == 200,
		"投影记录防守方参战人数")
	_expect(result.projection.defender.power == 2000,
		"投影用 capability 汇总防守方战力")
	_expect(result.projection.attacker.unit_ids == ["unit_a01", "unit_a02"],
		"投影按单位 id 升序列出参战单位")
	_expect(result.projection.attacker.resources["cash"] == 500
		and result.projection.attacker.resources["supplies"] == 200,
		"投影原样记录调用方提供的进攻方资源")

	_expect(result.units["units"]["unit_a01"]["people"] == 33,
		"进攻方第一支单位按比例承担 67 人损失")
	_expect(result.units["units"]["unit_a02"]["people"] == 17,
		"进攻方第二支单位按比例承担 33 人损失")
	_expect(result.units["units"]["unit_d01"]["people"] == 120,
		"无装备民兵不具备防守能力，不承担战损")
	_expect(result.units["units"]["unit_d02"]["people"] == 80,
		"防守方第二支无装备民兵同样保持不变")
	_expect(result.defender_loss == 0, "无防守能力时防守方战损为 0")
	_expect(result.units["units"]["unit_a03"]["people"] == 30,
		"未参战进攻方单位不受影响")
	_expect(result.units["units"]["unit_d03"]["people"] == 25,
		"未参战防守方单位不受影响")
	_expect(result.units["sequence"] == int(units["sequence"]) + 1,
		"候选单位文档推进序列")
	_expect(Units.valid(result.units), "候选单位文档通过严格校验")

	var settled: Dictionary = result.settlement
	_expect(settled.ok, "settlement 原样返回结算结果")
	_expect(settled.outcome == outcome, "settlement.outcome 与顶层结果一致")
	_expect(settled.freeze.size() == 2, "结算冻结项交给权威落资产")
	_expect(_freeze_amount(settled.freeze, ATTACKER, "supplies", "attack_cost") == 150,
		"冻结进攻方出征消耗")
	_expect(settled.next_context["resources"][ATTACKER]["cash"] == 550,
		"进攻方获得结算战利品，桥接层不另行发放")
	_expect(settled.next_context["resources"][ATTACKER]["supplies"] == 50,
		"进攻方物资按结算扣除")
	_expect(settled.next_context["resources"][DEFENDER]["cash"] == 200,
		"防守方资源按结算扣除")
	_expect(Settlement.valid_context(settled.next_context),
		"结算候选上下文仍然有效")


func _test_wipe_out() -> void:
	var units: Dictionary = _small_units()
	var participation: Dictionary = _participation()
	var context: Dictionary = _context(participation)
	var request: Dictionary = _request("unit-engage-wipe", ["unit_x01"], ["unit_y01"])
	var result: Dictionary = UnitConflict.engage(units, participation, context, request,
		START + 20.0)
	_expect(result.ok, "小分队仍可结算")
	_expect(result.outcome.losses == 20, "小分队损失等于投入兵力")
	_expect(result.units["units"].has("unit_x01") == false,
		"进攻方人数被打光后从名册消失")
	_expect(result.units["units"]["unit_y01"]["people"] == 10,
		"防守方单位不因进攻方损失而减员")
	_expect(result.units["units"]["unit_y02"]["people"] == 30,
		"未参战单位不会因同侧单位被打光而受牵连")
	_expect(Units.valid(result.units), "有单位消失的候选文档仍有效")


func _test_defender_loss() -> void:
	var units: Dictionary = _guarded_units()
	var participation: Dictionary = _participation()
	var context: Dictionary = _context(participation)
	var request: Dictionary = _defender_request()
	var before: String = JSON.stringify(units)

	var result: Dictionary = UnitConflict.engage(units, participation, context, request,
		START + 20.0)
	_expect(result.ok, "有防守能力的防守方可以结算")
	_expect(JSON.stringify(units) == before, "防守方战损不修改输入单位文档")
	_expect(not result.has("reason") or str(result.reason).is_empty(),
		"成功结果原因为空")
	_expect(result.outcome.losses == 100, "进攻方损失仍由结算给出")
	_expect(result.projection.defender.people == 120,
		"防守投影记录全部参战人数")
	# 进攻 150 人战力 1500；防守护卫 100 人（1800）+ 20 人基础装备（396），
	# 压力系数 1500*10000/(2*3696) = 2029 bps，防守参战 120 人取整得 24 人。
	_expect(result.defender_loss == 24,
		"具备防守能力时防守方按战力比例承担战损")
	_expect(result.units["units"]["unit_g01"]["people"] == 80,
		"防守护卫人数按比例下降")
	_expect(result.units["units"]["unit_g02"]["people"] == 16,
		"同侧另一护卫按人数比例分摊")
	_expect(result.units["units"]["unit_a01"]["people"] == 33,
		"进攻方损失不变")
	_expect(result.units["units"]["unit_a02"]["people"] == 17,
		"进攻方第二支单位损失不变")
	_expect(result.units["units"]["unit_d03"]["people"] == 25,
		"无装备民兵不承担战损")
	_expect(result.units["units"]["unit_d04"]["people"] == 25,
		"未参战单位不承担战损")
	_expect(Units.valid(result.units), "带防守战损的候选文档仍有效")


func _test_defender_without_capability() -> void:
	var units: Dictionary = _units()
	var participation: Dictionary = _participation()
	var context: Dictionary = _context(participation)
	var request: Dictionary = _request()
	var result: Dictionary = UnitConflict.engage(units, participation, context, request,
		START + 20.0)
	_expect(result.ok, "无防守能力的防守方仍然可以结算")
	_expect(result.defender_loss == 0, "无防守能力时防守战损为 0")
	_expect(result.units["units"]["unit_d01"]["people"] == 120
		and result.units["units"]["unit_d02"]["people"] == 80,
		"全部无装备民兵保持原人数")


func _test_defender_loss_cap() -> void:
	var units: Dictionary = Units.initial_state(WORLD)
	units = _recruit(units, "unit_a01", ATTACKER, 100, "militia", "none")
	units = _recruit(units, "unit_a02", ATTACKER, 50, "militia", "none")
	units = _recruit(units, "unit_g01", DEFENDER, 200, "guard", "none")
	var participation: Dictionary = _participation()
	var context: Dictionary = _context(participation)
	var request: Dictionary = _request("unit-engage-cap", ["unit_a01", "unit_a02"],
		["unit_g01"])
	request["resources"][ATTACKER]["supplies"] = 5000
	var result: Dictionary = UnitConflict.engage(units, participation, context, request,
		START + 20.0)
	_expect(result.ok, "防守战损上限夹具可以结算")
	# 进攻 150 人战力 1500，防守 200 人战力 3600：比例
	# 1500*10000/(2*5100) = 1470 bps，低于 25% 上限，200 人取整得 29 人。
	_expect(result.defender_loss == 29, "上限内按比例取整")
	_expect(int(result.projection.attacker.people) == 150,
		"进攻人数取自单位投影")

	# 进攻战力远高于防守：比例超过 25% 上限，结果必须压在 25%。
	var strong: Dictionary = Units.initial_state(WORLD)
	strong = _recruit(strong, "unit_a01", ATTACKER, 500, "guard", "elite")
	strong = _recruit(strong, "unit_g01", DEFENDER, 100, "guard", "none")
	var strong_request: Dictionary = _request("unit-engage-capped", ["unit_a01"],
		["unit_g01"])
	strong_request["resources"][ATTACKER]["supplies"] = 5000
	var capped: Dictionary = UnitConflict.engage(strong, _participation(),
		_context(_participation()), strong_request, START + 20.0)
	_expect(capped.ok, "高强度进攻夹具可以结算")
	_expect(capped.defender_loss == 25,
		"单场防守战损不超过防守人数的 25%")
	_expect(capped.units["units"]["unit_g01"]["people"] == 75,
		"上限后防守单位仍有 75 人")
	_expect(capped.defender_loss <= int(capped.projection.defender.people),
		"防守战损不超过防守方现有兵力")

	# 小型防守：上限生效后仍取整到整数，不会超过现有兵力。
	var tiny: Dictionary = Units.initial_state(WORLD)
	tiny = _recruit(tiny, "unit_a01", ATTACKER, 500, "guard", "elite")
	tiny = _recruit(tiny, "unit_g01", DEFENDER, 5, "guard", "none")
	var tiny_request: Dictionary = _request("unit-engage-tiny", ["unit_a01"],
		["unit_g01"])
	tiny_request["resources"][ATTACKER]["supplies"] = 5000
	var tiny_result: Dictionary = UnitConflict.engage(tiny, _participation(),
		_context(_participation()), tiny_request, START + 20.0)
	_expect(tiny_result.ok, "小型防守夹具可以结算")
	_expect(tiny_result.defender_loss == 1,
		"5 人防守在 25% 上限下损失 1 人")
	_expect(tiny_result.units["units"]["unit_g01"]["people"] == 4,
		"损失不会超过防守方现有兵力")
	_expect(Units.valid(tiny_result.units), "小型防守候选文档仍有效")


func _test_defender_determinism_and_replay() -> void:
	var request: Dictionary = _defender_request()
	var left: Dictionary = UnitConflict.engage(_guarded_units(), _participation(),
		_context(_participation()), request, START + 20.0)
	var right: Dictionary = UnitConflict.engage(_guarded_units(), _participation(),
		_context(_participation()), request.duplicate(true), START + 20.0)
	_expect(left.ok and right.ok, "防守战损确定性夹具成功")
	_expect(JSON.stringify(left) == JSON.stringify(right),
		"相同输入得到相同的防守战损")
	_expect(left.defender_loss == right.defender_loss, "战损数值确定")
	_expect(left.units == right.units, "候选名册逐字节相同")

	var replay: Dictionary = UnitConflict.engage(_guarded_units(), _participation(),
		left.settlement.next_context, request, START + 20.0)
	_expect(replay.ok and replay.duplicate, "防守战损夹具同 id 回放")
	_expect(replay.defender_loss == left.defender_loss, "回放得到相同战损")
	_expect(replay.units == left.units, "回放得到相同候选名册")


func _test_guards() -> void:
	var units: Dictionary = _units()
	var participation: Dictionary = _participation()
	var context: Dictionary = _context(participation)
	var before: String = JSON.stringify(units)

	var non_owner: Dictionary = UnitConflict.engage(units, participation, context,
		_request("unit-guard-owner", ["unit_d01"], ["unit_d02"]), START + 20.0)
	_expect(not non_owner.ok and non_owner.reason == "not_owner",
		"进攻方列表不能包含他人单位")
	_expect(non_owner.has("units") == false, "owner 拒绝不返回候选文档")

	var non_owner_defender: Dictionary = UnitConflict.engage(units, participation, context,
		_request("unit-guard-owner-d", ["unit_a01"], ["unit_a02"]), START + 20.0)
	_expect(not non_owner_defender.ok and non_owner_defender.reason == "not_owner",
		"防守方列表不能包含他人单位")

	var unknown: Dictionary = UnitConflict.engage(units, participation, context,
		_request("unit-guard-unknown", ["unit_ghost"], ["unit_d01"]), START + 20.0)
	_expect(not unknown.ok and unknown.reason == "unknown_unit",
		"未知单位被具名拒绝")

	var empty_attacker: Dictionary = UnitConflict.engage(units, participation, context,
		_request("unit-guard-empty-a", [], ["unit_d01"]), START + 20.0)
	_expect(not empty_attacker.ok and empty_attacker.reason == "empty_units",
		"进攻方空单位列表被拒")
	var empty_defender: Dictionary = UnitConflict.engage(units, participation, context,
		_request("unit-guard-empty-d", ["unit_a01"], []), START + 20.0)
	_expect(not empty_defender.ok and empty_defender.reason == "empty_units",
		"防守方空单位列表被拒")

	var duplicate: Dictionary = UnitConflict.engage(units, participation, context,
		_request("unit-guard-dup", ["unit_a01", "unit_a01"], ["unit_d01"]),
		START + 20.0)
	_expect(not duplicate.ok and duplicate.reason == "duplicate_unit",
		"同一方重复单位被拒")
	var cross_duplicate: Dictionary = UnitConflict.engage(units, participation, context,
		_request("unit-guard-cross", ["unit_a01"], ["unit_a01"]), START + 20.0)
	_expect(not cross_duplicate.ok and cross_duplicate.reason == "duplicate_unit",
		"双方同时列出同一单位被拒")

	var bad_shape: Dictionary = UnitConflict.engage(units, participation, context,
		null, START + 20.0)
	_expect(not bad_shape.ok and bad_shape.reason == "invalid_request",
		"非字典请求被拒")
	var extra: Dictionary = _request()
	extra["surprise"] = 1
	_expect(UnitConflict.engage(units, participation, context, extra, START + 20.0).reason
		== "invalid_request", "多出未知键的请求被拒")
	var missing: Dictionary = _request()
	missing.erase("resources")
	_expect(UnitConflict.engage(units, participation, context, missing, START + 20.0).reason
		== "invalid_request", "缺少 resources 的请求被拒")
	var bad_attacker: Dictionary = _request()
	bad_attacker["attacker"] = "public"
	_expect(UnitConflict.engage(units, participation, context, bad_attacker,
		START + 20.0).reason == "invalid_attacker", "非法进攻方 id 被拒")
	var same_player: Dictionary = _request()
	same_player["defender"] = ATTACKER
	_expect(UnitConflict.engage(units, participation, context, same_player,
		START + 20.0).reason == "same_player", "自攻被拒")
	var missing_resource_row: Dictionary = _request()
	missing_resource_row["resources"] = {ATTACKER: {"cash": 500, "supplies": 200}}
	_expect(UnitConflict.engage(units, participation, context, missing_resource_row,
		START + 20.0).reason == "invalid_resources", "资源必须覆盖双方")
	var negative_resource: Dictionary = _request()
	negative_resource["resources"][DEFENDER]["cash"] = -1
	_expect(UnitConflict.engage(units, participation, context, negative_resource,
		START + 20.0).reason == "invalid_resources", "负资源被拒")
	var extra_resource_key: Dictionary = _request()
	extra_resource_key["resources"][DEFENDER]["extra"] = 1
	_expect(UnitConflict.engage(units, participation, context, extra_resource_key,
		START + 20.0).reason == "invalid_resources", "资源行多出未知键被拒")
	var non_array: Dictionary = _request()
	non_array["attacker_units"] = "unit_a01"
	_expect(UnitConflict.engage(units, participation, context, non_array,
		START + 20.0).reason == "invalid_request", "非数组单位列表被拒")

	_expect(JSON.stringify(units) == before, "所有守卫拒绝都不修改单位文档")
	_expect(UnitConflict.engage({}, participation, context, _request(),
		START + 20.0).reason == "invalid_units", "非法单位文档被拒")
	_expect(UnitConflict.engage(units, {}, context, _request(),
		START + 20.0).reason == "invalid_participation", "非法参与制度被拒")
	_expect(UnitConflict.engage(units, participation, {}, _request(),
		START + 20.0).reason == "invalid_context", "空结算上下文被拒")


func _test_rejections_passthrough() -> void:
	var units: Dictionary = _units()
	var before: String = JSON.stringify(units)

	var peace: Dictionary = Participation.initial_state(WORLD, HOST)
	var peace_context: Dictionary = _context(peace)
	var peace_result: Dictionary = UnitConflict.engage(units, peace, peace_context,
		_request("unit-reject-peace"), START + 20.0)
	_expect(not peace_result.ok and peace_result.reason == "peace_time",
		"和平档拒绝透传结算原因")
	_expect(JSON.stringify(units) == before, "和平拒绝不修改单位文档")

	var no_consent_part: Dictionary = _participation_missing("attacker")
	var no_consent: Dictionary = UnitConflict.engage(units, no_consent_part,
		_context(no_consent_part), _request("unit-reject-consent"), START + 20.0)
	_expect(not no_consent.ok and no_consent.reason == "no_consent",
		"未同意拒绝透传结算原因")

	var outside: Dictionary = UnitConflict.engage(units, _participation(),
		_context(_participation()),
		_request("unit-reject-window", ["unit_a01"], ["unit_d01"],
			START + 2.0 * HOUR + 10.0), START + 2.0 * HOUR + 20.0)
	_expect(not outside.ok and outside.reason == "stale_window",
		"参与窗口外拒绝透传结算原因")

	var poor: Dictionary = _request("unit-reject-supplies")
	poor["resources"][ATTACKER]["supplies"] = 10
	var poor_result: Dictionary = UnitConflict.engage(units, _participation(),
		_context(_participation()), poor, START + 20.0)
	_expect(not poor_result.ok and poor_result.reason == "insufficient_supply",
		"调用方出征粮草不足时透传结算原因")
	_expect(JSON.stringify(units) == before, "所有结算拒绝都不修改单位文档")


func _test_idempotency() -> void:
	var units: Dictionary = _units()
	var participation: Dictionary = _participation()
	var context: Dictionary = _context(participation)
	var request: Dictionary = _request()
	var first: Dictionary = UnitConflict.engage(units, participation, context, request,
		START + 20.0)
	_expect(first.ok, "幂等夹具首次交战成功")
	var before: String = JSON.stringify(units)

	var replay: Dictionary = UnitConflict.engage(units, participation,
		first.settlement.next_context, request, START + 20.0)
	_expect(replay.ok and replay.duplicate, "同 id 同 payload 重试回放")
	_expect(replay.outcome == first.outcome, "回放返回首次结算结果")
	_expect(replay.units == first.units, "回放重新得到相同的候选单位文档")
	_expect(replay.settlement.freeze == first.settlement.freeze,
		"回放返回首次冻结项")
	_expect(JSON.stringify(units) == before, "回放不修改输入单位文档")

	var changed_time: Dictionary = request.duplicate(true)
	changed_time["at_utc"] = START + 11.0
	var conflict: Dictionary = UnitConflict.engage(units, participation,
		first.settlement.next_context, changed_time, START + 20.0)
	_expect(not conflict.ok and conflict.reason == "duplicate_command",
		"同 id 换结算 payload 返回 duplicate_command")

	var changed_units: Dictionary = request.duplicate(true)
	changed_units["attacker_units"] = ["unit_a01"]
	var troop_conflict: Dictionary = UnitConflict.engage(units, participation,
		first.settlement.next_context, changed_units, START + 20.0)
	_expect(not troop_conflict.ok and troop_conflict.reason == "duplicate_command",
		"同 id 改变兵力使其成为不同 payload 并冲突")
	_expect(JSON.stringify(units) == before, "冲突不修改输入单位文档")


func _test_determinism() -> void:
	var request: Dictionary = _request()
	var left: Dictionary = UnitConflict.engage(_units(), _participation(),
		_context(_participation()), request, START + 20.0)
	var right: Dictionary = UnitConflict.engage(_units(), _participation(),
		_context(_participation()), request.duplicate(true), START + 20.0)
	_expect(left.ok and right.ok, "确定性夹具交战成功")
	_expect(JSON.stringify(left) == JSON.stringify(right),
		"同一输入得到逐字节相同结果")

	var reordered: Dictionary = _request()
	reordered["attacker_units"] = ["unit_a01", "unit_a02"]
	reordered["defender_units"] = ["unit_d01", "unit_d02"]
	var ordered: Dictionary = UnitConflict.engage(_units(), _participation(),
		_context(_participation()), reordered, START + 20.0)
	_expect(ordered.ok and ordered.units == left.units,
		"单位列表顺序不影响分摊结果")


func _test_json_round_trip() -> void:
	var units: Dictionary = _units()
	var participation: Dictionary = _participation()
	var context: Dictionary = _context(participation)
	var first: Dictionary = UnitConflict.engage(units, participation, context,
		_request(), START + 20.0)
	_expect(first.ok, "JSON 往返夹具首次交战成功")
	var round: Variant = JSON.parse_string(JSON.stringify(first.units))
	_expect(round is Dictionary and Units.valid(round),
		"候选单位文档 JSON 往返仍通过严格校验")

	var next_context: Dictionary = first.settlement.next_context
	var second_request: Dictionary = _request("unit-engage-2", ["unit_a02"],
		["unit_d01"], START + HOUR + 10.0)
	second_request["resources"] = {
		ATTACKER: {"cash": 550, "supplies": 50},
		DEFENDER: {"cash": 200, "supplies": 100},
	}
	var second: Dictionary = UnitConflict.engage(round,
		next_context["participation"], next_context, second_request,
		START + HOUR + 20.0)
	_expect(second.ok, "JSON 往返后的单位文档可以继续交战")
	_expect(second.outcome.window_id == WINDOW_2, "第二次交战进入下一参与窗口")
	_expect(second.units["units"].has("unit_a02") == false,
		"人数不足的进攻方单位在第二次交战后消失")
	_expect(second.units["units"]["unit_d01"]["people"] == 120,
		"防守方单位在第二次交战中仍不减员")
	_expect(Units.valid(second.units), "第二次交战的候选单位文档有效")


func _guarded_units() -> Dictionary:
	var state: Dictionary = Units.initial_state(WORLD)
	state = _recruit(state, "unit_a01", ATTACKER, 100)
	state = _recruit(state, "unit_a02", ATTACKER, 50)
	state = _recruit(state, "unit_a03", ATTACKER, 30)
	state = _recruit(state, "unit_g01", DEFENDER, 100, "guard", "none")
	state = _recruit(state, "unit_g02", DEFENDER, 20, "guard", "basic")
	state = _recruit(state, "unit_d03", DEFENDER, 25)
	state = _recruit(state, "unit_d04", DEFENDER, 25)
	return state


func _defender_request() -> Dictionary:
	return _request("unit-engage-defender", ["unit_a01", "unit_a02"],
		["unit_g01", "unit_g02"])


func _units() -> Dictionary:
	var state: Dictionary = Units.initial_state(WORLD)
	state = _recruit(state, "unit_a01", ATTACKER, 100)
	state = _recruit(state, "unit_a02", ATTACKER, 50)
	state = _recruit(state, "unit_a03", ATTACKER, 30)
	state = _recruit(state, "unit_d01", DEFENDER, 120)
	state = _recruit(state, "unit_d02", DEFENDER, 80)
	state = _recruit(state, "unit_d03", DEFENDER, 25)
	return state


func _small_units() -> Dictionary:
	var state: Dictionary = Units.initial_state(WORLD)
	state = _recruit(state, "unit_x01", ATTACKER, 20)
	state = _recruit(state, "unit_y01", DEFENDER, 10)
	state = _recruit(state, "unit_y02", DEFENDER, 30)
	return state


func _recruit(state: Dictionary, unit_id: String, owner: String,
		people: int, kind: String = "militia",
		equipment: String = "none") -> Dictionary:
	var result: Dictionary = Units.recruit(state, _stock(), {
		"id": unit_id,
		"owner": owner,
		"kind": kind,
		"people": people,
		"equipment": equipment,
		"station": "station_uc",
	}, START)
	assert(result.ok, "测试夹具的单位必须能招募")
	return result.state


func _stock() -> Dictionary:
	return {"cash": 1000000, "supplies": 1000000}


func _participation() -> Dictionary:
	var state: Dictionary = Participation.initial_state(WORLD, HOST)
	assert(Participation.declare_regime(state, WORLD, HOST, {
		"tier": Participation.TIER_LIMITED,
		"declaration_id": "declaration_uc",
		"effective_utc": START,
		"higher_risk": true,
		"areas": [{"id": ZONE, "min_x": 0, "min_z": 0, "max_x": 9, "max_z": 9}],
		"windows": [
			{"id": WINDOW_1, "start_utc": START, "end_utc": START + HOUR},
			{"id": WINDOW_2, "start_utc": START + HOUR, "end_utc": START + 2.0 * HOUR},
		],
		"loss_cap": 100,
		"offline_loss_cap": 30,
	}, "declare_uc", START).ok, "测试夹具的参与制度声明必须被接受")
	assert(Participation.declare_participation(state, WORLD, ATTACKER,
		Participation.ROLE_ATTACKER, "consent_uc_a", START).ok,
		"测试夹具的进攻方同意必须被接受")
	assert(Participation.declare_participation(state, WORLD, DEFENDER,
		Participation.ROLE_DEFENDER, "consent_uc_d", START).ok,
		"测试夹具的防守方同意必须被接受")
	return state


func _participation_missing(role: String) -> Dictionary:
	var state: Dictionary = Participation.initial_state(WORLD, HOST)
	assert(Participation.declare_regime(state, WORLD, HOST, {
		"tier": Participation.TIER_LIMITED,
		"declaration_id": "declaration_uc_missing",
		"effective_utc": START,
		"higher_risk": true,
		"areas": [{"id": ZONE, "min_x": 0, "min_z": 0, "max_x": 9, "max_z": 9}],
		"windows": [
			{"id": WINDOW_1, "start_utc": START, "end_utc": START + HOUR},
		],
		"loss_cap": 100,
		"offline_loss_cap": 30,
	}, "declare_uc_missing", START).ok, "缺失同意夹具的声明必须被接受")
	if role != "attacker":
		assert(Participation.declare_participation(state, WORLD, ATTACKER,
			Participation.ROLE_ATTACKER, "consent_uc_missing_a", START).ok,
			"缺失同意夹具的进攻方同意必须被接受")
	if role != "defender":
		assert(Participation.declare_participation(state, WORLD, DEFENDER,
			Participation.ROLE_DEFENDER, "consent_uc_missing_d", START).ok,
			"缺失同意夹具的防守方同意必须被接受")
	return state


func _context(participation: Dictionary) -> Dictionary:
	var context: Dictionary = Settlement.initial_context(WORLD, participation)
	context["targets"] = {
		TARGET: {
			"key": TARGET,
			"target": DEFENDER,
			"parcel_id": PARCEL,
			"lost": 0,
			"cap": 300,
		},
	}
	return context


func _request(command_id: String = "unit-engage-1",
		attacker_units: Array = ["unit_a02", "unit_a01"],
		defender_units: Array = ["unit_d02", "unit_d01"],
		at_utc: float = START + 10.0) -> Dictionary:
	return {
		"id": command_id,
		"attacker": ATTACKER,
		"defender": DEFENDER,
		"attacker_units": attacker_units.duplicate(),
		"defender_units": defender_units.duplicate(),
		"resources": {
			ATTACKER: {"cash": 500, "supplies": 200},
			DEFENDER: {"cash": 300, "supplies": 100},
		},
		"x": 1,
		"z": 1,
		"defender_online": true,
		"at_utc": at_utc,
		"target_parcel": PARCEL,
	}


func _freeze_amount(freeze: Array, owner: String, resource: String,
		reason: String) -> int:
	var total: int = 0
	for item: Variant in freeze:
		if not item is Dictionary:
			continue
		if str(item.get("owner", "")) == owner \
				and str(item.get("resource", "")) == resource \
				and str(item.get("reason", "")) == reason:
			total += int(item.get("amount", 0))
	return total


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
