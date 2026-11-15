extends RefCounted
## M11-03 规则决议效果纯规则切片：税费预告与公共建设固定系数。
## 纯规则：不读 RNG、系统时钟、磁盘、场景或网络；时刻由调用方显式传入，
## 所有成功写入返回候选文档，输入不被修改。
##
## 效果只从“已生效且已登记应用”的决议推导：
## - 决议状态必须是 effective，且通过 `ResolutionState.is_effective_at()`
##   在给定时刻有效。未生效、已撤销、未到生效时刻或未登记的决议不产生效果。
## - `apply()` 把一条决议的生效版本登记一次；版本水位以下的版本视为已应用，
##   同一版本不会产生第二次效果。
## - 税费只按“未来收入”计算，返回税额与净额，绝不从既有余额追溯扣除。
##   设计文档要求税费先预告：`tax_rate()` 给出费率，`tax_for()` 给出单笔结果。
## - 公共建设只提供可枚举的固定折减系数，同类效果不按决议条数堆叠，不做
##   通用公式引擎。
##
## 文档形状：
##   {
##     "applied_version": 0,
##     "applied": [
##       {"resolution_id": "<id>", "version": 1,
##        "kind": "public_works" | "tax", "at_utc": 1800000000.0},
##     ],
##   }
##
## `applied` 是有界应用记录，最多 `MAX_APPLIED` 行；超过时按 `at_utc`、再按
## 版本号淘汰最旧的一行。`applied_version` 是应用水位：不大于它的生效版本
## 都视为已经应用，因此记录被淘汰后重放旧命令也不会重复生效。效果文档与决议
## 文档必须一致：水位不超过决议规则版本，仍保留的每条记录都要对应决议行上
## 相同的类型和生效版本；不一致按 `invalid_state` 拒绝。

const ResolutionState = preload("res://world/resolution_state.gd")
const OwnerIds = preload("res://farm/owner_id.gd")

## 费率统一使用整数比例，除以 1000，避免浮点记账。
const PERMILLE_SCALE: int = 1000
## 每条已生效的税费决议增加的费率，以及合计上限。
const TAX_STEP_PERMILLE: int = 10
const MAX_TAX_PERMILLE: int = 200

## 公共建设只开放两个可解释的固定系数：公共项目相关支出折减与灾害损失折减。
## 只要有一条已生效的公共建设决议，两项系数同时生效；多条不叠加。
const EFFECT_PUBLIC_WORKS_EXPENSE: String = "public_works_expense"
const EFFECT_DISASTER_LOSS: String = "disaster_loss"
const COEFFICIENTS: Dictionary = {
	EFFECT_PUBLIC_WORKS_EXPENSE: 100,
	EFFECT_DISASTER_LOSS: 50,
}
const EFFECT_KINDS: Array[String] = [
	EFFECT_PUBLIC_WORKS_EXPENSE, EFFECT_DISASTER_LOSS,
]
## 系数上界只用于文档与常量自检，正常推导不会超过它。
const MAX_COEFFICIENT_PERMILLE: int = 500

## 单笔未来收入上限；税额用 64 位整数计算，远离安全整数上界。
const MAX_AMOUNT: int = 1_000_000_000_000
const MAX_APPLIED: int = 64
const MAX_SAFE_INTEGER: int = 9007199254740991

const STATE_KEYS: Array[String] = ["applied_version", "applied"]
const APPLIED_KEYS: Array[String] = [
	"resolution_id", "version", "kind", "at_utc",
]


## 没有应用记录时的初始文档。
static func empty() -> Dictionary:
	return {"applied_version": 0, "applied": []}


## 登记一条已生效决议的效果。版本水位以下的版本返回 `already_applied`；
## 未生效或已撤销返回 `not_active`；未到生效时刻返回 `not_effective`。
## 成功后追加一条有界记录并推进水位，记录超限时淘汰最旧一行。
static func apply(state: Dictionary, resolutions: Dictionary, resolution_id: Variant,
		now_utc: float) -> Dictionary:
	if not valid(state) or not ResolutionState.valid(resolutions) \
			or not consistent(state, resolutions):
		return _error("invalid_state")
	if not _valid_resolution_id(resolution_id):
		return _error("invalid_resolution")
	var row_value: Variant = _resolution_or_null(resolutions, str(resolution_id))
	if not row_value is Dictionary:
		return _error("unknown_resolution")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	var row: Dictionary = row_value
	if str(row.get("status")) != ResolutionState.STATUS_EFFECTIVE:
		return _error("not_active")
	if now_utc < float(row.get("effective_utc")):
		return _error("not_effective")
	var version: int = int(row.get("effective_version"))
	if version <= int(state.get("applied_version")):
		return _error("already_applied")
	var candidate: Dictionary = state.duplicate(true)
	candidate["applied"].append({
		"resolution_id": str(resolution_id),
		"version": version,
		"kind": str(row.get("kind")),
		"at_utc": now_utc,
	})
	while candidate["applied"].size() > MAX_APPLIED:
		candidate["applied"].remove_at(_oldest_index(candidate["applied"]))
	candidate["applied_version"] = version
	return _success(candidate)


