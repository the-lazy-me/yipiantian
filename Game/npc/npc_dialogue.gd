extends RefCounted
## M10-04 居民确定性对话（纯规则切片）。不读 RNG、系统时钟、磁盘、场景或网络；
## 所有入口显式接收 `now_utc`，同一输入得到同一输出。本模块不接模型、UI、
## `HeadlessWorld` 或 `WorldHost`，也不创建邀约、拜访、交易、财产或权属。
##
## 为什么先做这七类玩家话语：
##
##   greet      问候，打开一段对话；不需要任何世界事实就能回应。
##   farewell   告别，关闭对话；不需要任何世界事实。
##   apologize  道歉；对应既有社交动作，只改关系，不涉及资产叙述。
##   thank      道谢；同上，回应只需要固定模板。
##   ask_work   问农事；农事是既有权威状态，能回答“有记录/未记录”，不需要编造作物或数量。
##   ask_market 问行情；公开价格是既有可见事实，未传入时用“未记录”模板。
##   invite     邀约；既有 `npc_invitation.gd` 已定义关系/人格门限，这里只决定口头回应。
##
## 其它类别（买卖承诺、任务、天气、私密传闻、情绪评价）会要求本模块编造商品、
## 价格、数量、承诺或他人隐私，因此不进入第一批。
##
## 回复不是自由生成：`reply_kind` 只会是 `REPLY_KINDS` 中的固定模板 id；
## `memory_summary` 也只由固定短句 + 调用方传入的可见事实拼成。没有传入的
## 资产事实一律写成“没有记录”，绝不补出商品名、价格或数量。
##
## 输入契约（严格；未知键、越界、超限一律拒绝）：
##
##   relation:  # 与 `NpcSocial.PEER_KEYS` 完全一致的只读关系投影
##   {
##     "affinity": 0,          # -100..100 整数
##     "last_utc": 0.0,        # 最近社交时刻，不得晚于 now_utc
##     "gifts": 0,             # 0..MAX_GIFTS_PER_PEER
##     "acts": 0,              # 0..MAX_ACTS_PER_PEER
##   }
##
##   speech:
##   {
##     "category": "greet",    # CATEGORIES 之一
##     "last_dialogue_utc": 0.0,  # 0 表示从未对话；否则是最近一次对话时刻
##     "daily_affinity": 0,    # 今日已经通过对话获得的关系增量，0..MAX_DAILY_AFFINITY
##     "visible": {            # 可见事实，可为空；只接受固定键
##       "market_price": 12,   # 可选，公开可见的最新价格（0..MAX_VISIBLE_PRICE）
##       "work_recorded": true,# 可选，是否有已记录的农事
##     },
##   }
##
## 成功输出：
##
##   {
##     "ok": true, "reason": "",
##     "category": "greet",
##     "reply_kind": "reply_greet_warm",   # REPLY_KINDS 之一
##     "tone": "warm",                     # TONES 之一
##     "affinity_delta": 1,                # 0..MAX_DIALOGUE_DELTA
##     "affinity_after": 21,               # 夹在 Social.MIN/MAX_AFFINITY
##     "daily_affinity_after": 1,          # 夹在 0..MAX_DAILY_AFFINITY
##     "capped_reason": "",                # "" / "daily" / "affinity"
##     "memory_kind": "dialogue",
##     "memory_summary": "玩家向我问候，我作了回应。",
##     "cooldown_reason": "",
##     "fact_refs": {},                    # 只含本次引用的可见事实
##   }
##
## 拒绝只返回 `{ok:false, reason, cooldown_reason}`，不返回可写入的记忆或关系
## 增量，也不修改任何输入。

const Personality = preload("res://npc/npc_personality.gd")
const Social = preload("res://npc/npc_social.gd")
const Memory = preload("res://npc/npc_memory.gd")

