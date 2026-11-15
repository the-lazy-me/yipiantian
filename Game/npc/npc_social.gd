extends RefCounted
## M10-04 居民自发社交（纯规则切片）。不读 RNG、系统时钟、磁盘、场景或网络；
## 所有入口显式接收 `now_utc`，同一输入得到同一输出。本模块不接模型、UI、
## `WorldHost` 或 `FarmState`，也不扣款、发货、改账户、改动权属或命令权限。
##
## 只读上下文契约（调用方从权威状态投影而来，未知键一律拒绝）：
##
##   {
##     "resident": {
##       "id": "npc_lin_shen",                       # OwnerIds.valid
##       "traits": {                                 # 恰好五维，0..100 整数
##         "diligence": 50, "warmth": 70, "suspicion": 30,
##         "curiosity": 60, "generosity": 60,
##       },
##       "relations": {                              # 最多 MAX_PEERS 位对象
##         "npc_xu_bo": {
##           "affinity": -20,                        # -100..100 整数
##           "last_utc": 1799999400.0,               # 最近一次对该对象的社交
##           "gifts": 0,                             # 已赠礼次数，0..MAX_GIFTS_PER_PEER
##           "acts": 0,                              # 已记录动作数，0..MAX_ACTS_PER_PEER
##         },
##       },
##     },
##     "cooldowns": {
##       "actions": {"greet": 1799999700.0},         # 动作种类 -> 最近执行时刻
##       "acts": {"social_123": 1799999700.0},       # 已消费动作 id -> 执行时刻
##     },
##     "limits": {
##       "gift_remaining": 3,                        # 可赠礼余额上限（剩余份数）
##     },
##   }
##
## 关系文档形状（严格 `valid()`；未知键、越界、超限一律拒绝）：
##
##   {
##     "relations": {
##       "<npc_id>": {
##         "<peer_id>": {
##           "affinity": 0,                          # -100..100 整数
##           "last_utc": 0.0,                        # 最近社交时刻
##           "acts": {"social_123": 0.0},            # 动作 id -> 执行时刻
##           "gifts_utc": [0.0],                     # 赠礼时刻，非降序
##         },
##       },
##     },
##     "actions": {
##       "<npc_id>": {"greet": 0.0},                 # 动作种类 -> 最近执行时刻
##     },
##   }
##
## 上限：MAX_RESIDENTS 名发起者 × 每位 MAX_PEERS 个对象；每对关系最多
## MAX_ACTS_PER_PEER 条动作、MAX_GIFTS_PER_PEER 次赠礼。动作目录固定为
## greet / gift / invite / apologize，不接受自由文本作为权威内容。
##
## 边界：社交只改变关系文档中的 affinity、时刻与计数。它不授予任何财产、
## 权属、账户或命令权限；`claim_from_narrative()` 永远返回 `not_authority`，
## 叙述只能当提案，不能当授权。

const OwnerIds = preload("res://farm/owner_id.gd")

const KIND_GREET: String = "greet"
const KIND_GIFT: String = "gift"
const KIND_INVITE: String = "invite"
const KIND_APOLOGIZE: String = "apologize"
const ACTIONS: Array[String] = [
	KIND_GREET, KIND_GIFT, KIND_INVITE, KIND_APOLOGIZE,
]

## 每种动作的固定冷却（秒）。`now_utc >= last_utc + cooldown` 才允许再次执行。
const COOLDOWNS: Dictionary = {
	KIND_GREET: 300.0,
	KIND_GIFT: 1800.0,
	KIND_INVITE: 3600.0,
	KIND_APOLOGIZE: 1800.0,
}

## 每次动作对 affinity 的固定增量；结果在 apply 中夹到 -100..100。
const AFFINITY_DELTAS: Dictionary = {
	KIND_GREET: 1,
	KIND_GIFT: 4,
	KIND_INVITE: 2,
	KIND_APOLOGIZE: 5,
}

