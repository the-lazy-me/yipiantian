extends SceneTree
## M12-03 交战结算：纯规则无头测试。无场景、无时钟、无随机数、无网络、
## 无存档文档；每条命令都显式传入 UTC 时间。最后一行是验证证据。

const Settlement = preload("res://world/conflict_settlement.gd")
const Participation = preload("res://conflict/participation_state.gd")

const START: float = 1800000000.0
const HOUR: float = 3600.0
const WORLD: String = "world-settlement-a"
const OTHER_WORLD: String = "world-settlement-b"
const HOST: String = "player_00000000000000000000000000000001"
const ATTACKER: String = "player_00000000000000000000000000000002"
const DEFENDER: String = "player_00000000000000000000000000000003"
const NEIGHBOR: String = "player_00000000000000000000000000000004"

const PARCEL: String = "parcel_01"
const PARCEL_B: String = "parcel_02"
const TARGET: String = DEFENDER + "|" + PARCEL
const TARGET_B: String = NEIGHBOR + "|" + PARCEL_B
const ZONE: String = "zone_a"
const WINDOW_1: String = "window_1"
const WINDOW_2: String = "window_2"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_initial_and_success()
	_test_peace_and_consent()
	_test_time_guards()
	_test_target_cap()
	_test_participation_cap_and_offline()
	_test_windows_and_target_budget()
	_test_resources()
	_test_idempotency()
	_test_determinism_and_conservation()
	_test_invalid_shape()
	_test_document_validation()
	_test_json_round_trip()
	for failure: String in failures:
		push_error(failure)
	print("CONFLICT_SETTLEMENT_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_initial_and_success() -> void:
	var context: Dictionary = _context()
	_expect(Settlement.valid_context(context), "刚构建的结算上下文有效")
	_expect(Settlement.valid_context(Settlement.initial_context(WORLD, _participation())),
		"空资源空目标的初始上下文有效")
	var before: Dictionary = context.duplicate(true)
	var result: Dictionary = Settlement.settle(context,
		_command("settle-1", 20, START + 10.0), START + 20.0)
	_expect(result.ok, "合法交战可以结算")
	_expect(not result.duplicate, "第一次结算不是回放")
	_expect(context == before, "结算不修改输入上下文")
	var outcome: Dictionary = result.outcome
	_expect(outcome.losses == 20, "损失等于投入兵力")
	_expect(outcome.taken_cash == 20 and outcome.taken_supplies == 0,
		"损失先扣防守方现金")
	_expect(outcome.spoils == 10, "战利品为实际损失的一半")
	_expect(outcome.spoils <= outcome.losses, "战利品不超过实际损失")
	_expect(outcome.supply_cost == 20, "出征消耗按兵力计算")
	_expect(outcome.destroyed == 30, "销毁量等于出征消耗加未发放战利品")
	_expect(outcome.target_lost_before == 0 and outcome.target_lost_after == 20,
		"目标累计损失前进")
	_expect(outcome.window_id == WINDOW_1, "结算记录参与制度窗口")
	_expect(outcome.participation_loss_before == 0 and outcome.participation_cap == 100,
		"参与上限来自参与制度")
	_expect(result.freeze.size() == 2, "冻结项包含出征消耗与被扣损失")
	_expect(_freeze_amount(result.freeze, ATTACKER, "supplies", "attack_cost") == 20,
		"进攻方冻结出征消耗")
	_expect(_freeze_amount(result.freeze, DEFENDER, "cash", "at_risk_loss") == 20,
		"防守方冻结现金损失")
	var next: Dictionary = result.next_context
	_expect(next["resources"][ATTACKER]["cash"] == 510, "进攻方获得现金战利品")
	_expect(next["resources"][ATTACKER]["supplies"] == 180, "进攻方支付出征消耗")
	_expect(next["resources"][DEFENDER]["cash"] == 280, "防守方现金被扣")
	_expect(next["resources"][DEFENDER]["supplies"] == 100, "防守方物资未被多扣")
	_expect(next["targets"][TARGET]["lost"] == 20, "候选文档累计目标损失")
	_expect(next["participation"]["engagements"].has("settle-1"),
		"参与制度记录耐久交战行")
	_expect(Settlement.valid_context(next), "结算后的候选文档有效")
	_expect(Settlement.valid_context(JSON.parse_string(JSON.stringify(next))),
		"候选文档 JSON 往返仍有效")


func _test_peace_and_consent() -> void:
	var peace_context: Dictionary = _context_with(Participation.initial_state(WORLD, HOST))
	var peace_before: Dictionary = peace_context.duplicate(true)
	var peace: Dictionary = Settlement.settle(peace_context,
		_command("settle-peace", 5, START + 10.0), START + 20.0)
	_expect(not peace.ok and peace.reason == "peace_time", "和平档在结算层拒绝")
	_expect(peace_context == peace_before, "和平拒绝不修改上下文")

	var no_attacker: Dictionary = Settlement.settle(_context_with(_participation_missing("attacker")),
		_command("settle-no-attacker", 5, START + 10.0), START + 20.0)
	_expect(not no_attacker.ok and no_attacker.reason == "no_consent",
		"进攻方未同意时拒绝")
	var no_defender: Dictionary = Settlement.settle(_context_with(_participation_missing("defender")),
		_command("settle-no-defender", 5, START + 10.0), START + 20.0)
	_expect(not no_defender.ok and no_defender.reason == "no_consent",
		"防守方未同意时拒绝")

	var withdrawn_participation: Dictionary = _participation()
	assert(Participation.withdraw(withdrawn_participation, WORLD, ATTACKER,
		"withdraw-attacker", START).ok)
	var withdrawn_context: Dictionary = _context_with(withdrawn_participation)
	var at_effective: float = START + Participation.WITHDRAWAL_DELAY_SECONDS
	var withdrawn: Dictionary = Settlement.settle(withdrawn_context,
		_command("settle-withdrawn", 5, at_effective), at_effective + 10.0)
	_expect(not withdrawn.ok and withdrawn.reason == "no_consent",
		"退战生效后拒绝进攻方的新交战")
	_expect(withdrawn_context["targets"][TARGET]["lost"] == 0,
		"退战拒绝不写入目标损失")


func _test_time_guards() -> void:
	var context: Dictionary = _context()
	var future: Dictionary = Settlement.settle(context,
		_command("settle-future", 5, START + 10.0), START + 5.0)
	_expect(not future.ok and future.reason == "future_time", "晚于当前时刻的命令被拒")
	var stale: Dictionary = Settlement.settle(context,
		_command("settle-stale", 5, START + 10.0),
		START + 10.0 + Settlement.COMMAND_MAX_AGE_SECONDS + 1.0)
	_expect(not stale.ok and stale.reason == "stale_window", "超过命令年龄的命令被拒")
	var boundary: Dictionary = Settlement.settle(context,
		_command("settle-age-boundary", 1, START + 10.0),
		START + 10.0 + Settlement.COMMAND_MAX_AGE_SECONDS)
	_expect(boundary.ok, "命令年龄等于上限时仍可结算")
	var outside: Dictionary = Settlement.settle(context,
		_command("settle-outside", 5, START + 3.0 * HOUR), START + 3.0 * HOUR + 10.0)
	_expect(not outside.ok and outside.reason == "stale_window",
		"声明窗口之外的命令被拒")
	var before_effective: Dictionary = Settlement.settle(context,
		_command("settle-before", 5, START - 10.0), START)
	_expect(not before_effective.ok and before_effective.reason == "stale_window",
		"制度生效前的命令被拒")
	_expect(Settlement.settle(context, _command("settle-now-negative", 5, START + 10.0),
		-1.0).reason == "invalid_time", "负的当前时刻被拒")
	_expect(Settlement.settle(context, _command("settle-now-inf", 5, START + 10.0),
		INF).reason == "invalid_time", "非有限当前时刻被拒")


func _test_target_cap() -> void:
	var context: Dictionary = _context()
	context["targets"][TARGET]["cap"] = 10
	var first: Dictionary = Settlement.settle(context,
		_command("settle-cap-1", 20, START + 10.0), START + 20.0)
	_expect(first.ok and first.outcome.losses == 10,
		"单次损失被同目标上限压低")
	var second: Dictionary = Settlement.settle(first.next_context,
		_command("settle-cap-2", 20, START + 20.0), START + 30.0)
	_expect(not second.ok and second.reason == "target_cap",
		"同目标上限耗尽后反复袭击被拒")
	_expect(second.next_context["resources"][DEFENDER]["cash"] == 290,
		"上限拒绝不重复扣除防守方资源")
	_expect(second.next_context["targets"][TARGET]["lost"] == 10,
		"上限拒绝不增加目标损失")
	var neighbor: Dictionary = Settlement.settle(first.next_context,
		_command("settle-cap-neighbor", 20, START + 20.0, PARCEL_B, NEIGHBOR), START + 30.0)
	_expect(neighbor.ok, "另一个目标有独立的累计上限")

	var capped: Dictionary = _context()
	capped["targets"][TARGET]["cap"] = 40
	var step1: Dictionary = Settlement.settle(capped,
		_command("settle-cap-a", 20, START + 10.0), START + 20.0)
	var step2: Dictionary = Settlement.settle(step1.next_context,
		_command("settle-cap-b", 20, START + 20.0), START + 30.0)
	var step3: Dictionary = Settlement.settle(step2.next_context,
		_command("settle-cap-c", 20, START + 30.0), START + 40.0)
	_expect(step1.ok and step2.ok, "目标上限内可以连续结算两次")
	_expect(not step3.ok and step3.reason == "target_cap",
		"第三次反复袭击不能突破同目标上限")
	_expect(step3.next_context["targets"][TARGET]["lost"] == 40,
		"反复袭击后目标损失恰好停在上限")
	_expect(step3.next_context["resources"][DEFENDER]["cash"] == 260,
		"反复袭击只按两次成功结算扣资源")


func _test_participation_cap_and_offline() -> void:
	var low_cap: Dictionary = _context(5, 3)
	var first: Dictionary = Settlement.settle(low_cap,
		_command("settle-low-1", 20, START + 10.0), START + 20.0)
	_expect(first.ok and first.outcome.losses == 5,
		"实际损失被参与制度总上限压低")
	_expect(first.outcome.participation_cap == 5, "结果记录参与总上限")
	var second: Dictionary = Settlement.settle(first.next_context,
		_command("settle-low-2", 20, START + 20.0), START + 30.0)
	_expect(not second.ok and second.reason == "target_cap",
		"参与总上限耗尽后拒绝新交战")

	var offline_context: Dictionary = _context(100, 30)
	var offline1: Dictionary = Settlement.settle(offline_context,
		_command("settle-offline-1", 50, START + 10.0, PARCEL, DEFENDER, 1, 1, false),
		START + 20.0)
	_expect(offline1.ok and offline1.outcome.losses == 30,
		"离线防守方使用更小的离线上限")
	_expect(offline1.outcome.participation_cap == 30, "结果记录离线上限")
	var offline2: Dictionary = Settlement.settle(offline1.next_context,
		_command("settle-offline-2", 50, START + 20.0, PARCEL, DEFENDER, 1, 1, false),
		START + 30.0)
	_expect(not offline2.ok and offline2.reason == "target_cap",
		"离线上限耗尽后不能继续掠夺")
	var online: Dictionary = Settlement.settle(offline1.next_context,
		_command("settle-online-after", 50, START + 30.0, PARCEL, DEFENDER, 1, 1, true),
		START + 40.0)
	_expect(online.ok and online.outcome.losses == 50,
		"在线补打使用总上限的剩余额度")
	_expect(online.outcome.participation_loss_before == 30,
		"在线与离线共享同一窗口累计损失")
	_expect(online.outcome.participation_loss_before + online.outcome.losses == 80,
		"共享累计后总损失不超过在线总上限")


func _test_windows_and_target_budget() -> void:
	var context: Dictionary = _context()
	context["targets"][TARGET]["cap"] = 30
	var first: Dictionary = Settlement.settle(context,
		_command("settle-window-1", 20, START + 10.0), START + 20.0)
	var second: Dictionary = Settlement.settle(first.next_context,
		_command("settle-window-2", 20, START + HOUR + 10.0), START + HOUR + 20.0)
	_expect(first.ok and first.outcome.window_id == WINDOW_1, "第一窗口记录自己的窗口 id")
	_expect(second.ok and second.outcome.window_id == WINDOW_2,
		"第二窗口记录自己的窗口 id")
	_expect(second.outcome.losses == 10, "第二窗口仍受同目标总上限约束")
	_expect(second.next_context["targets"][TARGET]["lost"] == 30,
		"跨窗口累计到目标上限")
	var third: Dictionary = Settlement.settle(second.next_context,
		_command("settle-window-3", 1, START + 30.0), START + 40.0)
	_expect(not third.ok and third.reason == "target_cap",
		"目标上限跨窗口共享，第三窗口不能突破")
	_expect(Participation.loss_total(second.next_context["participation"],
		DEFENDER, WINDOW_1) == 20, "参与制度第一窗口累计 20")
	_expect(Participation.loss_total(second.next_context["participation"],
		DEFENDER, WINDOW_2) == 10, "参与制度第二窗口累计 10")


func _test_resources() -> void:
	var poor_attacker: Dictionary = _context()
	poor_attacker["resources"][ATTACKER]["supplies"] = 5
	var no_cost: Dictionary = Settlement.settle(poor_attacker,
		_command("settle-poor-attacker", 20, START + 10.0), START + 20.0)
	_expect(not no_cost.ok and no_cost.reason == "insufficient_resources",
		"进攻方物资不足以支付出征消耗时拒绝")
	_expect(poor_attacker["resources"][ATTACKER]["supplies"] == 5,
		"资源不足拒绝不扣除物资")

	var empty_defender: Dictionary = _context()
	empty_defender["resources"][DEFENDER] = {"cash": 0, "supplies": 0}
	var no_loot: Dictionary = Settlement.settle(empty_defender,
		_command("settle-empty-defender", 20, START + 10.0), START + 20.0)
	_expect(not no_loot.ok and no_loot.reason == "insufficient_resources",
		"防守方没有任何可损失资源时拒绝零值结算")
	_expect(empty_defender["targets"][TARGET]["lost"] == 0,
		"零资源拒绝不增加目标损失")

	var short_cash: Dictionary = _context()
	short_cash["resources"][DEFENDER] = {"cash": 5, "supplies": 100}
	var before_total: int = _total(short_cash, ATTACKER) + _total(short_cash, DEFENDER)
	var mixed: Dictionary = Settlement.settle(short_cash,
		_command("settle-short-cash", 20, START + 10.0), START + 20.0)
	_expect(mixed.ok, "防守方现金不足但物资足够时仍可结算")
	_expect(mixed.outcome.taken_cash == 5 and mixed.outcome.taken_supplies == 15,
		"损失先扣现金再扣物资")
	_expect(mixed.outcome.spoils_cash == 2 and mixed.outcome.spoils_supplies == 7,
		"战利品按现金与物资分别取半")
	_expect(mixed.outcome.spoils == 9 and mixed.outcome.destroyed == 31,
		"混合资源损失的战利品与销毁量正确")
	var next: Dictionary = mixed.next_context
	_expect(next["resources"][DEFENDER]["cash"] == 0
		and next["resources"][DEFENDER]["supplies"] == 85,
		"防守方资源不会被扣成负数")
	_expect(next["resources"][ATTACKER]["cash"] == 502
		and next["resources"][ATTACKER]["supplies"] == 187,
		"进攻方战利品与出征消耗按资源种类结算")
	_expect(_all_non_negative(next), "结算后所有资源非负")
	_expect(before_total - _total(next, ATTACKER) - _total(next, DEFENDER)
		== mixed.outcome.destroyed, "混合资源结算满足总量守恒")


func _test_idempotency() -> void:
	var context: Dictionary = _context()
	var command: Dictionary = _command("settle-dup", 20, START + 10.0)
	var first: Dictionary = Settlement.settle(context, command, START + 20.0)
	_expect(first.ok and not first.duplicate, "首次幂等用例结算成功")
	var replay: Dictionary = Settlement.settle(first.next_context, command, START + 20.0)
	_expect(replay.ok and replay.duplicate, "同 id 同 payload 重试回放首次结果")
	_expect(replay.outcome == first.outcome, "回放结果与首次一致")
	_expect(replay.next_context == first.next_context, "回放不改变候选文档")
	_expect(replay.next_context["resources"][DEFENDER]["cash"] == 280,
		"重试不重复扣除防守方损失")
	_expect(replay.next_context["resources"][ATTACKER]["cash"] == 510,
		"重试不重复发放战利品")
	_expect(replay.next_context["participation"]["engagements"].size() == 1,
		"重试不重复写入参与制度交战行")
	var conflict: Dictionary = Settlement.settle(first.next_context,
		_command("settle-dup", 21, START + 10.0), START + 20.0)
	_expect(not conflict.ok and conflict.reason == "duplicate_command",
		"同 id 换 payload 返回 duplicate_command")

	var pre: Dictionary = _participation()
	assert(Participation.engage(pre, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 10.0, 5, true, "settle-taken").ok)
	var pre_context: Dictionary = _context_with(pre)
	var taken: Dictionary = Settlement.settle(pre_context,
		_command("settle-taken", 10, START + 20.0), START + 30.0)
	_expect(not taken.ok and taken.reason == "duplicate_command",
		"参与制度耐久行已占用 id 时拒绝重复结算")
	_expect(Settlement.valid_context(pre_context),
		"参与制度已有交战但结算表为空时上下文仍有效")


func _test_determinism_and_conservation() -> void:
	var command: Dictionary = _command("settle-det", 20, START + 10.0)
	var left: Dictionary = Settlement.settle(_context(), command, START + 20.0)
	var right: Dictionary = Settlement.settle(_context(), command, START + 20.0)
	_expect(JSON.stringify(left) == JSON.stringify(right),
		"同一输入得到逐字节相同的结算结果")
	_expect(left.outcome == right.outcome and left.freeze == right.freeze,
		"确定性覆盖结果与冻结项")

	var context: Dictionary = _context()
	var before_total: int = _total(context, ATTACKER) + _total(context, DEFENDER)
	var result: Dictionary = Settlement.settle(context, command, START + 20.0)
	var after_total: int = _total(result.next_context, ATTACKER) \
		+ _total(result.next_context, DEFENDER)
	_expect(before_total - after_total == result.outcome.destroyed,
		"双方资源总量减少量等于明确销毁量")
	_expect(_all_non_negative(result.next_context), "结算后资源不为负")
	_expect(result.outcome.spoils <= result.outcome.losses,
		"守恒样例战利品不超过损失")
	_expect(result.outcome.spoils + (result.outcome.destroyed
		- result.outcome.supply_cost) == result.outcome.losses,
		"防守方损失由战利品和销毁量完整解释")


func _test_invalid_shape() -> void:
	var context: Dictionary = _context()
	var now: float = START + 20.0
	var base: Dictionary = _command("settle-shape", 10, START + 10.0)
	_expect(Settlement.settle(context, null, now).reason == "invalid_command",
		"非字典命令被拒")
	_expect(Settlement.settle(context, "nope", now).reason == "invalid_command",
		"字符串命令被拒")
	_expect(Settlement.settle(context, {}, now).reason == "invalid_command",
		"空命令被拒")
	var missing: Dictionary = base.duplicate(true)
	missing.erase("troops")
	_expect(Settlement.settle(context, missing, now).reason == "invalid_command",
		"缺必需字段的命令被拒")
	var extra: Dictionary = base.duplicate(true)
	extra["surprise"] = 1
	_expect(Settlement.settle(context, extra, now).reason == "invalid_command",
		"多出未知字段的命令被拒")
	var empty_id: Dictionary = base.duplicate(true)
	empty_id["id"] = ""
	_expect(Settlement.settle(context, empty_id, now).reason == "invalid_command",
		"空命令 id 被拒")
	var bad_attacker: Dictionary = base.duplicate(true)
	bad_attacker["attacker"] = "public"
	_expect(Settlement.settle(context, bad_attacker, now).reason == "invalid_attacker",
		"非法进攻方 id 被拒")
	var bad_defender: Dictionary = base.duplicate(true)
	bad_defender["defender"] = ""
	_expect(Settlement.settle(context, bad_defender, now).reason == "invalid_defender",
		"非法防守方 id 被拒")
	var same: Dictionary = base.duplicate(true)
	same["defender"] = ATTACKER
	_expect(Settlement.settle(context, same, now).reason == "same_player",
		"自攻被拒")
	for troops: Variant in [0, -1, 1.5, "20", Settlement.MAX_TROOPS + 1]:
		var bad_troops: Dictionary = base.duplicate(true)
		bad_troops["troops"] = troops
		_expect(Settlement.settle(context, bad_troops, now).reason == "invalid_troops",
			"非法兵力 %s 被拒" % str(troops))
	var bad_x: Dictionary = base.duplicate(true)
	bad_x["x"] = -1
	_expect(Settlement.settle(context, bad_x, now).reason == "invalid_position",
		"负坐标被拒")
	var bad_z: Dictionary = base.duplicate(true)
	bad_z["z"] = Settlement.MAX_COORD + 1
	_expect(Settlement.settle(context, bad_z, now).reason == "invalid_position",
		"越界坐标被拒")
	var bad_at: Dictionary = base.duplicate(true)
	bad_at["at_utc"] = -1.0
	_expect(Settlement.settle(context, bad_at, now).reason == "invalid_time",
		"负命令时间被拒")
	var inf_at: Dictionary = base.duplicate(true)
	inf_at["at_utc"] = INF
	_expect(Settlement.settle(context, inf_at, now).reason == "invalid_time",
		"非有限命令时间被拒")
	var bad_online: Dictionary = base.duplicate(true)
	bad_online["defender_online"] = "yes"
	_expect(Settlement.settle(context, bad_online, now).reason == "invalid_command",
		"非布尔在线标记被拒")
	var bad_parcel: Dictionary = base.duplicate(true)
	bad_parcel["target_parcel"] = 5
	_expect(Settlement.settle(context, bad_parcel, now).reason == "invalid_target",
		"非字符串地块 id 被拒")
	var malformed_parcel: Dictionary = base.duplicate(true)
	malformed_parcel["target_parcel"] = "bad id!"
	_expect(Settlement.settle(context, malformed_parcel, now).reason == "invalid_target",
		"非法地块 id 被拒")
	var unknown_parcel: Dictionary = base.duplicate(true)
	unknown_parcel["target_parcel"] = "parcel_09"
	_expect(Settlement.settle(context, unknown_parcel, now).reason == "unknown_target",
		"没有目标预算的地块被拒")
	_expect(Settlement.settle(null, base, now).reason == "invalid_context",
		"非字典上下文被拒")
	_expect(Settlement.settle({}, base, now).reason == "invalid_context",
		"空上下文被拒")


func _test_document_validation() -> void:
	_expect(not Settlement.valid_context(null), "空值不是有效上下文")
	_expect(not Settlement.valid_context("context"), "字符串不是有效上下文")
	var extra: Dictionary = _context()
	extra["extra"] = 1
	_expect(not Settlement.valid_context(extra), "多出未知键的上下文无效")
	var missing: Dictionary = _context()
	missing.erase("targets")
	_expect(not Settlement.valid_context(missing), "缺键的上下文无效")
	var negative: Dictionary = _context()
	var negative_resources: Dictionary = negative["resources"]
	negative_resources[ATTACKER]["cash"] = -1
	_expect(not Settlement.valid_context(negative), "负资源上下文无效")
	var wrong_world: Dictionary = Settlement.initial_context(OTHER_WORLD, _participation())
	_expect(not Settlement.valid_context(wrong_world),
		"参与制度与结算世界不一致时无效")
	var no_participation: Dictionary = _context()
	no_participation["participation"] = {}
	_expect(not Settlement.valid_context(no_participation), "缺失参与制度时无效")
	var over_cap: Dictionary = _context()
	over_cap["targets"][TARGET]["lost"] = 101
	_expect(not Settlement.valid_context(over_cap), "目标损失超过上限时无效")
	var zero_cap: Dictionary = _context()
	zero_cap["targets"][TARGET]["cap"] = 0
	_expect(not Settlement.valid_context(zero_cap), "目标上限为零时无效")
	var key_mismatch: Dictionary = _context()
	key_mismatch["targets"][TARGET]["key"] = "other"
	_expect(not Settlement.valid_context(key_mismatch), "目标键与行不一致时无效")

	var result: Dictionary = Settlement.settle(_context(),
		_command("settle-valid", 20, START + 10.0), START + 20.0)
	_expect(result.ok, "文档校验夹具结算成功")
	var forged_outcome: Dictionary = result.next_context.duplicate(true)
	var forged_consumed: Dictionary = forged_outcome["consumed"]
	forged_consumed["settle-valid"]["outcome"]["losses"] = 21
	_expect(not Settlement.valid_context(forged_outcome), "伪造结果损失时无效")
	var forged_target: Dictionary = result.next_context.duplicate(true)
	var forged_targets: Dictionary = forged_target["targets"]
	forged_targets[TARGET]["lost"] = 21
	_expect(not Settlement.valid_context(forged_target), "目标累计与结果之和不一致时无效")
	var forged_sequence: Dictionary = result.next_context.duplicate(true)
	forged_sequence["sequence"] = 0
	_expect(not Settlement.valid_context(forged_sequence), "序列小于已消费命令数时无效")
	var forged_payload: Dictionary = result.next_context.duplicate(true)
	var forged_payload_consumed: Dictionary = forged_payload["consumed"]
	forged_payload_consumed["settle-valid"]["payload"] = "[]"
	_expect(not Settlement.valid_context(forged_payload), "伪造命令 payload 时无效")
	var forged_freeze: Dictionary = result.next_context.duplicate(true)
	var forged_freeze_consumed: Dictionary = forged_freeze["consumed"]
	forged_freeze_consumed["settle-valid"]["freeze"][0]["amount"] = 21
	_expect(not Settlement.valid_context(forged_freeze), "伪造冻结项金额时无效")
	var forged_engagement: Dictionary = result.next_context.duplicate(true)
	var forged_participation: Dictionary = forged_engagement["participation"]
	forged_participation["engagements"]["settle-valid"]["amount"] = 19
	_expect(not Settlement.valid_context(forged_engagement), "参与制度交战行被篡改时无效")
	var pre: Dictionary = _participation()
	assert(Participation.engage(pre, WORLD, ATTACKER, DEFENDER, 1, 1,
		START + 5.0, 5, true, "pre-existing").ok)
	_expect(Settlement.valid_context(_context_with(pre)),
		"参与制度历史交战不在结算已消费表时仍有效")


func _test_json_round_trip() -> void:
	var first: Dictionary = Settlement.settle(_context(),
		_command("settle-json-1", 20, START + 10.0), START + 20.0)
	_expect(first.ok, "JSON 往返夹具首次结算成功")
	var round: Variant = JSON.parse_string(JSON.stringify(first.next_context))
	_expect(round is Dictionary and Settlement.valid_context(round),
		"JSON 往返后的上下文仍通过严格校验")
	var second: Dictionary = Settlement.settle(round,
		_command("settle-json-2", 5, START + 30.0), START + 40.0)
	_expect(second.ok, "JSON 往返后的上下文仍可继续结算")
	_expect(second.next_context["targets"][TARGET]["lost"] == 25,
		"JSON 往返后目标累计继续前进")
	_expect(Settlement.valid_context(second.next_context),
		"JSON 往返后的第二次结算文档有效")
	var replay: Dictionary = Settlement.settle(second.next_context,
		_command("settle-json-1", 20, START + 10.0), START + 20.0)
	_expect(replay.ok and replay.duplicate,
		"JSON 往返后旧命令仍可幂等回放")
	_expect(replay.next_context["resources"][DEFENDER]["cash"] == 275,
		"旧命令回放不重复扣除资源")


func _context(loss_cap: int = 100, offline_cap: int = 30) -> Dictionary:
	return _context_with(_participation(loss_cap, offline_cap))


func _context_with(participation: Dictionary) -> Dictionary:
	var context: Dictionary = Settlement.initial_context(WORLD, participation)
	var resources: Dictionary = {
		ATTACKER: {"cash": 500, "supplies": 200},
		DEFENDER: {"cash": 300, "supplies": 100},
		NEIGHBOR: {"cash": 200, "supplies": 80},
	}
	context["resources"] = resources
	var targets: Dictionary = {
		TARGET: _target(DEFENDER, PARCEL, 0, 100),
		TARGET_B: _target(NEIGHBOR, PARCEL_B, 0, 100),
	}
	context["targets"] = targets
	return context


func _participation(loss_cap: int = 100, offline_cap: int = 30) -> Dictionary:
	var state: Dictionary = Participation.initial_state(WORLD, HOST)
	_declare_active(state, loss_cap, offline_cap)
	assert(Participation.declare_participation(state, WORLD, ATTACKER,
		Participation.ROLE_ATTACKER, "consent-attacker", START).ok)
	assert(Participation.declare_participation(state, WORLD, DEFENDER,
		Participation.ROLE_DEFENDER, "consent-defender", START).ok)
	assert(Participation.declare_participation(state, WORLD, NEIGHBOR,
		Participation.ROLE_DEFENDER, "consent-neighbor", START).ok)
	return state


func _participation_missing(role: String) -> Dictionary:
	var state: Dictionary = Participation.initial_state(WORLD, HOST)
	_declare_active(state, 100, 30)
	if role != "attacker":
		assert(Participation.declare_participation(state, WORLD, ATTACKER,
			Participation.ROLE_ATTACKER, "consent-attacker", START).ok)
	if role != "defender":
		assert(Participation.declare_participation(state, WORLD, DEFENDER,
			Participation.ROLE_DEFENDER, "consent-defender", START).ok)
	return state


func _declare_active(state: Dictionary, loss_cap: int, offline_cap: int) -> void:
	var result: Dictionary = Participation.declare_regime(state, WORLD, HOST,
		_declaration("d-active", Participation.TIER_LIMITED, START, true,
			[_area(ZONE, 0, 0, 9, 9)],
			[_window(WINDOW_1, START, START + HOUR),
			_window(WINDOW_2, START + HOUR, START + 2.0 * HOUR)],
			loss_cap, offline_cap),
		"declare-active", START)
	assert(result.ok, "测试夹具的参与制度声明必须被接受")


func _declaration(declaration_id: String, tier: String, effective_utc: float,
		higher_risk: bool, areas: Array, windows: Array, loss_cap: int,
		offline_cap: int) -> Dictionary:
	return {
		"tier": tier,
		"declaration_id": declaration_id,
		"effective_utc": effective_utc,
		"higher_risk": higher_risk,
		"areas": areas,
		"windows": windows,
		"loss_cap": loss_cap,
		"offline_loss_cap": offline_cap,
	}


func _area(area_id: String, min_x: int, min_z: int, max_x: int, max_z: int) -> Dictionary:
	return {"id": area_id, "min_x": min_x, "min_z": min_z, "max_x": max_x, "max_z": max_z}


func _window(window_id: String, start_utc: float, end_utc: float) -> Dictionary:
	return {"id": window_id, "start_utc": start_utc, "end_utc": end_utc}


func _target(player: String, parcel_id: String, lost: int, cap: int) -> Dictionary:
	return {
		"key": player + "|" + parcel_id,
		"target": player,
		"parcel_id": parcel_id,
		"lost": lost,
		"cap": cap,
	}


func _command(command_id: String, troops: int, at_utc: float,
		parcel_id: String = PARCEL, defender: String = DEFENDER, x: int = 1,
		z: int = 1, online: bool = true) -> Dictionary:
	return {
		"id": command_id,
		"attacker": ATTACKER,
		"defender": defender,
		"target_parcel": parcel_id,
		"troops": troops,
		"x": x,
		"z": z,
		"defender_online": online,
		"at_utc": at_utc,
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


func _total(context: Dictionary, player: String) -> int:
	var row: Variant = context["resources"].get(player)
	if not row is Dictionary:
		return 0
	return int(row.get("cash", 0)) + int(row.get("supplies", 0))


func _all_non_negative(context: Dictionary) -> bool:
	for player: Variant in context["resources"]:
		var row: Variant = context["resources"][player]
		if not row is Dictionary:
			return false
		if int(row.get("cash", 0)) < 0 or int(row.get("supplies", 0)) < 0:
			return false
	return true


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
