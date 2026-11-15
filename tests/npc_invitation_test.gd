extends SceneTree
## M10-04 NPC 邀约拒绝规则。无头、隔离：不读真实时钟，不接模型/网络/主循环，
## 也不触碰农场存档、账户、财产、权属或真实拜访/赠礼。

const Inv = preload("res://npc/npc_invitation.gd")

const START: float = 1800000000.0
const LIN: String = "npc_lin_shen"
const XU: String = "npc_xu_bo"
const ZHOU: String = "npc_a_zhou"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_empty_and_valid()
	_test_json_roundtrip()
	_test_propose_and_determinism()
	_test_duplicate_pending()
	_test_propose_rejections()
	_test_accept_and_decline()
	_test_permission_rejections()
	_test_withdraw()
	_test_expiry_decisions()
	_test_expire_batch()
	_test_decision_validation()
	_test_capacity_and_limits()
	_test_strict_valid()
	_test_copy_on_write()
	_test_narrative_not_authority()
	for failure: String in failures:
		push_error(failure)
	print("NPC_INVITATION_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_empty_and_valid() -> void:
	var empty: Dictionary = Inv.empty_document()
	_expect(Inv.valid(empty), "空文档合法")
	_expect((empty.invitations as Dictionary).is_empty(), "空文档没有邀约")
	_expect(not Inv.valid(null), "null 文档被拒绝")
	_expect(not Inv.valid([]), "数组文档被拒绝")
	_expect(not Inv.valid({}), "空字典被拒绝")
	_expect(not Inv.valid({"invitations": []}), "invitations 不是字典被拒绝")
	var unknown_root: Dictionary = Inv.empty_document()
	unknown_root.extra = 1
	_expect(not Inv.valid(unknown_root), "未知根键被拒绝")


func _test_json_roundtrip() -> void:
	var empty_text: String = JSON.stringify(Inv.empty_document())
	var empty_parsed: Variant = JSON.parse_string(empty_text)
	_expect(empty_parsed is Dictionary and Inv.valid(empty_parsed),
		"空文档 JSON 往返合法")
	_expect(JSON.stringify(_empty_document_text()) == empty_text,
		"空文档 JSON 输出稳定")

	var proposed: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_VISIT, START)
	_expect(proposed.ok, "JSON 夹具的邀约被接受")
	var invitation_id: String = str(proposed.invitation.id)
	var accepted: Dictionary = Inv.accept(
		proposed.document, invitation_id, XU, START + 10.0)
	_expect(accepted.ok, "JSON 夹具的邀约被接受为 accepted")
	var text: String = JSON.stringify(accepted.document)
	var parsed: Variant = JSON.parse_string(text)
	_expect(parsed is Dictionary, "JSON 解析得到字典")
	_expect(Inv.valid(parsed), "解析后的文档仍然合法")
	Inv.normalize(parsed)
	_expect(JSON.stringify(parsed) == text, "归一后 JSON 与写入时一致")
	_expect(str(parsed.invitations[invitation_id].status) == Inv.STATUS_ACCEPTED,
		"JSON 往返保留状态")
	_expect(float(parsed.invitations[invitation_id].decided_utc) == START + 10.0,
		"JSON 往返保留决策时刻")


