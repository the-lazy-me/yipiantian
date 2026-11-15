extends SceneTree
## M12-04 执法闭环接入世界权威：HeadlessWorld 直接驱动 disputes.json，不经过
## 网络。覆盖缺失文档初始化、立案/证据/申诉、非管理员拒绝、受理→裁定→申诉→
## 更正→结案的历史保留、AI 建议零变化、恶意/空证据与非法事件 id、同命令重放、
## 换参数冲突、保存失败不留半状态、按身份过滤的视图，以及重启后的持久化与重放。
##
## 所有写入通过权威时钟；测试只从返回结果和落盘文档取证据。

const World = preload("res://world/headless_world.gd")
const Disputes = preload("res://world/dispute_state.gd")
const DisputesStore = preload("res://world/disputes_store.gd")
const FarmCommand = preload("res://farm/farm_command.gd")

const START: float = 2000000000.0
const WORLD: String = "world-dispute-authority"

const ADMIN: String = "player_00000000000000000000000000000001"
const FILER: String = "player_00000000000000000000000000000002"
const TARGET: String = "player_00000000000000000000000000000003"
const OUTSIDER: String = "player_00000000000000000000000000000004"
const STRANGER: String = "player_00000000000000000000000000000005"
const UNRELATED: String = "player_00000000000000000000000000000006"

var dir: String = ""
var world_dir: String = ""
var world
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/dispute-authority-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	var opened: Dictionary = _open_world(world_dir, ADMIN, START)
	if not bool(opened.get("ok", false)):
		_expect(false, "The authoritative world opens: %s" % str(opened.get("reason", "")))
		_finish()
		return
	_test_initialization()
	_test_filing()
	_test_non_authority_writes()
	_test_advisor_only()
	_test_evidence()
	_test_ruling_and_correction()
	_test_compensation()
	_test_views()
	_test_restart()
	_test_store_guards()
	_test_save_failure()
	_test_compensation_save_guards()
	_finish()


func _open_world(directory: String, host: String, now: float) -> Dictionary:
	var opened_world = World.new()
	var opened: Dictionary = opened_world.open(directory, now, WORLD, host)
	if bool(opened.get("ok", false)):
		world = opened_world
	return opened


func _execute(action: String, actor: String, args: Dictionary,
		command_id: String) -> Dictionary:
	return world.execute_dispute(action, actor, args, command_id)


func _case_view(view: Dictionary, case_id: String) -> Dictionary:
	var rows: Variant = view.get("cases")
	if rows is Array:
		for row_value: Variant in rows:
			if row_value is Dictionary \
					and str((row_value as Dictionary).get("case_id", "")) == case_id:
				return row_value
	return {}


func _public_row(view: Dictionary, case_id: String) -> Dictionary:
	var rows: Variant = view.get("public")
	if rows is Array:
		for row_value: Variant in rows:
			if row_value is Dictionary \
					and str((row_value as Dictionary).get("case_id", "")) == case_id:
				return row_value
	return {}


# ------------------------------------------------------------------- fixtures

## 缺失文档只在房主存在时初始化；房主是花名册里唯一的权威（规则禁止同一玩家
## 同时出现在 admin 与 arbiter，因此房主写入 admin）。普通玩家与匿名连接没有
## 案件细节，只看到空公开表。
func _test_initialization() -> void:
	var view: Dictionary = world.disputes_view(ADMIN)
	_expect(bool(view.get("available", false)),
		"A fresh hosted room has a dispute authority")
	_expect(bool(view.get("is_authority", false)),
		"The startup host is the room's authority")
	var roles: Variant = view.get("authority_roles")
	var admin_ids: Variant = (roles as Dictionary).get("admin", []) if roles is Dictionary else []
	var arbiter_ids: Variant = (roles as Dictionary).get("arbiter", []) if roles is Dictionary else []
	_expect(admin_ids is Array and (admin_ids as Array) == [ADMIN]
			and arbiter_ids is Array and (arbiter_ids as Array).is_empty(),
		"The host is the only authority id in the fresh roster")
	_expect((view.get("cases", []) as Array).is_empty()
			and (view.get("public", []) as Array).is_empty(),
		"A fresh room has no cases")
	_expect(not FileAccess.file_exists(_disputes_path()),
		"A fresh room has no disputes.json before the first write")
	var member_view: Dictionary = world.disputes_view(FILER)
	_expect(not bool(member_view.get("is_authority", true))
			and (member_view.get("cases", []) as Array).is_empty(),
		"An ordinary player sees no case details in a fresh room")
	var anonymous_view: Dictionary = world.disputes_view("")
	_expect(not bool(anonymous_view.get("is_authority", true))
			and (anonymous_view.get("cases", []) as Array).is_empty(),
		"An anonymous viewer sees no case details")
	_expect(Disputes.valid(world.disputes),
		"The in-memory dispute document passes the strict validator")


