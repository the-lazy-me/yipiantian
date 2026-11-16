extends RefCounted
## M8-04 公共基金纯规则切片：组织基金的缴入、负责人支出与换届。
## 纯规则：不读 RNG、系统时钟、磁盘、场景、网络或农场/经济文档；不调用
## `Economy`/`Ledger`，不创建真实账户、不转账、不记分录。所有写入口返回候选
## 文档而不是修改输入。
##
## 文档形状：
##   {
##     "funds": {
##       "fund_<org_id>": {
##         "org_id": "<org_id>",
##         "keeper": "<player_id>",
##         "contributors": {"<player_id>": 120},
##         "balance": 120,
##         "spent": 40,
##         "history": [
##           {"kind": "spend", "amount": 40, "actor": "<player_id>",
##            "project": "<project_id>", "at_utc": 1800000000.0},
##         ],
##       }
##     }
##   }
##
## 基金 id 与账户身份都由 `org_id` 派生：`fund_for()` 得到 `fund_<org_id>`，
## `account_for()` 得到 `org_<org_id>`。本切片只保存派生字符串，不创建真实
## 经济账户；真实 `pay` 由权威在支出时逐笔调用。
##
## 守恒：`balance + spent == contributors` 合计，且 `spent` 等于 history 中各笔
## 支出之和。history 只记录支出且有界（最多 256 条）；达到上限后拒绝继续支出，避免
## 丢弃审计行或伪造余额。缴入只增加 `balance` 与 `contributors`，不写 history。

const OwnerIds = preload("res://farm/owner_id.gd")

const FUND_PREFIX: String = "fund_"
const ACCOUNT_PREFIX: String = "org_"

const HISTORY_KIND_SPEND: String = "spend"

const STATE_KEYS: Array[String] = ["funds", "commands"]
const FUND_KEYS: Array[String] = [
	"org_id", "keeper", "contributors", "balance", "spent", "history",
]
const HISTORY_KEYS: Array[String] = [
	"kind", "amount", "actor", "project", "at_utc",
]
const COMMAND_KEYS: Array[String] = ["payload", "result"]
const COMMAND_RESULT_KEYS: Array[String] = ["ok", "reason", "action", "fund_id"]

const MAX_FUNDS: int = 64
const MAX_CONTRIBUTORS: int = 256
const MAX_HISTORY: int = 256
## 成功命令的重放记录。payload 只存规范请求的 SHA-256，结果只存答复的四个稳定
## 字段；64 条与内存窗口同量级，跨重启仍能识别已完成的命令而不二次转账。
const MAX_COMMANDS: int = 64
const MAX_COMMAND_ID_LENGTH: int = 128
## 单笔缴入、单成员累计缴入与基金余额上限；越界分别返回具名原因。
const MAX_CONTRIBUTION: int = 10_000
const MAX_TOTAL_CONTRIBUTION: int = 100_000
const MAX_BALANCE: int = 1_000_000
const MAX_SPEND: int = 1_000_000
const MAX_SAFE_INTEGER: int = 9007199254740991


## 没有基金时的初始文档。
static func empty() -> Dictionary:
	return {"funds": {}, "commands": {}}


## JSON 把所有数字读成浮点。规则文档的计数与金额必须还原为整数，否则重载后
## 即使语义不变，再次序列化也会把 `60` 写成 `60.0`，让“无变更的保存”改动文件。
## 仅用于已经通过 `valid()` 的文档。
static func normalize(document: Dictionary) -> Dictionary:
	var result: Dictionary = document.duplicate(true)
	var funds: Dictionary = result["funds"]
	for raw_id: Variant in funds:
		var row: Dictionary = funds[raw_id]
		row["balance"] = int(row["balance"])
		row["spent"] = int(row["spent"])
		var contributors: Dictionary = row["contributors"]
		for raw_player: Variant in contributors:
			contributors[raw_player] = int(contributors[raw_player])
		var history: Array = row["history"]
		for index: int in history.size():
			var entry: Dictionary = history[index]
			entry["amount"] = int(entry["amount"])
			entry["at_utc"] = float(entry["at_utc"])
	return result


## 把一条已完成命令写进基金文档候选。payload 是规范请求的 SHA-256；与基金
## 余额在同一份原子保存里落盘，因此重启后的重试不会再执行同一条命令。
static func remember_command(document: Dictionary, command_id: String,
		payload: String, result: Dictionary) -> Dictionary:
	if not valid(document) or not _valid_command_id(command_id):
		return document
	var commands: Dictionary = document["commands"]
	var candidate: Dictionary = document.duplicate(true)
	var candidate_commands: Dictionary = candidate["commands"]
	candidate_commands[command_id] = {
		"payload": payload.sha256_text(),
		"result": {
			"ok": bool(result.get("ok", false)),
			"reason": str(result.get("reason", "")),
			"action": str(result.get("action", "")),
			"fund_id": str(result.get("fund_id", "")),
		},
	}
	while candidate_commands.size() > MAX_COMMANDS:
		candidate_commands.erase(candidate_commands.keys()[0])
	return candidate