func _test_propose_and_determinism() -> void:
	var first: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_VISIT, START)
	_expect(first.ok and str(first.reason).is_empty(), "合法提议成功")
	var row: Dictionary = first.invitation
	_expect(str(row.from) == LIN, "邀约发起者正确")
	_expect(str(row.to) == XU, "邀约收件人正确")
	_expect(str(row.kind) == Inv.KIND_VISIT, "邀约种类正确")
	_expect(str(row.status) == Inv.STATUS_PENDING, "新邀约为 pending")
	_expect(float(row.created_utc) == START, "创建时刻取显式 now_utc")
	_expect(float(row.expires_utc) == START + float(Inv.TTL_SECONDS[Inv.KIND_VISIT]),
		"过期时刻取固定 TTL")
	_expect(str(row.id).begins_with("inv_"), "邀约 id 使用固定前缀")
	_expect(str(row.id) == Inv._invitation_id(LIN, XU, Inv.KIND_VISIT,
		float(row.expires_utc)), "邀约 id 由 from/to/kind/expires 派生")
	_expect(Inv.valid(first.document), "提议后的候选文档合法")

	var second: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_VISIT, START)
	_expect(str(first.invitation.id) == str(second.invitation.id),
		"同输入同 now 得到同 id")
	_expect(JSON.stringify(first.document) == JSON.stringify(second.document),
		"同输入同 now 得到同文档")

	var later: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_VISIT, START + 1.0)
	_expect(str(first.invitation.id) != str(later.invitation.id),
		"不同 now 得到不同 id")

	var validated: Dictionary = Inv.validate_proposal(
		Inv.empty_document(), _request(LIN, XU, Inv.KIND_VISIT), START)
	_expect(validated.ok, "validate_proposal 接受合法提议")
	_expect(not validated.has("document"), "validate_proposal 不写文档")
	_expect(str(validated.invitation.id) == str(first.invitation.id),
		"validate_proposal 与 propose 派生同一 id")

	var base: Dictionary = _propose(Inv.empty_document(), ZHOU, LIN,
		Inv.KIND_MEAL, START).document
	var base_id: String = str(base.invitations.keys()[0])
	var decided: Dictionary = Inv.accept(base, base_id, LIN, START + 1.0)
	_expect(decided.ok, "无关邀约可先被接受")
	var after: Dictionary = _propose(decided.document, LIN, XU,
		Inv.KIND_VISIT, START)
	_expect(after.ok and str(after.invitation.id) == str(first.invitation.id),
		"无关邀约不影响新邀约 id")


func _test_duplicate_pending() -> void:
	var document: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_VISIT, START).document
	var same_now: Dictionary = _propose(document, LIN, XU, Inv.KIND_VISIT, START)
	_expect(not same_now.ok and str(same_now.reason) == "already_pending",
		"同一时刻重复提议返回 already_pending")
	var later: Dictionary = _propose(document, LIN, XU, Inv.KIND_VISIT, START + 1.0)
	_expect(not later.ok and str(later.reason) == "already_pending",
		"pending 期间不同时刻重复提议返回 already_pending")
	_expect(not later.has("document"), "重复 pending 失败不带文档")

	var other_kind: Dictionary = _propose(document, LIN, XU, Inv.KIND_MEAL, START)
	_expect(other_kind.ok, "同一对居民可同时持有不同种类 pending 邀约")

	var reverse: Dictionary = _propose(document, XU, LIN, Inv.KIND_VISIT, START)
	_expect(reverse.ok, "反向邀约不被视为重复")

	var invitation_id: String = str(document.invitations.keys()[0])
	var accepted: Dictionary = Inv.accept(document, invitation_id, XU, START + 10.0)
	_expect(accepted.ok, "重复 id 夹具邀约被接受")
	var replay: Dictionary = _propose(accepted.document, LIN, XU,
		Inv.KIND_VISIT, START)
	_expect(not replay.ok and str(replay.reason) == "duplicate_id",
		"同一派生 id 的非 pending 重放返回 duplicate_id")

	var later_again: Dictionary = _propose(accepted.document, LIN, XU,
		Inv.KIND_VISIT, START + 20.0)
	_expect(later_again.ok, "决策后不同有效期可再次提议")


