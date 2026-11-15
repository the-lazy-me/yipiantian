extends RefCounted
## M10-04 居民角色权限矩阵：商人、银行家、官员。
##
## 纯规则模块：不读 RNG、系统时钟、磁盘、场景或网络，不持有或修改任何文档，
## 也不实现记账。它只回答一个前置问题——某个居民角色是否被允许提交某一类
## 既有 `FarmCommand`，以及单笔与窗口内的累计数量是否越界。
##
## 与 ADR-019 的边界：命令的付款人、借款人、订单所有者只能由权威从连接解析
## 并作为 `actor` 绑定。本模块不接受、不校验任何身份字段，角色不等于连接身份，
## 也不能绕过 `WorldHost` / `FarmCommand` 的连接路径。这里只做角色动作准入，
## 余额、订单、合同和权属仍由既有经济规则处理。
##
## 模型与叙事不是权限来源：`claim_from_narrative()` 永远返回 `not_authority`。
## 叙事只能是一份提案，不能授予权属、账户、职位或命令权限。

const FarmCommand = preload("res://farm/farm_command.gd")
const Roster = preload("res://npc/npc_roster.gd")

const MERCHANT: String = "merchant"
const BANKER: String = "banker"
const OFFICIAL: String = "official"
const ROLE_NAMES: Array[String] = [MERCHANT, BANKER, OFFICIAL]

## 三人名册的职务是设定常量，不是随机结果，也不是模型输出：阿舟在渡口迎来
## 送往，负责交易；许伯在竹汀记账理息，掌管钱庄；林婶在柳岸辈分最高，承担
## 调解与公共事务。角色只表达可提交的动作范围，不改变居民的性格或记忆。
const RESIDENT_ROLES: Dictionary = {
	Roster.NPC_A_ZHOU: MERCHANT,
	Roster.NPC_XU_BO: BANKER,
	Roster.NPC_LIN_SHEN: OFFICIAL,
}

## 白名单只引用 `FarmCommand` 的既有常量，未知 kind 一律拒绝。
##
## - `market_deliver` 是权威扫描，不是居民动作；
## - `loan_borrow` / `loan_repay` 是借款人本人的合同路径，规则银行没有
##   “由银行家代发贷款”的命令，因此不由这三种角色发起；
## - 官员的公共事务在当前命令集里只有 `pay` 与 `gift` 可表达；纠纷、组织
##   等治理命令不在本切片范围内，不能凭空发明 kind。
const ROLE_KINDS: Dictionary = {
	MERCHANT: [
		FarmCommand.ACCOUNT_OPEN,
		FarmCommand.PAY,
		FarmCommand.MARKET_OPEN,
		FarmCommand.MARKET_PLACE,
		FarmCommand.MARKET_CANCEL,
		FarmCommand.MARKET_SHIP,
	],
	BANKER: [
		FarmCommand.ACCOUNT_OPEN,
		FarmCommand.PAY,
		FarmCommand.BANK_OPEN,
	],
	OFFICIAL: [
		FarmCommand.ACCOUNT_OPEN,
		FarmCommand.PAY,
		FarmCommand.GIFT,
	],
}

## 单笔上限与周期累计上限。`amount` 是命令的主数量：付款/借款按 COIN，市场
## 与礼物按商品数量；无金额动作（开户、开市、开业、撤单）传 0。数值是当前
## 切片的显式规则，不读商人现金、库存或成交历史。银行家单笔上限与 ADR-017
## 的单笔本金上限对齐，便于以后把同一数值接到贷款路径。
const CALL_LIMITS: Dictionary = {
	MERCHANT: 200,
	BANKER: 1000,
	OFFICIAL: 100,
}
const WINDOW_LIMITS: Dictionary = {
	MERCHANT: 800,
	BANKER: 2000,
	OFFICIAL: 300,
}

## 窗口只按调用者传入的 `now_utc` 做确定性分桶，不读系统时钟。累计值
## `spent_in_window` 也由调用者按同一窗口键统计；本模块不保存窗口状态。
const WINDOW_HOUR: String = "hour"
const WINDOW_DAY: String = "day"
const WINDOWS: Dictionary = {
	WINDOW_HOUR: 3600,
	WINDOW_DAY: 86400,
}

const MAX_SAFE_INTEGER: int = 9007199254740991


## 报告居民担任的角色；未知居民返回空串。
static func role_of(resident_id: Variant) -> String:
	if not resident_id is String:
		return ""
	return str(RESIDENT_ROLES.get(resident_id, ""))


