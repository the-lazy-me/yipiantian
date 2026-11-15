extends SceneTree
## M10-04 居民确定性对话（纯规则）。无头、隔离：不读真实时钟，不接模型/网络/
## 主循环，也不触碰农场存档、账户、权属或真实拜访。

const Dialogue = preload("res://npc/npc_dialogue.gd")
const Personality = preload("res://npc/npc_personality.gd")
const Social = preload("res://npc/npc_social.gd")
const Memory = preload("res://npc/npc_memory.gd")

const START: float = 1800000000.0
const LIN: String = "npc_lin_shen"
const SEED: int = 42

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_constants_and_templates()
	_test_determinism()
	_test_affinity_bounds_and_daily_cap()
	_test_cooldown()
	_test_personality_tone()
	_test_invite_gate()
	_test_rejections()
	_test_memory_summary_and_facts()
	_test_social_relation_interop()
	for failure: String in failures:
		push_error(failure)
	print("NPC_DIALOGUE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_constants_and_templates() -> void:
	_expect(Dialogue.CATEGORIES.size() == 7, "类别表恰好七项")
	var seen: Dictionary = {}
	for category: String in Dialogue.CATEGORIES:
		_expect(not seen.has(category), "类别唯一 %s" % category)
		seen[category] = true
	_expect(Dialogue.valid_category(Dialogue.CATEGORY_GREET), "问候是合法类别")
	_expect(not Dialogue.valid_category("buy"), "未登记类别被拒绝")
	_expect(not Dialogue.valid_category(7), "非字符串类别被拒绝")

	var replies: Dictionary = {}
	for reply: String in Dialogue.REPLY_KINDS:
		_expect(not replies.has(reply), "模板 id 唯一 %s" % reply)
		replies[reply] = true
	_expect(Dialogue.valid_reply_kind(Dialogue.REPLY_FAREWELL), "告别模板在表内")
	_expect(not Dialogue.valid_reply_kind("reply_free_text"), "表外模板被拒绝")

	# 每类输入在其自身合法范围内都必须落在固定模板表内。
	for category: String in Dialogue.CATEGORIES:
		var result: Dictionary = Dialogue.respond_with_traits(
			_traits(80, 10, 60), _relation(50), _speech(category), START)
		_expect(result.ok, "类别 %s 可产生回复" % category)
		_expect(Dialogue.valid_reply_kind(result.reply_kind),
			"类别 %s 的模板在常量表内" % category)
		_expect(str(result.memory_kind) == Memory.KIND_DIALOGUE,
			"类别 %s 写入既有对话记忆种类" % category)
		var delta: int = int(result.affinity_delta)
		_expect(delta >= 0 and delta <= Dialogue.MAX_DIALOGUE_DELTA,
			"类别 %s 增量有界" % category)

	for category: String in Dialogue.BASE_AFFINITY_DELTAS:
		_expect(Dialogue.CATEGORIES.has(category), "增量表只含已知类别 %s" % category)
		var value: int = int(Dialogue.BASE_AFFINITY_DELTAS[category])
		_expect(value >= 0 and value <= Dialogue.MAX_DIALOGUE_DELTA,
			"类别 %s 基础增量不超过单次上限" % category)

	_expect(int(Dialogue.BASE_AFFINITY_DELTAS[Dialogue.CATEGORY_FAREWELL]) == 0,
		"告别不改变关系")
	_expect(float(Dialogue.COOLDOWN_SECONDS) >= float(Social.COOLDOWNS[Social.KIND_GREET]),
		"对话冷却不短于社交问候冷却")


func _test_determinism() -> void:
	var traits: Dictionary = Personality.traits(LIN, SEED).traits
	var first: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(30), _speech(Dialogue.CATEGORY_GREET), START)
	var second: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(30), _speech(Dialogue.CATEGORY_GREET), START)
	_expect(first.ok and second.ok, "同输入两次均成功")
	_expect(JSON.stringify(first) == JSON.stringify(second), "同输入同输出")

	# 相同内容、不同插入顺序的关系字典仍是同一输入。
	var reordered: Dictionary = {"acts": 0, "gifts": 0, "last_utc": 0.0, "affinity": 30}
	var third: Dictionary = Dialogue.respond_with_traits(
		traits, reordered, _speech(Dialogue.CATEGORY_GREET), START)
	_expect(JSON.stringify(first) == JSON.stringify(third),
		"关系字段顺序不影响输出")

	var derived: Dictionary = Dialogue.respond(
		LIN, SEED, _relation(30), _speech(Dialogue.CATEGORY_GREET), START)
	_expect(derived.ok, "id+seed 入口成功")
	_expect(JSON.stringify(first) == JSON.stringify(derived),
		"id+seed 入口与显式人格入口一致")

	var other_seed: Dictionary = Dialogue.respond(
		LIN, SEED + 1, _relation(30), _speech(Dialogue.CATEGORY_GREET), START)
	_expect(other_seed.ok, "另一世界种子仍可回应")
	_expect(str(other_seed.category) == str(first.category), "世界种子不改变类别")