func _test_filing() -> void:
	var no_events: Dictionary = _execute("file", FILER, {
		"case_id": "case_1", "against": TARGET, "event_ids": [],
	}, "cmd_file_no_events")
	_expect(str(no_events.get("reason", "")) == "no_events",
		"A filing without authoritative events is refused")
	_expect(not FileAccess.file_exists(_disputes_path()),
		"A refused filing creates no disputes.json")
	var bad_events: Dictionary = _execute("file", FILER, {
		"case_id": "case_1", "against": TARGET, "event_ids": ["unknown event!"],
	}, "cmd_file_bad_events")
	_expect(str(bad_events.get("reason", "")) == "invalid_events",
		"An invalid or unknown authoritative event id is refused")
	_expect(not FileAccess.file_exists(_disputes_path()),
		"An invalid event filing creates no disputes.json")

	# 格式合法但从未发生的事件必须被权威拒绝：规则层只看形状，权威才看日志。
	var ghost: Dictionary = _execute("file", FILER, {
		"case_id": "case_ghost", "against": TARGET, "event_ids": ["event_ghost"],
	}, "cmd_file_ghost")
	_expect(str(ghost.get("reason", "")) == "unknown_event",
		"A filing over an event that never happened is refused")
	_expect(not FileAccess.file_exists(_disputes_path()),
		"An unknown-event filing creates no disputes.json")

	# 另一个世界的真实事件也不是本世界的事实；复制事件编号不能跨世界立案。
	var other_dir: String = dir.path_join("other-world-events")
	DirAccess.make_dir_recursive_absolute(other_dir)
	var other_world = World.new()
	var other_opened: Dictionary = other_world.open(other_dir, START, "world-other", ADMIN)
	_expect(bool(other_opened.get("ok", false)),
		"The other world opens for the cross-world event fixture")
	var other_event: Dictionary = other_world.execute(
		FarmCommand.make_set_theft("event_other_world", true,
			other_world.authority_now_utc()), FILER)
	_expect(bool(other_event.get("ok", false)),
		"The other world records its own authoritative event")
	var foreign: Dictionary = _execute("file", FILER, {
		"case_id": "case_foreign", "against": TARGET,
		"event_ids": ["event_other_world"],
	}, "cmd_file_foreign")
	_expect(str(foreign.get("reason", "")) == "unknown_event",
		"An event from another world is refused as unknown")
	_expect(not FileAccess.file_exists(_disputes_path()),
		"A cross-world event filing creates no disputes.json")

	_expect(bool(_make_event("event_alpha").get("ok", false)),
		"The world records event_alpha as an accepted command")
	_expect(bool(_make_event("event_beta").get("ok", false)),
		"The world records event_beta as an accepted command")

	var filed: Dictionary = _execute("file", FILER, {
		"case_id": "case_1", "against": TARGET,
		"event_ids": ["event_alpha", "event_beta"],
	}, "cmd_file_1")
	_expect(bool(filed.get("ok", false))
			and str(filed.get("status", "")) == Disputes.STATUS_FILED,
		"An ordinary member files a case over the authority")
	_expect(FileAccess.file_exists(_disputes_path()),
		"A successful filing persists disputes.json")
	var stored: Dictionary = _disputes_doc()
	_expect(int(stored.get("version", -1)) == 1
			and str(stored.get("world_id", "")) == WORLD,
		"disputes.json carries version 1 and the world identity")
	var stored_state: Variant = stored.get("state")
	_expect(stored_state is Dictionary and Disputes.valid(stored_state),
		"disputes.json carries a strictly valid dispute document")

	var bytes_before: PackedByteArray = _disputes_bytes()
	var replay: Dictionary = _execute("file", FILER, {
		"case_id": "case_1", "against": TARGET,
		"event_ids": ["event_alpha", "event_beta"],
	}, "cmd_file_1")
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the same filing command returns the first result")
	_expect(_disputes_bytes() == bytes_before,
		"A filing replay leaves disputes.json byte-identical")
	var conflict: Dictionary = _execute("file", FILER, {
		"case_id": "case_1", "against": OUTSIDER,
		"event_ids": ["event_alpha", "event_beta"],
	}, "cmd_file_1")
	_expect(str(conflict.get("reason", "")) == "command_conflict",
		"Reusing a filing command id with different arguments conflicts")
	_expect(_disputes_bytes() == bytes_before,
		"A filing conflict leaves disputes.json byte-identical")
	var duplicate: Dictionary = _execute("file", FILER, {
		"case_id": "case_1", "against": OUTSIDER,
		"event_ids": ["event_gamma"],
	}, "cmd_file_duplicate_case")
	_expect(str(duplicate.get("reason", "")) == "duplicate_case",
		"Filing another case under an existing case id is refused")
	_expect(_disputes_bytes() == bytes_before,
		"A duplicate case filing leaves disputes.json byte-identical")


## 普通成员只能立案、提交证据与申诉：受理/裁定/更正/结案都因不在花名册而
## 返回 forbidden，案件文档不变。
func _test_non_authority_writes() -> void:
	var bytes_before: PackedByteArray = _disputes_bytes()
	var accept: Dictionary = _execute("accept", FILER,
		{"case_id": "case_1"}, "cmd_member_accept")
	_expect(str(accept.get("reason", "")) == "forbidden",
		"A non-authority accept is refused as forbidden")
	var reject: Dictionary = _execute("reject", FILER,
		{"case_id": "case_1"}, "cmd_member_reject")
	_expect(str(reject.get("reason", "")) == "forbidden",
		"A non-authority reject is refused as forbidden")
	var rule: Dictionary = _execute("rule", FILER, {
		"case_id": "case_1",
		"decision": {"advisor": false, "authority": true,
			"outcome": "upheld", "reason": "越权裁定"},
	}, "cmd_member_rule")
	_expect(str(rule.get("reason", "")) == "forbidden",
		"A non-authority ruling is refused as forbidden")
	var correct: Dictionary = _execute("correct", FILER,
		{"case_id": "case_1", "reason": "越权更正"}, "cmd_member_correct")
	_expect(str(correct.get("reason", "")) == "forbidden",
		"A non-authority correction is refused as forbidden")
	var close: Dictionary = _execute("close", FILER,
		{"case_id": "case_1"}, "cmd_member_close")
	_expect(str(close.get("reason", "")) == "forbidden",
		"A non-authority close is refused as forbidden")
	var stored: Dictionary = _case_view(world.disputes_view(ADMIN), "case_1")
	_expect(str(stored.get("status", "")) == Disputes.STATUS_FILED
			and (stored.get("audit", []) as Array).is_empty(),
		"Refused authority writes leave the case filed with no audit")
	_expect(_disputes_bytes() == bytes_before,
		"Refused authority writes leave disputes.json byte-identical")


## AI 建议在读取案件之前结束：固定 advisory_only，案件与文档都不变。
func _test_advisor_only() -> void:
	var bytes_before: PackedByteArray = _disputes_bytes()
	var advisor: Dictionary = _execute("rule", ADMIN, {
		"case_id": "case_1",
		"decision": {"advisor": true, "authority": false,
			"outcome": "upheld", "reason": "AI 建议"},
	}, "cmd_advisor")
	_expect(not bool(advisor.get("ok", true))
			and str(advisor.get("reason", "")) == "advisory_only",
		"An advisor ruling returns advisory_only")
	var stored: Dictionary = _case_view(world.disputes_view(ADMIN), "case_1")
	_expect(str(stored.get("status", "")) == Disputes.STATUS_FILED
			and (stored.get("audit", []) as Array).is_empty(),
		"An advisor ruling changes no case state")
	_expect(_disputes_bytes() == bytes_before,
		"An advisor ruling leaves disputes.json byte-identical")