## 只读税费费率，供规则预告使用。只有已应用且在该时刻有效的税费决议计入；
## 合计超过 `MAX_TAX_PERMILLE` 时以 `over_rate` 拒绝，不做静默截断。
static func tax_rate(state: Dictionary, resolutions: Dictionary, at_utc: float) -> Dictionary:
	if not valid(state) or not ResolutionState.valid(resolutions) \
			or not consistent(state, resolutions):
		return _error("invalid_state")
	if not _valid_time(at_utc):
		return _error("invalid_time")
	var rate: int = _tax_permille(state, resolutions, at_utc)
	if rate > MAX_TAX_PERMILLE:
		return _over_rate(rate)
	return {"ok": true, "reason": "", "rate_permille": rate}


## 给定一笔未来收入，返回费率、税额与净额。税额向下取整到整数金额单位；
## 本函数不读取也不修改任何既有余额，调用方负责只在未来收入上扣取。
static func tax_for(state: Dictionary, resolutions: Dictionary, amount: Variant,
		at_utc: float) -> Dictionary:
	if not valid(state) or not ResolutionState.valid(resolutions) \
			or not consistent(state, resolutions):
		return _error("invalid_state")
	if not _valid_time(at_utc):
		return _error("invalid_time")
	var value: int = _whole_number(amount)
	if value < 0:
		return _error("invalid_amount")
	if value > MAX_AMOUNT:
		return _error("amount_limit")
	var rate: int = _tax_permille(state, resolutions, at_utc)
	if rate > MAX_TAX_PERMILLE:
		return _over_rate(rate)
	var tax: int = value * rate / PERMILLE_SCALE
	return {
		"ok": true, "reason": "", "rate_permille": rate,
		"amount": value, "tax": tax, "net": value - tax,
	}


## 只读公共建设系数。未知效果类型返回 `unknown_kind`；没有已应用且在该时刻
## 有效的公共建设决议时系数为 0。系数按类型固定，不随决议条数叠加。
static func coefficient_for(state: Dictionary, resolutions: Dictionary, kind: Variant,
		at_utc: float) -> Dictionary:
	if not valid(state) or not ResolutionState.valid(resolutions) \
			or not consistent(state, resolutions):
		return _error("invalid_state")
	if not kind is String or not EFFECT_KINDS.has(str(kind)):
		return _error("unknown_kind")
	if not _valid_time(at_utc):
		return _error("invalid_time")
	var permille: int = 0
	if _has_public_works(state, resolutions, at_utc):
		permille = int(COEFFICIENTS[str(kind)])
	return {"ok": true, "reason": "", "kind": str(kind), "permille": permille}