func _test_affinity_bounds_and_daily_cap() -> void:
	var traits: Dictionary = _traits(70, 10, 60)

	var apologize_full: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(10, 0, 0, 0), _speech(
			Dialogue.CATEGORY_APOLOGIZE, 0.0, 4), START)
	_expect(apologize_full.ok, "日额度剩余 1 时道歉仍可回应")
	_expect(int(apologize_full.affinity_delta) == 1, "道歉增量被日上限截断")
	_expect(int(apologize_full.daily_affinity_after) == Dialogue.MAX_DAILY_AFFINITY,
		"日累计不超过上限")
	_expect(str(apologize_full.capped_reason) == "daily", "截断原因是日上限")

	var apologize_blocked: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(10, 0, 0, 0), _speech(
			Dialogue.CATEGORY_APOLOGIZE, 0.0, Dialogue.MAX_DAILY_AFFINITY), START)
	_expect(apologize_blocked.ok, "日额度用尽时对话仍成立")
	_expect(int(apologize_blocked.affinity_delta) == 0, "日额度用尽后不再增关系")
	_expect(int(apologize_blocked.daily_affinity_after) == Dialogue.MAX_DAILY_AFFINITY,
		"日额度用尽后累计不变")
	_expect(str(apologize_blocked.capped_reason) == "daily", "日额度用尽仍报告原因")

	var near_top: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(99), _speech(Dialogue.CATEGORY_GREET), START)
	_expect(near_top.ok, "接近上界仍可回应")
	_expect(int(near_top.affinity_after) == Social.MAX_AFFINITY, "关系增量夹在上界")

	var at_top: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(Social.MAX_AFFINITY), _speech(Dialogue.CATEGORY_GREET), START)
	_expect(at_top.ok, "上界时仍可回应")
	_expect(int(at_top.affinity_delta) == 0, "上界时增量归零")
	_expect(int(at_top.affinity_after) == Social.MAX_AFFINITY, "上界不越界")
	_expect(str(at_top.capped_reason) == "affinity", "上界截断报告 affinity")

	var at_bottom: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(Social.MIN_AFFINITY), _speech(Dialogue.CATEGORY_APOLOGIZE), START)
	_expect(at_bottom.ok, "下界时仍可回应")
	_expect(int(at_bottom.affinity_after) == Social.MIN_AFFINITY + 2,
		"下界增量从下界恢复且有界")

	var repeated: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(0), _speech(Dialogue.CATEGORY_GREET), START)
	_expect(int(repeated.affinity_delta) <= Dialogue.MAX_DIALOGUE_DELTA,
		"普通对话增量不超过单次上限")


