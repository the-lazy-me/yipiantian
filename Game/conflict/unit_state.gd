extends RefCounted
## M12-01 单位与补给的纯规则切片。全部入口为静态函数；无随机数、无系统时钟、
## 无磁盘、无场景、无网络。所有写入口显式接收 `now_utc`，同一输入得到同一输出，
## 并且先复制再写入：失败不返回 `state`，也不修改调用方传入的文档。
##
## 本切片只维护规则层单位名册、补给与工资状态，不读取 `FarmState`，不扣现金/粮草，
## 不写存档，不发 RPC。调用方根据返回的 `cost` / `consumed` 自行结算真实资产。
##
## 文档形状：
##
##   {
##     "world_id": "world-...",
##     "sequence": 0,
##     "last_upkeep_utc": -1.0,          # -1 表示尚未结算过补给
##     "units": {
##       "<unit_id>": {
##         "id": "<unit_id>",
##         "owner": "<owner>",
##         "kind": "militia" | "guard",
##         "people": 100,
##         "equipment": "none" | "basic" | "standard" | "elite",
##         "station": "<station_id>",
##         "recruited_utc": 0.0,
##         "unfed_days": 0,
##         "unpaid_days": 0,
##         "last_wage_utc": 0.0,          # 最近一次工资结算时刻，招募时等于 recruited_utc
##         "record_command_id": "<unit_id>",
##       },
##     },
##     "commands": {
##       "<command_id>": {
##         "payload": "[...]",
##         "result": {
##           "kind": "recruit" | "disband",
##           "unit_id": "<unit_id>",
##           "cost": {"cash": 0, "supplies": 0},
##         },
##       },
##     },
##   }
##
## 关键不变量：
## - 招募命令 id 同时就是单位 id，因此同一 id 的重复提交天然指向同一支部队；
##   `commands` 保存首次 payload 与结果，重试同 payload 回放，换 payload 返回
##   `command_conflict`。单位行另有 `record_command_id` 指向招募记录，`valid()`
##   要求两者互相一致，名册不能凭空出现。
## - 招募只读取调用方提供的库存上下文并返回成本；现金或粮草不足分别返回
##   `insufficient_cash` / `insufficient_supply`，不直接扣减任何真实资产。
## - 每支单位有固定目录成本、每日粮草和基础战力；装备枚举提供战力系数和
##   一次性现金成本。无资源时不能继续招募。
## - `upkeep` 按单位人数与目录消耗粮草。粮草只扣到可用数量为止，缺口按比例
##   产生逃兵并累计 `unfed_days`；欠供后 `capability()` 明确下降。
## - `pay_wages` 按单位人数与目录消耗现金。调用方给出本 tick 的现金总量，现金只付到
##   可用数量为止，缺口累计 `unpaid_days`；欠供与欠付共用同一份惩罚公式。
## - 同一时刻重复 `upkeep` 不再扣粮，返回 `settled_this_tick`；时间倒退返回
##   `time_regression`。工资以每支单位自己的 `last_wage_utc` 判断同一 tick。
## - `capability()` 是派生值，不缓存：基础战力 × 人数 × 装备系数 × 短缺惩罚
##   （欠供天数 + 欠付天数），全部使用整数万分比，结果确定。
## - 工资与粮草使用各自的结算入口和时刻：`last_upkeep_utc` 管粮草，单位行内的
##   `last_wage_utc` 管工资。两者都只由纯规则推进，不读取农场资产。

const OwnerIds = preload("res://farm/owner_id.gd")

const KIND_MILITIA: String = "militia"
const KIND_GUARD: String = "guard"

## 招募现金与每日粮草都按人数计；基础战力也是每人战力。每日工资同样按人数计，
## 与每日粮草同量级（1 份现金换 1 份粮草），便于把“付得起工资”与“买得起粮”
## 放在同一经济尺度上比较。
const CATALOG: Dictionary = {
	KIND_MILITIA: {
		"cash_cost_per_person": 2,
		"daily_supply_per_person": 1,
		"daily_wage_per_person": 1,
		"base_power_per_person": 10,
	},
	KIND_GUARD: {
		"cash_cost_per_person": 4,
		"daily_supply_per_person": 2,
		"daily_wage_per_person": 2,
		"base_power_per_person": 18,
	},
}

## 装备提供战力系数（万分比）和一次性现金成本（每人）。
const EQUIPMENT: Dictionary = {
	"none": {"power_bps": 10000, "cash_cost_per_person": 0},
	"basic": {"power_bps": 11000, "cash_cost_per_person": 2},
	"standard": {"power_bps": 12500, "cash_cost_per_person": 5},
	"elite": {"power_bps": 15000, "cash_cost_per_person": 10},
}