const CATEGORY_GREET: String = "greet"
const CATEGORY_ASK_WORK: String = "ask_work"
const CATEGORY_ASK_MARKET: String = "ask_market"
const CATEGORY_APOLOGIZE: String = "apologize"
const CATEGORY_THANK: String = "thank"
const CATEGORY_INVITE: String = "invite"
const CATEGORY_FAREWELL: String = "farewell"
const CATEGORIES: Array[String] = [
	CATEGORY_GREET, CATEGORY_ASK_WORK, CATEGORY_ASK_MARKET, CATEGORY_APOLOGIZE,
	CATEGORY_THANK, CATEGORY_INVITE, CATEGORY_FAREWELL,
]

const TONE_WARM: String = "warm"
const TONE_NEUTRAL: String = "neutral"
const TONE_GUARDED: String = "guarded"
const TONES: Array[String] = [TONE_WARM, TONE_NEUTRAL, TONE_GUARDED]

const REPLY_GREET_WARM: String = "reply_greet_warm"
const REPLY_GREET_NEUTRAL: String = "reply_greet_neutral"
const REPLY_GREET_GUARDED: String = "reply_greet_guarded"
const REPLY_WORK_RECORDED: String = "reply_work_recorded"
const REPLY_WORK_UNRECORDED: String = "reply_work_unrecorded"
const REPLY_MARKET_RECORDED: String = "reply_market_recorded"
const REPLY_MARKET_UNRECORDED: String = "reply_market_unrecorded"
const REPLY_APOLOGY_ACCEPTED: String = "reply_apology_accepted"
const REPLY_APOLOGY_WITHHELD: String = "reply_apology_withheld"
const REPLY_THANKS_WARM: String = "reply_thanks_warm"
const REPLY_THANKS_NEUTRAL: String = "reply_thanks_neutral"
const REPLY_INVITE_CONSIDER: String = "reply_invite_consider"
const REPLY_FAREWELL: String = "reply_farewell"
const REPLY_KINDS: Array[String] = [
	REPLY_GREET_WARM, REPLY_GREET_NEUTRAL, REPLY_GREET_GUARDED,
	REPLY_WORK_RECORDED, REPLY_WORK_UNRECORDED,
	REPLY_MARKET_RECORDED, REPLY_MARKET_UNRECORDED,
	REPLY_APOLOGY_ACCEPTED, REPLY_APOLOGY_WITHHELD,
	REPLY_THANKS_WARM, REPLY_THANKS_NEUTRAL,
	REPLY_INVITE_CONSIDER, REPLY_FAREWELL,
]

## 每类对话的固定关系增量。最大 2：一次对话不应接近一次赠礼（4）或道歉（5）
## 的权重，避免玩家只靠聊天快速推高关系。
const BASE_AFFINITY_DELTAS: Dictionary = {
	CATEGORY_GREET: 1,
	CATEGORY_ASK_WORK: 1,
	CATEGORY_ASK_MARKET: 1,
	CATEGORY_APOLOGIZE: 2,
	CATEGORY_THANK: 1,
	CATEGORY_INVITE: 2,
	CATEGORY_FAREWELL: 0,
}
const MAX_DIALOGUE_DELTA: int = 2

## 同一居民对同一玩家每 10 分钟最多一次有效对话。比社交动作的 greet 冷却
## （300 秒）更慢，因为对话由玩家直接触发，且不依赖居民自己的日程。
const COOLDOWN_SECONDS: float = 600.0

## 每名玩家每天（由调用方传入的 daily_affinity 计数）最多从对话获得 5 点关系。
## 从 0 到 100 仅靠对话需要 20 天，关系增长仍以居民自发社交和赠礼为主。
const MAX_DAILY_AFFINITY: int = 5

## 可见事实只保留有界标量；上限远低于安全整数，避免 UI 直接显示异常数值。
const MAX_VISIBLE_PRICE: int = 1000000

## 人格阈值。回复倾向由 warmth / suspicion 决定，generosity 只影响道谢模板。
const WARM_MIN_AFFINITY: int = 20
const WARM_MIN_WARMTH: int = 55
const GUARDED_MAX_AFFINITY: int = -20
const GUARDED_MIN_SUSPICION: int = 65
const GENEROUS_MIN_GENEROSITY: int = 60

