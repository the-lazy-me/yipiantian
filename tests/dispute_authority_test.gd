extends SceneTree
## M12-04 执法闭环接入世界权威：HeadlessWorld 直接驱动 disputes.json，不经过
## 网络。覆盖缺失文档初始化、立案/证据/申诉、非管理员拒绝、受理→裁定→申诉→
## 更正→结案的历史保留、AI 建议零变化、恶意/空证据与非法事件 id、同命令重放、
## 换参数冲突、保存失败不留半状态、按身份过滤的视图，以及重启后的持久化与重放。
##
## 所有写入通过权威时钟；测试只从返回结果和落盘文档取证据。

const World = preload("res://world/headless_world.gd")
const Disputes = preload("res://world/dispute_state.gd")

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
	_test_views()
	_test_restart()
	_test_store_guards()
	_test_save_failure()
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


## 视图按连接身份过滤：管理员看全部，当事人与证据提交人看相关案件，无身份连接
## 只看公开状态行。
func _test_views() -> void:
	var second: Dictionary = _execute("file", OUTSIDER, {
		"case_id": "case_2", "against": TARGET, "event_ids": ["event_delta"],
	}, "cmd_file_2")
	_expect(bool(second.get("ok", false)),
		"A second case from another member is accepted")

	var admin_view: Dictionary = world.disputes_view(ADMIN)
	_expect((admin_view.get("cases", []) as Array).size() == 2
			and (admin_view.get("public", []) as Array).size() == 2,
		"An administrator sees every case and every public row")
	_expect(_public_row(admin_view, "case_1").size() > 0,
		"The public rows carry both cases")
	_expect(not _public_row(admin_view, "case_1").has("evidence"),
		"Public rows do not leak evidence details")

	var filer_view: Dictionary = world.disputes_view(FILER)
	_expect((filer_view.get("cases", []) as Array).size() == 1
			and not _case_view(filer_view, "case_1").is_empty(),
		"A party sees only the case it filed")
	_expect((filer_view.get("public", []) as Array).size() == 2,
		"A party still sees the public status of every case")
	var target_view: Dictionary = world.disputes_view(TARGET)
	_expect((target_view.get("cases", []) as Array).size() == 2,
		"The target of both cases sees both cases")
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
			and (unrelated_view.get("public", []) as Array).size() == 2,
		"An unrelated member sees only public status rows")
	var anonymous_view: Dictionary = world.disputes_view("")
	_expect((anonymous_view.get("cases", []) as Array).is_empty()
			and (anonymous_view.get("public", []) as Array).size() == 2,
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
	DirAccess.make_dir_recursive_absolute(
		failure_dir.path_join("disputes.pending.json"))
	var before: String = JSON.stringify(failure_world.disputes)
	var failed: Dictionary = failure_world.execute_dispute("file", FILER, {
		"case_id": "case_1", "against": TARGET, "event_ids": ["event_alpha"],
	}, "cmd_save_failure")
	_expect(not bool(failed.get("ok", true))
			and str(failed.get("reason", "")).begins_with("save_disputes_"),
		"A failed save names the storage failure")
	_expect(JSON.stringify(failure_world.disputes) == before,
		"A failed save leaves no half-applied case in memory")
	_expect(not FileAccess.file_exists(failure_dir.path_join("disputes.json")),
		"A failed save does not create the main document")


# ------------------------------------------------------------------- helpers

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