## 严格文档校验：键集精确、水位与版本是非负整数、记录数有上限、记录按版本
## 严格递增且不超过水位、id 与类型合法、时刻合法。决议文档一致性由
## `consistent()` 在命令入口另外检查。
static func valid(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var document: Dictionary = value
	if not _exact_keys(document, STATE_KEYS):
		return false
	if not _valid_count(document.get("applied_version")):
		return false
	var applied_value: Variant = document.get("applied")
	if not applied_value is Array:
		return false
	var applied: Array = applied_value
	if applied.size() > MAX_APPLIED:
		return false
	var applied_version: int = int(document.get("applied_version"))
	var previous_version: int = 0
	for entry_value: Variant in applied:
		if not entry_value is Dictionary:
			return false
		var entry: Dictionary = entry_value
		if not _exact_keys(entry, APPLIED_KEYS):
			return false
		if not _valid_resolution_id(entry.get("resolution_id")):
			return false
		if not _valid_record_kind(entry.get("kind")):
			return false
		if not _valid_time_value(entry.get("at_utc")):
			return false
		if not _valid_count(entry.get("version")):
			return false
		var version: int = int(entry.get("version"))
		if version < 1 or version <= previous_version or version > applied_version:
			return false
		previous_version = version
	return true


## 合计已应用且在该时刻有效的税费决议。只遍历显式应用记录：记录被容量淘汰
## 的旧决议不再计入，这是有界文档的既定安排。调用方必须已通过一致性检查。
static func _tax_permille(state: Dictionary, resolutions: Dictionary, at_utc: float) -> int:
	var rate: int = 0
	var table: Dictionary = resolutions.get("resolutions")
	for entry_value: Variant in state.get("applied"):
		var entry: Dictionary = entry_value
		if str(entry.get("kind")) != ResolutionState.KIND_TAX:
			continue
		var resolution_id: String = str(entry.get("resolution_id"))
		if not ResolutionState.is_effective_at(resolutions, resolution_id, at_utc):
			continue
		var row: Dictionary = table[resolution_id]
		if int(row.get("effective_version")) != int(entry.get("version")):
			continue
		rate += TAX_STEP_PERMILLE
	return rate


## 是否存在已应用且在该时刻有效的公共建设决议。
static func _has_public_works(state: Dictionary, resolutions: Dictionary,
		at_utc: float) -> bool:
	var table: Dictionary = resolutions.get("resolutions")
	for entry_value: Variant in state.get("applied"):
		var entry: Dictionary = entry_value
		if str(entry.get("kind")) != ResolutionState.KIND_PUBLIC_WORKS:
			continue
		var resolution_id: String = str(entry.get("resolution_id"))
		if not ResolutionState.is_effective_at(resolutions, resolution_id, at_utc):
			continue
		var row: Dictionary = table[resolution_id]
		if int(row.get("effective_version")) == int(entry.get("version")):
			return true
	return false


## 效果文档与决议文档必须一致：水位不超过规则版本；仍保留的每条记录都要
## 对应同一决议行上相同的类型和生效版本。
static func consistent(state: Dictionary, resolutions: Dictionary) -> bool:
	if int(state.get("applied_version")) > int(resolutions.get("rules_version")):
		return false
	var table: Dictionary = resolutions.get("resolutions")
	var applied: Array = state.get("applied")
	for entry_value: Variant in applied:
		var entry: Dictionary = entry_value
		var resolution_id: String = str(entry.get("resolution_id"))
		if not table.has(resolution_id):
			return false
		var row_value: Variant = table[resolution_id]
		if not row_value is Dictionary:
			return false
		var row: Dictionary = row_value
		if str(row.get("kind")) != str(entry.get("kind")):
			return false
		if int(row.get("effective_version")) != int(entry.get("version")):
			return false
	return true


## 应用记录最旧一行的下标：先比时刻，再比版本号，最后比位置，保证确定性。
static func _oldest_index(applied: Array) -> int:
	var index: int = 0
	var best_time: float = float(applied[0]["at_utc"])
	var best_version: int = int(applied[0]["version"])
	for candidate: int in range(1, applied.size()):
		var row: Dictionary = applied[candidate]
		var at_utc: float = float(row["at_utc"])
		var version: int = int(row["version"])
		if at_utc < best_time or (at_utc == best_time and version < best_version):
			index = candidate
			best_time = at_utc
			best_version = version
	return index


static func _resolution_or_null(resolutions: Dictionary, resolution_id: String) -> Variant:
	var table: Variant = resolutions.get("resolutions")
	if not table is Dictionary:
		return null
	return (table as Dictionary).get(resolution_id)


static func _success(candidate: Dictionary) -> Dictionary:
	return {"ok": true, "reason": "", "state": candidate}


static func _error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


static func _over_rate(rate: int) -> Dictionary:
	return {
		"ok": false, "reason": "over_rate", "rate_permille": rate,
		"limit": MAX_TAX_PERMILLE,
	}


static func _exact_keys(value: Dictionary, keys: Array[String]) -> bool:
	if value.size() != keys.size():
		return false
	for key: String in keys:
		if not value.has(key):
			return false
	return true


static func _valid_resolution_id(value: Variant) -> bool:
	return value is String and OwnerIds.valid(value)


## 应用记录保存的是决议类型，不是效果类型。
static func _valid_record_kind(value: Variant) -> bool:
	return value is String and ResolutionState.KINDS.has(str(value))


static func _valid_time(value: float) -> bool:
	return is_finite(value) and value >= 0.0 and value <= float(MAX_SAFE_INTEGER)


static func _valid_time_value(value: Variant) -> bool:
	if value is int:
		return int(value) >= 0 and int(value) <= MAX_SAFE_INTEGER
	if value is float:
		return is_finite(float(value)) and float(value) >= 0.0 \
			and float(value) <= float(MAX_SAFE_INTEGER)
	return false


## JSON 往返会把整数读成浮点，因此容许整值浮点，但拒绝小数、负数、非有限值
## 与字符串。返回 -1 表示非法。
static func _whole_number(value: Variant) -> int:
	if not value is int and not value is float:
		return -1
	var number: float = float(value)
	if not is_finite(number) or number != floorf(number):
		return -1
	if number < 0.0 or number > float(MAX_SAFE_INTEGER):
		return -1
	return int(number)


static func _valid_count(value: Variant) -> bool:
	if not value is int and not value is float:
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)