## 道歉是否被接受只看当事人自己的怀疑度与关系，不读取其他玩家或外界评价。
const APOLOGY_WITHHOLD_MIN_SUSPICION: int = 70
const APOLOGY_WITHHOLD_MAX_AFFINITY: int = 0

const SPEECH_KEYS: Array[String] = [
	"category", "last_dialogue_utc", "daily_affinity", "visible",
]
const VISIBLE_KEYS: Array[String] = ["market_price", "work_recorded"]


## 从稳定 id + 世界种子派生人格，再走纯规则回应。派生由 `NpcPersonality`
## 唯一负责，本模块不另存或重算人格。
static func respond(npc_id: Variant, world_seed: Variant, relation: Variant,
		speech: Variant, now_utc: Variant) -> Dictionary:
	if not _valid_time(now_utc):
		return _refused("invalid_time")
	var profile: Dictionary = Personality.traits(npc_id, world_seed)
	if not profile.ok:
		return _refused(str(profile.reason))
	return respond_with_traits(profile.traits, relation, speech, now_utc)


## 使用已校验的人格档案。权威若已从名册取出 traits，可直接走这里，避免重复
## 推导；`Personality.valid()` 保证形状和范围。
static func respond_with_traits(traits: Variant, relation: Variant,
		speech: Variant, now_utc: Variant) -> Dictionary:
	if not _valid_time(now_utc):
		return _refused("invalid_time")
	if not Personality.valid(traits):
		return _refused("invalid_traits")
	if not valid_relation(relation):
		return _refused("invalid_relation")
	var now: float = float(now_utc)
	var row: Dictionary = relation
	if float(row.last_utc) > now:
		return _refused("invalid_relation")
	var checked: Dictionary = _check_speech(speech, now)
	if not checked.ok:
		return _refused(str(checked.reason), str(checked.cooldown_reason))

	var spoken: Dictionary = checked.speech
	var category: String = str(spoken.category)
	var affinity: int = int(row.affinity)
	var daily: int = int(spoken.daily_affinity)
	var visible: Dictionary = spoken.visible

	var last_dialogue: float = float(spoken.last_dialogue_utc)
	if last_dialogue > 0.0 and now < last_dialogue + COOLDOWN_SECONDS:
		return _refused("cooldown", "cooldown")

	var warmth: int = int((traits as Dictionary).warmth)
	var suspicion: int = int((traits as Dictionary).suspicion)
	var curiosity: int = int((traits as Dictionary).curiosity)

	if category == CATEGORY_INVITE:
		if affinity < Social.INVITE_MIN_AFFINITY:
			return _refused("low_affinity")
		if warmth < Social.INVITE_MIN_WARMTH \
				and curiosity < Social.INVITE_MIN_CURIOSITY:
			return _refused("not_inclined")

	var tone: String = _tone(affinity, warmth, suspicion)
	var reply_kind: String = _reply_kind(
		category, tone, affinity, suspicion,
		int((traits as Dictionary).generosity), visible)

	var base_delta: int = int(BASE_AFFINITY_DELTAS[category])
	var daily_remaining: int = MAX_DAILY_AFFINITY - daily
	var delta: int = mini(base_delta, daily_remaining)
	delta = mini(delta, Social.MAX_AFFINITY - affinity)
	delta = maxi(delta, 0)
	var capped_reason: String = ""
	if delta < base_delta:
		capped_reason = "daily" if delta == daily_remaining else "affinity"

	return {
		"ok": true,
		"reason": "",
		"category": category,
		"reply_kind": reply_kind,
		"tone": tone,
		"affinity_delta": delta,
		"affinity_after": clampi(
			affinity + delta, Social.MIN_AFFINITY, Social.MAX_AFFINITY),
		"daily_affinity_after": clampi(daily + delta, 0, MAX_DAILY_AFFINITY),
		"capped_reason": capped_reason,
		"memory_kind": Memory.KIND_DIALOGUE,
		"memory_summary": _summary(category, reply_kind, visible),
		"cooldown_reason": "",
		"fact_refs": _fact_refs(category, visible),
	}


