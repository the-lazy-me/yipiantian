extends RefCounted
## M12-03 交战与转移的最小纯规则结算切片。全部入口为静态函数；无随机数、
## 无系统时钟、无磁盘、无场景、无网络，所有命令显式传入 `now_utc`。
##
## 本切片只在规则层结算单次交战：校验命令、冻结本次涉及资源、产生唯一结果、
## 扣除防守方损失并把其中一部分作为战利品发给进攻方。它不接网络、不写农场
## 存档、不发 RPC；结算产生的候选文档与冻结项由调用方负责原子落盘。
##
## 结算上下文文档：
##
##   {
##     "world_id": "world-...",
##     "sequence": 0,
##     "resources": {
##       "<player>": {"cash": 0, "supplies": 0},
##     },
##     "targets": {
##       "<defender>|<parcel_id>": {
##         "key": "<defender>|<parcel_id>",
##         "target": "<defender>",
##         "parcel_id": "<parcel_id>" | "",
##         "lost": 0,
##         "cap": 100,
##       },
##     },
##     "participation": <ConflictParticipation 的完整文档>,
##     "consumed": {
##       "<command_id>": {
##         "payload": "[...]",
##         "outcome": {...},
##         "freeze": [...],
##       },
##     },
##   }
##
## 关键不变量：
## - 参与资格完全复用 `Game/conflict/participation_state.gd`：和平档拒绝、
##   区域/窗口、同意、退战、离线损失上限和修订失效都由它判定，本模块不复制
##   一套参与规则。这里额外维护“同目标累计损失与上限”，防止反复袭击同一目标
##   突破目标预算。
## - 命令必须显式携带时间；`at_utc` 不能晚于 `now_utc`，也不能早于
##   `COMMAND_MAX_AGE_SECONDS`，否则分别返回 `future_time` / `stale_window`。
## - 结算完全确定：损失由投入兵力和两个上限算出，无随机数。
## - 损失不超过防守方实际资源，资源不为负；战利品不超过实际损失，剩余部分
##   作为明确销毁量。双方资源总量减少量等于 outcome.destroyed。
## - 同一命令 id 只结算一次：重复提交同 payload 回放首次结果且不再次发放
##   战利品；同 id 换 payload 返回 `duplicate_command`。
## - `freeze` 是调用方需要落盘的冻结项列表（进攻方出征消耗、防守方被扣损失），
##   已按 command_id 去重；重复提交不会重复冻结或发放。
## - 失败命令不修改输入，也不产生任何资源变化。

const Participation = preload("res://conflict/participation_state.gd")
const OwnerIds = preload("res://farm/owner_id.gd")

## 每点兵力出征消耗的资源，由进攻方以物资支付并销毁。
const SUPPLY_COST_PER_TROOP: int = 1
## 每点兵力造成的规则层损失；实际损失还会被目标上限、参与上限和可用资源压低。
const LOSS_PER_TROOP: int = 1
## 战利品占实际损失的比例（万分比）。5000 即一半；其余部分明确销毁。
const SPOILS_BPS: int = 5000
## 命令超过这个年龄后视为过期，避免旧命令在结算层被无限重放。
const COMMAND_MAX_AGE_SECONDS: float = 3600.0

const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_TROOPS: int = 1000000
const MAX_COORD: int = 4096
const MAX_RESOURCES: int = 256
const MAX_TARGETS: int = 256
const MAX_CONSUMED: int = 1024
const MAX_COMMAND_ID_LENGTH: int = 128
const MAX_ENTRY_ID_LENGTH: int = 64
const MAX_WORLD_ID_LENGTH: int = 128
const MAX_PAYLOAD_LENGTH: int = 8192