func _test_propose_rejections() -> void:
	var empty: Dictionary = Inv.empty_document()
	_expect(str(_propose(empty, LIN, XU, Inv.KIND_VISIT, -1.0).reason)
		== "invalid_time", "非法提议时刻被拒绝")
	_expect(str(Inv.propose({"invitations": []}, _request(LIN, XU, Inv.KIND_VISIT),
		START).reason) == "invalid_document", "非法文档不得写入")
	_expect(str(Inv.propose(empty, null, START).reason) == "invalid_request",
		"null 请求被拒绝")
	_expect(str(Inv.propose(empty, {"from": LIN, "to": XU}, START).reason)
		== "invalid_request", "缺少种类被拒绝")
	var extra: Dictionary = _request(LIN, XU, Inv.KIND_VISIT)
	extra.note = "自由文本"
	_expect(str(Inv.propose(empty, extra, START).reason) == "invalid_request",
		"请求额外键被拒绝")
	_expect(str(Inv.propose(empty, _request("", XU, Inv.KIND_VISIT), START).reason)
		== "invalid_from", "非法发起者被拒绝")
	_expect(str(Inv.propose(empty, _request(LIN, "not a valid id", Inv.KIND_VISIT),
		START).reason) == "invalid_to", "非法收件人被拒绝")
	_expect(str(Inv.propose(empty, _request(LIN, LIN, Inv.KIND_VISIT), START).reason)
		== "invalid_target", "自己邀请自己被拒绝")
	_expect(str(Inv.propose(empty, _request(LIN, XU, "party"), START).reason)
		== "invalid_kind", "目录外种类被拒绝")
	var failure: Dictionary = _propose(empty, LIN, XU, "party", START)
	_expect(not failure.has("document"), "提议失败不带候选文档")


func _test_accept_and_decline() -> void:
	var proposed: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_MEAL, START)
	var document: Dictionary = proposed.document
	var invitation_id: String = str(proposed.invitation.id)
	var before: String = JSON.stringify(document)

	var accepted: Dictionary = Inv.accept(document, invitation_id, XU, START + 5.0)
	_expect(accepted.ok and str(accepted.reason).is_empty(), "收件人可以接受")
	var accepted_row: Dictionary = accepted.document.invitations[invitation_id]
	_expect(str(accepted_row.status) == Inv.STATUS_ACCEPTED, "接受后状态为 accepted")
	_expect(float(accepted_row.decided_utc) == START + 5.0, "记录接受时刻")
	_expect(str(accepted_row.reason) == Inv.STATUS_ACCEPTED, "接受原因固定为状态")
	_expect(Inv.valid(accepted.document), "接受后的候选文档合法")
	_expect(JSON.stringify(document) == before, "accept 不修改输入")

	var declined_base: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_TRADE_TALK, START)
	var declined: Dictionary = Inv.decline(declined_base.document,
		str(declined_base.invitation.id), XU, START + 7.0)
	_expect(declined.ok, "收件人可以拒绝")
	var declined_row: Dictionary = declined.document.invitations[
		str(declined_base.invitation.id)]
	_expect(str(declined_row.status) == Inv.STATUS_DECLINED, "拒绝后状态为 declined")
	_expect(float(declined_row.decided_utc) == START + 7.0, "记录拒绝时刻")
	_expect(str(declined_row.reason) == Inv.STATUS_DECLINED, "拒绝原因固定为状态")
	_expect(Inv.valid(declined.document), "拒绝后的候选文档合法")

	var second_accept: Dictionary = Inv.accept(
		accepted.document, invitation_id, XU, START + 10.0)
	_expect(not second_accept.ok and str(second_accept.reason) == "not_pending",
		"接受后不能再次接受")
	var decline_after_accept: Dictionary = Inv.decline(
		accepted.document, invitation_id, XU, START + 10.0)
	_expect(not decline_after_accept.ok
		and str(decline_after_accept.reason) == "not_pending",
		"接受后不能再拒绝")
	var withdraw_after_accept: Dictionary = Inv.withdraw(
		accepted.document, invitation_id, LIN, START + 10.0)
	_expect(not withdraw_after_accept.ok
		and str(withdraw_after_accept.reason) == "not_pending",
		"接受后不能再撤回")
	var decline_after_decline: Dictionary = Inv.decline(
		declined.document, str(declined_base.invitation.id), XU, START + 10.0)
	_expect(not decline_after_decline.ok
		and str(decline_after_decline.reason) == "not_pending",
		"拒绝后不能再次拒绝")
	_expect(not second_accept.has("document") and not decline_after_accept.has("document"),
		"非 pending 决策失败不带文档")

	_expect(accepted.document.has("invitations")
		and accepted.document.size() == 1, "接受结果只有邀约根键")
	_expect(not accepted.document.has("ownership")
		and not accepted.document.has("accounts")
		and not accepted.document.has("authority"),
		"接受不产生权属/账户/授权字段")


