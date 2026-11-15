extends RefCounted
## M12-04 纠纷登记与裁定规则。纯规则：无 RNG、无系统时钟、无磁盘、无场景、
## 无网络，也不读写 `FarmState`。所有命令都接收显式 UTC 时间，相同输入得到
## 相同输出。
##
## 本切片只把案件、证据、权限、申诉和更正整理成可校验的世界文档：
##
##   {
##     "authority_roles": {
##       "admin": ["player id", ...],
##       "arbiter": ["player id", ...],
##     },
##     "cases": {
##       "case_id": {
##         "filed_by": "player id",
##         "against": "player id",
##         "event_ids": ["authority event id", ...],
##         "evidence": [
##           {"id", "kind", "source", "submitted_by", "at_utc"},
##         ],
##         "status": "filed" | "accepted" | "rejected" | "ruled" |
##                   "appealed" | "corrected" | "closed",
##         "ruling": {} | {"by", "at_utc", "outcome", "reason"},
##         "appeals": [{"by", "at_utc", "reason"}],
##         "corrections": [{"by", "at_utc", "reason"}],
##         "manager_only": true,
##         "filed_utc": 0.0,
##         "audit": [{"action", "by", "at_utc"}],
##       }
##     }
##   }
##
## 与建议形状相比这里多了三个字段，都是为了让权限和审计能被文档自身校验：
## - `authority_roles` 是权威花名册，管理员/仲裁身份由文档决定，不信任调用方
##   临时自报的角色字符串。花名册为空时任何人都不能受理、裁定或更正。
## - `filed_utc` 给证据窗口提供锚点；证据只在立案后的固定窗口内受理。
## - `audit` 为每次管理员受理、驳回、裁定、更正和结案追加独立条目；AI 建议
##   永远不写入这里。
##
## 本切片不验证外部事件是否真实存在，也不执行任何资产扣减、补偿或封禁。它
## 只保证：案件必须由权威事件进入；受理、裁定和更正必须由花名册中的管理员/
## 仲裁发起；AI 只能得到 `advisory_only`；更正保留原裁定与全部申诉历史。
##
## 所有变更入口写时复制：输入文档始终保持逐字节不变，校验通过后才
## `duplicate(true)` 出候选并只修改候选。成功返回
## `{ok: true, reason: "", case_id, status, state}`；失败返回不含 `state` 的
## `{ok: false, reason, case_id}`。这样权威落盘失败时内存里不会留下半应用状态。

const OwnerIds = preload("res://farm/owner_id.gd")

const STATUS_FILED: String = "filed"
const STATUS_ACCEPTED: String = "accepted"
const STATUS_REJECTED: String = "rejected"
const STATUS_RULED: String = "ruled"
const STATUS_APPEALED: String = "appealed"
const STATUS_CORRECTED: String = "corrected"
const STATUS_CLOSED: String = "closed"
const STATUSES: Array[String] = [
	STATUS_FILED, STATUS_ACCEPTED, STATUS_REJECTED, STATUS_RULED,
	STATUS_APPEALED, STATUS_CORRECTED, STATUS_CLOSED,
]

const EVIDENCE_AUTHORITY_EVENT: String = "authority_event"
const EVIDENCE_LEDGER: String = "ledger"
const EVIDENCE_WITNESS: String = "witness"
const EVIDENCE_CHAT: String = "chat"
const EVIDENCE_DOCUMENT: String = "document"
const EVIDENCE_KINDS: Array[String] = [
	EVIDENCE_AUTHORITY_EVENT, EVIDENCE_LEDGER, EVIDENCE_WITNESS,
	EVIDENCE_CHAT, EVIDENCE_DOCUMENT,
]

## 管理员可以作出的裁定结果。本切片只记录结果语义，不据此扣减资产。
const OUTCOME_UPHELD: String = "upheld"
const OUTCOME_DISMISSED: String = "dismissed"
const OUTCOME_WARNING: String = "warning"
const OUTCOME_COMPENSATION: String = "compensation"
const OUTCOMES: Array[String] = [
	OUTCOME_UPHELD, OUTCOME_DISMISSED, OUTCOME_WARNING, OUTCOME_COMPENSATION,
]

const ACTION_ACCEPT: String = "accept"
const ACTION_REJECT: String = "reject"
const ACTION_RULE: String = "rule"
const ACTION_CORRECT: String = "correct"
const ACTION_CLOSE: String = "close"
const AUDIT_ACTIONS: Array[String] = [
	ACTION_ACCEPT, ACTION_REJECT, ACTION_RULE, ACTION_CORRECT, ACTION_CLOSE,
]