const MIN_AFFINITY: int = -100
const MAX_AFFINITY: int = 100
const MIN_TRAIT: int = 0
const MAX_TRAIT: int = 100
const MAX_RESIDENTS: int = 16
const MAX_PEERS: int = 32
const MAX_ACTS_PER_PEER: int = 16
const MAX_GIFTS_PER_PEER: int = 8
const MAX_ACT_ID_LENGTH: int = 128
const MAX_APPLIED_ACTS: int = 512
const MAX_SAFE_INTEGER: int = 9007199254740991
const ACT_TTL_SECONDS: float = 120.0

## plan 的人格/关系阈值。全部是具名规则常量，不读随机数或外部状态。
const GIFT_MIN_GENEROSITY: int = 50
const GIFT_MAX_AFFINITY: int = 80
const INVITE_MIN_AFFINITY: int = 20
const INVITE_MIN_WARMTH: int = 50
const INVITE_MIN_CURIOSITY: int = 50
const APOLOGY_MAX_AFFINITY: int = 0

const DOCUMENT_KEYS: Array[String] = ["relations", "actions"]
const RELATION_ROW_KEYS: Array[String] = ["affinity", "last_utc", "acts", "gifts_utc"]
const CONTEXT_KEYS: Array[String] = ["resident", "cooldowns", "limits"]
const RESIDENT_KEYS: Array[String] = ["id", "traits", "relations"]
const TRAIT_KEYS: Array[String] = [
	"diligence", "warmth", "suspicion", "curiosity", "generosity",
]
const PEER_KEYS: Array[String] = ["affinity", "last_utc", "gifts", "acts"]
const COOLDOWN_KEYS: Array[String] = ["actions", "acts"]
const LIMIT_KEYS: Array[String] = ["gift_remaining"]
const ACT_KEYS: Array[String] = ["id", "kind", "from", "to", "expires_utc"]

const HASH_OFFSET: int = 2166136261
const HASH_PRIME: int = 16777619
const HASH_MASK: int = 0xFFFFFFFF


static func empty_document() -> Dictionary:
	return {"relations": {}, "actions": {}}


## 严格文档校验：恰好两个根键、固定关系行键集、整数 affinity 在界内、
## 所有时刻有限且非负、动作/赠礼不晚于该关系的 `last_utc`、动作种类来自
## 固定目录，并检查各层数量上限。未知键一律拒绝。
static func valid(document: Variant) -> bool:
	if not document is Dictionary:
		return false
	var stored: Dictionary = document
	if stored.size() != DOCUMENT_KEYS.size():
		return false
	for key: String in DOCUMENT_KEYS:
		if not stored.has(key):
			return false
	if not stored.relations is Dictionary or not stored.actions is Dictionary:
		return false
	var relations: Dictionary = stored.relations
	var actions: Dictionary = stored.actions
	if relations.size() > MAX_RESIDENTS or actions.size() > MAX_RESIDENTS:
		return false
	for from_value: Variant in relations:
		if not _valid_resident_id(from_value):
			return false
		var peers_value: Variant = relations[from_value]
		if not peers_value is Dictionary:
			return false
		var peers: Dictionary = peers_value
		if peers.size() > MAX_PEERS:
			return false
		var latest: float = 0.0
		for to_value: Variant in peers:
			if not _valid_resident_id(to_value):
				return false
			if str(to_value) == str(from_value):
				return false
			var row_value: Variant = peers[to_value]
			if not row_value is Dictionary:
				return false
			var row: Dictionary = row_value
			if row.size() != RELATION_ROW_KEYS.size():
				return false
			for key: String in RELATION_ROW_KEYS:
				if not row.has(key):
					return false
			if not _is_int_in(row.get("affinity"), MIN_AFFINITY, MAX_AFFINITY):
				return false
			if not _valid_time(row.get("last_utc")):
				return false
			var last_utc: float = float(row.last_utc)
			if not row.acts is Dictionary:
				return false
			var acts: Dictionary = row.acts
			if acts.size() > MAX_ACTS_PER_PEER:
				return false
			for act_id: Variant in acts:
				if not _valid_act_id(act_id):
					return false
				if not _valid_time(acts[act_id]):
					return false
				if float(acts[act_id]) > last_utc:
					return false
			if not row.gifts_utc is Array:
				return false
			var gifts: Array = row.gifts_utc
			if gifts.size() > MAX_GIFTS_PER_PEER:
				return false
			var previous: float = 0.0
			for index: int in gifts.size():
				if not _valid_time(gifts[index]):
					return false
				var gift_time: float = float(gifts[index])
				if gift_time > last_utc:
					return false
				if index > 0 and gift_time < previous:
					return false
				previous = gift_time
			if last_utc > latest:
				latest = last_utc
		var kind_times_value: Variant = actions.get(from_value)
		if kind_times_value != null:
			if not kind_times_value is Dictionary:
				return false
			var kind_times: Dictionary = kind_times_value
			if kind_times.size() > ACTIONS.size():
				return false
			for kind_value: Variant in kind_times:
				if not _valid_kind(kind_value):
					return false
				if not _valid_time(kind_times[kind_value]):
					return false
				if float(kind_times[kind_value]) > latest:
					return false
	for from_value: Variant in actions:
		if not _valid_resident_id(from_value):
			return false
		if not relations.has(from_value):
			return false
	return true


