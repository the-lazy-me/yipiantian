extends RefCounted
## M10-03 意图执行账本（纯规则切片）。不读系统时钟、不碰磁盘、场景、网络或
## `FarmState`；所有入口显式接收 `now_utc`，同一输入得到同一输出。
##
## 文档形状：
##
##   {
##     "until_utc": 0.0,                         # 居民下次可行动时刻；0 表示可用
##     "intents": {"intent_xxx": 1800000000.0},  # 已消费意图 id -> 消费时刻
##   }
##
## 与 `npc_intent.gd` 的只读上下文 `cooldowns` 同形，调用方可以直接把本账本
## 投影进意图校验，不需要转换字段。
##
## 不变式：每条消费记录的消费时刻不大于 `until_utc`，即账本不会记录“冷却结束
## 前就消费”的历史；`valid()` 强制该约束，`record()` 只生成满足它的候选文档。
##
## 记录有界：最多 `MAX_RECORDS` 条，满额时按消费时刻淘汰最旧的一条；消费时刻
## 相同则按 id 升序淘汰，保证淘汰结果与字典遍历顺序无关。由于 `record()` 要求
## 新消费时刻不小于 `until_utc`，而 `valid()` 要求历史时刻不大于 `until_utc`，
## 新记录总是最新的，不会被本次淘汰，文档不会无限增长。

const MAX_RECORDS: int = 256
const MAX_ID_LENGTH: int = 128
const MAX_SAFE_INTEGER: int = 9007199254740991
const STATE_KEYS: Array[String] = ["until_utc", "intents"]


static func empty_state() -> Dictionary:
	return {"until_utc": 0.0, "intents": {}}


## 严格文档校验：恰好两个已知键、时间在安全范围内、id 是非空有界字符串，
## 且每条消费时刻不晚于 `until_utc`。未知键一律拒绝，避免旧权威静默丢掉新字段。
static func valid(state: Variant) -> bool:
	if not state is Dictionary or (state as Dictionary).size() != STATE_KEYS.size():
		return false
	var document: Dictionary = state
	for key: String in STATE_KEYS:
		if not document.has(key):
			return false
	if not _valid_time(document.until_utc):
		return false
	if not document.intents is Dictionary:
		return false
	var intents: Dictionary = document.intents
	if intents.size() > MAX_RECORDS:
		return false
	for intent_id: Variant in intents:
		if not _valid_intent_id(intent_id):
			return false
		if not _valid_time(intents[intent_id]):
			return false
		if float(intents[intent_id]) > float(document.until_utc):
			return false
	return true


## 冷却判定。`cooling` 为真表示 `now_utc` 早于居民下次可行动时刻。文档或时间
## 不合法时按保守方向失败关闭（`cooling: true`），调用方应先看 `ok`。
static func cooling(state: Variant, now_utc: float) -> Dictionary:
	if not valid(state):
		return {"ok": false, "reason": "invalid_state", "cooling": true, "until_utc": 0.0}
	if not _valid_time(now_utc):
		return {"ok": false, "reason": "invalid_time", "cooling": true, "until_utc": 0.0}
	var document: Dictionary = state
	return {
		"ok": true,
		"reason": "",
		"cooling": float(now_utc) < float(document.until_utc),
		"until_utc": float(document.until_utc),
	}


## 记录一次成功消费，返回候选文档而不修改输入。拒绝顺序：文档不合法、时间不
## 合法、id 不合法、居民仍在冷却、新冷却时刻倒退或早于本次消费、id 已消费。
## `until_utc` 是本次消费后的下次可行动时刻，必须不小于 `at_utc` 和文档原值。
static func record(state: Variant, intent_id: Variant, at_utc: float,
		until_utc: float) -> Dictionary:
	if not valid(state):
		return _fail("invalid_state")
	var document: Dictionary = state
	if not _valid_time(at_utc) or not _valid_time(until_utc):
		return _fail("invalid_time")
	if not _valid_intent_id(intent_id):
		return _fail("invalid_intent")
	if float(at_utc) < float(document.until_utc):
		return _fail("cooldown")
	if float(until_utc) < float(at_utc) or float(until_utc) < float(document.until_utc):
		return _fail("invalid_cooldown")
	if document.intents.has(intent_id):
		return _fail("duplicate_intent")
	var candidate: Dictionary = document.duplicate(true)
	candidate.intents[str(intent_id)] = float(at_utc)
	candidate.until_utc = float(until_utc)
	while candidate.intents.size() > MAX_RECORDS:
		candidate.intents.erase(_oldest_key(candidate.intents))
	return {"ok": true, "reason": "", "state": candidate}


## JSON 数字到达时都是 float；在严格校验之后归一，让内存文档保持写入时的形状。
static func normalize(state: Dictionary) -> void:
	state.until_utc = float(state.get("until_utc", 0.0))
	var intents: Variant = state.get("intents")
	if not intents is Dictionary:
		return
	for intent_id: Variant in intents:
		(intents as Dictionary)[intent_id] = float(intents[intent_id])


## 最早消费的 id；同一时刻按 id 升序取第一个，避免依赖字典遍历顺序。
static func _oldest_key(intents: Dictionary) -> String:
	var oldest_id: String = ""
	var oldest_time: float = 0.0
	for intent_id: Variant in intents:
		var key: String = str(intent_id)
		var at_utc: float = float(intents[intent_id])
		if oldest_id.is_empty() or at_utc < oldest_time \
				or (at_utc == oldest_time and key < oldest_id):
			oldest_id = key
			oldest_time = at_utc
	return oldest_id


static func _valid_intent_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_ID_LENGTH


static func _valid_time(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	return is_finite(float(value)) and float(value) >= 0.0 \
		and float(value) <= float(MAX_SAFE_INTEGER)


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