const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_CASES: int = 256
const MAX_AUTHORITY: int = 32
const MAX_EVENTS: int = 32
const MAX_EVIDENCE: int = 64
const MAX_REASON_LENGTH: int = 256
const MAX_SOURCE_LENGTH: int = 128

## 立案后的证据窗口。窗口结束后不再受理新证据；已有证据和裁定记录不删除。
const EVIDENCE_WINDOW_SECONDS: float = 604800.0

## 警告裁定的有效期，从 `ruling.at_utc` 起算。取 30 天与现有长期限一致
## （借款和保险的最长 30 天），也给被警告方一个完整、可预期的改正窗口；
## 它比 7 天证据窗口更长，因为警告针对的是后续行为而不是举证。
## 期限只由裁定时刻和本常量派生，不写入文档，旧文档无需迁移。
const WARNING_WINDOW_SECONDS: float = 2592000.0

## 警告的派生可见状态。它们不写入 `cases`，`valid()` 的严格键集不变；
## 案件、裁定和审计历史始终保留，到期只改变查询结果。
const WARNING_NOT_STARTED: String = "not_started"
const WARNING_ACTIVE: String = "active"
const WARNING_EXPIRED: String = "expired"

const STATE_KEYS: Array[String] = ["authority_roles", "cases"]
const ROLE_KEYS: Array[String] = ["admin", "arbiter"]
const CASE_KEYS: Array[String] = [
	"filed_by", "against", "event_ids", "evidence", "status", "ruling",
	"appeals", "corrections", "manager_only", "filed_utc", "audit",
]
const EVIDENCE_KEYS: Array[String] = ["id", "kind", "source", "submitted_by", "at_utc"]
const RULING_KEYS: Array[String] = ["by", "at_utc", "outcome", "reason"]
const APPEAL_KEYS: Array[String] = ["by", "at_utc", "reason"]
const CORRECTION_KEYS: Array[String] = ["by", "at_utc", "reason"]
const AUDIT_KEYS: Array[String] = ["action", "by", "at_utc"]
const DECISION_KEYS: Array[String] = ["advisor", "authority", "outcome", "reason"]

## 立案后到结案前都可以继续提交证据；驳回、更正后和已结案不再受理。
const EVIDENCE_STATUSES: Array[String] = [
	STATUS_FILED, STATUS_ACCEPTED, STATUS_RULED, STATUS_APPEALED,
]
const TERMINAL_STATUSES: Array[String] = [
	STATUS_REJECTED, STATUS_CORRECTED, STATUS_CLOSED,
]


static func empty(admin_ids: Array = [], arbiter_ids: Array = []) -> Dictionary:
	return {
		"authority_roles": {
			"admin": admin_ids.duplicate(),
			"arbiter": arbiter_ids.duplicate(),
		},
		"cases": {},
	}


## 严格文档校验：键集、枚举、时间、id、证据窗口、状态机、审计条目和上限
## 必须互相一致。任何无法由本模块操作产生的文档都会被拒绝。
static func valid(value: Variant) -> bool:
	if not value is Dictionary or (value as Dictionary).size() != STATE_KEYS.size():
		return false
	for key: String in STATE_KEYS:
		if not (value as Dictionary).has(key):
			return false
	if not _valid_authority_roles(value.authority_roles):
		return false
	if not value.cases is Dictionary or (value.cases as Dictionary).size() > MAX_CASES:
		return false
	for case_id: Variant in value.cases:
		if not _valid_entry_id(case_id):
			return false
		if not _valid_case(value, str(case_id), value.cases[case_id]):
			return false
	return true


