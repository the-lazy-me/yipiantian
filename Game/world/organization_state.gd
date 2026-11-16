extends RefCounted
## M11-02 组织规则最小切片：成员、职位、权限、公共账户引用、负责人交接、解散
## 与资产清算意图。
## 纯规则：不读 RNG、系统时钟、磁盘、场景、网络，也不依赖农场、经济或地籍
## 文档。所有命令显式传入 `now_utc`，并且返回候选文档而不是修改输入。
##
## 文档形状：
##   {
##     "organizations": {
##       "<org_id>": {
##         "name": "河岸合作社",
##         "created_utc": 1800000000.0,
##         "members": {"<player_id>": "leader" | "officer" | "member"},
##         "roles": {
##           "leader":  {"can_spend": true,  "can_manage": true},
##           "officer": {"can_spend": true,  "can_manage": false},
##           "member":  {"can_spend": false, "can_manage": false},
##         },
##         "account_id": "org_<org_id>",
##         "status": "active" | "closed",
##         "closed_utc": 0.0,
##         "closed_by": "",
##         "history": [
##           {"kind": "created", "actor": "<player_id>", "target": "",
##            "at_utc": 1800000000.0},
##         ],
##       }
##     },
##     "command_results": {
##       "<command_id>": {
##         "payload": "dissolve:<sha256>",
##         "result": {
##           "ok": true,
##           "reason": "",
##           "organization_id": "<org_id>",
##           "clearing": {
##             "account_id": "org_<org_id>",
##             "balance": 100,
##             "refunds": [{"player_id": "<player_id>", "amount": 60}],
##           },
##         },
##       }
##     }
##   }
##
## 组织资产身份由 `org_id` 和派生的 `account_id` 决定，负责人只是成员表中的
## 职位；换届只改两个成员的职位，从不改组织 id、账户 id 或组织行本身。解散
## 不删除组织行、成员表或历史行：它把 `status` 置为 `closed`，记录解散人与
## 时刻，并在 `history` 追加一行 `dissolved`。关闭后的组织拒绝加入、退出、指派、
## 交接、支出与再次解散，但历史仍可读。
##
## 历史行：`created` 必须恰好是首行且时刻等于 `created_utc`；`joined`、`left`
## 的 `target` 必须为空；`appointed`、`handover` 的 `target` 是另一名合法玩家；
## `dissolved` 只允许出现在关闭组织的最后一行，其 actor/at_utc 必须与
## `closed_by`/`closed_utc` 一致。历史有界（256 行），满时拒绝继续追加。
##
## 命令重放：只有成功的解散写入顶层 `command_results`，payload 是规范请求的
## SHA-256 摘要。同一命令 id 同 payload 返回首次结果并标记 `duplicate`，换 payload
## 返回 `command_conflict`。每个关闭组织恰好对应一条成功命令记录，反向也成立。

const OwnerIds = preload("res://farm/owner_id.gd")

const ROLE_LEADER: String = "leader"
const ROLE_OFFICER: String = "officer"
const ROLE_MEMBER: String = "member"
const ROLE_NAMES: Array[String] = [ROLE_LEADER, ROLE_OFFICER, ROLE_MEMBER]

## 权限表是规则本身，不是可自由编辑的数据：负责人可管理与支出，干事可支出，
## 普通成员两者都不可。文档仍保存一份便于审阅和未来扩展，但 `valid()` 要求
## 它与这里的规范值逐项一致，改文档不能提权。
const ROLE_PERMISSIONS: Dictionary = {
	ROLE_LEADER: {"can_spend": true, "can_manage": true},
	ROLE_OFFICER: {"can_spend": true, "can_manage": false},
	ROLE_MEMBER: {"can_spend": false, "can_manage": false},
}

const STATUS_ACTIVE: String = "active"
const STATUS_CLOSED: String = "closed"
const STATUSES: Array[String] = [STATUS_ACTIVE, STATUS_CLOSED]

const HISTORY_CREATED: String = "created"
const HISTORY_JOINED: String = "joined"
const HISTORY_LEFT: String = "left"
const HISTORY_APPOINTED: String = "appointed"
const HISTORY_HANDOVER: String = "handover"
const HISTORY_DISSOLVED: String = "dissolved"
const HISTORY_KINDS: Array[String] = [
	HISTORY_CREATED, HISTORY_JOINED, HISTORY_LEFT, HISTORY_APPOINTED,
	HISTORY_HANDOVER, HISTORY_DISSOLVED,
]

const STATE_KEYS: Array[String] = ["organizations", "command_results"]
## 解散意图在退款之前写入组织文档。退款是一次原子农场保存，账户现金因此只有
## “未退（等于基金余额）”与“已退（为 0）”两种状态；意图与这两种状态一起就能
## 在账本分录被淘汰后完成解散，不需要保留无界历史。意图只对活动组织存在，成功
## 解散时与关闭状态在同一次保存里清除。
const PENDING_DISSOLVES_KEY: String = "pending_dissolves"
const PENDING_KEYS: Array[String] = [
	"command_id", "actor", "at_utc", "balance", "contributors",
]
const ORG_KEYS: Array[String] = [
	"name", "created_utc", "members", "roles", "account_id",
	"status", "closed_utc", "closed_by", "history",
]
const ROLE_ROW_KEYS: Array[String] = ["can_spend", "can_manage"]
const HISTORY_KEYS: Array[String] = ["kind", "actor", "target", "at_utc"]
const COMMAND_KEYS: Array[String] = ["payload", "result"]
const RESULT_KEYS: Array[String] = ["ok", "reason", "organization_id", "clearing"]
const CLEARING_KEYS: Array[String] = ["account_id", "balance", "refunds"]
const REFUND_KEYS: Array[String] = ["player_id", "amount"]
## 解散选项由调用方投影外部事实：账户余额、在途支出数量与成员累计缴入。
const OPTION_KEYS: Array[String] = [
	"command_id", "balance", "pending_spend", "contributors",
]