func _test_cooldown() -> void:
	var traits: Dictionary = _traits(70, 10, 60)

	var cooling: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(10),
		_speech(Dialogue.CATEGORY_GREET, START - Dialogue.COOLDOWN_SECONDS + 1.0), START)
	_expect(not cooling.ok, "冷却中的对话被拒绝")
	_expect(str(cooling.reason) == "cooldown", "冷却拒绝原因明确")
	_expect(str(cooling.cooldown_reason) == "cooldown", "冷却原因可供 UI 使用")
	_expect(not cooling.has("affinity_delta") and not cooling.has("memory_summary"),
		"冷却拒绝无增量与记忆副作用")

	var boundary: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(10),
		_speech(Dialogue.CATEGORY_GREET, START - Dialogue.COOLDOWN_SECONDS), START)
	_expect(boundary.ok, "冷却边界时刻放行")
	_expect(str(boundary.cooldown_reason).is_empty(), "成功回复无冷却原因")

	var never: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(10), _speech(Dialogue.CATEGORY_GREET, 0.0), START)
	_expect(never.ok, "从未对话时不触发冷却")

	var future: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(10),
		_speech(Dialogue.CATEGORY_GREET, START + 1.0), START)
	_expect(not future.ok and str(future.reason) == "invalid_time",
		"未来的最近对话时刻被拒绝")


func _test_personality_tone() -> void:
	var warm: Dictionary = Dialogue.respond_with_traits(
		_traits(80, 10, 60), _relation(50), _speech(Dialogue.CATEGORY_GREET), START)
	_expect(str(warm.tone) == Dialogue.TONE_WARM, "高亲和与高温和给出温和语气")
	_expect(str(warm.reply_kind) == Dialogue.REPLY_GREET_WARM, "温和问候模板")

	var neutral: Dictionary = Dialogue.respond_with_traits(
		_traits(50, 20, 50), _relation(10), _speech(Dialogue.CATEGORY_GREET), START)
	_expect(str(neutral.tone) == Dialogue.TONE_NEUTRAL, "中等人格给出中性语气")
	_expect(str(neutral.reply_kind) == Dialogue.REPLY_GREET_NEUTRAL, "中性问候模板")

	var low_affinity: Dictionary = Dialogue.respond_with_traits(
		_traits(80, 10, 60), _relation(-30), _speech(Dialogue.CATEGORY_GREET), START)
	_expect(str(low_affinity.tone) == Dialogue.TONE_GUARDED, "低关系给出警戒语气")
	_expect(str(low_affinity.reply_kind) == Dialogue.REPLY_GREET_GUARDED, "警戒问候模板")
	_expect(int(low_affinity.affinity_delta)
		== int(Dialogue.BASE_AFFINITY_DELTAS[Dialogue.CATEGORY_GREET]),
		"低关系不改变问候的固定增量")

	var suspicious: Dictionary = Dialogue.respond_with_traits(
		_traits(80, 90, 60), _relation(80), _speech(Dialogue.CATEGORY_GREET), START)
	_expect(str(suspicious.tone) == Dialogue.TONE_GUARDED,
		"高多疑压过高温和：人格参与但不越界")
	_expect(str(suspicious.reply_kind) == Dialogue.REPLY_GREET_GUARDED,
		"高多疑使用警戒模板")

	var generous: Dictionary = Dialogue.respond_with_traits(
		_traits(50, 10, 70), _relation(10), _speech(Dialogue.CATEGORY_THANK), START)
	_expect(str(generous.reply_kind) == Dialogue.REPLY_THANKS_WARM, "高慷慨道谢模板")

	var frugal: Dictionary = Dialogue.respond_with_traits(
		_traits(50, 10, 20), _relation(10), _speech(Dialogue.CATEGORY_THANK), START)
	_expect(str(frugal.reply_kind) == Dialogue.REPLY_THANKS_NEUTRAL,
		"低慷慨道谢模板")

	var distrustful: Dictionary = Dialogue.respond_with_traits(
		_traits(50, 90, 60), _relation(0), _speech(Dialogue.CATEGORY_APOLOGIZE), START)
	_expect(str(distrustful.reply_kind) == Dialogue.REPLY_APOLOGY_WITHHELD,
		"高多疑且低关系时暂不接受道歉")

	var trusting: Dictionary = Dialogue.respond_with_traits(
		_traits(50, 10, 60), _relation(0), _speech(Dialogue.CATEGORY_APOLOGIZE), START)
	_expect(str(trusting.reply_kind) == Dialogue.REPLY_APOLOGY_ACCEPTED,
		"低多疑时接受道歉")

	# 人格只改变语气与模板，不改变固定类别增量。
	_expect(int(warm.affinity_delta) == int(neutral.affinity_delta),
		"人格不改变问候增量")
	var guarded_apology: Dictionary = Dialogue.respond_with_traits(
		_traits(80, 90, 60), _relation(-30),
		_speech(Dialogue.CATEGORY_APOLOGIZE), START)
	_expect(int(guarded_apology.affinity_delta) == Dialogue.MAX_DIALOGUE_DELTA,
		"低关系下道歉增量仍不超过单次上限")


