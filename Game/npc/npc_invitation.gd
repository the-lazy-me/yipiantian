extends RefCounted
## M10-04 NPC 邀约（纯规则切片）。不读 RNG、系统时钟、磁盘、场景或网络；
## 所有入口显式接收 `now_utc`，同一输入得到同一输出。本模块不接模型、UI、
## `WorldHost`、`HeadlessWorld` 或 `FarmState`，也不执行真实拜访、赠礼、扣款
## 或任何权属变更。
##
## 邀约文档形状（严格 `valid()`；未知键、越界、超限一律拒绝）：
##
##   {
##     "invitations": {
##       "inv_1234567890": {                    # id 由 from/to/kind/expires 派生
##         "id": "inv_1234567890",              # 必须与键相同
##         "from": "npc_lin_shen",              # OwnerIds.valid，不等于 to
##         "to": "npc_xu_bo",
##         "kind": "visit",                     # visit / meal / trade_talk
##         "created_utc": 1800000000.0,
##         "expires_utc": 1800003600.0,         # 严格晚于 created_utc
##         "status": "pending",                 # pending 时恰好这七个键
##       },
##       "inv_9876543210": {
##         # ... 同上七个键 ...
##         "status": "accepted",                # accepted / declined / expired / withdrawn
##         "decided_utc": 1800000100.0,         # created_utc <= decided_utc <= expires_utc
##         "reason": "accepted",                # 固定等于 status，不接受自由文本
##       },
##     },
##   }
##
## 上限：最多 MAX_INVITATIONS 条邀约，id 长度不超过 MAX_INVITATION_ID_LENGTH。
## 邀约种类与有效期来自固定目录，不接受调用方自造 id 或自由文本。
##
## 状态机：pending -> accepted / declined / withdrawn / expired，没有反向或
## 二次转换。只有收件人 `to` 可以接受或拒绝，只有发起人 `from` 可以撤回；
## 过期后继续决策返回 `expired`，并把该 pending 转成 expired。
##
## 边界：邀约只是一份可拒绝的提案。接受或拒绝不改变任何财产、权属、账户或
## 命令权限；`claim_from_narrative()` 永远返回 `not_authority`。
##
## 容量：表格最多 `MAX_INVITATIONS` 行。`prune()` 只淘汰已决终态行，让新邀约
## 在长驻留中继续可用；pending 行永远不会被它删除。淘汰不是丢历史：接受、拒绝
## 与撤回的结果已由 `NpcSocialMemory` 写进当事人有界记忆，过期行本就被该适配层
## 跳过。产品决定是“释放槽位优先于在表内永久保留全部历史”，因为容量耗尽会让
## 居民此后完全停止发起邀约。

const OwnerIds = preload("res://farm/owner_id.gd")

const KIND_VISIT: String = "visit"
const KIND_MEAL: String = "meal"
const KIND_TRADE_TALK: String = "trade_talk"
const KINDS: Array[String] = [KIND_VISIT, KIND_MEAL, KIND_TRADE_TALK]

## 每种邀约的固定有效期（秒）；`expires_utc = now_utc + TTL_SECONDS[kind]`。
const TTL_SECONDS: Dictionary = {
	KIND_VISIT: 3600.0,
	KIND_MEAL: 1800.0,
	KIND_TRADE_TALK: 900.0,
}

const STATUS_PENDING: String = "pending"
const STATUS_ACCEPTED: String = "accepted"
const STATUS_DECLINED: String = "declined"
const STATUS_EXPIRED: String = "expired"
const STATUS_WITHDRAWN: String = "withdrawn"
const STATUSES: Array[String] = [
	STATUS_PENDING, STATUS_ACCEPTED, STATUS_DECLINED, STATUS_EXPIRED, STATUS_WITHDRAWN,
]

const DECISION_ACCEPT: String = "accept"
const DECISION_DECLINE: String = "decline"
const DECISION_WITHDRAW: String = "withdraw"
const DECISIONS: Array[String] = [DECISION_ACCEPT, DECISION_DECLINE, DECISION_WITHDRAW]

