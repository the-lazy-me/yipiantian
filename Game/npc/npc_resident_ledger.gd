extends RefCounted
## M10-03 多居民意图账本文档（纯规则切片）。不读系统时钟、不碰磁盘、场景、
## 网络或 `FarmState`；所有入口显式接收 `now_utc`，同一输入得到同一输出。
##
## 单居民账本 `npc_intent_state.gd` 保持原样，继续服务其他调用方。本模块只把
## 同一形状按名册居民分组，供世界权威一次结算三人时使用：
##
##   {
##     "residents": {
##       "npc_a_zhou": {
##         "until_utc": 0.0,
##         "intents": {"intent_xxx": 1800000000.0},
##       },
##     },
##   }
##
## 每名居民的子文档与 `npc_intent.gd` 的只读上下文 `cooldowns` 同形，可以直接
## 投影进意图校验。只有名册内的 id 可以出现，未知居民一律拒绝；不存在条目的
## 居民按空账本处理，不需要预先写入。
##
## 严格校验：文档恰好一个键 `residents`；居民表最多 `MAX_RESIDENTS` 人；每人
## 子文档交给 `IntentState.valid()`，因此沿用“恰好两键、时间安全、id 有界、
## 最多 256 条、消费时刻不晚于 until_utc”的既有约束。
##
## `record()` 返回候选文档而不修改输入；`cooling()` 只读，返回与单居民账本同形
## 的判定结果。

const IntentState = preload("res://npc/npc_intent_state.gd")
const Roster = preload("res://npc/npc_roster.gd")

const MAX_RESIDENTS: int = 16
const DOCUMENT_KEYS: Array[String] = ["residents"]


static func empty() -> Dictionary:
	return {"residents": {}}


## 严格文档校验。未知键、名册外 id、超过居民上限或任一子文档不合法都拒绝。
static func valid(state: Variant) -> bool:
	if not state is Dictionary or (state as Dictionary).size() != DOCUMENT_KEYS.size():
		return false
	var document: Dictionary = state
	for key: String in DOCUMENT_KEYS:
		if not document.has(key):
			return false
	if not document.residents is Dictionary:
		return false
	var residents: Dictionary = document.residents
	if residents.size() > MAX_RESIDENTS:
		return false
	for npc_id: Variant in residents:
		if not _valid_resident_id(npc_id):
			return false
		if not IntentState.valid(residents[npc_id]):
			return false
	return true


## 某位居民的账本视图。返回深拷贝，调用方无法通过它改动多居民文档；没有条目
## 时返回合法的空账本。名册外 id 返回空字典，调用方应先看 `is_resident()`。
static func state_for(state: Variant, npc_id: String) -> Dictionary:
	if not valid(state) or not _valid_resident_id(npc_id):
		return {}
	var residents: Dictionary = (state as Dictionary).residents
	if residents.get(npc_id) is Dictionary:
		return (residents[npc_id] as Dictionary).duplicate(true)
	return IntentState.empty_state()


## 冷却判定，语义与 `IntentState.cooling()` 一致。文档不合法时失败关闭；
## 名册外 id 返回 `invalid_resident`，同样按冷却处理。
static func cooling(state: Variant, npc_id: String, now_utc: float) -> Dictionary:
	if not valid(state):
		return {"ok": false, "reason": "invalid_state", "cooling": true, "until_utc": 0.0}
	if not _valid_resident_id(npc_id):
		return {"ok": false, "reason": "invalid_resident", "cooling": true, "until_utc": 0.0}
	return IntentState.cooling(state_for(state, npc_id), now_utc)


## 记录一次成功消费，返回 `{ok, reason, document}`。输入文档不变；候选里的居民
## 子文档由 `IntentState.record()` 生成，因此重复、冷却、倒退与时间校验完全复用
## 单居民语义。名册外 id 返回 `invalid_resident`，没有条目的居民从空账本开始。
static func record(state: Variant, npc_id: String, intent_id: Variant, at_utc: float,
		until_utc: float) -> Dictionary:
	if not valid(state):
		return _fail("invalid_state")
	if not _valid_resident_id(npc_id):
		return _fail("invalid_resident")
	var current: Dictionary = state_for(state, npc_id)
	var written: Dictionary = IntentState.record(current, intent_id, at_utc, until_utc)
	if not bool(written.get("ok", false)):
		return _fail(str(written.get("reason", "")))
	var candidate: Dictionary = (state as Dictionary).duplicate(true)
	candidate.residents[npc_id] = written.state
	if not valid(candidate):
		return _fail("invalid_state")
	return {"ok": true, "reason": "", "document": candidate}


## JSON 数字到达时都是 float；在严格校验之后归一子文档，让内存形状与写入一致。
static func normalize(state: Dictionary) -> void:
	var residents: Variant = state.get("residents")
	if not residents is Dictionary:
		return
	for npc_id: Variant in residents:
		if residents[npc_id] is Dictionary:
			IntentState.normalize(residents[npc_id])


static func is_resident(npc_id: Variant) -> bool:
	return _valid_resident_id(npc_id)


static func _valid_resident_id(value: Variant) -> bool:
	return value is String and str(value) in Roster.IDS


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
