extends RefCounted
## M8-04a 公共项目纯规则切片：固定成本目录与公共项目预算事实。
## 纯规则：不读 RNG、系统时钟、磁盘、场景、网络或农场/经济文档；不发行、
## 不转账、不创建建筑，也不读取 `FarmState`。所有写入口返回候选文档而不是
## 修改输入。
##
## 文档形状：
##   {
##     "projects": {
##       "<project_id>": {
##         "kind": "village_square" | "public_well" | "road_segment",
##         "parcel_id": "<cadastral parcel id>" | "",
##         "funded": 300,             # 已覆盖的固定成本，等于 min(pledged, cost)
##         "status": "unbuilt" | "funded" | "built",
##         "pledged": 300,            # 累计承诺额，可以超过固定成本
##         "built_utc": 0.0,          # 未建成时固定为 0.0
##       }
##     }
##   }
##
## 本切片只记录预算事实：pledge 增加承诺额，达到目录成本后 `funded` 封顶为
## 成本并把状态转为 `funded`；release_pledge 可以退回承诺，使未建成的项目
## 重新低于成本；mark_built 只把已足额的项目标成建成。预先存在的私人建造
## (`FarmState.build`/`demolish`) 与建筑槽位不受影响。

const OwnerIds = preload("res://farm/owner_id.gd")

const KIND_VILLAGE_SQUARE: String = "village_square"
const KIND_PUBLIC_WELL: String = "public_well"
const KIND_ROAD_SEGMENT: String = "road_segment"
const KIND_NAMES: Array[String] = [
	KIND_VILLAGE_SQUARE, KIND_PUBLIC_WELL, KIND_ROAD_SEGMENT,
]

## 固定成本目录。项目行只保存 kind，成本由这里派生，因此改文档不能改价。
const CATALOG: Dictionary = {
	KIND_VILLAGE_SQUARE: 300,
	KIND_PUBLIC_WELL: 180,
	KIND_ROAD_SEGMENT: 120,
}

const STATUS_UNBUILT: String = "unbuilt"
const STATUS_FUNDED: String = "funded"
const STATUS_BUILT: String = "built"
const STATUSES: Array[String] = [STATUS_UNBUILT, STATUS_FUNDED, STATUS_BUILT]

const STATE_KEYS: Array[String] = ["projects"]
## 成功命令的耐久重放记录。内存窗口只挡当前进程；承诺与退回是真实资金语义，
## 重启后重发同一命令 id 不能再加一次承诺或再退一次。记录与项目文档同一次
## 原子保存落盘，64 条与其它 sidecar 的窗口同量级。
const COMMANDS_KEY: String = "commands"
const COMMAND_KEYS: Array[String] = ["payload", "result"]
const RESULT_KEYS: Array[String] = [
	"ok", "reason", "action", "project_id", "duplicate",
]
const ACTIONS: Array[String] = ["open", "pledge", "release", "build"]
const MAX_COMMANDS: int = 64
const MAX_COMMAND_ID_LENGTH: int = 128
const PROJECT_KEYS: Array[String] = [
	"kind", "parcel_id", "funded", "status", "pledged", "built_utc",
]

const MAX_PROJECTS: int = 32
const MAX_PROJECT_ID_LENGTH: int = 64
const MAX_PARCEL_ID_LENGTH: int = 64
## 单笔承诺上限与项目累计承诺上限；两者都显式拒绝，避免无界金额进入文档。
const MAX_PLEDGE: int = 1_000_000
const MAX_PLEDGED: int = 10_000_000
const MAX_SAFE_INTEGER: int = 9007199254740991


## 没有公共项目时的初始文档。
static func empty() -> Dictionary:
	return {"projects": {}}


## 目录成本；未知项目类型返回 0，方便调用方区分“未定义”与真实成本。
static func cost_of(kind: Variant) -> int:
	if not _valid_kind(kind):
		return 0
	return int(CATALOG[str(kind)])


## 把一次成功命令写进项目文档候选。payload 只存规范请求的 SHA-256，结果只存
## 五个稳定字段；与项目状态在同一份原子保存里落盘。
static func remember_command(document: Dictionary, command_id: String,
		payload: String, result: Dictionary) -> Dictionary:
	if not valid(document) or not _valid_command_id(command_id):
		return document
	var candidate: Dictionary = document.duplicate(true)
	var commands: Dictionary = {}
	var current: Variant = candidate.get(COMMANDS_KEY)
	if current is Dictionary:
		commands = current
	commands[command_id] = {
		"payload": payload.sha256_text(),
		"result": {
			"ok": bool(result.get("ok", false)),
			"reason": str(result.get("reason", "")),
			"action": str(result.get("action", "")),
			"project_id": str(result.get("project_id", "")),
			"duplicate": bool(result.get("duplicate", false)),
		},
	}
	while commands.size() > MAX_COMMANDS:
		commands.erase(commands.keys()[0])
	candidate[COMMANDS_KEY] = commands
	return candidate