const MAX_ORGANIZATIONS: int = 64
const MAX_MEMBERS: int = 256
const MAX_NAME_LENGTH: int = 64
const MAX_SAFE_INTEGER: int = 9007199254740991
const ACCOUNT_PREFIX: String = "org_"

## 历史与重放窗口的上界。组织最多 64 个且每个只解散一次，因此一条成功的解散
## 命令对应一个组织，64 条记录足够覆盖全部组织。
const MAX_HISTORY: int = 256
const MAX_COMMANDS: int = 64
const MAX_COMMAND_ID_LENGTH: int = 128
## 命令 payload 是规范请求的 SHA-256 摘要，而不是逐字参数。解散请求含最多
## 256 名缴入者，逐字保存会让 64 条记录轻易超过存档文件 64 KiB 预算；摘要在
## 长度上有界，同参数得到同摘要，不同参数得到不同摘要即可完成重放判定。
const PAYLOAD_PREFIX: String = "dissolve:"
const PAYLOAD_DIGEST_LENGTH: int = 64

## 清算金额沿用公共基金的整数上界；计算结果保持在 64 位整数安全范围内，比例分配
## 不会因为浮点或溢出产生不确定结果。
const MAX_BALANCE: int = 1_000_000
const MAX_CONTRIBUTION: int = 1_000_000
const MAX_CONTRIBUTORS: int = 256


## 没有组织时的初始文档。
static func empty() -> Dictionary:
	return {"organizations": {}, "command_results": {}}


## 组织账户 id 由组织 id 推导。换届、退出和改名都不改变它。
static func account_for(org_id: String) -> String:
	return ACCOUNT_PREFIX + org_id


## 报告成员在组织中的当前职位；组织或成员不存在、或组织已关闭时返回空串。
## 关闭组织保留成员表作为历史事实，但不再是可操作身份：所有授权读取都必须
## 经过这里，因此“已关闭”不会因为历史职位而被误判成“仍可支出/管理”。
static func role_of(state: Dictionary, org_id: String, player_id: String) -> String:
	var org: Variant = _organization_or_null(state, org_id)
	if not org is Dictionary:
		return ""
	if str((org as Dictionary).get("status", "")) != STATUS_ACTIVE:
		return ""
	return _historic_role_of(org, player_id)


## 报告成员在组织中的历史职位，包括已关闭组织。只用于展示历史，不能拿来
## 判定权限；权限判定一律使用 `role_of()`。
static func historic_role_of(state: Dictionary, org_id: String,
		player_id: String) -> String:
	var org: Variant = _organization_or_null(state, org_id)
	if not org is Dictionary:
		return ""
	return _historic_role_of(org, player_id)


## 创建一个组织，创建者成为首任负责人。组织 id 不能重复，数量有上限。
static func create(state: Dictionary, org_id: Variant, name: Variant, creator: Variant,
		now_utc: float) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	if not _valid_org_id(org_id):
		return _error("invalid_org")
	if not _valid_name(name):
		return _error("invalid_name")
	if not _valid_player_id(creator):
		return _error("invalid_player")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	var id: String = str(org_id)
	var organizations: Dictionary = state.organizations
	if organizations.has(id):
		return _error("already_exists")
	if organizations.size() >= MAX_ORGANIZATIONS:
		return _error("too_many")
	var candidate: Dictionary = state.duplicate(true)
	var candidate_organizations: Dictionary = candidate["organizations"]
	candidate_organizations[id] = {
		"name": str(name),
		"created_utc": now_utc,
		"members": {str(creator): ROLE_LEADER},
		"roles": ROLE_PERMISSIONS.duplicate(true),
		"account_id": account_for(id),
		"status": STATUS_ACTIVE,
		"closed_utc": 0.0,
		"closed_by": "",
		"history": [_history_row(HISTORY_CREATED, str(creator), "", now_utc)],
	}
	return _success(candidate)


## 加入组织。新成员固定为普通成员，职位只能由可管理角色指派。关闭组织拒绝加入。
static func join(state: Dictionary, org_id: Variant, player_id: Variant,
		now_utc: float) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	var id: String = str(org_id)
	var org: Variant = _organization_or_null(state, id)
	if not org is Dictionary:
		return _error("unknown_org")
	if not _valid_player_id(player_id):
		return _error("invalid_player")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	if str((org as Dictionary)["status"]) != STATUS_ACTIVE:
		return _error("org_closed")
	var pid: String = str(player_id)
	var members: Dictionary = (org as Dictionary)["members"]
	if members.has(pid):
		return _error("already_member")
	if members.size() >= MAX_MEMBERS:
		return _error("org_full")
	if _history_full(org):
		return _error("history_full")
	if _history_regression(org, now_utc):
		return _error("time_regression")
	var candidate: Dictionary = state.duplicate(true)
	var candidate_members: Dictionary = candidate["organizations"][id]["members"]
	candidate_members[pid] = ROLE_MEMBER
	var candidate_history: Array = candidate["organizations"][id]["history"]
	candidate_history.append(_history_row(HISTORY_JOINED, pid, "", now_utc))
	return _success(candidate)


