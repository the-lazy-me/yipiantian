extends SceneTree
## M11-03 规则决议效果纯规则切片的无头测试：不读场景、存档、网络或系统时钟。
## 同一序列必须得到同一文档；最后一行是验证证据。

const Effects = preload("res://world/resolution_effects.gd")
const Resolution = preload("res://world/resolution_state.gd")

const START: float = 1800000000.0
const HOUR: float = 3600.0
const VOTE_START: float = START + 60.0
const VOTE_END: float = VOTE_START + HOUR
const EFFECTIVE_UTC: float = VOTE_END + HOUR

const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const PLAYER_D: String = "player_00000000000000000000000000000004"
const PLAYER_E: String = "player_00000000000000000000000000000005"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_empty_and_shape()
	_test_apply_requires_active()
	_test_apply_once_per_version()
	_test_tax_is_future_only()
	_test_public_works_coefficients()
	_test_document_bounds_and_validation()
	_test_input_immutability_and_determinism()
	for failure: String in failures:
		push_error(failure)
	print("RESOLUTION_EFFECTS_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_empty_and_shape() -> void:
	var empty: Dictionary = Effects.empty()
	_expect(Effects.valid(empty), "空效果文档合法")
	_expect(int(empty.applied_version) == 0 and empty.applied.is_empty(),
		"空效果文档没有水位，也没有应用记录")
	_expect(not Effects.valid(null) and not Effects.valid([]) and not Effects.valid({}),
		"非字典或结构为空的文档被拒绝")
	_expect(Effects.valid(JSON.parse_string(JSON.stringify(empty))),
		"空文档经过 JSON 往返仍然合法")
	_expect(_rejects(empty, func(doc: Dictionary) -> void: doc["extra"] = true),
		"未知顶层键被拒绝")
	_expect(_rejects(empty, func(doc: Dictionary) -> void: doc.erase("applied_version")),
		"缺少 applied_version 被拒绝")
	_expect(_rejects(empty, func(doc: Dictionary) -> void: doc.erase("applied")),
		"缺少 applied 被拒绝")
	_expect(_rejects(empty, func(doc: Dictionary) -> void: doc["applied"] = {}),
		"applied 不是数组被拒绝")
	for bad_version: Variant in [-1, 1.5, INF, NAN, "1", true]:
		_expect(_rejects(empty, func(doc: Dictionary) -> void:
			doc["applied_version"] = bad_version),
			"非法的 applied_version 被拒绝")

	var tax: Dictionary = Effects.empty()
	var result: Dictionary = Effects.apply(tax, _tax_state(), "tax_1", EFFECTIVE_UTC)
	_expect(result.ok and Effects.valid(result.state), "合法税费应用后的文档合法")
	_expect(Effects.valid(JSON.parse_string(JSON.stringify(result.state))),
		"应用后的文档经过 JSON 往返仍然合法")
	_expect(result.state.applied.size() == 1, "一次应用只追加一条记录")
	_expect(int(result.state.applied[0].version) == 1
		and result.state.applied[0].kind == Resolution.KIND_TAX,
		"记录保存版本与决议类型")


func _test_apply_requires_active() -> void:
	var empty: Dictionary = Effects.empty()
	var state: Dictionary = _proposed_state()

	var unknown: Dictionary = Effects.apply(empty, state, "missing", EFFECTIVE_UTC)
	_expect(not unknown.ok and unknown.reason == "unknown_resolution",
		"未知决议不能应用")
	var bad_id: Dictionary = Effects.apply(empty, state, "bad id", EFFECTIVE_UTC)
	_expect(not bad_id.ok and bad_id.reason == "invalid_resolution",
		"非法决议 id 不能应用")

	var proposed: Dictionary = Effects.apply(empty, state, "tax_1", EFFECTIVE_UTC)
	_expect(not proposed.ok and proposed.reason == "not_active",
		"未生效的提案不能产生效果")

	var passed: Dictionary = _passed_state("tax_1")
	var not_yet: Dictionary = Effects.apply(empty, passed, "tax_1", EFFECTIVE_UTC)
	_expect(not not_yet.ok and not_yet.reason == "not_active",
		"已通过但未生效的提案不能产生效果")

	var withdrawn: Dictionary = Resolution.withdraw(state, "tax_1", PLAYER_A,
		VOTE_START + 10.0).state
	_expect(Effects.apply(empty, withdrawn, "tax_1", EFFECTIVE_UTC).reason == "not_active",
		"已撤案的提案不能产生效果")

	var rejected: Dictionary = Resolution.propose(state, "tax_2", PLAYER_B,
		_proposal_from(VOTE_START + HOUR), START).state
	rejected = Resolution.close(rejected, "tax_2", VOTE_END + HOUR).state
	_expect(rejected.resolutions["tax_2"].status == Resolution.STATUS_REJECTED,
		"无票提案被否决")
	_expect(Effects.apply(empty, rejected, "tax_2", EFFECTIVE_UTC + HOUR).reason
		== "not_active", "被否决的提案不能产生效果")

	var effective: Dictionary = _tax_state()
	var revoked: Dictionary = Resolution.revoke(effective, "tax_1", PLAYER_B,
		EFFECTIVE_UTC + 10.0).state
	_expect(Effects.apply(empty, revoked, "tax_1", EFFECTIVE_UTC + 20.0).reason
		== "not_active", "已撤销的决议不再产生新效果")

	var early: Dictionary = Effects.apply(empty, effective, "tax_1", EFFECTIVE_UTC - 1.0)
	_expect(not early.ok and early.reason == "not_effective",
		"未到生效时刻不能应用")
	var bad_time: Dictionary = Effects.apply(empty, effective, "tax_1", -1.0)
	_expect(not bad_time.ok and bad_time.reason == "invalid_time",
		"非法时刻不能应用")

	var broken: Dictionary = effective.duplicate(true)
	broken.resolutions["tax_1"]["status"] = "draft"
	_expect(Effects.apply(empty, broken, "tax_1", EFFECTIVE_UTC).reason == "invalid_state",
		"不合法的决议文档被拒绝")
	var broken_effects: Dictionary = {"applied_version": 2, "applied": []}
	_expect(Effects.apply(broken_effects, effective, "tax_1", EFFECTIVE_UTC).reason
		== "invalid_state", "水位高于决议规则版本被拒绝")


func _test_apply_once_per_version() -> void:
	var effect: Dictionary = Effects.empty()
	var resolutions: Dictionary = _tax_state()
	var first: Dictionary = Effects.apply(effect, resolutions, "tax_1", EFFECTIVE_UTC)
	_expect(first.ok and int(first.state.applied_version) == 1,
		"首次应用推进版本水位")
	var accepted: Dictionary = first.state.duplicate(true)
	var duplicate: Dictionary = Effects.apply(first.state, resolutions, "tax_1",
		EFFECTIVE_UTC + HOUR)
	_expect(not duplicate.ok and duplicate.reason == "already_applied",
		"同一生效版本只应用一次")
	_expect(first.state == accepted, "重复应用被拒绝后文档不变")
	var double_apply: Dictionary = Effects.apply(first.state, resolutions, "tax_1",
		EFFECTIVE_UTC)
	_expect(not double_apply.ok and double_apply.reason == "already_applied",
		"同一时刻重试同样被拒绝")

	# 撤销一个应用过的税费决议后，水位不变；新版本可继续应用。
	var revoked: Dictionary = Resolution.revoke(resolutions, "tax_1", PLAYER_B,
		EFFECTIVE_UTC + 10.0).state
	var retried: Dictionary = Effects.apply(first.state, revoked, "tax_1",
		EFFECTIVE_UTC + 20.0)
	_expect(not retried.ok and retried.reason == "not_active",
		"撤销后重试不会第二次生效")
	_expect(Effects.tax_rate(first.state, revoked, EFFECTIVE_UTC + 20.0).rate_permille == 0,
		"撤销后税费费率归零")

	var effect_json: Variant = JSON.parse_string(JSON.stringify(first.state))
	_expect(Effects.valid(effect_json), "应用记录经过 JSON 往返仍然合法")
	_expect(Effects.apply(effect_json, resolutions, "tax_1", EFFECTIVE_UTC + HOUR).reason
		== "already_applied", "JSON 往返后仍然拒绝重复应用")


func _test_tax_is_future_only() -> void:
	var effect: Dictionary = Effects.empty()
	var resolutions: Dictionary = _tax_state()
	_expect(Effects.tax_rate(effect, resolutions, EFFECTIVE_UTC).rate_permille == 0,
		"未应用的税费决议不产生费率")
	_expect(Effects.tax_for(effect, resolutions, 1000, EFFECTIVE_UTC)["tax"] == 0,
		"未应用的税费决议不产生税额")

	effect = Effects.apply(effect, resolutions, "tax_1", EFFECTIVE_UTC).state
	var rate: Dictionary = Effects.tax_rate(effect, resolutions, EFFECTIVE_UTC)
	_expect(rate.ok and rate.rate_permille == Effects.TAX_STEP_PERMILLE,
		"已应用的税费决议产生固定比例")
	_expect(Effects.tax_rate(effect, resolutions, EFFECTIVE_UTC - 1.0).rate_permille == 0,
		"生效时刻之前的收入不扣税")

	var quote: Dictionary = Effects.tax_for(effect, resolutions, 1000, EFFECTIVE_UTC)
	_expect(quote.ok and quote.amount == 1000 and quote.tax == 10 and quote.net == 990,
		"1000 收入按 10/1000 比例扣 10，净额 990")
	var exact: Dictionary = Effects.tax_for(effect, resolutions, 10, EFFECTIVE_UTC)
	_expect(exact.tax == 0 and exact.net == 10, "小额收入向下取整为零税")
	var odd: Dictionary = Effects.tax_for(effect, resolutions, 105, EFFECTIVE_UTC)
	_expect(odd.tax == 1 and odd.net == 104, "小额尾数向下取整")
	_expect(Effects.tax_for(effect, resolutions, 0, EFFECTIVE_UTC)["tax"] == 0,
		"零收入没有税")
	for bad_amount: Variant in [-1, 1.5, INF, NAN, "100", null]:
		var refused: Dictionary = Effects.tax_for(effect, resolutions, bad_amount,
			EFFECTIVE_UTC)
		_expect(not refused.ok and refused.reason == "invalid_amount",
			"非法收入金额被拒绝")
	_expect(Effects.tax_for(effect, resolutions, Effects.MAX_AMOUNT + 1, EFFECTIVE_UTC).reason
		== "amount_limit", "超过收入上限被拒绝")
	_expect(not Effects.tax_for(effect, resolutions, 10, -1.0).ok
		and Effects.tax_for(effect, resolutions, 10, -1.0).reason == "invalid_time",
		"非法查询时刻被拒绝")
	_expect(not quote.has("balance") and not quote.has("cash"),
		"税费结果不携带也不修改任何余额")

	# 两条税费决议合计费率，但绝不按既有资产追溯扣除。
	var resolutions_two: Dictionary = _add_tax(resolutions, "tax_2", VOTE_START + HOUR)
	effect = Effects.apply(effect, resolutions_two, "tax_2", EFFECTIVE_UTC + 3.0 * HOUR).state
	var combined: Dictionary = Effects.tax_rate(effect, resolutions_two, EFFECTIVE_UTC + 3.0 * HOUR)
	_expect(combined.rate_permille == 2 * Effects.TAX_STEP_PERMILLE,
		"两条已应用税费决议合计费率")
	_expect(Effects.tax_for(effect, resolutions_two, 1000,
		EFFECTIVE_UTC + 3.0 * HOUR)["tax"] == 20,
		"合计费率只作用于给定的未来收入")

	# 公共建设决议不改变税费费率。
	var mixed: Dictionary = _add_public_works(resolutions_two, "works_1",
		VOTE_START + 2.0 * HOUR)
	effect = Effects.apply(effect, mixed, "works_1", EFFECTIVE_UTC + 5.0 * HOUR).state
	_expect(Effects.tax_rate(effect, mixed, EFFECTIVE_UTC + 5.0 * HOUR).rate_permille
		== 2 * Effects.TAX_STEP_PERMILLE, "公共建设决议不计入税费费率")


func _test_public_works_coefficients() -> void:
	var effect: Dictionary = Effects.empty()
	var resolutions: Dictionary = _public_works_state()
	_expect(Effects.coefficient_for(effect, resolutions,
		Effects.EFFECT_PUBLIC_WORKS_EXPENSE, EFFECTIVE_UTC).permille == 0,
		"未应用的公共建设决议没有系数")
	effect = Effects.apply(effect, resolutions, "works_1", EFFECTIVE_UTC).state
	for kind: String in Effects.EFFECT_KINDS:
		var result: Dictionary = Effects.coefficient_for(effect, resolutions, kind,
			EFFECTIVE_UTC)
		_expect(result.ok and int(result.permille) == int(Effects.COEFFICIENTS[kind]),
			"公共建设决议给出固定系数 " + kind)
	_expect(Effects.coefficient_for(effect, resolutions,
		Effects.EFFECT_PUBLIC_WORKS_EXPENSE, EFFECTIVE_UTC - 1.0).permille == 0,
		"生效前的支出不享受折减")
	_expect(Effects.coefficient_for(effect, resolutions, "bridge", EFFECTIVE_UTC).reason
		== "unknown_kind", "未知效果类型被拒绝")
	_expect(Effects.coefficient_for(effect, resolutions, null, EFFECTIVE_UTC).reason
		== "unknown_kind", "非字符串效果类型被拒绝")
	_expect(Effects.coefficient_for(effect, resolutions,
		Effects.EFFECT_DISASTER_LOSS, -1.0).reason == "invalid_time",
		"非法系数查询时刻被拒绝")
	_expect(Effects.coefficient_for(effect, resolutions,
		Effects.EFFECT_DISASTER_LOSS, EFFECTIVE_UTC)["permille"]
		<= Effects.MAX_COEFFICIENT_PERMILLE, "系数不超过声明上界")
	_expect(not Effects.coefficient_for(effect, resolutions,
		Effects.EFFECT_DISASTER_LOSS, EFFECTIVE_UTC).has("state"),
		"系数查询不返回候选文档")

	# 第二条公共建设决议不叠加系数。
	var two: Dictionary = _add_public_works(resolutions, "works_2", VOTE_START + HOUR)
	effect = Effects.apply(effect, two, "works_2", EFFECTIVE_UTC + 3.0 * HOUR).state
	_expect(Effects.coefficient_for(effect, two, Effects.EFFECT_DISASTER_LOSS,
		EFFECTIVE_UTC + 3.0 * HOUR).permille
		== int(Effects.COEFFICIENTS[Effects.EFFECT_DISASTER_LOSS]),
		"多条公共建设决议不叠加折减")

	var revoked: Dictionary = Resolution.revoke(two, "works_1", PLAYER_B,
		EFFECTIVE_UTC + 4.0 * HOUR).state
	_expect(Effects.coefficient_for(effect, revoked, Effects.EFFECT_DISASTER_LOSS,
		EFFECTIVE_UTC + 4.0 * HOUR).permille
		== int(Effects.COEFFICIENTS[Effects.EFFECT_DISASTER_LOSS]),
		"撤销其中一条后另一条仍然生效")
	var both_revoked: Dictionary = Resolution.revoke(revoked, "works_2", PLAYER_C,
		EFFECTIVE_UTC + 5.0 * HOUR).state
	_expect(Effects.coefficient_for(effect, both_revoked, Effects.EFFECT_DISASTER_LOSS,
		EFFECTIVE_UTC + 5.0 * HOUR).permille == 0,
		"所有公共建设决议撤销后系数归零")


func _test_document_bounds_and_validation() -> void:
	var effect: Dictionary = Effects.empty()
	var resolutions: Dictionary = _tax_state()
	effect = Effects.apply(effect, resolutions, "tax_1", EFFECTIVE_UTC).state
	# 税费费率上限：每条 10/1000，合计二十条达到上限。
	for index: int in range(2, 21):
		resolutions = _add_tax(resolutions, "tax_%02d" % index, VOTE_START + index * HOUR)
		effect = Effects.apply(effect, resolutions, "tax_%02d" % index,
			EFFECTIVE_UTC + index * HOUR).state
	_expect(int(effect.applied_version) == 20 and effect.applied.size() == 20,
		"连续应用二十条税费决议")
	_expect(Effects.tax_rate(effect, resolutions, EFFECTIVE_UTC + 20.0 * HOUR).rate_permille
		== Effects.MAX_TAX_PERMILLE, "合计费率恰好到达上限")
	var overflow: Dictionary = _add_tax(resolutions, "tax_21", VOTE_START + 21.0 * HOUR)
	effect = Effects.apply(effect, overflow, "tax_21", EFFECTIVE_UTC + 21.0 * HOUR).state
	var over: Dictionary = Effects.tax_rate(effect, overflow, EFFECTIVE_UTC + 21.0 * HOUR)
	_expect(not over.ok and over.reason == "over_rate",
		"超过费率上限被拒绝而不是静默截断")
	_expect(int(over.rate_permille) == Effects.MAX_TAX_PERMILLE + Effects.TAX_STEP_PERMILLE,
		"超限结果报告实际费率")
	var over_tax: Dictionary = Effects.tax_for(effect, overflow, 1000,
		EFFECTIVE_UTC + 21.0 * HOUR)
	_expect(not over_tax.ok and over_tax.reason == "over_rate",
		"超过费率上限时未来收入也不扣取")

	# 应用记录上限与按时间淘汰。
	var full: Dictionary = Effects.empty()
	var many: Dictionary = _tax_state()
	for index: int in range(2, Effects.MAX_APPLIED + 2):
		many = _add_tax(many, "tax_%03d" % index, VOTE_START + index * HOUR)
		full = Effects.apply(full, many, "tax_%03d" % index,
			EFFECTIVE_UTC + index * HOUR).state
	_expect(full.applied.size() == Effects.MAX_APPLIED, "应用记录保持在上限内")
	_expect(Effects.valid(full), "达到记录上限的文档合法")
	_expect(int(full.applied[0].version) == 2,
		"超限时淘汰最旧一条记录")
	_expect(int(full.applied[full.applied.size() - 1].version) == Effects.MAX_APPLIED + 1,
		"最新一条记录保留")
	_expect(int(full.applied_version) == Effects.MAX_APPLIED + 1,
		"水位继续前进")

	# 已知文档形状的拒绝分支。
	var applied: Dictionary = Effects.apply(Effects.empty(), _tax_state(), "tax_1",
		EFFECTIVE_UTC).state
	_expect(_rejects(applied, func(doc: Dictionary) -> void:
		doc["applied"][0]["extra"] = true), "未知记录键被拒绝")
	_expect(_rejects(applied, func(doc: Dictionary) -> void:
		doc["applied"][0].erase("kind")), "缺少记录键被拒绝")
	_expect(_rejects(applied, func(doc: Dictionary) -> void:
		doc["applied"][0]["resolution_id"] = "bad id"), "非法记录 id 被拒绝")
	_expect(_rejects(applied, func(doc: Dictionary) -> void:
		doc["applied"][0]["kind"] = "bridge"), "未知记录类型被拒绝")
	_expect(_rejects(applied, func(doc: Dictionary) -> void:
		doc["applied"][0]["version"] = 0), "记录版本必须为正")
	_expect(_rejects(applied, func(doc: Dictionary) -> void:
		doc["applied"][0]["version"] = 2), "记录版本不能超过水位")
	_expect(_rejects(applied, func(doc: Dictionary) -> void:
		doc["applied"][0]["at_utc"] = -1.0), "负记录时刻被拒绝")
	_expect(_rejects(applied, func(doc: Dictionary) -> void:
		doc["applied_version"] = 0), "记录版本高于水位被拒绝")
	var doubled: Dictionary = applied.duplicate(true)
	var second: Dictionary = full.applied[full.applied.size() - 1].duplicate(true)
	doubled["applied"].append(second)
	doubled["applied"][0]["version"] = 1
	doubled["applied"].append(doubled["applied"][0].duplicate(true))
	_expect(not Effects.valid(doubled), "重复记录版本被拒绝")

	var too_many: Dictionary = Effects.empty()
	too_many["applied_version"] = Effects.MAX_APPLIED
	for index: int in range(1, Effects.MAX_APPLIED + 1):
		too_many["applied"].append({
			"resolution_id": "tax_%03d" % index,
			"version": index,
			"kind": Resolution.KIND_TAX,
			"at_utc": EFFECTIVE_UTC + index,
		})
	_expect(Effects.valid(too_many), "恰好上限数量的记录合法")
	too_many["applied_version"] = Effects.MAX_APPLIED + 1
	too_many["applied"].append({
		"resolution_id": "tax_999",
		"version": Effects.MAX_APPLIED + 1,
		"kind": Resolution.KIND_TAX,
		"at_utc": EFFECTIVE_UTC,
	})
	_expect(not Effects.valid(too_many), "超过记录上限被拒绝")

	# 效果文档与决议文档的一致性。
	var inconsistent: Dictionary = applied.duplicate(true)
	inconsistent["applied"][0]["kind"] = Resolution.KIND_PUBLIC_WORKS
	_expect(Effects.tax_rate(inconsistent, _tax_state(), EFFECTIVE_UTC).reason
		== "invalid_state", "记录类型与决议不一致被拒绝")
	var wrong_version: Dictionary = applied.duplicate(true)
	wrong_version["applied_version"] = 2
	_expect(Effects.tax_rate(wrong_version, _tax_state(), EFFECTIVE_UTC).reason
		== "invalid_state", "水位超过决议规则版本被拒绝")
	_expect(Effects.apply(inconsistent, _tax_state(), "tax_1", EFFECTIVE_UTC).reason
		== "invalid_state", "不一致的效果文档在应用入口也被拒绝")


func _test_input_immutability_and_determinism() -> void:
	var resolutions: Dictionary = _tax_state()
	var effect: Dictionary = Effects.empty()
	var effect_before: Dictionary = effect.duplicate(true)
	var resolutions_before: Dictionary = resolutions.duplicate(true)
	var applied: Dictionary = Effects.apply(effect, resolutions, "tax_1", EFFECTIVE_UTC)
	_expect_immutable_effect(effect, effect_before)
	_expect_immutable_resolutions(resolutions, resolutions_before)
	var candidate: Dictionary = applied.state
	var candidate_before: Dictionary = candidate.duplicate(true)
	Effects.tax_rate(candidate, resolutions, EFFECTIVE_UTC)
	Effects.tax_for(candidate, resolutions, 1000, EFFECTIVE_UTC)
	Effects.coefficient_for(candidate, resolutions,
		Effects.EFFECT_DISASTER_LOSS, EFFECTIVE_UTC)
	Effects.apply(candidate, resolutions, "tax_1", EFFECTIVE_UTC + HOUR)
	Effects.valid(candidate)
	_expect(candidate == candidate_before, "查询与被拒绝的命令都不修改文档")

	var first: Dictionary = _sequence()
	var second: Dictionary = _sequence()
	_expect(first == second and JSON.stringify(first) == JSON.stringify(second),
		"同一序列产生同一文档与同一 JSON")
	_expect(int(first.applied_version) == 2 and first.applied.size() == 2,
		"确定性序列以税费和公共建设各应用一次结束")
	_expect(Effects.tax_rate(first, _sequence_resolutions(), EFFECTIVE_UTC + 4.0 * HOUR)
		.rate_permille == Effects.TAX_STEP_PERMILLE,
		"确定性序列的费率可复现")


func _sequence() -> Dictionary:
	var resolutions: Dictionary = _sequence_resolutions()
	var effect: Dictionary = Effects.empty()
	effect = Effects.apply(effect, resolutions, "tax_1", EFFECTIVE_UTC).state
	effect = Effects.apply(effect, resolutions, "works_1", EFFECTIVE_UTC + 3.0 * HOUR).state
	return effect


func _proposal(kind: String, vote_start: float) -> Dictionary:
	return {
		"kind": kind,
		"title": "规则",
		"vote_start_utc": vote_start,
		"vote_end_utc": vote_start + HOUR,
		"effective_utc": vote_start + 2.0 * HOUR,
	}


func _proposal_from(vote_start: float) -> Dictionary:
	return _proposal(Resolution.KIND_TAX, vote_start)


func _proposed_state() -> Dictionary:
	return Resolution.propose(Resolution.empty(), "tax_1", PLAYER_A,
		_proposal(Resolution.KIND_TAX, VOTE_START), START).state


func _passed_state(resolution_id: String) -> Dictionary:
	var state: Dictionary = Resolution.propose(Resolution.empty(), resolution_id, PLAYER_A,
		_proposal(Resolution.KIND_TAX, VOTE_START), START).state
	state = Resolution.vote(state, resolution_id, PLAYER_B, true, VOTE_START + 10.0).state
	state = Resolution.vote(state, resolution_id, PLAYER_C, true, VOTE_START + 20.0).state
	return Resolution.close(state, resolution_id, VOTE_END).state


func _tax_state() -> Dictionary:
	return Resolution.activate(_passed_state("tax_1"), "tax_1", EFFECTIVE_UTC).state


func _public_works_state() -> Dictionary:
	var state: Dictionary = Resolution.propose(Resolution.empty(), "works_1", PLAYER_A,
		_proposal(Resolution.KIND_PUBLIC_WORKS, VOTE_START), START).state
	state = Resolution.vote(state, "works_1", PLAYER_B, true, VOTE_START + 10.0).state
	state = Resolution.vote(state, "works_1", PLAYER_C, true, VOTE_START + 20.0).state
	state = Resolution.close(state, "works_1", VOTE_END).state
	return Resolution.activate(state, "works_1", EFFECTIVE_UTC).state


func _add_tax(resolutions: Dictionary, resolution_id: String, vote_start: float) -> Dictionary:
	var state: Dictionary = Resolution.propose(resolutions, resolution_id, PLAYER_A,
		_proposal(Resolution.KIND_TAX, vote_start), vote_start - 60.0).state
	state = Resolution.vote(state, resolution_id, PLAYER_B, true, vote_start + 10.0).state
	state = Resolution.vote(state, resolution_id, PLAYER_C, true, vote_start + 20.0).state
	state = Resolution.close(state, resolution_id, vote_start + HOUR).state
	return Resolution.activate(state, resolution_id, vote_start + 2.0 * HOUR).state


func _add_public_works(resolutions: Dictionary, resolution_id: String,
		vote_start: float) -> Dictionary:
	var state: Dictionary = Resolution.propose(resolutions, resolution_id, PLAYER_A,
		_proposal(Resolution.KIND_PUBLIC_WORKS, vote_start), vote_start - 60.0).state
	state = Resolution.vote(state, resolution_id, PLAYER_B, true, vote_start + 10.0).state
	state = Resolution.vote(state, resolution_id, PLAYER_C, true, vote_start + 20.0).state
	state = Resolution.close(state, resolution_id, vote_start + HOUR).state
	return Resolution.activate(state, resolution_id, vote_start + 2.0 * HOUR).state


func _sequence_resolutions() -> Dictionary:
	var state: Dictionary = _tax_state()
	return _add_public_works(state, "works_1", VOTE_START + HOUR)


func _rejects(state: Dictionary, mutate: Callable) -> bool:
	var copy: Dictionary = state.duplicate(true)
	mutate.call(copy)
	return not Effects.valid(copy)


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)


func _expect_immutable_effect(state: Dictionary, before: Dictionary) -> void:
	_expect(state == before, "应用命令不修改调用方效果文档")


func _expect_immutable_resolutions(state: Dictionary, before: Dictionary) -> void:
	_expect(state == before, "应用命令不修改调用方决议文档")