func _test_invite_gate() -> void:
	var traits: Dictionary = _traits(80, 10, 60)

	var low: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(Social.INVITE_MIN_AFFINITY - 1),
		_speech(Dialogue.CATEGORY_INVITE), START)
	_expect(not low.ok and str(low.reason) == "low_affinity",
		"关系低于邀约门限被拒绝")
	_expect(not low.has("affinity_delta") and not low.has("memory_summary"),
		"关系门限拒绝无副作用")

	var cold: Dictionary = Dialogue.respond_with_traits(
		_traits(10, 10, 10, 10), _relation(Social.INVITE_MIN_AFFINITY),
		_speech(Dialogue.CATEGORY_INVITE), START)
	_expect(not cold.ok and str(cold.reason) == "not_inclined",
		"低温和不参与邀约回应")

	var warm_ok: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(Social.INVITE_MIN_AFFINITY),
		_speech(Dialogue.CATEGORY_INVITE), START)
	_expect(warm_ok.ok, "关系与人格都满足时回应邀约")
	_expect(str(warm_ok.reply_kind) == Dialogue.REPLY_INVITE_CONSIDER,
		"邀约回复只是考虑，不承诺成行")

	var curious_ok: Dictionary = Dialogue.respond_with_traits(
		_traits(10, 10, 10, Social.INVITE_MIN_CURIOSITY), _relation(50),
		_speech(Dialogue.CATEGORY_INVITE), START)
	_expect(curious_ok.ok, "高好奇可替代低温和进入邀约回应")


