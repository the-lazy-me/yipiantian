extends RefCounted
## M12-01 / M12-03 交叉切片：单位 -> 交战结算 -> 单位损失。全部入口为静态函数；
## 无随机数、无系统时钟、无磁盘、无场景、无网络；`now_utc` 显式传入，同一输入
## 得到同一输出。写入口先复制再写入，失败不返回候选文档，输入逐字节不变。
##
## 本模块只把已有单位文档接到已有交战结算上：它不重新实现参与窗口、损失公式、
## 战利品或资产守恒，也不扣现金、不写农场、不发放战利品。参与资格与资源冻结
## 仍由 `conflict_settlement.gd` 调用 `participation_state.gd` 判定；结算返回的
## `freeze` / `outcome` / `next_context` 原样交给权威落账。分离传入的
## `participation_document` 只做严格校验与世界一致性检查，结算读取上下文内的
## 参与制度文档，回放时不会覆盖已推进的耐久交战行。
##
## 请求形状：
##
##   request = {
##     "id": "<command_id>",
##     "attacker": "<player>",
##     "defender": "<player>",
##     "attacker_units": ["<unit_id>", ...],
##     "defender_units": ["<unit_id>", ...],
##     "resources": {
##       "<attacker>": {"cash": 0, "supplies": 0},
##       "<defender>": {"cash": 0, "supplies": 0},
##     },
##     "x": 0, "z": 0, "defender_online": true, "at_utc": 0.0,
##     "target_parcel": "<parcel_id>",   # 可选
##   }
##
## 投影：
## - `troops` 取进攻方参战单位的 `people` 之和，作为结算命令的唯一兵力输入。
## - `power` 由 `unit_state.capability()` 求和得出，只用于报告；结算命令没有
##   战力字段，本切片不拿它改写损失。
## - 现金/物资不属于单位文档。`resources` 必须由调用方显式提供，并严格校验为
##   恰好覆盖进攻方与防守方两条非负整数行；新结算时覆盖结算上下文的对应行，
##   不做任何推导或捏造。
##
## 损失映射：
## - `outcome.losses` 是结算对进攻方兵力的损失；防守方在该结算里承担现金与
##   物资损失，不是人数损失。本切片只把该数值映射到进攻方参战单位，不把同一
##   数值再摊到防守方，也不新增战斗公式。
## - 只遍历请求列出的进攻方单位。单位按 id 升序、按人数比例分配：
##   `share_i = total_loss * people_i / total_people`（整数向下取整），余数按 id
##   升序补到仍有人数的单位（优先最小 id）；人数归零的单位从名册移除。
## - 损失超过进攻方参战总人数时该方参战单位全部移除，不产生负人数；防守方
##   参战单位保持不变。
##
## 幂等：
## - 复用结算文档的 `consumed`：同 id 同结算 payload 回放首次 `outcome` 与
##   `freeze`，桥接层据同一 `outcome` 重新映射损失；同 id 换结算 payload 由
##   结算层返回 `duplicate_command`。桥接层不额外持久化状态。
## - 回放应重发首次的单位文档。若调用方已经应用过候选文档再回放，桥接层无法
##   从输入区分“已应用”，会再次按同一 `outcome` 映射。

const Units = preload("res://conflict/unit_state.gd")
const Participation = preload("res://conflict/participation_state.gd")
const Settlement = preload("res://world/conflict_settlement.gd")
const OwnerIds = preload("res://farm/owner_id.gd")

const REQUEST_KEYS: Array[String] = [
	"id", "attacker", "defender", "attacker_units", "defender_units",
	"resources", "x", "z", "defender_online", "at_utc",
]
const OPTIONAL_TARGET_PARCEL: String = "target_parcel"
const RESOURCE_KEYS: Array[String] = ["cash", "supplies"]

