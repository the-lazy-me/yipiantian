extends RefCounted
## M11-03 规则决议最小切片：提案、表决、预告、生效、版本与撤销。
## 纯规则：不读 RNG、系统时钟、磁盘、场景或网络；所有命令显式传入
## `now_utc`，返回候选文档而不是修改输入。同一命令序列得到同一输出。
##
## 文档形状：
##   {
##     "rules_version": 0,
##     "resolutions": {
##       "<resolution_id>": {
##         "kind": "public_works" | "tax",
##         "title": "修桥",
##         "proposed_by": "<player_id>",
##         "proposed_utc": 1800000000.0,
##         "vote_start_utc": 1800000060.0,
##         "vote_end_utc": 1800003660.0,
##         "effective_utc": 1800007260.0,
##         "status": "proposed" | "passed" | "rejected" | "withdrawn"
##                 | "effective" | "revoked",
##         "approvals": ["<player_id>"],
##         "rejections": ["<player_id>"],
##         "revision": 1,
##         "effective_version": 0,
##         "revoked_by": "",
##         "revoked_utc": 0.0,
##         "revoked_version": 0,
##       }
##     }
##   }
##
## 生命周期与 revision：
##   proposed(1) -> close 通过/否决(2) -> activate 生效(3) -> revoke 撤销(4)
##   proposed(1) -> withdraw 撤案(2)
## 只有 activate 和 revoke 推进顶层 `rules_version`；每次推进分配一个新版本号。
## 生效决议在 `effective_version` 记住分配到的版本，撤销时再在 `revoked_version`
## 记住撤销版本。新决议或撤销不重写旧决议的提案、表决、时间和已生效版本，
## `is_effective_at()` 用 `[effective_utc, revoked_utc)` 还原历史生效区间，所以
## 撤销不会追溯改变撤销前已经发生的事件，既有合同按事件发生时的版本继续成立。
##
## 表决规则：
## - 投票窗口是半开区间 `[vote_start_utc, vote_end_utc)`，窗口外投票被拒绝。
## - 提案人不能给自己的提案投票；同一玩家只能投一次，赞成和反对互斥。
## - 通过阈值：至少 `MIN_APPROVALS` 张赞成票，且赞成票多于反对票。
## - `close()` 只能在窗口结束后调用，只把提案定为 passed/rejected，不直接生效。
##   `activate()` 必须等到 `effective_utc`；因此过了投票窗口本身不会产生生效规则。
## - 撤案只允许提案人在投票窗口结束前进行；撤销只允许已生效决议，且撤销人必须
##   是曾投赞成票的成员。成员资格与职位由上层权威另行校验，本切片不读组织文档。
## - 文档有界：决议数、单边投票人数、标题长度都受常量限制，严格校验拒绝未知键。

const OwnerIds = preload("res://farm/owner_id.gd")

const KIND_PUBLIC_WORKS: String = "public_works"
const KIND_TAX: String = "tax"
const KINDS: Array[String] = [KIND_PUBLIC_WORKS, KIND_TAX]

const STATUS_PROPOSED: String = "proposed"
const STATUS_PASSED: String = "passed"
const STATUS_REJECTED: String = "rejected"
const STATUS_WITHDRAWN: String = "withdrawn"
const STATUS_EFFECTIVE: String = "effective"
const STATUS_REVOKED: String = "revoked"
const STATUSES: Array[String] = [
	STATUS_PROPOSED, STATUS_PASSED, STATUS_REJECTED, STATUS_WITHDRAWN,
	STATUS_EFFECTIVE, STATUS_REVOKED,
]

## 至少两张赞成票且赞成票严格多于反对票。
const MIN_APPROVALS: int = 2
## 投票结束到最早生效时刻之间的预告期。
const NOTICE_SECONDS: float = 3600.0

const MAX_RESOLUTIONS: int = 128
## 赞成和反对各自的人数上限；两边不重叠，所以一份提案最多两面各 128 人。
const MAX_VOTERS: int = 128
const MAX_TITLE_LENGTH: int = 128
const MAX_SAFE_INTEGER: int = 9007199254740991