## 查一条已完成命令。返回空表表示没有记录；payload 不一致时返回
## `command_conflict` 的形状，由调用方转成带 action/fund_id 的答复。
static func replay_command(document: Dictionary, command_id: String,
		payload: String) -> Dictionary:
	if not valid(document) or not document["commands"].has(command_id):
		return {}
	var entry: Dictionary = document["commands"][command_id]
	var stored: Dictionary = entry["result"]
	if str(entry["payload"]) != payload.sha256_text():
		stored = stored.duplicate(true)
		stored["ok"] = false
		stored["reason"] = "command_conflict"
		return stored
	var duplicate: Dictionary = stored.duplicate(true)
	duplicate["duplicate"] = true
	return duplicate


## 基金 id 由组织 id 派生，换届、改名或余额变化都不改变它。
static func fund_for(org_id: String) -> String:
	return FUND_PREFIX + org_id


## 派生账户引用。这里只返回字符串，不创建经济账户。
static func account_for(org_id: String) -> String:
	return ACCOUNT_PREFIX + org_id


## 开立一个组织基金。开立者成为首任 keeper，并以 0 累计额进入成员表；
## 基金初始余额为 0。同一组织不能重复开立。
static func open_fund(document: Dictionary, org_id: Variant, keeper: Variant) -> Dictionary:
	if not valid(document):
		return _error("invalid_state")
	if not _valid_org_id(org_id):
		return _error("invalid_org")
	if not _valid_player_id(keeper):
		return _error("invalid_player")
	var funds: Dictionary = document["funds"]
	var fund_id: String = fund_for(str(org_id))
	if funds.has(fund_id):
		return _error("already_exists")
	if funds.size() >= MAX_FUNDS:
		return _error("too_many")
	var candidate: Dictionary = document.duplicate(true)
	var candidate_funds: Dictionary = candidate["funds"]
	candidate_funds[fund_id] = {
		"org_id": str(org_id),
		"keeper": str(keeper),
		"contributors": {str(keeper): 0},
		"balance": 0,
		"spent": 0,
		"history": [],
	}
	return _success(candidate)


## 缴入基金。任何合法玩家都可缴入；只增加余额与成员累计额，不写 history。
## 单笔、单成员累计和余额上限分别以 `amount_limit`、`contribution_limit`、
## `balance_limit` 拒绝。
static func contribute(document: Dictionary, fund_id: Variant, contributor: Variant,
		amount: Variant) -> Dictionary:
	if not valid(document):
		return _error("invalid_state")
	var funds: Dictionary = document["funds"]
	var id: String = str(fund_id)
	if not _valid_fund_id(fund_id) or not funds.has(id):
		return _error("unknown_fund")
	if not _valid_player_id(contributor):
		return _error("invalid_player")
	var value: int = _positive_whole(amount)
	if value <= 0:
		return _error("invalid_amount")
	if value > MAX_CONTRIBUTION:
		return _error("amount_limit")
	var row: Dictionary = funds[id]
	var contributors: Dictionary = row["contributors"]
	var player_id: String = str(contributor)
	var existing: int = int(contributors.get(player_id, 0))
	if existing + value > MAX_TOTAL_CONTRIBUTION:
		return _error("contribution_limit")
	if not contributors.has(player_id) and contributors.size() >= MAX_CONTRIBUTORS:
		return _error("fund_full")
	var balance: int = int(row["balance"])
	if balance + value > MAX_BALANCE:
		return _error("balance_limit")
	var candidate: Dictionary = document.duplicate(true)
	var candidate_row: Dictionary = candidate["funds"][id]
	var candidate_contributors: Dictionary = candidate_row["contributors"]
	candidate_contributors[player_id] = existing + value
	candidate_row["balance"] = balance + value
	return _success(candidate)