## 立案。案件必须至少提供一个权威事件 id；重复案件 id 拒绝。立案本身不会
## 产生任何处罚，也不改变任何权属。
static func file(state: Dictionary, case_id: String, filed_by: String, against: String,
		event_ids: Variant, at_utc: float) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", case_id)
	if not _valid_entry_id(case_id):
		return _error("invalid_case", "")
	if not _valid_player(filed_by) or not _valid_player(against):
		return _error("invalid_player", case_id)
	if filed_by == against:
		return _error("same_player", case_id)
	if not _valid_time(at_utc):
		return _error("invalid_time", case_id)
	if not event_ids is Array or (event_ids as Array).is_empty():
		return _error("no_events", case_id)
	if (event_ids as Array).size() > MAX_EVENTS:
		return _error("invalid_events", case_id)
	var seen_events: Dictionary = {}
	for event_id: Variant in event_ids:
		if not _valid_entry_id(event_id) or seen_events.has(str(event_id)):
			return _error("invalid_events", case_id)
		seen_events[str(event_id)] = true
	var cases: Dictionary = state.cases
	if cases.has(case_id):
		return _error("duplicate_case", case_id)
	if cases.size() >= MAX_CASES:
		return _error("capacity", case_id)
	var candidate: Dictionary = state.duplicate(true)
	candidate.cases[case_id] = {
		"filed_by": filed_by,
		"against": against,
		"event_ids": _string_array(event_ids),
		"evidence": [],
		"status": STATUS_FILED,
		"ruling": {},
		"appeals": [],
		"corrections": [],
		"manager_only": true,
		"filed_utc": float(at_utc),
		"audit": [],
	}
	return _success(case_id, STATUS_FILED, candidate)


## 受理。只有花名册中的管理员/仲裁可以操作，且只能从 `filed` 进入。
static func accept(state: Dictionary, case_id: String, actor: String, at_utc: float) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", case_id)
	if not _valid_entry_id(case_id):
		return _error("invalid_case", "")
	if not _valid_time(at_utc):
		return _error("invalid_time", case_id)
	if not _valid_player(actor):
		return _error("invalid_player", case_id)
	if not _is_authority(state, actor):
		return _error("not_authority", case_id)
	var entry: Variant = _case(state, case_id)
	if not entry is Dictionary:
		return _error("missing_case", case_id)
	if str(entry.status) != STATUS_FILED:
		return _error("invalid_status", case_id)
	if at_utc < float(entry.filed_utc):
		return _error("time_regression", case_id)
	var candidate: Dictionary = state.duplicate(true)
	var candidate_entry: Dictionary = candidate.cases[case_id]
	candidate_entry.status = STATUS_ACCEPTED
	candidate_entry.audit.append(_audit_row(ACTION_ACCEPT, actor, at_utc))
	return _success(case_id, STATUS_ACCEPTED, candidate)


## 驳回。恶意举报在立案后可以被管理员直接驳回，但不会被自动定罪；驳回同样
## 只写入独立审计条目。
static func reject(state: Dictionary, case_id: String, actor: String, at_utc: float) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", case_id)
	if not _valid_entry_id(case_id):
		return _error("invalid_case", "")
	if not _valid_time(at_utc):
		return _error("invalid_time", case_id)
	if not _valid_player(actor):
		return _error("invalid_player", case_id)
	if not _is_authority(state, actor):
		return _error("not_authority", case_id)
	var entry: Variant = _case(state, case_id)
	if not entry is Dictionary:
		return _error("missing_case", case_id)
	if str(entry.status) != STATUS_FILED:
		return _error("invalid_status", case_id)
	if at_utc < float(entry.filed_utc):
		return _error("time_regression", case_id)
	var candidate: Dictionary = state.duplicate(true)
	var candidate_entry: Dictionary = candidate.cases[case_id]
	candidate_entry.status = STATUS_REJECTED
	candidate_entry.audit.append(_audit_row(ACTION_REJECT, actor, at_utc))
	return _success(case_id, STATUS_REJECTED, candidate)


## 提交证据。只受理未终结案件；证据 id 在案件内唯一；立案前的时间拒绝，超过
## 固定证据窗口时具名拒绝。证据不会自行改变案件状态。
static func submit_evidence(state: Dictionary, case_id: String, evidence: Variant) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", case_id)
	if not _valid_entry_id(case_id):
		return _error("invalid_case", "")
	var entry: Variant = _case(state, case_id)
	if not entry is Dictionary:
		return _error("missing_case", case_id)
	if not EVIDENCE_STATUSES.has(str(entry.status)):
		return _error("case_closed", case_id)
	if not _valid_evidence(evidence):
		return _error("invalid_evidence", case_id)
	var evidence_id: String = str((evidence as Dictionary).id)
	for existing: Variant in entry.evidence:
		if existing is Dictionary and str(existing.get("id", "")) == evidence_id:
			return _error("duplicate_evidence", case_id)
	var at_utc: float = float((evidence as Dictionary).at_utc)
	var filed_utc: float = float(entry.filed_utc)
	if at_utc < filed_utc:
		return _error("time_regression", case_id)
	if at_utc > filed_utc + EVIDENCE_WINDOW_SECONDS:
		return _error("evidence_expired", case_id)
	if not entry.evidence.is_empty():
		var last: Dictionary = entry.evidence[entry.evidence.size() - 1]
		if at_utc < float(last.at_utc):
			return _error("time_regression", case_id)
	if entry.evidence.size() >= MAX_EVIDENCE:
		return _error("capacity", case_id)
	var candidate: Dictionary = state.duplicate(true)
	var candidate_entry: Dictionary = candidate.cases[case_id]
	candidate_entry.evidence.append({
		"id": evidence_id,
		"kind": str((evidence as Dictionary).kind),
		"source": str((evidence as Dictionary).source),
		"submitted_by": str((evidence as Dictionary).submitted_by),
		"at_utc": at_utc,
	})
	return _success(case_id, str(entry.status), candidate)