func _test_evidence() -> void:
	var bytes_before: PackedByteArray = _disputes_bytes()
	var first: Dictionary = _execute("evidence", FILER, {
		"case_id": "case_1", "evidence_id": "ev_1",
		"kind": Disputes.EVIDENCE_AUTHORITY_EVENT, "source": "event_alpha",
	}, "cmd_ev_1")
	_expect(bool(first.get("ok", false)),
		"A party submits authoritative-event evidence")
	var replay: Dictionary = _execute("evidence", FILER, {
		"case_id": "case_1", "evidence_id": "ev_1",
		"kind": Disputes.EVIDENCE_AUTHORITY_EVENT, "source": "event_alpha",
	}, "cmd_ev_1")
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the evidence command is a duplicate")
	var duplicate: Dictionary = _execute("evidence", FILER, {
		"case_id": "case_1", "evidence_id": "ev_1",
		"kind": Disputes.EVIDENCE_AUTHORITY_EVENT, "source": "event_beta",
	}, "cmd_ev_duplicate")
	_expect(str(duplicate.get("reason", "")) == "duplicate_evidence",
		"A reused evidence id with different content is refused")
	var empty: Dictionary = _execute("evidence", FILER, {
		"case_id": "case_1", "evidence_id": "", "kind": "witness", "source": "",
	}, "cmd_ev_empty")
	_expect(str(empty.get("reason", "")) == "invalid_evidence",
		"Empty or malformed evidence is refused")
	var malicious: Dictionary = _execute("evidence", FILER, {
		"case_id": "case_1", "evidence_id": "ev_bad",
		"kind": "malware", "source": "doc_1",
	}, "cmd_ev_bad")
	_expect(str(malicious.get("reason", "")) == "invalid_evidence",
		"An evidence kind outside the fixed catalog is refused")
	var missing: Dictionary = _execute("evidence", FILER, {
		"case_id": "case_missing", "evidence_id": "ev_missing",
		"kind": "witness", "source": "doc_1",
	}, "cmd_ev_missing")
	_expect(str(missing.get("reason", "")) == "missing_case",
		"Evidence for an unknown case is refused")
	var witness: Dictionary = _execute("evidence", TARGET, {
		"case_id": "case_1", "evidence_id": "ev_witness",
		"kind": Disputes.EVIDENCE_WITNESS, "source": "witness_1",
	}, "cmd_ev_witness")
	_expect(bool(witness.get("ok", false)),
		"The other party may also submit evidence")
	var stranger: Dictionary = _execute("evidence", STRANGER, {
		"case_id": "case_1", "evidence_id": "ev_stranger",
		"kind": Disputes.EVIDENCE_DOCUMENT, "source": "doc_1",
	}, "cmd_ev_stranger")
	_expect(bool(stranger.get("ok", false)),
		"A non-party may submit evidence and becomes related to the case")
	var stored: Dictionary = _case_view(world.disputes_view(ADMIN), "case_1")
	_expect((stored.get("evidence", []) as Array).size() == 3,
		"Only the three accepted evidence rows are stored")
	_expect(_disputes_bytes() != bytes_before,
		"The accepted evidence is persisted")


func _test_ruling_and_correction() -> void:
	var accepted: Dictionary = _execute("accept", ADMIN,
		{"case_id": "case_1"}, "cmd_accept")
	_expect(bool(accepted.get("ok", false))
			and str(accepted.get("status", "")) == Disputes.STATUS_ACCEPTED,
		"An administrator accepts the case")
	var bytes_after_accept: PackedByteArray = _disputes_bytes()
	var accept_replay: Dictionary = _execute("accept", ADMIN,
		{"case_id": "case_1"}, "cmd_accept")
	_expect(bool(accept_replay.get("ok", false))
			and bool(accept_replay.get("duplicate", false)),
		"Replaying the accept command is a duplicate")
	_expect(_disputes_bytes() == bytes_after_accept,
		"An accept replay leaves disputes.json byte-identical")
	var reject_after: Dictionary = _execute("reject", ADMIN,
		{"case_id": "case_1"}, "cmd_reject_after_accept")
	_expect(str(reject_after.get("reason", "")) == "invalid_status",
		"An accepted case can no longer be rejected")

	var advisor: Dictionary = _execute("rule", ADMIN, {
		"case_id": "case_1",
		"decision": {"advisor": true, "authority": false,
			"outcome": "upheld", "reason": "AI 建议"},
	}, "cmd_advisor_after_accept")
	_expect(str(advisor.get("reason", "")) == "advisory_only",
		"An advisor ruling after acceptance still returns advisory_only")

	var ruled: Dictionary = _execute("rule", ADMIN, {
		"case_id": "case_1",
		"decision": {"advisor": false, "authority": true,
			"outcome": "upheld", "reason": "证据成立"},
	}, "cmd_rule")
	_expect(bool(ruled.get("ok", false))
			and str(ruled.get("status", "")) == Disputes.STATUS_RULED,
		"An administrator rules the accepted case")
	var after_rule: Dictionary = _case_view(world.disputes_view(ADMIN), "case_1")
	var ruling_before: Dictionary = (after_rule.get("ruling") as Dictionary).duplicate(true)
	_expect(str(ruling_before.get("by", "")) == ADMIN
			and str(ruling_before.get("outcome", "")) == "upheld",
		"The ruling records its author and semantic outcome")
	var bytes_after_rule: PackedByteArray = _disputes_bytes()
	var rule_replay: Dictionary = _execute("rule", ADMIN, {
		"case_id": "case_1",
		"decision": {"advisor": false, "authority": true,
			"outcome": "upheld", "reason": "证据成立"},
	}, "cmd_rule")
	_expect(bool(rule_replay.get("ok", false))
			and bool(rule_replay.get("duplicate", false)),
		"Replaying the ruling command is a duplicate")
	_expect(_disputes_bytes() == bytes_after_rule,
		"A ruling replay leaves disputes.json byte-identical")
	var conflict: Dictionary = _execute("rule", ADMIN, {
		"case_id": "case_1",
		"decision": {"advisor": false, "authority": true,
			"outcome": "dismissed", "reason": "换一个裁定"},
	}, "cmd_rule")
	_expect(str(conflict.get("reason", "")) == "command_conflict",
		"Reusing a ruling command id with another decision conflicts")
	_expect(_disputes_bytes() == bytes_after_rule,
		"A ruling conflict leaves disputes.json byte-identical")

	var outsider_appeal: Dictionary = _execute("appeal", OUTSIDER,
		{"case_id": "case_1", "reason": "旁人不服"}, "cmd_appeal_outsider")
	_expect(str(outsider_appeal.get("reason", "")) == "not_party",
		"Only the case parties may appeal")
	var appeal: Dictionary = _execute("appeal", TARGET,
		{"case_id": "case_1", "reason": "不服裁定"}, "cmd_appeal")
	_expect(bool(appeal.get("ok", false))
			and str(appeal.get("status", "")) == Disputes.STATUS_APPEALED,
		"A party appeals the ruling")
	var after_appeal: Dictionary = _case_view(world.disputes_view(ADMIN), "case_1")
	_expect((after_appeal.get("ruling") as Dictionary) == ruling_before,
		"An appeal preserves the original ruling")
	var bytes_after_appeal: PackedByteArray = _disputes_bytes()
	var appeal_replay: Dictionary = _execute("appeal", TARGET,
		{"case_id": "case_1", "reason": "不服裁定"}, "cmd_appeal")
	_expect(bool(appeal_replay.get("ok", false))
			and bool(appeal_replay.get("duplicate", false)),
		"Replaying the appeal command is a duplicate")
	_expect(_disputes_bytes() == bytes_after_appeal,
		"An appeal replay leaves disputes.json byte-identical")
	var second_appeal: Dictionary = _execute("appeal", FILER,
		{"case_id": "case_1", "reason": "再次申诉"}, "cmd_appeal_second")
	_expect(str(second_appeal.get("reason", "")) == "already_appealed",
		"A case can only be appealed once")

	var corrected: Dictionary = _execute("correct", ADMIN,
		{"case_id": "case_1", "reason": "补充证据后更正"}, "cmd_correct")
	_expect(bool(corrected.get("ok", false))
			and str(corrected.get("status", "")) == Disputes.STATUS_CORRECTED,
		"An administrator corrects the appealed case")
	var after_correction: Dictionary = _case_view(world.disputes_view(ADMIN), "case_1")
	_expect((after_correction.get("ruling") as Dictionary) == ruling_before
			and (after_correction.get("appeals", []) as Array).size() == 1
			and (after_correction.get("corrections", []) as Array).size() == 1,
		"A correction preserves the ruling and the appeal")
	_expect(_audit_actions(after_correction) == ["accept", "rule", "correct"],
		"The correction appends its own audit row")
	var bytes_after_correction: PackedByteArray = _disputes_bytes()
	var correction_replay: Dictionary = _execute("correct", ADMIN,
		{"case_id": "case_1", "reason": "补充证据后更正"}, "cmd_correct")
	_expect(bool(correction_replay.get("ok", false))
			and bool(correction_replay.get("duplicate", false)),
		"Replaying the correction command is a duplicate")
	_expect(_disputes_bytes() == bytes_after_correction,
		"A correction replay leaves disputes.json byte-identical")
	var second_correction: Dictionary = _execute("correct", ADMIN,
		{"case_id": "case_1", "reason": "再次更正"}, "cmd_correct_second")
	_expect(str(second_correction.get("reason", "")) == "already_corrected",
		"A case can only be corrected once")

	var closed: Dictionary = _execute("close", ADMIN,
		{"case_id": "case_1"}, "cmd_close")
	_expect(bool(closed.get("ok", false))
			and str(closed.get("status", "")) == Disputes.STATUS_CLOSED,
		"An administrator closes the corrected case")
	var after_close: Dictionary = _case_view(world.disputes_view(ADMIN), "case_1")
	_expect(_audit_actions(after_close) == ["accept", "rule", "correct", "close"],
		"Closing appends the final audit row")
	_expect((after_close.get("ruling") as Dictionary) == ruling_before
			and (after_close.get("appeals", []) as Array).size() == 1
			and (after_close.get("corrections", []) as Array).size() == 1,
		"Closing keeps the ruling, appeal and correction history")
	var bytes_after_close: PackedByteArray = _disputes_bytes()
	var close_replay: Dictionary = _execute("close", ADMIN,
		{"case_id": "case_1"}, "cmd_close")
	_expect(bool(close_replay.get("ok", false))
			and bool(close_replay.get("duplicate", false)),
		"Replaying the close command is a duplicate")
	_expect(_disputes_bytes() == bytes_after_close,
		"A close replay leaves disputes.json byte-identical")
	var evidence_after: Dictionary = _execute("evidence", TARGET, {
		"case_id": "case_1", "evidence_id": "ev_after_close",
		"kind": "witness", "source": "witness_2",
	}, "cmd_ev_after_close")
	_expect(str(evidence_after.get("reason", "")) == "case_closed",
		"A closed case refuses new evidence")
	var correct_after: Dictionary = _execute("correct", ADMIN,
		{"case_id": "case_1", "reason": "结案后更正"}, "cmd_correct_after_close")
	_expect(str(correct_after.get("reason", "")) == "already_closed",
		"A closed case refuses another correction")
	var close_again: Dictionary = _execute("close", ADMIN,
		{"case_id": "case_1"}, "cmd_close_again")
	_expect(str(close_again.get("reason", "")) == "already_closed",
		"Closing an already closed case is refused")


