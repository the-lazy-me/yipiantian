extends RefCounted
## M11-02 组织规则最小切片：成员、职位、权限、公共账户引用与负责人交接。
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
##       }
##     }
##   }
##
## 组织资产身份由 `org_id` 和派生的 `account_id` 决定，负责人只是成员表中的
## 职位；换届只改两个成员的职位，从不改组织 id、账户 id 或组织行本身。每个
## 组织恰好一名负责人，最后一名成员不能直接离开（本切片没有解散规则）。

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

const STATE_KEYS: Array[String] = ["organizations"]
const ORG_KEYS: Array[String] = ["name", "created_utc", "members", "roles", "account_id"]
const ROLE_ROW_KEYS: Array[String] = ["can_spend", "can_manage"]

const MAX_ORGANIZATIONS: int = 64
const MAX_MEMBERS: int = 256
const MAX_NAME_LENGTH: int = 64
const MAX_SAFE_INTEGER: int = 9007199254740991
const ACCOUNT_PREFIX: String = "org_"


## 没有组织时的初始文档。
static func empty() -> Dictionary:
	return {"organizations": {}}


## 组织账户 id 由组织 id 推导。换届、退出和改名都不改变它。
static func account_for(org_id: String) -> String:
	return ACCOUNT_PREFIX + org_id


## 报告成员在组织中的职位；组织或成员不存在时返回空串。
static func role_of(state: Dictionary, org_id: String, player_id: String) -> String:
	var org: Variant = _organization_or_null(state, org_id)
	if not org is Dictionary:
		return ""
	var members: Variant = (org as Dictionary).get("members")
	if not members is Dictionary or not (members as Dictionary).has(player_id):
		return ""
	return str((members as Dictionary)[player_id])


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
	}
	return _success(candidate)


## 加入组织。新成员固定为普通成员，职位只能由可管理角色指派。
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
	var pid: String = str(player_id)
	var members: Dictionary = (org as Dictionary)["members"]
	if members.has(pid):
		return _error("already_member")
	if members.size() >= MAX_MEMBERS:
		return _error("org_full")
	var candidate: Dictionary = state.duplicate(true)
	var candidate_members: Dictionary = candidate["organizations"][id]["members"]
	candidate_members[pid] = ROLE_MEMBER
	return _success(candidate)


## 离开组织。负责人必须先交接；最后一名成员不能离开，因为本切片没有解散
## 规则，留下一个没人能管理的账户比隐式解散更安全。
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
	var pid: String = str(player_id)
	var members: Dictionary = (org as Dictionary)["members"]
	if not members.has(pid):
		return _error("not_member")
	if members.size() == 1:
		return _error("last_member")
	if str(members[pid]) == ROLE_LEADER:
		return _error("leader_must_transfer")
	var candidate: Dictionary = state.duplicate(true)
	var candidate_members: Dictionary = candidate["organizations"][id]["members"]
	candidate_members.erase(pid)
	return _success(candidate)


## 指派已有成员的新职位。只有 `can_manage` 角色可以指派，目标必须是成员；
## 负责人职位不能经此处产生，必须走 `transfer_leadership()`。
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
	var candidate: Dictionary = state.duplicate(true)
	var candidate_members: Dictionary = candidate["organizations"][id]["members"]
	candidate_members[target_id] = str(role)
	return _success(candidate)


## 负责人交接。原负责人降为普通成员，新负责人必须是当前成员。组织 id 和
## 账户 id 完全不变，因此资产身份不随换届改变。
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
	var candidate: Dictionary = state.duplicate(true)
	var candidate_members: Dictionary = candidate["organizations"][id]["members"]
	candidate_members[actor_id] = ROLE_MEMBER
	candidate_members[leader_id] = ROLE_LEADER
	return _success(candidate)


## 支出授权检查，不写文档。调用方必须来自组织成员，其当前职位需要
## `can_spend`；账户 id 必须等于组织声明的账户，不能改指向别的账户；金额
## 必须是正整数。拒绝原因彼此区分，便于证明“越权支出拒绝”。
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


## 严格文档校验：顶层与组织行键集精确、名称/时间/id/账户合法、角色枚举与
## 权限表逐项匹配、每个组织恰好一名负责人，所有表都受上限约束。
static func valid(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var document: Dictionary = value
	if document.size() != STATE_KEYS.size() or not document.has("organizations"):
		return false
	var organizations_value: Variant = document.get("organizations")
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
	return true


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
	return leaders == 1


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


static func _organization_or_null(state: Dictionary, org_id: String) -> Variant:
	if not _valid_org_id(org_id):
		return null
	var organizations: Variant = state.get("organizations")
	if not organizations is Dictionary:
		return null
	return (organizations as Dictionary).get(org_id)


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