## 裁定。`decision` 必须显式区分建议与权威：
##   {"advisor": bool, "authority": bool, "outcome": String, "reason": String}
## 两个标志必须恰好一个为真。`advisor` 调用只返回 `advisory_only`，绝不会写入
## 状态或审计；`authority` 调用才要求操作者在花名册中，并追加一条独立审计。
static func rule(state: Dictionary, case_id: String, actor: String, decision: Variant,
		at_utc: float) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", case_id)
	if not _valid_decision(decision):
		return _error("invalid_decision", case_id)
	var advisor: bool = bool((decision as Dictionary).advisor)
	var authority: bool = bool((decision as Dictionary).authority)
	if advisor == authority:
		return _error("invalid_decision", case_id)
	# AI 建议在读取案件之前就结束：它不可能触达任何状态或审计。
	if advisor:
		return _error("advisory_only", case_id)
	if not _valid_entry_id(case_id):
		return _error("invalid_case", "")
	if not _valid_time(at_utc):
		return _error("invalid_time", case_id)
	if not _valid_player(actor):
		return _error("invalid_player", case_id)
	if not _is_authority(state, actor):
		return _error("not_authority", case_id)
	var entry: Variant = _case(state, case_id)
	if not entry is Dictionary:
		return _error("missing_case", case_id)
	if str(entry.status) != STATUS_ACCEPTED:
		return _error("invalid_status", case_id)
	var outcome: String = str((decision as Dictionary).outcome)
	if not OUTCOMES.has(outcome):
		return _error("invalid_outcome", case_id)
	var reason: String = str((decision as Dictionary).reason)
	if not _valid_reason(reason):
		return _error("invalid_reason", case_id)
	var accepted_utc: float = _accepted_utc(entry)
	if at_utc < accepted_utc:
		return _error("time_regression", case_id)
	var candidate: Dictionary = state.duplicate(true)
	var candidate_entry: Dictionary = candidate.cases[case_id]
	candidate_entry.ruling = {
		"by": actor,
		"at_utc": float(at_utc),
		"outcome": outcome,
		"reason": reason,
	}
	candidate_entry.status = STATUS_RULED
	candidate_entry.audit.append(_audit_row(ACTION_RULE, actor, at_utc))
	return _success(case_id, STATUS_RULED, candidate)


## 申诉。只有案件双方可以申诉，且只能对已裁定案件提出一次；申诉不删除原裁定。
static func appeal(state: Dictionary, case_id: String, actor: String, reason: String,
		at_utc: float) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", case_id)
	if not _valid_entry_id(case_id):
		return _error("invalid_case", "")
	if not _valid_time(at_utc):
		return _error("invalid_time", case_id)
	if not _valid_player(actor):
		return _error("invalid_player", case_id)
	var entry: Variant = _case(state, case_id)
	if not entry is Dictionary:
		return _error("missing_case", case_id)
	if str(entry.status) == STATUS_APPEALED:
		return _error("already_appealed", case_id)
	if str(entry.status) != STATUS_RULED:
		return _error("invalid_status", case_id)
	if actor != str(entry.filed_by) and actor != str(entry.against):
		return _error("not_party", case_id)
	if not _valid_reason(reason):
		return _error("invalid_reason", case_id)
	if at_utc < float(entry.ruling.at_utc):
		return _error("time_regression", case_id)
	var candidate: Dictionary = state.duplicate(true)
	var candidate_entry: Dictionary = candidate.cases[case_id]
	candidate_entry.appeals.append({
		"by": actor,
		"at_utc": float(at_utc),
		"reason": reason,
	})
	candidate_entry.status = STATUS_APPEALED
	return _success(case_id, STATUS_APPEALED, candidate)