## 补偿裁定：被裁定方（against）的可用现金转入受补偿方（filed_by）；金额不足
## 拒绝裁定，成功后同一案件重放/二次裁定不再转账，现金总额与已发行量不变。
func _test_compensation() -> void:
	_expect(bool(_make_event("event_comp").get("ok", false)),
		"The world records event_comp")
	_expect(_open_account(FILER, "acct_filer"), "The filer opens a real cash account")
	_expect(_open_account(TARGET, "acct_target"), "The target opens a real cash account")
	var filer_before: int = world.farm.economy_cash(FILER)
	var target_before: int = world.farm.economy_cash(TARGET)
	var total_before: int = world.farm.economy_total_cash()
	var issued_before: int = world.farm.economy_issued()

	var filed: Dictionary = _execute("file", FILER, {
		"case_id": "case_comp", "against": TARGET,
		"event_ids": ["event_comp"],
	}, "cmd_comp_file")
	_expect(bool(filed.get("ok", false)), "The compensation case is filed")
	var accepted: Dictionary = _execute("accept", ADMIN,
		{"case_id": "case_comp"}, "cmd_comp_accept")
	_expect(bool(accepted.get("ok", false)), "The compensation case is accepted")

	var missing: Dictionary = _execute("rule", ADMIN, {
		"case_id": "case_comp",
		"decision": {"advisor": false, "authority": true,
			"outcome": "compensation", "reason": "缺少金额"},
	}, "cmd_comp_missing_amount")
	_expect(str(missing.get("reason", "")) == "invalid_compensation",
		"A compensation ruling without an amount is refused")
	var too_much: Dictionary = _execute("rule", ADMIN, {
		"case_id": "case_comp",
		"decision": {"advisor": false, "authority": true,
			"outcome": "compensation", "reason": "超额补偿"},
		"amount": 100000,
	}, "cmd_comp_too_much")
	_expect(str(too_much.get("reason", "")) == "compensation_insufficient",
		"An unaffordable compensation is refused instead of partially charged")
	var member_rule: Dictionary = _execute("rule", FILER, {
		"case_id": "case_comp",
		"decision": {"advisor": false, "authority": true,
			"outcome": "compensation", "reason": "越权补偿"},
		"amount": 10,
	}, "cmd_comp_member")
	_expect(str(member_rule.get("reason", "")) == "forbidden",
		"A non-authority compensation ruling is refused")
	_expect(world.farm.economy_cash(FILER) == filer_before
			and world.farm.economy_cash(TARGET) == target_before,
		"Refused compensation rulings move no cash")
	var still: Dictionary = _case_view(world.disputes_view(ADMIN), "case_comp")
	_expect(str(still.get("status", "")) == Disputes.STATUS_ACCEPTED,
		"A refused compensation leaves the case accepted")

	var args: Dictionary = {
		"case_id": "case_comp",
		"decision": {"advisor": false, "authority": true,
			"outcome": "compensation", "reason": "证据成立，赔偿三十"},
		"amount": 30,
	}
	var ruled: Dictionary = _execute("rule", ADMIN, args, "cmd_comp_rule")
	_expect(bool(ruled.get("ok", false))
			and str(ruled.get("status", "")) == Disputes.STATUS_RULED,
		"The affordable compensation ruling succeeds")
	_expect(world.farm.economy_cash(TARGET) == target_before - 30,
		"The sanctioned party pays the compensation")
	_expect(world.farm.economy_cash(FILER) == filer_before + 30,
		"The compensated party receives the compensation")
	_expect(world.farm.economy_total_cash() == total_before,
		"The compensation conserves total cash")
	_expect(world.farm.economy_issued() == issued_before,
		"The compensation issues no new cash")
	var reconciled: Dictionary = world.farm.economy_reconcile()
	_expect(bool(reconciled.get("ok", false))
			and int(reconciled.get("total_cash", -1)) == total_before,
		"The ledger reconciles after the compensation")
	var entry: Dictionary = _ledger_entry("dispute_compensate_case_comp")
	_expect(str(entry.get("kind", "")) == "pay",
		"The compensation is a balanced pay ledger entry")
	var lines: Array = entry.get("lines", [])
	_expect(lines.size() == 2
			and _line_matches(lines, "account:" + FILER, 30, 0)
			and _line_matches(lines, "account:" + TARGET, 0, 30),
		"The ledger debits the receiver and credits the sanctioned party")
	var farm_bytes: PackedByteArray = _farm_bytes()
	var dispute_bytes: PackedByteArray = _disputes_bytes()
	var replay: Dictionary = _execute("rule", ADMIN, args, "cmd_comp_rule")
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"Replaying the compensation ruling returns duplicate")
	_expect(world.farm.economy_cash(FILER) == filer_before + 30
			and world.farm.economy_cash(TARGET) == target_before - 30,
		"A compensation replay moves no cash again")
	_expect(_farm_bytes() == farm_bytes and _disputes_bytes() == dispute_bytes,
		"A compensation replay leaves both documents byte-identical")
	var again: Dictionary = _execute("rule", ADMIN, args, "cmd_comp_rule_again")
	_expect(str(again.get("reason", "")) == "invalid_status",
		"A second ruling on the same case is refused")
	_expect(world.farm.economy_cash(FILER) == filer_before + 30
			and world.farm.economy_cash(TARGET) == target_before - 30,
		"A second ruling moves no cash again")