const STATE_KEYS: Array[String] = ["rules_version", "resolutions"]
const RESOLUTION_KEYS: Array[String] = [
	"kind", "title", "proposed_by", "proposed_utc", "vote_start_utc",
	"vote_end_utc", "effective_utc", "status", "approvals", "rejections",
	"revision", "effective_version", "revoked_by", "revoked_utc",
	"revoked_version",
]
const PROPOSAL_KEYS: Array[String] = [
	"kind", "title", "vote_start_utc", "vote_end_utc", "effective_utc",
]


## 没有决议时的初始文档。
static func empty() -> Dictionary:
	return {"rules_version": 0, "resolutions": {}}


## 提出一条决议。`proposal` 必须恰好包含 kind、title 和三个时刻。投票窗口在
## `now_utc` 或之后开始，结束必须晚于开始；生效时刻至少比投票结束晚一个预告期。
## id 在文档内唯一，数量有上限。
static func propose(state: Dictionary, resolution_id: Variant, proposer: Variant,
		proposal: Variant, now_utc: float) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	if not _valid_resolution_id(resolution_id):
		return _error("invalid_resolution")
	if not _valid_player(proposer):
		return _error("invalid_player")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	if not proposal is Dictionary:
		return _error("invalid_proposal")
	var raw: Dictionary = proposal
	if raw.size() != PROPOSAL_KEYS.size():
		return _error("invalid_proposal")
	for key: String in PROPOSAL_KEYS:
		if not raw.has(key):
			return _error("invalid_proposal")
	if not _valid_kind(raw.get("kind")):
		return _error("invalid_kind")
	if not _valid_title(raw.get("title")):
		return _error("invalid_title")
	if not _valid_time(raw.get("vote_start_utc")) \
			or not _valid_time(raw.get("vote_end_utc")) \
			or not _valid_time(raw.get("effective_utc")):
		return _error("invalid_time")
	var vote_start: float = float(raw.get("vote_start_utc"))
	var vote_end: float = float(raw.get("vote_end_utc"))
	var effective_utc: float = float(raw.get("effective_utc"))
	if vote_start < now_utc or vote_end <= vote_start:
		return _error("invalid_window")
	# 用减法而不是加法比较，避免接近上限的时刻相加溢出。
	if effective_utc - vote_end < NOTICE_SECONDS:
		return _error("notice_too_short")
	var resolutions: Dictionary = state.resolutions
	var id: String = str(resolution_id)
	if resolutions.has(id):
		return _error("already_exists")
	if resolutions.size() >= MAX_RESOLUTIONS:
		return _error("too_many")
	var candidate: Dictionary = state.duplicate(true)
	var candidate_resolutions: Dictionary = candidate["resolutions"]
	candidate_resolutions[id] = {
		"kind": str(raw.get("kind")),
		"title": str(raw.get("title")),
		"proposed_by": str(proposer),
		"proposed_utc": now_utc,
		"vote_start_utc": vote_start,
		"vote_end_utc": vote_end,
		"effective_utc": effective_utc,
		"status": STATUS_PROPOSED,
		"approvals": [],
		"rejections": [],
		"revision": 1,
		"effective_version": 0,
		"revoked_by": "",
		"revoked_utc": 0.0,
		"revoked_version": 0,
	}
	return _success(candidate)