## 更正。管理员只能追加更正记录，原裁定和申诉历史保持原样；每次更正追加一条
## 独立审计。允许在裁定后直接更正，也允许在申诉后更正。
static func correct(state: Dictionary, case_id: String, actor: String, reason: String,
		at_utc: float) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", case_id)
	if not _valid_entry_id(case_id):
		return _error("invalid_case", "")
	if not _valid_time(at_utc):
		return _error("invalid_time", case_id)
	if not _valid_player(actor):
		return _error("invalid_player", case_id)
	if not _is_authority(state, actor):
		return _error("not_authority", case_id)
	var entry: Variant = _case(state, case_id)
	if not entry is Dictionary:
		return _error("missing_case", case_id)
	if str(entry.status) == STATUS_CORRECTED:
		return _error("already_corrected", case_id)
	if str(entry.status) == STATUS_CLOSED:
		return _error("already_closed", case_id)
	if str(entry.status) != STATUS_RULED and str(entry.status) != STATUS_APPEALED:
		return _error("invalid_status", case_id)
	if not _valid_reason(reason):
		return _error("invalid_reason", case_id)
	if at_utc < float(entry.ruling.at_utc):
		return _error("time_regression", case_id)
	if not entry.appeals.is_empty() and at_utc < float(entry.appeals[0].at_utc):
		return _error("time_regression", case_id)
	var candidate: Dictionary = state.duplicate(true)
	var candidate_entry: Dictionary = candidate.cases[case_id]
	candidate_entry.corrections.append({
		"by": actor,
		"at_utc": float(at_utc),
		"reason": reason,
	})
	candidate_entry.status = STATUS_CORRECTED
	candidate_entry.audit.append(_audit_row(ACTION_CORRECT, actor, at_utc))
	return _success(case_id, STATUS_CORRECTED, candidate)


## 结案。只有已更正的案件可以结案；结案不删除任何历史，只再追加一条审计。
static func close(state: Dictionary, case_id: String, actor: String, at_utc: float) -> Dictionary:
	if not _state_ready(state):
		return _error("invalid_state", case_id)
	if not _valid_entry_id(case_id):
		return _error("invalid_case", "")
	if not _valid_time(at_utc):
		return _error("invalid_time", case_id)
	if not _valid_player(actor):
		return _error("invalid_player", case_id)
	if not _is_authority(state, actor):
		return _error("not_authority", case_id)
	var entry: Variant = _case(state, case_id)
	if not entry is Dictionary:
		return _error("missing_case", case_id)
	if str(entry.status) == STATUS_CLOSED:
		return _error("already_closed", case_id)
	if str(entry.status) != STATUS_CORRECTED:
		return _error("invalid_status", case_id)
	if at_utc < float(entry.corrections[0].at_utc):
		return _error("time_regression", case_id)
	var candidate: Dictionary = state.duplicate(true)
	var candidate_entry: Dictionary = candidate.cases[case_id]
	candidate_entry.status = STATUS_CLOSED
	candidate_entry.audit.append(_audit_row(ACTION_CLOSE, actor, at_utc))
	return _success(case_id, STATUS_CLOSED, candidate)


## 某条警告在 `at_utc` 的派生状态。警告不写入文档：起算点是裁定时刻
## `ruling.at_utc`，到期点是它加 `WARNING_WINDOW_SECONDS`，按半开区间
## `[起算, 到期)` 判定，因此恰好到达到期时刻即为 `expired`。结案、更正和申诉
## 都不改变这个判定：它们只追加历史，不撤销也没有能力改写原裁定结果。
##
## 成功返回
## `{ok: true, reason: "", case_id, status, starts_utc, expires_utc}`；
## 失败返回 `{ok: false, reason, case_id}`，且绝不返回派生的有效状态。
## 输入文档必须通过完整 `valid()`，非法文档一律 `invalid_state`，派生值不能
## 绕开文档校验。
static func warning_state(state: Dictionary, case_id: String, at_utc: Variant) -> Dictionary:
	if not valid(state):
		return _error("invalid_state", case_id)
	if not _valid_entry_id(case_id):
		return _error("invalid_case", "")
	if not _valid_time(at_utc):
		return _error("invalid_time", case_id)
	var entry: Variant = _case(state, case_id)
	if not entry is Dictionary:
		return _error("missing_case", case_id)
	var ruling: Dictionary = entry.ruling
	if ruling.is_empty() or str(ruling.outcome) != OUTCOME_WARNING:
		return _error("no_warning", case_id)
	var starts_utc: float = float(ruling.at_utc)
	var expires_utc: float = starts_utc + WARNING_WINDOW_SECONDS
	var now: float = float(at_utc)
	var status: String = WARNING_ACTIVE
	if now < starts_utc:
		status = WARNING_NOT_STARTED
	elif now >= expires_utc:
		status = WARNING_EXPIRED
	return {
		"ok": true,
		"reason": "",
		"case_id": case_id,
		"status": status,
		"starts_utc": starts_utc,
		"expires_utc": expires_utc,
	}