## 视图按连接身份过滤：管理员看全部，当事人与证据提交人看相关案件，无身份连接
## 只看公开状态行。
func _test_views() -> void:
	_expect(bool(_make_event("event_delta").get("ok", false)),
		"The world records event_delta for the second case")
	var second: Dictionary = _execute("file", OUTSIDER, {
		"case_id": "case_2", "against": TARGET, "event_ids": ["event_delta"],
	}, "cmd_file_2")
	_expect(bool(second.get("ok", false)),
		"A second case from another member is accepted")

	var admin_view: Dictionary = world.disputes_view(ADMIN)
	_expect((admin_view.get("cases", []) as Array).size() == 3
			and (admin_view.get("public", []) as Array).size() == 3,
		"An administrator sees every case and every public row")
	_expect(_public_row(admin_view, "case_1").size() > 0,
		"The public rows carry both cases")
	_expect(not _public_row(admin_view, "case_1").has("evidence"),
		"Public rows do not leak evidence details")

	var filer_view: Dictionary = world.disputes_view(FILER)
	_expect((filer_view.get("cases", []) as Array).size() == 2
			and not _case_view(filer_view, "case_1").is_empty()
			and not _case_view(filer_view, "case_comp").is_empty(),
		"A party sees only the cases it filed")
	_expect((filer_view.get("public", []) as Array).size() == 3,
		"A party still sees the public status of every case")
	var target_view: Dictionary = world.disputes_view(TARGET)
	_expect((target_view.get("cases", []) as Array).size() == 3,
		"The target of every case sees every case")
	var outsider_view: Dictionary = world.disputes_view(OUTSIDER)
	_expect((outsider_view.get("cases", []) as Array).size() == 1
			and not _case_view(outsider_view, "case_2").is_empty(),
		"The second filer sees only its own case")
	var stranger_view: Dictionary = world.disputes_view(STRANGER)
	_expect((stranger_view.get("cases", []) as Array).size() == 1
			and not _case_view(stranger_view, "case_1").is_empty(),
		"An evidence submitter sees the case it contributed to")
	var unrelated_view: Dictionary = world.disputes_view(UNRELATED)
	_expect((unrelated_view.get("cases", []) as Array).is_empty()
			and (unrelated_view.get("public", []) as Array).size() == 3,
		"An unrelated member sees only public status rows")
	var anonymous_view: Dictionary = world.disputes_view("")
	_expect((anonymous_view.get("cases", []) as Array).is_empty()
			and (anonymous_view.get("public", []) as Array).size() == 3,
		"An anonymous connection sees only public status rows")


## 重启保留案件、裁定与审计；同一 command id 的重放由已写入的案件事实识别为
## duplicate，文档字节不变。
func _test_restart() -> void:
	var bytes_before: PackedByteArray = _disputes_bytes()
	var reopened: Dictionary = _open_world(world_dir, "", START + 3600.0)
	_expect(bool(reopened.get("ok", false)),
		"The world reopens from the existing disputes.json: %s"
			% str(reopened.get("reason", "")))
	if not bool(reopened.get("ok", false)):
		return
	_expect(_disputes_bytes() == bytes_before,
		"Reopening the world does not rewrite disputes.json")
	var view: Dictionary = world.disputes_view(ADMIN)
	_expect(bool(view.get("is_authority", false)),
		"The stored authority roster survives the restart")
	var case_1: Dictionary = _case_view(view, "case_1")
	_expect(str(case_1.get("status", "")) == Disputes.STATUS_CLOSED,
		"The closed case survives the restart")
	_expect(_audit_actions(case_1) == ["accept", "rule", "correct", "close"],
		"The full audit trail survives the restart")
	_expect(str((case_1.get("ruling") as Dictionary).get("outcome", "")) == "upheld",
		"The original ruling survives the restart")
	var case_comp: Dictionary = _case_view(view, "case_comp")
	_expect(str(case_comp.get("status", "")) == Disputes.STATUS_RULED
			and str((case_comp.get("ruling") as Dictionary).get("outcome", ""))
				== "compensation",
		"The compensation ruling survives the restart")
	_expect(world.farm.economy_cash(FILER) == 150
			and world.farm.economy_cash(TARGET) == 90,
		"The compensation balances survive the restart exactly once")
	var comp_again: Dictionary = _execute("rule", ADMIN, {
		"case_id": "case_comp",
		"decision": {"advisor": false, "authority": true,
			"outcome": "compensation", "reason": "重启后再次裁定"},
		"amount": 30,
	}, "cmd_comp_rule_after_restart")
	_expect(str(comp_again.get("reason", "")) == "invalid_status",
		"A post-restart ruling attempt is refused")
	_expect(world.farm.economy_cash(FILER) == 150
			and world.farm.economy_cash(TARGET) == 90,
		"A post-restart ruling attempt moves no cash")
	var file_replay: Dictionary = _execute("file", FILER, {
		"case_id": "case_1", "against": TARGET,
		"event_ids": ["event_alpha", "event_beta"],
	}, "cmd_file_1")
	_expect(bool(file_replay.get("ok", false))
			and bool(file_replay.get("duplicate", false)),
		"The filing command still replays after the restart")
	var accept_replay: Dictionary = _execute("accept", ADMIN,
		{"case_id": "case_1"}, "cmd_accept")
	_expect(bool(accept_replay.get("ok", false))
			and bool(accept_replay.get("duplicate", false)),
		"The accept command still replays after the restart")
	var rule_replay: Dictionary = _execute("rule", ADMIN, {
		"case_id": "case_1",
		"decision": {"advisor": false, "authority": true,
			"outcome": "upheld", "reason": "证据成立"},
	}, "cmd_rule")
	_expect(bool(rule_replay.get("ok", false))
			and bool(rule_replay.get("duplicate", false)),
		"The ruling command still replays after the restart")
	var close_replay: Dictionary = _execute("close", ADMIN,
		{"case_id": "case_1"}, "cmd_close")
	_expect(bool(close_replay.get("ok", false))
			and bool(close_replay.get("duplicate", false)),
		"The close command still replays after the restart")
	_expect(_disputes_bytes() == bytes_before,
		"Restart replays leave disputes.json byte-identical")