## 报告角色由哪位居民担任；未知角色返回空串。与 `role_of()` 互为反查，名册
## 映射因此可以从任一侧核对。
static func resident_of(role: Variant) -> String:
	if not _valid_role(role):
		return ""
	for resident_id: String in RESIDENT_ROLES:
		if str(RESIDENT_ROLES[resident_id]) == str(role):
			return resident_id
	return ""


## 返回角色的命令白名单副本。未知角色返回空数组；调用者修改返回值不会改变
## 规则表。
static func allowed_kinds(role: Variant) -> Array[String]:
	var kinds: Array[String] = []
	if not _valid_role(role):
		return kinds
	for kind: Variant in ROLE_KINDS[str(role)]:
		kinds.append(str(kind))
	return kinds


## 角色的单笔上限；未知角色返回 0，便于调用者显式拒绝。
static func call_limit(role: Variant) -> int:
	if not _valid_role(role):
		return 0
	return int(CALL_LIMITS[str(role)])


## 角色的周期累计上限；未知角色返回 0。
static func window_limit(role: Variant) -> int:
	if not _valid_role(role):
		return 0
	return int(WINDOW_LIMITS[str(role)])


## 角色动作准入。它只回答“这个居民角色可否提交这类命令、数量是否在界限内”，
## 不做身份解析、不校验完整命令载荷、不改任何状态。调用者必须先把连接身份
## 解析为 `actor`，再调用本入口；即使这里返回 ok，也不构成权属或余额证明。
##
## 判定顺序固定：unknown_role → forbidden_kind → invalid_amount →
## invalid_time → unknown_window → limit_per_call → limit_window。
static func may_submit(role: Variant, command_kind: Variant, amount: Variant,
		spent_in_window: Variant, now_utc: Variant, window: Variant) -> Dictionary:
	if not _valid_role(role):
		return _refused("unknown_role")
	if not command_kind is String or not str(command_kind) in FarmCommand.KINDS:
		return _refused("forbidden_kind")
	var kind: String = str(command_kind)
	if not allowed_kinds(role).has(kind):
		return _refused("forbidden_kind")
	if not _valid_amount(amount) or not _valid_amount(spent_in_window):
		return _refused("invalid_amount")
	if not _valid_time(now_utc):
		return _refused("invalid_time")
	var bucket: Dictionary = window_bucket(now_utc, window)
	if not bool(bucket.ok):
		return _refused(str(bucket.reason))
	var amount_value: int = int(amount)
	var spent_value: int = int(spent_in_window)
	var per_call: int = call_limit(role)
	if amount_value > per_call:
		return _refused("limit_per_call")
	var cumulative: int = window_limit(role)
	# 先判断 spent 本身越界，再用减法比较，避免两个大整数相加溢出安全范围。
	if spent_value > cumulative or amount_value > cumulative - spent_value:
		return _refused("limit_window")
	return {
		"ok": true,
		"reason": "",
		"role": str(role),
		"kind": kind,
		"bucket": int(bucket.bucket),
		"remaining": cumulative - spent_value - amount_value,
	}


## 把 `now_utc` 按窗口长度确定性分桶。同一时刻与窗口总得到同一桶号；跨过窗口
## 边界时桶号递增。它只是给调用者的窗口键，不保存任何累计值。
static func window_bucket(now_utc: Variant, window: Variant) -> Dictionary:
	if not _valid_time(now_utc):
		return {"ok": false, "reason": "invalid_time", "bucket": -1}
	if not _valid_window(window):
		return {"ok": false, "reason": "unknown_window", "bucket": -1}
	var seconds: int = int(WINDOWS[str(window)])
	return {
		"ok": true,
		"reason": "",
		"bucket": int(floorf(float(now_utc) / float(seconds))),
	}


## 模型或叙事声称自己拥有某种权属、职位或命令权限时，规则一律拒绝。无论
## 角色是否存在、声明什么动作，返回值都只表示“这是提案，不是授权”。
static func claim_from_narrative(role: Variant, claimed_action: Variant) -> Dictionary:
	var role_text: String = str(role) if role is String else ""
	return {
		"ok": false,
		"reason": "not_authority",
		"authority": false,
		"proposal_only": true,
		"role": role_text,
		"claimed_action": str(claimed_action),
	}


static func _refused(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


static func _valid_role(value: Variant) -> bool:
	return value is String and str(value) in ROLE_NAMES


## 数量必须是非负整数；JSON 往返会把整数读成浮点，因此容许整值浮点。无金额
## 动作传 0，负数和 fractional 值都拒绝。
static func _valid_amount(value: Variant) -> bool:
	if not value is int and not value is float:
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)


static func _valid_time(value: Variant) -> bool:
	if not value is int and not value is float:
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER)


static func _valid_window(value: Variant) -> bool:
	return value is String and str(value) in WINDOWS