const REASON_INVALID_CONTEXT: String = "invalid_context"
const REASON_INVALID_COMMAND: String = "invalid_command"
const REASON_INVALID_ATTACKER: String = "invalid_attacker"
const REASON_INVALID_DEFENDER: String = "invalid_defender"
const REASON_SAME_PLAYER: String = "same_player"
const REASON_INVALID_TROOPS: String = "invalid_troops"
const REASON_INVALID_POSITION: String = "invalid_position"
const REASON_INVALID_TIME: String = "invalid_time"
const REASON_INVALID_TARGET: String = "invalid_target"
const REASON_INVALID_PARTICIPATION: String = "invalid_participation"
const REASON_UNKNOWN_TARGET: String = "unknown_target"
const REASON_PEACE_TIME: String = "peace_time"
const REASON_NO_CONSENT: String = "no_consent"
const REASON_INSUFFICIENT_RESOURCES: String = "insufficient_resources"
const REASON_TARGET_CAP: String = "target_cap"
const REASON_DUPLICATE_COMMAND: String = "duplicate_command"
const REASON_STALE_WINDOW: String = "stale_window"
const REASON_FUTURE_TIME: String = "future_time"
const REASON_CAPACITY: String = "capacity"

const FREEZE_ATTACK_COST: String = "attack_cost"
const FREEZE_AT_RISK_LOSS: String = "at_risk_loss"
const FREEZE_RESOURCES: Array[String] = ["cash", "supplies"]
const FREEZE_REASONS: Array[String] = [FREEZE_ATTACK_COST, FREEZE_AT_RISK_LOSS]

const CONTEXT_KEYS: Array[String] = [
	"world_id", "sequence", "resources", "targets", "participation", "consumed",
]
const RESOURCE_KEYS: Array[String] = ["cash", "supplies"]
const TARGET_KEYS: Array[String] = ["key", "target", "parcel_id", "lost", "cap"]
const CONSUMED_KEYS: Array[String] = ["payload", "outcome", "freeze"]
const FREEZE_KEYS: Array[String] = [
	"owner", "resource", "amount", "command_id", "reason",
]
const OUTCOME_KEYS: Array[String] = [
	"command_id", "attacker", "defender", "target", "parcel_id", "troops",
	"x", "z", "defender_online", "at_utc", "losses", "taken_cash",
	"taken_supplies", "spoils", "spoils_cash", "spoils_supplies", "destroyed",
	"supply_cost", "target_lost_before", "target_lost_after", "target_cap",
	"window_id", "participation_loss_before", "participation_cap",
]
const COMMAND_KEYS: Array[String] = [
	"id", "attacker", "defender", "troops", "x", "z", "defender_online", "at_utc",
]
const OPTIONAL_TARGET_PARCEL: String = "target_parcel"


## 新建一个空结算上下文。参与制度文档原样复制进候选文档；资源、目标预算和
## 已消费命令由调用方按世界事实补齐。
static func initial_context(world_id: String, participation: Variant) -> Dictionary:
	var participation_copy: Dictionary = {}
	if participation is Dictionary:
		participation_copy = participation.duplicate(true)
	return {
		"world_id": world_id,
		"sequence": 0,
		"resources": {},
		"targets": {},
		"participation": participation_copy,
		"consumed": {},
	}


## 目标累计键：同一防守方 + 同一地块共用一个损失预算；没有地块时用空串。
static func target_key(defender: String, parcel_id: String) -> String:
	return defender + "|" + parcel_id