# ------------------------------------------------------------- storage guards

func _test_store_guards() -> void:
	var corrupt_dir: String = dir.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	_write_text(corrupt_dir.path_join("disputes.json"), "{")
	var corrupt_open: Dictionary = World.new().open(corrupt_dir, START, WORLD, ADMIN)
	_expect(not bool(corrupt_open.get("ok", true))
			and str(corrupt_open.get("reason", "")) == "load_disputes_corrupt",
		"A corrupt dispute document stops the authority")

	var version_dir: String = dir.path_join("unsupported")
	DirAccess.make_dir_recursive_absolute(version_dir)
	_write_text(version_dir.path_join("disputes.json"), JSON.stringify({
		"version": 2, "world_id": WORLD, "state": Disputes.empty([ADMIN], []),
	}))
	var version_open: Dictionary = World.new().open(version_dir, START, WORLD, ADMIN)
	_expect(not bool(version_open.get("ok", true))
			and str(version_open.get("reason", "")) == "load_disputes_unsupported",
		"An unsupported dispute document version stops the authority")

	var other_dir: String = dir.path_join("other-world")
	DirAccess.make_dir_recursive_absolute(other_dir)
	_write_text(other_dir.path_join("disputes.json"), JSON.stringify({
		"version": 1, "world_id": "another-world",
		"state": Disputes.empty([ADMIN], []),
	}))
	var other_open: Dictionary = World.new().open(other_dir, START, WORLD, ADMIN)
	_expect(not bool(other_open.get("ok", true))
			and str(other_open.get("reason", "")) == "load_disputes_world_mismatch",
		"A dispute document from another world stops the authority")

	var hostless_dir: String = dir.path_join("hostless")
	DirAccess.make_dir_recursive_absolute(hostless_dir)
	var hostless_world = World.new()
	var hostless_open: Dictionary = hostless_world.open(hostless_dir, START, WORLD, "")
	_expect(bool(hostless_open.get("ok", false)),
		"A world without a host still opens")
	if bool(hostless_open.get("ok", false)):
		_expect(not bool(hostless_world.disputes_view("").get("available", true)),
			"A hostless room has no dispute authority")
		var refused: Dictionary = hostless_world.execute_dispute("file", ADMIN, {
			"case_id": "case_1", "against": TARGET, "event_ids": ["event_alpha"],
		}, "cmd_hostless")
		_expect(str(refused.get("reason", "")) == "no_host",
			"A hostless room refuses dispute writes as no_host")

	# A store that never loaded has no world identity, so a save would write an
	# empty `world_id` that every later open rejects as `world_mismatch`.
	var fresh_dir: String = dir.path_join("fresh-store")
	var fresh_store = DisputesStore.new(fresh_dir)
	var fresh_saved: Dictionary = fresh_store.save_state(Disputes.empty([ADMIN], []))
	_expect(not bool(fresh_saved.get("ok", true))
			and str(fresh_saved.get("kind", "")) == "invalid_world",
		"A store without a loaded identity refuses to save")
	_expect(not FileAccess.file_exists(fresh_dir.path_join("disputes.json")),
		"A refused save creates no document")


## 落盘失败时规则候选不能留在内存里，也不能改写主文档。把 pending 路径做成
## 目录即可让暂存写入失败，而不依赖平台权限。
func _test_save_failure() -> void:
	var failure_dir: String = dir.path_join("save-failure")
	DirAccess.make_dir_recursive_absolute(failure_dir)
	var failure_world = World.new()
	var opened: Dictionary = failure_world.open(failure_dir, START, WORLD, ADMIN)
	_expect(bool(opened.get("ok", false)), "The save-failure world opens")
	if not bool(opened.get("ok", false)):
		return
	var event: Dictionary = failure_world.execute(
		FarmCommand.make_set_theft("event_failure", true,
			failure_world.authority_now_utc()), FILER)
	_expect(bool(event.get("ok", false)),
		"The save-failure world records a real authoritative event")
	DirAccess.make_dir_recursive_absolute(
		failure_dir.path_join("disputes.pending.json"))
	var before: String = JSON.stringify(failure_world.disputes)
	var failed: Dictionary = failure_world.execute_dispute("file", FILER, {
		"case_id": "case_1", "against": TARGET, "event_ids": ["event_failure"],
	}, "cmd_save_failure")
	_expect(not bool(failed.get("ok", true))
			and str(failed.get("reason", "")).begins_with("save_disputes_"),
		"A failed save names the storage failure")
	_expect(JSON.stringify(failure_world.disputes) == before,
		"A failed save leaves no half-applied case in memory")
	_expect(not FileAccess.file_exists(failure_dir.path_join("disputes.json")),
		"A failed save does not create the main document")