const MAX_INVITATIONS: int = 128
const MAX_INVITATION_ID_LENGTH: int = 128
const MAX_SAFE_INTEGER: int = 9007199254740991

## 终态行的保留窗口（秒）：7 天，与自然时令长度（`NatureState.SEASON_SECONDS`）、
## 贷款最短期限和纠纷证据窗口同一尺度。窗口按 `decided_utc` 起算，晚于窗口的
## 终态行才可淘汰；pending 行不受窗口影响。
const DEFAULT_RETAIN_SECONDS: float = 604800.0

const DOCUMENT_KEYS: Array[String] = ["invitations"]
const REQUEST_KEYS: Array[String] = ["from", "to", "kind"]
const PENDING_KEYS: Array[String] = [
	"id", "from", "to", "kind", "created_utc", "expires_utc", "status",
]
const DECIDED_KEYS: Array[String] = [
	"id", "from", "to", "kind", "created_utc", "expires_utc", "status",
	"decided_utc", "reason",
]

const HASH_OFFSET: int = 2166136261
const HASH_PRIME: int = 16777619
const HASH_MASK: int = 0xFFFFFFFF


static func empty_document() -> Dictionary:
	return {"invitations": {}}


## 严格文档校验：恰好一个根键；每行按状态使用精确键集；from/to 合法且不同；
## 种类来自固定目录；id 必须等于键并由 from/to/kind/expires 确定性派生；
## `created_utc < expires_utc`；非 pending 行必须有 `created_utc <= decided_utc
## <= expires_utc`，且 `reason` 固定等于状态。未知键、超限一律拒绝。
static func valid(document: Variant) -> bool:
	if not document is Dictionary:
		return false
	var stored: Dictionary = document
	if stored.size() != DOCUMENT_KEYS.size():
		return false
	for key: String in DOCUMENT_KEYS:
		if not stored.has(key):
			return false
	if not stored.invitations is Dictionary:
		return false
	var invitations: Dictionary = stored.invitations
	if invitations.size() > MAX_INVITATIONS:
		return false
	for id_value: Variant in invitations:
		if not _valid_invitation_id(id_value):
			return false
		var invitation_id: String = str(id_value)
		var row_value: Variant = invitations[id_value]
		if not row_value is Dictionary:
			return false
		var row: Dictionary = row_value
		if not row.has("status"):
			return false
		var status_value: Variant = row.get("status")
		if not _valid_status(status_value):
			return false
		var status: String = str(status_value)
		var keys: Array[String] = PENDING_KEYS
		if status != STATUS_PENDING:
			keys = DECIDED_KEYS
		if not _exact_keys(row, keys):
			return false
		if not _valid_invitation_id(row.get("id")):
			return false
		if str(row.id) != invitation_id:
			return false
		if not _valid_owner_id(row.get("from")):
			return false
		if not _valid_owner_id(row.get("to")):
			return false
		if str(row.from) == str(row.to):
			return false
		if not _valid_kind(row.get("kind")):
			return false
		if not _valid_time(row.get("created_utc")):
			return false
		if not _valid_time(row.get("expires_utc")):
			return false
		var created_utc: float = float(row.created_utc)
		var expires_utc: float = float(row.expires_utc)
		if expires_utc <= created_utc:
			return false
		if invitation_id != _invitation_id(
				str(row.from), str(row.to), str(row.kind), expires_utc):
			return false
		if status != STATUS_PENDING:
			if not _valid_time(row.get("decided_utc")):
				return false
			var decided_utc: float = float(row.decided_utc)
			if decided_utc < created_utc or decided_utc > expires_utc:
				return false
			var reason_value: Variant = row.get("reason")
			if not reason_value is String or str(reason_value) != status:
				return false
	return true


## JSON 数字到达时都是 float；在严格校验之后归一，让内存文档保持写入形状。
static func normalize(document: Dictionary) -> void:
	var invitations_value: Variant = document.get("invitations")
	if not invitations_value is Dictionary:
		return
	var invitations: Dictionary = invitations_value
	for id_value: Variant in invitations:
		var row_value: Variant = invitations[id_value]
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		for key: String in ["created_utc", "expires_utc", "decided_utc"]:
			if row.has(key):
				row[key] = float(row[key])