## 在投票窗口内投一票。窗口是 `[vote_start_utc, vote_end_utc)`：开始时刻可以
## 投，结束时刻已经关闭。提案人不能投自己的提案；同一玩家不能重复投，也不能
## 既赞成又反对。
static func vote(state: Dictionary, resolution_id: Variant, voter: Variant,
		approve: bool, now_utc: float) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	if not _valid_resolution_id(resolution_id):
		return _error("invalid_resolution")
	var resolution: Variant = _resolution_or_null(state, str(resolution_id))
	if not resolution is Dictionary:
		return _error("unknown_resolution")
	if not _valid_player(voter):
		return _error("invalid_player")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	var row: Dictionary = resolution
	if str(row.status) != STATUS_PROPOSED:
		return _error("not_proposed")
	if now_utc < float(row.vote_start_utc):
		return _error("not_started")
	if now_utc >= float(row.vote_end_utc):
		return _error("closed")
	if str(voter) == str(row.proposed_by):
		return _error("self_vote")
	var approvals: Array = row.approvals
	var rejections: Array = row.rejections
	if approvals.has(str(voter)) or rejections.has(str(voter)):
		return _error("already_voted")
	var target: Array = approvals if approve else rejections
	if target.size() >= MAX_VOTERS:
		return _error("too_many_votes")
	var candidate: Dictionary = state.duplicate(true)
	var candidate_row: Dictionary = candidate["resolutions"][str(resolution_id)]
	if approve:
		candidate_row["approvals"].append(str(voter))
	else:
		candidate_row["rejections"].append(str(voter))
	return _success(candidate)


## 只读计票：返回当前赞成/反对人数和是否达到通过阈值。它不改变状态，也不受
## 调用时刻影响；关闭窗口由 `close()` 负责。
static func tally(state: Dictionary, resolution_id: Variant) -> Dictionary:
	if not valid(state):
		return _tally_result(false, "invalid_state", 0, 0, false)
	if not _valid_resolution_id(resolution_id):
		return _tally_result(false, "invalid_resolution", 0, 0, false)
	var resolution: Variant = _resolution_or_null(state, str(resolution_id))
	if not resolution is Dictionary:
		return _tally_result(false, "unknown_resolution", 0, 0, false)
	var row: Dictionary = resolution
	var approvals: int = row.approvals.size()
	var rejections: int = row.rejections.size()
	return _tally_result(true, "", approvals, rejections,
		_meets_threshold(approvals, rejections))


## 在投票窗口结束后关闭提案。达到阈值则 passed，否则 rejected；两者都不等于
## 生效。已关闭的提案不能再次关闭。
static func close(state: Dictionary, resolution_id: Variant, now_utc: float) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	if not _valid_resolution_id(resolution_id):
		return _error("invalid_resolution")
	var resolution: Variant = _resolution_or_null(state, str(resolution_id))
	if not resolution is Dictionary:
		return _error("unknown_resolution")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	var row: Dictionary = resolution
	if str(row.status) != STATUS_PROPOSED:
		return _error("not_proposed")
	if now_utc < float(row.vote_end_utc):
		return _error("window_open")
	var candidate: Dictionary = state.duplicate(true)
	var candidate_row: Dictionary = candidate["resolutions"][str(resolution_id)]
	var passed: bool = _meets_threshold(candidate_row["approvals"].size(),
		candidate_row["rejections"].size())
	candidate_row["status"] = STATUS_PASSED if passed else STATUS_REJECTED
	candidate_row["revision"] = 2
	return _success(candidate)


## 让已通过的提案在 `effective_utc` 或之后生效。每次生效分配一个新的规则版本。
## 提前调用或在否决/撤案/已生效的提案上调用都会被拒绝。
static func activate(state: Dictionary, resolution_id: Variant, now_utc: float) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	if not _valid_resolution_id(resolution_id):
		return _error("invalid_resolution")
	var resolution: Variant = _resolution_or_null(state, str(resolution_id))
	if not resolution is Dictionary:
		return _error("unknown_resolution")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	var row: Dictionary = resolution
	if str(row.status) != STATUS_PASSED:
		return _error("not_passed")
	if now_utc < float(row.effective_utc):
		return _error("too_early")
	var version: int = int(state.rules_version) + 1
	var candidate: Dictionary = state.duplicate(true)
	var candidate_row: Dictionary = candidate["resolutions"][str(resolution_id)]
	candidate_row["status"] = STATUS_EFFECTIVE
	candidate_row["revision"] = 3
	candidate_row["effective_version"] = version
	candidate["rules_version"] = version
	return _success(candidate)


