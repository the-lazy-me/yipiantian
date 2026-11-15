extends SceneTree
## M11-03 规则决议纯规则切片的无头测试：不读场景、存档、网络或系统时钟。
## 同一命令序列必须得到同一文档；最后一行是验证证据。

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
const PLAYER_F: String = "player_00000000000000000000000000000006"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_empty_and_shape()
	_test_propose()
	_test_vote_window_and_duplicates()
	_test_tally_and_close()
	_test_withdraw()
	_test_revoke()
	_test_versions_are_not_retroactive()
	_test_document_validity()
	_test_bounds_and_determinism()
	for failure: String in failures:
		push_error(failure)
	print("RESOLUTION_STATE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_empty_and_shape() -> void:
	var empty: Dictionary = Resolution.empty()
	_expect(Resolution.valid(empty), "空文档合法")
	_expect(int(empty.rules_version) == 0 and empty.resolutions.is_empty(),
		"空文档没有规则版本，也没有决议")
	_expect(not Resolution.valid(null) and not Resolution.valid([]) and not Resolution.valid({}),
		"非字典或结构为空的文档被拒绝")
	_expect(Resolution.valid(JSON.parse_string(JSON.stringify(empty))),
		"空文档经过 JSON 往返仍然合法")
	_expect(_rejects(empty, func(doc: Dictionary) -> void: doc["extra"] = true),
		"未知顶层键被拒绝")
	_expect(_rejects(empty, func(doc: Dictionary) -> void: doc.erase("rules_version")),
		"缺少 rules_version 被拒绝")
	_expect(_rejects(empty, func(doc: Dictionary) -> void: doc.erase("resolutions")),
		"缺少 resolutions 被拒绝")
	_expect(_rejects(empty, func(doc: Dictionary) -> void: doc["resolutions"] = []),
		"resolutions 不是字典被拒绝")
	for bad_version: Variant in [-1, 1.5, INF, NAN, "1", true]:
		_expect(_rejects(empty, func(doc: Dictionary) -> void:
			doc["rules_version"] = bad_version),
			"非法的 rules_version 被拒绝")
	_expect(Resolution.valid(_proposed_state()), "提案后的文档合法")
	_expect(Resolution.valid(JSON.parse_string(JSON.stringify(_proposed_state()))),
		"提案后的文档经过 JSON 往返仍然合法")


func _test_propose() -> void:
	var state: Dictionary = Resolution.empty()
	var before: Dictionary = state.duplicate(true)
	var result: Dictionary = Resolution.propose(state, "res_1", PLAYER_A, _proposal(), START)
	_expect(result.ok and str(result.reason).is_empty(), "合法提案被接受")
	_expect(state == before, "提案命令不修改调用方文档")
	var doc: Dictionary = result.state
	_expect(Resolution.valid(doc), "提案后的文档严格合法")
	var row: Dictionary = doc.resolutions["res_1"]
	_expect(row.status == Resolution.STATUS_PROPOSED and int(row.revision) == 1,
		"新提案状态为 proposed，revision 为 1")
	_expect(row.proposed_by == PLAYER_A and float(row.proposed_utc) == START,
		"提案记录提案人和提案时刻")
	_expect(float(row.vote_start_utc) == VOTE_START and float(row.vote_end_utc) == VOTE_END
		and float(row.effective_utc) == EFFECTIVE_UTC,
		"提案记录投票窗口和生效时刻")
	_expect(row.approvals.is_empty() and row.rejections.is_empty(),
		"新提案没有赞成或反对票")
	_expect(int(row.effective_version) == 0 and int(row.revoked_version) == 0
		and row.revoked_by == "" and float(row.revoked_utc) == 0.0,
		"新提案没有生效或撤销版本")
	_expect(int(doc.rules_version) == 0, "提案本身不推进规则版本")

	var accepted: Dictionary = doc.duplicate(true)
	var duplicate: Dictionary = Resolution.propose(doc, "res_1", PLAYER_B, _proposal(), START)
	_expect(not duplicate.ok and duplicate.reason == "already_exists",
		"重复的决议 id 被拒绝")
	_expect(doc == accepted, "重复 id 被拒绝后文档不变")

	for bad_id: Variant in ["", "bad id", "bad/id", 42, null]:
		var refused: Dictionary = Resolution.propose(doc, bad_id, PLAYER_A, _proposal(), START)
		_expect(not refused.ok and refused.reason == "invalid_resolution",
			"非法决议 id 被拒绝")
	for bad_player: Variant in ["", "bad player", "@world", 42, null]:
		var refused: Dictionary = Resolution.propose(doc, "res_2", bad_player, _proposal(), START)
		_expect(not refused.ok and refused.reason == "invalid_player",
			"非法提案人被拒绝")
	for bad_time: float in [-1.0, INF, NAN]:
		var refused: Dictionary = Resolution.propose(doc, "res_2", PLAYER_A, _proposal(),
			bad_time)
		_expect(not refused.ok and refused.reason == "invalid_time",
			"非法提案时刻被拒绝")
	_expect(Resolution.propose(doc, "res_2", PLAYER_A, "not a proposal", START).reason
		== "invalid_proposal", "非字典提案被拒绝")
	_expect(Resolution.propose(doc, "res_2", PLAYER_A, {}, START).reason
		== "invalid_proposal", "空提案字典被拒绝")
	_expect(Resolution.propose(doc, "res_2", PLAYER_A,
		_proposal_with("extra", true), START).reason == "invalid_proposal",
		"带未知键的提案被拒绝")
	var missing: Dictionary = _proposal()
	missing.erase("title")
	_expect(Resolution.propose(doc, "res_2", PLAYER_A, missing, START).reason
		== "invalid_proposal", "缺少字段的提案被拒绝")
	_expect(Resolution.propose(doc, "res_2", PLAYER_A,
		_proposal_with("kind", "bridge"), START).reason == "invalid_kind",
		"未知决议类型被拒绝")
	_expect(Resolution.propose(doc, "res_2", PLAYER_A,
		_proposal_with("title", ""), START).reason == "invalid_title",
		"空标题被拒绝")
	_expect(Resolution.propose(doc, "res_2", PLAYER_A,
		_proposal_with("title", " padded "), START).reason == "invalid_title",
		"带首尾空白的标题被拒绝")
	_expect(Resolution.propose(doc, "res_2", PLAYER_A,
		_proposal_with("title", "bad\nname"), START).reason == "invalid_title",
		"带控制字符的标题被拒绝")
	_expect(Resolution.propose(doc, "res_2", PLAYER_A,
		_proposal_with("vote_start_utc", START - 1.0), START).reason
		== "invalid_window", "投票窗口不能早于提案时刻")
	_expect(Resolution.propose(doc, "res_2", PLAYER_A,
		_proposal_with("vote_end_utc", VOTE_START), START).reason == "invalid_window",
		"投票结束必须晚于开始")
	_expect(Resolution.propose(doc, "res_2", PLAYER_A,
		_proposal_with("effective_utc", VOTE_END + Resolution.NOTICE_SECONDS - 1.0),
		START).reason == "notice_too_short", "预告期不足被拒绝")
	_expect(Resolution.propose(doc, "res_2", PLAYER_A,
		_proposal_with("vote_end_utc", INF), START).reason == "invalid_time",
		"非有限投票时刻被拒绝")


func _test_vote_window_and_duplicates() -> void:
	var state: Dictionary = _proposed_state()
	var before: Dictionary = state.duplicate(true)
	_expect(Resolution.vote(state, "res_1", PLAYER_B, true, VOTE_START - 1.0).reason
		== "not_started", "投票开始前不能投票")
	_expect(state == before, "窗口外拒绝不修改文档")
	var voted: Dictionary = Resolution.vote(state, "res_1", PLAYER_B, true, VOTE_START)
	_expect(voted.ok, "投票开始时刻可以投票")
	state = voted.state
	_expect(Resolution.valid(state), "投票后的文档合法")
	_expect(state.resolutions["res_1"].approvals == [PLAYER_B], "赞成票被记录")
	_expect(state.resolutions["res_1"].revision == 1, "投票不改变提案 revision")

	_expect(Resolution.vote(state, "res_1", PLAYER_B, true, VOTE_START + 10.0).reason
		== "already_voted", "同一玩家不能重复投赞成票")
	_expect(Resolution.vote(state, "res_1", PLAYER_B, false, VOTE_START + 11.0).reason
		== "already_voted", "同一玩家不能改投反对票")
	var rejected: Dictionary = Resolution.vote(state, "res_1", PLAYER_C, false,
		VOTE_START + 20.0)
	_expect(rejected.ok and state.resolutions["res_1"].rejections.is_empty(),
		"另一玩家可以投反对票，且原文档不被修改")
	state = rejected.state
	_expect(state.resolutions["res_1"].rejections == [PLAYER_C], "反对票被记录")
	_expect(Resolution.vote(state, "res_1", PLAYER_A, true, VOTE_START + 30.0).reason
		== "self_vote", "提案人不能给自己的提案投票")
	_expect(Resolution.vote(state, "res_1", PLAYER_D, true, VOTE_END).reason
		== "closed", "投票结束时刻窗口已关闭")
	_expect(Resolution.vote(state, "res_1", PLAYER_D, true, VOTE_END + 1.0).reason
		== "closed", "投票窗口结束后不能投票")
	_expect(Resolution.vote(state, "missing", PLAYER_D, true, VOTE_START).reason
		== "unknown_resolution", "未知决议不能投票")
	_expect(Resolution.vote(state, "bad id", PLAYER_D, true, VOTE_START).reason
		== "invalid_resolution", "非法决议 id 不能投票")
	_expect(Resolution.vote(state, "res_1", "bad player", true, VOTE_START).reason
		== "invalid_player", "非法投票人被拒绝")
	_expect(Resolution.vote(state, "res_1", PLAYER_D, true, -1.0).reason
		== "invalid_time", "非法投票时刻被拒绝")

	var passed: Dictionary = Resolution.close(state, "res_1", VOTE_END).state
	_expect(Resolution.vote(passed, "res_1", PLAYER_D, true, VOTE_END + 5.0).reason
		== "not_proposed", "已关闭的提案不能继续投票")
	var withdrawn: Dictionary = Resolution.withdraw(state, "res_1", PLAYER_A,
		VOTE_START + 40.0).state
	_expect(Resolution.vote(withdrawn, "res_1", PLAYER_D, true, VOTE_START + 50.0).reason
		== "not_proposed", "已撤案的提案不能继续投票")


func _test_tally_and_close() -> void:
	var state: Dictionary = _proposed_state()
	state = Resolution.vote(state, "res_1", PLAYER_B, true, VOTE_START + 10.0).state
	state = Resolution.vote(state, "res_1", PLAYER_C, true, VOTE_START + 20.0).state
	state = Resolution.vote(state, "res_1", PLAYER_D, false, VOTE_START + 30.0).state
	var tally: Dictionary = Resolution.tally(state, "res_1")
	_expect(tally.ok and tally.approvals == 2 and tally.rejections == 1,
		"计票返回准确的赞成和反对人数")
	_expect(tally.passed, "两票赞成、一票反对达到阈值")
	_expect(Resolution.tally(state, "res_1") == tally, "计票是确定性的")
	_expect(Resolution.tally(state, "missing").reason == "unknown_resolution",
		"未知决议计票具名失败")
	_expect(Resolution.tally(state, "bad id").reason == "invalid_resolution",
		"非法决议 id 计票失败")
	_expect(not Resolution.tally(state, "res_1").has("state"),
		"计票不返回候选文档")

	_expect(Resolution.close(state, "res_1", VOTE_END - 1.0).reason == "window_open",
		"投票窗口未结束不能关闭")
	var accepted: Dictionary = state.duplicate(true)
	var closed: Dictionary = Resolution.close(state, "res_1", VOTE_END)
	_expect(closed.ok, "窗口结束时刻可以关闭")
	_expect(state == accepted, "关闭命令不修改输入文档")
	state = closed.state
	_expect(state.resolutions["res_1"].status == Resolution.STATUS_PASSED
		and int(state.resolutions["res_1"].revision) == 2,
		"达到阈值的提案变为 passed，revision 为 2")
	_expect(int(state.rules_version) == 0, "关闭提案本身不让规则生效")
	_expect(Resolution.valid(state), "关闭后的文档合法")
	_expect(not Resolution.is_effective_at(state, "res_1", EFFECTIVE_UTC + HOUR),
		"passed 但未 activate 的规则不算生效")
	_expect(Resolution.close(state, "res_1", VOTE_END + 1.0).reason == "not_proposed",
		"已关闭的提案不能再次关闭")
	_expect(Resolution.activate(state, "res_1", EFFECTIVE_UTC - 1.0).reason == "too_early",
		"预告期未满不能生效")
	var activated: Dictionary = Resolution.activate(state, "res_1", EFFECTIVE_UTC)
	_expect(activated.ok, "预告期结束时刻可以生效")
	state = activated.state
	_expect(state.resolutions["res_1"].status == Resolution.STATUS_EFFECTIVE
		and int(state.resolutions["res_1"].revision) == 3,
		"生效后状态为 effective，revision 为 3")
	_expect(int(state.resolutions["res_1"].effective_version) == 1
		and int(state.rules_version) == 1, "第一次生效分配规则版本 1")
	_expect(Resolution.valid(state), "生效后的文档合法")
	_expect(not Resolution.is_effective_at(state, "res_1", EFFECTIVE_UTC - 1.0),
		"生效时刻之前规则无效")
	_expect(Resolution.is_effective_at(state, "res_1", EFFECTIVE_UTC),
		"生效时刻起规则有效")
	_expect(Resolution.is_effective_at(state, "res_1", EFFECTIVE_UTC + 10.0 * HOUR),
		"生效后规则持续有效")
	_expect(Resolution.activate(state, "res_1", EFFECTIVE_UTC + 1.0).reason == "not_passed",
		"已生效的提案不能重复生效")

	# 只有一票赞成、两票反对：rejected。
	var rejected: Dictionary = _proposed_state()
	rejected = Resolution.vote(rejected, "res_1", PLAYER_B, true, VOTE_START + 10.0).state
	rejected = Resolution.vote(rejected, "res_1", PLAYER_C, false, VOTE_START + 20.0).state
	rejected = Resolution.vote(rejected, "res_1", PLAYER_D, false, VOTE_START + 30.0).state
	rejected = Resolution.close(rejected, "res_1", VOTE_END).state
	_expect(rejected.resolutions["res_1"].status == Resolution.STATUS_REJECTED,
		"票数不足的提案变为 rejected")
	_expect(Resolution.activate(rejected, "res_1", EFFECTIVE_UTC + HOUR).reason
		== "not_passed", "被否决的提案不能生效")
	_expect(not Resolution.is_effective_at(rejected, "res_1", EFFECTIVE_UTC + 10.0 * HOUR),
		"被否决的提案永远不生效")

	# 两票赞成、两票反对：赞成没有严格多于反对，rejected。
	var tied: Dictionary = _proposed_state()
	tied = Resolution.vote(tied, "res_1", PLAYER_B, true, VOTE_START + 10.0).state
	tied = Resolution.vote(tied, "res_1", PLAYER_C, true, VOTE_START + 20.0).state
	tied = Resolution.vote(tied, "res_1", PLAYER_D, false, VOTE_START + 30.0).state
	tied = Resolution.vote(tied, "res_1", PLAYER_E, false, VOTE_START + 40.0).state
	tied = Resolution.close(tied, "res_1", VOTE_END).state
	_expect(tied.resolutions["res_1"].status == Resolution.STATUS_REJECTED,
		"赞成票必须严格多于反对票")

	# 一票赞成、零票反对：未达到最少赞成数，rejected。
	var lonely: Dictionary = _proposed_state()
	lonely = Resolution.vote(lonely, "res_1", PLAYER_B, true, VOTE_START + 10.0).state
	lonely = Resolution.close(lonely, "res_1", VOTE_END).state
	_expect(lonely.resolutions["res_1"].status == Resolution.STATUS_REJECTED,
		"少于最少赞成数的提案被否决")

	# 过了投票窗口很久才关闭也不会自动生效。
	var late: Dictionary = _proposed_state()
	late = Resolution.vote(late, "res_1", PLAYER_B, true, VOTE_START + 10.0).state
	late = Resolution.vote(late, "res_1", PLAYER_C, true, VOTE_START + 20.0).state
	late = Resolution.close(late, "res_1", EFFECTIVE_UTC + 10.0 * HOUR).state
	_expect(late.resolutions["res_1"].status == Resolution.STATUS_PASSED
		and int(late.rules_version) == 0,
		"过期窗口只产生 passed，不产生生效规则")
	_expect(not Resolution.is_effective_at(late, "res_1", EFFECTIVE_UTC + 20.0 * HOUR),
		"未经 activate 的过期提案仍然无效")
	late = Resolution.activate(late, "res_1", EFFECTIVE_UTC + 20.0 * HOUR).state
	_expect(late.resolutions["res_1"].status == Resolution.STATUS_EFFECTIVE
		and int(late.rules_version) == 1, "显式 activate 后过期提案才生效")


func _test_withdraw() -> void:
	var state: Dictionary = _proposed_state()
	state = Resolution.vote(state, "res_1", PLAYER_B, true, VOTE_START + 10.0).state
	_expect(Resolution.withdraw(state, "res_1", PLAYER_B, VOTE_START + 20.0).reason
		== "not_proposer", "非提案人不能撤案")
	var accepted: Dictionary = state.duplicate(true)
	var withdrawn: Dictionary = Resolution.withdraw(state, "res_1", PLAYER_A,
		VOTE_START + 20.0)
	_expect(withdrawn.ok, "提案人可以在窗口内撤案")
	_expect(state == accepted, "撤案命令不修改输入文档")
	state = withdrawn.state
	_expect(state.resolutions["res_1"].status == Resolution.STATUS_WITHDRAWN
		and int(state.resolutions["res_1"].revision) == 2,
		"撤案后状态为 withdrawn，revision 为 2")
	_expect(state.resolutions["res_1"].approvals == [PLAYER_B],
		"撤案保留已经投出的票作为历史")
	_expect(int(state.rules_version) == 0, "撤案不推进规则版本")
	_expect(Resolution.valid(state), "撤案后的文档合法")
	_expect(Resolution.withdraw(state, "res_1", PLAYER_A, VOTE_START + 30.0).reason
		== "not_proposed", "已撤案的提案不能再撤案")

	var at_end: Dictionary = _proposed_state()
	_expect(Resolution.withdraw(at_end, "res_1", PLAYER_A, VOTE_END).reason
		== "window_closed", "投票窗口结束后不能撤案")
	var closed: Dictionary = Resolution.close(at_end, "res_1", VOTE_END).state
	_expect(Resolution.withdraw(closed, "res_1", PLAYER_A, VOTE_END + 1.0).reason
		== "not_proposed", "已关闭的提案不能撤案")
	var effective: Dictionary = Resolution.activate(
		Resolution.close(Resolution.vote(Resolution.vote(_proposed_state(), "res_1",
		PLAYER_B, true, VOTE_START + 10.0).state, "res_1", PLAYER_C, true,
		VOTE_START + 20.0).state, "res_1", VOTE_END).state, "res_1", EFFECTIVE_UTC).state
	_expect(Resolution.withdraw(effective, "res_1", PLAYER_A, EFFECTIVE_UTC + 1.0).reason
		== "not_proposed", "已生效的提案不能撤案")
	_expect(Resolution.withdraw(_proposed_state(), "missing", PLAYER_A,
		VOTE_START).reason == "unknown_resolution", "未知决议不能撤案")
	_expect(Resolution.withdraw(_proposed_state(), "res_1", "bad player",
		VOTE_START).reason == "invalid_player", "非法撤案人被拒绝")


func _test_revoke() -> void:
	var proposed: Dictionary = _proposed_state()
	_expect(Resolution.revoke(proposed, "res_1", PLAYER_B, VOTE_START).reason
		== "not_effective", "未生效的提案不能撤销")
	var passed: Dictionary = Resolution.close(
		Resolution.vote(Resolution.vote(proposed, "res_1", PLAYER_B, true,
		VOTE_START + 10.0).state, "res_1", PLAYER_C, true, VOTE_START + 20.0).state,
		"res_1", VOTE_END).state
	_expect(Resolution.revoke(passed, "res_1", PLAYER_B, EFFECTIVE_UTC).reason
		== "not_effective", "已通过但未生效的提案不能撤销")
	var effective: Dictionary = Resolution.activate(passed, "res_1", EFFECTIVE_UTC).state
	_expect(Resolution.revoke(effective, "res_1", PLAYER_E, EFFECTIVE_UTC + 10.0).reason
		== "not_approver", "没有投赞成票的人不能撤销")
	_expect(Resolution.revoke(effective, "res_1", PLAYER_A, EFFECTIVE_UTC + 10.0).reason
		== "not_approver", "提案人未投赞成票时不能撤销")
	var accepted: Dictionary = effective.duplicate(true)
	var snapshot: Dictionary = effective.resolutions["res_1"].duplicate(true)
	var revoked_result: Dictionary = Resolution.revoke(effective, "res_1", PLAYER_B,
		EFFECTIVE_UTC + 10.0)
	_expect(revoked_result.ok, "曾投赞成票的成员可以撤销生效规则")
	_expect(effective == accepted, "撤销命令不修改输入文档")
	var revoked: Dictionary = revoked_result.state
	var row: Dictionary = revoked.resolutions["res_1"]
	_expect(row.status == Resolution.STATUS_REVOKED and int(row.revision) == 4,
		"撤销后状态为 revoked，revision 为 4")
	_expect(row.revoked_by == PLAYER_B and float(row.revoked_utc) == EFFECTIVE_UTC + 10.0,
		"撤销记录撤销人和撤销时刻")
	_expect(int(row.revoked_version) == 2 and int(revoked.rules_version) == 2,
		"撤销分配新的规则版本")
	_expect(int(row.effective_version) == 1, "撤销保留原生效版本")
	_expect(Resolution.valid(revoked), "撤销后的文档合法")
	_expect(Resolution.is_effective_at(revoked, "res_1", EFFECTIVE_UTC),
		"撤销不追溯：生效时刻的规则仍然有效")
	_expect(Resolution.is_effective_at(revoked, "res_1", EFFECTIVE_UTC + 9.0),
		"撤销前一刻的规则仍然有效")
	_expect(not Resolution.is_effective_at(revoked, "res_1", EFFECTIVE_UTC + 10.0),
		"撤销时刻起规则不再有效")
	_expect(not Resolution.is_effective_at(revoked, "res_1", EFFECTIVE_UTC + 20.0),
		"撤销之后规则无效")
	for key: String in ["kind", "title", "proposed_by", "proposed_utc", "vote_start_utc",
			"vote_end_utc", "effective_utc", "approvals", "rejections",
			"effective_version"]:
		_expect(row[key] == snapshot[key], "撤销不改写历史字段 " + key)
	_expect(Resolution.revoke(revoked, "res_1", PLAYER_B, EFFECTIVE_UTC + 20.0).reason
		== "not_effective", "已撤销的决议不能再次撤销")
	_expect(Resolution.revoke(effective, "missing", PLAYER_B, EFFECTIVE_UTC).reason
		== "unknown_resolution", "未知决议不能撤销")
	_expect(Resolution.revoke(effective, "res_1", "bad player", EFFECTIVE_UTC).reason
		== "invalid_player", "非法撤销人被拒绝")


func _test_versions_are_not_retroactive() -> void:
	var first: Dictionary = _effective_state()
	var first_snapshot: Dictionary = first.resolutions["res_1"].duplicate(true)
	var next_start: float = EFFECTIVE_UTC + HOUR
	var next_proposal: Dictionary = _proposal_from(next_start)
	var second: Dictionary = Resolution.propose(first, "res_2", PLAYER_D,
		next_proposal, next_start).state
	second = Resolution.vote(second, "res_2", PLAYER_E, true, next_start + 60.0).state
	second = Resolution.vote(second, "res_2", PLAYER_F, true, next_start + 120.0).state
	second = Resolution.close(second, "res_2", next_start + HOUR).state
	second = Resolution.activate(second, "res_2", next_start + 2.0 * HOUR).state
	_expect(Resolution.valid(second), "第二条规则生效后的文档合法")
	_expect(int(second.resolutions["res_2"].effective_version) == 2
		and int(second.rules_version) == 2, "新规则分配版本 2")
	_expect(second.resolutions["res_1"] == first_snapshot,
		"新版本不重写旧决议行")
	_expect(Resolution.is_effective_at(second, "res_1", EFFECTIVE_UTC + 10.0),
		"旧规则在自己的生效区间内继续有效")
	_expect(Resolution.is_effective_at(second, "res_2", next_start + 2.0 * HOUR),
		"新规则从自己的生效时刻起有效")

	var second_snapshot: Dictionary = second.resolutions["res_2"].duplicate(true)
	var revoke_at: float = next_start + 3.0 * HOUR
	second = Resolution.revoke(second, "res_1", PLAYER_B, revoke_at).state
	_expect(int(second.resolutions["res_1"].revoked_version) == 3
		and int(second.rules_version) == 3, "撤销旧规则分配版本 3")
	_expect(second.resolutions["res_2"] == second_snapshot, "撤销旧规则不改写新规则行")
	_expect(Resolution.is_effective_at(second, "res_1", revoke_at - 1.0),
		"撤销旧规则不追溯撤销前的事件")
	_expect(not Resolution.is_effective_at(second, "res_1", revoke_at),
		"撤销时刻起旧规则失效")
	_expect(Resolution.is_effective_at(second, "res_2", next_start + 2.0 * HOUR),
		"撤销旧规则不影响新规则的生效区间")
	_expect(Resolution.valid(second), "多版本与撤销混合后文档仍然合法")


func _test_document_validity() -> void:
	var state: Dictionary = _revoked_state()
	_expect(Resolution.valid(JSON.parse_string(JSON.stringify(state))),
		"生效并撤销后的文档经过 JSON 往返仍然合法")

	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["extra"] = true), "未知决议行键被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"].erase("status")), "缺少决议行键被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["kind"] = "bridge"), "未知 kind 被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["title"] = ""), "空标题记录被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["proposed_by"] = "bad player"),
		"非法提案人记录被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["proposed_utc"] = -1.0), "负提案时刻被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["proposed_utc"] = VOTE_START + 1.0),
		"投票窗口早于提案时刻被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["vote_end_utc"] = float(
			doc["resolutions"]["res_1"]["vote_start_utc"])),
		"投票结束不晚于开始被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["effective_utc"] = VOTE_END + 1.0),
		"预告期不足的记录被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["status"] = "draft"), "未知状态被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["status"] = 1), "非字符串状态被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["approvals"] = {}), "非数组赞成票被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["rejections"] = "none"), "非数组反对票被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["approvals"] = [PLAYER_B, PLAYER_B]),
		"重复赞成票被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["approvals"] = [PLAYER_A]),
		"提案人出现在赞成票中被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["approvals"] = [PLAYER_B, "bad player"]),
		"非法投票人记录被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["rejections"] = [PLAYER_B]),
		"同一人同时赞成和反对被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["revision"] = 1), "撤销行 revision 不匹配被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["revision"] = 3), "撤销行旧 revision 被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["effective_version"] = 0),
		"撤销行缺少生效版本被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["revoked_by"] = ""), "撤销行缺少撤销人被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["revoked_by"] = PLAYER_E),
		"撤销人不是赞成者被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["revoked_utc"] = EFFECTIVE_UTC - 1.0),
		"撤销时刻早于生效时刻被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["revoked_version"] = 1),
		"撤销版本不晚于生效版本被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["rules_version"] = 1), "rules_version 与生命周期不匹配被拒绝")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["rules_version"] = 0), "零版本却存在撤销行被拒绝")

	var effective: Dictionary = _effective_state()
	_expect(_rejects(effective, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["revoked_by"] = PLAYER_B),
		"生效行不能携带撤销人")
	_expect(_rejects(effective, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["revoked_utc"] = EFFECTIVE_UTC + 1.0),
		"生效行不能携带撤销时刻")
	_expect(_rejects(effective, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["revoked_version"] = 2),
		"生效行不能携带撤销版本")
	_expect(_rejects(effective, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["effective_version"] = 0),
		"生效行缺少生效版本被拒绝")

	var proposed: Dictionary = _proposed_state()
	_expect(_rejects(proposed, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["revision"] = 2), "提案行 revision 不匹配被拒绝")
	_expect(_rejects(proposed, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["status"] = Resolution.STATUS_PASSED),
		"未达阈值的 passed 行被拒绝")
	_expect(_rejects(proposed, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_1"]["effective_version"] = 1),
		"未生效行携带生效版本被拒绝")

	# 两条生效规则不能复用同一个版本号。
	var two: Dictionary = _effective_state()
	var next_start: float = EFFECTIVE_UTC + HOUR
	two = Resolution.propose(two, "res_2", PLAYER_D, _proposal_from(next_start),
		next_start).state
	two = Resolution.vote(two, "res_2", PLAYER_E, true, next_start + 60.0).state
	two = Resolution.vote(two, "res_2", PLAYER_F, true, next_start + 120.0).state
	two = Resolution.close(two, "res_2", next_start + HOUR).state
	two = Resolution.activate(two, "res_2", next_start + 2.0 * HOUR).state
	_expect(Resolution.valid(two), "两条生效规则文档合法")
	_expect(_rejects(two, func(doc: Dictionary) -> void:
		doc["resolutions"]["res_2"]["effective_version"] = 1),
		"重复生效版本号被拒绝")


func _test_bounds_and_determinism() -> void:
	var full: Dictionary = Resolution.empty()
	var all_accepted: bool = true
	for index: int in Resolution.MAX_RESOLUTIONS:
		var result: Dictionary = Resolution.propose(full, "bulk_%03d" % index, PLAYER_A,
			_proposal(), START)
		all_accepted = all_accepted and result.ok
		full = result.state
	_expect(all_accepted and Resolution.valid(full),
		"文档接受恰好上限数量的决议")
	var accepted: Dictionary = full.duplicate(true)
	var overflow: Dictionary = Resolution.propose(full, "overflow", PLAYER_A, _proposal(),
		START)
	_expect(not overflow.ok and overflow.reason == "too_many",
		"超过决议数量上限被拒绝")
	_expect(full == accepted, "超限拒绝不修改文档")

	var voters: Dictionary = _proposed_state()
	for index: int in range(2, Resolution.MAX_VOTERS + 2):
		var voted: Dictionary = Resolution.vote(voters, "res_1", _player(index), true,
			VOTE_START)
		_expect(voted.ok, "上限内的赞成票被接受")
		voters = voted.state
	_expect(Resolution.valid(voters), "达到投票人数上限的文档合法")
	_expect(Resolution.vote(voters, "res_1", _player(Resolution.MAX_VOTERS + 2), true,
		VOTE_START).reason == "too_many_votes", "超过单边投票人数上限被拒绝")
	voters = Resolution.close(voters, "res_1", VOTE_END).state
	_expect(voters.resolutions["res_1"].status == Resolution.STATUS_PASSED,
		"上限内的大量赞成票可以通过")

	var first: Dictionary = _run_sequence()
	var second: Dictionary = _run_sequence()
	_expect(not first.is_empty() and first == second,
		"同一命令序列产生同一文档")
	_expect(JSON.stringify(first) == JSON.stringify(second),
		"同一命令序列的 JSON 文本也一致")
	_expect(int(first.rules_version) == 2
		and first.resolutions["res_1"].status == Resolution.STATUS_REVOKED,
		"确定性序列以生效后撤销结束")

	var seed: Dictionary = Resolution.empty()
	var untouched: Dictionary = seed.duplicate(true)
	Resolution.propose(seed, "res_1", PLAYER_A, _proposal(), START)
	Resolution.vote(seed, "res_1", PLAYER_B, true, VOTE_START)
	Resolution.tally(seed, "res_1")
	Resolution.close(seed, "res_1", VOTE_END)
	Resolution.activate(seed, "res_1", EFFECTIVE_UTC)
	Resolution.withdraw(seed, "res_1", PLAYER_A, VOTE_START)
	Resolution.revoke(seed, "res_1", PLAYER_B, EFFECTIVE_UTC)
	_expect(seed == untouched, "所有命令都不修改调用方文档")

	var long_title: String = "x".repeat(Resolution.MAX_TITLE_LENGTH)
	var long_result: Dictionary = Resolution.propose(Resolution.empty(), "long", PLAYER_A,
		_proposal_with("title", long_title), START)
	_expect(long_result.ok, "标题上限长度被接受")
	var too_long: Dictionary = Resolution.propose(Resolution.empty(), "long", PLAYER_A,
		_proposal_with("title", long_title + "x"), START)
	_expect(not too_long.ok and too_long.reason == "invalid_title",
		"超过标题上限被拒绝")


func _proposal() -> Dictionary:
	return _proposal_from(VOTE_START)


func _proposal_from(vote_start: float) -> Dictionary:
	return {
		"kind": Resolution.KIND_PUBLIC_WORKS,
		"title": "修桥",
		"vote_start_utc": vote_start,
		"vote_end_utc": vote_start + HOUR,
		"effective_utc": vote_start + 2.0 * HOUR,
	}


func _proposal_with(key: String, value: Variant) -> Dictionary:
	var proposal: Dictionary = _proposal()
	proposal[key] = value
	return proposal


func _proposed_state() -> Dictionary:
	return Resolution.propose(Resolution.empty(), "res_1", PLAYER_A, _proposal(),
		START).state


func _effective_state() -> Dictionary:
	var state: Dictionary = _proposed_state()
	state = Resolution.vote(state, "res_1", PLAYER_B, true, VOTE_START + 10.0).state
	state = Resolution.vote(state, "res_1", PLAYER_C, true, VOTE_START + 20.0).state
	state = Resolution.close(state, "res_1", VOTE_END).state
	return Resolution.activate(state, "res_1", EFFECTIVE_UTC).state


func _revoked_state() -> Dictionary:
	var state: Dictionary = _effective_state()
	return Resolution.revoke(state, "res_1", PLAYER_B, EFFECTIVE_UTC + 10.0).state


func _run_sequence() -> Dictionary:
	var state: Dictionary = _proposed_state()
	state = Resolution.vote(state, "res_1", PLAYER_B, true, VOTE_START + 10.0).state
	state = Resolution.vote(state, "res_1", PLAYER_C, true, VOTE_START + 20.0).state
	state = Resolution.close(state, "res_1", VOTE_END).state
	state = Resolution.activate(state, "res_1", EFFECTIVE_UTC).state
	return Resolution.revoke(state, "res_1", PLAYER_B, EFFECTIVE_UTC + 10.0).state


func _player(index: int) -> String:
	return "player_%032d" % index


func _rejects(state: Dictionary, mutate: Callable) -> bool:
	var copy: Dictionary = state.duplicate(true)
	mutate.call(copy)
	return not Resolution.valid(copy)


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