## 授权并记录一笔公共项目支出。只有当前 keeper 可以支出；金额不能超过余额；
## 每次支出追加一条 history 行。达到 history 上限后拒绝继续支出。
## 本函数只改预算事实，不调用 Economy/Ledger，也不转账。
static func authorize_spend(document: Dictionary, fund_id: Variant, actor: Variant,
		project: Variant, amount: Variant, now_utc: float) -> Dictionary:
	if not valid(document):
		return _error("invalid_state")
	var funds: Dictionary = document["funds"]
	var id: String = str(fund_id)
	if not _valid_fund_id(fund_id) or not funds.has(id):
		return _error("unknown_fund")
	if not _valid_player_id(actor):
		return _error("invalid_player")
	var row: Dictionary = funds[id]
	if str(actor) != str(row["keeper"]):
		return _error("not_keeper")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	if not _valid_project_id(project):
		return _error("invalid_project")
	var value: int = _positive_whole(amount)
	if value <= 0:
		return _error("invalid_amount")
	if value > MAX_SPEND:
		return _error("amount_limit")
	var balance: int = int(row["balance"])
	if value > balance:
		return _error("insufficient_funds")
	var history: Array = row["history"]
	if history.size() >= MAX_HISTORY:
		return _error("history_full")
	var candidate: Dictionary = document.duplicate(true)
	var candidate_row: Dictionary = candidate["funds"][id]
	candidate_row["balance"] = balance - value
	candidate_row["spent"] = int(row["spent"]) + value
	var candidate_history: Array = candidate_row["history"]
	candidate_history.append({
		"kind": HISTORY_KIND_SPEND,
		"amount": value,
		"actor": str(actor),
		"project": str(project),
		"at_utc": float(now_utc),
	})
	return _success(candidate)


## 换届：只有当前 keeper 可以轮换，新 keeper 必须已在本基金 contributors 中。
## 只改 `keeper` 字段；基金 id、账户派生、余额、成员累计和 history 都不变。
static func rotate_keeper(document: Dictionary, fund_id: Variant, actor: Variant,
		new_keeper: Variant) -> Dictionary:
	if not valid(document):
		return _error("invalid_state")
	var funds: Dictionary = document["funds"]
	var id: String = str(fund_id)
	if not _valid_fund_id(fund_id) or not funds.has(id):
		return _error("unknown_fund")
	if not _valid_player_id(actor) or not _valid_player_id(new_keeper):
		return _error("invalid_player")
	var row: Dictionary = funds[id]
	if str(actor) != str(row["keeper"]):
		return _error("not_keeper")
	if str(new_keeper) == str(row["keeper"]):
		return _error("same_keeper")
	var contributors: Dictionary = row["contributors"]
	if not contributors.has(str(new_keeper)):
		return _error("not_member")
	var candidate: Dictionary = document.duplicate(true)
	var candidate_row: Dictionary = candidate["funds"][id]
	candidate_row["keeper"] = str(new_keeper)
	return _success(candidate)