const RECORD_RECRUIT: String = "recruit"
const RECORD_DISBAND: String = "disband"
const RECORD_KINDS: Array[String] = [RECORD_RECRUIT, RECORD_DISBAND]

const STATUS_FED: String = "fed"
const STATUS_SHORTFALL: String = "shortfall"
const STATUS_SETTLED_THIS_TICK: String = "settled_this_tick"
const STATUS_PAID: String = "paid"
const STATUS_UNPAID: String = "unpaid"

## 短缺天数（欠供 + 欠付）每多一天扣掉 25% 战力，最多扣 75%，避免规则层战力
## 归零后无法解释。两种短缺共用一份惩罚，不叠加出第二套战力公式。
const SUPPLY_PENALTY_BPS_PER_DAY: int = 2500
const MAX_SUPPLY_PENALTY_BPS: int = 7500
const BPS_SCALE: int = 10000

## 工资按整日结算：只有跨过完整 86400 秒才对每支单位计一天工资。周期用整数，
## 避免月份日长、时区周边与浮点折算带来的歧义；结算时刻仍由调用方显式给出。
const WAGE_PERIOD_SECONDS: int = 86400

## -1 表示文档从未结算过补给；JSON 往返后可能是 -1 或 -1.0。
const NEVER_UPKEPT: float = -1.0

const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_UNITS: int = 64
const MAX_PEOPLE_PER_UNIT: int = 500
const MAX_UNFED_DAYS: int = 1000000
const MAX_UNPAID_DAYS: int = 1000000
const MAX_COMMANDS: int = 256
const MAX_UNIT_ID_LENGTH: int = 128
const MAX_COMMAND_ID_LENGTH: int = 128
const MAX_STATION_LENGTH: int = 64
const MAX_WORLD_ID_LENGTH: int = 128
const MAX_PAYLOAD_LENGTH: int = 8192

const STATE_KEYS: Array[String] = [
	"world_id", "sequence", "last_upkeep_utc", "units", "commands",
]
const UNIT_KEYS: Array[String] = [
	"id", "owner", "kind", "people", "equipment", "station", "recruited_utc",
	"unfed_days", "unpaid_days", "last_wage_utc", "record_command_id",
]
const RECORD_KEYS: Array[String] = ["payload", "result"]
const RESULT_KEYS: Array[String] = ["kind", "unit_id", "cost"]
const COST_KEYS: Array[String] = ["cash", "supplies"]
const STOCK_KEYS: Array[String] = ["cash", "supplies"]
const RECRUIT_KEYS: Array[String] = [
	"id", "owner", "kind", "people", "equipment", "station",
]
const DISBAND_KEYS: Array[String] = ["id", "unit_id", "owner"]

const REASON_INVALID_STATE: String = "invalid_state"
const REASON_INVALID_STOCK: String = "invalid_stock"
const REASON_INVALID_CASH: String = "invalid_cash"
const REASON_INVALID_COMMAND: String = "invalid_command"
const REASON_INVALID_UNIT_ID: String = "invalid_unit_id"
const REASON_INVALID_OWNER: String = "invalid_owner"
const REASON_INVALID_KIND: String = "invalid_kind"
const REASON_INVALID_PEOPLE: String = "invalid_people"
const REASON_INVALID_EQUIPMENT: String = "invalid_equipment"
const REASON_INVALID_STATION: String = "invalid_station"
const REASON_INVALID_TIME: String = "invalid_time"
const REASON_TIME_REGRESSION: String = "time_regression"
const REASON_COMMAND_CONFLICT: String = "command_conflict"
const REASON_CAPACITY: String = "capacity"
const REASON_UNKNOWN_UNIT: String = "unknown_unit"
const REASON_NOT_OWNER: String = "not_owner"
const REASON_INSUFFICIENT_CASH: String = "insufficient_cash"
const REASON_INSUFFICIENT_SUPPLY: String = "insufficient_supply"


## 新建空名册。`last_upkeep_utc` 使用 -1 表示尚未结算。
static func initial_state(world_id: String) -> Dictionary:
	return {
		"world_id": world_id,
		"sequence": 0,
		"last_upkeep_utc": NEVER_UPKEPT,
		"units": {},
		"commands": {},
	}