func _test_permission_rejections() -> void:
	var document: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_VISIT, START).document
	var invitation_id: String = str(document.invitations.keys()[0])

	var sender_accept: Dictionary = Inv.accept(document, invitation_id, LIN, START + 1.0)
	_expect(not sender_accept.ok and str(sender_accept.reason) == "not_recipient",
		"发起人不能代替收件人接受")
	var sender_decline: Dictionary = Inv.decline(document, invitation_id, LIN, START + 1.0)
	_expect(not sender_decline.ok and str(sender_decline.reason) == "not_recipient",
		"发起人不能代替收件人拒绝")
	var third_accept: Dictionary = Inv.accept(document, invitation_id, ZHOU, START + 1.0)
	_expect(not third_accept.ok and str(third_accept.reason) == "not_recipient",
		"第三方不能接受")
	var third_decline: Dictionary = Inv.decline(document, invitation_id, ZHOU, START + 1.0)
	_expect(not third_decline.ok and str(third_decline.reason) == "not_recipient",
		"第三方不能拒绝")
	var non_string_actor: Dictionary = Inv.accept(document, invitation_id, 42, START + 1.0)
	_expect(not non_string_actor.ok and str(non_string_actor.reason) == "not_recipient",
		"非字符串决策人不被接受")
	var recipient_withdraw: Dictionary = Inv.withdraw(
		document, invitation_id, XU, START + 1.0)
	_expect(not recipient_withdraw.ok and str(recipient_withdraw.reason) == "not_initiator",
		"收件人不能撤回")
	_expect(not sender_accept.has("document") and not third_decline.has("document"),
		"权限拒绝不带候选文档")


func _test_withdraw() -> void:
	var proposed: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_MEAL, START)
	var document: Dictionary = proposed.document
	var invitation_id: String = str(proposed.invitation.id)
	var before: String = JSON.stringify(document)
	var withdrawn: Dictionary = Inv.withdraw(document, invitation_id, LIN, START + 3.0)
	_expect(withdrawn.ok, "发起人可以撤回 pending 邀约")
	var row: Dictionary = withdrawn.document.invitations[invitation_id]
	_expect(str(row.status) == Inv.STATUS_WITHDRAWN, "撤回后状态为 withdrawn")
	_expect(float(row.decided_utc) == START + 3.0, "记录撤回时刻")
	_expect(str(row.reason) == Inv.STATUS_WITHDRAWN, "撤回原因固定为状态")
	_expect(Inv.valid(withdrawn.document), "撤回后的候选文档合法")
	_expect(JSON.stringify(document) == before, "withdraw 不修改输入")
	var again: Dictionary = Inv.withdraw(
		withdrawn.document, invitation_id, LIN, START + 4.0)
	_expect(not again.ok and str(again.reason) == "not_pending",
		"撤回后不能再次撤回")
	var accept_withdrawn: Dictionary = Inv.accept(
		withdrawn.document, invitation_id, XU, START + 4.0)
	_expect(not accept_withdrawn.ok
		and str(accept_withdrawn.reason) == "not_pending",
		"已撤回的邀约不能被接受")