static func _valid_case(state: Dictionary, case_id: String, value: Variant) -> bool:
	if not value is Dictionary or (value as Dictionary).size() != CASE_KEYS.size():
		return false
	for key: String in CASE_KEYS:
		if not (value as Dictionary).has(key):
			return false
	if not _valid_player(value.filed_by) or not _valid_player(value.against):
		return false
	if str(value.filed_by) == str(value.against):
		return false
	if not _valid_time(value.filed_utc):
		return false
	if not _valid_event_ids(value.event_ids):
		return false
	if not _valid_evidence_rows(value.evidence, float(value.filed_utc)):
		return false
	if not value.status is String or not STATUSES.has(str(value.status)):
		return false
	if not value.manager_only is bool or not bool(value.manager_only):
		return false
	if not _valid_ruling(value.ruling):
		return false
	if not _valid_history_rows(value.appeals, APPEAL_KEYS):
		return false
	if not _valid_history_rows(value.corrections, CORRECTION_KEYS):
		return false
	if not _valid_audit_rows(value.audit):
		return false
	return _valid_history(state, case_id, value)


## 校验每个状态允许出现的裁定、申诉、更正和审计组合。这样伪造文档不能只改
## `status` 就冒充已裁定，也不能删除受理/裁定审计来隐藏管理员操作。
static func _valid_history(state: Dictionary, case_id: String, entry: Dictionary) -> bool:
	var status: String = str(entry.status)
	var ruling: Dictionary = entry.ruling
	var appeals: Array = entry.appeals
	var corrections: Array = entry.corrections
	var audit: Array = entry.audit
	var filed_utc: float = float(entry.filed_utc)
	var has_ruling: bool = not ruling.is_empty()
	if status == STATUS_FILED:
		if has_ruling or not appeals.is_empty() or not corrections.is_empty():
			return false
		return audit.is_empty()
	if status == STATUS_ACCEPTED:
		if has_ruling or not appeals.is_empty() or not corrections.is_empty():
			return false
		return _audit_matches(audit, ACTION_ACCEPT, 1, state, filed_utc)
	if status == STATUS_REJECTED:
		if has_ruling or not appeals.is_empty() or not corrections.is_empty():
			return false
		return _audit_matches(audit, ACTION_REJECT, 1, state, filed_utc)
	if not has_ruling or audit.size() < 2:
		return false
	if str(audit[0].action) != ACTION_ACCEPT or str(audit[1].action) != ACTION_RULE:
		return false
	if not _is_authority(state, str(audit[0].by)) \
			or not _is_authority(state, str(audit[1].by)):
		return false
	if float(audit[0].at_utc) < filed_utc:
		return false
	if str(audit[1].by) != str(ruling.by) \
			or float(audit[1].at_utc) != float(ruling.at_utc):
		return false
	if float(ruling.at_utc) < float(audit[0].at_utc):
		return false
	if not _valid_appeal_timeline(entry):
		return false
	match status:
		STATUS_RULED:
			if not appeals.is_empty() or not corrections.is_empty() or audit.size() != 2:
				return false
			return true
		STATUS_APPEALED:
			if appeals.size() != 1 or not corrections.is_empty() or audit.size() != 2:
				return false
			return true
		STATUS_CORRECTED:
			if corrections.size() != 1 or appeals.size() > 1 or audit.size() != 3:
				return false
			if str(audit[2].action) != ACTION_CORRECT:
				return false
			if not _is_authority(state, str(audit[2].by)):
				return false
			if str(audit[2].by) != str(corrections[0].by) \
					or float(audit[2].at_utc) != float(corrections[0].at_utc):
				return false
			if float(corrections[0].at_utc) < float(ruling.at_utc):
				return false
			if not appeals.is_empty() \
					and float(corrections[0].at_utc) < float(appeals[0].at_utc):
				return false
			return true
		STATUS_CLOSED:
			if corrections.size() != 1 or appeals.size() > 1 or audit.size() != 4:
				return false
			if str(audit[2].action) != ACTION_CORRECT \
					or str(audit[3].action) != ACTION_CLOSE:
				return false
			if not _is_authority(state, str(audit[2].by)) \
					or not _is_authority(state, str(audit[3].by)):
				return false
			if str(audit[2].by) != str(corrections[0].by) \
					or float(audit[2].at_utc) != float(corrections[0].at_utc):
				return false
			if float(corrections[0].at_utc) < float(ruling.at_utc):
				return false
			if not appeals.is_empty() \
					and float(corrections[0].at_utc) < float(appeals[0].at_utc):
				return false
			if float(audit[3].at_utc) < float(corrections[0].at_utc):
				return false
			return true
	return false