## 离开组织。负责人必须先交接；最后一名成员不能离开，因为那时应走 `dissolve()`，
## 由它记录关闭与清算意图。关闭组织拒绝退出。
static func leave(state: Dictionary, org_id: Variant, player_id: Variant,
		now_utc: float) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	var id: String = str(org_id)
	var org: Variant = _organization_or_null(state, id)
	if not org is Dictionary:
		return _error("unknown_org")
	if not _valid_player_id(player_id):
		return _error("invalid_player")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	if str((org as Dictionary)["status"]) != STATUS_ACTIVE:
		return _error("org_closed")
	var pid: String = str(player_id)
	var members: Dictionary = (org as Dictionary)["members"]
	if not members.has(pid):
		return _error("not_member")
	if members.size() == 1:
		return _error("last_member")
	if str(members[pid]) == ROLE_LEADER:
		return _error("leader_must_transfer")
	if _history_full(org):
		return _error("history_full")
	if _history_regression(org, now_utc):
		return _error("time_regression")
	var candidate: Dictionary = state.duplicate(true)
	var candidate_members: Dictionary = candidate["organizations"][id]["members"]
	candidate_members.erase(pid)
	var candidate_history: Array = candidate["organizations"][id]["history"]
	candidate_history.append(_history_row(HISTORY_LEFT, pid, "", now_utc))
	return _success(candidate)


## 指派已有成员的新职位。只有 `can_manage` 角色可以指派，目标必须是成员；
## 负责人职位不能经此处产生，必须走 `transfer_leadership()`。关闭组织拒绝指派。
static func appoint(state: Dictionary, org_id: Variant, actor: Variant, target: Variant,
		role: Variant, now_utc: float) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	var id: String = str(org_id)
	var org: Variant = _organization_or_null(state, id)
	if not org is Dictionary:
		return _error("unknown_org")
	if not _valid_player_id(actor) or not _valid_player_id(target):
		return _error("invalid_player")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	if not _valid_role(role):
		return _error("invalid_role")
	if str((org as Dictionary)["status"]) != STATUS_ACTIVE:
		return _error("org_closed")
	var actor_id: String = str(actor)
	var target_id: String = str(target)
	var members: Dictionary = (org as Dictionary)["members"]
	if not members.has(actor_id):
		return _error("not_member")
	if not _can(org, str(members[actor_id]), "can_manage"):
		return _error("role_forbidden")
	if not members.has(target_id):
		return _error("target_not_member")
	# 负责人只能经交接产生：既不能把 leader 当普通职位指派，也不能用降级
	# 绕过交接把唯一的负责人移除。
	if str(role) == ROLE_LEADER or str(members[target_id]) == ROLE_LEADER:
		return _error("leader_requires_transfer")
	if _history_full(org):
		return _error("history_full")
	if _history_regression(org, now_utc):
		return _error("time_regression")
	var candidate: Dictionary = state.duplicate(true)
	var candidate_members: Dictionary = candidate["organizations"][id]["members"]
	candidate_members[target_id] = str(role)
	var candidate_history: Array = candidate["organizations"][id]["history"]
	candidate_history.append(_history_row(HISTORY_APPOINTED, actor_id, target_id, now_utc))
	return _success(candidate)


## 负责人交接。原负责人降为普通成员，新负责人必须是当前成员。组织 id 和
## 账户 id 完全不变，因此资产身份不随换届改变。关闭组织拒绝交接。
static func transfer_leadership(state: Dictionary, org_id: Variant, actor: Variant,
		new_leader: Variant, now_utc: float) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	var id: String = str(org_id)
	var org: Variant = _organization_or_null(state, id)
	if not org is Dictionary:
		return _error("unknown_org")
	if not _valid_player_id(actor) or not _valid_player_id(new_leader):
		return _error("invalid_player")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	if str((org as Dictionary)["status"]) != STATUS_ACTIVE:
		return _error("org_closed")
	var actor_id: String = str(actor)
	var leader_id: String = str(new_leader)
	var members: Dictionary = (org as Dictionary)["members"]
	if not members.has(actor_id):
		return _error("not_member")
	if str(members[actor_id]) != ROLE_LEADER:
		return _error("not_leader")
	if not members.has(leader_id):
		return _error("target_not_member")
	if actor_id == leader_id:
		return _error("same_leader")
	if _history_full(org):
		return _error("history_full")
	if _history_regression(org, now_utc):
		return _error("time_regression")
	var candidate: Dictionary = state.duplicate(true)
	var candidate_members: Dictionary = candidate["organizations"][id]["members"]
	candidate_members[actor_id] = ROLE_MEMBER
	candidate_members[leader_id] = ROLE_LEADER
	var candidate_history: Array = candidate["organizations"][id]["history"]
	candidate_history.append(_history_row(HISTORY_HANDOVER, actor_id, leader_id, now_utc))
	return _success(candidate)


## 支出授权检查，不写文档。调用方必须来自组织成员，其当前职位需要
## `can_spend`；账户 id 必须等于组织声明的账户，不能改指向别的账户；金额
## 必须是正整数。关闭组织一律拒绝。拒绝原因彼此区分，便于证明“越权支出拒绝”。
static func authorize_spend(state: Dictionary, org_id: Variant, actor: Variant,
		account_id: Variant, amount: Variant, now_utc: float) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	var id: String = str(org_id)
	var org: Variant = _organization_or_null(state, id)
	if not org is Dictionary:
		return _error("unknown_org")
	if not _valid_player_id(actor):
		return _error("invalid_player")
	if str((org as Dictionary)["status"]) != STATUS_ACTIVE:
		return _error("org_closed")
	var actor_id: String = str(actor)
	var members: Dictionary = (org as Dictionary)["members"]
	if not members.has(actor_id):
		return _error("not_member")
	if not _can(org, str(members[actor_id]), "can_spend"):
		return _error("role_forbidden")
	if not account_id is String or str(account_id) != str((org as Dictionary)["account_id"]):
		return _error("wrong_account")
	if not _valid_amount(amount):
		return _error("invalid_amount")
	return {
		"ok": true,
		"reason": "",
		"org_id": id,
		"account_id": str((org as Dictionary)["account_id"]),
		"amount": int(amount),
	}