static func valid_category(value: Variant) -> bool:
	return value is String and str(value) in CATEGORIES


static func valid_reply_kind(value: Variant) -> bool:
	return value is String and str(value) in REPLY_KINDS


## 关系投影必须与 `NpcSocial.PEER_KEYS` 完全一致，字段范围和上限复用社交模块，
## 避免对话层另造一套关系形状。
static func valid_relation(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var row: Dictionary = value
	if not _exact_keys(row, Social.PEER_KEYS):
		return false
	if not _is_int_in(row.get("affinity"), Social.MIN_AFFINITY, Social.MAX_AFFINITY):
		return false
	if not _valid_time(row.get("last_utc")):
		return false
	if not _is_int_in(row.get("gifts"), 0, Social.MAX_GIFTS_PER_PEER):
		return false
	if not _is_int_in(row.get("acts"), 0, Social.MAX_ACTS_PER_PEER):
		return false
	return true


static func valid_speech(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var speech: Dictionary = value
	if not _exact_keys(speech, SPEECH_KEYS):
		return false
	if not valid_category(speech.get("category")):
		return false
	if not _valid_time(speech.get("last_dialogue_utc")):
		return false
	if not _is_int_in(speech.get("daily_affinity"), 0, MAX_DAILY_AFFINITY):
		return false
	return valid_visible(speech.get("visible"))


static func valid_visible(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var visible: Dictionary = value
	for key: Variant in visible.keys():
		if not (key is String) or not str(key) in VISIBLE_KEYS:
			return false
	if visible.has("market_price"):
		if not _is_int_in(visible.market_price, 0, MAX_VISIBLE_PRICE):
			return false
	if visible.has("work_recorded"):
		if not visible.work_recorded is bool:
			return false
	return true


static func _check_speech(value: Variant, now_utc: float) -> Dictionary:
	if not value is Dictionary:
		return _check_failed("invalid_speech")
	var speech: Dictionary = value
	if not _exact_keys(speech, SPEECH_KEYS):
		return _check_failed("invalid_speech")
	if not valid_category(speech.get("category")):
		return _check_failed("invalid_category")
	if not _valid_time(speech.get("last_dialogue_utc")):
		return _check_failed("invalid_time")
	if float(speech.last_dialogue_utc) > now_utc:
		return _check_failed("invalid_time")
	if not _is_int_in(speech.get("daily_affinity"), 0, MAX_DAILY_AFFINITY):
		return _check_failed("invalid_speech")
	if not valid_visible(speech.get("visible")):
		return _check_failed("invalid_visible")
	return {
		"ok": true, "reason": "", "cooldown_reason": "",
		"speech": {
			"category": str(speech.category),
			"last_dialogue_utc": float(speech.last_dialogue_utc),
			"daily_affinity": int(speech.daily_affinity),
			"visible": (speech.visible as Dictionary).duplicate(true),
		},
	}


## 先看警戒，再看温和：高多疑的居民不会因为高亲和就被当成热情。关系达到
## 20 且 warmth >= 55 才进入 warm；affinity <= -20 或 suspicion >= 65 一律
## guarded；其余 neutral。阈值只影响语气与模板，不改变增量。
static func _tone(affinity: int, warmth: int, suspicion: int) -> String:
	if affinity <= GUARDED_MAX_AFFINITY or suspicion >= GUARDED_MIN_SUSPICION:
		return TONE_GUARDED
	if affinity >= WARM_MIN_AFFINITY and warmth >= WARM_MIN_WARMTH:
		return TONE_WARM
	return TONE_NEUTRAL


static func _reply_kind(category: String, tone: String, affinity: int,
		suspicion: int, generosity: int, visible: Dictionary) -> String:
	if category == CATEGORY_GREET:
		if tone == TONE_WARM:
			return REPLY_GREET_WARM
		if tone == TONE_GUARDED:
			return REPLY_GREET_GUARDED
		return REPLY_GREET_NEUTRAL
	if category == CATEGORY_ASK_WORK:
		return REPLY_WORK_RECORDED if bool(visible.get("work_recorded", false)) \
			else REPLY_WORK_UNRECORDED
	if category == CATEGORY_ASK_MARKET:
		return REPLY_MARKET_RECORDED if visible.has("market_price") \
			else REPLY_MARKET_UNRECORDED
	if category == CATEGORY_APOLOGIZE:
		if suspicion >= APOLOGY_WITHHOLD_MIN_SUSPICION \
				and affinity <= APOLOGY_WITHHOLD_MAX_AFFINITY:
			return REPLY_APOLOGY_WITHHELD
		return REPLY_APOLOGY_ACCEPTED
	if category == CATEGORY_THANK:
		return REPLY_THANKS_WARM if generosity >= GENEROUS_MIN_GENEROSITY \
			else REPLY_THANKS_NEUTRAL
	if category == CATEGORY_INVITE:
		return REPLY_INVITE_CONSIDER
	if category == CATEGORY_FAREWELL:
		return REPLY_FAREWELL
	return ""


## 摘要只由固定短句与调用方传入的可见标量组成；没有事实时写“没有记录”。
## 这里不读取记忆正文、不拼接自由文本，也不推断未传入的商品或数量。
static func _summary(category: String, reply_kind: String,
		visible: Dictionary) -> String:
	if category == CATEGORY_GREET:
		return "玩家向我问候，我作了回应。"
	if category == CATEGORY_ASK_WORK:
		if bool(visible.get("work_recorded", false)):
			return "玩家问起农事，我回答有记录。"
		return "玩家问起农事，我回答没有记录。"
	if category == CATEGORY_ASK_MARKET:
		if visible.has("market_price"):
			return "玩家问起行情，我回答最近价格为%d。" % int(visible.market_price)
		return "玩家问起行情，我回答没有记录。"
	if category == CATEGORY_APOLOGIZE:
		if reply_kind == REPLY_APOLOGY_WITHHELD:
			return "玩家向我道歉，我暂未接受。"
		return "玩家向我道歉，我接受。"
	if category == CATEGORY_THANK:
		return "玩家向我道谢，我作了回应。"
	if category == CATEGORY_INVITE:
		return "玩家邀我做客，我表示会考虑。"
	if category == CATEGORY_FAREWELL:
		return "玩家与我道别。"
	return ""


## 只把本次模板真正引用的可见事实交给 UI/权威；其它字段不随输出泄露。
static func _fact_refs(category: String, visible: Dictionary) -> Dictionary:
	if category == CATEGORY_ASK_WORK and visible.has("work_recorded"):
		return {"work_recorded": bool(visible.work_recorded)}
	if category == CATEGORY_ASK_MARKET and visible.has("market_price"):
		return {"market_price": int(visible.market_price)}
	return {}


static func _is_int_in(value: Variant, minimum: int, maximum: int) -> bool:
	if value is int:
		return int(value) >= minimum and int(value) <= maximum
	if not value is float:
		return false
	var number: float = value
	return is_finite(number) and number == floorf(number) \
		and number >= float(minimum) and number <= float(maximum)


static func _valid_time(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	return is_finite(float(value)) and float(value) >= 0.0 \
		and float(value) <= float(Social.MAX_SAFE_INTEGER)


static func _exact_keys(value: Dictionary, keys: Array[String]) -> bool:
	if value.size() != keys.size():
		return false
	for key: String in keys:
		if not value.has(key):
			return false
	return true


static func _refused(reason: String, cooldown_reason: String = "") -> Dictionary:
	return {
		"ok": false, "reason": reason, "cooldown_reason": cooldown_reason,
	}


static func _check_failed(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "cooldown_reason": "", "speech": {}}