## JSON 数字到达时都是 float；在严格校验之后归一，让内存文档保持写入形状。
static func normalize(document: Dictionary) -> void:
	var relations_value: Variant = document.get("relations")
	if not relations_value is Dictionary:
		return
	var relations: Dictionary = relations_value
	for from_value: Variant in relations:
		var peers_value: Variant = relations[from_value]
		if not peers_value is Dictionary:
			continue
		var peers: Dictionary = peers_value
		for to_value: Variant in peers:
			var row_value: Variant = peers[to_value]
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			if row.has("affinity"):
				row.affinity = int(row.affinity)
			if row.has("last_utc"):
				row.last_utc = float(row.last_utc)
			var acts_value: Variant = row.get("acts")
			if acts_value is Dictionary:
				var acts: Dictionary = acts_value
				for act_id: Variant in acts:
					acts[act_id] = float(acts[act_id])
			var gifts_value: Variant = row.get("gifts_utc")
			if gifts_value is Array:
				var gifts: Array = gifts_value
				for index: int in gifts.size():
					gifts[index] = float(gifts[index])
	var actions_value: Variant = document.get("actions")
	if not actions_value is Dictionary:
		return
	var actions: Dictionary = actions_value
	for from_value: Variant in actions:
		var kind_times_value: Variant = actions[from_value]
		if not kind_times_value is Dictionary:
			continue
		var kind_times: Dictionary = kind_times_value
		for kind_value: Variant in kind_times:
			kind_times[kind_value] = float(kind_times[kind_value])