func _test_expiry_decisions() -> void:
	var before_expiry: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_TRADE_TALK, START)
	var expires: float = float(before_expiry.invitation.expires_utc)
	var accepted: Dictionary = Inv.accept(before_expiry.document,
		str(before_expiry.invitation.id), XU, expires - 1.0)
	_expect(accepted.ok, "过期前一秒仍可接受")

	var at_expiry: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_TRADE_TALK, START)
	var at_id: String = str(at_expiry.invitation.id)
	var input_before: String = JSON.stringify(at_expiry.document)
	var expired_accept: Dictionary = Inv.accept(
		at_expiry.document, at_id, XU, expires)
	_expect(not expired_accept.ok and str(expired_accept.reason) == "expired",
		"到达过期时刻接受返回 expired")
	_expect(expired_accept.has("document"), "过期决策附带转 expired 的候选文档")
	_expect(JSON.stringify(at_expiry.document) == input_before,
		"过期决策不修改输入")
	var expired_row: Dictionary = expired_accept.document.invitations[at_id]
	_expect(str(expired_row.status) == Inv.STATUS_EXPIRED, "过期决策把邀约转为 expired")
	_expect(float(expired_row.decided_utc) == expires, "过期决策时刻夹在 expires_utc")
	_expect(str(expired_row.reason) == Inv.STATUS_EXPIRED, "过期原因为 expired")
	_expect(Inv.valid(expired_accept.document), "过期决策候选文档合法")
	var after_expired: Dictionary = Inv.accept(
		expired_accept.document, at_id, XU, expires + 1.0)
	_expect(not after_expired.ok and str(after_expired.reason) == "not_pending",
		"已过期邀约不能再次决策")

	var decline_expired: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_MEAL, START)
	var decline_expires: float = float(decline_expired.invitation.expires_utc)
	var declined: Dictionary = Inv.decline(decline_expired.document,
		str(decline_expired.invitation.id), XU, decline_expires + 1.0)
	_expect(not declined.ok and str(declined.reason) == "expired",
		"过期后拒绝返回 expired")
	_expect(str(declined.document.invitations[
		str(decline_expired.invitation.id)].status) == Inv.STATUS_EXPIRED,
		"过期后拒绝同样转为 expired")

	var withdraw_expired: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_VISIT, START)
	var withdraw_expires: float = float(withdraw_expired.invitation.expires_utc)
	var withdrawn: Dictionary = Inv.withdraw(withdraw_expired.document,
		str(withdraw_expired.invitation.id), LIN, withdraw_expires + 1.0)
	_expect(not withdrawn.ok and str(withdrawn.reason) == "expired",
		"过期后撤回返回 expired")
	_expect(str(withdrawn.document.invitations[
		str(withdraw_expired.invitation.id)].status) == Inv.STATUS_EXPIRED,
		"过期后撤回同样转为 expired")


func _test_expire_batch() -> void:
	var document: Dictionary = Inv.empty_document()
	var meal: Dictionary = _propose(document, LIN, XU, Inv.KIND_MEAL, START)
	document = meal.document
	var talk: Dictionary = _propose(document, LIN, XU, Inv.KIND_TRADE_TALK, START)
	document = talk.document
	var visit: Dictionary = _propose(document, LIN, XU, Inv.KIND_VISIT, START)
	document = visit.document
	var before: String = JSON.stringify(document)

	var early: Dictionary = Inv.expire(document, START + 1000.0)
	_expect(early.ok and int(early.expired) == 1, "只过期已到期的 trade_talk")
	_expect(str(early.document.invitations[str(talk.invitation.id)].status)
		== Inv.STATUS_EXPIRED, "trade_talk 转为 expired")
	_expect(str(early.document.invitations[str(meal.invitation.id)].status)
		== Inv.STATUS_PENDING, "meal 仍在 pending")
	_expect(str(early.document.invitations[str(visit.invitation.id)].status)
		== Inv.STATUS_PENDING, "visit 仍在 pending")
	_expect(JSON.stringify(document) == before, "expire 不修改输入")

	var middle: Dictionary = Inv.expire(early.document, START + 2000.0)
	_expect(int(middle.expired) == 1, "第二次批量只新过期 meal")
	_expect(str(middle.document.invitations[str(meal.invitation.id)].status)
		== Inv.STATUS_EXPIRED, "meal 转为 expired")

	var late: Dictionary = Inv.expire(middle.document, START + 3600.0)
	_expect(int(late.expired) == 1, "到期边界时刻 visit 转为 expired")
	_expect(str(late.document.invitations[str(visit.invitation.id)].status)
		== Inv.STATUS_EXPIRED, "visit 转为 expired")

	var repeat_text: String = JSON.stringify(late.document)
	var repeat: Dictionary = Inv.expire(late.document, START + 3600.0)
	_expect(repeat.ok and int(repeat.expired) == 0, "重复 expire 不重复计数")
	_expect(JSON.stringify(repeat.document) == repeat_text,
		"重复 expire 不改变文档")

	var empty: Dictionary = Inv.expire(Inv.empty_document(), START)
	_expect(empty.ok and int(empty.expired) == 0, "空文档 expire 合法且计数为零")
	_expect(not Inv.expire(Inv.empty_document(), -1.0).has("document"),
		"非法时刻 expire 不带文档")
	_expect(str(Inv.expire({"invitations": []}, START).reason) == "invalid_document",
		"非法文档 expire 被拒绝")