## 查一条已记录命令。没有记录返回空表；payload 不一致返回 `command_conflict`。
static func replay_command(document: Dictionary, command_id: String,
		payload: String) -> Dictionary:
	if not valid(document):
		return {}
	var commands_value: Variant = document.get(COMMANDS_KEY)
	if not commands_value is Dictionary:
		return {}
	var commands: Dictionary = commands_value
	if not commands.has(command_id):
		return {}
	var entry: Variant = commands[command_id]
	if not entry is Dictionary:
		return {}
	var stored: Dictionary = (entry as Dictionary)["result"]
	if str((entry as Dictionary)["payload"]) != payload.sha256_text():
		stored = stored.duplicate(true)
		stored["ok"] = false
		stored["reason"] = "command_conflict"
		stored["duplicate"] = false
		return stored
	var duplicate: Dictionary = stored.duplicate(true)
	duplicate["duplicate"] = true
	return duplicate


## 登记一个公共项目。项目 id 唯一，数量有上限；初始没有承诺、未足额、未建成。
static func open_project(document: Dictionary, project_id: Variant, kind: Variant,
		parcel_id: Variant) -> Dictionary:
	if not valid(document):
		return _error("invalid_state")
	if not _valid_project_id(project_id):
		return _error("invalid_project")
	if not _valid_kind(kind):
		return _error("invalid_kind")
	if not _valid_parcel_id(parcel_id):
		return _error("invalid_parcel")
	var id: String = str(project_id)
	var projects: Dictionary = document["projects"]
	if projects.has(id):
		return _error("already_exists")
	if projects.size() >= MAX_PROJECTS:
		return _error("too_many")
	var candidate: Dictionary = document.duplicate(true)
	var candidate_projects: Dictionary = candidate["projects"]
	candidate_projects[id] = {
		"kind": str(kind),
		"parcel_id": str(parcel_id),
		"funded": 0,
		"status": STATUS_UNBUILT,
		"pledged": 0,
		"built_utc": 0.0,
	}
	return _success(candidate)


## 增加项目承诺额。项目必须已登记；已建成项目不能再承诺。`funded` 随累计
## 承诺额增长但封顶为固定成本，达到成本时状态转为 `funded`。
static func pledge(document: Dictionary, project_id: Variant, amount: Variant) -> Dictionary:
	if not valid(document):
		return _error("invalid_state")
	var projects: Dictionary = document["projects"]
	var id: String = str(project_id)
	if not _valid_project_id(project_id) or not projects.has(id):
		return _error("unknown_project")
	var row: Dictionary = projects[id]
	if str(row["status"]) == STATUS_BUILT:
		return _error("already_built")
	var value: int = _positive_whole(amount)
	if value <= 0:
		return _error("invalid_amount")
	if value > MAX_PLEDGE:
		return _error("amount_limit")
	var pledged: int = int(row["pledged"])
	var new_pledged: int = pledged + value
	if new_pledged > MAX_PLEDGED:
		return _error("amount_limit")
	var cost: int = int(CATALOG[str(row["kind"])])
	var funded: int = mini(new_pledged, cost)
	var candidate: Dictionary = document.duplicate(true)
	var candidate_row: Dictionary = candidate["projects"][id]
	candidate_row["pledged"] = new_pledged
	candidate_row["funded"] = funded
	candidate_row["status"] = STATUS_UNBUILT if funded < cost else STATUS_FUNDED
	return _success(candidate)


## 退回承诺额。不能退超过当前承诺，也不能退已建成项目；退回后低于固定成本
## 时状态回到 `unbuilt`。
static func release_pledge(document: Dictionary, project_id: Variant,
		amount: Variant) -> Dictionary:
	if not valid(document):
		return _error("invalid_state")
	var projects: Dictionary = document["projects"]
	var id: String = str(project_id)
	if not _valid_project_id(project_id) or not projects.has(id):
		return _error("unknown_project")
	var row: Dictionary = projects[id]
	if str(row["status"]) == STATUS_BUILT:
		return _error("already_built")
	var value: int = _positive_whole(amount)
	if value <= 0:
		return _error("invalid_amount")
	if value > MAX_PLEDGE:
		return _error("amount_limit")
	var pledged: int = int(row["pledged"])
	if value > pledged:
		return _error("insufficient_pledged")
	var new_pledged: int = pledged - value
	var cost: int = int(CATALOG[str(row["kind"])])
	var funded: int = mini(new_pledged, cost)
	var candidate: Dictionary = document.duplicate(true)
	var candidate_row: Dictionary = candidate["projects"][id]
	candidate_row["pledged"] = new_pledged
	candidate_row["funded"] = funded
	candidate_row["status"] = STATUS_UNBUILT if funded < cost else STATUS_FUNDED
	return _success(candidate)