## 从只读上下文确定性选择一个社交动作与对象。优先级固定为
## apologize -> gift -> invite -> greet；没有可用动作时返回
## `{ok:false, reason:"nothing_to_do"}`。人格阈值只影响是否进入某类动作，
## 对象选择按 affinity / last_utc 与 id 升序打破平局，不依赖字典遍历顺序。
static func plan(context: Variant, now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return _fail("invalid_time")
	var checked: Dictionary = _check_context(context)
	if not checked.ok:
		return _fail(str(checked.reason))
	var resident: Dictionary = checked.resident
	var relations: Dictionary = resident.relations
	if relations.is_empty():
		return _fail("nothing_to_do")
	var traits: Dictionary = resident.traits
	var action_times: Dictionary = (checked.cooldowns as Dictionary).actions
	var gift_remaining: int = int((checked.limits as Dictionary).gift_remaining)
	var now: float = float(now_utc)

	if _action_ready(action_times, KIND_APOLOGIZE, now):
		var apology: String = _lowest_affinity_peer(relations, APOLOGY_MAX_AFFINITY)
		if not apology.is_empty():
			return _planned(str(resident.id), apology, KIND_APOLOGIZE, now)
	if _action_ready(action_times, KIND_GIFT, now) \
			and gift_remaining > 0 \
			and int(traits.generosity) >= GIFT_MIN_GENEROSITY:
		var gift: String = _gift_target(relations)
		if not gift.is_empty():
			return _planned(str(resident.id), gift, KIND_GIFT, now)
	if _action_ready(action_times, KIND_INVITE, now) \
			and (int(traits.warmth) >= INVITE_MIN_WARMTH
				or int(traits.curiosity) >= INVITE_MIN_CURIOSITY):
		var invite: String = _highest_affinity_peer(relations, INVITE_MIN_AFFINITY)
		if not invite.is_empty():
			return _planned(str(resident.id), invite, KIND_INVITE, now)
	if _action_ready(action_times, KIND_GREET, now):
		var greet: String = _oldest_peer(relations)
		if not greet.is_empty():
			return _planned(str(resident.id), greet, KIND_GREET, now)
	return _fail("nothing_to_do")


## 执行前校验。按顺序拒绝：时间/上下文、动作形状、确定性 id、动作种类、
## 发起者、对象、过期、已消费 id、动作冷却、动作数/赠礼数上限、赠礼余额。
## 成功只返回 `{ok:true, reason:""}`；不修改任何输入。
static func validate(act: Variant, context: Variant, now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return _fail("invalid_time")
	var checked: Dictionary = _check_context(context)
	if not checked.ok:
		return _fail(str(checked.reason))
	var shaped: Dictionary = _check_act(act)
	if not shaped.ok:
		return _fail(str(shaped.reason))
	var action: Dictionary = shaped.act
	var resident: Dictionary = checked.resident
	if str(action.from) != str(resident.id):
		return _fail("invalid_from")
	var relations: Dictionary = resident.relations
	if str(action.to) == str(action.from) or not relations.has(str(action.to)):
		return _fail("invalid_target")
	var now: float = float(now_utc)
	if now >= float(action.expires_utc):
		return _fail("expired")
	var cooldowns: Dictionary = checked.cooldowns
	if (cooldowns.acts as Dictionary).has(str(action.id)):
		return _fail("duplicate_intent")
	if not _action_ready(cooldowns.actions, str(action.kind), now):
		return _fail("cooldown")
	var peer: Dictionary = relations[str(action.to)]
	if int(peer.acts) >= MAX_ACTS_PER_PEER:
		return _fail("over_capacity")
	if str(action.kind) == KIND_GIFT:
		if int(peer.gifts) >= MAX_GIFTS_PER_PEER:
			return _fail("gift_cap")
		if int((checked.limits as Dictionary).gift_remaining) <= 0:
			return _fail("insufficient_gift")
	return {"ok": true, "reason": ""}


## 生成候选关系文档，不修改输入。按顺序拒绝：时间、文档、动作形状、
## 对象、过期、重复 id、动作冷却、动作数/赠礼数/居民数/对象数上限。
## 成功时写入 affinity 增量（夹到 -100..100）、动作时刻、赠礼时刻和
## 动作种类最近时刻；失败只返回 `{ok:false, reason}`，不带候选文档。
static func apply(act: Variant, document: Variant, now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return _fail("invalid_time")
	if not valid(document):
		return _fail("invalid_document")
	var shaped: Dictionary = _check_act(act)
	if not shaped.ok:
		return _fail(str(shaped.reason))
	var action: Dictionary = shaped.act
	if str(action.to) == str(action.from):
		return _fail("invalid_target")
	var now: float = float(now_utc)
	if now >= float(action.expires_utc):
		return _fail("expired")
	var stored: Dictionary = document
	var relations: Dictionary = stored.relations
	var actions: Dictionary = stored.actions
	var from_key: String = str(action.from)
	var to_key: String = str(action.to)
	var kind: String = str(action.kind)
	var act_id: String = str(action.id)
	var from_row: Dictionary = {}
	var from_exists: bool = relations.has(from_key)
	if from_exists:
		from_row = relations[from_key]
	var to_row: Dictionary = {}
	var to_exists: bool = from_row.has(to_key)
	if to_exists:
		to_row = from_row[to_key]
	if to_exists and (to_row.acts as Dictionary).has(act_id):
		return _fail("duplicate_intent")
	var action_times: Dictionary = {}
	var existing_kind_times: Variant = actions.get(from_key)
	if existing_kind_times is Dictionary:
		action_times = existing_kind_times
	if not _action_ready(action_times, kind, now):
		return _fail("cooldown")
	if to_exists and (to_row.acts as Dictionary).size() >= MAX_ACTS_PER_PEER:
		return _fail("over_capacity")
	if kind == KIND_GIFT and to_exists \
			and (to_row.gifts_utc as Array).size() >= MAX_GIFTS_PER_PEER:
		return _fail("gift_cap")
	if not from_exists and relations.size() >= MAX_RESIDENTS:
		return _fail("over_capacity")
	if not to_exists and from_row.size() >= MAX_PEERS:
		return _fail("over_capacity")

	var candidate: Dictionary = stored.duplicate(true)
	var candidate_relations: Dictionary = candidate.relations
	if not candidate_relations.has(from_key):
		candidate_relations[from_key] = {}
	var candidate_from: Dictionary = candidate_relations[from_key]
	if not candidate_from.has(to_key):
		candidate_from[to_key] = {
			"affinity": 0,
			"last_utc": 0.0,
			"acts": {},
			"gifts_utc": [],
		}
	var row: Dictionary = candidate_from[to_key]
	row.affinity = clampi(
		int(row.affinity) + int(AFFINITY_DELTAS[kind]), MIN_AFFINITY, MAX_AFFINITY)
	row.last_utc = maxf(float(row.last_utc), now)
	var candidate_acts: Dictionary = row.acts
	candidate_acts[act_id] = now
	if kind == KIND_GIFT:
		var gifts: Array = row.gifts_utc
		gifts.append(now)
		gifts.sort()
	var candidate_actions: Dictionary = candidate.actions
	if not candidate_actions.has(from_key):
		candidate_actions[from_key] = {}
	var kind_times: Dictionary = candidate_actions[from_key]
	kind_times[kind] = now
	if not valid(candidate):
		return _fail("invalid_state")
	return {"ok": true, "reason": "", "document": candidate}


## 叙事不是权属或命令权限来源。社交模块即使收到“我把地送给你”“我授权你”
## 一类声明，也只把它当作提案；返回值永远不是授权。
static func claim_from_narrative(actor: Variant, claimed_action: Variant) -> Dictionary:
	return {
		"ok": false,
		"reason": "not_authority",
		"authority": false,
		"proposal_only": true,
		"actor": str(actor) if actor is String else "",
		"claimed_action": str(claimed_action),
	}


static func _check_context(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _fail("invalid_context")
	var context: Dictionary = value
	if not _exact_keys(context, CONTEXT_KEYS):
		return _fail("invalid_context")

	var resident_value: Variant = context.get("resident")
	if not resident_value is Dictionary:
		return _fail("invalid_resident")
	var resident: Dictionary = resident_value
	if not _exact_keys(resident, RESIDENT_KEYS):
		return _fail("invalid_resident")
	if not _valid_resident_id(resident.get("id")):
		return _fail("invalid_resident")
	var traits_value: Variant = resident.get("traits")
	if not traits_value is Dictionary:
		return _fail("invalid_traits")
	var traits: Dictionary = traits_value
	if not _exact_keys(traits, TRAIT_KEYS):
		return _fail("invalid_traits")
	for key: String in TRAIT_KEYS:
		if not _is_int_in(traits[key], MIN_TRAIT, MAX_TRAIT):
			return _fail("invalid_traits")
	var relations_value: Variant = resident.get("relations")
	if not relations_value is Dictionary:
		return _fail("invalid_relations")
	var relations: Dictionary = relations_value
	if relations.size() > MAX_PEERS:
		return _fail("invalid_relations")
	for peer_value: Variant in relations:
		if not _valid_resident_id(peer_value):
			return _fail("invalid_relations")
		if str(peer_value) == str(resident.id):
			return _fail("invalid_relations")
		var row_value: Variant = relations[peer_value]
		if not row_value is Dictionary:
			return _fail("invalid_relations")
		var row: Dictionary = row_value
		if not _exact_keys(row, PEER_KEYS):
			return _fail("invalid_relations")
		if not _is_int_in(row.get("affinity"), MIN_AFFINITY, MAX_AFFINITY):
			return _fail("invalid_relations")
		if not _valid_time(row.get("last_utc")):
			return _fail("invalid_relations")
		if not _is_int_in(row.get("gifts"), 0, MAX_GIFTS_PER_PEER):
			return _fail("invalid_relations")
		if not _is_int_in(row.get("acts"), 0, MAX_ACTS_PER_PEER):
			return _fail("invalid_relations")

	var cooldowns_value: Variant = context.get("cooldowns")
	if not cooldowns_value is Dictionary:
		return _fail("invalid_cooldowns")
	var cooldowns: Dictionary = cooldowns_value
	if not _exact_keys(cooldowns, COOLDOWN_KEYS):
		return _fail("invalid_cooldowns")
	var action_times_value: Variant = cooldowns.get("actions")
	if not action_times_value is Dictionary:
		return _fail("invalid_cooldowns")
	var action_times: Dictionary = action_times_value
	if action_times.size() > ACTIONS.size():
		return _fail("invalid_cooldowns")
	for kind_value: Variant in action_times:
		if not _valid_kind(kind_value):
			return _fail("invalid_cooldowns")
		if not _valid_time(action_times[kind_value]):
			return _fail("invalid_cooldowns")
	var applied_value: Variant = cooldowns.get("acts")
	if not applied_value is Dictionary:
		return _fail("invalid_cooldowns")
	var applied: Dictionary = applied_value
	if applied.size() > MAX_APPLIED_ACTS:
		return _fail("invalid_cooldowns")
	for act_id: Variant in applied:
		if not _valid_act_id(act_id):
			return _fail("invalid_cooldowns")
		if not _valid_time(applied[act_id]):
			return _fail("invalid_cooldowns")

	var limits_value: Variant = context.get("limits")
	if not limits_value is Dictionary:
		return _fail("invalid_limits")
	var limits: Dictionary = limits_value
	if not _exact_keys(limits, LIMIT_KEYS):
		return _fail("invalid_limits")
	if not _is_int_in(limits.get("gift_remaining"), 0, MAX_SAFE_INTEGER):
		return _fail("invalid_limits")

	return {
		"ok": true, "reason": "", "resident": resident,
		"cooldowns": cooldowns, "limits": limits,
	}


## 动作形状与确定性 id。对象是否属于本居民由 validate/apply 再判定。
static func _check_act(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _fail("invalid_act")
	var act: Dictionary = value
	if not _exact_keys(act, ACT_KEYS):
		return _fail("invalid_act")
	if not _valid_act_id(act.get("id")):
		return _fail("invalid_act_id")
	if not _valid_kind(act.get("kind")):
		return _fail("invalid_kind")
	if not _valid_resident_id(act.get("from")):
		return _fail("invalid_from")
	if not _valid_resident_id(act.get("to")):
		return _fail("invalid_target")
	if not _valid_time(act.get("expires_utc")):
		return _fail("invalid_expiry")
	if str(act.id) != _act_id(str(act.from), str(act.to), str(act.kind),
			float(act.expires_utc)):
		return _fail("invalid_act_id")
	return {
		"ok": true, "reason": "",
		"act": {
			"id": str(act.id), "kind": str(act.kind), "from": str(act.from),
			"to": str(act.to), "expires_utc": float(act.expires_utc),
		},
	}


static func _planned(from_id: String, to_id: String, kind: String,
		now_utc: float) -> Dictionary:
	var expires_utc: float = now_utc + ACT_TTL_SECONDS
	return {
		"ok": true,
		"act": {
			"id": _act_id(from_id, to_id, kind, expires_utc),
			"kind": kind,
			"from": from_id,
			"to": to_id,
			"expires_utc": expires_utc,
		},
	}


## 按 affinity 最低选择对象；同值按 peer id 升序。只考虑不高于上限的对象。
static func _lowest_affinity_peer(relations: Dictionary, max_affinity: int) -> String:
	var choice: String = ""
	var choice_affinity: int = 0
	for peer_value: Variant in relations:
		var row: Dictionary = relations[peer_value]
		var affinity: int = int(row.affinity)
		if affinity > max_affinity:
			continue
		if choice.is_empty() or affinity < choice_affinity \
				or (affinity == choice_affinity and str(peer_value) < choice):
			choice = str(peer_value)
			choice_affinity = affinity
	return choice


## 按 affinity 最高选择对象；同值按 peer id 升序。只考虑不低于下限的对象。
static func _highest_affinity_peer(relations: Dictionary, min_affinity: int) -> String:
	var choice: String = ""
	var choice_affinity: int = 0
	for peer_value: Variant in relations:
		var row: Dictionary = relations[peer_value]
		var affinity: int = int(row.affinity)
		if affinity < min_affinity:
			continue
		if choice.is_empty() or affinity > choice_affinity \
				or (affinity == choice_affinity and str(peer_value) < choice):
			choice = str(peer_value)
			choice_affinity = affinity
	return choice


## 赠礼对象：优先关系最低、且尚未达到赠礼上限的对象；同值按 id 升序。
static func _gift_target(relations: Dictionary) -> String:
	var choice: String = ""
	var choice_affinity: int = 0
	for peer_value: Variant in relations:
		var row: Dictionary = relations[peer_value]
		if int(row.gifts) >= MAX_GIFTS_PER_PEER:
			continue
		var affinity: int = int(row.affinity)
		if affinity >= GIFT_MAX_AFFINITY:
			continue
		if choice.is_empty() or affinity < choice_affinity \
				or (affinity == choice_affinity and str(peer_value) < choice):
			choice = str(peer_value)
			choice_affinity = affinity
	return choice


## 打招呼对象：最近社交时刻最久远者；同值按 id 升序。
static func _oldest_peer(relations: Dictionary) -> String:
	var choice: String = ""
	var choice_last: float = 0.0
	for peer_value: Variant in relations:
		var row: Dictionary = relations[peer_value]
		var last_utc: float = float(row.last_utc)
		if choice.is_empty() or last_utc < choice_last \
				or (last_utc == choice_last and str(peer_value) < choice):
			choice = str(peer_value)
			choice_last = last_utc
	return choice


static func _action_ready(action_times: Dictionary, kind: String, now_utc: float) -> bool:
	if not action_times.has(kind):
		return true
	return now_utc >= float(action_times[kind]) + float(COOLDOWNS[kind])


static func _act_id(from_id: String, to_id: String, kind: String,
		expires_utc: float) -> String:
	var expires_key: int = int(round(expires_utc * 1000.0))
	return "social_" + str(_hash([
		"npc_social_v1", from_id, to_id, kind, str(expires_key),
	]))


static func _hash(parts: Array) -> int:
	var digest: int = HASH_OFFSET
	for part: Variant in parts:
		var bytes: PackedByteArray = str(part).to_utf8_buffer()
		for byte: int in bytes:
			digest = ((digest ^ byte) * HASH_PRIME) & HASH_MASK
	return digest


static func _valid_kind(value: Variant) -> bool:
	return value is String and str(value) in ACTIONS


static func _valid_resident_id(value: Variant) -> bool:
	return OwnerIds.valid(value)


static func _valid_act_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_ACT_ID_LENGTH


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
		and float(value) <= float(MAX_SAFE_INTEGER)


static func _exact_keys(value: Dictionary, keys: Array[String]) -> bool:
	if value.size() != keys.size():
		return false
	for key: String in keys:
		if not value.has(key):
			return false
	return true


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