## 招募一支单位。成功返回候选文档 `state` 与本次成本 `cost`，不扣真实资产；
## 同 command id 同 payload 回放首次结果且不修改输入，换 payload 返回
## `command_conflict`。失败不返回 `state`。
static func recruit(state: Variant, stock: Variant, command: Variant,
		now_utc: Variant) -> Dictionary:
	if not state is Dictionary or not valid(state):
		return _failure(REASON_INVALID_STATE)
	if not _valid_time(now_utc):
		return _failure(REASON_INVALID_TIME)
	var parsed: Dictionary = _parse_recruit(command)
	if not bool(parsed.get("ok", false)):
		return _failure(str(parsed.get("reason", REASON_INVALID_COMMAND)))
	var cmd: Dictionary = parsed["command"]
	var document: Dictionary = state
	var now: float = float(now_utc)

	var command_id: String = str(cmd["id"])
	var payload: String = _recruit_payload(cmd, now)
	var replay: Dictionary = _replay(document, command_id, payload)
	if not replay.is_empty():
		if not bool(replay.get("ok", false)):
			return _failure(str(replay.get("reason", REASON_COMMAND_CONFLICT)))
		return replay
	if _is_regression(document, now):
		return _failure(REASON_TIME_REGRESSION)

	var units: Dictionary = document["units"]
	if units.size() >= MAX_UNITS:
		return _failure(REASON_CAPACITY)
	var checked_stock: Dictionary = _parse_stock(stock)
	if not bool(checked_stock.get("ok", false)):
		return _failure(str(checked_stock.get("reason", REASON_INVALID_STOCK)))

	var kind: String = str(cmd["kind"])
	var people: int = int(cmd["people"])
	var equipment: String = str(cmd["equipment"])
	var cost: Dictionary = _recruit_cost(kind, people, equipment)
	if int(checked_stock["cash"]) < int(cost["cash"]):
		return _failure(REASON_INSUFFICIENT_CASH)
	if int(checked_stock["supplies"]) < int(cost["supplies"]):
		return _failure(REASON_INSUFFICIENT_SUPPLY)

	var unit: Dictionary = {
		"id": command_id,
		"owner": str(cmd["owner"]),
		"kind": kind,
		"people": people,
		"equipment": equipment,
		"station": str(cmd["station"]),
		"recruited_utc": now,
		"unfed_days": 0,
		"unpaid_days": 0,
		"last_wage_utc": now,
		"record_command_id": command_id,
	}
	var next: Dictionary = document.duplicate(true)
	var next_units: Dictionary = next["units"]
	next_units[command_id] = unit
	var next_commands: Dictionary = next["commands"]
	next_commands[command_id] = {
		"payload": payload,
		"result": {
			"kind": RECORD_RECRUIT,
			"unit_id": command_id,
			"cost": cost.duplicate(true),
		},
	}
	next["sequence"] = int(next["sequence"]) + 1
	return {
		"ok": true,
		"reason": "",
		"duplicate": false,
		"state": next,
		"unit_id": command_id,
		"unit": unit.duplicate(true),
		"cost": cost.duplicate(true),
	}


## 解散一支单位。写时复制；同 command id 同 payload 回放，换 payload 冲突。
## 只有单位所有者可以解散（`not_owner`），未知单位返回 `unknown_unit`。
static func disband(state: Variant, command: Variant,
		now_utc: Variant) -> Dictionary:
	if not state is Dictionary or not valid(state):
		return _failure(REASON_INVALID_STATE)
	if not _valid_time(now_utc):
		return _failure(REASON_INVALID_TIME)
	var parsed: Dictionary = _parse_disband(command)
	if not bool(parsed.get("ok", false)):
		return _failure(str(parsed.get("reason", REASON_INVALID_COMMAND)))
	var cmd: Dictionary = parsed["command"]
	var document: Dictionary = state
	var now: float = float(now_utc)

	var command_id: String = str(cmd["id"])
	var payload: String = JSON.stringify([command_id, str(cmd["unit_id"]),
		str(cmd["owner"])])
	var replay: Dictionary = _replay(document, command_id, payload)
	if not replay.is_empty():
		if not bool(replay.get("ok", false)):
			return _failure(str(replay.get("reason", REASON_COMMAND_CONFLICT)))
		return replay
	if _is_regression(document, now):
		return _failure(REASON_TIME_REGRESSION)

	var units: Dictionary = document["units"]
	var unit_id: String = str(cmd["unit_id"])
	if not units.has(unit_id):
		return _failure(REASON_UNKNOWN_UNIT)
	var row: Dictionary = units[unit_id]
	if str(row["owner"]) != str(cmd["owner"]):
		return _failure(REASON_NOT_OWNER)

	var next: Dictionary = document.duplicate(true)
	var next_units: Dictionary = next["units"]
	var removed: Dictionary = next_units[unit_id].duplicate(true)
	next_units.erase(unit_id)
	var next_commands: Dictionary = next["commands"]
	next_commands[command_id] = {
		"payload": payload,
		"result": {
			"kind": RECORD_DISBAND,
			"unit_id": unit_id,
			"cost": {"cash": 0, "supplies": 0},
		},
	}
	next["sequence"] = int(next["sequence"]) + 1
	return {
		"ok": true,
		"reason": "",
		"duplicate": false,
		"state": next,
		"unit_id": unit_id,
		"unit": removed,
	}