## 结算单次交战。成功返回候选文档 `next_context` 和需要调用方落盘的 `freeze`
## 列表；失败返回稳定原因且不改动输入。重复命令同 payload 回放首次结果，
## 不会再次扣除资源或发放战利品。
static func settle(state: Variant, command: Variant, now_utc: Variant) -> Dictionary:
	if not state is Dictionary:
		return _failure(REASON_INVALID_CONTEXT, {})
	var context: Dictionary = state
	if not valid_context(context):
		return _failure(REASON_INVALID_CONTEXT, context)
	if not _valid_time(now_utc):
		return _failure(REASON_INVALID_TIME, context)
	var parsed: Dictionary = _parse_command(command)
	if not bool(parsed.get("ok", false)):
		return _failure(str(parsed.get("reason", REASON_INVALID_COMMAND)), context)
	var cmd: Dictionary = parsed.command
	var command_id: String = str(cmd["id"])
	var attacker: String = str(cmd["attacker"])
	var defender: String = str(cmd["defender"])
	var target_parcel: String = str(cmd["target_parcel"])
	var troops: int = int(cmd["troops"])
	var x: int = int(cmd["x"])
	var z: int = int(cmd["z"])
	var online: bool = bool(cmd["defender_online"])
	var at_utc: float = float(cmd["at_utc"])
	var now: float = float(now_utc)

	var payload: String = _payload(command_id, attacker, defender, target_parcel,
		troops, x, z, online, at_utc)
	var consumed: Dictionary = context["consumed"]
	if consumed.has(command_id):
		var entry: Variant = consumed[command_id]
		if not entry is Dictionary or str(entry.get("payload", "")) != payload:
			return _failure(REASON_DUPLICATE_COMMAND, context)
		var stored_outcome: Variant = entry.get("outcome")
		var stored_freeze: Variant = entry.get("freeze")
		if not stored_outcome is Dictionary or not stored_freeze is Array:
			return _failure(REASON_INVALID_CONTEXT, context)
		# 回放不产生新的资源变化；freeze 按 command_id 幂等，可安全重复落盘。
		return _success(true, stored_outcome.duplicate(true), stored_freeze.duplicate(true),
			context)

	# 同一 id 已经出现在参与制度文档的耐久行里：即使结算层没见过它，也不能
	# 再发一次战利品。
	if _participation_id_taken(context["participation"], command_id):
		return _failure(REASON_DUPLICATE_COMMAND, context)

	if at_utc > now:
		return _failure(REASON_FUTURE_TIME, context)
	if now - at_utc > COMMAND_MAX_AGE_SECONDS:
		return _failure(REASON_STALE_WINDOW, context)

	var key: String = target_key(defender, target_parcel)
	var targets: Dictionary = context["targets"]
	if not targets.has(key):
		return _failure(REASON_UNKNOWN_TARGET, context)
	var target_row: Variant = targets[key]
	if not target_row is Dictionary \
			or str(target_row.get("target", "")) != defender \
			or str(target_row.get("parcel_id", "")) != target_parcel:
		return _failure(REASON_UNKNOWN_TARGET, context)
	var target_lost_before: int = int(target_row.get("lost", 0))
	var target_cap: int = int(target_row.get("cap", 0))
	var target_remaining: int = target_cap - target_lost_before
	if target_remaining <= 0:
		return _failure(REASON_TARGET_CAP, context)

	var resources: Dictionary = context["resources"]
	var attacker_row: Dictionary = _resources_for(resources, attacker)
	var defender_row: Dictionary = _resources_for(resources, defender)
	var supply_cost: int = troops * SUPPLY_COST_PER_TROOP
	if int(attacker_row["supplies"]) < supply_cost:
		return _failure(REASON_INSUFFICIENT_RESOURCES, context)
	if consumed.size() >= MAX_CONSUMED:
		return _failure(REASON_CAPACITY, context)

	# 用参与制度的现成 engage 判定做只读探测：和平、区域、窗口、同意、退战、
	# 离线上限和修订失效都由它给出。探测只改副本，结果立即丢弃。
	var probe: Dictionary = _probe(context["participation"], str(context["world_id"]),
		attacker, defender, x, z, at_utc, online, command_id)
	if not bool(probe.get("ok", false)):
		return _failure(_map_participation_reason(str(probe.get("reason", ""))), context)
	var window_id: String = str(probe.get("window_id", ""))
	var participation_cap: int = int(probe.get("cap", 0))
	# probe 以 amount=1 成功，返回的 loss_total 已包含这 1 点探测损失。
	var participation_loss_before: int = int(probe.get("loss_total", 0)) - 1
	if participation_loss_before < 0 or participation_cap <= 0:
		return _failure(REASON_INVALID_PARTICIPATION, context)
	var participation_remaining: int = participation_cap - participation_loss_before
	if participation_remaining <= 0:
		return _failure(REASON_TARGET_CAP, context)

	var defender_cash: int = int(defender_row["cash"])
	var defender_supplies: int = int(defender_row["supplies"])
	var available: int = defender_cash + defender_supplies
	var raw_loss: int = troops * LOSS_PER_TROOP
	var losses: int = mini(mini(raw_loss, target_remaining),
		mini(participation_remaining, available))
	if losses <= 0:
		if target_remaining <= 0 or participation_remaining <= 0:
			return _failure(REASON_TARGET_CAP, context)
		# 防守方没有任何可损失资源，攻击不产生零值战利品结算。
		return _failure(REASON_INSUFFICIENT_RESOURCES, context)

	# 先扣现金再扣物资，结算顺序固定，便于复现与审计。
	var taken_cash: int = mini(losses, defender_cash)
	var taken_supplies: int = losses - taken_cash
	var spoils_cash: int = taken_cash * SPOILS_BPS / 10000
	var spoils_supplies: int = taken_supplies * SPOILS_BPS / 10000
	var spoils: int = spoils_cash + spoils_supplies
	var destroyed: int = supply_cost + losses - spoils

	var next: Dictionary = context.duplicate(true)
	var next_resources: Dictionary = next["resources"]
	var next_attacker: Dictionary = _resources_for(next_resources, attacker)
	var next_defender: Dictionary = _resources_for(next_resources, defender)
	next_attacker["cash"] = int(next_attacker["cash"]) + spoils_cash
	next_attacker["supplies"] = int(next_attacker["supplies"]) - supply_cost \
		+ spoils_supplies
	next_defender["cash"] = int(next_defender["cash"]) - taken_cash
	next_defender["supplies"] = int(next_defender["supplies"]) - taken_supplies
	next_resources[attacker] = next_attacker
	next_resources[defender] = next_defender

	var next_targets: Dictionary = next["targets"]
	var next_target: Dictionary = next_targets[key]
	next_target["lost"] = target_lost_before + losses
	next_targets[key] = next_target

	# 在全新副本上用真实损失和命令 id 写入参与制度，形成耐久交战行。探测已
	# 证明同一输入的同意与上限成立，这里失败只可能是输入被并发改动或 id 冲突。
	var final_participation: Dictionary = context["participation"].duplicate(true)
	var engaged: Dictionary = Participation.engage(final_participation,
		str(context["world_id"]), attacker, defender, x, z, at_utc, losses, online,
		command_id)
	if not bool(engaged.get("ok", false)):
		return _failure(_map_participation_reason(str(engaged.get("reason", ""))), context)
	if str(engaged.get("window_id", "")) != window_id:
		return _failure(REASON_INVALID_PARTICIPATION, context)
	next["participation"] = final_participation

	var freeze: Array = []
	freeze.append({
		"owner": attacker,
		"resource": "supplies",
		"amount": supply_cost,
		"command_id": command_id,
		"reason": FREEZE_ATTACK_COST,
	})
	if taken_cash > 0:
		freeze.append({
			"owner": defender,
			"resource": "cash",
			"amount": taken_cash,
			"command_id": command_id,
			"reason": FREEZE_AT_RISK_LOSS,
		})
	if taken_supplies > 0:
		freeze.append({
			"owner": defender,
			"resource": "supplies",
			"amount": taken_supplies,
			"command_id": command_id,
			"reason": FREEZE_AT_RISK_LOSS,
		})

	var outcome: Dictionary = {
		"command_id": command_id,
		"attacker": attacker,
		"defender": defender,
		"target": key,
		"parcel_id": target_parcel,
		"troops": troops,
		"x": x,
		"z": z,
		"defender_online": online,
		"at_utc": at_utc,
		"losses": losses,
		"taken_cash": taken_cash,
		"taken_supplies": taken_supplies,
		"spoils": spoils,
		"spoils_cash": spoils_cash,
		"spoils_supplies": spoils_supplies,
		"destroyed": destroyed,
		"supply_cost": supply_cost,
		"target_lost_before": target_lost_before,
		"target_lost_after": target_lost_before + losses,
		"target_cap": target_cap,
		"window_id": window_id,
		"participation_loss_before": participation_loss_before,
		"participation_cap": participation_cap,
	}
	var next_consumed: Dictionary = next["consumed"]
	next_consumed[command_id] = {
		"payload": payload,
		"outcome": outcome.duplicate(true),
		"freeze": freeze.duplicate(true),
	}
	next["sequence"] = int(next["sequence"]) + 1
	return _success(false, outcome, freeze, next)