func _test_rejections() -> void:
	var traits: Dictionary = _traits(50, 20, 50)

	var bad_category: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(0), _speech("trade"), START)
	_expect(not bad_category.ok and str(bad_category.reason) == "invalid_category",
		"目录外类别被拒绝")
	_expect(Dialogue.valid_speech(_speech(Dialogue.CATEGORY_GREET)),
		"合法对话输入通过公开校验")
	_expect(not Dialogue.valid_speech(_speech("trade")),
		"公开校验拒绝目录外类别")
	_expect(not Dialogue.valid_speech(
		{"category": Dialogue.CATEGORY_GREET, "last_dialogue_utc": 0.0,
			"daily_affinity": 0}), "公开校验要求可见事实键")

	var unknown_speech_key: Dictionary = _speech(Dialogue.CATEGORY_GREET)
	unknown_speech_key.text = "自由文本"
	_expect(not Dialogue.respond_with_traits(
		traits, _relation(0), unknown_speech_key, START).ok,
		"对话输入额外键被拒绝")

	var missing_speech_key: Dictionary = _speech(Dialogue.CATEGORY_GREET)
	missing_speech_key.erase("visible")
	_expect(not Dialogue.respond_with_traits(
		traits, _relation(0), missing_speech_key, START).ok,
		"对话输入缺少可见事实键被拒绝")

	var daily_over: Dictionary = _speech(Dialogue.CATEGORY_GREET, 0.0,
		Dialogue.MAX_DAILY_AFFINITY + 1)
	_expect(not Dialogue.respond_with_traits(traits, _relation(0), daily_over, START).ok,
		"日累计超过上限的输入被拒绝")

	var bad_relation_affinity: Dictionary = _relation(101)
	_expect(not Dialogue.respond_with_traits(
		traits, bad_relation_affinity, _speech(Dialogue.CATEGORY_GREET), START).ok,
		"关系越界被拒绝")
	_expect(not Dialogue.valid_relation({"affinity": 5.5, "last_utc": 0.0,
		"gifts": 0, "acts": 0}), "非整数 affinity 被拒绝")
	_expect(not Dialogue.valid_relation({"affinity": 0, "last_utc": 0.0,
		"gifts": 0}), "缺少关系字段被拒绝")
	_expect(not Dialogue.valid_relation({"affinity": 0, "last_utc": 0.0,
		"gifts": 0, "acts": 0, "extra": 1}), "关系额外键被拒绝")
	_expect(not Dialogue.valid_relation({"affinity": 0, "last_utc": 0.0,
		"gifts": Social.MAX_GIFTS_PER_PEER + 1, "acts": 0}), "赠礼计数越界被拒绝")
	_expect(not Dialogue.valid_relation({"affinity": 0, "last_utc": 0.0,
		"gifts": 0, "acts": Social.MAX_ACTS_PER_PEER + 1}), "动作计数越界被拒绝")

	var future_relation: Dictionary = _relation(0)
	future_relation.last_utc = START + 1.0
	_expect(not Dialogue.respond_with_traits(
		traits, future_relation, _speech(Dialogue.CATEGORY_GREET), START).ok,
		"晚于当前时刻的关系时刻被拒绝")

	var future_now: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(0), _speech(Dialogue.CATEGORY_GREET), -1.0)
	_expect(not future_now.ok and str(future_now.reason) == "invalid_time",
		"非法当前时刻被拒绝")
	_expect(not Dialogue.respond_with_traits(
		traits, _relation(0), _speech(Dialogue.CATEGORY_GREET), INF).ok,
		"无限当前时刻被拒绝")

	var bad_traits: Dictionary = _traits(50, 20, 50)
	bad_traits.erase(Personality.WARMTH)
	_expect(not Dialogue.respond_with_traits(
		bad_traits, _relation(0), _speech(Dialogue.CATEGORY_GREET), START).ok,
		"缺少人格维度被拒绝")
	var out_of_range_traits: Dictionary = _traits(50, 20, 50)
	out_of_range_traits.warmth = 101
	_expect(not Dialogue.respond_with_traits(
		out_of_range_traits, _relation(0), _speech(Dialogue.CATEGORY_GREET), START).ok,
		"人格越界被拒绝")

	var bad_id: Dictionary = Dialogue.respond(
		"", SEED, _relation(0), _speech(Dialogue.CATEGORY_GREET), START)
	_expect(not bad_id.ok and str(bad_id.reason) == "invalid_npc_id",
		"非法居民 id 被拒绝")
	var bad_seed: Dictionary = Dialogue.respond(
		LIN, -1, _relation(0), _speech(Dialogue.CATEGORY_GREET), START)
	_expect(not bad_seed.ok and str(bad_seed.reason) == "invalid_seed",
		"非法世界种子被拒绝")


func _test_memory_summary_and_facts() -> void:
	var traits: Dictionary = _traits(50, 20, 50)

	var work_missing: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(10), _speech(Dialogue.CATEGORY_ASK_WORK), START)
	_expect(str(work_missing.memory_summary) == "玩家问起农事，我回答没有记录。",
		"未传入农事事实时摘要写没有记录")
	_expect((work_missing.fact_refs as Dictionary).is_empty(),
		"未引用事实时不带 fact_refs")

	var work_recorded: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(10),
		_speech(Dialogue.CATEGORY_ASK_WORK, 0.0, 0, {"work_recorded": true}), START)
	_expect(str(work_recorded.reply_kind) == Dialogue.REPLY_WORK_RECORDED,
		"有农事记录时使用记录模板")
	_expect(str(work_recorded.memory_summary) == "玩家问起农事，我回答有记录。",
		"农事摘要只写结构化事实")
	_expect(work_recorded.fact_refs == {"work_recorded": true},
		"农事引用只带传入字段")

	var market_missing: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(10), _speech(Dialogue.CATEGORY_ASK_MARKET), START)
	_expect(str(market_missing.reply_kind) == Dialogue.REPLY_MARKET_UNRECORDED,
		"无行情时使用未记录模板")
	_expect(str(market_missing.memory_summary) == "玩家问起行情，我回答没有记录。",
		"无行情时不编造价格")

	var market_recorded: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(10),
		_speech(Dialogue.CATEGORY_ASK_MARKET, 0.0, 0, {"market_price": 12}), START)
	_expect(str(market_recorded.reply_kind) == Dialogue.REPLY_MARKET_RECORDED,
		"有行情时使用记录模板")
	_expect(str(market_recorded.memory_summary) == "玩家问起行情，我回答最近价格为12。",
		"行情摘要只引用传入价格")
	_expect(market_recorded.fact_refs == {"market_price": 12},
		"行情引用只带传入字段")

	var work_summary_facts: Dictionary = work_recorded.fact_refs
	_expect(not work_summary_facts.has("market_price"),
		"农事摘要不夹带行情字段")

	# 可见事实只接受固定键与有界标量，价格不能是 string 或负数。
	_expect(not Dialogue.valid_visible({"goods": "麦子"}), "可见事实未知键被拒绝")
	_expect(not Dialogue.valid_visible({"market_price": -1}), "负价格被拒绝")
	_expect(not Dialogue.valid_visible(
		{"market_price": Dialogue.MAX_VISIBLE_PRICE + 1}), "超上限价格被拒绝")
	_expect(not Dialogue.valid_visible({"market_price": "12"}), "字符串价格被拒绝")
	_expect(not Dialogue.valid_visible({"work_recorded": "yes"}),
		"非布尔农事标记被拒绝")
	_expect(Dialogue.valid_visible({}), "空可见事实合法")

	# 拒绝路径不携带任何可写入记忆的内容。
	var rejected: Dictionary = Dialogue.respond_with_traits(
		traits, _relation(0), _speech("unknown"), START)
	_expect(not rejected.has("memory_summary") and not rejected.has("reply_kind"),
		"拒绝结果不返回记忆摘要或模板")