static func _valid_appeal_timeline(entry: Dictionary) -> bool:
	if entry.appeals.is_empty():
		return true
	var appeal: Dictionary = entry.appeals[0]
	if appeal.by != entry.filed_by and appeal.by != entry.against:
		return false
	return float(appeal.at_utc) >= float(entry.ruling.at_utc)


static func _audit_matches(audit: Array, action: String, size: int, state: Dictionary,
		filed_utc: float) -> bool:
	if audit.size() != size:
		return false
	if str(audit[0].action) != action:
		return false
	if not _is_authority(state, str(audit[0].by)):
		return false
	return float(audit[0].at_utc) >= filed_utc


static func _valid_authority_roles(value: Variant) -> bool:
	if not value is Dictionary or (value as Dictionary).size() != ROLE_KEYS.size():
		return false
	for key: String in ROLE_KEYS:
		if not (value as Dictionary).has(key):
			return false
	var seen: Dictionary = {}
	for key: String in ROLE_KEYS:
		var ids: Variant = (value as Dictionary)[key]
		if not ids is Array or (ids as Array).size() > MAX_AUTHORITY:
			return false
		for player_id: Variant in ids:
			if not _valid_player(player_id) or seen.has(str(player_id)):
				return false
			seen[str(player_id)] = true
	return true


static func _valid_event_ids(value: Variant) -> bool:
	if not value is Array or (value as Array).is_empty() \
			or (value as Array).size() > MAX_EVENTS:
		return false
	var seen: Dictionary = {}
	for event_id: Variant in value:
		if not _valid_entry_id(event_id) or seen.has(str(event_id)):
			return false
		seen[str(event_id)] = true
	return true


static func _valid_evidence_rows(value: Variant, filed_utc: float) -> bool:
	if not value is Array or (value as Array).size() > MAX_EVIDENCE:
		return false
	var seen: Dictionary = {}
	var previous: float = filed_utc
	for row: Variant in value:
		if not _valid_evidence(row):
			return false
		if seen.has(str((row as Dictionary).id)):
			return false
		seen[str((row as Dictionary).id)] = true
		var at_utc: float = float((row as Dictionary).at_utc)
		if at_utc < filed_utc or at_utc > filed_utc + EVIDENCE_WINDOW_SECONDS:
			return false
		if at_utc < previous:
			return false
		previous = at_utc
	return true


static func _valid_evidence(value: Variant) -> bool:
	if not value is Dictionary or (value as Dictionary).size() != EVIDENCE_KEYS.size():
		return false
	for key: String in EVIDENCE_KEYS:
		if not (value as Dictionary).has(key):
			return false
	if not _valid_entry_id((value as Dictionary).id):
		return false
	if not (value as Dictionary).kind is String \
			or not EVIDENCE_KINDS.has(str((value as Dictionary).kind)):
		return false
	if not _valid_source((value as Dictionary).source):
		return false
	if not _valid_player((value as Dictionary).submitted_by):
		return false
	return _valid_time((value as Dictionary).at_utc)


