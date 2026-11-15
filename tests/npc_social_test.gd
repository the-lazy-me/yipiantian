extends SceneTree
## M10-04 居民自发社交。无头、隔离：不读真实时钟，不接模型/网络/主循环，
## 也不触碰农场存档、账户、权属或真实赠礼。

const Social = preload("res://npc/npc_social.gd")

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
	_test_plan_selection()
	_test_plan_determinism()
	_test_plan_cooldowns_and_nothing()
	_test_validate_rejections()
	_test_affinity_bounds()
	_test_capacity_and_gift_caps()
	_test_apply_and_duplicate()
	_test_copy_on_write()
	_test_strict_valid()
	_test_context_rejections()
	_test_narrative_not_authority()
	for failure: String in failures:
		push_error(failure)
	print("NPC_SOCIAL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_empty_and_valid() -> void:
	var empty: Dictionary = Social.empty_document()
	_expect(Social.valid(empty), "空文档合法")
	_expect((empty.relations as Dictionary).is_empty(), "空文档没有关系")
	_expect((empty.actions as Dictionary).is_empty(), "空文档没有动作时刻")
	_expect(not Social.valid(null), "null 文档被拒绝")
	_expect(not Social.valid([]), "数组文档被拒绝")
	_expect(not Social.valid({}), "空字典被拒绝")


func _test_json_roundtrip() -> void:
	var empty_text: String = JSON.stringify(Social.empty_document())
	var empty_parsed: Variant = JSON.parse_string(empty_text)
	_expect(empty_parsed is Dictionary and Social.valid(empty_parsed),
		"空文档 JSON 往返合法")
	var plain_text: String = JSON.stringify(_empty_document_text())
	_expect(plain_text == empty_text, "空文档 JSON 输出稳定")

	var applied: Dictionary = Social.apply(
		_act(LIN, XU, Social.KIND_GIFT, START + Social.ACT_TTL_SECONDS),
		Social.empty_document(), START)
	_expect(applied.ok, "JSON 夹具的赠礼动作被接受")
	var document: Dictionary = applied.document
	var text: String = JSON.stringify(document)
	var parsed: Variant = JSON.parse_string(text)
	_expect(parsed is Dictionary, "JSON 解析得到字典")
	_expect(Social.valid(parsed), "解析后的文档仍然合法")
	Social.normalize(parsed)
	_expect(JSON.stringify(parsed) == text, "归一后 JSON 与写入时一致")
	_expect(float(parsed.relations[LIN][XU].affinity) == 4.0,
		"JSON 往返保留关系增量")


func _test_plan_selection() -> void:
	var context: Dictionary = _context()
	var apology: Dictionary = Social.plan(context, START)
	_expect(apology.ok, "负关系时生成道歉动作")
	_expect(str(apology.act.kind) == Social.KIND_APOLOGIZE, "优先选择道歉")
	_expect(str(apology.act.to) == XU, "道歉对象是关系最低者")
	_expect(str(apology.act.from) == LIN, "动作发起者是本人")
	_expect(float(apology.act.expires_utc) == START + Social.ACT_TTL_SECONDS,
		"动作有效期取规划时刻加固定 TTL")

	var gift_context: Dictionary = _context()
	gift_context.resident.relations[XU].affinity = 10
	var gift: Dictionary = Social.plan(gift_context, START)
	_expect(gift.ok and str(gift.act.kind) == Social.KIND_GIFT, "关系非负时选择赠礼")
	_expect(str(gift.act.to) == XU, "赠礼对象是关系最低者")

	var invite_context: Dictionary = _context()
	invite_context.resident.relations[XU].affinity = 10
	invite_context.limits.gift_remaining = 0
	var invite: Dictionary = Social.plan(invite_context, START)
	_expect(invite.ok and str(invite.act.kind) == Social.KIND_INVITE,
		"没有赠礼余额且人格外向时选择邀请")
	_expect(str(invite.act.to) == ZHOU, "邀请对象是关系最高者")

	var greet_context: Dictionary = _greet_only_context()
	var greet: Dictionary = Social.plan(greet_context, START)
	_expect(greet.ok and str(greet.act.kind) == Social.KIND_GREET, "兜底动作是打招呼")
	_expect(str(greet.act.to) == XU, "打招呼对象是最近社交最久远者")

	var lonely: Dictionary = _context()
	lonely.resident.relations = {}
	var none: Dictionary = Social.plan(lonely, START)
	_expect(not none.ok and str(none.reason) == "nothing_to_do",
		"没有对象时返回 nothing_to_do")


func _test_plan_determinism() -> void:
	var context: Dictionary = _context()
	var first: Dictionary = Social.plan(context, START)
	var second: Dictionary = Social.plan(context, START)
	_expect(first.ok and second.ok, "同上下文重复规划均成功")
	_expect(JSON.stringify(first.act) == JSON.stringify(second.act),
		"同上下文同结果")
	_expect(str(first.act.id) == str(second.act.id), "同上下文同 act id")
	_expect(str(first.act.id).begins_with("social_"), "act id 使用固定前缀")

	var reordered: Dictionary = _context()
	var peers: Dictionary = reordered.resident.relations
	var flipped: Dictionary = {}
	flipped[ZHOU] = peers[ZHOU]
	flipped[XU] = peers[XU]
	reordered.resident.relations = flipped
	var third: Dictionary = Social.plan(reordered, START)
	_expect(JSON.stringify(first.act) == JSON.stringify(third.act),
		"对象字典顺序不影响选择")

	var later: Dictionary = Social.plan(context, START + 1.0)
	_expect(str(first.act.id) != str(later.act.id), "不同规划时刻得到不同 id")


func _test_plan_cooldowns_and_nothing() -> void:
	var greet_context: Dictionary = _greet_only_context()
	greet_context.cooldowns.actions[Social.KIND_GREET] = START - 299.0
	_expect(str(Social.plan(greet_context, START).reason) == "nothing_to_do",
		"动作冷却未结束时规划返回 nothing_to_do")

	greet_context.cooldowns.actions[Social.KIND_GREET] = START - 300.0
	var boundary: Dictionary = Social.plan(greet_context, START)
	_expect(boundary.ok and str(boundary.act.kind) == Social.KIND_GREET,
		"冷却边界时刻放行")

	var blocked: Dictionary = _context()
	blocked.cooldowns.actions = {
		Social.KIND_GREET: START,
		Social.KIND_GIFT: START,
		Social.KIND_INVITE: START,
		Social.KIND_APOLOGIZE: START,
	}
	_expect(str(Social.plan(blocked, START).reason) == "nothing_to_do",
		"全部动作冷却中返回 nothing_to_do")

	var invalid_time: Dictionary = Social.plan(_context(), -1.0)
	_expect(not invalid_time.ok and str(invalid_time.reason) == "invalid_time",
		"非法规划时刻被拒绝")
	var invalid_context: Dictionary = Social.plan({}, START)
	_expect(not invalid_context.ok and str(invalid_context.reason) == "invalid_context",
		"非法上下文被拒绝")


func _test_validate_rejections() -> void:
	var context: Dictionary = _context()
	var greet: Dictionary = _act(LIN, XU, Social.KIND_GREET,
		START + Social.ACT_TTL_SECONDS)
	var approved: Dictionary = Social.validate(greet, context, START)
	_expect(approved.ok and str(approved.reason).is_empty(), "合法动作通过校验")

	var wrong_kind: Dictionary = _act(LIN, XU, "trade", START + Social.ACT_TTL_SECONDS)
	_expect(str(Social.validate(wrong_kind, context, START).reason) == "invalid_kind",
		"目录外动作被拒绝")

	var ghost: Dictionary = _act(LIN, "npc_ghost", Social.KIND_GREET,
		START + Social.ACT_TTL_SECONDS)
	_expect(str(Social.validate(ghost, context, START).reason) == "invalid_target",
		"未知对象被拒绝")

	var self_target: Dictionary = _act(LIN, LIN, Social.KIND_GREET,
		START + Social.ACT_TTL_SECONDS)
	_expect(str(Social.validate(self_target, context, START).reason) == "invalid_target",
		"把自己当作对象被拒绝")

	var wrong_from: Dictionary = _act(XU, LIN, Social.KIND_GREET,
		START + Social.ACT_TTL_SECONDS)
	_expect(str(Social.validate(wrong_from, context, START).reason) == "invalid_from",
		"不是上下文居民的发起者被拒绝")

	var expired: Dictionary = _act(LIN, XU, Social.KIND_GREET, START)
	_expect(str(Social.validate(expired, context, START).reason) == "expired",
		"到达过期时刻被拒绝")

	var duplicate_context: Dictionary = context.duplicate(true)
	duplicate_context.cooldowns.acts[greet.id] = START
	_expect(str(Social.validate(greet, duplicate_context, START).reason)
		== "duplicate_intent", "已消费 act id 被拒绝")

	var cooling_context: Dictionary = context.duplicate(true)
	cooling_context.cooldowns.actions[Social.KIND_GREET] = START - 10.0
	_expect(str(Social.validate(greet, cooling_context, START).reason) == "cooldown",
		"动作冷却中拒绝")

	var full_context: Dictionary = context.duplicate(true)
	full_context.resident.relations[XU].acts = Social.MAX_ACTS_PER_PEER
	_expect(str(Social.validate(greet, full_context, START).reason) == "over_capacity",
		"动作数达到上限被拒绝")

	var gift: Dictionary = _act(LIN, XU, Social.KIND_GIFT,
		START + Social.ACT_TTL_SECONDS)
	var gift_context: Dictionary = context.duplicate(true)
	gift_context.resident.relations[XU].gifts = Social.MAX_GIFTS_PER_PEER
	_expect(str(Social.validate(gift, gift_context, START).reason) == "gift_cap",
		"赠礼次数达到上限被拒绝")

	var broke_context: Dictionary = context.duplicate(true)
	broke_context.limits.gift_remaining = 0
	_expect(str(Social.validate(gift, broke_context, START).reason)
		== "insufficient_gift", "赠礼余额为零被拒绝")

	var bad_id: Dictionary = greet.duplicate(true)
	bad_id.expires_utc = START + 60.0
	_expect(str(Social.validate(bad_id, context, START).reason) == "invalid_act_id",
		"篡改过期时刻后 id 不再匹配")

	var extra_key: Dictionary = greet.duplicate(true)
	extra_key.text = "自由文本"
	_expect(str(Social.validate(extra_key, context, START).reason) == "invalid_act",
		"动作额外键被拒绝")

	var bad_time: Dictionary = Social.validate(greet, context, -1.0)
	_expect(not bad_time.ok and str(bad_time.reason) == "invalid_time",
		"非法校验时刻被拒绝")


func _test_affinity_bounds() -> void:
	var high: Dictionary = _document({"affinity": 100, "last_utc": START - 10.0})
	var high_result: Dictionary = Social.apply(
		_act(LIN, XU, Social.KIND_GREET, START + Social.ACT_TTL_SECONDS), high, START)
	_expect(high_result.ok, "上界附近动作仍可执行")
	_expect(int(high_result.document.relations[LIN][XU].affinity) == 100,
		"affinity 增量被夹在上界")
	_expect(Social.valid(high_result.document), "上界候选文档合法")

	var low: Dictionary = _document({"affinity": -100, "last_utc": START - 10.0})
	var low_result: Dictionary = Social.apply(
		_act(LIN, XU, Social.KIND_APOLOGIZE, START + Social.ACT_TTL_SECONDS), low, START)
	_expect(low_result.ok, "下界附近道歉仍可执行")
	_expect(int(low_result.document.relations[LIN][XU].affinity) == -95,
		"affinity 增量从下界恢复且有界")

	var over: Dictionary = _document({"affinity": 101})
	_expect(not Social.valid(over), "affinity 超过 100 被拒绝")
	var under: Dictionary = _document({"affinity": -101})
	_expect(not Social.valid(under), "affinity 低于 -100 被拒绝")
	var fractional: Dictionary = _document({"affinity": 5.5})
	_expect(not Social.valid(fractional), "非整数 affinity 被拒绝")
	var integral_float: Dictionary = _document({"affinity": 5.0})
	_expect(Social.valid(integral_float), "整数值的 JSON float affinity 合法")


func _test_capacity_and_gift_caps() -> void:
	var gift_doc: Dictionary = _document({
		"last_utc": START - 100.0,
		"gifts_utc": _times(Social.MAX_GIFTS_PER_PEER, START - 100.0),
	})
	_expect(Social.valid(gift_doc), "满额赠礼文档合法")
	var gift_capped: Dictionary = Social.apply(
		_act(LIN, XU, Social.KIND_GIFT, START + Social.ACT_TTL_SECONDS), gift_doc, START)
	_expect(not gift_capped.ok and str(gift_capped.reason) == "gift_cap",
		"赠礼次数上限在 apply 中拒绝")
	_expect(not gift_capped.has("document") and not gift_capped.has("state"),
		"赠礼失败不带候选文档")

	var acts: Dictionary = {}
	for index: int in Social.MAX_ACTS_PER_PEER:
		acts["social_full_%02d" % index] = START - 100.0
	var act_doc: Dictionary = _document({"last_utc": START - 100.0, "acts": acts})
	_expect(Social.valid(act_doc), "满额动作文档合法")
	var act_capped: Dictionary = Social.apply(
		_act(LIN, XU, Social.KIND_GREET, START + Social.ACT_TTL_SECONDS), act_doc, START)
	_expect(not act_capped.ok and str(act_capped.reason) == "over_capacity",
		"动作数上限在 apply 中拒绝")

	var resident_doc: Dictionary = {"relations": {}, "actions": {}}
	for index: int in Social.MAX_RESIDENTS:
		resident_doc.relations["npc_resident_%02d" % index] = {}
	_expect(Social.valid(resident_doc), "达到居民上限的空文档合法")
	var resident_capped: Dictionary = Social.apply(
		_act(LIN, XU, Social.KIND_GREET, START + Social.ACT_TTL_SECONDS),
		resident_doc, START)
	_expect(not resident_capped.ok and str(resident_capped.reason) == "over_capacity",
		"新增居民超过上限被拒绝")

	var peer_rows: Dictionary = {}
	for index: int in Social.MAX_PEERS:
		peer_rows["npc_peer_%02d" % index] = _row()
	var peer_doc: Dictionary = {"relations": {LIN: peer_rows}, "actions": {}}
	_expect(Social.valid(peer_doc), "达到对象上限的文档合法")
	var peer_capped: Dictionary = Social.apply(
		_act(LIN, "npc_extra_peer", Social.KIND_GREET,
			START + Social.ACT_TTL_SECONDS), peer_doc, START)
	_expect(not peer_capped.ok and str(peer_capped.reason) == "over_capacity",
		"新增对象超过上限被拒绝")


func _test_apply_and_duplicate() -> void:
	var empty: Dictionary = Social.empty_document()
	var greet: Dictionary = _act(LIN, XU, Social.KIND_GREET,
		START + Social.ACT_TTL_SECONDS)
	var first: Dictionary = Social.apply(greet, empty, START)
	_expect(first.ok and str(first.reason).is_empty(), "合法动作写入成功")
	var document: Dictionary = first.document
	_expect(Social.valid(document), "写入后的候选文档合法")
	_expect(int(document.relations[LIN][XU].affinity) == 1, "打招呼增加 1 点关系")
	_expect(float(document.relations[LIN][XU].last_utc) == START, "记录最近社交时刻")
	_expect((document.relations[LIN][XU].acts as Dictionary).has(greet.id),
		"记录动作 id")
	_expect(float(document.actions[LIN][Social.KIND_GREET]) == START,
		"记录动作种类最近时刻")

	var replay: Dictionary = Social.apply(greet, document, START)
	_expect(not replay.ok and str(replay.reason) == "duplicate_intent",
		"同一 act id 重放被拒绝")
	_expect(int(document.relations[LIN][XU].affinity) == 1,
		"重放不重复增加关系")

	var cooling: Dictionary = Social.apply(
		_act(LIN, XU, Social.KIND_GREET, START + 10.0 + Social.ACT_TTL_SECONDS),
		document, START + 10.0)
	_expect(not cooling.ok and str(cooling.reason) == "cooldown",
		"冷却中第二次打招呼被拒绝")

	var second: Dictionary = Social.apply(
		_act(LIN, XU, Social.KIND_GREET, START + 300.0 + Social.ACT_TTL_SECONDS),
		document, START + 300.0)
	_expect(second.ok, "冷却结束后可再次打招呼")
	_expect(int(second.document.relations[LIN][XU].affinity) == 2,
		"第二次打招呼继续累加关系")

	var gift: Dictionary = Social.apply(
		_act(LIN, XU, Social.KIND_GIFT, START + 300.0 + Social.ACT_TTL_SECONDS),
		second.document, START + 300.0)
	_expect(gift.ok, "赠礼动作写入成功")
	_expect(int(gift.document.relations[LIN][XU].affinity) == 6,
		"赠礼增加 4 点关系")
	_expect((gift.document.relations[LIN][XU].gifts_utc as Array).size() == 1,
		"记录赠礼时刻")
	_expect(float(gift.document.relations[LIN][XU].gifts_utc[0]) == START + 300.0,
		"赠礼时刻取本次执行时刻")

	var gift_cooling: Dictionary = Social.apply(
		_act(LIN, XU, Social.KIND_GIFT,
			START + 301.0 + Social.ACT_TTL_SECONDS),
		gift.document, START + 301.0)
	_expect(not gift_cooling.ok and str(gift_cooling.reason) == "cooldown",
		"赠礼冷却未结束时被拒绝")

	var bad_document: Dictionary = Social.apply(greet, {"relations": {}}, START)
	_expect(not bad_document.ok and str(bad_document.reason) == "invalid_document",
		"非法文档不得写入")


func _test_copy_on_write() -> void:
	var document: Dictionary = _document({"affinity": 5, "last_utc": START - 100.0})
	var before: String = JSON.stringify(document)
	var applied: Dictionary = Social.apply(
		_act(LIN, XU, Social.KIND_GREET, START + Social.ACT_TTL_SECONDS),
		document, START)
	_expect(applied.ok, "写时复制夹具动作成功")
	_expect(JSON.stringify(document) == before, "apply 不修改输入文档")
	var candidate: Dictionary = applied.document
	candidate.relations[LIN][XU].acts["injected"] = 1.0
	_expect(not (document.relations[LIN][XU].acts as Dictionary).has("injected"),
		"候选文档与输入深拷贝隔离")
	candidate.relations[LIN][XU].affinity = 99
	_expect(int(document.relations[LIN][XU].affinity) == 5,
		"修改候选关系不污染输入")

	var expired: Dictionary = Social.apply(
		_act(LIN, XU, Social.KIND_GREET, START), document, START)
	_expect(not expired.ok and str(expired.reason) == "expired",
		"过期动作被拒绝")
	_expect(not expired.has("document") and not expired.has("state"),
		"失败结果不携带候选文档")


func _test_strict_valid() -> void:
	var unknown_root: Dictionary = Social.empty_document()
	unknown_root.extra = 1
	_expect(not Social.valid(unknown_root), "未知根键被拒绝")
	_expect(not Social.valid({"relations": {}}), "缺少 actions 根键被拒绝")
	_expect(not Social.valid({"relations": [], "actions": {}}),
		"relations 不是字典被拒绝")

	var unknown_row: Dictionary = _document()
	unknown_row.relations[LIN][XU].extra = 1
	_expect(not Social.valid(unknown_row), "关系行未知键被拒绝")

	var missing_row: Dictionary = _document()
	missing_row.relations[LIN][XU].erase("gifts_utc")
	_expect(not Social.valid(missing_row), "关系行缺少字段被拒绝")

	var unknown_kind: Dictionary = {"relations": {LIN: {}},
		"actions": {LIN: {"trade": 0.0}}}
	_expect(not Social.valid(unknown_kind), "关系文档中的未知动作被拒绝")

	var self_relation: Dictionary = {"relations": {LIN: {LIN: _row()}}, "actions": {}}
	_expect(not Social.valid(self_relation), "自己与自己的关系被拒绝")

	var bad_act_time: Dictionary = _document({"last_utc": START - 100.0,
		"acts": {"social_x": START}})
	_expect(not Social.valid(bad_act_time), "动作时刻晚于最近社交时刻被拒绝")

	var unsorted_gifts: Dictionary = _document({"last_utc": START,
		"gifts_utc": [START, START - 1.0]})
	_expect(not Social.valid(unsorted_gifts), "赠礼时刻必须非降序")

	var too_many_acts: Dictionary = _document({"last_utc": START - 100.0})
	var acts: Dictionary = {}
	for index: int in Social.MAX_ACTS_PER_PEER + 1:
		acts["social_x%02d" % index] = START - 100.0
	too_many_acts.relations[LIN][XU].acts = acts
	_expect(not Social.valid(too_many_acts), "超过动作数上限被拒绝")

	var too_many_gifts: Dictionary = _document({"last_utc": START - 100.0,
		"gifts_utc": _times(Social.MAX_GIFTS_PER_PEER + 1, START - 100.0)})
	_expect(not Social.valid(too_many_gifts), "超过赠礼数上限被拒绝")

	var too_many_peers: Dictionary = {"relations": {LIN: {}}, "actions": {}}
	for index: int in Social.MAX_PEERS + 1:
		too_many_peers.relations[LIN]["npc_peer_%02d" % index] = _row()
	_expect(not Social.valid(too_many_peers), "超过对象数上限被拒绝")

	var too_many_residents: Dictionary = {"relations": {}, "actions": {}}
	for index: int in Social.MAX_RESIDENTS + 1:
		too_many_residents.relations["npc_resident_%02d" % index] = {}
	_expect(not Social.valid(too_many_residents), "超过居民数上限被拒绝")

	var non_string_id: Dictionary = _document({"last_utc": START,
		"acts": {5: START}})
	_expect(not Social.valid(non_string_id), "非字符串动作 id 被拒绝")

	var long_id: Dictionary = _document({"last_utc": START,
		"acts": {"x".repeat(Social.MAX_ACT_ID_LENGTH + 1): START}})
	_expect(not Social.valid(long_id), "超长动作 id 被拒绝")

	var orphan_action: Dictionary = {"relations": {}, "actions": {LIN: {}}}
	_expect(not Social.valid(orphan_action), "没有关系行的动作时刻被拒绝")

	var late_action: Dictionary = _document({"last_utc": START - 100.0})
	late_action.actions[LIN] = {Social.KIND_GREET: START}
	_expect(not Social.valid(late_action), "动作种类时刻晚于最近社交被拒绝")


func _test_context_rejections() -> void:
	var unknown_key: Dictionary = _context()
	unknown_key.extra = 1
	_expect(str(Social.plan(unknown_key, START).reason) == "invalid_context",
		"上下文未知键被拒绝")

	var bad_traits: Dictionary = _context()
	bad_traits.resident.traits.erase("warmth")
	_expect(str(Social.plan(bad_traits, START).reason) == "invalid_traits",
		"缺少人格维度被拒绝")

	var out_of_range: Dictionary = _context()
	out_of_range.resident.traits.warmth = 101
	_expect(str(Social.plan(out_of_range, START).reason) == "invalid_traits",
		"人格越界被拒绝")

	var bad_relation: Dictionary = _context()
	bad_relation.resident.relations[XU].affinity = 101
	_expect(str(Social.plan(bad_relation, START).reason) == "invalid_relations",
		"上下文关系越界被拒绝")

	var bad_cooldown: Dictionary = _context()
	bad_cooldown.cooldowns.actions["trade"] = START
	_expect(str(Social.plan(bad_cooldown, START).reason) == "invalid_cooldowns",
		"上下文冷却含目录外动作被拒绝")

	var bad_limit: Dictionary = _context()
	bad_limit.limits.gift_remaining = -1
	_expect(str(Social.plan(bad_limit, START).reason) == "invalid_limits",
		"负赠礼余额被拒绝")

	var too_many_peers: Dictionary = _context()
	var peers: Dictionary = {}
	for index: int in Social.MAX_PEERS + 1:
		peers["npc_peer_%02d" % index] = {
			"affinity": 0, "last_utc": 0.0, "gifts": 0, "acts": 0,
		}
	too_many_peers.resident.relations = peers
	_expect(str(Social.plan(too_many_peers, START).reason) == "invalid_relations",
		"上下文对象数超限被拒绝")


func _test_narrative_not_authority() -> void:
	var claim: Dictionary = Social.claim_from_narrative(LIN, "我把渡口和账本送给你")
	_expect(not bool(claim.ok), "叙事声称权属不产生成功结果")
	_expect(str(claim.reason) == "not_authority", "叙事永远不是授权")
	_expect(not bool(claim.authority), "叙事不携带授权标记")
	_expect(bool(claim.proposal_only), "叙事只作为提案")
	_expect(not claim.has("grant") and not claim.has("ownership"),
		"叙事不返回权属结果")

	var non_string: Dictionary = Social.claim_from_narrative(42, 42)
	_expect(str(non_string.reason) == "not_authority", "非字符串叙事同样不授权")


func _context() -> Dictionary:
	return {
		"resident": {
			"id": LIN,
			"traits": {
				"diligence": 50,
				"warmth": 70,
				"suspicion": 30,
				"curiosity": 60,
				"generosity": 60,
			},
			"relations": {
				XU: {"affinity": -20, "last_utc": START - 600.0, "gifts": 0, "acts": 0},
				ZHOU: {"affinity": 40, "last_utc": START - 100.0, "gifts": 0, "acts": 0},
			},
		},
		"cooldowns": {"actions": {}, "acts": {}},
		"limits": {"gift_remaining": 3},
	}


func _greet_only_context() -> Dictionary:
	var context: Dictionary = _context()
	context.resident.traits.warmth = 0
	context.resident.traits.curiosity = 0
	context.resident.traits.generosity = 0
	context.resident.relations[XU].affinity = 10
	context.resident.relations[ZHOU].affinity = 20
	context.limits.gift_remaining = 0
	return context


func _row() -> Dictionary:
	return {"affinity": 0, "last_utc": 0.0, "acts": {}, "gifts_utc": []}


func _document(fields: Dictionary = {}) -> Dictionary:
	var row: Dictionary = _row()
	for key: Variant in fields:
		row[key] = fields[key]
	return {"relations": {LIN: {XU: row}}, "actions": {}}


func _empty_document_text() -> Dictionary:
	return {"relations": {}, "actions": {}}


func _act(from_id: String, to_id: String, kind: String,
		expires_utc: float) -> Dictionary:
	return {
		"id": Social._act_id(from_id, to_id, kind, expires_utc),
		"kind": kind,
		"from": from_id,
		"to": to_id,
		"expires_utc": expires_utc,
	}


func _times(count: int, at_utc: float) -> Array:
	var values: Array = []
	for index: int in count:
		values.append(at_utc)
	return values


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