## 低频战略补给结算。按 unit id 升序分配调用方提供的粮草，扣到可用数量为止；
## 缺口按比例造成逃兵并累计 `unfed_days`，存活单位的 `capability()` 随之下降。
## 同一时刻重复调用返回 `settled_this_tick`，不再次扣粮；时间倒退返回
## `time_regression`。`stock` 只读，实际库存扣减由调用方按 `consumed` 完成。
static func upkeep(state: Variant, stock: Variant, now_utc: Variant) -> Dictionary:
	if not state is Dictionary or not valid(state):
		return _failure(REASON_INVALID_STATE)
	if not _valid_time(now_utc):
		return _failure(REASON_INVALID_TIME)
	var checked_stock: Dictionary = _parse_stock(stock)
	if not bool(checked_stock.get("ok", false)):
		return _failure(str(checked_stock.get("reason", REASON_INVALID_STOCK)))
	var document: Dictionary = state
	var now: float = float(now_utc)
	var last: float = float(document["last_upkeep_utc"])
	if last >= 0.0 and now < last:
		return _failure(REASON_TIME_REGRESSION)
	if last >= 0.0 and now == last:
		return {
			"ok": true,
			"reason": "",
			"state": document,
			"status": STATUS_SETTLED_THIS_TICK,
			"settled_this_tick": true,
			"consumed": 0,
			"deserters": 0,
			"affected": [],
		}

	var available: int = int(checked_stock["supplies"])
	var consumed: int = 0
	var total_deserters: int = 0
	var affected: Array = []
	var next: Dictionary = document.duplicate(true)
	var next_units: Dictionary = next["units"]
	var ids: Array = next_units.keys()
	ids.sort()
	for raw_id: Variant in ids:
		var unit_id: String = str(raw_id)
		var row: Dictionary = next_units[unit_id]
		var people: int = int(row["people"])
		var required: int = _daily_supply(str(row["kind"]), people)
		var supplied: int = mini(required, available)
		available -= supplied
		consumed += supplied
		var shortfall: int = required - supplied
		if shortfall <= 0:
			row["unfed_days"] = 0
			next_units[unit_id] = row
			continue
		var deserters: int = (people * shortfall + required - 1) / required
		var survivors: int = people - deserters
		var unfed_days: int = int(row["unfed_days"]) + 1
		total_deserters += deserters
		affected.append({
			"unit_id": unit_id,
			"owner": str(row["owner"]),
			"kind": str(row["kind"]),
			"required": required,
			"supplied": supplied,
			"shortfall": shortfall,
			"deserters": deserters,
			"people_before": people,
			"people_after": survivors,
			"unfed_days": unfed_days,
			"removed": survivors <= 0,
		})
		if survivors <= 0:
			next_units.erase(unit_id)
		else:
			row["people"] = survivors
			row["unfed_days"] = unfed_days
			next_units[unit_id] = row

	next["last_upkeep_utc"] = now
	next["sequence"] = int(next["sequence"]) + 1
	return {
		"ok": true,
		"reason": "",
		"state": next,
		"status": STATUS_SHORTFALL if total_deserters > 0 else STATUS_FED,
		"settled_this_tick": false,
		"consumed": consumed,
		"deserters": total_deserters,
		"affected": affected,
	}


## 派生战力：基础每人战力 × 人数 × 装备系数 × 短缺惩罚，全部整数万分比。
## 短缺天数取欠供与欠付的合计；未知单位返回 `unknown_unit` 与 0 战力；
## 文档不合法返回 `invalid_state`。
static func capability(state: Variant, unit_id: Variant) -> Dictionary:
	if not state is Dictionary or not valid(state):
		return {"ok": false, "reason": REASON_INVALID_STATE, "power": 0}
	if not _valid_unit_id(unit_id):
		return {"ok": false, "reason": REASON_INVALID_UNIT_ID, "power": 0}
	var document: Dictionary = state
	var units: Dictionary = document["units"]
	var key: String = str(unit_id)
	if not units.has(key):
		return {"ok": false, "reason": REASON_UNKNOWN_UNIT, "power": 0}
	var row: Dictionary = units[key]
	var unfed_days: int = int(row["unfed_days"])
	var unpaid_days: int = int(row["unpaid_days"])
	return {
		"ok": true,
		"reason": "",
		"unit_id": key,
		"power": _power(row),
		"people": int(row["people"]),
		"kind": str(row["kind"]),
		"equipment": str(row["equipment"]),
		"unfed_days": unfed_days,
		"unpaid_days": unpaid_days,
		"equipment_bps": int(EQUIPMENT[str(row["equipment"])]["power_bps"]),
		"penalty_bps": _penalty_bps(unfed_days + unpaid_days),
	}