## 提案人在投票窗口结束前撤案。窗口关闭后必须走 `close()`，避免看到票数后
## 临时撤案。已通过的提案不能撤案。
static func withdraw(state: Dictionary, resolution_id: Variant, actor: Variant,
		now_utc: float) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	if not _valid_resolution_id(resolution_id):
		return _error("invalid_resolution")
	var resolution: Variant = _resolution_or_null(state, str(resolution_id))
	if not resolution is Dictionary:
		return _error("unknown_resolution")
	if not _valid_player(actor):
		return _error("invalid_player")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	var row: Dictionary = resolution
	if str(row.status) != STATUS_PROPOSED:
		return _error("not_proposed")
	if str(actor) != str(row.proposed_by):
		return _error("not_proposer")
	if now_utc >= float(row.vote_end_utc):
		return _error("window_closed")
	var candidate: Dictionary = state.duplicate(true)
	var candidate_row: Dictionary = candidate["resolutions"][str(resolution_id)]
	candidate_row["status"] = STATUS_WITHDRAWN
	candidate_row["revision"] = 2
	return _success(candidate)


## 撤销一条已生效决议。只有曾投赞成票的玩家可以撤销；每次撤销分配一个新的
## 规则版本并记录撤销人、时刻与版本，提案、表决、生效时刻和 `effective_version`
## 保持原样，不追溯改写撤销前的事件。
static func revoke(state: Dictionary, resolution_id: Variant, actor: Variant,
		now_utc: float) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	if not _valid_resolution_id(resolution_id):
		return _error("invalid_resolution")
	var resolution: Variant = _resolution_or_null(state, str(resolution_id))
	if not resolution is Dictionary:
		return _error("unknown_resolution")
	if not _valid_player(actor):
		return _error("invalid_player")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	var row: Dictionary = resolution
	if str(row.status) != STATUS_EFFECTIVE:
		return _error("not_effective")
	if not row.approvals.has(str(actor)):
		return _error("not_approver")
	if now_utc < float(row.effective_utc):
		return _error("too_early")
	var version: int = int(state.rules_version) + 1
	var candidate: Dictionary = state.duplicate(true)
	var candidate_row: Dictionary = candidate["resolutions"][str(resolution_id)]
	candidate_row["status"] = STATUS_REVOKED
	candidate_row["revision"] = 4
	candidate_row["revoked_by"] = str(actor)
	candidate_row["revoked_utc"] = now_utc
	candidate_row["revoked_version"] = version
	candidate["rules_version"] = version
	return _success(candidate)


## 规则在 `at_utc` 是否生效：已生效决议从 `effective_utc` 起持续有效；已撤销
## 决议只在 `[effective_utc, revoked_utc)` 内有效。非法输入失败关闭。
static func is_effective_at(state: Dictionary, resolution_id: Variant, at_utc: float) -> bool:
	if not valid(state):
		return false
	if not _valid_resolution_id(resolution_id):
		return false
	if not _valid_time(at_utc):
		return false
	var resolution: Variant = _resolution_or_null(state, str(resolution_id))
	if not resolution is Dictionary:
		return false
	var row: Dictionary = resolution
	var effective_utc: float = float(row.effective_utc)
	if str(row.status) == STATUS_EFFECTIVE:
		return at_utc >= effective_utc
	if str(row.status) == STATUS_REVOKED:
		return at_utc >= effective_utc and at_utc < float(row.revoked_utc)
	return false


## 从 JSON 读回的文档会把整值数字读成浮点。校验通过后把计数与版本字段恢复为
## 整数，使内存文档与写入前的形状一致；时刻仍保持数值（可能带小数）。调用方
## 必须先通过 `valid()`，本函数不做校验。
static func normalize(state: Dictionary) -> void:
	var rules_version: Variant = state.get("rules_version")
	if rules_version is float and is_finite(float(rules_version)) \
			and float(rules_version) == floorf(float(rules_version)):
		state["rules_version"] = int(rules_version)
	var resolutions: Variant = state.get("resolutions")
	if not resolutions is Dictionary:
		return
	for resolution_id: Variant in resolutions:
		var row_value: Variant = (resolutions as Dictionary)[resolution_id]
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		for key: String in ["revision", "effective_version", "revoked_version"]:
			var number: Variant = row.get(key)
			if number is float and is_finite(float(number)) \
					and float(number) == floorf(float(number)):
				row[key] = int(number)