static func _valid_ruling(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	if (value as Dictionary).is_empty():
		return true
	if (value as Dictionary).size() != RULING_KEYS.size():
		return false
	for key: String in RULING_KEYS:
		if not (value as Dictionary).has(key):
			return false
	if not _valid_player((value as Dictionary).by):
		return false
	if not _valid_time((value as Dictionary).at_utc):
		return false
	if not (value as Dictionary).outcome is String \
			or not OUTCOMES.has(str((value as Dictionary).outcome)):
		return false
	return _valid_reason(str((value as Dictionary).reason))


static func _valid_history_rows(value: Variant, keys: Array[String]) -> bool:
	if not value is Array or (value as Array).size() > 1:
		return false
	for row: Variant in value:
		if not row is Dictionary or (row as Dictionary).size() != keys.size():
			return false
		for key: String in keys:
			if not (row as Dictionary).has(key):
				return false
		if not _valid_player((row as Dictionary).by):
			return false
		if not _valid_time((row as Dictionary).at_utc):
			return false
		if not _valid_reason(str((row as Dictionary).reason)):
			return false
	return true


static func _valid_audit_rows(value: Variant) -> bool:
	if not value is Array or (value as Array).size() > 4:
		return false
	var previous: float = 0.0
	for index: int in (value as Array).size():
		var row: Variant = (value as Array)[index]
		if not row is Dictionary or (row as Dictionary).size() != AUDIT_KEYS.size():
			return false
		for key: String in AUDIT_KEYS:
			if not (row as Dictionary).has(key):
				return false
		if not (row as Dictionary).action is String \
				or not AUDIT_ACTIONS.has(str((row as Dictionary).action)):
			return false
		if not _valid_player((row as Dictionary).by):
			return false
		if not _valid_time((row as Dictionary).at_utc):
			return false
		var at_utc: float = float((row as Dictionary).at_utc)
		if index > 0 and at_utc < previous:
			return false
		previous = at_utc
	return true


static func _valid_decision(value: Variant) -> bool:
	if not value is Dictionary or (value as Dictionary).size() != DECISION_KEYS.size():
		return false
	for key: String in DECISION_KEYS:
		if not (value as Dictionary).has(key):
			return false
	if not (value as Dictionary).advisor is bool \
			or not (value as Dictionary).authority is bool:
		return false
	if not (value as Dictionary).outcome is String \
			or not (value as Dictionary).reason is String:
		return false
	return true


static func _state_ready(state: Dictionary) -> bool:
	var roles: Variant = state.get("authority_roles")
	var cases: Variant = state.get("cases")
	return roles is Dictionary and _valid_authority_roles(roles) \
		and cases is Dictionary and (cases as Dictionary).size() <= MAX_CASES


static func _case(state: Dictionary, case_id: String) -> Variant:
	var cases: Variant = state.get("cases")
	if not cases is Dictionary:
		return null
	return (cases as Dictionary).get(case_id)


static func _is_authority(state: Dictionary, actor: String) -> bool:
	var roles: Variant = state.get("authority_roles")
	if not roles is Dictionary:
		return false
	for key: String in ROLE_KEYS:
		var ids: Variant = (roles as Dictionary).get(key)
		if ids is Array and (ids as Array).has(actor):
			return true
	return false


static func _accepted_utc(entry: Dictionary) -> float:
	if entry.audit is Array and not entry.audit.is_empty():
		return float(entry.audit[0].get("at_utc", entry.filed_utc))
	return float(entry.filed_utc)


static func _audit_row(action: String, actor: String, at_utc: float) -> Dictionary:
	return {"action": action, "by": actor, "at_utc": float(at_utc)}


static func _success(case_id: String, status: String, candidate: Dictionary) -> Dictionary:
	return {
		"ok": true,
		"reason": "",
		"case_id": case_id,
		"status": status,
		"state": candidate,
	}


static func _error(reason: String, case_id: String) -> Dictionary:
	return {"ok": false, "reason": reason, "case_id": case_id}


static func _string_array(value: Variant) -> Array:
	var output: Array = []
	if value is Array:
		for entry: Variant in value:
			output.append(str(entry))
	return output


static func _valid_player(value: Variant) -> bool:
	return value is String and str(value) != "public" and OwnerIds.valid(value)


static func _valid_entry_id(value: Variant) -> bool:
	return OwnerIds.valid(value)


static func _valid_source(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_SOURCE_LENGTH:
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		var letter: bool = (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var digit: bool = code >= 48 and code <= 57
		if not letter and not digit and code != 95 and code != 45 and code != 46 and code != 58:
			return false
	return true


static func _valid_reason(value: String) -> bool:
	return not value.strip_edges().is_empty() and value.length() <= MAX_REASON_LENGTH


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) >= 0.0 and float(value) <= float(MAX_SAFE_INTEGER)