## 解散组织并返回资产清算意图，不移动任何钱。
##
## 只有当前负责人可以解散。`options` 是调用方对外部事实的只读投影，必须恰好含
## 四个键：
##   command_id    首次成功的重放键；同一 id 同 payload 返回首次结果。
##   balance       组织公共账户当前余额，0..MAX_BALANCE。
##   pending_spend 尚未结算的支出授权数量；大于 0 时拒绝解散，避免解散后仍有
##                 在途付款而账户已经关闭。
##   contributors  成员累计缴入 `{player_id: amount}`，用于按比例计算退款。
##
## 清算意图：按缴入比例分配整份余额，整数除法产生的余数按 player_id 升序逐个
## 分配，退款行按 player_id 升序排列，退款合计严格等于 `balance`。余额大于 0
## 但累计缴入为 0 时无法确定收款人，返回 `unowned_balance`；余额为 0 时退款表为空。
## 关闭保留全部成员与历史行，并在最后追加一条 `dissolved` 行。
static func dissolve(state: Dictionary, org_id: Variant, actor: Variant, now_utc: float,
		options: Variant) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	if not _valid_org_id(org_id):
		return _error("invalid_org")
	var id: String = str(org_id)
	var org: Variant = _organization_or_null(state, id)
	if not org is Dictionary:
		return _error("unknown_org")
	if not _valid_player_id(actor):
		return _error("invalid_player")
	if not _valid_time(now_utc):
		return _error("invalid_time")
	var parsed: Dictionary = _parse_options(options)
	if not bool(parsed.get("ok", false)):
		return _error(str(parsed.get("reason", "invalid_options")))
	var command_id: String = str(parsed["command_id"])
	var balance: int = int(parsed["balance"])
	var pending_spend: int = int(parsed["pending_spend"])
	var contributors: Dictionary = parsed["contributors"]
	var payload: String = _dissolve_payload(command_id, id, str(actor), now_utc,
		balance, pending_spend, contributors)
	var replayed: Dictionary = _replay_dissolve(state, command_id, payload)
	if not replayed.is_empty():
		return replayed
	var actor_id: String = str(actor)
	var row: Dictionary = org
	var members: Dictionary = row["members"]
	if not members.has(actor_id):
		return _error("not_member")
	if str(members[actor_id]) != ROLE_LEADER:
		return _error("not_leader")
	if str(row["status"]) != STATUS_ACTIVE:
		return _error("already_closed")
	if pending_spend > 0:
		return _error("pending_spend")
	if _history_regression(row, now_utc):
		return _error("time_regression")
	var computed: Dictionary = _clearing(row, balance, contributors)
	if not bool(computed.get("ok", false)):
		return _error(str(computed.get("reason", "unowned_balance")))
	if _history_full(row):
		return _error("history_full")
	var clearing: Dictionary = (computed["clearing"] as Dictionary).duplicate(true)
	var candidate: Dictionary = state.duplicate(true)
	var candidate_row: Dictionary = candidate["organizations"][id]
	candidate_row["status"] = STATUS_CLOSED
	candidate_row["closed_utc"] = float(now_utc)
	candidate_row["closed_by"] = actor_id
	var candidate_history: Array = candidate_row["history"]
	candidate_history.append(_history_row(HISTORY_DISSOLVED, actor_id, "", now_utc))
	var recorded: Dictionary = {
		"ok": true,
		"reason": "",
		"organization_id": id,
		"clearing": clearing.duplicate(true),
	}
	var candidate_commands: Dictionary = candidate["command_results"]
	candidate_commands[command_id] = {"payload": payload, "result": recorded}
	# 关闭组织不保留自己的解散意图；其它组织的意图不受影响。
	var candidate_pending_value: Variant = candidate.get(PENDING_DISSOLVES_KEY)
	if candidate_pending_value is Dictionary:
		var candidate_pending: Dictionary = candidate_pending_value
		candidate_pending.erase(id)
		if candidate_pending.is_empty():
			candidate.erase(PENDING_DISSOLVES_KEY)
	return {
		"ok": true,
		"reason": "",
		"duplicate": false,
		"state": candidate,
		"organization_id": id,
		"clearing": clearing,
	}


## 严格文档校验：顶层与组织行键集精确、名称/时间/id/账户合法、角色枚举与
## 权限表逐项匹配、每个组织恰好一名负责人、状态与关闭字段/历史行互相一致、
## 解散命令记录与关闭组织一一对应，所有表都受上限约束。
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
		if not STATE_KEYS.has(str(key)) and str(key) != PENDING_DISSOLVES_KEY:
			return false
	var organizations_value: Variant = document["organizations"]
	if not organizations_value is Dictionary:
		return false
	var organizations: Dictionary = organizations_value
	if organizations.size() > MAX_ORGANIZATIONS:
		return false
	for org_id: Variant in organizations:
		if not _valid_org_id(org_id):
			return false
		if not _valid_organization(str(org_id), organizations[org_id]):
			return false
	var commands_value: Variant = document["command_results"]
	if not commands_value is Dictionary:
		return false
	var commands: Dictionary = commands_value
	if commands.size() > MAX_COMMANDS:
		return false
	var covered: Dictionary = {}
	for command_id: Variant in commands:
		if not _valid_command(command_id, commands[command_id], organizations):
			return false
		var stored: Dictionary = (commands[command_id] as Dictionary)["result"]
		var referenced: String = str(stored["organization_id"])
		covered[referenced] = int(covered.get(referenced, 0)) + 1
	# 关闭组织必须恰好有一条成功解散记录，活动组织必须没有；单向检查会让
	# 读取方把“已关闭但没有清算意图”或“活动组织带着解散记录”当成合法。
	for org_id: Variant in organizations:
		var org: Dictionary = organizations[org_id]
		if str(org["status"]) == STATUS_CLOSED and int(covered.get(str(org_id), 0)) != 1:
			return false
	var pending_value: Variant = document.get(PENDING_DISSOLVES_KEY, {})
	if not pending_value is Dictionary:
		return false
	var pending: Dictionary = pending_value
	if pending.size() > MAX_ORGANIZATIONS:
		return false
	for org_id: Variant in pending:
		if not _valid_org_id(org_id):
			return false
		if not organizations.has(str(org_id)):
			return false
		var org: Dictionary = organizations[str(org_id)]
		if str(org["status"]) != STATUS_ACTIVE:
			return false
		if not _valid_pending_dissolve(org, pending[org_id], commands):
			return false
	return true