## 每日工资结算。调用方给出本次可用的现金总量 `available_cash`，规则按 unit id
## 升序逐支支付；每支单位按自己的 `last_wage_utc` 累计整日数，只有整日才计工资。
## 现金只付到可用数量为止，缺口累计 `unpaid_days`；`capability()` 随合计短缺天数
## 下降。同一时刻重复调用没有整日可计，返回 `settled_this_tick` 且不扣现金。
## 现金扣减由调用方按返回的 `paid` 完成；文档只推进各单位的 `last_wage_utc` 与
## `sequence`，不改 `last_upkeep_utc`。
static func pay_wages(state: Variant, available_cash: Variant,
		now_utc: Variant) -> Dictionary:
	if not state is Dictionary or not valid(state):
		return _failure(REASON_INVALID_STATE)
	if not _valid_time(now_utc):
		return _failure(REASON_INVALID_TIME)
	if not _is_count(available_cash):
		return _failure(REASON_INVALID_CASH)
	var document: Dictionary = state
	var now: float = float(now_utc)
	var available: int = int(available_cash)
	var total_required: int = 0
	var total_paid: int = 0
	var total_unpaid: int = 0
	var settlements: Array = []
	var affected: Array = []
	var next: Dictionary = document.duplicate(true)
	var next_units: Dictionary = next["units"]
	var ids: Array = next_units.keys()
	ids.sort()
	for raw_id: Variant in ids:
		var unit_id: String = str(raw_id)
		var row: Dictionary = next_units[unit_id]
		var last: float = float(row["last_wage_utc"])
		if now < last:
			return _failure(REASON_TIME_REGRESSION)
		var days: int = int(floor((now - last) / float(WAGE_PERIOD_SECONDS)))
		if days <= 0:
			continue
		var required: int = _wages_due(str(row["kind"]), int(row["people"]), days)
		var paid: int = mini(required, available)
		var shortfall: int = required - paid
		available -= paid
		total_required += required
		total_paid += paid
		total_unpaid += shortfall
		var unpaid_days: int = int(row["unpaid_days"])
		if shortfall > 0:
			# 上限只防止候选文档越过 `valid()` 的形状上限；惩罚本身早已封顶。
			unpaid_days = mini(unpaid_days + days, MAX_UNPAID_DAYS)
		else:
			unpaid_days = 0
		row["unpaid_days"] = unpaid_days
		row["last_wage_utc"] = last + float(days * WAGE_PERIOD_SECONDS)
		next_units[unit_id] = row
		var record: Dictionary = {
			"unit_id": unit_id,
			"owner": str(row["owner"]),
			"kind": str(row["kind"]),
			"days": days,
			"required": required,
			"paid": paid,
			"shortfall": shortfall,
			"unpaid_days": unpaid_days,
		}
		settlements.append(record)
		if shortfall > 0:
			affected.append(record.duplicate(true))

	if settlements.is_empty():
		return {
			"ok": true,
			"reason": "",
			"state": document,
			"status": STATUS_SETTLED_THIS_TICK,
			"settled_this_tick": true,
			"required": 0,
			"paid": 0,
			"unpaid": 0,
			"settlements": [],
			"affected": [],
		}
	next["sequence"] = int(next["sequence"]) + 1
	return {
		"ok": true,
		"reason": "",
		"state": next,
		"status": STATUS_UNPAID if total_unpaid > 0 else STATUS_PAID,
		"settled_this_tick": false,
		"required": total_required,
		"paid": total_paid,
		"unpaid": total_unpaid,
		"settlements": settlements,
		"affected": affected,
	}