## 严格校验结算上下文。除了形状、资源和目标预算，还要求每条已消费命令都能
## 在参与制度文档里找到同 id、同参数、同损失的耐久交战行，且目标累计损失
## 等于已消费结果之和。
static func valid_context(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var context: Dictionary = value
	if context.size() != CONTEXT_KEYS.size():
		return false
	for key: String in CONTEXT_KEYS:
		if not context.has(key):
			return false
	if not _valid_world_id(context["world_id"]):
		return false
	if not _is_count(context["sequence"]) \
			or int(context["sequence"]) >= MAX_SAFE_INTEGER:
		return false

	var resources: Variant = context["resources"]
	if not resources is Dictionary or resources.size() > MAX_RESOURCES:
		return false
	for owner: Variant in resources:
		if not _valid_player(owner):
			return false
		var row: Variant = resources[owner]
		if not row is Dictionary or row.size() != RESOURCE_KEYS.size():
			return false
		for field: String in RESOURCE_KEYS:
			if not row.has(field):
				return false
		if not _is_count(row["cash"]) or not _is_count(row["supplies"]):
			return false

	var targets: Variant = context["targets"]
	if not targets is Dictionary or targets.size() > MAX_TARGETS:
		return false
	for target: Variant in targets:
		var key: String = str(target)
		if not _valid_target_key(key):
			return false
		var row: Variant = targets[target]
		if not row is Dictionary or row.size() != TARGET_KEYS.size():
			return false
		for field: String in TARGET_KEYS:
			if not row.has(field):
				return false
		if str(row["key"]) != key:
			return false
		if not _valid_player(row["target"]):
			return false
		if not row["parcel_id"] is String:
			return false
		var parcel_id: String = str(row["parcel_id"])
		if not parcel_id.is_empty() and not _valid_entry_id(parcel_id):
			return false
		if key != target_key(str(row["target"]), parcel_id):
			return false
		if not _is_count(row["lost"]) or not _is_count(row["cap"]):
			return false
		if int(row["cap"]) <= 0 or int(row["lost"]) > int(row["cap"]):
			return false

	var participation: Variant = context["participation"]
	if not participation is Dictionary or not Participation.valid(participation):
		return false
	if str(participation["world_id"]) != str(context["world_id"]):
		return false

	var consumed: Variant = context["consumed"]
	if not consumed is Dictionary or consumed.size() > MAX_CONSUMED:
		return false
	var sums: Dictionary = {}
	for command_id: Variant in consumed:
		if not _valid_command_id(command_id):
			return false
		var entry: Variant = consumed[command_id]
		if not entry is Dictionary or entry.size() != CONSUMED_KEYS.size():
			return false
		for field: String in CONSUMED_KEYS:
			if not entry.has(field):
				return false
		if not entry["payload"] is String or not entry["freeze"] is Array:
			return false
		var payload: String = str(entry["payload"])
		if payload.length() > MAX_PAYLOAD_LENGTH:
			return false
		var outcome: Variant = entry["outcome"]
		if not outcome is Dictionary or not _valid_outcome(outcome, str(command_id)):
			return false
		if not _payload_matches(payload, outcome, str(command_id)):
			return false
		if not _valid_freeze(entry["freeze"], outcome):
			return false
		if not _valid_settlement_engagement(participation, outcome, str(command_id)):
			return false
		var key: String = str(outcome["target"])
		if not targets.has(key):
			return false
		sums[key] = int(sums.get(key, 0)) + int(outcome["losses"])

	for key: Variant in targets:
		if int(targets[key]["lost"]) != int(sums.get(str(key), 0)):
			return false
	# 成功结算每次都追加一行已消费命令并让 sequence 加一。
	if int(context["sequence"]) < consumed.size():
		return false
	return true


static func _parse_command(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"ok": false, "reason": REASON_INVALID_COMMAND}
	var command: Dictionary = value
	if command.size() < COMMAND_KEYS.size() or command.size() > COMMAND_KEYS.size() + 1:
		return {"ok": false, "reason": REASON_INVALID_COMMAND}
	for field: String in COMMAND_KEYS:
		if not command.has(field):
			return {"ok": false, "reason": REASON_INVALID_COMMAND}
	for field: Variant in command:
		if not COMMAND_KEYS.has(str(field)) and str(field) != OPTIONAL_TARGET_PARCEL:
			return {"ok": false, "reason": REASON_INVALID_COMMAND}
	var command_id: Variant = command["id"]
	if not _valid_command_id(command_id):
		return {"ok": false, "reason": REASON_INVALID_COMMAND}
	var attacker: Variant = command["attacker"]
	if not _valid_player(attacker):
		return {"ok": false, "reason": REASON_INVALID_ATTACKER}
	var defender: Variant = command["defender"]
	if not _valid_player(defender):
		return {"ok": false, "reason": REASON_INVALID_DEFENDER}
	if str(attacker) == str(defender):
		return {"ok": false, "reason": REASON_SAME_PLAYER}
	var troops: Variant = command["troops"]
	if not _is_count(troops) or int(troops) <= 0 or int(troops) > MAX_TROOPS:
		return {"ok": false, "reason": REASON_INVALID_TROOPS}
	if not _valid_coord(command["x"]) or not _valid_coord(command["z"]):
		return {"ok": false, "reason": REASON_INVALID_POSITION}
	if not command["defender_online"] is bool:
		return {"ok": false, "reason": REASON_INVALID_COMMAND}
	if not _valid_time(command["at_utc"]):
		return {"ok": false, "reason": REASON_INVALID_TIME}
	var target_parcel: String = ""
	if command.has(OPTIONAL_TARGET_PARCEL):
		var raw: Variant = command[OPTIONAL_TARGET_PARCEL]
		if not raw is String:
			return {"ok": false, "reason": REASON_INVALID_TARGET}
		target_parcel = str(raw)
		if not target_parcel.is_empty() and not _valid_entry_id(target_parcel):
			return {"ok": false, "reason": REASON_INVALID_TARGET}
	return {
		"ok": true,
		"reason": "",
		"command": {
			"id": str(command_id),
			"attacker": str(attacker),
			"defender": str(defender),
			"target_parcel": target_parcel,
			"troops": int(troops),
			"x": int(command["x"]),
			"z": int(command["z"]),
			"defender_online": bool(command["defender_online"]),
			"at_utc": float(command["at_utc"]),
		},
	}


static func _probe(participation: Dictionary, world_id: String, attacker: String,
		defender: String, x: int, z: int, at_utc: float, online: bool,
		command_id: String) -> Dictionary:
	var copy: Dictionary = participation.duplicate(true)
	return Participation.engage(copy, world_id, attacker, defender, x, z, at_utc,
		1, online, command_id)


## 把参与制度的稳定原因折叠成本模块的公开原因表，避免调用方同时处理两套词表。
static func _map_participation_reason(reason: String) -> String:
	match reason:
		"peace":
			return REASON_PEACE_TIME
		"regime_not_effective", "outside_window":
			return REASON_STALE_WINDOW
		"attacker_not_consented", "target_not_participating", \
		"attacker_withdrawn", "target_withdrawn":
			return REASON_NO_CONSENT
		"loss_cap_exceeded":
			return REASON_TARGET_CAP
		"command_conflict":
			return REASON_DUPLICATE_COMMAND
		_:
			return REASON_INVALID_PARTICIPATION


static func _participation_id_taken(participation: Dictionary, command_id: String) -> bool:
	if participation.get("engagements", {}).has(command_id):
		return true
	if participation.get("command_results", {}).has(command_id):
		return true
	var regime: Variant = participation.get("regime")
	if regime is Dictionary and str(regime.get("command_id", "")) == command_id:
		return true
	var participants: Variant = participation.get("participants")
	if not participants is Dictionary:
		return false
	for player_id: Variant in participants:
		var participant: Variant = participants[player_id]
		if not participant is Dictionary:
			continue
		if str(participant.get("consent_command_id", "")) == command_id:
			return true
		if str(participant.get("withdraw_command_id", "")) == command_id:
			return true
	return false


static func _valid_outcome(value: Dictionary, command_id: String) -> bool:
	if value.size() != OUTCOME_KEYS.size():
		return false
	for key: String in OUTCOME_KEYS:
		if not value.has(key):
			return false
	if not value["command_id"] is String or str(value["command_id"]) != command_id:
		return false
	if not _valid_player(value["attacker"]) or not _valid_player(value["defender"]):
		return false
	if str(value["attacker"]) == str(value["defender"]):
		return false
	if not _valid_target_key(value["target"]):
		return false
	if not value["parcel_id"] is String:
		return false
	var parcel_id: String = str(value["parcel_id"])
	if not parcel_id.is_empty() and not _valid_entry_id(parcel_id):
		return false
	if str(value["target"]) != target_key(str(value["defender"]), parcel_id):
		return false
	for field: String in ["troops", "x", "z", "losses", "taken_cash",
			"taken_supplies", "spoils", "spoils_cash", "spoils_supplies",
			"destroyed", "supply_cost", "target_lost_before", "target_lost_after",
			"target_cap", "participation_loss_before", "participation_cap"]:
		if not _is_count(value[field]):
			return false
	if not value["defender_online"] is bool or not _valid_time(value["at_utc"]):
		return false
	if not value["window_id"] is String or not _valid_entry_id(value["window_id"]):
		return false

	var troops: int = int(value["troops"])
	var losses: int = int(value["losses"])
	var taken_cash: int = int(value["taken_cash"])
	var taken_supplies: int = int(value["taken_supplies"])
	var spoils: int = int(value["spoils"])
	var spoils_cash: int = int(value["spoils_cash"])
	var spoils_supplies: int = int(value["spoils_supplies"])
	if troops <= 0 or troops > MAX_TROOPS:
		return false
	if int(value["x"]) > MAX_COORD or int(value["z"]) > MAX_COORD:
		return false
	if int(value["supply_cost"]) != troops * SUPPLY_COST_PER_TROOP:
		return false
	if losses <= 0 or losses > troops * LOSS_PER_TROOP:
		return false
	if taken_cash + taken_supplies != losses:
		return false
	if spoils_cash != taken_cash * SPOILS_BPS / 10000:
		return false
	if spoils_supplies != taken_supplies * SPOILS_BPS / 10000:
		return false
	if spoils != spoils_cash + spoils_supplies or spoils > losses:
		return false
	if int(value["destroyed"]) != int(value["supply_cost"]) + losses - spoils:
		return false
	if int(value["target_cap"]) <= 0:
		return false
	if int(value["target_lost_before"]) + losses != int(value["target_lost_after"]):
		return false
	if int(value["target_lost_after"]) > int(value["target_cap"]):
		return false
	if int(value["participation_cap"]) <= 0:
		return false
	if int(value["participation_loss_before"]) < 0:
		return false
	if int(value["participation_loss_before"]) + losses \
			> int(value["participation_cap"]):
		return false
	return true


static func _valid_freeze(value: Variant, outcome: Dictionary) -> bool:
	if not value is Array:
		return false
	var expected: int = 1
	if int(outcome["taken_cash"]) > 0:
		expected += 1
	if int(outcome["taken_supplies"]) > 0:
		expected += 1
	if value.size() != expected:
		return false
	var attack_cost: int = 0
	var at_risk_cash: int = 0
	var at_risk_supplies: int = 0
	for item: Variant in value:
		if not item is Dictionary:
			return false
		var row: Dictionary = item
		if row.size() != FREEZE_KEYS.size():
			return false
		for field: String in FREEZE_KEYS:
			if not row.has(field):
				return false
		if not _valid_player(row["owner"]):
			return false
		var resource: String = str(row["resource"])
		if not FREEZE_RESOURCES.has(resource):
			return false
		if not _is_count(row["amount"]) or int(row["amount"]) <= 0:
			return false
		if not _valid_command_id(row["command_id"]) \
				or str(row["command_id"]) != str(outcome["command_id"]):
			return false
		var reason: String = str(row["reason"])
		if not FREEZE_REASONS.has(reason):
			return false
		if reason == FREEZE_ATTACK_COST:
			if str(row["owner"]) != str(outcome["attacker"]) or resource != "supplies":
				return false
			attack_cost += int(row["amount"])
		else:
			if str(row["owner"]) != str(outcome["defender"]):
				return false
			if resource == "cash":
				at_risk_cash += int(row["amount"])
			else:
				at_risk_supplies += int(row["amount"])
	if attack_cost != int(outcome["supply_cost"]):
		return false
	return at_risk_cash == int(outcome["taken_cash"]) \
		and at_risk_supplies == int(outcome["taken_supplies"])


## 已消费命令必须能在参与制度文档里找到同 id 的耐久交战行，且坐标、时间、
## 兵力损失和窗口完全一致。这样结算文档不能凭空多出一笔战利品。
static func _valid_settlement_engagement(participation: Dictionary, outcome: Dictionary,
		command_id: String) -> bool:
	var engagements: Variant = participation.get("engagements")
	if not engagements is Dictionary:
		return false
	var row: Variant = engagements.get(command_id)
	if not row is Dictionary:
		return false
	if str(row.get("attacker", "")) != str(outcome["attacker"]):
		return false
	if str(row.get("target", "")) != str(outcome["defender"]):
		return false
	if int(row.get("x", -1)) != int(outcome["x"]) \
			or int(row.get("z", -1)) != int(outcome["z"]):
		return false
	if float(row.get("at_utc", -1.0)) != float(outcome["at_utc"]):
		return false
	if int(row.get("amount", 0)) != int(outcome["losses"]):
		return false
	if bool(row.get("defender_online", false)) != bool(outcome["defender_online"]):
		return false
	return str(row.get("window_id", "")) == str(outcome["window_id"])


static func _payload_matches(payload: String, outcome: Dictionary,
		command_id: String) -> bool:
	var parsed: Variant = _parse_payload(payload)
	if not parsed is Array:
		return false
	var parts: Array = parsed
	if parts.size() != 9:
		return false
	if str(parts[0]) != command_id:
		return false
	if str(parts[1]) != str(outcome["attacker"]):
		return false
	if str(parts[2]) != str(outcome["defender"]):
		return false
	if str(parts[3]) != str(outcome["parcel_id"]):
		return false
	if not _is_count(parts[4]) or int(parts[4]) != int(outcome["troops"]):
		return false
	if not _is_count(parts[5]) or int(parts[5]) != int(outcome["x"]):
		return false
	if not _is_count(parts[6]) or int(parts[6]) != int(outcome["z"]):
		return false
	if not parts[7] is bool or bool(parts[7]) != bool(outcome["defender_online"]):
		return false
	if not _valid_time(parts[8]) or float(parts[8]) != float(outcome["at_utc"]):
		return false
	return true


static func _resources_for(resources: Dictionary, player_id: String) -> Dictionary:
	var row: Variant = resources.get(player_id)
	if row is Dictionary:
		return row
	return {"cash": 0, "supplies": 0}


static func _payload(command_id: String, attacker: String, defender: String,
		parcel_id: String, troops: int, x: int, z: int, online: bool,
		at_utc: float) -> String:
	return JSON.stringify([
		command_id, attacker, defender, parcel_id, troops, x, z, online, float(at_utc),
	])


static func _success(duplicate: bool, outcome: Dictionary, freeze: Array,
		next_context: Dictionary) -> Dictionary:
	return {
		"ok": true,
		"reason": "",
		"duplicate": duplicate,
		"outcome": outcome,
		"freeze": freeze,
		"next_context": next_context,
	}


static func _failure(reason: String, context: Dictionary) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"duplicate": false,
		"outcome": {},
		"freeze": [],
		"next_context": context,
	}


static func _valid_target_key(value: Variant) -> bool:
	if not value is String:
		return false
	var parts: PackedStringArray = str(value).split("|")
	if parts.size() != 2:
		return false
	if not _valid_player(parts[0]):
		return false
	return parts[1].is_empty() or _valid_entry_id(parts[1])


static func _valid_player(value: Variant) -> bool:
	return value is String and str(value) != "public" and OwnerIds.valid(value)


static func _valid_coord(value: Variant) -> bool:
	return _is_count(value) and int(value) >= 0 and int(value) <= MAX_COORD


static func _valid_entry_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_ENTRY_ID_LENGTH and OwnerIds.valid(value)


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
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)


static func _parse_payload(text: String) -> Variant:
	# JSON.parse_string 会对损坏输入打印引擎错误；校验路径把损坏当作普通拒绝。
	var json: JSON = JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data