func _test_decision_validation() -> void:
	var proposed: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_VISIT, START)
	var document: Dictionary = proposed.document
	var invitation_id: String = str(proposed.invitation.id)
	var approved: Dictionary = Inv.validate_decision(
		document, invitation_id, XU, Inv.DECISION_ACCEPT, START + 1.0)
	_expect(approved.ok and not approved.has("document"),
		"决策前复校验接受合法决策且不写文档")
	_expect(str(approved.invitation.id) == invitation_id,
		"复校验返回对应邀约")

	_expect(str(Inv.validate_decision(document, invitation_id, XU, "ignore",
		START).reason) == "invalid_decision", "未知决策种类被拒绝")
	_expect(str(Inv.validate_decision(document, "", XU, Inv.DECISION_ACCEPT,
		START).reason) == "invalid_invitation_id", "空邀约 id 被拒绝")
	_expect(str(Inv.validate_decision(document, 7, XU, Inv.DECISION_ACCEPT,
		START).reason) == "invalid_invitation_id", "非字符串邀约 id 被拒绝")
	_expect(str(Inv.validate_decision(document, "inv_missing", XU,
		Inv.DECISION_ACCEPT, START).reason) == "unknown_invitation",
		"未知邀约被拒绝")
	_expect(str(Inv.validate_decision(document, invitation_id, XU,
		Inv.DECISION_ACCEPT, -1.0).reason) == "invalid_time",
		"非法决策时刻被拒绝")
	_expect(str(Inv.validate_decision({"invitations": []}, invitation_id, XU,
		Inv.DECISION_ACCEPT, START).reason) == "invalid_document",
		"非法文档的决策被拒绝")
	_expect(str(Inv.validate_decision(document, invitation_id, XU,
		Inv.DECISION_ACCEPT, START + float(Inv.TTL_SECONDS[Inv.KIND_VISIT])).reason)
		== "expired", "过期 pending 的复校验返回 expired")


func _test_capacity_and_limits() -> void:
	var full: Dictionary = _pending_document(Inv.MAX_INVITATIONS)
	_expect(Inv.valid(full), "达到邀约上限的文档合法")
	var over: Dictionary = _propose(full, "npc_extra", "npc_to",
		Inv.KIND_VISIT, START)
	_expect(not over.ok and str(over.reason) == "over_capacity",
		"新增邀约超过上限被拒绝")
	_expect(not over.has("document"), "超限失败不带文档")

	var too_many: Dictionary = _pending_document(Inv.MAX_INVITATIONS + 1)
	_expect(not Inv.valid(too_many), "超过邀约数上限被拒绝")