func _test_social_relation_interop() -> void:
	# 用真实社交 API 生成关系，再投影成对话输入（PEER_KEYS），避免自造形状。
	var applied: Dictionary = Social.apply({
		"id": Social._act_id(
			LIN, "npc_xu_bo", Social.KIND_GIFT, START + Social.ACT_TTL_SECONDS),
		"kind": Social.KIND_GIFT,
		"from": LIN,
		"to": "npc_xu_bo",
		"expires_utc": START + Social.ACT_TTL_SECONDS,
	}, Social.empty_document(), START)
	_expect(applied.ok, "真实社交动作写入成功")
	var row: Dictionary = applied.document.relations[LIN]["npc_xu_bo"]
	var projection: Dictionary = {
		"affinity": int(row.affinity),
		"last_utc": float(row.last_utc),
		"gifts": (row.gifts_utc as Array).size(),
		"acts": (row.acts as Dictionary).size(),
	}
	_expect(Dialogue.valid_relation(projection), "社交行可投影为对话关系")
	_expect(not Dialogue.valid_relation(row), "对话不接受社交文档原始行形状")

	var profile: Dictionary = Personality.traits(LIN, SEED)
	_expect(profile.ok, "真实人格派生成功")
	_expect(Personality.valid(profile.traits), "派生人格通过真实校验")
	var result: Dictionary = Dialogue.respond_with_traits(
		profile.traits, projection, _speech(Dialogue.CATEGORY_GREET), START)
	_expect(result.ok, "真实人格与真实关系投影可对话")
	_expect(int(result.affinity_after) == clampi(
		int(row.affinity) + int(result.affinity_delta),
		Social.MIN_AFFINITY, Social.MAX_AFFINITY), "关系结果沿用社交上界")
	_expect(int(result.affinity_delta) <= Social.AFFINITY_DELTAS[Social.KIND_GIFT],
		"单次对话增量不超过一次赠礼")


func _traits(warmth: int, suspicion: int, generosity: int,
		curiosity: int = 50) -> Dictionary:
	return {
		"diligence": 50,
		"warmth": warmth,
		"suspicion": suspicion,
		"curiosity": curiosity,
		"generosity": generosity,
	}


func _relation(affinity: int, last_utc: float = 0.0, gifts: int = 0,
		acts: int = 0) -> Dictionary:
	return {"affinity": affinity, "last_utc": last_utc, "gifts": gifts, "acts": acts}


func _speech(category: String, last_dialogue_utc: float = 0.0,
		daily_affinity: int = 0, visible: Dictionary = {}) -> Dictionary:
	return {
		"category": category,
		"last_dialogue_utc": last_dialogue_utc,
		"daily_affinity": daily_affinity,
		"visible": visible,
	}


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