## 校验一份提议但不写入。返回 `{ok, reason, invitation}`；成功时 `invitation`
## 是完整、待插入的 pending 行（含确定性 id）。失败不带候选文档。
static func validate_proposal(document: Variant, request: Variant,
		now_utc: float) -> Dictionary:
	return _check_proposal(document, request, now_utc)


## 创建一条 pending 邀约，返回候选文档而不修改输入。同一 (from,to,kind) 已有
## pending 时返回 `already_pending`；派生 id 已存在（不同时刻重放同一有效期）
## 返回 `duplicate_id`；达到总上限返回 `over_capacity`。失败只返回
## `{ok:false, reason}`，不带任何文档。
static func propose(document: Variant, request: Variant, now_utc: float) -> Dictionary:
	var checked: Dictionary = _check_proposal(document, request, now_utc)
	if not checked.ok:
		return checked
	var invitation: Dictionary = checked.invitation
	var candidate: Dictionary = (document as Dictionary).duplicate(true)
	candidate.invitations[str(invitation.id)] = invitation.duplicate(true)
	if not valid(candidate):
		return _fail("invalid_state")
	return {
		"ok": true, "reason": "", "document": candidate,
		"invitation": invitation.duplicate(true),
	}


## 决策前复校验：时间、文档、决策种类、id、存在性、权限、状态、过期。
## 成功只返回 `{ok:true, reason:"", invitation}`，不修改输入。
static func validate_decision(document: Variant, invitation_id: Variant,
		actor: Variant, decision: Variant, now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return _fail("invalid_time")
	if not valid(document):
		return _fail("invalid_document")
	if not _valid_decision(decision):
		return _fail("invalid_decision")
	if not _valid_invitation_id(invitation_id):
		return _fail("invalid_invitation_id")
	var invitations: Dictionary = (document as Dictionary).invitations
	var invitation_key: String = str(invitation_id)
	if not invitations.has(invitation_key):
		return _fail("unknown_invitation")
	var row: Dictionary = invitations[invitation_key]
	if str(decision) == DECISION_WITHDRAW:
		if not actor is String or str(actor) != str(row.from):
			return _fail("not_initiator")
	else:
		if not actor is String or str(actor) != str(row.to):
			return _fail("not_recipient")
	if str(row.status) != STATUS_PENDING:
		return _fail("not_pending")
	if float(now_utc) >= float(row.expires_utc):
		return _fail("expired")
	return {"ok": true, "reason": "", "invitation": row.duplicate(true)}


## 收件人接受 pending 邀约。只有 `to` 可以决定；非 pending 返回 `not_pending`；
## 已过期返回 `expired`，并附带把该邀约转为 expired 的候选文档（此时输入仍不
## 被修改）。接受不授予任何财产、权属、账户或命令权限。
static func accept(document: Variant, invitation_id: Variant, actor: Variant,
		now_utc: float) -> Dictionary:
	return _decide(document, invitation_id, actor, DECISION_ACCEPT, now_utc)


## 收件人拒绝 pending 邀约。边界与 `accept()` 相同，拒绝同样不改变任何权属。
static func decline(document: Variant, invitation_id: Variant, actor: Variant,
		now_utc: float) -> Dictionary:
	return _decide(document, invitation_id, actor, DECISION_DECLINE, now_utc)


## 发起人撤回 pending 邀约。只有 `from` 可以撤回；已过期返回 `expired` 并附带
## 转为 expired 的候选文档。
static func withdraw(document: Variant, invitation_id: Variant, actor: Variant,
		now_utc: float) -> Dictionary:
	return _decide(document, invitation_id, actor, DECISION_WITHDRAW, now_utc)


## 批量把到期 pending 转为 expired，返回候选文档而不修改输入。按 id 升序处理，
## 结果与字典遍历顺序无关；重复调用返回同样的文档且 `expired` 为 0。
static func expire(document: Variant, now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return _fail("invalid_time")
	if not valid(document):
		return _fail("invalid_document")
	var candidate: Dictionary = (document as Dictionary).duplicate(true)
	var invitations: Dictionary = candidate.invitations
	var ids: Array[String] = []
	for id_value: Variant in invitations:
		ids.append(str(id_value))
	ids.sort()
	var expired: int = 0
	for invitation_id: String in ids:
		var row: Dictionary = invitations[invitation_id]
		if str(row.status) == STATUS_PENDING \
				and float(now_utc) >= float(row.expires_utc):
			row.status = STATUS_EXPIRED
			row.decided_utc = float(row.expires_utc)
			row.reason = STATUS_EXPIRED
			expired += 1
	if not valid(candidate):
		return _fail("invalid_state")
	return {
		"ok": true, "reason": "", "document": candidate, "expired": expired,
	}


## 淘汰已决终态行，返回有界候选文档而不修改输入。只删除满足下列全部条件的行：
##
##   * `status` 不是 pending（受保护，永不淘汰）；
##   * `decided_utc + retain_seconds <= now_utc`（窗口内保留，边界时刻恰好释放）。
##
## 已决行已带合法的 `decided_utc`（`valid()` 保证落在 created..expires 内），
## 因此无需按状态分别取时刻。未知参数、非法时刻、非正或非有限保留窗口都失败
## 关闭。成功时附带按 id 升序的 `removed` 列表，候选文档仍通过 `valid()`；
## 同一输入得到同一输出。产品决定是释放槽位优先于在表内永久保留全部历史，
## 理由写入本模块头部注释。
static func prune(document: Variant, now_utc: Variant,
		retain_seconds: Variant) -> Dictionary:
	if not _valid_time(now_utc):
		return _fail("invalid_time")
	if not _valid_retain_seconds(retain_seconds):
		return _fail("invalid_retain_seconds")
	if not valid(document):
		return _fail("invalid_document")
	var candidate: Dictionary = (document as Dictionary).duplicate(true)
	var invitations: Dictionary = candidate.invitations
	var removed: Array[String] = []
	for id_value: Variant in invitations:
		var row: Dictionary = invitations[id_value]
		if str(row.status) == STATUS_PENDING:
			continue
		if float(row.decided_utc) + float(retain_seconds) <= float(now_utc):
			removed.append(str(id_value))
	removed.sort()
	for invitation_id: String in removed:
		invitations.erase(invitation_id)
	if not valid(candidate):
		return _fail("invalid_state")
	return {
		"ok": true, "reason": "", "document": candidate, "removed": removed,
	}


## 叙事不是权属、账户或命令权限来源。接受邀约也不会让模型叙述获得任何授权；
## 此处与 `npc_social.gd` / `npc_roles.gd` 保持同一原则。
static func claim_from_narrative(actor: Variant, claimed_action: Variant) -> Dictionary:
	return {
		"ok": false,
		"reason": "not_authority",
		"authority": false,
		"proposal_only": true,
		"actor": str(actor) if actor is String else "",
		"claimed_action": str(claimed_action),
	}


static func _check_proposal(document: Variant, request: Variant,
		now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return _fail("invalid_time")
	if not valid(document):
		return _fail("invalid_document")
	var checked: Dictionary = _check_request(request)
	if not checked.ok:
		return checked
	var from_id: String = str(checked.from)
	var to_id: String = str(checked.to)
	var kind: String = str(checked.kind)
	var created_utc: float = float(now_utc)
	var expires_utc: float = created_utc + float(TTL_SECONDS[kind])
	var invitation_id: String = _invitation_id(from_id, to_id, kind, expires_utc)
	var invitations: Dictionary = (document as Dictionary).invitations
	for existing_id: Variant in invitations:
		var existing: Dictionary = invitations[existing_id]
		if str(existing.status) == STATUS_PENDING \
				and str(existing.from) == from_id \
				and str(existing.to) == to_id \
				and str(existing.kind) == kind:
			return _fail("already_pending")
	if invitations.has(invitation_id):
		return _fail("duplicate_id")
	if invitations.size() >= MAX_INVITATIONS:
		return _fail("over_capacity")
	return {
		"ok": true,
		"reason": "",
		"invitation": {
			"id": invitation_id,
			"from": from_id,
			"to": to_id,
			"kind": kind,
			"created_utc": created_utc,
			"expires_utc": expires_utc,
			"status": STATUS_PENDING,
		},
	}


static func _check_request(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _fail("invalid_request")
	var request: Dictionary = value
	if not _exact_keys(request, REQUEST_KEYS):
		return _fail("invalid_request")
	if not _valid_owner_id(request.get("from")):
		return _fail("invalid_from")
	if not _valid_owner_id(request.get("to")):
		return _fail("invalid_to")
	if str(request.get("from")) == str(request.get("to")):
		return _fail("invalid_target")
	if not _valid_kind(request.get("kind")):
		return _fail("invalid_kind")
	return {
		"ok": true,
		"reason": "",
		"from": str(request.from),
		"to": str(request.to),
		"kind": str(request.kind),
	}


static func _decide(document: Variant, invitation_id: Variant, actor: Variant,
		decision: String, now_utc: float) -> Dictionary:
	var checked: Dictionary = validate_decision(
		document, invitation_id, actor, decision, now_utc)
	if not checked.ok:
		if str(checked.reason) == "expired":
			var expired_id: String = str(invitation_id)
			var original: Dictionary = (document as Dictionary).invitations[expired_id]
			var expired_candidate: Dictionary = _transition(
				document, expired_id, STATUS_EXPIRED, float(original.expires_utc))
			if not valid(expired_candidate):
				return _fail("invalid_state")
			return {
				"ok": false, "reason": "expired", "document": expired_candidate,
			}
		return _fail(str(checked.reason))
	var target: String = STATUS_ACCEPTED
	if decision == DECISION_DECLINE:
		target = STATUS_DECLINED
	elif decision == DECISION_WITHDRAW:
		target = STATUS_WITHDRAWN
	var candidate: Dictionary = _transition(
		document, str(invitation_id), target, float(now_utc))
	if not valid(candidate):
		return _fail("invalid_state")
	return {"ok": true, "reason": "", "document": candidate}


## 写时复制的单行状态转换；`decided_utc` 必须落在 created..expires 内。
static func _transition(document: Variant, invitation_id: String, status: String,
		decided_utc: float) -> Dictionary:
	var candidate: Dictionary = (document as Dictionary).duplicate(true)
	var row: Dictionary = candidate.invitations[invitation_id]
	row.status = status
	row.decided_utc = decided_utc
	row.reason = status
	return candidate


## id 由 `FNV-1a(["npc_invitation_v1", from, to, kind, 过期毫秒])` 确定性派生。
## 调用方不能自造 id 冒充足够的邀约；`valid()` 会重新推导并比对。
static func _invitation_id(from_id: String, to_id: String, kind: String,
		expires_utc: float) -> String:
	var expires_key: int = int(round(expires_utc * 1000.0))
	return "inv_" + str(_hash([
		"npc_invitation_v1", from_id, to_id, kind, str(expires_key),
	]))


static func _hash(parts: Array) -> int:
	var digest: int = HASH_OFFSET
	for part: Variant in parts:
		var bytes: PackedByteArray = str(part).to_utf8_buffer()
		for byte: int in bytes:
			digest = ((digest ^ byte) * HASH_PRIME) & HASH_MASK
	return digest


static func _valid_status(value: Variant) -> bool:
	return value is String and str(value) in STATUSES


static func _valid_decision(value: Variant) -> bool:
	return value is String and str(value) in DECISIONS


static func _valid_kind(value: Variant) -> bool:
	return value is String and str(value) in KINDS


static func _valid_owner_id(value: Variant) -> bool:
	return OwnerIds.valid(value)


static func _valid_invitation_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_INVITATION_ID_LENGTH


static func _valid_time(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	return is_finite(float(value)) and float(value) >= 0.0 \
		and float(value) <= float(MAX_SAFE_INTEGER)


## 保留窗口必须为正、有限且不超过安全整数；0 会让刚决策的行立刻消失，拒绝。
static func _valid_retain_seconds(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	return is_finite(float(value)) and float(value) > 0.0 \
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