## 解散意图必须能被 `finish_pending_dissolve()` 原样完成：命令 id 未被占用、
## 时刻不早于组织历史、余额与缴入者能算出一份非空且合计相等的退款表。
static func _valid_pending_dissolve(org: Dictionary, value: Variant,
		commands: Dictionary) -> bool:
	if not value is Dictionary:
		return false
	var entry: Dictionary = value
	if entry.size() != PENDING_KEYS.size():
		return false
	for key: String in PENDING_KEYS:
		if not entry.has(key):
			return false
	if not _valid_command_id(entry.get("command_id")):
		return false
	if commands.has(str(entry["command_id"])):
		return false
	if not _valid_player_id(entry.get("actor")):
		return false
	if not _valid_time(entry.get("at_utc")):
		return false
	if _history_regression(org, float(entry["at_utc"])):
		return false
	var balance: int = _whole_in_range(entry.get("balance"), MAX_BALANCE)
	if balance <= 0:
		return false
	var parsed: Dictionary = _parse_contributors(entry.get("contributors"))
	if not bool(parsed.get("ok", false)):
		return false
	var split: Dictionary = refunds(balance, parsed["contributors"])
	if not bool(split.get("ok", false)):
		return false
	var refunds_value: Variant = split.get("refunds")
	return refunds_value is Array and not (refunds_value as Array).is_empty()