## 补偿的两个落盘失败路径：disputes 写失败不得动现金；farm 写失败回滚案件。
## 第三组直接构造“disputes 已写、farm 未写”的崩溃现场，验证重启补付一次。
func _test_compensation_save_guards() -> void:
	var dispute_dir: String = dir.path_join("comp-disputes-failure")
	DirAccess.make_dir_recursive_absolute(dispute_dir)
	var dispute_world = World.new()
	_expect(bool(dispute_world.open(dispute_dir, START, WORLD, ADMIN).get("ok", false)),
		"The disputes-failure world opens")
	_expect(_open_account_on(dispute_world, FILER, "df_acct_filer"),
		"The disputes-failure world opens the filer account")
	_expect(_open_account_on(dispute_world, TARGET, "df_acct_target"),
		"The disputes-failure world opens the target account")
	_expect(bool(_make_event_on(dispute_world, "event_df").get("ok", false)),
		"The disputes-failure world records an event")
	_execute_on(dispute_world, "file", FILER, {
		"case_id": "case_df", "against": TARGET, "event_ids": ["event_df"],
	}, "df_file")
	_execute_on(dispute_world, "accept", ADMIN, {"case_id": "case_df"}, "df_accept")
	var filer_before: int = dispute_world.farm.economy_cash(FILER)
	var target_before: int = dispute_world.farm.economy_cash(TARGET)
	var total_before: int = dispute_world.farm.economy_total_cash()
	var farm_before: PackedByteArray = _farm_bytes_at(dispute_dir)
	DirAccess.make_dir_recursive_absolute(dispute_dir.path_join("disputes.pending.json"))
	var failed: Dictionary = _execute_on(dispute_world, "rule", ADMIN, {
		"case_id": "case_df",
		"decision": {"advisor": false, "authority": true,
			"outcome": "compensation", "reason": "保存失败"},
		"amount": 12,
	}, "df_rule")
	_expect(str(failed.get("reason", "")).begins_with("save_disputes_"),
		"A failed dispute save names the storage failure")
	_expect(dispute_world.farm.economy_cash(FILER) == filer_before
			and dispute_world.farm.economy_cash(TARGET) == target_before
			and dispute_world.farm.economy_total_cash() == total_before,
		"A failed dispute save moves no cash")
	_expect(_farm_bytes_at(dispute_dir) == farm_before,
		"A failed dispute save leaves farm.json byte-identical")
	var kept: Dictionary = _case_view(dispute_world.disputes_view(ADMIN), "case_df")
	_expect(str(kept.get("status", "")) == Disputes.STATUS_ACCEPTED,
		"A failed dispute save leaves the case accepted")
	_remove_empty_dir(dispute_dir.path_join("disputes.pending.json"))
	var retried: Dictionary = _execute_on(dispute_world, "rule", ADMIN, {
		"case_id": "case_df",
		"decision": {"advisor": false, "authority": true,
			"outcome": "compensation", "reason": "保存失败"},
		"amount": 12,
	}, "df_rule_retry")
	_expect(bool(retried.get("ok", false)),
		"Retrying after the dispute save failure succeeds")
	_expect(dispute_world.farm.economy_cash(FILER) == filer_before + 12
			and dispute_world.farm.economy_cash(TARGET) == target_before - 12,
		"The retry transfers the compensation exactly once")

	var farm_failure_dir: String = dir.path_join("comp-farm-failure")
	DirAccess.make_dir_recursive_absolute(farm_failure_dir)
	var farm_failure_world = World.new()
	_expect(bool(farm_failure_world.open(farm_failure_dir, START, WORLD, ADMIN).get("ok", false)),
		"The farm-failure world opens")
	_expect(_open_account_on(farm_failure_world, FILER, "ff_acct_filer"),
		"The farm-failure world opens the filer account")
	_expect(_open_account_on(farm_failure_world, TARGET, "ff_acct_target"),
		"The farm-failure world opens the target account")
	_expect(bool(_make_event_on(farm_failure_world, "event_ff").get("ok", false)),
		"The farm-failure world records an event")
	_execute_on(farm_failure_world, "file", FILER, {
		"case_id": "case_ff", "against": TARGET, "event_ids": ["event_ff"],
	}, "ff_file")
	_execute_on(farm_failure_world, "accept", ADMIN, {"case_id": "case_ff"}, "ff_accept")
	var ff_filer: int = farm_failure_world.farm.economy_cash(FILER)
	var ff_target: int = farm_failure_world.farm.economy_cash(TARGET)
	var ff_farm_bytes: PackedByteArray = _farm_bytes_at(farm_failure_dir)
	var ff_dispute_bytes: PackedByteArray = _disputes_bytes_at(farm_failure_dir)
	DirAccess.make_dir_recursive_absolute(farm_failure_dir.path_join("farm.pending.json"))
	var farm_failed: Dictionary = _execute_on(farm_failure_world, "rule", ADMIN, {
		"case_id": "case_ff",
		"decision": {"advisor": false, "authority": true,
			"outcome": "compensation", "reason": "农场保存失败"},
		"amount": 7,
	}, "ff_rule")
	_expect(str(farm_failed.get("reason", "")).begins_with("save_compensation_"),
		"A failed farm save names the compensation storage failure")
	_expect(farm_failure_world.farm.economy_cash(FILER) == ff_filer
			and farm_failure_world.farm.economy_cash(TARGET) == ff_target,
		"A failed farm save leaves in-memory cash untouched")
	_expect(_farm_bytes_at(farm_failure_dir) == ff_farm_bytes,
		"A failed farm save leaves farm.json byte-identical")
	_expect(_disputes_bytes_at(farm_failure_dir) == ff_dispute_bytes,
		"A failed farm save rolls the dispute document back")
	_remove_empty_dir(farm_failure_dir.path_join("farm.pending.json"))
	var farm_retried: Dictionary = _execute_on(farm_failure_world, "rule", ADMIN, {
		"case_id": "case_ff",
		"decision": {"advisor": false, "authority": true,
			"outcome": "compensation", "reason": "农场保存失败"},
		"amount": 7,
	}, "ff_rule_retry")
	_expect(bool(farm_retried.get("ok", false)),
		"Retrying after the farm save failure succeeds")
	_expect(farm_failure_world.farm.economy_cash(FILER) == ff_filer + 7
			and farm_failure_world.farm.economy_cash(TARGET) == ff_target - 7,
		"The farm-save retry transfers the compensation exactly once")

	# 构造上次崩溃留下的持久状态：案件已裁定、补偿记录 paid=false、农场未转账。
	var crash_dir: String = dir.path_join("comp-crash-recovery")
	DirAccess.make_dir_recursive_absolute(crash_dir)
	var crash_world = World.new()
	_expect(bool(crash_world.open(crash_dir, START, WORLD, ADMIN).get("ok", false)),
		"The crash-recovery fixture world opens")
	_expect(_open_account_on(crash_world, FILER, "cr_acct_filer"),
		"The crash fixture opens the filer account")
	_expect(_open_account_on(crash_world, TARGET, "cr_acct_target"),
		"The crash fixture opens the target account")
	_expect(bool(_make_event_on(crash_world, "event_cr").get("ok", false)),
		"The crash fixture records an event")
	_execute_on(crash_world, "file", FILER, {
		"case_id": "case_cr", "against": TARGET, "event_ids": ["event_cr"],
	}, "cr_file")
	_execute_on(crash_world, "accept", ADMIN, {"case_id": "case_cr"}, "cr_accept")
	var crash_at: float = crash_world.authority_now_utc() + 1.0
	var crash_decision: Dictionary = {
		"advisor": false, "authority": true,
		"outcome": "compensation", "reason": "崩溃前已裁定",
	}
	var crash_ruled: Dictionary = Disputes.rule(crash_world.disputes, "case_cr",
		ADMIN, crash_decision, crash_at)
	_expect(bool(crash_ruled.get("ok", false)),
		"The crash fixture builds a valid compensation ruling")
	var crash_store = DisputesStore.new(crash_dir)
	# The fixture writes the pending marker directly instead of going through a
	# world open, so it has to supply the identity `load_state` would have set.
	# `save_state` refuses an empty one, which is what a fresh store has.
	crash_store.world_id = WORLD
	var crash_commands: Array = [{
		"command_id": "cr_rule", "payload": JSON.stringify(["rule", ADMIN, {
			"case_id": "case_cr", "decision": crash_decision, "amount": 20,
		}]),
		"result": {"ok": true, "reason": "", "action": "rule",
			"case_id": "case_cr", "duplicate": false, "status": "ruled"},
	}]
	var crash_enforcement: Dictionary = {
		"case_cr": {"amount": 20, "at_utc": crash_at, "paid": false},
	}
	var crash_saved: Dictionary = crash_store.save_state(crash_ruled.state,
		crash_commands, crash_enforcement)
	_expect(bool(crash_saved.get("ok", false)),
		"The crash fixture persists a pending compensation")
	var crash_filer: int = crash_world.farm.economy_cash(FILER)
	var crash_target: int = crash_world.farm.economy_cash(TARGET)
	var crash_total: int = crash_world.farm.economy_total_cash()

	var recovered = World.new()
	var recovered_open: Dictionary = recovered.open(crash_dir, START + 100.0, WORLD, ADMIN)
	_expect(bool(recovered_open.get("ok", false)),
		"Opening after the interrupted compensation succeeds: %s"
			% str(recovered_open.get("reason", "")))
	_expect(recovered.farm.economy_cash(FILER) == crash_filer + 20
			and recovered.farm.economy_cash(TARGET) == crash_target - 20,
		"The open-time recovery pays the pending compensation once")
	_expect(recovered.farm.economy_total_cash() == crash_total,
		"The recovered compensation conserves total cash")
	var recovered_doc: Dictionary = _disputes_doc_at(crash_dir)
	var recovered_marker: Variant = (recovered_doc.get("enforcement", {}) as Dictionary).get(
		"case_cr", {})
	_expect(recovered_marker is Dictionary and bool(recovered_marker.get("paid", false)),
		"The recovered compensation records a durable paid marker")
	_expect(str(_case_view(recovered.disputes_view(ADMIN), "case_cr").get("status", ""))
			== Disputes.STATUS_RULED,
		"The recovered case keeps its ruling")

	var reopened_again = World.new()
	var reopened_again_open: Dictionary = reopened_again.open(
		crash_dir, START + 200.0, WORLD, ADMIN)
	_expect(bool(reopened_again_open.get("ok", false)),
		"Reopening the recovered world succeeds")
	_expect(reopened_again.farm.economy_cash(FILER) == crash_filer + 20
			and reopened_again.farm.economy_cash(TARGET) == crash_target - 20,
		"Reopening the recovered world does not transfer twice")
	var after_recovery: Dictionary = _execute_on(reopened_again, "rule", ADMIN, {
		"case_id": "case_cr",
		"decision": {"advisor": false, "authority": true,
			"outcome": "compensation", "reason": "恢复后再次裁定"},
		"amount": 20,
	}, "cr_rule_after_recovery")
	_expect(str(after_recovery.get("reason", "")) == "invalid_status",
		"A ruling attempt after recovery is refused")
	_expect(reopened_again.farm.economy_cash(FILER) == crash_filer + 20
			and reopened_again.farm.economy_cash(TARGET) == crash_target - 20,
		"A ruling attempt after recovery moves no cash")