func _test_strict_valid() -> void:
	var proposed: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_VISIT, START)
	var document: Dictionary = proposed.document
	var invitation_id: String = str(proposed.invitation.id)

	var row_extra: Dictionary = document.duplicate(true)
	row_extra.invitations[invitation_id].extra = 1
	_expect(not Inv.valid(row_extra), "邀约行未知键被拒绝")

	var missing_field: Dictionary = document.duplicate(true)
	missing_field.invitations[invitation_id].erase("kind")
	_expect(not Inv.valid(missing_field), "邀约行缺少字段被拒绝")

	var pending_decided: Dictionary = document.duplicate(true)
	pending_decided.invitations[invitation_id].decided_utc = START
	_expect(not Inv.valid(pending_decided), "pending 行携带 decided_utc 被拒绝")

	var accepted: Dictionary = Inv.accept(document, invitation_id, XU, START + 1.0)
	var accepted_document: Dictionary = accepted.document
	var missing_reason: Dictionary = accepted_document.duplicate(true)
	missing_reason.invitations[invitation_id].erase("reason")
	_expect(not Inv.valid(missing_reason), "非 pending 行缺少 reason 被拒绝")

	var missing_decided: Dictionary = accepted_document.duplicate(true)
	missing_decided.invitations[invitation_id].erase("decided_utc")
	_expect(not Inv.valid(missing_decided), "非 pending 行缺少 decided_utc 被拒绝")

	var bad_status: Dictionary = document.duplicate(true)
	bad_status.invitations[invitation_id].status = "maybe"
	_expect(not Inv.valid(bad_status), "未知状态被拒绝")

	var bad_reason: Dictionary = accepted_document.duplicate(true)
	bad_reason.invitations[invitation_id].reason = "declined"
	_expect(not Inv.valid(bad_reason), "reason 与状态不一致被拒绝")

	var non_string_reason: Dictionary = accepted_document.duplicate(true)
	non_string_reason.invitations[invitation_id].reason = 1
	_expect(not Inv.valid(non_string_reason), "非字符串 reason 被拒绝")

	var zero_duration: Dictionary = document.duplicate(true)
	zero_duration.invitations[invitation_id].expires_utc = START
	_expect(not Inv.valid(zero_duration), "expires 必须晚于 created")

	var inverted_duration: Dictionary = document.duplicate(true)
	inverted_duration.invitations[invitation_id].expires_utc = START - 1.0
	_expect(not Inv.valid(inverted_duration), "expires 早于 created 被拒绝")

	var decided_before: Dictionary = accepted_document.duplicate(true)
	decided_before.invitations[invitation_id].decided_utc = START - 1.0
	_expect(not Inv.valid(decided_before), "decided 早于 created 被拒绝")

	var decided_after: Dictionary = accepted_document.duplicate(true)
	decided_after.invitations[invitation_id].decided_utc = \
		float(document.invitations[invitation_id].expires_utc) + 1.0
	_expect(not Inv.valid(decided_after), "decided 晚于 expires 被拒绝")

	var self_invite: Dictionary = document.duplicate(true)
	var self_row: Dictionary = self_invite.invitations[invitation_id]
	self_row.to = LIN
	_expect(not Inv.valid(self_invite), "from 与 to 相同被拒绝")

	var unknown_kind: Dictionary = document.duplicate(true)
	unknown_kind.invitations[invitation_id].kind = "party"
	_expect(not Inv.valid(unknown_kind), "未知邀约种类被拒绝")

	var key_mismatch: Dictionary = document.duplicate(true)
	var stored_row: Dictionary = key_mismatch.invitations[invitation_id]
	key_mismatch.invitations.erase(invitation_id)
	key_mismatch.invitations["inv_fake"] = stored_row
	_expect(not Inv.valid(key_mismatch), "行 id 与字典键不一致被拒绝")

	var forged_id: Dictionary = document.duplicate(true)
	var forged_row: Dictionary = forged_id.invitations[invitation_id]
	forged_id.invitations.erase(invitation_id)
	forged_row.id = "inv_0"
	forged_id.invitations["inv_0"] = forged_row
	_expect(not Inv.valid(forged_id), "自造 id 未通过确定性派生被拒绝")

	var non_string_key: Dictionary = {"invitations": {}}
	non_string_key.invitations[5] = stored_row
	_expect(not Inv.valid(non_string_key), "非字符串邀约键被拒绝")

	var long_key: Dictionary = {"invitations": {}}
	long_key.invitations["x".repeat(Inv.MAX_INVITATION_ID_LENGTH + 1)] = stored_row
	_expect(not Inv.valid(long_key), "超长邀约 id 被拒绝")

	var missing_invitations: Dictionary = {"other": {}}
	_expect(not Inv.valid(missing_invitations), "缺少 invitations 根键被拒绝")