## 标记项目建成。只有已覆盖固定成本的项目可以建成；重复标记返回
## `already_built`，不会重写首次建成时间。
static func mark_built(document: Dictionary, project_id: Variant,
		now_utc: float) -> Dictionary:
	if not valid(document):
		return _error("invalid_state")
	var projects: Dictionary = document["projects"]
	var id: String = str(project_id)
	if not _valid_project_id(project_id) or not projects.has(id):
		return _error("unknown_project")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	var row: Dictionary = projects[id]
	if str(row["status"]) == STATUS_BUILT:
		return _error("already_built")
	var cost: int = int(CATALOG[str(row["kind"])])
	if int(row["funded"]) < cost:
		return _error("underfunded")
	var candidate: Dictionary = document.duplicate(true)
	var candidate_row: Dictionary = candidate["projects"][id]
	candidate_row["status"] = STATUS_BUILT
	candidate_row["built_utc"] = float(now_utc)
	return _success(candidate)


## 严格文档校验：顶层与项目行键集精确、id/类型/地块/金额/状态/时间合法，
## `funded` 必须等于 `min(pledged, cost)`，状态与金额互相对齐，项目数有上限。
static func valid(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var document: Dictionary = value
	if document.size() < STATE_KEYS.size() \
			or document.size() > STATE_KEYS.size() + 1:
		return false
	for key: String in STATE_KEYS:
		if not document.has(key):
			return false
	for key: Variant in document:
		if not STATE_KEYS.has(str(key)) and str(key) != COMMANDS_KEY:
			return false
	var projects_value: Variant = document.get("projects")
	if not projects_value is Dictionary:
		return false
	var projects: Dictionary = projects_value
	if projects.size() > MAX_PROJECTS:
		return false
	for project_id: Variant in projects:
		if not _valid_project_id(project_id):
			return false
		if not _valid_project(projects[project_id]):
			return false
	var commands_value: Variant = document.get(COMMANDS_KEY, {})
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
	if not _exact_keys(result, RESULT_KEYS):
		return false
	if not result.get("ok") is bool or not result.get("duplicate") is bool:
		return false
	if not result.get("reason") is String or (result["reason"] as String).length() > 64:
		return false
	if not result.get("action") is String or str(result["action"]) not in ACTIONS:
		return false
	if not result.get("project_id") is String:
		return false
	var project_id: String = str(result["project_id"])
	return project_id.is_empty() or _valid_project_id(project_id)


static func _valid_command_id(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_COMMAND_ID_LENGTH:
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		if code < 0x20 or code == 0x7F:
			return false
	return true


static func _valid_hex(text: String) -> bool:
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		if not ((code >= 0x30 and code <= 0x39) or (code >= 0x61 and code <= 0x66)):
			return false
	return true


static func _valid_project(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var row: Dictionary = value
	if not _exact_keys(row, PROJECT_KEYS):
		return false
	if not _valid_kind(row.get("kind")):
		return false
	if not _valid_parcel_id(row.get("parcel_id")):
		return false
	var pledged: int = _non_negative_whole(row.get("pledged"))
	if pledged < 0 or pledged > MAX_PLEDGED:
		return false
	var cost: int = int(CATALOG[str(row["kind"])])
	var funded: int = _non_negative_whole(row.get("funded"))
	if funded < 0 or funded != mini(pledged, cost):
		return false
	var status: Variant = row.get("status")
	if not status is String or str(status) not in STATUSES:
		return false
	var built_utc: Variant = row.get("built_utc")
	if not _valid_time_value(built_utc):
		return false
	if str(status) == STATUS_BUILT:
		return funded == cost
	if float(built_utc) != 0.0:
		return false
	if str(status) == STATUS_FUNDED:
		return funded == cost
	return funded < cost


static func _success(candidate: Dictionary) -> Dictionary:
	return {"ok": true, "reason": "", "state": candidate}


static func _error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


static func _valid_project_id(value: Variant) -> bool:
	return value is String and str(value).length() <= MAX_PROJECT_ID_LENGTH \
		and OwnerIds.valid(value)


## 公共项目可以暂未绑定地块（空串），但一旦填写必须是合法地块 id。
static func _valid_parcel_id(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.length() > MAX_PARCEL_ID_LENGTH:
		return false
	return text.is_empty() or OwnerIds.valid(text)


static func _valid_kind(value: Variant) -> bool:
	return value is String and str(value) in KIND_NAMES


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