static func _valid_organization(org_id: String, value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var org: Dictionary = value
	if org.size() != ORG_KEYS.size():
		return false
	for key: String in ORG_KEYS:
		if not org.has(key):
			return false
	if not _valid_name(org.get("name")):
		return false
	if not _valid_time(org.get("created_utc")):
		return false
	if not org.get("account_id") is String or str(org.get("account_id")) != account_for(org_id):
		return false
	if not _valid_roles(org.get("roles")):
		return false
	if not _valid_status(org.get("status")):
		return false
	var history_value: Variant = org.get("history")
	if not history_value is Array:
		return false
	var history: Array = history_value
	if history.is_empty() or history.size() > MAX_HISTORY:
		return false
	var dissolved: int = 0
	var previous_time: float = -1.0
	for index: int in history.size():
		var entry: Variant = history[index]
		if not _valid_history_row(entry):
			return false
		var kind: String = str((entry as Dictionary)["kind"])
		# 创建行只能出现一次且必须是首行：历史从组织创建开始，读取方不需要
		# 在中间查找第二个起点。
		if kind == HISTORY_CREATED and index != 0:
			return false
		# 历史时间不得倒退，否则会出现“关闭之后又加入”这类读起来自相矛盾的
		# 记录；关闭时刻也因此不早于任何历史行。
		var at_utc: float = float((entry as Dictionary)["at_utc"])
		if at_utc < previous_time:
			return false
		previous_time = at_utc
		if kind == HISTORY_DISSOLVED:
			dissolved += 1
	var created_utc: float = float(org["created_utc"])
	var first: Dictionary = history[0]
	if str(first["kind"]) != HISTORY_CREATED or float(first["at_utc"]) != created_utc:
		return false
	var closed_utc_value: Variant = org.get("closed_utc")
	var closed_by_value: Variant = org.get("closed_by")
	if not closed_by_value is String:
		return false
	if str(org["status"]) == STATUS_ACTIVE:
		if dissolved != 0:
			return false
		if not str(closed_by_value).is_empty():
			return false
		if not _valid_time(closed_utc_value) or float(closed_utc_value) != 0.0:
			return false
	else:
		if dissolved != 1:
			return false
		if not _valid_player_id(closed_by_value):
			return false
		if not _valid_time(closed_utc_value):
			return false
		if float(closed_utc_value) < created_utc:
			return false
		var last: Dictionary = history[history.size() - 1]
		if str(last["kind"]) != HISTORY_DISSOLVED:
			return false
		if str(last["actor"]) != str(closed_by_value):
			return false
		if float(last["at_utc"]) != float(closed_utc_value):
			return false
	var members_value: Variant = org.get("members")
	if not members_value is Dictionary:
		return false
	var members: Dictionary = members_value
	if members.is_empty() or members.size() > MAX_MEMBERS:
		return false
	var leaders: int = 0
	for player_id: Variant in members:
		if not _valid_player_id(player_id):
			return false
		var role: Variant = members[player_id]
		if not _valid_role(role):
			return false
		if str(role) == ROLE_LEADER:
			leaders += 1
	# 每个组织恰好一名负责人：零名会让账户无人管理，多名则权限含混。
	# 关闭组织同样保留这名负责人，作为历史事实而不是可操作权限。
	return leaders == 1


static func _valid_history_row(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var row: Dictionary = value
	if row.size() != HISTORY_KEYS.size():
		return false
	for key: String in HISTORY_KEYS:
		if not row.has(key):
			return false
	var kind: Variant = row.get("kind")
	if not kind is String or str(kind) not in HISTORY_KINDS:
		return false
	if not _valid_player_id(row.get("actor")):
		return false
	if not row.get("target") is String:
		return false
	var target: String = str(row["target"])
	if str(kind) in [HISTORY_APPOINTED, HISTORY_HANDOVER]:
		if not _valid_player_id(target) or target == str(row["actor"]):
			return false
	elif not target.is_empty():
		return false
	return _valid_time(row.get("at_utc"))


static func _valid_command(command_id: Variant, value: Variant,
		organizations: Dictionary) -> bool:
	if not _valid_command_id(command_id):
		return false
	if not value is Dictionary:
		return false
	var entry: Dictionary = value
	if entry.size() != COMMAND_KEYS.size():
		return false
	for key: String in COMMAND_KEYS:
		if not entry.has(key):
			return false
	if not _valid_payload(entry.get("payload")):
		return false
	var result_value: Variant = entry.get("result")
	if not result_value is Dictionary:
		return false
	var result: Dictionary = result_value
	if result.size() != RESULT_KEYS.size():
		return false
	for key: String in RESULT_KEYS:
		if not result.has(key):
			return false
	if not result.get("ok") is bool or not bool(result["ok"]):
		return false
	if not result.get("reason") is String or not str(result["reason"]).is_empty():
		return false
	if not _valid_org_id(result.get("organization_id")):
		return false
	var org_id: String = str(result["organization_id"])
	if not organizations.has(org_id):
		return false
	var org: Dictionary = organizations[org_id]
	if str(org["status"]) != STATUS_CLOSED:
		return false
	return _valid_clearing(result.get("clearing"), org)


static func _valid_clearing(value: Variant, org: Dictionary) -> bool:
	if not value is Dictionary:
		return false
	var clearing: Dictionary = value
	if clearing.size() != CLEARING_KEYS.size():
		return false
	for key: String in CLEARING_KEYS:
		if not clearing.has(key):
			return false
	if not clearing.get("account_id") is String:
		return false
	if str(clearing["account_id"]) != str(org["account_id"]):
		return false
	var balance: int = _whole_in_range(clearing.get("balance"), MAX_BALANCE)
	if balance < 0:
		return false
	var refunds_value: Variant = clearing.get("refunds")
	if not refunds_value is Array:
		return false
	var refunds: Array = refunds_value
	if refunds.size() > MAX_CONTRIBUTORS:
		return false
	if balance == 0 and not refunds.is_empty():
		return false
	var total: int = 0
	var previous: String = ""
	for refund_value: Variant in refunds:
		if not refund_value is Dictionary:
			return false
		var refund: Dictionary = refund_value
		if refund.size() != REFUND_KEYS.size():
			return false
		for key: String in REFUND_KEYS:
			if not refund.has(key):
				return false
		if not _valid_player_id(refund.get("player_id")):
			return false
		var player_id: String = str(refund["player_id"])
		# 退款行必须按 player_id 严格升序，既去重也锁定确定性顺序。
		if player_id <= previous:
			return false
		previous = player_id
		var amount: int = _whole_in_range(refund.get("amount"), MAX_BALANCE)
		if amount <= 0:
			return false
		total += amount
		if total > MAX_BALANCE:
			return false
	return total == balance


static func _valid_roles(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var roles: Dictionary = value
	if roles.size() != ROLE_NAMES.size():
		return false
	for role: String in ROLE_NAMES:
		if not roles.has(role):
			return false
		var row_value: Variant = roles[role]
		if not row_value is Dictionary:
			return false
		var row: Dictionary = row_value
		if row.size() != ROLE_ROW_KEYS.size():
			return false
		for key: String in ROLE_ROW_KEYS:
			if not row.has(key) or not row[key] is bool:
				return false
			if bool(row[key]) != bool(ROLE_PERMISSIONS[role][key]):
				return false
	return true


## 规范载荷：把请求编码成 JSON（缴入者按 id 排序，避免同一组事实因字典插入
## 顺序不同而被重放判定为 `command_conflict`），再取 SHA-256 摘要。
static func _dissolve_payload(command_id: String, org_id: String, actor: String,
		now_utc: float, balance: int, pending_spend: int,
		contributors: Dictionary) -> String:
	var ids: Array = contributors.keys()
	ids.sort()
	var ordered: Dictionary = {}
	for player_id: Variant in ids:
		ordered[str(player_id)] = int(contributors[player_id])
	var canonical: String = JSON.stringify([
		"dissolve", command_id, org_id, actor, float(now_utc),
		balance, pending_spend, ordered,
	])
	return PAYLOAD_PREFIX + canonical.sha256_text()


static func _valid_payload(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if not text.begins_with(PAYLOAD_PREFIX):
		return false
	var digest: String = text.substr(PAYLOAD_PREFIX.length())
	if digest.length() != PAYLOAD_DIGEST_LENGTH:
		return false
	for index: int in digest.length():
		var code: int = digest.unicode_at(index)
		var digit: bool = code >= 48 and code <= 57
		var lower: bool = code >= 97 and code <= 102
		if not digit and not lower:
			return false
	return true


static func _replay_dissolve(state: Dictionary, command_id: String,
		payload: String) -> Dictionary:
	var commands_value: Variant = state.get("command_results")
	if not commands_value is Dictionary:
		return {}
	var commands: Dictionary = commands_value
	if not commands.has(command_id):
		return {}
	var entry: Variant = commands[command_id]
	if not entry is Dictionary or str((entry as Dictionary).get("payload", "")) != payload:
		return _error("command_conflict")
	var result: Variant = (entry as Dictionary).get("result")
	if not result is Dictionary:
		return {}
	return {
		"ok": true,
		"reason": "",
		"duplicate": true,
		"state": state,
		"organization_id": str((result as Dictionary).get("organization_id", "")),
		"clearing": ((result as Dictionary)["clearing"] as Dictionary).duplicate(true),
	}


## 只读的退款拆分：与 `dissolve()` 共用 `_clearing()` 的比例与余数规则，不改
## 文档、不创建命令。权威在「农场已退款、组织或基金文档还没写完」的恢复路径
## 上用它与账本付款分录对照，避免在第二处复制清算算术。
static func refunds(balance: int, contributors: Dictionary) -> Dictionary:
	var computed: Dictionary = _clearing({"account_id": ""}, balance, contributors)
	if not bool(computed.get("ok", false)):
		return computed
	var refunds_value: Variant = (computed["clearing"] as Dictionary)["refunds"]
	return {
		"ok": true,
		"reason": "",
		"refunds": (refunds_value as Array).duplicate(true),
	}


## 该组织未完成的解散意图；没有时返回空表。
static func pending_dissolve(state: Dictionary, org_id: String) -> Dictionary:
	var pending_value: Variant = state.get(PENDING_DISSOLVES_KEY)
	if not pending_value is Dictionary:
		return {}
	var entry: Variant = (pending_value as Dictionary).get(org_id)
	return entry if entry is Dictionary else {}


## 在退款之前把已授权的解散意图写进组织文档。之后退款、关闭组织、移除基金行
## 任何一步中断，都能从意图完成；意图与关闭状态在同一次组织保存里切换，不留下
## 两套事实。命令 id 已被占用时拒绝，避免把重放记录改写成新意图。
static func mark_pending_dissolve(state: Dictionary, org_id: String, command_id: String,
		actor: String, at_utc: float, balance: int,
		contributors: Dictionary) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	var org: Variant = _organization_or_null(state, org_id)
	if not org is Dictionary:
		return _error("unknown_org")
	if str((org as Dictionary)["status"]) != STATUS_ACTIVE:
		return _error("already_closed")
	if not pending_dissolve(state, org_id).is_empty():
		return _error("pending_exists")
	var commands_value: Variant = state["command_results"]
	if commands_value is Dictionary and (commands_value as Dictionary).has(command_id):
		return _error("command_conflict")
	var parsed: Dictionary = _parse_contributors(contributors)
	if not bool(parsed.get("ok", false)):
		return _error("invalid_contributors")
	var split: Dictionary = refunds(balance, parsed["contributors"])
	if balance <= 0 or not bool(split.get("ok", false)) \
			or (split["refunds"] as Array).is_empty():
		return _error("invalid_clearing")
	var entry: Dictionary = {
		"command_id": command_id,
		"actor": actor,
		"at_utc": float(at_utc),
		"balance": balance,
		"contributors": (parsed["contributors"] as Dictionary).duplicate(true),
	}
	var candidate: Dictionary = state.duplicate(true)
	var pending: Dictionary = {}
	var candidate_pending: Variant = candidate.get(PENDING_DISSOLVES_KEY)
	if candidate_pending is Dictionary:
		pending = candidate_pending
	pending[org_id] = entry
	candidate[PENDING_DISSOLVES_KEY] = pending
	if not valid(candidate):
		return _error("invalid_pending")
	return {"ok": true, "reason": "", "state": candidate, "entry": entry.duplicate(true)}


## 用意图里保存的已授权事实完成解散：关闭组织、写入同命令的清算记录，并移除
## 意图。不重新检查当前负责人，因为授权发生在意图写入时；读取方也不依赖退款
## 分录，余额与缴入者都在意图里。
static func finish_pending_dissolve(state: Dictionary, org_id: String) -> Dictionary:
	if not valid(state):
		return _error("invalid_state")
	var entry: Dictionary = pending_dissolve(state, org_id)
	if entry.is_empty():
		return _error("no_pending")
	var org: Variant = _organization_or_null(state, org_id)
	if not org is Dictionary:
		return _error("unknown_org")
	var row: Dictionary = org
	if str(row["status"]) != STATUS_ACTIVE:
		return _error("already_closed")
	var balance: int = int(entry["balance"])
	var contributors_value: Variant = entry["contributors"]
	var contributors: Dictionary = contributors_value if contributors_value is Dictionary \
		else {}
	var computed: Dictionary = _clearing(row, balance, contributors)
	if not bool(computed.get("ok", false)):
		return _error(str(computed.get("reason", "unowned_balance")))
	var clearing: Dictionary = (computed["clearing"] as Dictionary).duplicate(true)
	var command_id: String = str(entry["command_id"])
	var actor: String = str(entry["actor"])
	var at_utc: float = float(entry["at_utc"])
	var candidate: Dictionary = state.duplicate(true)
	var candidate_row: Dictionary = candidate["organizations"][org_id]
	candidate_row["status"] = STATUS_CLOSED
	candidate_row["closed_utc"] = at_utc
	candidate_row["closed_by"] = actor
	var history: Array = candidate_row["history"]
	history.append(_history_row(HISTORY_DISSOLVED, actor, "", at_utc))
	var candidate_commands: Dictionary = candidate["command_results"]
	candidate_commands[command_id] = {
		"payload": _dissolve_payload(command_id, org_id, actor, at_utc, balance, 0,
			contributors),
		"result": {
			"ok": true, "reason": "", "organization_id": org_id,
			"clearing": clearing.duplicate(true),
		},
	}
	var candidate_pending: Dictionary = candidate[PENDING_DISSOLVES_KEY]
	candidate_pending.erase(org_id)
	if candidate_pending.is_empty():
		candidate.erase(PENDING_DISSOLVES_KEY)
	if not valid(candidate):
		return _error("invalid_pending")
	return {
		"ok": true, "reason": "", "state": candidate,
		"organization_id": org_id, "clearing": clearing,
	}


## 按缴入比例分配余额：每份取整数下界，剩余单位按 id 升序逐一补齐。结果与
## 参数顺序无关，退款行升序，合计等于余额。
static func _clearing(org: Dictionary, balance: int,
		contributors: Dictionary) -> Dictionary:
	var account_id: String = str(org["account_id"])
	if balance == 0:
		return {
			"ok": true,
			"reason": "",
			"clearing": {"account_id": account_id, "balance": 0, "refunds": []},
		}
	var total: int = 0
	for player_id: Variant in contributors:
		total += int(contributors[player_id])
	if total <= 0:
		return _error("unowned_balance")
	var ids: Array = contributors.keys()
	ids.sort()
	var shares: Array = []
	var assigned: int = 0
	for player_id: Variant in ids:
		var share: int = balance * int(contributors[player_id]) / total
		shares.append(share)
		assigned += share
	var remainder: int = balance - assigned
	for index: int in remainder:
		shares[index] = int(shares[index]) + 1
	var refunds: Array = []
	for index: int in ids.size():
		if int(shares[index]) > 0:
			refunds.append({"player_id": str(ids[index]), "amount": int(shares[index])})
	return {
		"ok": true,
		"reason": "",
		"clearing": {"account_id": account_id, "balance": balance, "refunds": refunds},
	}


static func _parse_options(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _error("invalid_options")
	var options: Dictionary = value
	if options.size() != OPTION_KEYS.size():
		return _error("invalid_options")
	for key: String in OPTION_KEYS:
		if not options.has(key):
			return _error("invalid_options")
	if not _valid_command_id(options["command_id"]):
		return _error("invalid_command_id")
	var balance: int = _whole_in_range(options["balance"], MAX_BALANCE)
	if balance < 0:
		return _error("invalid_balance")
	var pending_spend: int = _whole_in_range(options["pending_spend"], MAX_SAFE_INTEGER)
	if pending_spend < 0:
		return _error("invalid_pending_spend")
	var parsed: Dictionary = _parse_contributors(options["contributors"])
	if not bool(parsed.get("ok", false)):
		return _error("invalid_contributors")
	var contributors: Dictionary = parsed["contributors"]
	return {
		"ok": true,
		"reason": "",
		"command_id": str(options["command_id"]),
		"balance": balance,
		"pending_spend": pending_spend,
		"contributors": contributors.duplicate(true),
	}


## 缴入表既用于解散选项，也用于保留下来的解散意图；两处必须同一份校验，
## 否则写入合法的意图可能在恢复时算不出退款。
static func _parse_contributors(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _error("invalid_contributors")
	var contributors: Dictionary = value
	if contributors.size() > MAX_CONTRIBUTORS:
		return _error("invalid_contributors")
	var total: int = 0
	for player_id: Variant in contributors:
		if not _valid_player_id(player_id):
			return _error("invalid_contributors")
		var amount: int = _whole_in_range(contributors[player_id], MAX_CONTRIBUTION)
		if amount < 0:
			return _error("invalid_contributors")
		total += amount
		if total > MAX_SAFE_INTEGER:
			return _error("invalid_contributors")
	return {
		"ok": true, "reason": "",
		"contributors": contributors.duplicate(true),
	}


static func _history_row(kind: String, actor: String, target: String,
		at_utc: float) -> Dictionary:
	return {"kind": kind, "actor": actor, "target": target, "at_utc": at_utc}


static func _organization_or_null(state: Dictionary, org_id: String) -> Variant:
	if not _valid_org_id(org_id):
		return null
	var organizations: Variant = state.get("organizations")
	if not organizations is Dictionary:
		return null
	return (organizations as Dictionary).get(org_id)


static func _history_full(org: Dictionary) -> bool:
	var history: Variant = org.get("history")
	return history is Array and (history as Array).size() >= MAX_HISTORY


## 追加历史行的前提：新行时刻不得早于最后一行，否则候选文档会被 `valid()`
## 拒绝，而读取方会看到“关闭之后又加入”这种自相矛盾的历史。
static func _history_regression(org: Dictionary, now_utc: float) -> bool:
	var history: Variant = org.get("history")
	if not history is Array or (history as Array).is_empty():
		return false
	var last: Variant = (history as Array)[(history as Array).size() - 1]
	if not last is Dictionary:
		return true
	return float(now_utc) < float((last as Dictionary).get("at_utc", 0.0))


static func _historic_role_of(org: Dictionary, player_id: String) -> String:
	var members: Variant = org.get("members")
	if not members is Dictionary or not (members as Dictionary).has(player_id):
		return ""
	return str((members as Dictionary)[player_id])


static func _can(org: Dictionary, role: String, permission: String) -> bool:
	var roles: Variant = org.get("roles")
	if not roles is Dictionary:
		return false
	var row: Variant = (roles as Dictionary).get(role)
	if not row is Dictionary:
		return false
	return bool((row as Dictionary).get(permission, false))


static func _success(candidate: Dictionary) -> Dictionary:
	return {"ok": true, "reason": "", "state": candidate}


static func _error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


static func _valid_org_id(value: Variant) -> bool:
	return value is String and OwnerIds.valid(value)


static func _valid_player_id(value: Variant) -> bool:
	return value is String and OwnerIds.valid(value)


static func _valid_role(value: Variant) -> bool:
	return value is String and str(value) in ROLE_NAMES


static func _valid_status(value: Variant) -> bool:
	return value is String and str(value) in STATUSES


static func _valid_command_id(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_COMMAND_ID_LENGTH:
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		if code < 32 or code == 127:
			return false
	return true


static func _valid_name(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_NAME_LENGTH:
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


## 金额必须是正整数；JSON 往返会把整数读成浮点，因此容许整值浮点，但拒绝
## 零、负数、小数和非有限值。
static func _valid_amount(value: Variant) -> bool:
	if not value is int and not value is float:
		return false
	var number: float = float(value)
	return is_finite(number) and number > 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)


## 非负整值，超过上限返回 -1，同时承担“形状非法”的标记；调用方分别用
## `< 0` 判断形状，`<= 0` 判断业务下限。
static func _whole_in_range(value: Variant, maximum: int) -> int:
	if not value is int and not value is float:
		return -1
	var number: float = float(value)
	if not is_finite(number) or number != floorf(number):
		return -1
	if number < 0.0 or number > float(maximum):
		return -1
	return int(number)