func _test_copy_on_write() -> void:
	var proposed: Dictionary = _propose(Inv.empty_document(), LIN, XU,
		Inv.KIND_MEAL, START)
	var document: Dictionary = proposed.document
	var invitation_id: String = str(proposed.invitation.id)
	var before: String = JSON.stringify(document)

	var accepted: Dictionary = Inv.accept(document, invitation_id, XU, START + 10.0)
	_expect(accepted.ok, "写时复制夹具接受成功")
	_expect(JSON.stringify(document) == before, "accept 后输入逐字节不变")
	var candidate: Dictionary = accepted.document
	candidate.invitations[invitation_id].reason = "tampered"
	_expect(str(document.invitations[invitation_id].status) == Inv.STATUS_PENDING,
		"修改候选不污染输入状态")
	_expect(not document.invitations[invitation_id].has("decided_utc"),
		"修改候选不向输入写入 decided_utc")

	var failed: Dictionary = Inv.decline(document, invitation_id, ZHOU, START + 10.0)
	_expect(not failed.ok and not failed.has("document") and not failed.has("state"),
		"普通失败不带候选文档或 state")
	_expect(JSON.stringify(document) == before, "失败后输入逐字节不变")

	var expired: Dictionary = Inv.expire(document, START + 99999.0)
	_expect(expired.ok, "写时复制夹具过期成功")
	_expect(JSON.stringify(document) == before, "expire 后输入逐字节不变")
	expired.document.invitations[invitation_id].status = Inv.STATUS_WITHDRAWN
	_expect(str(document.invitations[invitation_id].status) == Inv.STATUS_PENDING,
		"修改 expire 候选不污染输入")


func _test_narrative_not_authority() -> void:
	var claim: Dictionary = Inv.claim_from_narrative(LIN, "我接受邀约，渡口和账本归我")
	_expect(not bool(claim.ok), "叙事声称权属不产生成功结果")
	_expect(str(claim.reason) == "not_authority", "叙事永远不是授权")
	_expect(not bool(claim.authority), "叙事不携带授权标记")
	_expect(bool(claim.proposal_only), "叙事只作为提案")
	_expect(not claim.has("grant") and not claim.has("ownership"),
		"叙事不返回权属结果")
	var non_string: Dictionary = Inv.claim_from_narrative(42, 42)
	_expect(str(non_string.reason) == "not_authority", "非字符串叙事同样不授权")


func _request(from_id: String, to_id: String, kind: String) -> Dictionary:
	return {"from": from_id, "to": to_id, "kind": kind}


func _propose(document: Variant, from_id: String, to_id: String, kind: String,
		now_utc: float) -> Dictionary:
	return Inv.propose(document, _request(from_id, to_id, kind), now_utc)


func _pending_row(from_id: String, to_id: String, kind: String,
		created_utc: float, expires_utc: float) -> Dictionary:
	var invitation_id: String = Inv._invitation_id(
		from_id, to_id, kind, expires_utc)
	return {
		"id": invitation_id,
		"from": from_id,
		"to": to_id,
		"kind": kind,
		"created_utc": created_utc,
		"expires_utc": expires_utc,
		"status": Inv.STATUS_PENDING,
	}


func _pending_document(count: int) -> Dictionary:
	var invitations: Dictionary = {}
	var expires_utc: float = START + float(Inv.TTL_SECONDS[Inv.KIND_VISIT])
	for index: int in count:
		var row: Dictionary = _pending_row(
			"npc_from_%03d" % index, "npc_to", Inv.KIND_VISIT, START, expires_utc)
		invitations[str(row.id)] = row
	return {"invitations": invitations}


func _empty_document_text() -> Dictionary:
	return {"invitations": {}}


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