## 严格校验单位文档：精确键集、上限、枚举、id、时间、成本、名册与耐久命令记录
## 的相互引用。未知键一律拒绝，没有旧格式兼容分支。
static func valid(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var document: Dictionary = value
	if not _exact_keys(document, STATE_KEYS):
		return false
	if not _valid_world_id(document["world_id"]):
		return false
	if not _is_count(document["sequence"]) \
			or int(document["sequence"]) >= MAX_SAFE_INTEGER:
		return false
	if not _valid_last_upkeep(document["last_upkeep_utc"]):
		return false

	var commands_value: Variant = document["commands"]
	if not commands_value is Dictionary or commands_value.size() > MAX_COMMANDS:
		return false
	var commands: Dictionary = commands_value
	var disbanded: Array[String] = []
	for command_id: Variant in commands:
		if not _valid_command_id(command_id):
			return false
		var entry_value: Variant = commands[command_id]
		if not entry_value is Dictionary:
			return false
		if not _valid_record(str(command_id), entry_value):
			return false
		var result: Dictionary = entry_value["result"]
		if str(result["kind"]) == RECORD_DISBAND:
			disbanded.append(str(result["unit_id"]))

	var units_value: Variant = document["units"]
	if not units_value is Dictionary or units_value.size() > MAX_UNITS:
		return false
	var units: Dictionary = units_value
	for unit_id: Variant in units:
		if not _valid_unit_id(unit_id):
			return false
		var key: String = str(unit_id)
		var row_value: Variant = units[unit_id]
		if not row_value is Dictionary:
			return false
		var row: Dictionary = row_value
		if not _exact_keys(row, UNIT_KEYS):
			return false
		if not row["id"] is String or str(row["id"]) != key:
			return false
		if not _valid_owner(row["owner"]):
			return false
		if not row["kind"] is String or not CATALOG.has(str(row["kind"])):
			return false
		if not _valid_people(row["people"]):
			return false
		if not row["equipment"] is String \
				or not EQUIPMENT.has(str(row["equipment"])):
			return false
		if not _valid_station(row["station"]):
			return false
		if not _valid_time(row["recruited_utc"]):
			return false
		if not _is_count(row["unfed_days"]) \
				or int(row["unfed_days"]) > MAX_UNFED_DAYS:
			return false
		if not _valid_unpaid_days(row["unpaid_days"]):
			return false
		if not _valid_wage_clock(row["last_wage_utc"], row["recruited_utc"]):
			return false
		if not _valid_unit_id(row["record_command_id"]):
			return false
		var record_id: String = str(row["record_command_id"])
		if record_id != key or not commands.has(record_id):
			return false
		if not _valid_unit_record(commands[record_id], key, row):
			return false

	for unit_id: String in disbanded:
		if units.has(unit_id):
			return false
		if not _has_recruit_record(commands, unit_id):
			return false

	# 每次成功写入都递增 sequence；补给结算也会递增，因此它不小于命令记录数。
	if int(document["sequence"]) < commands.size():
		return false
	return true


static func _parse_recruit(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"ok": false, "reason": REASON_INVALID_COMMAND}
	var command: Dictionary = value
	if not _exact_keys(command, RECRUIT_KEYS):
		return {"ok": false, "reason": REASON_INVALID_COMMAND}
	if not _valid_unit_id(command["id"]):
		return {"ok": false, "reason": REASON_INVALID_UNIT_ID}
	if not _valid_owner(command["owner"]):
		return {"ok": false, "reason": REASON_INVALID_OWNER}
	if not command["kind"] is String or not CATALOG.has(str(command["kind"])):
		return {"ok": false, "reason": REASON_INVALID_KIND}
	if not _valid_people(command["people"]):
		return {"ok": false, "reason": REASON_INVALID_PEOPLE}
	if not command["equipment"] is String \
			or not EQUIPMENT.has(str(command["equipment"])):
		return {"ok": false, "reason": REASON_INVALID_EQUIPMENT}
	if not _valid_station(command["station"]):
		return {"ok": false, "reason": REASON_INVALID_STATION}
	return {
		"ok": true,
		"reason": "",
		"command": {
			"id": str(command["id"]),
			"owner": str(command["owner"]),
			"kind": str(command["kind"]),
			"people": int(command["people"]),
			"equipment": str(command["equipment"]),
			"station": str(command["station"]),
		},
	}


static func _parse_disband(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"ok": false, "reason": REASON_INVALID_COMMAND}
	var command: Dictionary = value
	if not _exact_keys(command, DISBAND_KEYS):
		return {"ok": false, "reason": REASON_INVALID_COMMAND}
	if not _valid_command_id(command["id"]):
		return {"ok": false, "reason": REASON_INVALID_COMMAND}
	if not _valid_unit_id(command["unit_id"]):
		return {"ok": false, "reason": REASON_INVALID_UNIT_ID}
	if not _valid_owner(command["owner"]):
		return {"ok": false, "reason": REASON_INVALID_OWNER}
	return {
		"ok": true,
		"reason": "",
		"command": {
			"id": str(command["id"]),
			"unit_id": str(command["unit_id"]),
			"owner": str(command["owner"]),
		},
	}


static func _parse_stock(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"ok": false, "reason": REASON_INVALID_STOCK}
	var stock: Dictionary = value
	if not _exact_keys(stock, STOCK_KEYS):
		return {"ok": false, "reason": REASON_INVALID_STOCK}
	if not _is_count(stock["cash"]) or not _is_count(stock["supplies"]):
		return {"ok": false, "reason": REASON_INVALID_STOCK}
	return {
		"ok": true,
		"reason": "",
		"cash": int(stock["cash"]),
		"supplies": int(stock["supplies"]),
	}


## 已存在的 command id：同 payload 返回可回放的首次结果；不同 payload 返回失败。
## 这里只读出文档内容，不复制也不写入。
static func _replay(document: Dictionary, command_id: String,
		payload: String) -> Dictionary:
	var commands: Dictionary = document["commands"]
	if not commands.has(command_id):
		return {}
	var entry: Dictionary = commands[command_id]
	if str(entry["payload"]) != payload:
		return {"ok": false, "reason": REASON_COMMAND_CONFLICT}
	var result: Dictionary = entry["result"]
	var unit_id: String = str(result["unit_id"])
	var returned: Dictionary = {
		"ok": true,
		"reason": "",
		"duplicate": true,
		"state": document,
		"unit_id": unit_id,
	}
	if str(result["kind"]) == RECORD_RECRUIT:
		returned["cost"] = result["cost"].duplicate(true)
		var units: Dictionary = document["units"]
		returned["unit"] = units[unit_id].duplicate(true) if units.has(unit_id) else {}
	else:
		returned["unit"] = {}
	return returned


static func _recruit_cost(kind: String, people: int, equipment: String) -> Dictionary:
	var catalog: Dictionary = CATALOG[kind]
	var gear: Dictionary = EQUIPMENT[equipment]
	var per_person: int = int(catalog["cash_cost_per_person"]) \
		+ int(gear["cash_cost_per_person"])
	return {
		"cash": per_person * people,
		"supplies": int(catalog["daily_supply_per_person"]) * people,
	}


static func _daily_supply(kind: String, people: int) -> int:
	var catalog: Dictionary = CATALOG[kind]
	return int(catalog["daily_supply_per_person"]) * people


static func _wages_due(kind: String, people: int, days: int) -> int:
	var catalog: Dictionary = CATALOG[kind]
	return int(catalog["daily_wage_per_person"]) * people * days


static func _power(row: Dictionary) -> int:
	var catalog: Dictionary = CATALOG[str(row["kind"])]
	var gear: Dictionary = EQUIPMENT[str(row["equipment"])]
	var shortfall_days: int = int(row["unfed_days"]) + int(row["unpaid_days"])
	var numerator: int = int(catalog["base_power_per_person"]) \
		* int(row["people"]) * int(gear["power_bps"]) \
		* _penalty_bps(shortfall_days)
	return numerator / (BPS_SCALE * BPS_SCALE)


static func _penalty_bps(shortfall_days: int) -> int:
	return BPS_SCALE - mini(shortfall_days * SUPPLY_PENALTY_BPS_PER_DAY,
		MAX_SUPPLY_PENALTY_BPS)


static func _recruit_payload(command: Dictionary, now: float) -> String:
	return JSON.stringify([
		str(command["id"]), str(command["owner"]), str(command["kind"]),
		int(command["people"]), str(command["equipment"]),
		str(command["station"]), float(now),
	])


static func _is_regression(document: Dictionary, now: float) -> bool:
	var last: float = float(document["last_upkeep_utc"])
	return last >= 0.0 and now < last


static func _valid_record(command_id: String, value: Dictionary) -> bool:
	if not _exact_keys(value, RECORD_KEYS):
		return false
	if not value["payload"] is String or not value["result"] is Dictionary:
		return false
	var payload: String = str(value["payload"])
	if payload.length() > MAX_PAYLOAD_LENGTH:
		return false
	var result: Dictionary = value["result"]
	if not _exact_keys(result, RESULT_KEYS):
		return false
	if not result["kind"] is String or not RECORD_KINDS.has(str(result["kind"])):
		return false
	if not _valid_unit_id(result["unit_id"]):
		return false
	if not result["cost"] is Dictionary:
		return false
	var cost: Dictionary = result["cost"]
	if not _exact_keys(cost, COST_KEYS):
		return false
	if not _is_count(cost["cash"]) or not _is_count(cost["supplies"]):
		return false
	var parsed: Variant = _parse_payload(payload)
	if not parsed is Array:
		return false
	var parts: Array = parsed
	match str(result["kind"]):
		RECORD_RECRUIT:
			return _valid_recruit_record(command_id, parts, result, cost)
		RECORD_DISBAND:
			return _valid_disband_record(command_id, parts, result, cost)
		_:
			return false


static func _valid_recruit_record(command_id: String, parts: Array,
		result: Dictionary, cost: Dictionary) -> bool:
	if parts.size() != 7:
		return false
	if not parts[0] is String or str(parts[0]) != command_id:
		return false
	if not _valid_owner(parts[1]):
		return false
	if not parts[2] is String or not CATALOG.has(str(parts[2])):
		return false
	if not _valid_people(parts[3]):
		return false
	if not parts[4] is String or not EQUIPMENT.has(str(parts[4])):
		return false
	if not _valid_station(parts[5]):
		return false
	if not _valid_time(parts[6]):
		return false
	if str(result["unit_id"]) != command_id:
		return false
	var expected: Dictionary = _recruit_cost(str(parts[2]), int(parts[3]),
		str(parts[4]))
	return int(cost["cash"]) == int(expected["cash"]) \
		and int(cost["supplies"]) == int(expected["supplies"])


static func _valid_disband_record(command_id: String, parts: Array,
		result: Dictionary, cost: Dictionary) -> bool:
	if parts.size() != 3:
		return false
	if not parts[0] is String or str(parts[0]) != command_id:
		return false
	if not _valid_unit_id(parts[1]):
		return false
	if not _valid_owner(parts[2]):
		return false
	if str(result["unit_id"]) != str(parts[1]):
		return false
	return int(cost["cash"]) == 0 and int(cost["supplies"]) == 0


## 单位行必须与它记录的招募命令一致。人数只会因欠供下降，因此当前人数不能
## 超过招募时人数；其余字段与招募 payload 完全一致。
static func _valid_unit_record(entry: Dictionary, unit_id: String,
		row: Dictionary) -> bool:
	var result: Dictionary = entry["result"]
	if str(result["kind"]) != RECORD_RECRUIT \
			or str(result["unit_id"]) != unit_id:
		return false
	var parsed: Variant = _parse_payload(str(entry["payload"]))
	if not parsed is Array:
		return false
	var parts: Array = parsed
	if parts.size() != 7:
		return false
	if str(parts[1]) != str(row["owner"]):
		return false
	if str(parts[2]) != str(row["kind"]):
		return false
	if str(parts[4]) != str(row["equipment"]):
		return false
	if str(parts[5]) != str(row["station"]):
		return false
	if float(parts[6]) != float(row["recruited_utc"]):
		return false
	return int(row["people"]) <= int(parts[3])


static func _has_recruit_record(commands: Dictionary, unit_id: String) -> bool:
	var entry_value: Variant = commands.get(unit_id)
	if not entry_value is Dictionary:
		return false
	var result_value: Variant = entry_value.get("result")
	if not result_value is Dictionary:
		return false
	var result: Dictionary = result_value
	return str(result.get("kind", "")) == RECORD_RECRUIT \
		and str(result.get("unit_id", "")) == unit_id


static func _valid_last_upkeep(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	if not is_finite(number):
		return false
	if number == NEVER_UPKEPT:
		return true
	return number >= 0.0 and number <= float(MAX_SAFE_INTEGER)


static func _valid_people(value: Variant) -> bool:
	return _is_count(value) and int(value) >= 1 \
		and int(value) <= MAX_PEOPLE_PER_UNIT


static func _valid_unpaid_days(value: Variant) -> bool:
	return _is_count(value) and int(value) <= MAX_UNPAID_DAYS


## 工资时钟必须合法，且不能早于招募时刻：招募时两者对齐，之后只前进。
static func _valid_wage_clock(wage_utc: Variant, recruited_utc: Variant) -> bool:
	return _valid_time(wage_utc) and _valid_time(recruited_utc) \
		and float(wage_utc) >= float(recruited_utc)


static func _valid_owner(value: Variant) -> bool:
	return value is String and str(value) != "public" and OwnerIds.valid(value)


static func _valid_station(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	return not text.is_empty() and text.length() <= MAX_STATION_LENGTH \
		and OwnerIds.valid(text)


static func _valid_unit_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_UNIT_ID_LENGTH


static func _valid_command_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_COMMAND_ID_LENGTH


static func _valid_world_id(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_WORLD_ID_LENGTH:
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		var letter: bool = (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var digit: bool = code >= 48 and code <= 57
		if not letter and not digit and code != 95 and code != 45 and code != 46 \
				and code != 58:
			return false
	return true


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) >= 0.0 and float(value) <= float(MAX_SAFE_INTEGER)


static func _is_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 \
		and number <= float(MAX_SAFE_INTEGER) and number == floorf(number)


static func _exact_keys(value: Dictionary, keys: Array[String]) -> bool:
	if value.size() != keys.size():
		return false
	for key: String in keys:
		if not value.has(key):
			return false
	return true


static func _parse_payload(text: String) -> Variant:
	# JSON.parse_string 会对损坏输入打印引擎错误；校验路径把损坏当作普通拒绝。
	var json: JSON = JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


static func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