## 严格文档校验：顶层与决议行键集精确、枚举/id/标题/时间合法、投票窗口与
## 预告期有序、投票人不重复且不是提案人、生命周期与 revision 对应、版本号
## 唯一且覆盖 `1..rules_version`、所有表受上限约束。旧行只允许状态迁移改变
## 生命周期字段，任何历史字段被重写都会让文档失效。
static func valid(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var document: Dictionary = value
	if document.size() != STATE_KEYS.size():
		return false
	for key: String in STATE_KEYS:
		if not document.has(key):
			return false
	if not _valid_count(document.get("rules_version")):
		return false
	var resolutions_value: Variant = document.get("resolutions")
	if not resolutions_value is Dictionary:
		return false
	var resolutions: Dictionary = resolutions_value
	if resolutions.size() > MAX_RESOLUTIONS:
		return false
	var effective_count: int = 0
	var revoked_count: int = 0
	var versions: Dictionary = {}
	for resolution_id: Variant in resolutions:
		if not _valid_resolution_id(resolution_id):
			return false
		if not _valid_resolution(resolutions[resolution_id]):
			return false
		var row: Dictionary = resolutions[resolution_id]
		var status: String = str(row.get("status"))
		if status == STATUS_EFFECTIVE:
			effective_count += 1
			if not _claim_version(versions, row.get("effective_version")):
				return false
		elif status == STATUS_REVOKED:
			revoked_count += 1
			if not _claim_version(versions, row.get("effective_version")):
				return false
			if not _claim_version(versions, row.get("revoked_version")):
				return false
	var rules_version: int = int(document.get("rules_version"))
	# 每个生效消费一个版本，每个撤销消费生效和撤销两个版本；版本号连续无空洞。
	if rules_version != effective_count + 2 * revoked_count:
		return false
	for used: Variant in versions:
		if int(used) > rules_version:
			return false
	return true


static func _valid_resolution(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var row: Dictionary = value
	if row.size() != RESOLUTION_KEYS.size():
		return false
	for key: String in RESOLUTION_KEYS:
		if not row.has(key):
			return false
	if not _valid_kind(row.get("kind")):
		return false
	if not _valid_title(row.get("title")):
		return false
	if not _valid_player(row.get("proposed_by")):
		return false
	for key: String in ["proposed_utc", "vote_start_utc", "vote_end_utc", "effective_utc"]:
		if not _valid_time(row.get(key)):
			return false
	var proposed_utc: float = float(row.get("proposed_utc"))
	var vote_start: float = float(row.get("vote_start_utc"))
	var vote_end: float = float(row.get("vote_end_utc"))
	var effective_utc: float = float(row.get("effective_utc"))
	if vote_start < proposed_utc or vote_end <= vote_start:
		return false
	if effective_utc - vote_end < NOTICE_SECONDS:
		return false
	var status_value: Variant = row.get("status")
	if not status_value is String or not STATUSES.has(str(status_value)):
		return false
	var status: String = str(status_value)
	if not _valid_votes(row.get("approvals"), row.get("rejections"),
			str(row.get("proposed_by"))):
		return false
	if not _valid_count(row.get("revision")) \
			or not _valid_count(row.get("effective_version")) \
			or not _valid_count(row.get("revoked_version")) \
			or not _valid_time(row.get("revoked_utc")):
		return false
	var revision: int = int(row.get("revision"))
	var effective_version: int = int(row.get("effective_version"))
	var revoked_version: int = int(row.get("revoked_version"))
	var revoked_by: Variant = row.get("revoked_by")
	var revoked_utc: float = float(row.get("revoked_utc"))
	var approvals: Array = row.get("approvals")
	var rejections: Array = row.get("rejections")
	var passed: bool = _meets_threshold(approvals.size(), rejections.size())
	if status == STATUS_PROPOSED:
		if revision != 1 or effective_version != 0:
			return false
	elif status == STATUS_PASSED:
		if revision != 2 or effective_version != 0 or not passed:
			return false
	elif status == STATUS_REJECTED:
		if revision != 2 or effective_version != 0 or passed:
			return false
	elif status == STATUS_WITHDRAWN:
		if revision != 2 or effective_version != 0:
			return false
	elif status == STATUS_EFFECTIVE:
		if revision != 3 or effective_version < 1 or not passed:
			return false
	elif status == STATUS_REVOKED:
		if revision != 4 or effective_version < 1 or not passed:
			return false
		if not _valid_player(revoked_by):
			return false
		if not approvals.has(str(revoked_by)):
			return false
		if revoked_utc < effective_utc:
			return false
		if revoked_version <= effective_version:
			return false
	else:
		return false
	if status == STATUS_REVOKED:
		# 撤销字段只在 revoked 行出现。
		return true
	if not revoked_by is String or not str(revoked_by).is_empty():
		return false
	if revoked_utc != 0.0 or revoked_version != 0:
		return false
	if status == STATUS_EFFECTIVE:
		return true
	# 未生效行不能携带生效版本。
	return effective_version == 0


static func _valid_votes(approvals_value: Variant, rejections_value: Variant,
		proposer: String) -> bool:
	if not approvals_value is Array or not rejections_value is Array:
		return false
	var approvals: Array = approvals_value
	var rejections: Array = rejections_value
	if approvals.size() > MAX_VOTERS or rejections.size() > MAX_VOTERS:
		return false
	var seen: Dictionary = {}
	for list: Array in [approvals, rejections]:
		for voter: Variant in list:
			if not _valid_player(voter):
				return false
			var voter_id: String = str(voter)
			if voter_id == proposer or seen.has(voter_id):
				return false
			seen[voter_id] = true
	return true


static func _meets_threshold(approvals: int, rejections: int) -> bool:
	return approvals >= MIN_APPROVALS and approvals > rejections


## 版本号必须为正整数且在文档内唯一；由 valid() 再检查不超过 rules_version。
static func _claim_version(versions: Dictionary, value: Variant) -> bool:
	if not _valid_count(value):
		return false
	var version: int = int(value)
	if version < 1 or versions.has(version):
		return false
	versions[version] = true
	return true


static func _resolution_or_null(state: Dictionary, resolution_id: String) -> Variant:
	var resolutions: Variant = state.get("resolutions")
	if not resolutions is Dictionary:
		return null
	return (resolutions as Dictionary).get(resolution_id)


static func _success(candidate: Dictionary) -> Dictionary:
	return {"ok": true, "reason": "", "state": candidate}


static func _error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


static func _tally_result(ok: bool, reason: String, approvals: int, rejections: int,
		passed: bool) -> Dictionary:
	return {
		"ok": ok,
		"reason": reason,
		"approvals": approvals,
		"rejections": rejections,
		"passed": passed,
	}


static func _valid_resolution_id(value: Variant) -> bool:
	return value is String and OwnerIds.valid(value)


static func _valid_player(value: Variant) -> bool:
	return value is String and OwnerIds.valid(value)


static func _valid_kind(value: Variant) -> bool:
	return value is String and KINDS.has(str(value))


static func _valid_title(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_TITLE_LENGTH:
		return false
	if text != text.strip_edges():
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		if code < 32 or code == 127:
			return false
	return true


static func _valid_time(value: Variant) -> bool:
	if not value is int and not value is float:
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER)


## 版本与 revision 都是非负整数；JSON 往返可能读成整值浮点，因此容许整值浮点。
static func _valid_count(value: Variant) -> bool:
	if not value is int and not value is float:
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)