const REASON_INVALID_UNITS: String = "invalid_units"
const REASON_INVALID_PARTICIPATION: String = "invalid_participation"
const REASON_INVALID_REQUEST: String = "invalid_request"
const REASON_INVALID_RESOURCES: String = "invalid_resources"
const REASON_INVALID_ATTACKER: String = "invalid_attacker"
const REASON_INVALID_DEFENDER: String = "invalid_defender"
const REASON_SAME_PLAYER: String = "same_player"
const REASON_EMPTY_UNITS: String = "empty_units"
const REASON_DUPLICATE_UNIT: String = "duplicate_unit"
const REASON_WRONG_WORLD: String = "wrong_world"


## 让已有单位文档参与一次已有交战结算，并把结算损失确定性地映射回单位人数。
## 成功返回 `units` 候选单位文档、`outcome` / `settlement`（结算结果原样）与
## `projection`（兵力与资源投影）；失败只返回具名原因，不返回候选文档。
static func engage(units_document: Variant, participation_document: Variant,
		settlement_context: Variant, request: Variant, now_utc: Variant) -> Dictionary:
	if not units_document is Dictionary or not Units.valid(units_document):
		return _failure(REASON_INVALID_UNITS)
	if not participation_document is Dictionary \
			or not Participation.valid(participation_document):
		return _failure(REASON_INVALID_PARTICIPATION)
	var parsed: Dictionary = _parse_request(request)
	if not bool(parsed.get("ok", false)):
		return _failure(str(parsed.get("reason", REASON_INVALID_REQUEST)))
	var req: Dictionary = parsed["request"]
	if not settlement_context is Dictionary:
		return _failure(Settlement.REASON_INVALID_CONTEXT)
	var context: Dictionary = settlement_context
	var consumed_value: Variant = context.get("consumed")
	var known: bool = consumed_value is Dictionary \
		and consumed_value.has(str(req["id"]))
	var working: Dictionary = context
	if not known:
		# 新结算才把调用方显式资源写入上下文副本；回放保留输入文档，避免把
		# 首次结算后的资源状态覆盖回请求里的出发值。
		working = context.duplicate(true)
		var resources_value: Variant = working.get("resources")
		if not resources_value is Dictionary:
			return _failure(Settlement.REASON_INVALID_CONTEXT)
		var resources: Dictionary = resources_value
		var requested: Dictionary = req["resources"]
		resources[str(req["attacker"])] = requested[str(req["attacker"])].duplicate(true)
		resources[str(req["defender"])] = requested[str(req["defender"])].duplicate(true)
	if not Settlement.valid_context(working):
		return _failure(Settlement.REASON_INVALID_CONTEXT)
	if str(working["world_id"]) != str(units_document["world_id"]) \
			or str(units_document["world_id"]) != str(participation_document["world_id"]):
		return _failure(REASON_WRONG_WORLD)

	var attacker: String = str(req["attacker"])
	var defender: String = str(req["defender"])
	var unit_rows: Dictionary = units_document["units"]
	var attacker_ids: Array = req["attacker_units"]
	var defender_ids: Array = req["defender_units"]
	var owner_reason: String = _check_owners(unit_rows, attacker_ids, attacker)
	if not owner_reason.is_empty():
		return _failure(owner_reason)
	owner_reason = _check_owners(unit_rows, defender_ids, defender)
	if not owner_reason.is_empty():
		return _failure(owner_reason)

	var attacker_projection: Dictionary = _project(units_document, attacker_ids, attacker)
	var defender_projection: Dictionary = _project(units_document, defender_ids, defender)
	if attacker_projection.is_empty() or defender_projection.is_empty():
		return _failure(REASON_INVALID_UNITS)

	var command: Dictionary = {
		"id": str(req["id"]),
		"attacker": attacker,
		"defender": defender,
		"troops": int(attacker_projection["people"]),
		"x": req["x"],
		"z": req["z"],
		"defender_online": req["defender_online"],
		"at_utc": req["at_utc"],
	}
	if bool(req["has_target_parcel"]):
		command[OPTIONAL_TARGET_PARCEL] = req["target_parcel"]

	var settled: Dictionary = Settlement.settle(working, command, now_utc)
	if not bool(settled.get("ok", false)):
		return _failure(str(settled.get("reason", Settlement.REASON_INVALID_CONTEXT)))

	var outcome: Dictionary = settled["outcome"]
	var total_loss: int = int(outcome.get("losses", 0))
	var next: Dictionary = units_document.duplicate(true)
	var next_units: Dictionary = next["units"]
	# `losses` 是结算对进攻方兵力的损失；防守方在该结算里承担的是现金与物资
	# 损失（见 conflict_settlement 的 freeze），不是人数损失。把同一数值也
	# 摊到防守方单位会凭空再减员，所以只映射进攻方。
	_apply_losses(next_units, attacker_ids, total_loss)
	next["sequence"] = int(next["sequence"]) + 1
	if not Units.valid(next):
		return _failure(REASON_INVALID_UNITS)

	attacker_projection["resources"] = req["resources"][attacker].duplicate(true)
	defender_projection["resources"] = req["resources"][defender].duplicate(true)
	return {
		"ok": true,
		"reason": "",
		"duplicate": bool(settled.get("duplicate", false)),
		"outcome": outcome,
		"units": next,
		"settlement": settled,
		"projection": {
			"attacker": attacker_projection,
			"defender": defender_projection,
		},
	}