# ------------------------------------------------------------------- helpers

## 用一条真实、已接受且无副作用的 `set_theft` 命令制造权威事件。
func _make_event(event_id: String) -> Dictionary:
	return _make_event_on(world, event_id)


func _make_event_on(target_world, event_id: String) -> Dictionary:
	return target_world.execute(FarmCommand.make_set_theft(event_id, true,
		target_world.authority_now_utc()), FILER)


func _open_account(actor: String, command_id: String) -> bool:
	return _open_account_on(world, actor, command_id)


func _open_account_on(target_world, actor: String, command_id: String) -> bool:
	var result: Dictionary = target_world.execute(
		FarmCommand.make_account_open(command_id, target_world.authority_now_utc()), actor)
	return bool(result.get("ok", false))


func _execute_on(target_world, action: String, actor: String, args: Dictionary,
		command_id: String) -> Dictionary:
	return target_world.execute_dispute(action, actor, args, command_id)


func _ledger_entry(event_id: String) -> Dictionary:
	for entry_value: Variant in world.farm.economy_ledger_entries():
		if entry_value is Dictionary \
				and str((entry_value as Dictionary).get("event_id", "")) == event_id:
			return entry_value
	return {}


func _line_matches(lines: Array, account: String, debit: int, credit: int) -> bool:
	for line_value: Variant in lines:
		if line_value is Dictionary \
				and str((line_value as Dictionary).get("account", "")) == account \
				and int((line_value as Dictionary).get("debit", 0)) == debit \
				and int((line_value as Dictionary).get("credit", 0)) == credit:
			return true
	return false


func _farm_bytes() -> PackedByteArray:
	return _farm_bytes_at(world_dir)


func _farm_bytes_at(directory: String) -> PackedByteArray:
	var path: String = directory.path_join("farm.json")
	return FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) \
		else PackedByteArray()


func _disputes_bytes_at(directory: String) -> PackedByteArray:
	var path: String = directory.path_join("disputes.json")
	return FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) \
		else PackedByteArray()


func _disputes_doc_at(directory: String) -> Dictionary:
	var path: String = directory.path_join("disputes.json")
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _remove_empty_dir(path: String) -> void:
	var parent: DirAccess = DirAccess.open(path.get_base_dir())
	if parent != null:
		parent.remove(path.get_file())


func _audit_actions(case_row: Dictionary) -> Array:
	var actions: Array = []
	var audit_value: Variant = case_row.get("audit")
	if audit_value is Array:
		for row_value: Variant in audit_value:
			if row_value is Dictionary:
				actions.append(str((row_value as Dictionary).get("action", "")))
	return actions


func _disputes_path() -> String:
	return world_dir.path_join("disputes.json")


func _disputes_doc() -> Dictionary:
	if not FileAccess.file_exists(_disputes_path()):
		return {}
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(_disputes_path()))
	return parsed if parsed is Dictionary else {}


func _disputes_bytes() -> PackedByteArray:
	return FileAccess.get_file_as_bytes(_disputes_path()) \
		if FileAccess.file_exists(_disputes_path()) else PackedByteArray()


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("DISPUTE_AUTHORITY_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