## 严格文档校验：顶层与基金行键集精确，基金 id 必须等于 `fund_for(org_id)`，
## keeper 必须已是 contributor，金额为非负整数且受上限约束，history 只含合法
## 支出行且其合计等于 `spent`，`balance + spent` 等于成员累计缴入总额。
static func valid(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var document: Dictionary = value
	if not _exact_keys(document, STATE_KEYS):
		return false
	var funds_value: Variant = document.get("funds")
	if not funds_value is Dictionary:
		return false
	var funds: Dictionary = funds_value
	if funds.size() > MAX_FUNDS:
		return false
	for fund_id: Variant in funds:
		if not _valid_fund_id(fund_id):
			return false
		if not _valid_fund(str(fund_id), funds[fund_id]):
			return false
	var commands_value: Variant = document["commands"]
	if not commands_value is Dictionary:
		return false
	var commands: Dictionary = commands_value
	if commands.size() > MAX_COMMANDS:
		return false
	for command_id: Variant in commands:
		if not _valid_command(str(command_id), commands[command_id]):
			return false
	return true


static func _valid_command(command_id: String, value: Variant) -> bool:
	if not _valid_command_id(command_id):
		return false
	if not value is Dictionary:
		return false
	var entry: Dictionary = value
	if not _exact_keys(entry, COMMAND_KEYS):
		return false
	var payload: Variant = entry.get("payload")
	if not payload is String or (payload as String).length() != 64 \
			or not _valid_hex(str(payload)):
		return false
	var result_value: Variant = entry.get("result")
	if not result_value is Dictionary:
		return false
	var result: Dictionary = result_value
	if not _exact_keys(result, COMMAND_RESULT_KEYS):
		return false
	if not result.get("ok") is bool:
		return false
	if not result.get("reason") is String or (result["reason"] as String).length() > 64:
		return false
	var action: Variant = result.get("action")
	if not action is String or not (str(action) in ["open", "contribute", "spend", "rotate"]):
		return false
	if not result.get("fund_id") is String:
		return false
	var fund_id: String = str(result["fund_id"])
	return fund_id.is_empty() or _valid_fund_id(fund_id)


static func _valid_fund(fund_id: String, value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var row: Dictionary = value
	if not _exact_keys(row, FUND_KEYS):
		return false
	if not _valid_org_id(row.get("org_id")):
		return false
	if fund_id != fund_for(str(row["org_id"])):
		return false
	if not _valid_player_id(row.get("keeper")):
		return false
	var contributors_value: Variant = row.get("contributors")
	if not contributors_value is Dictionary:
		return false
	var contributors: Dictionary = contributors_value
	if contributors.is_empty() or contributors.size() > MAX_CONTRIBUTORS:
		return false
	var contributed_total: int = 0
	for player_id: Variant in contributors:
		if not _valid_player_id(player_id):
			return false
		var total: int = _non_negative_whole(contributors[player_id])
		if total < 0 or total > MAX_TOTAL_CONTRIBUTION:
			return false
		contributed_total += total
	if not contributors.has(str(row["keeper"])):
		return false
	var balance: int = _non_negative_whole(row.get("balance"))
	if balance < 0 or balance > MAX_BALANCE:
		return false
	var spent: int = _non_negative_whole(row.get("spent"))
	if spent < 0:
		return false
	var history_value: Variant = row.get("history")
	if not history_value is Array:
		return false
	var history: Array = history_value
	if history.size() > MAX_HISTORY:
		return false
	var history_total: int = 0
	for entry: Variant in history:
		if not _valid_history_entry(entry):
			return false
		history_total += int((entry as Dictionary)["amount"])
	if history_total != spent:
		return false
	return balance + spent == contributed_total


static func _valid_history_entry(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var entry: Dictionary = value
	if not _exact_keys(entry, HISTORY_KEYS):
		return false
	if not entry.get("kind") is String or str(entry["kind"]) != HISTORY_KIND_SPEND:
		return false
	var amount: int = _positive_whole(entry.get("amount"))
	if amount <= 0 or amount > MAX_SPEND:
		return false
	if not _valid_player_id(entry.get("actor")):
		return false
	if not _valid_project_id(entry.get("project")):
		return false
	return _valid_time_value(entry.get("at_utc"))


static func _success(candidate: Dictionary) -> Dictionary:
	return {"ok": true, "reason": "", "state": candidate}


static func _error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


static func _valid_org_id(value: Variant) -> bool:
	return value is String and OwnerIds.valid(value)


static func _valid_player_id(value: Variant) -> bool:
	return value is String and OwnerIds.valid(value)


static func _valid_fund_id(value: Variant) -> bool:
	return value is String and OwnerIds.valid(value)


static func _valid_command_id(value: Variant) -> bool:
	return value is String and not (value as String).is_empty() \
		and (value as String).length() <= MAX_COMMAND_ID_LENGTH


static func _valid_hex(value: String) -> bool:
	for index: int in value.length():
		var code: int = value.unicode_at(index)
		var digit: bool = code >= 48 and code <= 57
		var lower: bool = code >= 97 and code <= 102
		if not digit and not lower:
			return false
	return true


static func _valid_project_id(value: Variant) -> bool:
	return value is String and OwnerIds.valid(value)


static func _exact_keys(value: Dictionary, keys: Array[String]) -> bool:
	if value.size() != keys.size():
		return false
	for key: String in keys:
		if not value.has(key):
			return false
	return true


## JSON 往返会把整数读成浮点，因此容许整值浮点，但拒绝小数、负数、
## 非有限值与字符串。返回 -1 表示非法。
static func _whole_number(value: Variant) -> int:
	if not value is int and not value is float:
		return -1
	var number: float = float(value)
	if not is_finite(number) or number != floorf(number):
		return -1
	if number < 0.0 or number > float(MAX_SAFE_INTEGER):
		return -1
	return int(number)


static func _positive_whole(value: Variant) -> int:
	var number: int = _whole_number(value)
	if number <= 0:
		return -1
	return number


static func _non_negative_whole(value: Variant) -> int:
	return _whole_number(value)


static func _valid_time(value: float) -> bool:
	return is_finite(value) and value >= 0.0 and value <= float(MAX_SAFE_INTEGER)


static func _valid_time_value(value: Variant) -> bool:
	if value is int:
		return int(value) >= 0 and int(value) <= MAX_SAFE_INTEGER
	if value is float:
		return is_finite(float(value)) and float(value) >= 0.0 \
			and float(value) <= float(MAX_SAFE_INTEGER)
	return false