static func _parse_request(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _failure(REASON_INVALID_REQUEST)
	var request: Dictionary = value
	if request.size() < REQUEST_KEYS.size() \
			or request.size() > REQUEST_KEYS.size() + 1:
		return _failure(REASON_INVALID_REQUEST)
	for key: String in REQUEST_KEYS:
		if not request.has(key):
			return _failure(REASON_INVALID_REQUEST)
	for key: Variant in request:
		if not REQUEST_KEYS.has(str(key)) and str(key) != OPTIONAL_TARGET_PARCEL:
			return _failure(REASON_INVALID_REQUEST)

	var command_id: Variant = request["id"]
	if not command_id is String or str(command_id).is_empty() \
			or str(command_id).length() > Settlement.MAX_COMMAND_ID_LENGTH:
		return _failure(REASON_INVALID_REQUEST)
	var attacker: Variant = request["attacker"]
	if not _valid_player(attacker):
		return _failure(REASON_INVALID_ATTACKER)
	var defender: Variant = request["defender"]
	if not _valid_player(defender):
		return _failure(REASON_INVALID_DEFENDER)
	if str(attacker) == str(defender):
		return _failure(REASON_SAME_PLAYER)

	var attacker_ids: Dictionary = _parse_ids(request["attacker_units"])
	if not bool(attacker_ids.get("ok", false)):
		return attacker_ids
	var defender_ids: Dictionary = _parse_ids(request["defender_units"])
	if not bool(defender_ids.get("ok", false)):
		return defender_ids
	var seen: Dictionary = {}
	for unit_id: Variant in attacker_ids["ids"]:
		seen[str(unit_id)] = true
	for unit_id: Variant in defender_ids["ids"]:
		if seen.has(str(unit_id)):
			return _failure(REASON_DUPLICATE_UNIT)

	var resources: Dictionary = _parse_resources(request["resources"],
		str(attacker), str(defender))
	if not bool(resources.get("ok", false)):
		return resources
	return {
		"ok": true,
		"reason": "",
		"request": {
			"id": str(command_id),
			"attacker": str(attacker),
			"defender": str(defender),
			"attacker_units": attacker_ids["ids"],
			"defender_units": defender_ids["ids"],
			"resources": resources["resources"],
			"x": request["x"],
			"z": request["z"],
			"defender_online": request["defender_online"],
			"at_utc": request["at_utc"],
			"target_parcel": request.get(OPTIONAL_TARGET_PARCEL),
			"has_target_parcel": request.has(OPTIONAL_TARGET_PARCEL),
		},
	}


static func _parse_ids(value: Variant) -> Dictionary:
	if not value is Array:
		return _failure(REASON_INVALID_REQUEST)
	var raw_ids: Array = value
	if raw_ids.is_empty():
		return _failure(REASON_EMPTY_UNITS)
	var ids: Array = []
	var seen: Dictionary = {}
	for raw: Variant in raw_ids:
		if not raw is String or str(raw).is_empty() \
				or str(raw).length() > Units.MAX_UNIT_ID_LENGTH:
			return _failure(REASON_INVALID_UNITS)
		var unit_id: String = str(raw)
		if seen.has(unit_id):
			return _failure(REASON_DUPLICATE_UNIT)
		seen[unit_id] = true
		ids.append(unit_id)
	ids.sort()
	return {"ok": true, "reason": "", "ids": ids}


static func _parse_resources(value: Variant, attacker: String,
		defender: String) -> Dictionary:
	if not value is Dictionary:
		return _failure(REASON_INVALID_RESOURCES)
	var resources: Dictionary = value
	if resources.size() != 2 or not resources.has(attacker) \
			or not resources.has(defender):
		return _failure(REASON_INVALID_RESOURCES)
	var parsed: Dictionary = {}
	for owner: Variant in [attacker, defender]:
		var row_value: Variant = resources[str(owner)]
		if not row_value is Dictionary:
			return _failure(REASON_INVALID_RESOURCES)
		var row: Dictionary = row_value
		if row.size() != RESOURCE_KEYS.size():
			return _failure(REASON_INVALID_RESOURCES)
		for key: String in RESOURCE_KEYS:
			if not row.has(key):
				return _failure(REASON_INVALID_RESOURCES)
		if not _is_count(row["cash"]) or not _is_count(row["supplies"]):
			return _failure(REASON_INVALID_RESOURCES)
		parsed[str(owner)] = {
			"cash": int(row["cash"]),
			"supplies": int(row["supplies"]),
		}
	return {"ok": true, "reason": "", "resources": parsed}


static func _check_owners(unit_rows: Dictionary, ids: Array, owner: String) -> String:
	for raw: Variant in ids:
		var unit_id: String = str(raw)
		if not unit_rows.has(unit_id):
			return Units.REASON_UNKNOWN_UNIT
		if str(unit_rows[unit_id]["owner"]) != owner:
			return Units.REASON_NOT_OWNER
	return ""


static func _project(document: Dictionary, ids: Array, owner: String) -> Dictionary:
	var people: int = 0
	var power: int = 0
	for raw: Variant in ids:
		var capability: Dictionary = Units.capability(document, str(raw))
		if not bool(capability.get("ok", false)):
			return {}
		people += int(capability["people"])
		power += int(capability["power"])
	return {
		"owner": owner,
		"unit_ids": ids.duplicate(),
		"people": people,
		"power": power,
	}


## 只修改传入的候选名册；`ids` 已按 id 升序且都属于同一方。
static func _apply_losses(unit_rows: Dictionary, ids: Array, total_loss: int) -> void:
	var total_people: int = 0
	for raw: Variant in ids:
		total_people += int(unit_rows[str(raw)]["people"])
	if total_loss <= 0 or total_people <= 0:
		return
	if total_loss >= total_people:
		for raw: Variant in ids:
			unit_rows.erase(str(raw))
		return

	var assigned: int = 0
	var losses: Dictionary = {}
	for raw: Variant in ids:
		var unit_id: String = str(raw)
		var people: int = int(unit_rows[unit_id]["people"])
		var share: int = total_loss * people / total_people
		losses[unit_id] = share
		assigned += share
	var remainder: int = total_loss - assigned
	for raw: Variant in ids:
		if remainder <= 0:
			break
		var unit_id: String = str(raw)
		var room: int = int(unit_rows[unit_id]["people"]) - int(losses[unit_id])
		var extra: int = mini(room, remainder)
		losses[unit_id] = int(losses[unit_id]) + extra
		remainder -= extra
	for raw: Variant in ids:
		var unit_id: String = str(raw)
		var survivors: int = int(unit_rows[unit_id]["people"]) - int(losses[unit_id])
		if survivors <= 0:
			unit_rows.erase(unit_id)
		else:
			var row: Dictionary = unit_rows[unit_id]
			row["people"] = survivors
			unit_rows[unit_id] = row


static func _valid_player(value: Variant) -> bool:
	return value is String and str(value) != "public" and OwnerIds.valid(value)


static func _is_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 \
		and number <= float(Units.MAX_SAFE_INTEGER) and number == floorf(number)


static func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
