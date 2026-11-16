extends RefCounted
## M3-01 headless world session. Starts from the local v27 storage boundary,
## executes commands on the authoritative FarmState and persists through
## FarmStore. No scene, node, DisplayServer, GPU, clock or network access.

const FarmState = preload("res://farm/farm_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Crops = preload("res://farm/crop_catalog.gd")
const NatureState = preload("res://farm/nature_state.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const TerritoryState = preload("res://world/territory_state.gd")
const TerritoryStore = preload("res://world/territory_store.gd")
const TerritoryPaths = preload("res://world/territory_paths.gd")
const Organization = preload("res://world/organization_state.gd")
const OrganizationStore = preload("res://world/organization_store.gd")
const UnitState = preload("res://conflict/unit_state.gd")
const UnitStore = preload("res://world/unit_store.gd")
const PublicFund = preload("res://world/public_fund.gd")
const FundStore = preload("res://world/fund_store.gd")
const PublicWorks = preload("res://world/public_works.gd")
const PublicWorksStore = preload("res://world/public_works_store.gd")
const Participation = preload("res://conflict/participation_state.gd")
const ParticipationStore = preload("res://world/participation_store.gd")
const Disputes = preload("res://world/dispute_state.gd")
const DisputesStore = preload("res://world/disputes_store.gd")
const ResolutionState = preload("res://world/resolution_state.gd")
const ResolutionsStore = preload("res://world/resolutions_store.gd")
const ResolutionEffects = preload("res://world/resolution_effects.gd")
const ResolutionEffectsStore = preload("res://world/resolution_effects_store.gd")
const UnitConflict = preload("res://conflict/unit_conflict.gd")
const ConflictSettlement = preload("res://world/conflict_settlement.gd")
const ConflictStore = preload("res://world/conflict_store.gd")
const Economy = preload("res://farm/economy_state.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")
const OwnerIds = preload("res://farm/owner_id.gd")
const Ledger = preload("res://farm/ledger_state.gd")
const Market = preload("res://farm/market_state.gd")
const NpcIntent = preload("res://npc/npc_intent.gd")
const NpcResidentLedger = preload("res://npc/npc_resident_ledger.gd")
const NpcResidentLedgerStore = preload("res://npc/npc_resident_ledger_store.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")
const NpcRoles = preload("res://npc/npc_roles.gd")
const NpcSocial = preload("res://npc/npc_social.gd")
const NpcSocialMemory = preload("res://npc/npc_social_memory.gd")
const NpcInvitation = preload("res://npc/npc_invitation.gd")
const NpcDialogue = preload("res://npc/npc_dialogue.gd")
const NpcMemory = preload("res://npc/npc_memory.gd")
const NpcMemoryFeed = preload("res://npc/npc_memory_feed.gd")
const NpcPersonality = preload("res://npc/npc_personality.gd")
const ResidentsStore = preload("res://world/residents_store.gd")

# 一次成功消费后的居民冷却。意图自身的过期窗口只有 120 秒；冷却稍长，保证同一
# 权威时刻的重复扫描不会重新规划同一件事，同时给后续行为切片留下可调常量。
const RESIDENT_COOLDOWN_SECONDS: float = 300.0
## 社交的调用方上限：滚动 24 小时内每位居民最多 4 个动作、1 次赠礼。规则模块
## 自身的动作冷却（最长的邀请 3600 秒）不足以约束一整天，因此由权威在投影上下文
## 与选择前执行这两项上限；计数来自已持久化关系文档里的动作/赠礼时刻，重启后
## 仍然生效。
const RESIDENT_SOCIAL_WINDOW_SECONDS: float = 86400.0
const RESIDENT_SOCIAL_DAILY_CAP: int = 4
const RESIDENT_GIFT_DAILY_CAP: int = 1
## 自发社交选中 `invite` 时创建的邀约种类。规则层的 `invite` 动作不带子种类，
## 权威固定映射为“来访”，有效期与派生 id 由 `NpcInvitation` 决定。
const RESIDENT_INVITATION_KIND: String = NpcInvitation.KIND_VISIT
## 被邀请方是否接受的确定性阈值：对发起人的 affinity 加上本人 warm/suspicion
## 人格差，达到 0 即接受，否则拒绝。没有 RNG、模型或自由文本。
const INVITATION_ACCEPT_SCORE: int = 0

## 单个目标（防守方 + 地块）的累计交战损失预算。参与制度自己的 `loss_cap`
## 按窗口累计，跨窗口反复袭击同一目标仍可能无限累积；这个固定常量由权威决定，
## 客户端不能指定，给“旧窗口结束、新窗口再打”加上一个总上限。100 与参与制度
## 文档和夹具里使用的示例预算一致，也足以覆盖一次中队的损失。
const CONFLICT_TARGET_LOSS_CAP: int = 100
## 只读视图里“近期结果”的上限。consumed 可容纳 1024 条，全部下发会超出 48 KiB
## 答复预算；20 条摘要足以显示最近战况，且仍按命令 id 稳定排序。
const CONFLICT_RECENT_RESULTS: int = 20

# 客户端按上一次权威摘要的时钟给命令打戳，到达时天然落后一个单程延迟。这个
# 有界的宽容把网络延迟与真正的倒填区分开；更早的命令仍按 time_backwards 拒绝。
const COMMAND_CLOCK_TOLERANCE: float = 2.0
# 客户端时钟只在摘要之间自行前进，正常偏差是秒级。命令时间超过服务器逻辑时钟
# 这个上界就拒绝，避免任意 at_utc 被当作已过去的时间来结算生长或经济。
const COMMAND_CLOCK_FUTURE_TOLERANCE: float = 3600.0

## Emitted when a commit or a time advance changed shared state that other
## members cannot reconstruct from the command alone: economy settlement and
## cadastre ownership. The host answers it with a fresh world summary; no new
## network message type is introduced.
signal shared_changed

var store: FarmStore
var farm: FarmState
var decorations: Decorations
var nature: NatureState
var nature_store: NatureStore
var territory: Dictionary = {}
var territory_store: TerritoryStore
var commands: FarmCommand
var now_utc: float = 0.0
## 服务器自有的单调逻辑时钟。生长结算仍由 now_utc / advance_to 驱动，但邀请
## 与社交到期不能等下一次生长事件，因此另记启动时刻和单调经过时间。
var _session_start_utc: float = 0.0
var _session_started_ms: int = 0
var world_id: String = ""
var directory: String = ""
var _nature_persisted: bool = false
var _territory_persisted: bool = false
## 居民自主行动默认关闭：只有显式调用 `enable_residents()` 的权威才会在
## `settle_residents()` / 启用后的 `settle_economy_now()` 中结算三名居民。
var residents_enabled: bool = false
## 多居民意图账本文档；缺失时为合法空文档，消费成功后才写盘。
var residents: Dictionary = {}
var residents_store: NpcResidentLedgerStore
## 居民社交关系与有界记忆。与意图账本分开的 world 级 sidecar：它只保存关系、
## 动作时刻与记忆行，不复制现金、货物、账户或权属。缺失时按 world 初始化相邻
## 关系与空记忆；存在但损坏、异世界或超限则拒绝启动。默认关闭时只读不写。
var resident_social: Dictionary = {}
var resident_memories: Dictionary = {}
## 有界邀约表（最多 64 条）。行是 `NpcInvitation` 规则行加上创建它的 act id
## `command_id`；同一 command/act id 重放不会创建第二条，也不会二次裁决。
var resident_invitations: Dictionary = {}
## 每名玩家对每名居民的对话状态：最近对话时刻、当日已获得的关系增量与所属
## UTC 日。按 (player_id, npc_id) 键控，只随 `residents.json` 同一次原子保存
## 写入；这里是权威投影，不是客户端可写的状态。
var resident_dialogues: Dictionary = {}
## 已接受对话命令的首个回复，只在内存里：同一 command id 重放返回首次答复且
## 不二次写关系/记忆/对话状态。跨重启的重试由持久化的 `last_dialogue_utc`
## 冷却拒绝，不会二次增长；因此不需把命令日志写进信封。
var _dialogue_results: Dictionary = {}
const MAX_DIALOGUE_RESULTS: int = 64
var residents_state_store: ResidentsStore
## 组织成员、职位与负责人表。与 territory.json 同级的 world 级 sidecar；缺失
## 表示还没有任何组织，存在但无效则拒绝启动。
var organizations: Dictionary = {}
var organizations_store: OrganizationStore
## 已接受组织命令的首个结果。sidecar 的 `state` 形状必须保持严格，所以重放窗口
## 只存在内存里：同一命令 id 的即时重试幂等，重启后的重试仍由规则给出
## `already_exists` / `already_member` 等具名结果。
var _organization_results: Dictionary = {}
const MAX_ORGANIZATION_RESULTS: int = 64
## 单位名册与补给文档。与 territory.json 同级的 world 级 sidecar；缺失表示还没有
## 任何单位，存在但无效则拒绝启动。
var units: Dictionary = {}
var units_store: UnitStore
## 公共基金文档。与 territory.json 同级的 world 级 sidecar；缺失表示还没有任何
## 基金，存在但无效则拒绝启动。基金余额必须始终等于组织真实账户现金。
var funds: Dictionary = {}
var funds_store: FundStore
## 已接受基金命令的首个结果。基金文档的 `state` 形状必须保持严格，且本切片
## 明确不在基金文档里另存命令表，所以重放窗口只存在内存里：同一命令 id 的即时
## 重试幂等；缴入/支出跨重启的重试由账本 `fund_pay_` / `fund_spend_` 分录补写。
var _fund_results: Dictionary = {}
const MAX_FUND_RESULTS: int = 64
## 公共项目文档（M8-04a）。与 territory.json 同级的 world 级 sidecar；缺失表示
## 还没有任何项目，存在但无效则拒绝启动。承诺只是记账承诺，不托管现金。
var public_works: Dictionary = {}
var public_works_store: PublicWorksStore
## 已接受公共项目命令的首个结果。项目文档的 `state` 形状必须保持严格，重放窗口
## 只存在内存里；跨重启的 build 重试由 `fund_spend_pw_spend_<id>` 账本分录与基金
## history 补写，绝不二次支出。
var _public_works_results: Dictionary = {}
const MAX_PUBLIC_WORKS_RESULTS: int = 64
## 参与制度文档（M12-02）。与 territory.json 同级的 world 级 sidecar；房间没有
## 房主玩家时保持为空，所有声明/同意操作返回 `no_host`。房主身份是该文档的持久
## 事实，可用启动参数显式绑定，但显式值必须与已存文档一致。
var participation: Dictionary = {}
var participation_store: ParticipationStore
## 纠纷案件文档（M12-04）。与 territory.json 同级的 world 级 sidecar；房间没有
## 房主玩家时保持为空，所有写操作返回 `no_host`。文档存在时尊重其
## `authority_roles`，房主只用于初始化缺失文档的权威花名册。
var disputes: Dictionary = {}
var disputes_store: DisputesStore
## 补偿执行记录，来自 disputes.json 信封层：每案 {amount, at_utc, paid}。
## `paid=false` 表示裁定的转账可能尚未落盘，重启时按账本事件核对并补付；
## 它不进入 `state`，所以案件文档仍是严格两键形状。
var _dispute_enforcement: Dictionary = {}
## 已接受纠纷命令的首个结果。纠纷文档的 `state` 形状必须保持严格，不能在案件
## 文档里另存命令表，所以重放窗口只存在内存里；跨重启的同一命令由案件自身
## 已写入的当事人、证据 id、裁定与审计推导 `duplicate`，绝不二次写。
var _disputes_results: Dictionary = {}
const MAX_DISPUTES_RESULTS: int = 64
const DISPUTE_ACTIONS: Array[String] = [
	"file", "accept", "reject", "evidence", "rule", "appeal", "correct", "close",
]
## 交战结算上下文（M12-03）。world 级 sidecar；`state` 必须通过
## `ConflictSettlement.valid_context()`，`_conflict_applied` 是存储层自己的提交
## 进度标记，不进入规则文档。缺失时是 `world_id` 已知的空上下文，参与文档由
## 交战入口在结算前覆盖成实时文档。
var conflicts: Dictionary = {}
var conflicts_store: ConflictStore
var _conflict_applied: Dictionary = {}
## 规则决议文档（M11-03）。与 territory.json 同级的 world 级 sidecar；缺失是
## 合法空决议表且不写盘，存在但损坏、版本不支持或属于另一个世界则拒绝启动。
## 文档本身保持 `ResolutionState` 的严格两键形状，命令日志只存在于信封层。
var resolutions: Dictionary = {}
var resolutions_store: ResolutionsStore
## 决议效果文档（M11-03）：`resolution_effects.json`。它只由已生效并已登记的
## 决议推导，但应用水位必须跨重启保留，否则重启会重复应用或丢掉旧版本。缺失
## 是合法空文档且不写盘；存在但损坏、版本不支持或属于另一个世界拒绝启动。
var resolution_effects: Dictionary = {}
var resolution_effects_store: ResolutionEffectsStore
## 已接受决议命令的首个结果，来自 `resolutions.json` 信封层的 `commands`。
## 同一 command id 的重放返回首次结果且不追加日志；换参数返回
## `command_conflict`。日志最多 `ResolutionsStore.MAX_COMMANDS` 行，超出淘汰最旧。
var _resolution_results: Dictionary = {}


## `world_identity` names the cadastre document's world. An empty value adopts
## the identity already stored on disk (or "world" for a fresh directory), so
## old headless callers keep working without knowing the world id. An explicit
## identity must match the stored document instead of silently relabelling land.
func open(save_directory: String, now_utc_seconds: float,
		world_identity: String = "", host_player: String = "") -> Dictionary:
	# The caller supplies a logical time. Missing worlds start from it; existing
	# worlds keep their stored settlement baselines until an action or advance.
	if not _valid_time(now_utc_seconds):
		return _failure("invalid_time")
	var normalized: String = ProjectSettings.globalize_path(save_directory).simplify_path()
	if not normalized.is_absolute_path():
		return _failure("relative_path")
	directory = normalized
	store = FarmStore.new(directory)
	var loaded: Dictionary = store.load_state()
	if not loaded.ok:
		# Recovery stays an explicit storage decision; a failed load is never
		# replaced by a fresh farm.
		return _failure("load_" + str(loaded.kind))
	commands = FarmCommand.new()
	now_utc = now_utc_seconds
	_session_start_utc = now_utc_seconds
	_session_started_ms = Time.get_ticks_msec()
	nature_store = NatureStore.new(directory)
	var nature_loaded: Dictionary = nature_store.load_state()
	if not nature_loaded.ok:
		# A nature document that exists but cannot be read must not be replaced
		# by a fresh seed: that would reroll weather the world already had.
		return _failure("load_nature_" + str(nature_loaded.kind))
	# The cadastre lives in its own document. A corrupt or relabelled document
	# stops the authority instead of being overwritten by a fresh layout.
	var territory_identity: String = world_identity if not world_identity.is_empty() else "world"
	territory_store = TerritoryStore.new(directory)
	var territory_loaded: Dictionary = territory_store.load_state(territory_identity)
	if not territory_loaded.ok:
		return _failure("load_territory_" + str(territory_loaded.kind))
	territory = territory_loaded.state
	var stored_world: String = str(territory.get("world_id", ""))
	if not world_identity.is_empty() and stored_world != world_identity:
		territory = {}
		return _failure("territory_world_mismatch")
	world_id = stored_world
	if world_id.is_empty():
		territory = {}
		return _failure("invalid_world")
	_territory_persisted = str(territory_loaded.kind) == "loaded"
	# 居民意图账本是与 territory.json 同级的 world 级 sidecar。缺失是合法空账本；
	# 存在但读不出来的文档必须让权威停止启动，否则重启会忘记已消费意图。
	residents_store = NpcResidentLedgerStore.new(directory)
	var residents_loaded: Dictionary = residents_store.load_state()
	if not residents_loaded.ok:
		return _failure("load_residents_" + str(residents_loaded.kind))
	residents = residents_loaded.state
	# 社交关系与记忆是另一个 world 级 sidecar。缺失是合法初始文档；损坏、版本
	# 不支持、属于另一个世界或超出规则容量必须让权威停止启动，否则重启会用空
	# 关系覆盖已发生的社交与记忆，或把异世界文档误当成本世界事实。
	residents_state_store = ResidentsStore.new(directory)
	var residents_state_loaded: Dictionary = residents_state_store.load_state(
		world_id, now_utc_seconds)
	if not residents_state_loaded.ok:
		return _failure("load_resident_state_" + str(residents_state_loaded.kind))
	resident_social = residents_state_loaded.state.social
	resident_memories = residents_state_loaded.state.memories
	resident_invitations = residents_state_loaded.state.invitations
	resident_dialogues = residents_state_loaded.state.dialogues
	# 组织表同样是 world 级 sidecar。缺失是合法的空表；存在但损坏或版本不支持
	# 必须让权威停止启动，否则重启会用空表覆盖已有成员与负责人。
	organizations_store = OrganizationStore.new(directory)
	var organizations_loaded: Dictionary = organizations_store.load_state()
	if not organizations_loaded.ok:
		return _failure("load_organizations_" + str(organizations_loaded.kind))
	organizations = organizations_loaded.state
	# 公共项目同样是 world 级 sidecar。缺失是合法的空项目表；存在但损坏或版本
	# 不支持必须让权威停止启动，否则重启会用空表覆盖已有项目、承诺与建成时间。
	public_works_store = PublicWorksStore.new(directory)
	var public_works_loaded: Dictionary = public_works_store.load_state()
	if not public_works_loaded.ok:
		return _failure("load_public_works_" + str(public_works_loaded.kind))
	public_works = public_works_loaded.state
	# 单位名册与补给同样是 world 级 sidecar。缺失是合法的空名册；存在但损坏或
	# 版本不支持必须让权威停止启动，否则重启会用空名册覆盖已有单位与补给状态。
	units_store = UnitStore.new(directory)
	var units_loaded: Dictionary = units_store.load_state(world_id)
	if not units_loaded.ok:
		return _failure("load_units_" + str(units_loaded.kind))
	units = units_loaded.state
	# A roster written for another world must not be applied to this one. The
	# unit ids and owners are world facts, so relabelling is refused explicitly
	# instead of being treated as a fresh empty roster.
	if str(units.get("world_id", "")) != world_id:
		units = {}
		return _failure("load_units_world_mismatch")
	# 交战上下文同样是 world 级 sidecar，在单位之后、农场之前加载。缺失是合法
	# 空上下文；存在但损坏、版本不支持或属于另一个世界必须停止启动，否则重启
	# 会用空表覆盖已结算的战利品与目标预算。
	conflicts_store = ConflictStore.new(directory)
	var conflicts_loaded: Dictionary = conflicts_store.load_state(world_id)
	if not conflicts_loaded.ok:
		return _failure("load_conflicts_" + str(conflicts_loaded.kind))
	conflicts = conflicts_loaded.state
	_conflict_applied = conflicts_loaded.applied
	# 基金文档同样是 world 级 sidecar。缺失是合法的空表；存在但损坏或版本不支持
	# 必须让权威停止启动，否则重启会用空表覆盖已有基金与支出历史。
	funds_store = FundStore.new(directory)
	var funds_loaded: Dictionary = funds_store.load_state()
	if not funds_loaded.ok:
		return _failure("load_funds_" + str(funds_loaded.kind))
	funds = funds_loaded.state
	# 参与制度同样是 world 级 sidecar。缺失且房间有房主玩家时是初始和平声明；
	# 缺失且没有房主时保持为空，声明类操作返回 `no_host`，而不是虚构一个房主。
	participation_store = ParticipationStore.new(directory)
	var participation_loaded: Dictionary = participation_store.load_state(
		world_id, host_player)
	if not participation_loaded.ok:
		return _failure("load_participation_" + str(participation_loaded.kind))
	participation = participation_loaded.state
	# 纠纷案件同样是 world 级 sidecar。缺失且房间有房主玩家时以房主初始化唯一
	# 权威；缺失且没有房主时保持为空，写操作返回 `no_host`。存在但损坏、版本
	# 不支持或属于另一个世界必须停止启动，否则重启会用空表覆盖已有案件与审计。
	disputes_store = DisputesStore.new(directory)
	var disputes_loaded: Dictionary = disputes_store.load_state(world_id, host_player)
	if not disputes_loaded.ok:
		return _failure("load_disputes_" + str(disputes_loaded.kind))
	disputes = disputes_loaded.state
	_load_dispute_commands(disputes_loaded.get("commands", []))
	_dispute_enforcement = disputes_loaded.get("enforcement", {}).duplicate(true)
	# 规则决议同样是 world 级 sidecar。缺失是合法的空决议表且不写盘；存在但损坏、
	# 版本不支持或属于另一个世界必须停止启动，否则重启会用空表覆盖已生效的规则
	# 版本、提案与撤销历史。命令日志只恢复内存重放窗口，不进入规则文档。
	resolutions_store = ResolutionsStore.new(directory)
	var resolutions_loaded: Dictionary = resolutions_store.load_state(world_id)
	if not resolutions_loaded.ok:
		return _failure("load_resolutions_" + str(resolutions_loaded.kind))
	resolutions = resolutions_loaded.state
	_load_resolution_commands(resolutions_loaded.get("commands", []))
	# 决议效果同样是 world 级 sidecar。缺失是合法空文档且不写盘；存在但损坏、
	# 版本不支持、属于另一个世界或与决议文档不一致必须停止启动，否则重启会用
	# 空效果覆盖已应用的水位，或让撤销后的规则重新产生税费。
	resolution_effects_store = ResolutionEffectsStore.new(directory)
	var effects_loaded: Dictionary = resolution_effects_store.load_state(world_id)
	if not effects_loaded.ok:
		return _failure("load_resolution_effects_" + str(effects_loaded.kind))
	resolution_effects = effects_loaded.state
	if not ResolutionEffects.consistent(resolution_effects, resolutions):
		resolution_effects = {}
		return _failure("load_resolution_effects_inconsistent")
	# 决议可能在上次退出前已生效，但效果尚未登记（例如两次落盘之间中断，或
	# 决议来自更早的版本）。打开世界时按生效版本补齐一次；写盘失败拒绝启动，
	# 让下一次启动重试，而不是带着缺失的效果继续服务。
	var backfilled: Dictionary = _backfill_resolution_effects(now_utc_seconds)
	if not bool(backfilled.get("ok", false)):
		return _failure("backfill_resolution_effects_" + str(backfilled.get("reason", "")))
	if loaded.kind == "missing":
		farm = FarmState.new(now_utc_seconds)
		decorations = Decorations.new()
		# A missing farm does not own the weather history: nature.json may already
		# exist (for example a world created but not yet committed). Adopt that seed
		# instead of sampling one now and discarding it on the first save.
		if nature_loaded.kind == "loaded":
			nature = NatureState.new()
			if not nature.restore_snapshot(nature_loaded.state):
				farm = null
				decorations = null
				nature = null
				return _failure("restore_nature")
			_nature_persisted = true
		else:
			nature = NatureState.new(NatureState.create_seed())
			_nature_persisted = false
		farm.set_environment(nature)
		# 基金余额与组织账户现金是同一事实的两份记录。两份文档不一致时不静默
		# 修正：那会凭空创造或抹掉资金，也会掩盖上一次写到一半的提交。
		if not _funds_match_farm(farm):
			funds = {}
			farm = null
			decorations = null
			nature = null
			return _failure("load_funds_mismatch")
		# A pending compensation needs the farm document it should have written;
		# a missing farm beside such a record is an inconsistent world, not a new
		# one to seed over.
		if not _dispute_enforcement.is_empty():
			farm = null
			decorations = null
			nature = null
			return _failure("recover_disputes_missing_farm")
		return {"ok": true, "kind": "created"}
	farm = FarmState.new()
	if not farm.restore_snapshot(loaded.farm):
		farm = null
		return _failure("restore_farm")
	decorations = Decorations.new()
	if not decorations.restore_snapshot(loaded.decorations):
		farm = null
		decorations = null
		return _failure("restore_decorations")
	nature = NatureState.new()
	if nature_loaded.kind == "loaded":
		if not nature.restore_snapshot(nature_loaded.state):
			farm = null
			decorations = null
			nature = null
			return _failure("restore_nature")
		_nature_persisted = true
	else:
		# A world saved before the nature document existed keeps the fixed
		# default seed, so reading it never samples a new sequence. The seed is
		# written before the next farm commit.
		_nature_persisted = false
	# The session owns the weather source; FarmState only queries the blocks it
	# is given and never reads a global or a store.
	farm.set_environment(nature)
	if not _funds_match_farm(farm):
		funds = {}
		farm = null
		decorations = null
		nature = null
		return _failure("load_funds_mismatch")
	# 裁定与补偿分属两个 sidecar。disputes 先落盘、farm 后落盘；如果上次在两次
	# 写入之间中断，信封里的 `paid=false` 记录会让这里补付或补记完成标记，绝不
	# 让已经裁定的补偿悬空，也绝不二次转账。
	var recovered: Dictionary = _recover_dispute_compensations()
	if not bool(recovered.get("ok", false)):
		farm = null
		decorations = null
		nature = null
		return _failure("recover_disputes_" + str(recovered.get("reason", "")))
	return {"ok": true, "kind": "loaded"}


func execute(command: Dictionary, actor: String = "") -> Dictionary:
	# A command enters the authoritative state only after its candidate was
	# written by FarmStore and the storage boundary accepted the commit.
	if farm == null:
		return _result(false, "not_open", false, "")
	# Retries of a committed id still replay; only new work outside the transit
	# allowance is refused. The future bound is measured against the server's own
	# monotonic clock, not against at_utc: a client-supplied time must never be
	# able to leap the world clock or settle economy deadlines early.
	var command_id: Variant = command.get("id")
	# ADR-028 §5: a new BUILD transaction reads the cadastre exactly once, from a
	# snapshot taken at the entrance. The snapshot is only consumed after
	# `commands.execute` produced a non-replay candidate; replays return before
	# the gate, so land transferred after a committed build never re-judges it.
	var is_build: bool = str(command.get("kind", "")) == FarmCommand.BUILD
	var land_view: Dictionary = territory.duplicate(true) if is_build else {}
	var land_sequence: int = int(territory.get("sequence", 0)) if is_build else 0
	var land_claimed: bool = false
	if FarmCommand.valid(command) and not (command_id is String and FarmCommand.has_committed(farm, command_id)):
		var at: float = float(command.at_utc)
		if at < now_utc - COMMAND_CLOCK_TOLERANCE:
			return _result(false, "time_backwards", false, str(command_id))
		if at > authority_now_utc() + COMMAND_CLOCK_FUTURE_TOLERANCE:
			return _result(false, "time_forwards", false, str(command_id))
	var execution: Dictionary = commands.execute(farm, command, actor, decorations.snapshot())
	if not execution.ok:
		return _result(false, str(execution.reason), bool(execution.duplicate), str(execution.command_id))
	if execution.duplicate:
		# A replay is not a new event: it does not advance the clock, scan the
		# economy, save or broadcast. Domain-level duplicates (a rule that already
		# applied this action in a durable window) take the same path.
		var replay: Dictionary = execution.result
		return {
			"ok": bool(replay.get("ok", false)), "reason": str(replay.get("reason", "")),
			"stage": "duplicate", "duplicate": true, "command_id": command.id,
			"reward_crop_id": replay.get("reward_crop_id", ""),
			"reward_amount": replay.get("reward_amount", 0),
		}
	var candidate: RefCounted = execution.candidate
	# ADR-028: the land gate runs after the farm rules accepted the candidate, so
	# the existing reasons (invalid_slot, invalid_blueprint, occupied, ...) keep
	# their priority. A refusal here discards the candidate before any file write.
	if is_build:
		var gate: Dictionary = TerritoryState.build_gate(land_view, str(command.slot_id), actor)
		if not bool(gate.get("ok", false)):
			return _result(false, str(gate.get("reason", "")), false, command.id)
		# This authority is single-threaded with no await, so the guard cannot fire
		# today. It records the transaction invariant for a future async or sharded
		# save: land that moved after the snapshot makes the gate decision stale.
		if int(territory.get("sequence", 0)) != land_sequence:
			return _result(false, "stale_land", false, command.id)
		# "First build claims the land": an unclaimed parcel is claimed for this
		# actor before the farm is written. The claim is its own sidecar write.
		if bool(gate.get("claim", false)):
			var land_candidate: Dictionary = land_view.duplicate(true)
			var claim: Dictionary = TerritoryState.claim(land_candidate, world_id,
				str(gate.get("parcel_id", "")), actor, str(command.id),
				_territory_action_time(str(command.id)))
			if not bool(claim.get("ok", false)):
				return _result(false, "claim_" + str(claim.get("reason", "")), false, command.id)
			var land_saved: Dictionary = territory_store.save_state(land_candidate)
			if not land_saved.ok:
				# The farm candidate is still private: the farm file and the live
				# farm stay exactly as they were, so the command is retriable.
				return _result(false, "save_land_" + str(land_saved.kind), false, command.id)
			# ADR-028 §5: if the farm write below fails, this completed claim stays.
			# It is an orphan claim, not an orphan building: the land is already
			# the retrying actor's, so the retry only has to write the farm. The
			# reverse order would leave a house on land its owner does not own.
			territory = land_candidate
			_territory_persisted = true
			land_claimed = true
	# Economy settlement is an authority sweep, not a command. It runs at the
	# authority's own now_utc; command.at_utc is only the command's timestamp and
	# never drives expiry, matching or overdue marking.
	var scan: Dictionary = settle_economy(candidate, now_utc)
	if not scan.ok:
		return _result(false, str(scan.reason), false, command.id)
	# The seed is written once, before the first farm commit. A failure here
	# changes no gameplay state and keeps the command retriable; a lost first
	# creation race adopts the winner's seed instead of writing its own.
	var nature_saved: Dictionary = _ensure_nature_persisted()
	if not nature_saved.ok:
		return _result(false, "save_nature_" + str(nature_saved.kind), false, command.id)
	var decoration_before: Dictionary = decorations.snapshot()
	decorations.unlock(candidate.snapshot().harvested, candidate.snapshot().kitchen)
	var saved: Dictionary = store.save_state(candidate, decorations)
	if not saved.ok:
		# Keep the in-memory decorations aligned with the last accepted commit.
		decorations.restore_snapshot(decoration_before)
		return _result(false, "save_" + str(saved.kind), false, command.id)
	farm.accept(candidate)
	# 农场已经提交：把这次命令投影成居民记忆。记忆写入或落盘失败只报告在
	# `memory` 字段里，绝不改变已经提交的命令结果。
	var memory: Dictionary = {}
	if residents_enabled:
		memory = _remember_committed_command(command, actor)
	# The kitchen is a world-shared document: a member's dish changes what every
	# neighbour sees, so peers get a fresh summary just as an economy commit
	# does. The acting client follows the same path; its own replay is skipped
	# because the summary is applied by each recipient.
	if FarmCommand.is_economy_kind(str(command.kind)) or str(command.kind) == FarmCommand.KITCHEN \
			or bool(scan.changed) or land_claimed:
		shared_changed.emit()
	var result: Dictionary = {
		"ok": true, "reason": "", "stage": "committed", "duplicate": false, "command_id": command.id,
		"reward_crop_id": execution.result.get("reward_crop_id", ""),
		"reward_amount": execution.result.get("reward_amount", 0),
		"market_expired": int(scan.counts.get("expired", 0)),
		"market_matched": int(scan.counts.get("matched", 0)),
		"market_delivered": int(scan.counts.get("delivered", 0)),
		"market_lost": int(scan.counts.get("lost", 0)),
		"loans_settled": int(scan.counts.get("loans", 0)),
	}
	if residents_enabled:
		result["memory"] = memory
	return result


## Runs the fixed post-commit/post-advance economy sweeps. Each rule function is
## deterministic and idempotent: `market_expire` releases dues, `market_match`
## refreshes quotes and fills, `market_deliver` returns arrived goods, and
## `economy_settle_loans` marks overdue contracts. Clients never trigger this;
## the authority calls it with its own clock and the result travels in the
## world summary.
func settle_economy(state: RefCounted, now_utc_seconds: float) -> Dictionary:
	var counts: Dictionary = {"expired": 0, "matched": 0, "delivered": 0, "lost": 0, "loans": 0}
	if state == null:
		return {"ok": false, "reason": "not_open", "counts": counts, "changed": false}
	var expired: Dictionary = state.market_expire(now_utc_seconds)
	if not expired.ok:
		return {"ok": false, "reason": "market_expire_" + str(expired.reason),
			"counts": counts, "changed": false}
	counts.expired = int(expired.get("expired", 0))
	var matched: Dictionary = state.market_match(now_utc_seconds)
	if not matched.ok:
		return {"ok": false, "reason": "market_match_" + str(matched.reason),
			"counts": counts, "changed": int(counts.expired) > 0}
	counts.matched = int(matched.get("count", 0))
	var delivered: Dictionary = state.market_deliver(now_utc_seconds)
	if not delivered.ok:
		return {"ok": false, "reason": "market_deliver_" + str(delivered.reason),
			"counts": counts, "changed": int(counts.expired) + int(counts.matched) > 0}
	counts.delivered = int(delivered.get("count", 0))
	# A declared-risk arrival can end as a loss instead of a delivery. It changes
	# state just as much: the shipment becomes terminal and a durable loss row is
	# written, so a sweep that only lost goods must still save and broadcast.
	counts.lost = int(delivered.get("lost", 0))
	var loans: Dictionary = state.economy_settle_loans(now_utc_seconds)
	if not loans.ok:
		return {"ok": false, "reason": "loans_" + str(loans.reason),
			"counts": counts,
			"changed": int(counts.expired) + int(counts.matched) + int(counts.delivered) \
				+ int(counts.lost) > 0}
	counts.loans = int(loans.get("count", 0))
	return {"ok": true, "reason": "", "counts": counts,
		"changed": int(counts.expired) + int(counts.matched) + int(counts.delivered) \
			+ int(counts.lost) + int(counts.loans) > 0}


## Periodic authority sweep. Expiry, matching against resting orders, arrivals
## and loan due dates are deadlines of their own; they must not wait for the
## next crop stage or the next player command. The server calls this on a short
## cadence with its own clock. It works on a candidate and only accepts it after
## the save succeeds, so a failed write leaves the live world exactly as it was.
func settle_economy_now(at_utc_seconds: float) -> Dictionary:
	if farm == null:
		return {"ok": false, "reason": "not_open", "changed": false, "counts": {}}
	if not is_finite(at_utc_seconds) or at_utc_seconds < 0.0:
		return {"ok": false, "reason": "invalid_time", "changed": false, "counts": {}}
	var candidate: RefCounted = farm.copy()
	var scan: Dictionary = settle_economy(candidate, at_utc_seconds)
	if not scan.ok:
		return scan
	# 居民结算默认不运行；启用后并入同一候选与同一次保存，绝不产生第二次写入或
	# 第二次广播。关闭时下面的分支不执行，返回值与改动前逐字节一致。
	var resident_outcome: Dictionary = {"ok": true, "changed": false,
		"ledger_changed": false, "social_changed": false,
		"invitation_changed": false, "candidate": candidate,
		"document": residents, "social": resident_social,
		"memories": resident_memories, "invitations": resident_invitations,
		"counts": {}, "failures": [], "intents": [], "social_actions": [],
		"invitation_actions": []}
	if residents_enabled:
		resident_outcome = _apply_residents(candidate, at_utc_seconds)
		if not resident_outcome.ok:
			return {"ok": false, "reason": str(resident_outcome.reason),
				"changed": false, "counts": scan.counts}
		candidate = resident_outcome.candidate
		if bool(resident_outcome.changed):
			scan.changed = true
			scan["residents"] = {
				"counts": resident_outcome.counts,
				"failures": resident_outcome.failures,
				"intents": resident_outcome.intents,
				"social": resident_outcome.social_actions,
				"invitations": resident_outcome.invitation_actions,
			}
	if not bool(scan.changed):
		return scan
	# Same ordering as execute()/save(): the seed is written before the first
	# farm commit so a sweep cannot create a farm that has no persisted seed.
	var nature_saved: Dictionary = _ensure_nature_persisted()
	if not nature_saved.ok:
		return {"ok": false, "reason": "save_nature_" + str(nature_saved.kind),
			"changed": false, "counts": scan.counts}
	var saved: Dictionary = store.save_state(candidate, decorations)
	if not saved.ok:
		return {"ok": false, "reason": "save_" + str(saved.kind), "changed": false,
			"counts": scan.counts}
	# 农场保存成功后写居民账本与社交/记忆 sidecar。任一文档写失败时农场文件已经
	# 落盘，因此接受同一候选并广播，避免“磁盘领先、内存落后”的分歧；已经在农场
	# 上的交易不会重发，关系文档留待后续结算重新记录。
	if residents_enabled:
		var resident_saved: Dictionary = _save_resident_documents(
			resident_outcome, at_utc_seconds)
		if not resident_saved.ok:
			farm.accept(candidate)
			shared_changed.emit()
			return {"ok": false, "reason": str(resident_saved.reason),
				"changed": true, "counts": scan.counts}
	farm.accept(candidate)
	shared_changed.emit()
	return scan


## 显式开启居民自主行动。只置本会话标志，不写任何文件：持久状态由调用方决定
## （账本在成功消费后由结算写盘，仍默认关闭，重启后需要再次调用）。
func enable_residents() -> Dictionary:
	residents_enabled = true
	return {"ok": true, "enabled": true}


## 居民结算入口。默认关闭时只返回 `disabled`，不建账户、不交易、不写盘。
## 启用后在同一 farm 候选上依次处理名册三人：确保经济账户 -> 读取本人现金、
## 货物、公开卖单与本人冷却 -> plan -> validate -> 以 intent.id 提交买单 ->
## market_match -> 成功才记录账本。任一居民失败只登记具名原因并继续下一个，
## 该居民的子候选整笔丢弃，不留下半笔交易。
##
## 经济结算之后，按同一时刻为每名居民投影社交上下文，对真实关系文档执行
## plan/validate/apply，并把已发生动作写入本人有界记忆。赠礼只改关系与记忆，
## 不移动现金、货物、账户或权属。
##
## 整批完成后才写盘：先确保自然种子，再保存农场，随后保存居民账本，最后保存
## 社交/记忆 sidecar，最后更新内存并广播。文档写失败时农场已经落盘，因此接受
## 同一候选、保持内存与磁盘一致，并照实返回具名原因；重试不会二次成交，也不会
## 对同一 act id 二次写入。
func settle_residents(at_utc_seconds: float) -> Dictionary:
	if farm == null:
		return _resident_failure("not_open")
	if not is_finite(at_utc_seconds) or at_utc_seconds < 0.0:
		return _resident_failure("invalid_time")
	if not residents_enabled:
		return {"ok": true, "reason": "disabled", "changed": false,
			"counts": {"opened": 0, "purchased": 0, "failed": 0, "socialized": 0},
			"failures": [], "intents": [], "social": [], "invitations": []}
	var candidate: RefCounted = farm.copy()
	var outcome: Dictionary = _apply_residents(candidate, at_utc_seconds)
	if not bool(outcome.ok):
		return _resident_failure(str(outcome.reason))
	if not bool(outcome.changed):
		return {"ok": true, "reason": "", "changed": false,
			"counts": outcome.counts, "failures": outcome.failures,
			"intents": outcome.intents, "social": outcome.social_actions,
			"invitations": outcome.invitation_actions}
	var nature_saved: Dictionary = _ensure_nature_persisted()
	if not nature_saved.ok:
		return _resident_failure("save_nature_" + str(nature_saved.kind))
	var saved: Dictionary = store.save_state(outcome.candidate, decorations)
	if not saved.ok:
		return _resident_failure("save_" + str(saved.kind))
	var resident_saved: Dictionary = _save_resident_documents(
		outcome, at_utc_seconds)
	if not resident_saved.ok:
		# 农场文件已落盘：接受同一候选以保持内存与磁盘一致。同一意图重试时
		# 市场命令 id 不变，不会二次成交；账本或关系文档在后续结算里补记。
		farm.accept(outcome.candidate)
		shared_changed.emit()
		return {"ok": false, "reason": str(resident_saved.reason),
			"changed": true, "counts": outcome.counts,
			"failures": outcome.failures, "intents": outcome.intents,
			"social": outcome.social_actions,
			"invitations": outcome.invitation_actions}
	farm.accept(outcome.candidate)
	shared_changed.emit()
	return {"ok": true, "reason": "", "changed": true,
		"counts": outcome.counts, "failures": outcome.failures,
		"intents": outcome.intents, "social": outcome.social_actions,
		"invitations": outcome.invitation_actions}


## 保存居民账本与社交/记忆 sidecar（农场已经落盘）。每个文档都是一次原子替换；
## 账本成功后立即更新内存账本，避免下一次结算用旧账本规划而重复成交。社交文档
## 保存失败时保留旧的活文档，不把未落盘的关系当成事实。
func _save_resident_documents(outcome: Dictionary, at_utc_seconds: float) -> Dictionary:
	if bool(outcome.get("ledger_changed", false)):
		var ledger_saved: Dictionary = residents_store.save_state(outcome.document)
		if not ledger_saved.ok:
			return {"ok": false,
				"reason": "save_residents_" + str(ledger_saved.kind)}
		residents = outcome.document
	if bool(outcome.get("social_changed", false)) \
			or bool(outcome.get("invitation_changed", false)) \
			or bool(outcome.get("memory_changed", false)):
		var state_saved: Dictionary = residents_state_store.save_state({
			"social": outcome.social, "memories": outcome.memories,
			"invitations": outcome.invitations,
			"dialogues": outcome.get("dialogues", resident_dialogues),
		}, at_utc_seconds)
		if not state_saved.ok:
			return {"ok": false,
				"reason": "save_resident_state_" + str(state_saved.kind)}
		resident_social = outcome.social
		resident_memories = outcome.memories
		resident_invitations = outcome.invitations
		if outcome.has("dialogues"):
			resident_dialogues = outcome.dialogues
	return {"ok": true, "reason": ""}


## 把一条已提交命令投影成居民记忆。调用点已经在农场落盘之后，因此这里的任何
## 失败都只是 `memory` 字段里的结果，不会回滚命令。只有确实新增了记忆行才写
## residents.json；纯旁观重复、未映射命令或空名册都不重写 sidecar。
func _remember_committed_command(command: Dictionary, actor: String) -> Dictionary:
	var projection: Dictionary = _memory_projection(command, actor)
	if projection.is_empty():
		return {"ok": true, "written": 0, "duplicates": 0,
			"skipped": "unmapped_kind", "reason": "", "source_event_id": ""}
	var event_id: String = str(projection.id)
	# 名册只决定谁收到记忆和显示名，不复制任何农场或经济事实。
	var built: Dictionary = NpcRoster.build(world_id, nature.get_seed())
	if not bool(built.get("ok", false)):
		return {"ok": false, "written": 0, "duplicates": 0, "skipped": "",
			"reason": "roster_" + str(built.get("reason", "")),
			"source_event_id": event_id}
	var event_at: float = _memory_event_time(command, resident_memories)
	var candidate: Dictionary = resident_memories.duplicate(true)
	var applied: Dictionary = NpcMemoryFeed.apply(candidate, projection, {
		"now_utc": event_at, "world_id": world_id, "roster": built.roster,
	})
	if not bool(applied.get("ok", false)):
		return {"ok": false, "written": 0, "duplicates": 0, "skipped": "",
			"reason": str(applied.get("reason", "")),
			"source_event_id": event_id}
	var written: int = int(applied.get("written", 0))
	if written > 0:
		var saved: Dictionary = _save_resident_documents({
			"social": resident_social, "memories": candidate,
			"invitations": resident_invitations,
			"dialogues": resident_dialogues, "memory_changed": true,
		}, event_at)
		if not bool(saved.get("ok", false)):
			return {"ok": false, "written": 0, "duplicates": 0, "skipped": "",
				"reason": str(saved.get("reason", "")),
				"source_event_id": event_id}
	return {"ok": true, "written": written,
		"duplicates": int(applied.get("duplicates", 0)),
		"skipped": str(applied.get("skipped", "")), "reason": "",
		"source_event_id": str(applied.get("event_id", event_id))}


## 记忆行不允许晚于保存时刻，而居民结算可能已经把行写到命令时刻之后（玩家时钟
## 也允许小幅落后）。新行时刻取「命令时刻」与「现有最新记忆时刻」的较大者：
## 正常路径仍是命令时刻，只在已存在更晚事实时跟着前进，不引入系统时钟。
static func _memory_event_time(command: Dictionary, memories: Dictionary) -> float:
	var at: float = float(command.get("at_utc", 0.0))
	var npcs_value: Variant = memories.get("npcs")
	if not npcs_value is Dictionary:
		return at
	for npc_value: Variant in (npcs_value as Dictionary).values():
		if not npc_value is Dictionary:
			continue
		var entries_value: Variant = (npc_value as Dictionary).get("entries")
		if not entries_value is Dictionary:
			continue
		for entry_value: Variant in (entries_value as Dictionary).values():
			if not entry_value is Dictionary:
				continue
			var entry_at: float = float((entry_value as Dictionary).get("at_utc", 0.0))
			if entry_at > at:
				at = entry_at
	return at


## 已提交命令到记忆事件的最小映射。`target` 只取命令自身的真实字段：农事用地
## 块定位，赠礼用收礼人，建造用宅基槽位。`set_theft` 只是开关，不是一次偷取；
## 地籍没有独立命令，首次建造的占地由 build 事件代表，不另造同 id 事件。
func _memory_projection(command: Dictionary, actor: String) -> Dictionary:
	var memory_kind: String = ""
	var target: String = ""
	match str(command.get("kind", "")):
		FarmCommand.HARVEST:
			memory_kind = NpcMemoryFeed.KIND_HARVEST
			target = str(command.get("field_id", ""))
		FarmCommand.SOW:
			memory_kind = NpcMemoryFeed.KIND_SOW
			target = str(command.get("field_id", ""))
		FarmCommand.WATER:
			memory_kind = NpcMemoryFeed.KIND_WATER
			target = str(command.get("field_id", ""))
		FarmCommand.GIFT:
			memory_kind = NpcMemoryFeed.KIND_GIFT
			target = str(command.get("to_id", ""))
		FarmCommand.BUILD:
			memory_kind = NpcMemoryFeed.KIND_BUILD
			target = str(command.get("slot_id", ""))
		_:
			return {}
	return {
		"kind": memory_kind, "id": str(command.get("id", "")),
		"actor": actor, "target": target, "ok": true,
	}


## 在候选农场、账本候选与社交/记忆候选上完成三名居民的规划与成交，不写盘、
## 不改活状态。返回 {ok, reason, changed, ledger_changed, social_changed,
## candidate, document, social, memories, counts, failures, intents,
## social_actions}。每次购买都在 `candidate.copy()` 上提交，只有下单与撮合都
## 成功才替换工作候选并记录账本；社交动作只有在关系与记忆候选都成功后才被接受。
func _apply_residents(candidate: RefCounted, at_utc_seconds: float) -> Dictionary:
	var counts: Dictionary = {"opened": 0, "purchased": 0, "failed": 0,
		"socialized": 0}
	var failures: Array = []
	var intents: Array = []
	var social_actions: Array = []
	var working: RefCounted = candidate
	var ledger: Dictionary = residents
	var social: Dictionary = resident_social
	var memories: Dictionary = resident_memories
	var invitations: Dictionary = resident_invitations
	var changed: bool = false
	var ledger_changed: bool = false
	var social_changed: bool = false
	var invitation_changed: bool = false
	var invitation_actions: Array = []
	for npc_id: String in NpcRoster.IDS:
		# 固定 id 让重复开户幂等：已开通（或已领赠款）视为可继续，不必区分本次
		# 是否新开户。其他失败只影响这名居民。
		var accounts: Variant = working.economy_snapshot().get("accounts")
		var has_account: bool = accounts is Dictionary \
			and (accounts as Dictionary).has(npc_id)
		if not has_account:
			var opened: Dictionary = working.economy_open_account(
				"npc-open-" + npc_id, npc_id, at_utc_seconds)
			if not bool(opened.get("ok", false)) \
					and str(opened.get("reason", "")) != "already_granted":
				failures.append({"resident": npc_id,
					"reason": "open_" + str(opened.get("reason", ""))})
				counts.failed = int(counts.failed) + 1
				continue
			if bool(opened.get("ok", false)):
				changed = true
				counts.opened = int(counts.opened) + 1
		# 只把公开、仍有余量的卖单投影给规则；买单与关闭行不进入候选。
		var offers: Array = []
		for row: Variant in working.market_orders():
			if not row is Dictionary:
				continue
			var order: Dictionary = row
			if str(order.get("side", "")) != Market.SIDE_SELL \
					or str(order.get("status", "")) != Market.STATUS_OPEN:
				continue
			var remaining: int = int(order.get("remaining", 0))
			var price: int = int(order.get("price", 0))
			if remaining <= 0 or price <= 0:
				continue
			offers.append({
				"good": str(order.get("good", "")),
				"price": price,
				"remaining": remaining,
			})
		var resident_state: Dictionary = NpcResidentLedger.state_for(ledger, npc_id)
		if resident_state.is_empty():
			resident_state = {"until_utc": 0.0, "intents": {}}
		var context: Dictionary = {
			"resident": {
				"id": npc_id,
				"cash": working.economy_cash(npc_id),
				"bag": working.economy_goods(npc_id),
			},
			"market": {"orders": offers},
			"cooldowns": resident_state,
		}
		var planned: Dictionary = NpcIntent.plan(context, at_utc_seconds)
		if not bool(planned.get("ok", false)):
			failures.append({"resident": npc_id,
				"reason": str(planned.get("reason", ""))})
			counts.failed = int(counts.failed) + 1
			continue
		var intent: Dictionary = planned.intent
		# 执行前用同一上下文重新校验，过期、重复与预算都在这里拦住。
		var checked: Dictionary = NpcIntent.validate(intent, context, at_utc_seconds)
		if not bool(checked.get("ok", false)):
			failures.append({"resident": npc_id,
				"reason": str(checked.get("reason", ""))})
			counts.failed = int(counts.failed) + 1
			continue
		# 单居民子候选：下单失败或撮合失败时整笔丢弃，不污染其他居民的成交。
		var purchase: RefCounted = working.copy()
		var placed: Dictionary = purchase.market_place_order(str(intent.id), npc_id,
			Market.SIDE_BUY, str(intent.good), int(intent.price), int(intent.quantity),
			float(intent.expires_utc), at_utc_seconds)
		if not bool(placed.get("ok", false)):
			failures.append({"resident": npc_id,
				"reason": "place_" + str(placed.get("reason", ""))})
			counts.failed = int(counts.failed) + 1
			continue
		var matched: Dictionary = purchase.market_match(at_utc_seconds)
		if not bool(matched.get("ok", false)):
			failures.append({"resident": npc_id,
				"reason": "match_" + str(matched.get("reason", ""))})
			counts.failed = int(counts.failed) + 1
			continue
		var recorded: Dictionary = NpcResidentLedger.record(ledger, npc_id,
			str(intent.id), at_utc_seconds,
			at_utc_seconds + RESIDENT_COOLDOWN_SECONDS)
		if not bool(recorded.get("ok", false)):
			failures.append({"resident": npc_id,
				"reason": "record_" + str(recorded.get("reason", ""))})
			counts.failed = int(counts.failed) + 1
			continue
		working = purchase
		ledger = recorded.document
		changed = true
		ledger_changed = true
		counts.purchased = int(counts.purchased) + 1
		intents.append({
			"resident": npc_id, "intent": str(intent.id), "good": str(intent.good),
			"quantity": int(intent.quantity), "price": int(intent.price),
			"matched": int(matched.get("count", 0)),
		})
	# 邀约裁决阶段：先处理上一轮留下的 pending 邀约（到期转 expired，其余由被
	# 邀请方按关系与人格确定性接受/拒绝），再进入本轮社交规划。因此本轮新建的
	# 邀约最早在下一次结算被裁决。裁决只改邀约状态并写当事人有界记忆，不移动
	# 现金、货物、账户、权属，也不改关系文档。
	var invitations_settled: Dictionary = _settle_invitations(
		invitations, memories, social, at_utc_seconds)
	if bool(invitations_settled.changed):
		invitations = invitations_settled.invitations
		memories = invitations_settled.memories
		invitation_changed = true
		changed = true
		invitation_actions.append_array(invitations_settled.actions)
	# 淘汰窗口外的终态行，给本轮新邀约让出容量。裁决刚写入的行仍在窗口内，
	# 本轮的 `last_invitation` 不会因为这次回收而消失。
	var invitations_pruned: Dictionary = _prune_invitations(
		invitations, at_utc_seconds)
	if int(invitations_pruned.removed) > 0:
		invitations = invitations_pruned.invitations
		invitation_changed = true
		changed = true
	# 社交阶段：经济成交之后，对每名居民从真实关系文档投影上下文。同一时刻已经
	# 记录过动作的居民整名跳过；滚动 24 小时的动作/赠礼上限在这里执行。每轮只
	# 接受关系候选与本人记忆候选都成功的动作，赠礼只写关系与记忆，不移动任何
	# 现金、货物、账户或权属。
	for npc_id: String in NpcRoster.IDS:
		if _social_happened_at(social, npc_id, at_utc_seconds):
			continue
		var profile: Dictionary = NpcPersonality.traits(npc_id, nature.get_seed())
		if not bool(profile.get("ok", false)):
			continue
		var attempts: int = 0
		while attempts < RESIDENT_SOCIAL_DAILY_CAP:
			var since_utc: float = at_utc_seconds - RESIDENT_SOCIAL_WINDOW_SECONDS
			# 邀约创建同样计入每日社交上限，避免一天内反复发出邀约。
			if _social_actions_since(social, npc_id, since_utc) \
					+ _invitations_since(invitations, npc_id, since_utc) \
					>= RESIDENT_SOCIAL_DAILY_CAP:
				break
			var gifts_used: int = _social_gifts_since(social, npc_id, since_utc)
			var gift_remaining: int = maxi(0,
				RESIDENT_GIFT_DAILY_CAP - gifts_used)
			var context: Dictionary = _social_context_for(social, npc_id,
				profile.traits, gift_remaining)
			var planned: Dictionary = NpcSocial.plan(context, at_utc_seconds)
			if not bool(planned.get("ok", false)):
				break
			var act: Dictionary = planned.act
			# 规则选中 `invite` 时不立即写关系，而是用 NpcInvitation 的既有规则
			# 创建 pending；同一 act id（command_id）重放只会得到 duplicate。
			if str(act.kind) == NpcSocial.KIND_INVITE:
				var invited: Dictionary = _create_invitation(
					invitations, act, at_utc_seconds)
				if bool(invited.get("created", false)):
					invitations = invited.invitations
					invitation_changed = true
					changed = true
					invitation_actions.append({
						"resident": npc_id, "act": str(act.id),
						"invitation": str(invited.invitation_id),
						"to": str(act.to),
					})
				break
			var checked: Dictionary = NpcSocial.validate(
				act, context, at_utc_seconds)
			if not bool(checked.get("ok", false)):
				break
			var applied: Dictionary = NpcSocial.apply(act, social, at_utc_seconds)
			if not bool(applied.get("ok", false)):
				break
			var written: Dictionary = NpcSocialMemory.apply(memories, {
				"ok": true, "act": act.duplicate(true),
			}, {
				"now_utc": at_utc_seconds, "world_id": world_id,
				"resident_id": npc_id,
				"names": NpcRoster.DISPLAY_NAMES.duplicate(true),
			})
			if not bool(written.get("ok", false)) \
					or not bool(written.get("written", false)):
				break
			social = applied.document
			memories = written.memory
			social_changed = true
			changed = true
			counts.socialized = int(counts.socialized) + 1
			social_actions.append({
				"resident": npc_id, "act": str(act.id),
				"kind": str(act.kind), "to": str(act.to),
			})
			attempts += 1
	return {
		"ok": true, "reason": "", "changed": changed,
		"ledger_changed": ledger_changed, "social_changed": social_changed,
		"invitation_changed": invitation_changed,
		"candidate": working, "document": ledger, "social": social,
		"memories": memories, "invitations": invitations,
		"counts": counts, "failures": failures, "intents": intents,
		"social_actions": social_actions,
		"invitation_actions": invitation_actions,
	}


## 同一权威时刻是否已经有该居民的动作。重复扫描与重启后同一时刻的重放都因此
## 不产生第二个动作；不同动作种类也不会在同一时刻各执行一次。
func _social_happened_at(social: Dictionary, npc_id: String,
		at_utc_seconds: float) -> bool:
	var peers: Variant = (social.get("relations", {}) as Dictionary).get(npc_id)
	if not peers is Dictionary:
		return false
	var peer_map: Dictionary = peers
	for peer: Variant in peer_map:
		var row: Variant = peer_map[peer]
		if not row is Dictionary:
			continue
		var acts: Variant = (row as Dictionary).get("acts", {})
		if not acts is Dictionary:
			continue
		var act_map: Dictionary = acts
		for act_id: Variant in act_map:
			if float(act_map[act_id]) == at_utc_seconds:
				return true
	return false


## 滚动窗口内该居民已执行的动作数，用于调用方每日上限。
func _social_actions_since(social: Dictionary, npc_id: String,
		since_utc: float) -> int:
	var total: int = 0
	var peers: Variant = (social.get("relations", {}) as Dictionary).get(npc_id)
	if not peers is Dictionary:
		return 0
	var peer_map: Dictionary = peers
	for peer: Variant in peer_map:
		var row: Variant = peer_map[peer]
		if not row is Dictionary:
			continue
		var acts: Variant = (row as Dictionary).get("acts", {})
		if not acts is Dictionary:
			continue
		var act_map: Dictionary = acts
		for act_id: Variant in act_map:
			if float(act_map[act_id]) > since_utc:
				total += 1
	return total


## 滚动窗口内该居民已赠礼次数，用于每日赠礼预算。
func _social_gifts_since(social: Dictionary, npc_id: String,
		since_utc: float) -> int:
	var total: int = 0
	var peers: Variant = (social.get("relations", {}) as Dictionary).get(npc_id)
	if not peers is Dictionary:
		return 0
	var peer_map: Dictionary = peers
	for peer: Variant in peer_map:
		var row: Variant = peer_map[peer]
		if not row is Dictionary:
			continue
		var gifts: Variant = (row as Dictionary).get("gifts_utc", [])
		if not gifts is Array:
			continue
		var gift_times: Array = gifts
		for gift_utc: Variant in gift_times:
			if float(gift_utc) > since_utc:
				total += 1
	return total


## 从真实关系文档投影一位居民的只读社交上下文。每对关系达到动作上限的对象不再
## 进入选择；已消费 act id 全部进入冷却投影，防止跨重启重放。
func _social_context_for(social: Dictionary, npc_id: String, traits: Dictionary,
		gift_remaining: int) -> Dictionary:
	var relations: Dictionary = {}
	var applied: Dictionary = {}
	var peers_value: Variant = (social.get("relations", {}) as Dictionary).get(npc_id)
	if peers_value is Dictionary:
		var peers: Dictionary = peers_value
		for peer: Variant in peers:
			# 只把名册居民投影为自发社交对象。玩家与居民的对话关系也写在
			# 同一份关系文档里（玩家 id 是合法 owner id），但居民不会因为一次
			# 对话就反过来自主拜访玩家，因此这里过滤掉非名册对象。
			if not NpcRoster.IDS.has(str(peer)):
				continue
			var row: Variant = peers[peer]
			if not row is Dictionary:
				continue
			var acts: Variant = (row as Dictionary).get("acts", {})
			if not acts is Dictionary:
				continue
			for act_id: Variant in acts:
				applied[act_id] = float((acts as Dictionary)[act_id])
			if (acts as Dictionary).size() >= NpcSocial.MAX_ACTS_PER_PEER:
				continue
			relations[peer] = {
				"affinity": int((row as Dictionary).affinity),
				"last_utc": float((row as Dictionary).last_utc),
				"gifts": ((row as Dictionary).get("gifts_utc", []) as Array).size(),
				"acts": (acts as Dictionary).size(),
			}
	var action_times: Dictionary = {}
	var actions_value: Variant = (social.get("actions", {}) as Dictionary).get(npc_id)
	if actions_value is Dictionary:
		action_times = (actions_value as Dictionary).duplicate(true)
	return {
		"resident": {
			"id": npc_id, "traits": traits.duplicate(true),
			"relations": relations,
		},
		"cooldowns": {"actions": action_times, "acts": applied},
		"limits": {"gift_remaining": gift_remaining},
	}


## 处理 pending 邀约：先把到期的转 expired（不写记忆），再按 id 升序让被邀请方
## 依据对发起人的 affinity 与本人 warm/suspicion 人格确定性接受或拒绝。本轮刚
## 创建（`created_utc == now_utc`）的邀约留到下一次结算，同一时刻重放不会立刻
## 裁决。每次决策先把确定性事件投影到双方有界记忆，只有两个候选都成功才接受
## 邀约状态。返回候选邀约表与记忆；不修改输入，也不移动任何资产或权属。
func _settle_invitations(invitations: Dictionary, memories: Dictionary,
		social: Dictionary, now_utc: float) -> Dictionary:
	var table: Dictionary = invitations
	var actions: Array = []
	var changed: bool = false
	var expiry: Dictionary = NpcInvitation.expire(
		_invitation_rules_document(table), now_utc)
	if bool(expiry.get("ok", false)) and int(expiry.get("expired", 0)) > 0:
		table = _merge_invitation_rows(table, expiry.document)
		changed = true
	var ids: Array[String] = []
	for id_value: Variant in table:
		var row_value: Variant = table[id_value]
		if row_value is Dictionary \
				and str((row_value as Dictionary).get("status", "")) \
					== NpcInvitation.STATUS_PENDING \
				and float((row_value as Dictionary).get("created_utc", 0.0)) \
					< float(now_utc):
			ids.append(str(id_value))
	ids.sort()
	for invitation_id: String in ids:
		if not table.has(invitation_id):
			continue
		var row: Dictionary = table[invitation_id]
		if str(row.get("status", "")) != NpcInvitation.STATUS_PENDING:
			continue
		var document: Dictionary = _invitation_rules_document(table)
		var status: String = NpcInvitation.STATUS_DECLINED
		var decided: Dictionary = NpcInvitation.decline(
			document, invitation_id, str(row.to), now_utc)
		if _invitation_accepts(social, row):
			status = NpcInvitation.STATUS_ACCEPTED
			decided = NpcInvitation.accept(
				document, invitation_id, str(row.to), now_utc)
		if not bool(decided.get("ok", false)):
			continue
		var event: Dictionary = {
			"ok": true,
			"invitation": {
				"id": invitation_id, "from": str(row.from), "to": str(row.to),
				"kind": str(row.kind), "status": status,
				"decided_utc": now_utc,
			},
		}
		# 适配层只为该状态对应的当事人写一行；依次尝试双方，任一失败则不提交。
		var initiator: Dictionary = NpcSocialMemory.apply(memories, {
			"ok": true, "invitation": (event.invitation as Dictionary).duplicate(true),
		}, _invitation_memory_context(str(row.from), now_utc))
		if not bool(initiator.get("ok", false)):
			continue
		var recipient: Dictionary = NpcSocialMemory.apply(initiator.memory, {
			"ok": true, "invitation": (event.invitation as Dictionary).duplicate(true),
		}, _invitation_memory_context(str(row.to), now_utc))
		if not bool(recipient.get("ok", false)):
			continue
		table = _merge_invitation_rows(table, decided.document)
		memories = recipient.memory
		changed = true
		actions.append({
			"invitation": invitation_id, "from": str(row.from),
			"to": str(row.to), "kind": str(row.kind), "status": status,
		})
	return {
		"ok": true, "invitations": table, "memories": memories,
		"changed": changed, "actions": actions,
	}


## 淘汰窗口外的已决邀约行。表上限按行数计，若只标记 expired 不回收，约 22 个
## 逻辑日后终态行填满 64 行，居民会永久停止发起新邀约（M13 驻留切片观察到）。
## pending 永不淘汰；本轮刚裁决的行 `decided_utc == now_utc` 仍在窗口内。
## 权威表每行多一个 `command_id`，必须先投影成纯规则文档再合并回持久化行。
func _prune_invitations(invitations: Dictionary, now_utc: float) -> Dictionary:
	var pruned: Dictionary = NpcInvitation.prune(
		_invitation_rules_document(invitations), now_utc,
		NpcInvitation.DEFAULT_RETAIN_SECONDS)
	if not bool(pruned.get("ok", false)):
		return {"ok": true, "invitations": invitations, "removed": 0}
	var removed: Array = pruned.get("removed", [])
	if removed.is_empty():
		return {"ok": true, "invitations": invitations, "removed": 0}
	var merged: Dictionary = _merge_invitation_rows(invitations, pruned.document)
	return {"ok": true, "invitations": merged, "removed": removed.size()}


## 确定性接受规则：被邀请方对发起人的 affinity + 本人温和 - 多疑，达到阈值即
## 接受。没有 RNG、模型或自由文本；同一关系与人格总是同一结果。
func _invitation_accepts(social: Dictionary, row: Dictionary) -> bool:
	var to_id: String = str(row.to)
	var from_id: String = str(row.from)
	var affinity: int = 0
	var peers_value: Variant = (social.get("relations", {}) as Dictionary).get(to_id)
	if peers_value is Dictionary:
		var peer_value: Variant = (peers_value as Dictionary).get(from_id)
		if peer_value is Dictionary:
			affinity = int((peer_value as Dictionary).get("affinity", 0))
	var warmth: int = 50
	var suspicion: int = 50
	if nature != null:
		var profile: Dictionary = NpcPersonality.traits(to_id, nature.get_seed())
		if bool(profile.get("ok", false)):
			var traits: Dictionary = profile.traits
			warmth = int(traits.get("warmth", 50))
			suspicion = int(traits.get("suspicion", 50))
	return affinity + warmth - suspicion >= INVITATION_ACCEPT_SCORE


## 用 `NpcInvitation.propose` 创建 pending。同一 act id（command_id）已存在时
## 返回 duplicate 且不改表；已存在同对象同类 pending、派生 id 冲突或达到 64 条
## 容量时都不创建。成功时把 act id 记入行内，供跨重启重放判重。
func _create_invitation(invitations: Dictionary, act: Dictionary,
		now_utc: float) -> Dictionary:
	var act_id: String = str(act.get("id", ""))
	for row_value: Variant in invitations.values():
		if row_value is Dictionary \
				and str((row_value as Dictionary).get("command_id", "")) == act_id:
			return {"ok": true, "created": false, "reason": "duplicate",
				"invitations": invitations,
				"invitation_id": str((row_value as Dictionary).get("id", ""))}
	if invitations.size() >= ResidentsStore.MAX_INVITATIONS:
		return {"ok": false, "created": false, "reason": "over_capacity",
			"invitations": invitations}
	var proposed: Dictionary = NpcInvitation.propose(
		_invitation_rules_document(invitations),
		{"from": str(act.from), "to": str(act.to),
			"kind": RESIDENT_INVITATION_KIND},
		now_utc)
	if not bool(proposed.get("ok", false)):
		return {"ok": false, "created": false,
			"reason": str(proposed.get("reason", "")), "invitations": invitations}
	var candidate: Dictionary = _merge_invitation_rows(
		invitations, proposed.document, act_id)
	if not ResidentsStore.valid_invitations(candidate):
		return {"ok": false, "created": false, "reason": "invalid_state",
			"invitations": invitations}
	var invitation: Dictionary = proposed.invitation
	return {"ok": true, "created": true, "reason": "",
		"invitations": candidate, "invitation_id": str(invitation.id)}


## `NpcInvitation` 文档视图：去掉持久化专用的 `command_id`，其余保持严格形状。
func _invitation_rules_document(invitations: Dictionary) -> Dictionary:
	var rows: Dictionary = {}
	for id_value: Variant in invitations:
		var row_value: Variant = invitations[id_value]
		if not row_value is Dictionary:
			continue
		var row: Dictionary = (row_value as Dictionary).duplicate(true)
		row.erase("command_id")
		rows[id_value] = row
	return {"invitations": rows}


## 把规则模块返回的候选文档合并回持久化表，保留每行原有的 command_id；新行
## 使用 `new_command`。行集合不变，所以不会因合并丢失已决策的邀约。
func _merge_invitation_rows(invitations: Dictionary, document: Variant,
		new_command: String = "") -> Dictionary:
	var merged: Dictionary = {}
	var source: Variant = (document as Dictionary).get("invitations", {})
	if not source is Dictionary:
		return merged
	for id_value: Variant in source:
		var row_value: Variant = source[id_value]
		if not row_value is Dictionary:
			continue
		var row: Dictionary = (row_value as Dictionary).duplicate(true)
		if invitations.has(id_value) and invitations[id_value] is Dictionary \
				and (invitations[id_value] as Dictionary).has("command_id"):
			row["command_id"] = str(
				(invitations[id_value] as Dictionary).command_id)
		elif not new_command.is_empty():
			row["command_id"] = new_command
		else:
			continue
		merged[str(id_value)] = row
	return merged


func _invitation_memory_context(resident_id: String, now_utc: float) -> Dictionary:
	return {
		"now_utc": now_utc, "world_id": world_id, "resident_id": resident_id,
		"names": NpcRoster.DISPLAY_NAMES.duplicate(true),
	}


## 滚动窗口内该居民创建过的邀约数，与社交动作一起受每日上限约束。
func _invitations_since(invitations: Dictionary, npc_id: String,
		since_utc: float) -> int:
	var total: int = 0
	for row_value: Variant in invitations.values():
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		if str(row.get("from", "")) == npc_id \
				and float(row.get("created_utc", 0.0)) > since_utc:
			total += 1
	return total


## 一名居民参与的 pending 邀约计数与最近一条邀约的公开投影；视图只含双方、
## 状态与创建时刻，不含 command_id、reason 或任何自由文本。
func _resident_invitation_summary(npc_id: String) -> Dictionary:
	var pending: int = 0
	var last: Dictionary = {}
	var last_created: float = -1.0
	var last_id: String = ""
	for id_value: Variant in resident_invitations:
		var row_value: Variant = resident_invitations[id_value]
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		if str(row.get("from", "")) != npc_id and str(row.get("to", "")) != npc_id:
			continue
		if str(row.get("status", "")) == NpcInvitation.STATUS_PENDING:
			pending += 1
		var created_utc: float = float(row.get("created_utc", 0.0))
		var invitation_id: String = str(id_value)
		if last.is_empty() or created_utc > last_created \
				or (created_utc == last_created and invitation_id < last_id):
			last = {
				"from": str(row.get("from", "")), "to": str(row.get("to", "")),
				"status": str(row.get("status", "")),
				"created_utc": created_utc,
			}
			last_created = created_utc
			last_id = invitation_id
	return {"pending": pending, "last": last}


## 居民只读视图。居民未启用时只返回 `disabled`，不暴露关系或记忆；启用后按
## `NpcRoster.IDS` 固定顺序投影公开事实。视图不含现金、账户、货物、权属或
## 对话正文：记忆只给条数与最近时刻，购买只给商品与时刻。
##
## 购买的商品不在意图账本里（账本只保存已消费意图 id 与时刻），因此从权威
## 农场里本人已成交的买单投影；订单被归档或没有成交时 `last_purchase` 为空，
## 不把未成交的挂单当成购买。
func residents_view(viewer: String = "") -> Dictionary:
	if not residents_enabled:
		return {"available": false, "reason": "disabled", "viewer": viewer,
			"residents": []}
	if farm == null:
		return {"available": false, "reason": "not_open", "viewer": viewer,
			"residents": []}
	var seed_value: int = nature.get_seed() if nature != null else 0
	var rows: Array = []
	for npc_id: String in NpcRoster.IDS:
		var traits: Dictionary = {}
		var profile: Dictionary = NpcPersonality.traits(npc_id, seed_value)
		if bool(profile.get("ok", false)):
			traits = (profile.traits as Dictionary).duplicate(true)
		var memory: Dictionary = _resident_memory_summary(npc_id)
		var invitation: Dictionary = _resident_invitation_summary(npc_id)
		rows.append({
			"id": npc_id,
			"display_name": str(NpcRoster.DISPLAY_NAMES.get(npc_id, "")),
			"role": NpcRoles.role_of(npc_id),
			"traits": traits,
			"relations": _resident_relations(npc_id),
			"memory_count": int(memory.count),
			"last_memory_utc": float(memory.last_utc),
			"intents_consumed": _resident_intent_count(npc_id),
			"last_purchase": _resident_last_purchase(npc_id),
			"pending_invitations": int(invitation.pending),
			"last_invitation": invitation.last,
		})
	return {"available": true, "reason": "", "viewer": viewer, "residents": rows}


## 两名邻居的只读关系行，按名册顺序排列；缺失关系行按初始的 0 值投影。
func _resident_relations(npc_id: String) -> Array:
	var relations: Dictionary = {}
	var stored: Variant = (resident_social.get("relations", {}) as Dictionary).get(npc_id)
	if stored is Dictionary:
		relations = stored
	var rows: Array = []
	for peer_id: String in NpcRoster.IDS:
		if peer_id == npc_id:
			continue
		var row: Dictionary = {}
		var value: Variant = relations.get(peer_id)
		if value is Dictionary:
			row = value
		var acts: Dictionary = {}
		var acts_value: Variant = row.get("acts", {})
		if acts_value is Dictionary:
			acts = acts_value
		var gifts: int = 0
		var gifts_value: Variant = row.get("gifts_utc", [])
		if gifts_value is Array:
			gifts = (gifts_value as Array).size()
		rows.append({
			"id": peer_id,
			"display_name": str(NpcRoster.DISPLAY_NAMES.get(peer_id, "")),
			"affinity": int(row.get("affinity", 0)),
			"last_utc": float(row.get("last_utc", 0.0)),
			"acts": acts.size(),
			"gifts": gifts,
		})
	return rows


func _resident_memory_summary(npc_id: String) -> Dictionary:
	var entries: Dictionary = {}
	var npcs_value: Variant = resident_memories.get("npcs", {})
	if npcs_value is Dictionary:
		var row_value: Variant = (npcs_value as Dictionary).get(npc_id, {})
		if row_value is Dictionary:
			var entries_value: Variant = (row_value as Dictionary).get("entries", {})
			if entries_value is Dictionary:
				entries = entries_value
	var latest: float = 0.0
	for entry: Variant in entries.values():
		if entry is Dictionary:
			latest = maxf(latest, float((entry as Dictionary).get("at_utc", 0.0)))
	return {"count": entries.size(), "last_utc": latest}


func _resident_intent_count(npc_id: String) -> int:
	var ledger: Dictionary = NpcResidentLedger.state_for(residents, npc_id)
	var value: Variant = ledger.get("intents", {})
	return (value as Dictionary).size() if value is Dictionary else 0


func _resident_last_purchase(npc_id: String) -> Dictionary:
	var chosen: Dictionary = {}
	var chosen_utc: float = -1.0
	for value: Variant in farm.market_orders():
		if not value is Dictionary:
			continue
		var order: Dictionary = value
		if str(order.get("owner", "")) != npc_id \
				or str(order.get("side", "")) != Market.SIDE_BUY \
				or int(order.get("filled", 0)) <= 0:
			continue
		var created_utc: float = float(order.get("created_utc", 0.0))
		if created_utc >= chosen_utc:
			chosen = order
			chosen_utc = created_utc
	if chosen.is_empty():
		return {}
	return {"good": str(chosen.get("good", "")), "at_utc": chosen_utc}


## 只读视图里每人最多回看这么多条本次会话的对话结果。结果只在内存里，重启后
## 视图从持久化的对话状态重新推导，不假装记得旧回复正文。
const DIALOGUE_RECENT_RESULTS: int = 8


## 玩家对居民的确定性对话只读视图。隐私分级：
## - 只对已加入世界的连接开放（由连接层传入 `is_member`）；未加入时只回
##   `available=false`，不暴露任何玩家行；
## - 即使已加入，也**只**投影查看者本人对名册居民的对话状态与最近的本人
##   对话结果；其他玩家的对话时刻、日累计与冷却永不出现。
## 冷却状态由权威时钟与规则模块的 `COOLDOWN_SECONDS` 推导，客户端不能用本地
## 时钟改写。`daily_affinity` 在 UTC 日切后惰性归零（不写盘，只影响投影）。
func dialogues_view(viewer: String = "", is_member: bool = false) -> Dictionary:
	if not is_member or viewer.is_empty():
		return {"available": false, "reason": "not_a_member", "viewer": viewer,
			"is_member": is_member, "now_utc": authority_now_utc(),
			"residents": [], "recent": []}
	if farm == null:
		return {"available": false, "reason": "not_open", "viewer": viewer,
			"is_member": is_member, "now_utc": authority_now_utc(),
			"residents": [], "recent": []}
	if not residents_enabled:
		return {"available": false, "reason": "disabled", "viewer": viewer,
			"is_member": is_member, "now_utc": authority_now_utc(),
			"residents": [], "recent": []}
	var now: float = authority_now_utc()
	var day: int = _dialogue_day(now)
	var rows: Array = []
	for npc_id: String in NpcRoster.IDS:
		var state: Dictionary = _dialogue_state_for(viewer, npc_id)
		var last_utc: float = float(state.get("last_dialogue_utc", 0.0))
		var cooldown_remaining: float = 0.0
		if last_utc > 0.0:
			cooldown_remaining = maxf(0.0,
				last_utc + NpcDialogue.COOLDOWN_SECONDS - now)
		rows.append({
			"id": npc_id,
			"display_name": str(NpcRoster.DISPLAY_NAMES.get(npc_id, "")),
			"affinity": _dialogue_affinity(npc_id, viewer),
			"last_dialogue_utc": last_utc,
			"daily_affinity": int(state.get("daily_affinity", 0)) \
				if int(state.get("day_utc", -1)) == day else 0,
			"daily_limit": NpcDialogue.MAX_DAILY_AFFINITY,
			"cooldown_seconds": NpcDialogue.COOLDOWN_SECONDS,
			"cooldown_remaining": cooldown_remaining,
			"ready": cooldown_remaining <= 0.0,
		})
	return {
		"available": true, "reason": "", "viewer": viewer,
		"is_member": is_member, "now_utc": now, "residents": rows,
		"recent": _dialogue_recent(viewer),
	}


## 最近的本人对话结果。结果窗口只在内存里，并只返回查看者自己的行。
func _dialogue_recent(viewer: String) -> Array:
	var rows: Array = []
	for key: Variant in _dialogue_results.keys():
		var entry: Dictionary = _dialogue_results[key]
		var result_value: Variant = entry.get("result")
		if not result_value is Dictionary:
			continue
		var result: Dictionary = result_value
		if str(result.get("viewer", "")) != viewer:
			continue
		rows.append({
			"command_id": str(key), "npc_id": str(result.get("npc_id", "")),
			"category": str(result.get("category", "")),
			"reply_kind": str(result.get("reply_kind", "")),
			"tone": str(result.get("tone", "")),
			"affinity_delta": int(result.get("affinity_delta", 0)),
			"at_utc": float(result.get("at_utc", 0.0)),
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a.at_utc) != float(b.at_utc):
			return float(a.at_utc) > float(b.at_utc)
		return str(a.command_id) < str(b.command_id))
	if rows.size() > DIALOGUE_RECENT_RESULTS:
		rows = rows.slice(0, DIALOGUE_RECENT_RESULTS)
	return rows


## 通过权威时钟执行一次玩家对居民的对话。所有世界事实都由权威投影：
## `visible` 里的行情来自最近一笔真实公开成交，农事记录来自真实已种植地块；
## 关系来自持久化的 `residents` 社交文档；时间取 `authority_now_utc()`；日切
## 按 UTC 日惰性归零。客户端传入的事实、时间、关系或日累计一律不参与计算。
##
## 成功时关系增量、对话记忆与对话状态在同一份 `residents.json` 候选里计算，
## 并且只经过一次原子保存；保存失败不修改任何活文档。同一 command id 在本会话
## 内重放返回首次回复（换参数返回 `command_conflict`），不二次写关系、记忆或
## 计数。跨重启的重放窗口不写进信封：首次成功后 `last_dialogue_utc` 会让仍在
## 冷却内的重试得到 `cooldown`，而记忆 id 由 command id 派生，若确有跨重启的
## 同 id 请求，重复记忆会被拒绝而不是二次增长关系。
##
## `is_member` 只为与 `execute_resolution` 保持同一入口形状：写入权限、只读状态
## 与角色门由 `WorldHost` 在调用本函数前判定，只读投影走 `dialogues_view()`。
func execute_dialogue(actor: String, npc_id: String, category: String,
		command_id: String, is_member: bool = false) -> Dictionary:
	if residents_state_store == null or farm == null:
		return _dialogue_result(false, "not_open", actor, npc_id, category)
	if not residents_enabled:
		# 没有启用居民的世界里名册不活动。对话只对已启用的权威开放，避免把
		# “居民不存在”显示成一段成功的独白。
		return _dialogue_result(false, "disabled", actor, npc_id, category)
	if not _valid_dispute_player(actor):
		return _dialogue_result(false, "invalid_player", actor, npc_id, category)
	if not NpcRoster.IDS.has(npc_id):
		return _dialogue_result(false, "invalid_npc", actor, npc_id, category)
	if not NpcDialogue.valid_category(category):
		return _dialogue_result(false, "invalid_category", actor, npc_id, category)
	if not _valid_resolution_command_id(command_id):
		return _dialogue_result(false, "invalid_command", actor, npc_id, category)
	var payload: String = JSON.stringify([actor, npc_id, category])
	var replayed: Dictionary = _replay_dialogue(command_id, payload)
	if not replayed.is_empty():
		return replayed
	var now: float = authority_now_utc()
	var seed_value: int = nature.get_seed() if nature != null else 0
	var profile: Dictionary = NpcPersonality.traits(npc_id, seed_value)
	if not bool(profile.get("ok", false)):
		return _dialogue_result(false, "invalid_traits", actor, npc_id, category)
	var relation: Dictionary = _dialogue_relation(npc_id, actor)
	var stored_state: Dictionary = _dialogue_state_for(actor, npc_id)
	var speech: Dictionary = {
		"category": category,
		"last_dialogue_utc": float(stored_state.get("last_dialogue_utc", 0.0)),
		"daily_affinity": _dialogue_daily(actor, npc_id, now),
		"visible": _dialogue_visible(),
	}
	var replied: Dictionary = NpcDialogue.respond_with_traits(
		profile.traits, relation, speech, now)
	if not bool(replied.get("ok", false)):
		return _dialogue_result(false, str(replied.get("reason", "")),
			actor, npc_id, category, str(replied.get("cooldown_reason", "")))
	# 记忆 id 由 command id 派生。若它已经在文档里，说明这次请求在别处（例如
	# 重启前的会话）已经落地，绝不能二次增长关系。
	var memory_id: String = _dialogue_memory_id(command_id, npc_id, actor)
	if _resident_memory_has(memory_id):
		var duplicate: Dictionary = _dialogue_result(true, "", actor, npc_id, category)
		duplicate["duplicate"] = true
		duplicate["reason"] = "duplicate"
		duplicate["reason_text"] = _dialogue_reason_text("duplicate")
		return duplicate
	var social_candidate: Dictionary = resident_social.duplicate(true)
	var memories_candidate: Dictionary = resident_memories.duplicate(true)
	var dialogues_candidate: Dictionary = resident_dialogues.duplicate(true)
	var delta: int = int(replied.affinity_delta)
	var relation_written: Dictionary = _dialogue_write_relation(
		social_candidate, npc_id, actor, delta, now)
	if not bool(relation_written.get("ok", false)):
		return _dialogue_result(false, str(relation_written.get("reason", "")),
			actor, npc_id, category)
	if not _dialogue_write_state(dialogues_candidate, actor, npc_id, now,
			int(replied.daily_affinity_after)):
		return _dialogue_result(false, "invalid_state", actor, npc_id, category)
	var remembered: Dictionary = NpcMemory.remember(memories_candidate, npc_id, {
		"id": _dialogue_memory_id(command_id, npc_id, actor),
		"kind": str(replied.memory_kind),
		"participants": [actor],
		"summary": str(replied.memory_summary),
		"salience": _dialogue_salience(category),
		"at_utc": now,
		"world_id": world_id,
		"state_version": 0,
	}, now)
	if not bool(remembered.get("ok", false)):
		return _dialogue_result(false, "invalid_memory", actor, npc_id, category)
	if not NpcSocial.valid(social_candidate) \
			or not NpcMemory.valid_document(memories_candidate, now) \
			or not ResidentsStore.valid_dialogues(dialogues_candidate):
		return _dialogue_result(false, "invalid_state", actor, npc_id, category)
	var saved: Dictionary = residents_state_store.save_state({
		"social": social_candidate, "memories": memories_candidate,
		"invitations": resident_invitations,
		"dialogues": dialogues_candidate,
	}, now)
	if not saved.ok:
		return _dialogue_result(false,
			"save_resident_state_" + str(saved.kind), actor, npc_id, category)
	resident_social = social_candidate
	resident_memories = memories_candidate
	resident_dialogues = dialogues_candidate
	var result: Dictionary = _dialogue_result(true, "", actor, npc_id, category)
	result["reply_kind"] = str(replied.get("reply_kind", ""))
	result["tone"] = str(replied.get("tone", ""))
	result["affinity_delta"] = delta
	result["affinity_after"] = int(replied.get("affinity_after", 0))
	result["daily_affinity_after"] = int(replied.get("daily_affinity_after", 0))
	result["capped_reason"] = str(replied.get("capped_reason", ""))
	result["memory_kind"] = str(replied.get("memory_kind", ""))
	result["memory_summary"] = str(replied.get("memory_summary", ""))
	result["fact_refs"] = (replied.get("fact_refs", {}) as Dictionary).duplicate(true)
	result["at_utc"] = now
	_remember_dialogue_result(command_id, payload, result)
	return result.duplicate(true)


## 关系投影：只把真实社交文档里的那一行压成 `NpcSocial.PEER_KEYS` 形状。玩家
## 行不存在时按亲密度 0、无动作投影，不虚构赠礼或动作。
func _dialogue_relation(npc_id: String, player_id: String) -> Dictionary:
	var relations_value: Variant = resident_social.get("relations", {})
	var peers_value: Variant = relations_value.get(npc_id) \
		if relations_value is Dictionary else null
	var row: Dictionary = {}
	if peers_value is Dictionary:
		var stored: Variant = (peers_value as Dictionary).get(player_id)
		if stored is Dictionary:
			row = stored
	var gifts: int = 0
	var gifts_value: Variant = row.get("gifts_utc", [])
	if gifts_value is Array:
		gifts = (gifts_value as Array).size()
	var acts: int = 0
	var acts_value: Variant = row.get("acts", {})
	if acts_value is Dictionary:
		acts = (acts_value as Dictionary).size()
	return {
		"affinity": int(row.get("affinity", 0)),
		"last_utc": float(row.get("last_utc", 0.0)),
		"gifts": gifts,
		"acts": acts,
	}


func _dialogue_affinity(npc_id: String, player_id: String) -> int:
	return int(_dialogue_relation(npc_id, player_id).affinity)


## 当前玩家对一名居民的持久化对话行；缺失时是空字典，不创建文档条目。
func _dialogue_state_for(player_id: String, npc_id: String) -> Dictionary:
	var rows_value: Variant = resident_dialogues.get(player_id)
	if not rows_value is Dictionary:
		return {}
	var row_value: Variant = (rows_value as Dictionary).get(npc_id)
	return row_value if row_value is Dictionary else {}


## UTC 日序号，与偷菜日切使用同一个 86400 秒边界。
static func _dialogue_day(now_utc: float) -> int:
	return int(floorf(now_utc / 86400.0))


## 当日累计：持久化的日序号与今天不同即视为 0；归零只发生在投影里，写盘要等到
## 下一次成功对话。
func _dialogue_daily(player_id: String, npc_id: String, now_utc: float) -> int:
	var state: Dictionary = _dialogue_state_for(player_id, npc_id)
	if int(state.get("day_utc", -1)) != _dialogue_day(now_utc):
		return 0
	return int(state.get("daily_affinity", 0))


## 权威可见事实投影。行情取最近一笔真实成交的成交价（公开市场事实）；没有成交
## 时不传价格，规则层回答“没有记录”。农事记录取是否有任何地块种着作物，即
## “是否有已记录的农事”，不暴露地块 id、作物种类或数量。
func _dialogue_visible() -> Dictionary:
	var visible: Dictionary = {}
	var trades: Array = farm.market_trades()
	if not trades.is_empty():
		var latest: Dictionary = trades[trades.size() - 1]
		var price: int = int(latest.get("price", 0))
		if price > 0 and price <= NpcDialogue.MAX_VISIBLE_PRICE:
			visible["market_price"] = price
	var data: Dictionary = farm.snapshot()
	var fields_value: Variant = data.get("fields")
	var worked: bool = false
	if fields_value is Dictionary:
		for field_value: Variant in (fields_value as Dictionary).values():
			if not field_value is Dictionary:
				continue
			var cells_value: Variant = (field_value as Dictionary).get("cells")
			if not cells_value is Dictionary:
				continue
			for cell_value: Variant in (cells_value as Dictionary).values():
				if cell_value is Dictionary \
						and not str((cell_value as Dictionary).get("crop_id", "")).is_empty():
					worked = true
					break
			if worked:
				break
	visible["work_recorded"] = worked
	return visible


## 关系写入：对话只改变这一名玩家与这一名居民之间的 affinity 与最近互动时刻。
## 行不存在时新建空动作/赠礼行；已有动作与赠礼时刻保留，不把对话伪装成交社动作。
## 一行关系的对象数有上限；玩家行已存在时永不新建，超过上限才算失败。
func _dialogue_write_relation(candidate: Dictionary, npc_id: String,
		player_id: String, delta: int, now_utc: float) -> Dictionary:
	var relations_value: Variant = candidate.get("relations")
	if not relations_value is Dictionary:
		return {"ok": false, "reason": "invalid_state"}
	var relations: Dictionary = relations_value
	if not relations.has(npc_id):
		return {"ok": false, "reason": "invalid_state"}
	var peers: Dictionary = relations[npc_id]
	if not peers.has(player_id):
		if peers.size() >= NpcSocial.MAX_PEERS:
			return {"ok": false, "reason": "dialogue_capacity"}
		peers[player_id] = {
			"affinity": 0, "last_utc": 0.0, "acts": {}, "gifts_utc": [],
		}
	var row: Dictionary = peers[player_id]
	row["affinity"] = clampi(int(row.get("affinity", 0)) + delta,
		NpcSocial.MIN_AFFINITY, NpcSocial.MAX_AFFINITY)
	row["last_utc"] = maxf(float(row.get("last_utc", 0.0)), now_utc)
	return {"ok": true, "reason": ""}


## 对话状态写入：最近对话时刻、当日累计与日序号。日切后的累计由规则层从 0
## 算出（投影时已归零），这里只原样保存。行键必须是名册居民，外层键是当前连接
## 解析出的玩家，绝不接收客户端身份。
func _dialogue_write_state(candidate: Dictionary, player_id: String,
		npc_id: String, now_utc: float, daily_after: int) -> bool:
	if not candidate.has(player_id):
		if candidate.size() >= ResidentsStore.MAX_DIALOGUE_PLAYERS:
			return false
		candidate[player_id] = {}
	var rows: Dictionary = candidate[player_id]
	rows[npc_id] = {
		"last_dialogue_utc": now_utc,
		"daily_affinity": clampi(daily_after, 0, NpcDialogue.MAX_DAILY_AFFINITY),
		"day_utc": _dialogue_day(now_utc),
	}
	return ResidentsStore.valid_dialogues(candidate)


static func _dialogue_salience(category: String) -> int:
	if category == NpcDialogue.CATEGORY_APOLOGIZE:
		return 50
	if category == NpcDialogue.CATEGORY_INVITE:
		return 30
	if category == NpcDialogue.CATEGORY_FAREWELL:
		return 15
	return 20


## 记忆 id 由 command id、居民 id 与玩家 id 派生，FNV-1a 两轮 64 位。不同玩家
## 可能选到同一个 command id，玩家必须参与 id，否则第二名玩家的首次对话会被
## 误判为重复。对话记忆不需要跨重启重放窗口，但这个确定性 id 让“同一命令的
## 第二条记忆”永远写不进去。
static func _dialogue_memory_id(command_id: String, npc_id: String,
		player_id: String) -> String:
	return "dlg_%08x%08x" % [
		_dialogue_hash(command_id, npc_id, player_id, "0"),
		_dialogue_hash(command_id, npc_id, player_id, "1"),
	]


static func _dialogue_hash(command_id: String, npc_id: String, player_id: String,
		domain: String) -> int:
	const OFFSET: int = 2166136261
	const PRIME: int = 16777619
	const MASK: int = 0xFFFFFFFF
	var digest: int = OFFSET
	for part: String in [command_id, npc_id, player_id, domain]:
		for byte: int in part.to_utf8_buffer():
			digest = ((digest ^ byte) * PRIME) & MASK
		digest = ((digest ^ 0xFF) * PRIME) & MASK
	return digest


func _resident_memory_has(memory_id: String) -> bool:
	var npcs_value: Variant = resident_memories.get("npcs")
	if not npcs_value is Dictionary:
		return false
	for npc_value: Variant in (npcs_value as Dictionary).values():
		if not npc_value is Dictionary:
			continue
		var entries_value: Variant = (npc_value as Dictionary).get("entries", {})
		if entries_value is Dictionary and (entries_value as Dictionary).has(memory_id):
			return true
	return false


func _replay_dialogue(command_id: String, payload: String) -> Dictionary:
	var entry_value: Variant = _dialogue_results.get(command_id)
	if not entry_value is Dictionary:
		return {}
	var stored_value: Variant = (entry_value as Dictionary).get("result")
	if not stored_value is Dictionary:
		return {}
	var stored: Dictionary = stored_value
	if str((entry_value as Dictionary).get("payload", "")) != payload:
		return _dialogue_result(false, "command_conflict",
			str(stored.get("viewer", "")), str(stored.get("npc_id", "")),
			str(stored.get("category", "")))
	var reply: Dictionary = stored.duplicate(true)
	reply["duplicate"] = true
	return reply


## 记录首次回复，最多保留 `MAX_DIALOGUE_RESULTS` 条，超出淘汰最旧的一条。窗口
## 只在内存里，不进入 `residents.json`。
func _remember_dialogue_result(command_id: String, payload: String,
		result: Dictionary) -> void:
	if _dialogue_results.size() >= MAX_DIALOGUE_RESULTS \
			and not _dialogue_results.has(command_id):
		var oldest: String = ""
		var oldest_utc: float = INF
		for key: Variant in _dialogue_results.keys():
			var entry: Dictionary = _dialogue_results[key]
			var stored_value: Variant = entry.get("result")
			var at: float = float((stored_value as Dictionary).get("at_utc", 0.0)) \
				if stored_value is Dictionary else 0.0
			if at < oldest_utc or (at == oldest_utc and str(key) < oldest):
				oldest = str(key)
				oldest_utc = at
		_dialogue_results.erase(oldest)
	_dialogue_results[command_id] = {
		"payload": payload, "result": result.duplicate(true),
	}


static func _dialogue_result(ok: bool, reason: String, actor: String,
		npc_id: String, category: String, cooldown_reason: String = "") -> Dictionary:
	return {
		"ok": ok, "reason": reason,
		"reason_text": _dialogue_reason_text(reason),
		"viewer": actor, "npc_id": npc_id, "category": category,
		"duplicate": false, "reply_kind": "", "tone": "",
		"affinity_delta": 0, "affinity_after": 0, "daily_affinity_after": 0,
		"capped_reason": "", "memory_kind": "", "memory_summary": "",
		"cooldown_reason": cooldown_reason, "fact_refs": {}, "at_utc": 0.0,
	}


## 对话的具名中文原因。规则模块只返回机器原因；这里补上可直接显示的一句，
## 未知原因保留机器串作为兜底而不是静默消失。
static func _dialogue_reason_text(reason: String) -> String:
	match reason:
		"": return ""
		"not_open": return "世界尚未打开。"
		"invalid_player": return "玩家身份无效。"
		"invalid_npc": return "找不到这位居民。"
		"invalid_category": return "这句话的类型无效。"
		"invalid_command": return "对话编号无效。"
		"command_conflict": return "这个对话编号已经用于另一次对话。"
		"duplicate": return "这次对话已经记录过了。"
		"cooldown": return "这位居民刚和你聊过，请稍后再来。"
		"low_affinity": return "你和这位居民还不够熟。"
		"not_inclined": return "这位居民现在不想答应。"
		"invalid_time": return "时间无效。"
		"invalid_traits": return "居民人格档案无效。"
		"invalid_relation": return "居民关系记录无效。"
		"invalid_state": return "对话状态无效。"
		"invalid_memory": return "居民记忆无法写入。"
		"not_a_member": return "尚未加入这个世界。"
		"forbidden": return "当前身份不能执行这个操作。"
		"read_only": return "世界正在迁移，暂时只读。"
		"disabled": return "居民对话尚未启用。"
		"dialogue_capacity": return "这位居民认识的人已经太多了。"
		"payload_too_large": return "指令过大。"
		"rate_limited": return "请求太频繁，请稍后再试。"
	if reason.begins_with("save_resident_state_"):
		return "居民状态未能保存这次对话。"
	return reason


static func _resident_failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "changed": false,
		"counts": {"opened": 0, "purchased": 0, "failed": 0, "socialized": 0},
		"failures": [], "intents": [], "social": [], "invitations": []}


## The authority's own logical clock: the world time it started from plus
## monotonic elapsed time. Growth still settles only through now_utc/advance_to;
## this clock exists so invitations, social grants and clock-skew bounds keep
## moving in a world that has no crop event to advance now_utc.
func authority_now_utc() -> float:
	if _session_started_ms <= 0:
		return now_utc
	return maxf(now_utc, _session_start_utc
		+ float(Time.get_ticks_msec() - _session_started_ms) / 1000.0)


func next_event_utc() -> float:
	# The next stage boundary comes from authoritative cell growth and the crop
	# durations owned by FarmState/Crops; no growth rule is duplicated here.
	# An empty or fully mature world has no future boundary and returns INF.
	# A growing crop also reports the end of the current weather block, because
	# the growth rate can change there.
	if farm == null:
		return INF
	var data: Dictionary = farm.snapshot()
	var kind: String = _current_weather_kind()
	var next: float = INF
	for field_id: String in data.fields:
		for cell_id: String in data.fields[field_id].cells:
			var cell: Dictionary = data.fields[field_id].cells[cell_id]
			if cell.crop_id.is_empty():
				continue
			var duration: float = Crops.definition(cell.crop_id).duration_seconds
			var growth: float = float(cell.growth_seconds)
			var baseline: float = float(cell.last_settled_utc_seconds)
			var factor: float = FarmState.weather_growth_factor(kind, float(cell.get("moisture", FarmState.MOISTURE_DEFAULT)))
			if factor <= 0.0 or not is_finite(factor):
				factor = 1.0
			for threshold: float in [duration * Crops.YOUNG_PROGRESS, duration]:
				if growth >= threshold:
					continue
				var at: float = baseline + (threshold - growth) / factor
				if at < next:
					next = at
	if not is_finite(next):
		return INF
	# A boundary already due before the current world time is applied by
	# settling at the current time, so it is reported as "now", not the past.
	return maxf(next, now_utc)


func advance_to(target_utc_seconds: float) -> Dictionary:
	# Growth is settled by FarmState in segments that stop on each event; the
	# final segment reaches the requested target. Backwards time is refused.
	if farm == null:
		return _failure("not_open")
	if not _valid_time(target_utc_seconds):
		return _failure("invalid_time")
	if target_utc_seconds < now_utc:
		return _failure("time_backwards")
	var changed: Array[String] = []
	var visual: Array[String] = []
	# A reopened world may hold baselines older than the supplied logical time.
	# Normalize at the current time before looking for future boundaries.
	var normalized: Dictionary = farm.settle(now_utc)
	if not normalized.ok:
		return normalized
	_merge_names(changed, normalized.get("changed_fields", []))
	_merge_names(visual, normalized.get("visual_changed", []))
	var segments: int = 0
	while true:
		var event: float = next_event_utc()
		# Weather block boundaries are segment points owned by this session, just
		# like growth events. They are where FarmState applies a moisture change.
		if nature != null:
			var weather_event: float = nature.next_weather_at(now_utc)
			if is_finite(weather_event) and weather_event < event:
				event = weather_event
		if not is_finite(event) or event > target_utc_seconds or event <= now_utc:
			break
		var settled: Dictionary = farm.settle(event)
		if not settled.ok:
			return settled
		_merge_names(changed, settled.get("changed_fields", []))
		_merge_names(visual, settled.get("visual_changed", []))
		now_utc = event
		segments += 1
	if now_utc < target_utc_seconds:
		var final_settled: Dictionary = farm.settle(target_utc_seconds)
		if not final_settled.ok:
			return final_settled
		_merge_names(changed, final_settled.get("changed_fields", []))
		_merge_names(visual, final_settled.get("visual_changed", []))
		now_utc = target_utc_seconds
		segments += 1
	# The economy sweep uses the same authoritative clock as growth. It runs
	# once at the target, not per growth segment: the rules are deterministic
	# and depend only on the final UTC instant.
	var scan: Dictionary = settle_economy(farm, now_utc)
	if not scan.ok:
		return {"ok": false, "reason": str(scan.reason), "changed_fields": changed,
			"visual_changed": visual, "segments": segments}
	if bool(scan.changed):
		shared_changed.emit()
	return {
		"ok": true, "reason": "", "changed_fields": changed,
		"reward_crop_id": "", "reward_amount": 0,
		"visual_changed": visual, "segments": segments,
		"market_expired": int(scan.counts.get("expired", 0)),
		"market_matched": int(scan.counts.get("matched", 0)),
		"market_delivered": int(scan.counts.get("delivered", 0)),
		"market_lost": int(scan.counts.get("lost", 0)),
		"loans_settled": int(scan.counts.get("loans", 0)),
	}


func _current_weather_kind() -> String:
	# The block at the session clock decides the factor until the next weather
	# boundary; advance_to() stops at that boundary before recomputing.
	if nature == null:
		return ""
	var weather: Dictionary = nature.weather_at(now_utc)
	return str(weather.kind) if not weather.is_empty() else ""


func save() -> Dictionary:
	if farm == null:
		return _failure("not_open")
	var nature_saved: Dictionary = _ensure_nature_persisted()
	if not nature_saved.ok:
		return _failure("save_nature_" + str(nature_saved.kind))
	# An untouched default cadastre is deterministic, so it is written only after
	# it was loaded or changed. That keeps a plain headless world from creating a
	# document whose world id a later shared authority did not choose.
	if _territory_persisted:
		var territory_saved: Dictionary = territory_store.save_state(territory)
		if not territory_saved.ok:
			return _failure("save_territory_" + str(territory_saved.kind))
	return store.save_state(farm, decorations)


## Read-only copy of the cadastre. Callers cannot mutate the authority's document
## through the returned value.
func territory_view() -> Dictionary:
	return territory.duplicate(true)


## Opened member ids this world recognizes for a land transfer: every granted
## economy account that names a real player. The roster is derived on demand and
## never stored in the cadastre, so a receiver is a member exactly while their
## durable account exists. The world account, the rule merchant, organization
## accounts and residents are not players and are excluded.
func territory_members() -> Array:
	var result: Array = []
	if farm == null:
		return result
	var snapshot: Dictionary = farm.economy_snapshot()
	var accounts_value: Variant = snapshot.get("accounts")
	if not accounts_value is Dictionary:
		return result
	var accounts: Dictionary = accounts_value
	for owner: Variant in accounts:
		var owner_id: String = str(owner)
		if owner_id.is_empty() or owner_id == Economy.WORLD_OWNER \
				or owner_id == Market.MERCHANT or OwnerIds.is_organization_account(owner_id) \
				or NpcRoster.IDS.has(owner_id):
			continue
		var account: Variant = accounts[owner]
		if not account is Dictionary or not bool((account as Dictionary).get("granted", false)):
			continue
		result.append(owner_id)
	result.sort()
	return result


## Parcel ids opened to every member because a built public work is bound to them.
## This is a read-only dependency on `public_works`: the cadastre is not rewritten
## and no project document is touched. A project that is not bound or not built
## contributes nothing.
func public_works_passable_parcels() -> Array:
	var result: Array = []
	var projects_value: Variant = public_works.get("projects")
	if not projects_value is Dictionary:
		return result
	var projects: Dictionary = projects_value
	for project_id: Variant in projects:
		var row: Variant = projects[project_id]
		if not row is Dictionary:
			continue
		if str((row as Dictionary).get("status", "")) != PublicWorks.STATUS_BUILT:
			continue
		var parcel_id: String = str((row as Dictionary).get("parcel_id", ""))
		if parcel_id.is_empty() or result.has(parcel_id):
			continue
		result.append(parcel_id)
	result.sort()
	return result


## Passage decision at the authority layer. The player is always resolved by the
## connection, never by the payload. Ownership, unclaimed ground and built public
## works are the only sources of passage; there is no field-level "public road"
## flag in the cadastre (recorded as a boundary in RECORD-10).
func can_pass_territory(parcel_id: String, actor: String) -> Dictionary:
	if territory_store == null:
		return {"ok": false, "reason": "not_open", "parcel_id": parcel_id, "passable": false}
	var illegal_actor: bool = actor.is_empty() or actor == TerritoryState.PUBLIC_OWNER \
		or not OwnerIds.valid(actor)
	if illegal_actor:
		return {"ok": false, "reason": "invalid_player", "parcel_id": parcel_id,
			"passable": false}
	var parcels: Variant = territory.get("parcels")
	if not parcels is Dictionary or not (parcels as Dictionary).has(parcel_id):
		return {"ok": false, "reason": "unknown_parcel", "parcel_id": parcel_id,
			"passable": false}
	return {"ok": true, "reason": "", "parcel_id": parcel_id,
		"passable": TerritoryState.can_pass(territory, parcel_id, actor,
			public_works_passable_parcels())}


## The single parcel this world routes from. A built village square is the public
## entrance. When several built squares are bound the smallest parcel id wins,
## because the routing view has exactly one entrance and inventing a multi-origin
## search is a product decision this read-only slice does not take. A bound parcel
## the cadastre does not contain is deliberately not filtered here: the routing
## view reports `unknown_entrance`, which tells an operator the project is
## misconfigured instead of hiding it behind `no_entrance`.
func public_entrance_parcel() -> String:
	var projects_value: Variant = public_works.get("projects")
	if not projects_value is Dictionary:
		return ""
	var projects: Dictionary = projects_value
	var candidates: Array = []
	for project_id: Variant in projects:
		var row: Variant = projects[project_id]
		if not row is Dictionary:
			continue
		if str((row as Dictionary).get("kind", "")) != PublicWorks.KIND_VILLAGE_SQUARE:
			continue
		if str((row as Dictionary).get("status", "")) != PublicWorks.STATUS_BUILT:
			continue
		var parcel_id: String = str((row as Dictionary).get("parcel_id", ""))
		if parcel_id.is_empty() or candidates.has(parcel_id):
			continue
		candidates.append(parcel_id)
	candidates.sort()
	return str(candidates[0]) if not candidates.is_empty() else ""


## Parcel ids of completed farm buildings, mapped by the ADR-028 ordinal
## convention (`TerritoryState.slot_parcel_id`) and intersected with this
## cadastre. A construction site is not a homestead yet. Every building slot is a
## homestead in the current catalog (the three blueprints are all private plans),
## so a completed workshop or pavilion counts too rather than forcing a second
## "residence" flag into the building document. Slots whose parcel this cadastre
## does not contain are skipped: the building exists but has no land to route.
func built_homestead_parcels() -> Array:
	var result: Array = []
	if farm == null:
		return result
	var parcels_value: Variant = territory.get("parcels")
	if not parcels_value is Dictionary:
		return result
	var parcels: Dictionary = parcels_value
	var buildings: Dictionary = farm.buildings_at(now_utc)
	var slots: Array = buildings.keys()
	slots.sort()
	for slot_value: Variant in slots:
		var slot_id: String = str(slot_value)
		var row: Variant = buildings[slot_id]
		if not row is Dictionary or str((row as Dictionary).get("state", "")) != "done":
			continue
		var parcel_id: String = TerritoryState.slot_parcel_id(slot_id)
		if parcel_id.is_empty() or not parcels.has(parcel_id):
			continue
		if not result.has(parcel_id):
			result.append(parcel_id)
	result.sort()
	return result


## Read-only connectivity answer for one parcel: would making it impassable cut
## the public entrance off from a completed homestead? This is the authority half
## of `TerritoryPaths.check_blocking()`; it never writes a store, never advances
## `territory.sequence` and never edits the farm. It is a read like `can_pass`, so
## visitors and anonymous members may ask it.
##
## Returns {ok, reason, parcel_id, blocking}. `blocking` always has the
## `check_blocking()` shape; when the routing view cannot be built it carries the
## same named failure instead, so callers never handle two answer shapes.
func check_territory_blocking(parcel_id: String) -> Dictionary:
	if territory_store == null or farm == null:
		return _territory_blocking_failure("not_open", parcel_id)
	var parcels_value: Variant = territory.get("parcels")
	if not parcels_value is Dictionary:
		return _territory_blocking_failure("invalid_state", parcel_id)
	var entrance: String = public_entrance_parcel()
	if entrance.is_empty():
		return _territory_blocking_failure("no_entrance", parcel_id)
	var passable: Array = []
	var parcels: Dictionary = parcels_value
	for value: Variant in public_works_passable_parcels():
		var passable_id: String = str(value)
		if parcels.has(passable_id):
			passable.append(passable_id)
	var view: Dictionary = TerritoryPaths.build_view(territory, {
		"entrance": entrance,
		"homesteads": built_homestead_parcels(),
		"passable": passable,
	})
	if not bool(view.get("ok", false)):
		return _territory_blocking_failure(str(view.get("reason", "invalid_state")),
			parcel_id)
	var blocking: Dictionary = TerritoryPaths.check_blocking(view, parcel_id)
	return {
		"ok": bool(blocking.get("ok", false)),
		"reason": str(blocking.get("reason", "")),
		"parcel_id": parcel_id,
		"blocking": blocking,
	}


static func _territory_blocking_failure(reason: String, parcel_id: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "parcel_id": parcel_id,
		"blocking": {
			"ok": false, "reason": reason, "parcel": parcel_id, "entrance": "",
			"entrance_reachable": false, "blocked": [], "newly_blocked": [],
		},
	}


## Claims a parcel for the actor resolved by the connection layer. The land time
## is the authority clock, unless this command id already names a land action:
## a retry then reuses the recorded stamp and replays idempotently across a
## restart instead of conflicting on a newer clock.
func claim_territory(parcel_id: String, actor: String, command_id: String) -> Dictionary:
	if territory_store == null:
		return _territory_failure("not_open", parcel_id)
	var candidate: Dictionary = territory.duplicate(true)
	var result: Dictionary = TerritoryState.claim(candidate, world_id, parcel_id, actor,
		command_id, _territory_action_time(command_id))
	return _commit_territory(candidate, result)


func transfer_territory(parcel_id: String, actor: String, to: String,
		command_id: String) -> Dictionary:
	if territory_store == null:
		return _territory_failure("not_open", parcel_id)
	var candidate: Dictionary = territory.duplicate(true)
	var result: Dictionary = TerritoryState.transfer(candidate, parcel_id, actor, to,
		command_id, _territory_action_time(command_id), territory_members())
	return _commit_territory(candidate, result)


func release_territory(parcel_id: String, actor: String, command_id: String) -> Dictionary:
	if territory_store == null:
		return _territory_failure("not_open", parcel_id)
	var candidate: Dictionary = territory.duplicate(true)
	var result: Dictionary = TerritoryState.release(candidate, parcel_id, actor,
		command_id, _territory_action_time(command_id))
	return _commit_territory(candidate, result)


## A failed or replayed command changes no file. A new command is written first
## and only then becomes the live document, so a failed save leaves the authority
## exactly as it was.
func _commit_territory(candidate: Dictionary, result: Dictionary) -> Dictionary:
	if not bool(result.get("ok", false)) or bool(result.get("duplicate", false)):
		return result
	var saved: Dictionary = territory_store.save_state(candidate)
	if not saved.ok:
		return _territory_failure("save_" + str(saved.kind), str(result.get("parcel_id", "")))
	territory = candidate
	_territory_persisted = true
	return result


func _territory_action_time(command_id: String) -> float:
	var recorded: float = TerritoryState.recorded_time(territory, command_id)
	return recorded if recorded >= 0.0 else now_utc


static func _territory_failure(reason: String, parcel_id: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "parcel_id": parcel_id, "owner": "",
		"status": "", "duplicate": false,
	}


## 只读的组织视图。成员及其职位是公开社会事实；账户 id、权限表的写入路径和
## 内存命令窗口都不下发。组织按 id 排序，相同成员集合产生逐字节相同的载荷。
func organizations_view() -> Dictionary:
	var organizations_value: Variant = organizations.get("organizations")
	if not organizations_value is Dictionary:
		return {"organizations": []}
	var rows: Array = []
	var by_id: Dictionary = organizations_value
	for org_id: String in by_id.keys():
		var org_value: Variant = by_id[org_id]
		if not org_value is Dictionary:
			continue
		var org: Dictionary = org_value
		var members: Dictionary = {}
		var members_value: Variant = org.get("members")
		if members_value is Dictionary:
			members = (members_value as Dictionary).duplicate(true)
		var roles: Dictionary = {}
		var roles_value: Variant = org.get("roles")
		if roles_value is Dictionary:
			roles = (roles_value as Dictionary).duplicate(true)
		rows.append({
			"id": org_id,
			"name": str(org.get("name", "")),
			"created_utc": float(org.get("created_utc", 0.0)),
			"status": str(org.get("status", Organization.STATUS_ACTIVE)),
			"closed_utc": float(org.get("closed_utc", 0.0)),
			"members": members,
			"roles": roles,
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.id) < str(b.id))
	return {"organizations": rows}


## 通过权威时钟执行一次组织操作。操作者由调用方（连接层）解析传入，参数里
## 的任何 actor/owner 字段都不参与授权。规则在副本上计算，候选写盘成功后才
## 替换活文档；同一命令 id 的即时重放返回首次结果并标记 `duplicate`。
func execute_organization(action: String, actor: String, args: Dictionary,
		command_id: String) -> Dictionary:
	if organizations_store == null:
		return _organization_result(false, "not_open", action, "", false)
	if not _valid_org_command_id(command_id):
		return _organization_result(false, "invalid_command", action, "", false)
	var payload: String = JSON.stringify([action, actor, args])
	var replayed: Dictionary = _replay_organization(command_id, payload)
	if not replayed.is_empty():
		return replayed
	var org_id: String = str(args.get("org_id", ""))
	var now: float = authority_now_utc()
	var outcome: Dictionary
	match action:
		"create":
			outcome = Organization.create(organizations, args.get("org_id", ""),
				args.get("name", ""), actor, now)
		"join":
			outcome = Organization.join(organizations, args.get("org_id", ""), actor, now)
		"leave":
			outcome = Organization.leave(organizations, args.get("org_id", ""), actor, now)
		"appoint":
			outcome = Organization.appoint(organizations, args.get("org_id", ""), actor,
				args.get("player_id"), args.get("role"), now)
		"transfer_leadership":
			outcome = Organization.transfer_leadership(organizations, args.get("org_id", ""),
				actor, args.get("player_id"), now)
		"dissolve":
			return _dissolve_organization(actor, args, command_id, payload)
		_:
			return _organization_result(false, "unknown_action", action, org_id, false)
	if not bool(outcome.get("ok", false)):
		return _organization_result(false, str(outcome.get("reason", "")), action, org_id, false)
	var candidate: Dictionary = outcome.state
	var saved: Dictionary = organizations_store.save_state(candidate)
	if not saved.ok:
		return _organization_result(false, "save_organizations_" + str(saved.kind),
			action, org_id, false)
	organizations = candidate
	var result: Dictionary = _organization_result(true, "", action, org_id, false)
	_remember_organization_command(command_id, payload, result)
	return result


## 解散组织：规则先按当前余额与缴入比例算出清算意图，权威再把基金余额逐笔退还
## 给缴入者，最后关闭组织并移除基金行。退款分录 id 由组织、命令与收款人派生，
## 因此农场已落盘而组织或基金文档尚未落盘时，重试会凭分录跳过已付部分，不会
## 二次转账；组织文档已经关闭时按存档里的同命令清算记录只补完基金移除。
func _dissolve_organization(actor: String, args: Dictionary, command_id: String,
		payload: String) -> Dictionary:
	var org_id: String = str(args.get("org_id", ""))
	if funds_store == null:
		return _organization_result(false, "not_open", "dissolve", org_id, false)
	var recorded: Dictionary = _dissolve_record(org_id, command_id)
	if not recorded.is_empty():
		var closed: Dictionary = _close_dissolved_fund(org_id)
		if not bool(closed.get("ok", false)):
			return _organization_result(false, str(closed.get("reason", "")),
				"dissolve", org_id, false)
		var recovered: Dictionary = _organization_result(true, "", "dissolve", org_id, true)
		recovered["clearing"] = (recorded["clearing"] as Dictionary).duplicate(true)
		return recovered
	var fund_id: String = PublicFund.fund_for(org_id)
	var fund_row: Dictionary = _fund_row(fund_id)
	var account: String = PublicFund.account_for(org_id)
	# 基金账面余额必须等于组织账户真实现金。不一致只接受一种解释：上一次解散
	# 已经把退款写进农场，但组织或基金文档还没写完。此时按账面余额重算同一份
	# 清算意图，并只允许「每笔退款都已有分录」的补完路径。
	var balance: int = farm.economy_cash(account) if farm != null else 0
	var recovering_paid: bool = false
	if not fund_row.is_empty() and int(fund_row.get("balance", -1)) != balance:
		if int(fund_row.get("balance", -1)) < balance:
			return _organization_result(false, "balance_mismatch", "dissolve", org_id, false)
		balance = int(fund_row.get("balance", -1))
		recovering_paid = true
	var contributors: Dictionary = {}
	var contributors_value: Variant = fund_row.get("contributors", {})
	if contributors_value is Dictionary:
		contributors = (contributors_value as Dictionary).duplicate(true)
	var outcome: Dictionary = Organization.dissolve(organizations, org_id, actor,
		authority_now_utc(), {
			"command_id": command_id, "balance": balance,
			"pending_spend": 0, "contributors": contributors,
		})
	if not bool(outcome.get("ok", false)):
		return _organization_result(false, str(outcome.get("reason", "")),
			"dissolve", org_id, false)
	var clearing: Dictionary = (outcome.get("clearing", {}) as Dictionary).duplicate(true)
	var refunds_value: Variant = clearing.get("refunds", [])
	if not refunds_value is Array:
		return _organization_result(false, "balance_mismatch", "dissolve", org_id, false)
	var refunds: Array = refunds_value
	var candidate: RefCounted = null
	if not refunds.is_empty():
		var account_ids: Array = [account]
		for value: Variant in refunds:
			if not value is Dictionary:
				return _organization_result(false, "balance_mismatch", "dissolve", org_id, false)
			account_ids.append(str((value as Dictionary).get("player_id", "")))
		candidate = _farm_candidate_with_accounts(account_ids)
		if candidate == null:
			return _organization_result(false, "not_open", "dissolve", org_id, false)
	var paid_any: bool = false
	for value: Variant in refunds:
		var refund: Dictionary = value
		var player_id: String = str(refund.get("player_id", ""))
		var amount: int = int(refund.get("amount", 0))
		var event_id: String = _refund_event_id(org_id, command_id, player_id)
		var marker: Dictionary = _ledger_payment_marker(event_id, account, player_id)
		if not marker.is_empty():
			if int(marker.get("amount", -1)) != amount:
				return _organization_result(false, "command_conflict", "dissolve", org_id, false)
			continue
		if recovering_paid:
			return _organization_result(false, "balance_mismatch", "dissolve", org_id, false)
		var payment: Dictionary = candidate.economy_authority_pay(account, player_id,
			amount, event_id, authority_now_utc())
		if not bool(payment.get("ok", false)):
			return _organization_result(false,
				_fund_pay_reason(str(payment.get("reason", ""))), "dissolve", org_id, false)
		paid_any = true
	var candidate_funds: Dictionary = _funds_without(fund_id)
	var effective_farm: RefCounted = candidate if candidate != null else farm
	if candidate != null and candidate.economy_cash(account) != 0:
		return _organization_result(false, "balance_mismatch", "dissolve", org_id, false)
	if not PublicFund.valid(candidate_funds) \
			or not _fund_balance_invariant(candidate_funds, effective_farm):
		return _organization_result(false, "balance_mismatch", "dissolve", org_id, false)
	if paid_any:
		var saved: Dictionary = store.save_state(candidate, decorations)
		if not saved.ok:
			return _organization_result(false, "save_" + str(saved.kind),
				"dissolve", org_id, false)
		farm.accept(candidate)
		shared_changed.emit()
	var organizations_saved: Dictionary = organizations_store.save_state(outcome.state)
	if not organizations_saved.ok:
		return _organization_result(false,
			"save_organizations_" + str(organizations_saved.kind), "dissolve", org_id, false)
	organizations = outcome.state
	var funds_saved: Dictionary = funds_store.save_state(candidate_funds)
	if not funds_saved.ok:
		return _organization_result(false, "save_funds_" + str(funds_saved.kind),
			"dissolve", org_id, false)
	funds = candidate_funds
	var result: Dictionary = _organization_result(true, "", "dissolve", org_id, false)
	result["clearing"] = clearing.duplicate(true)
	_remember_organization_command(command_id, payload, result)
	return result


## 组织文档里同 command id 的成功解散记录。它证明退款与关闭已经落盘，重试只需
## 补完基金行移除，不再经过规则或转账。命令记录是状态顶层表，不是组织行字段。
func _dissolve_record(org_id: String, command_id: String) -> Dictionary:
	var organizations_value: Variant = organizations.get("organizations")
	if org_id.is_empty() or not organizations_value is Dictionary:
		return {}
	var org_value: Variant = (organizations_value as Dictionary).get(org_id)
	if not org_value is Dictionary:
		return {}
	if str((org_value as Dictionary).get("status", "")) != Organization.STATUS_CLOSED:
		return {}
	var commands_value: Variant = organizations.get("command_results")
	if not commands_value is Dictionary:
		return {}
	var entry_value: Variant = (commands_value as Dictionary).get(command_id)
	if not entry_value is Dictionary:
		return {}
	var result_value: Variant = (entry_value as Dictionary).get("result")
	if not result_value is Dictionary:
		return {}
	var result: Dictionary = result_value
	if str(result.get("organization_id", "")) != org_id:
		return {}
	if not result.get("clearing") is Dictionary:
		return {}
	return result


func _close_dissolved_fund(org_id: String) -> Dictionary:
	var fund_id: String = PublicFund.fund_for(org_id)
	if _fund_row(fund_id).is_empty():
		return {"ok": true, "reason": ""}
	var candidate_funds: Dictionary = _funds_without(fund_id)
	if not PublicFund.valid(candidate_funds) \
			or not _fund_balance_invariant(candidate_funds, farm):
		return {"ok": false, "reason": "balance_mismatch"}
	var saved: Dictionary = funds_store.save_state(candidate_funds)
	if not saved.ok:
		return {"ok": false, "reason": "save_funds_" + str(saved.kind)}
	funds = candidate_funds
	return {"ok": true, "reason": ""}


func _funds_without(fund_id: String) -> Dictionary:
	var candidate: Dictionary = funds.duplicate(true)
	var by_id: Variant = candidate.get("funds")
	if by_id is Dictionary:
		(by_id as Dictionary).erase(fund_id)
	return candidate


static func _refund_event_id(org_id: String, command_id: String,
		player_id: String) -> String:
	return "org_refund_" + (org_id + "|" + command_id + "|" + player_id).sha256_text()


func _replay_organization(command_id: String, payload: String) -> Dictionary:
	var entry: Variant = _organization_results.get(command_id)
	if not entry is Dictionary:
		return {}
	var first: Variant = (entry as Dictionary).get("result")
	if not first is Dictionary:
		return {}
	var stored: Dictionary = first
	if str((entry as Dictionary).get("payload", "")) != payload:
		return _organization_result(false, "command_conflict",
			str(stored.get("action", "")), str(stored.get("org_id", "")), false)
	var replayed: Dictionary = _organization_result(bool(stored.get("ok", false)),
		str(stored.get("reason", "")), str(stored.get("action", "")),
		str(stored.get("org_id", "")), true)
	if stored.get("clearing") is Dictionary:
		replayed["clearing"] = (stored["clearing"] as Dictionary).duplicate(true)
	return replayed


func _remember_organization_command(command_id: String, payload: String,
		result: Dictionary) -> void:
	_organization_results[command_id] = {"payload": payload, "result": result.duplicate(true)}
	while _organization_results.size() > MAX_ORGANIZATION_RESULTS:
		_organization_results.erase(_organization_results.keys()[0])


static func _organization_result(ok: bool, reason: String, action: String,
		org_id: String, duplicate: bool) -> Dictionary:
	return {
		"ok": ok, "reason": reason, "action": action,
		"org_id": org_id, "duplicate": duplicate,
	}


static func _valid_org_command_id(value: String) -> bool:
	return not value.is_empty() and value.length() <= FarmCommand.MAX_ID_LENGTH


## 只读的单位视图。名册、归属、兵种、人数、装备、驻地与欠供天数是公开的战术事实；
## 命令记录、账户 id 和补给扣减路径都不下发。按单位 id 排序，相同名册产生逐字节
## 相同的载荷。
func units_view() -> Dictionary:
	var rows: Array = []
	var units_value: Variant = units.get("units")
	if units_value is Dictionary:
		var by_id: Dictionary = units_value
		for unit_id: String in by_id.keys():
			var row_value: Variant = by_id[unit_id]
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			rows.append({
				"id": unit_id,
				"owner": str(row.get("owner", "")),
				"kind": str(row.get("kind", "")),
				"people": int(row.get("people", 0)),
				"equipment": str(row.get("equipment", "")),
				"station": str(row.get("station", "")),
				"unfed_days": int(row.get("unfed_days", 0)),
				"unpaid_days": int(row.get("unpaid_days", 0)),
			})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.id) < str(b.id))
	return {"units": rows}


## 通过权威时钟执行一次单位操作。操作者由调用方（连接层）解析传入，参数里的任何
## actor/owner 字段都不参与授权。招募先写农场（现金转给 @world、口袋粮草扣除），
## 农场保存成功后才写单位文档；解散与补给只写单位文档。失败不修改活文档。
func execute_unit(action: String, actor: String, args: Dictionary,
		command_id: String) -> Dictionary:
	if units_store == null or farm == null:
		return _unit_result(false, "not_open", action, "", false)
	match action:
		"recruit":
			return _recruit_unit(actor, args, command_id)
		"disband":
			return _disband_unit(actor, args, command_id)
		"upkeep":
			return _upkeep_units()
		"wage":
			return _pay_unit_wages()
		_:
			return _unit_result(false, "unknown_action", action, "", false)


func _recruit_unit(actor: String, args: Dictionary, command_id: String) -> Dictionary:
	if command_id.is_empty():
		return _unit_result(false, UnitState.REASON_INVALID_COMMAND, "recruit", "", false)
	var command: Dictionary = {
		"id": command_id,
		"owner": actor,
		"kind": args.get("kind", ""),
		"people": args.get("people"),
		"equipment": args.get("equipment", ""),
		"station": args.get("station", ""),
	}
	var now: float = _unit_action_time(command_id)
	var outcome: Dictionary = UnitState.recruit(units, _actor_stock(actor), command, now)
	if not bool(outcome.get("ok", false)):
		var reason: String = str(outcome.get("reason", ""))
		# 农场已经扣款、单位文档尚未写入时，重试会看到减少后的口袋。ledger 里的
		# `unit_pay_<id>` 是这两份文档之间的唯一持久标记：金额与双方账户都对得上，
		# 就说明农场侧已经提交，本次只需补写单位文档，绝不能再次扣资产。
		if reason == UnitState.REASON_INSUFFICIENT_CASH \
				or reason == UnitState.REASON_INSUFFICIENT_SUPPLY:
			var marker: Dictionary = _unit_payment_marker(command_id, actor)
			if not marker.is_empty():
				return _recover_paid_recruit(marker, command, command_id)
		return _unit_result(false, reason, "recruit", command_id, false)
	if bool(outcome.get("duplicate", false)):
		return _unit_result(true, "", "recruit", str(outcome.get("unit_id", command_id)), true)
	# 口袋仍然够用时规则会重新给出成功候选，但农场侧可能已经付过款。任何匹配的
	# 付款分录都优先当作重试，避免第二次扣款或因为时间戳不同而报冲突。
	var paid: Dictionary = _unit_payment_marker(command_id, actor)
	if not paid.is_empty():
		return _recover_paid_recruit(paid, command, command_id)

	var candidate: RefCounted = _farm_candidate_with_world_account()
	if candidate == null:
		return _unit_result(false, "not_open", "recruit", command_id, false)
	var payment: Dictionary = candidate.economy_pay(_unit_payment_id(command_id),
		actor, Economy.WORLD_OWNER, int(outcome.cost.cash), now)
	if not bool(payment.get("ok", false)):
		return _unit_result(false, _unit_pay_reason(str(payment.get("reason", ""))),
			"recruit", command_id, false)
	# A replayed payment means this farm document already holds the deduction and
	# the goods removal from the same atomic save; do not take the supplies again.
	if not bool(payment.get("duplicate", false)) \
			and not _deduct_supplies(candidate, actor, int(outcome.cost.supplies)):
		return _unit_result(false, UnitState.REASON_INSUFFICIENT_SUPPLY,
			"recruit", command_id, false)
	var saved: Dictionary = store.save_state(candidate, decorations)
	if not saved.ok:
		return _unit_result(false, "save_" + str(saved.kind), "recruit", command_id, false)
	farm.accept(candidate)
	shared_changed.emit()
	return _commit_unit_document(outcome, "recruit", command_id)


## 农场侧已经提交、单位文档缺失时的补写。付款分录同时证明金额与收款方；时间取
## 首次付款时刻，若补给已推进则夹到 `last_upkeep_utc`，避免规则判时间倒退。
func _recover_paid_recruit(marker: Dictionary, command: Dictionary,
		command_id: String) -> Dictionary:
	var cost: Dictionary = _recruit_cost(command)
	if cost.is_empty() or int(marker.get("amount", -1)) != int(cost.cash):
		return _unit_result(false, "command_conflict", "recruit", command_id, false)
	var stamp: float = float(marker.get("at_utc", 0.0))
	var last_upkeep: float = float(units.get("last_upkeep_utc", -1.0))
	if last_upkeep >= 0.0 and stamp < last_upkeep:
		stamp = last_upkeep
	var recovered: Dictionary = UnitState.recruit(units,
		{"cash": int(cost.cash), "supplies": int(cost.supplies)}, command, stamp)
	if not bool(recovered.get("ok", false)):
		return _unit_result(false, str(recovered.get("reason", "")),
			"recruit", command_id, false)
	return _commit_unit_document(recovered, "recruit", command_id)


func _disband_unit(actor: String, args: Dictionary, command_id: String) -> Dictionary:
	if command_id.is_empty():
		return _unit_result(false, UnitState.REASON_INVALID_COMMAND, "disband", "", false)
	var command: Dictionary = {
		"id": command_id,
		"unit_id": args.get("unit_id", ""),
		"owner": actor,
	}
	var outcome: Dictionary = UnitState.disband(units, command, authority_now_utc())
	if not bool(outcome.get("ok", false)):
		return _unit_result(false, str(outcome.get("reason", "")),
			"disband", str(outcome.get("unit_id", "")), false)
	if bool(outcome.get("duplicate", false)):
		return _unit_result(true, "", "disband",
			str(outcome.get("unit_id", "")), true)
	return _commit_unit_document(outcome, "disband",
		str(outcome.get("unit_id", "")))


## 低频战略补给结算。按 owner 分组，用该 owner 口袋里的粮草调用同一份规则：
## 每支单位的需求、缺口逃兵与战力惩罚都由 `UnitState.upkeep` 决定，这里只负责
## 把各 owner 的消耗合并、按目录顺序扣粮并落盘。现金不发生变化。
func _upkeep_units() -> Dictionary:
	# The authority clock has sub-second resolution, while `UnitState.upkeep`
	# decides "same tick" by exact timestamp equality. Quantizing to whole
	# seconds makes duplicate requests inside one wall-clock second one strategic
	# tick instead of two supply deductions.
	var now: float = floorf(authority_now_utc())
	var last: float = float(units.get("last_upkeep_utc", -1.0))
	if last >= 0.0 and now < last:
		return _unit_result(false, UnitState.REASON_TIME_REGRESSION, "upkeep", "", false)
	if last >= 0.0 and now == last:
		var settled: Dictionary = _unit_result(true, "", "upkeep", "", false)
		settled["status"] = UnitState.STATUS_SETTLED_THIS_TICK
		settled["settled_this_tick"] = true
		settled["consumed"] = 0
		settled["deserters"] = 0
		settled["affected"] = []
		return settled

	var units_value: Variant = units.get("units")
	if not units_value is Dictionary:
		return _unit_result(false, UnitState.REASON_INVALID_STATE, "upkeep", "", false)
	var by_id: Dictionary = units_value
	var owners: Array[String] = _unit_owners()

	if owners.is_empty():
		var empty: Dictionary = UnitState.upkeep(units, {"cash": 0, "supplies": 0}, now)
		if not bool(empty.get("ok", false)):
			return _unit_result(false, str(empty.get("reason", "")), "upkeep", "", false)
		var empty_saved: Dictionary = units_store.save_state(empty.state)
		if not empty_saved.ok:
			return _unit_result(false, "save_units_" + str(empty_saved.kind),
				"upkeep", "", false)
		units = empty.state
		var empty_result: Dictionary = _unit_result(true, "", "upkeep", "", false)
		empty_result["status"] = str(empty.get("status", ""))
		empty_result["settled_this_tick"] = false
		empty_result["consumed"] = 0
		empty_result["deserters"] = 0
		empty_result["affected"] = []
		return empty_result

	var consumed_by_owner: Dictionary = {}
	var supplies_by_owner: Dictionary = {}
	for owner: String in owners:
		supplies_by_owner[owner] = _owner_supplies(owner)
	var next_units: Dictionary = by_id.duplicate(true)
	var total_consumed: int = 0
	var total_deserters: int = 0
	var affected: Array = []
	for owner: String in owners:
		var sub_document: Dictionary = _owner_document(owner)
		if sub_document.is_empty():
			return _unit_result(false, UnitState.REASON_INVALID_STATE, "upkeep", "", false)
		var settled: Dictionary = UnitState.upkeep(sub_document,
			{"cash": 0, "supplies": int(supplies_by_owner.get(owner, 0))}, now)
		if not bool(settled.get("ok", false)):
			return _unit_result(false, str(settled.get("reason", "")), "upkeep", "", false)
		for unit_id: Variant in next_units.keys():
			var row_value: Variant = next_units[unit_id]
			if row_value is Dictionary \
					and str((row_value as Dictionary).get("owner", "")) == owner:
				next_units.erase(unit_id)
		var sub_units: Dictionary = settled.state["units"]
		for unit_id: Variant in sub_units:
			next_units[str(unit_id)] = (sub_units[unit_id] as Dictionary).duplicate(true)
		consumed_by_owner[owner] = int(settled.get("consumed", 0))
		total_consumed += int(settled.get("consumed", 0))
		total_deserters += int(settled.get("deserters", 0))
		for row_value: Variant in settled.get("affected", []):
			if row_value is Dictionary:
				affected.append((row_value as Dictionary).duplicate(true))
	affected.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.unit_id) < str(b.unit_id))

	var next: Dictionary = units.duplicate(true)
	next["units"] = next_units
	next["last_upkeep_utc"] = now
	next["sequence"] = int(units["sequence"]) + 1
	# 农场先落盘，单位文档后落盘。单位写失败时农场已经扣粮，接受同一候选并广播，
	# 让内存与磁盘一致；本次单位候选不生效，下一次调用会重新结算。顺序与居民账本
	# 相反是刻意的：粮草在农场文档里，先写单位会让逃兵和扣粮分成两次可失败写入。
	if total_consumed > 0:
		if farm == null:
			return _unit_result(false, "not_open", "upkeep", "", false)
		var candidate: RefCounted = farm.copy()
		for owner: String in owners:
			var amount: int = int(consumed_by_owner.get(owner, 0))
			if amount > 0 and not _deduct_supplies(candidate, owner, amount):
				return _unit_result(false, UnitState.REASON_INVALID_STOCK,
					"upkeep", "", false)
		var saved: Dictionary = store.save_state(candidate, decorations)
		if not saved.ok:
			return _unit_result(false, "save_" + str(saved.kind), "upkeep", "", false)
		farm.accept(candidate)
		shared_changed.emit()
	var units_saved: Dictionary = units_store.save_state(next)
	if not units_saved.ok:
		return _unit_result(false, "save_units_" + str(units_saved.kind),
			"upkeep", "", false)
	units = next
	var result: Dictionary = _unit_result(true, "", "upkeep", "", false)
	result["status"] = UnitState.STATUS_SHORTFALL if total_deserters > 0 \
		else UnitState.STATUS_FED
	result["settled_this_tick"] = false
	result["consumed"] = total_consumed
	result["deserters"] = total_deserters
	result["affected"] = affected
	return result


## 低频工资结算。现金从各 owner 的口袋付给 @world，规则按 unit id 升序逐支支付，
## 现金只付到可用数量为止，缺口累计欠付天数。与补给不同，工资跨两份文档：农场
## 账本记付款、单位文档记 `last_wage_utc` 与 `unpaid_days`。先付钱、后写单位，
## 并用「结算前各单位 `last_wage_utc`」派生的保留事件 id 作为持久标记：单位写
## 失败后，同一份前状态重试会落到同一个账本事件，只补写单位文档，不会二次扣款。
func _pay_unit_wages() -> Dictionary:
	# 与补给同理：权威时钟带毫秒，而规则按整日计数，量化到整秒让同一秒内的
	# 重复请求成为同一次结算。
	var now: float = floorf(authority_now_utc())
	var owners: Array[String] = _unit_owners()
	if owners.is_empty():
		var settled: Dictionary = _unit_result(true, "", "wage", "", false)
		settled["status"] = UnitState.STATUS_SETTLED_THIS_TICK
		settled["settled_this_tick"] = true
		settled["required"] = 0
		settled["paid"] = 0
		settled["unpaid"] = 0
		settled["affected"] = []
		return settled

	var by_id: Dictionary = units["units"]
	var next_units: Dictionary = by_id.duplicate(true)
	# 每个 owner 的付款事件：`{event_id, stamp, amount}`，只有本次真正要付的才收。
	var payments: Array = []
	var total_required: int = 0
	var total_paid: int = 0
	var total_unpaid: int = 0
	var affected: Array = []
	var changed: bool = false
	for owner: String in owners:
		var sub_document: Dictionary = _owner_document(owner)
		if sub_document.is_empty():
			return _unit_result(false, UnitState.REASON_INVALID_STATE, "wage", "", false)
		# 事件 id 只由结算前的单位时钟决定：重试时单位文档若没写成功，前状态不变，
		# 因此无论换哪个 command id 都会命中同一条账本分录。
		var event_id: String = _wage_payment_id(owner, sub_document)
		var marker: Dictionary = _ledger_payment_marker(event_id, owner,
			Economy.WORLD_OWNER)
		var stamp: float = float(marker.get("at_utc", now)) if not marker.is_empty() \
			else now
		var available: int = int(marker.get("amount", 0)) if not marker.is_empty() \
			else farm.economy_cash(owner)
		var outcome: Dictionary = UnitState.pay_wages(sub_document, available, stamp)
		if not bool(outcome.get("ok", false)):
			return _unit_result(false, str(outcome.get("reason", "")), "wage", "", false)
		if not marker.is_empty() and int(outcome.paid) != int(marker.amount):
			# 账本证明付过一笔，但按同一份前状态重算的金额对不上：说明这条事件
			# 被别的业务占用，不能当成重试静默跳过。
			return _unit_result(false, "command_conflict", "wage", "", false)
		if marker.is_empty() and int(outcome.paid) > 0:
			payments.append({
				"owner": owner, "event_id": event_id,
				"amount": int(outcome.paid), "stamp": stamp,
			})
		if not bool(outcome.settled_this_tick):
			changed = true
			total_paid += int(outcome.paid)
		total_required += int(outcome.required)
		total_unpaid += int(outcome.unpaid)
		for unit_id: Variant in next_units.keys():
			var row_value: Variant = next_units[unit_id]
			if row_value is Dictionary \
					and str((row_value as Dictionary).get("owner", "")) == owner:
				next_units.erase(unit_id)
		var sub_units: Dictionary = outcome.state["units"]
		for unit_id: Variant in sub_units:
			next_units[str(unit_id)] = (sub_units[unit_id] as Dictionary).duplicate(true)
		for row_value: Variant in outcome.get("affected", []):
			if row_value is Dictionary:
				affected.append((row_value as Dictionary).duplicate(true))

	if not changed:
		var fresh: Dictionary = _unit_result(true, "", "wage", "", false)
		fresh["status"] = UnitState.STATUS_SETTLED_THIS_TICK
		fresh["settled_this_tick"] = true
		fresh["required"] = 0
		fresh["paid"] = 0
		fresh["unpaid"] = 0
		fresh["affected"] = []
		return fresh

	affected.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.unit_id) < str(b.unit_id))
	var next: Dictionary = units.duplicate(true)
	next["units"] = next_units
	next["sequence"] = int(units["sequence"]) + 1
	# 与招募同样的顺序：农场先落盘，单位文档后落盘。单位写失败时账本分录已经是
	# 重试的依据，下一次调用会走 `marker` 分支补写单位文档而不再次扣款。
	if not payments.is_empty():
		var candidate: RefCounted = _farm_candidate_with_world_account()
		if candidate == null:
			return _unit_result(false, "not_open", "wage", "", false)
		for payment: Dictionary in payments:
			var transfer: Dictionary = candidate.economy_authority_pay(
				str(payment.owner), Economy.WORLD_OWNER, int(payment.amount),
				str(payment.event_id), float(payment.stamp))
			if not bool(transfer.get("ok", false)):
				return _unit_result(false, _unit_pay_reason(str(transfer.get("reason", ""))),
					"wage", "", false)
		var saved: Dictionary = store.save_state(candidate, decorations)
		if not saved.ok:
			return _unit_result(false, "save_" + str(saved.kind), "wage", "", false)
		farm.accept(candidate)
		shared_changed.emit()
	var units_saved: Dictionary = units_store.save_state(next)
	if not units_saved.ok:
		return _unit_result(false, "save_units_" + str(units_saved.kind),
			"wage", "", false)
	units = next
	var result: Dictionary = _unit_result(true, "", "wage", "", false)
	result["status"] = UnitState.STATUS_UNPAID if total_unpaid > 0 \
		else UnitState.STATUS_PAID
	result["settled_this_tick"] = false
	result["required"] = total_required
	result["paid"] = total_paid
	result["unpaid"] = total_unpaid
	result["affected"] = affected
	return result


## 名册里出现过的 owner 集合，按 id 升序。补给与工资都按它逐个口袋结算。
func _unit_owners() -> Array[String]:
	var owners: Array[String] = []
	var rows_value: Variant = units.get("units")
	if not rows_value is Dictionary:
		return owners
	var by_id: Dictionary = rows_value
	for unit_id: Variant in by_id:
		var row_value: Variant = by_id[unit_id]
		if not row_value is Dictionary:
			continue
		var owner: String = str((row_value as Dictionary).get("owner", ""))
		if not owners.has(owner):
			owners.append(owner)
	owners.sort()
	return owners


func _commit_unit_document(outcome: Dictionary, action: String,
		unit_id: String) -> Dictionary:
	var candidate: Dictionary = outcome.state
	var saved: Dictionary = units_store.save_state(candidate)
	if not saved.ok:
		return _unit_result(false, "save_units_" + str(saved.kind),
			action, unit_id, false)
	units = candidate
	return _unit_result(true, "", action, unit_id, false)


## 只读的基金视图。金额、负责人与成员累计是公开的财政事实；history 与命令记录
## 都不下发。按 fund_id 排序，相同基金集合产生逐字节相同的载荷。
func funds_view() -> Dictionary:
	var rows: Array = []
	var funds_value: Variant = funds.get("funds")
	if funds_value is Dictionary:
		var by_id: Dictionary = funds_value
		for fund_id: String in by_id.keys():
			var row_value: Variant = by_id[fund_id]
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			var contributors: Dictionary = {}
			var contributors_value: Variant = row.get("contributors")
			if contributors_value is Dictionary:
				contributors = (contributors_value as Dictionary).duplicate(true)
			rows.append({
				"fund_id": fund_id,
				"org_id": str(row.get("org_id", "")),
				"keeper": str(row.get("keeper", "")),
				"balance": int(row.get("balance", 0)),
				"spent": int(row.get("spent", 0)),
				"contributors": contributors,
			})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.fund_id) < str(b.fund_id))
	return {"funds": rows}


## 通过权威时钟执行一次公共基金操作。操作者由调用方（连接层）解析传入，参数里的
## actor/owner 字段都不参与授权。规则在副本上计算；缴入/支出先写农场现金、后写
## 基金文档，开立/换届只写基金文档。同一命令 id 的即时重放返回首次结果并标记
## `duplicate`；跨重启的缴入/支出重试由账本分录补写基金文档且不二次转账。
func execute_fund(action: String, actor: String, args: Dictionary,
		command_id: String) -> Dictionary:
	if funds_store == null or farm == null:
		return _fund_result(false, "not_open", action, "", false)
	if action == "state":
		return {
			"ok": true, "reason": "", "action": "state", "fund_id": "",
			"duplicate": false, "state": funds_view(),
		}
	if action != "open" and action != "contribute" and action != "spend" \
			and action != "rotate":
		return _fund_result(false, "unknown_action", action, "", false)
	if not _valid_fund_command_id(command_id):
		return _fund_result(false, "invalid_command", action, "", false)
	# 基金文档的 `state` 形状必须保持严格，且本切片明确不在文档里另存命令表：
	# 重放窗口只存在内存里，payload 由动作、操作者与参数直接生成。
	var payload: String = JSON.stringify([action, actor, args])
	var replayed: Dictionary = _replay_fund(command_id, payload)
	if not replayed.is_empty():
		return replayed
	var result: Dictionary
	match action:
		"open":
			result = _open_fund(actor, args, command_id)
		"contribute":
			result = _contribute_fund(actor, args, command_id)
		"spend":
			result = _spend_fund(actor, args, command_id)
		_:
			result = _rotate_fund_keeper(actor, args, command_id)
	if bool(result.get("ok", false)):
		_remember_fund_command(command_id, payload, result)
	return result


func _open_fund(actor: String, args: Dictionary, command_id: String) -> Dictionary:
	var org_id: String = str(args.get("org_id", ""))
	var fund_id: String = PublicFund.fund_for(org_id) if not org_id.is_empty() else ""
	var outcome: Dictionary = PublicFund.open_fund(funds, org_id, actor)
	if not bool(outcome.get("ok", false)):
		return _fund_result(false, str(outcome.get("reason", "")),
			"open", fund_id, false)
	# 基金由组织成员管理：只有当前职位可支出的成员能开立，keeper 就是操作者。
	var permission: String = _org_spend_permission(org_id, actor)
	if not permission.is_empty():
		return _fund_result(false, permission, "open", fund_id, false)
	var candidate: Dictionary = outcome.state
	if not _fund_balance_invariant(candidate, farm):
		return _fund_result(false, "balance_mismatch", "open", fund_id, false)
	var saved: Dictionary = funds_store.save_state(candidate)
	if not saved.ok:
		return _fund_result(false, "save_funds_" + str(saved.kind),
			"open", fund_id, false)
	funds = candidate
	return _fund_result(true, "", "open", fund_id, false)


func _contribute_fund(actor: String, args: Dictionary, command_id: String) -> Dictionary:
	var fund_id: String = _fund_id_from_args(args)
	var row: Dictionary = _fund_row(fund_id)
	if row.is_empty():
		return _fund_result(false, "unknown_fund", "contribute", fund_id, false)
	var org_account: String = PublicFund.account_for(str(row.get("org_id", "")))
	var amount: Variant = args.get("amount")
	var marker: Dictionary = _ledger_payment_marker(
		"fund_pay_" + command_id, actor, org_account)
	if not marker.is_empty():
		# 农场已经扣款：账本分录是唯一持久标记。金额对不上说明同一命令 id 被换成
		# 另一笔操作，必须拒绝；金额一致时只补写基金文档，绝不再次转账。
		if _whole_amount(amount) != int(marker.get("amount", -1)):
			return _fund_result(false, "command_conflict", "contribute", fund_id, false)
		if _fund_balance_matches_row(fund_id, farm):
			return _fund_result(true, "", "contribute", fund_id, true)
		var rebuilt: Dictionary = PublicFund.contribute(funds, fund_id, actor,
			int(marker.get("amount", 0)))
		if not bool(rebuilt.get("ok", false)):
			return _fund_result(false, str(rebuilt.get("reason", "")),
				"contribute", fund_id, false)
		return _commit_recovered_funds(rebuilt.state, "contribute", fund_id)
	var outcome: Dictionary = PublicFund.contribute(funds, fund_id, actor, amount)
	if not bool(outcome.get("ok", false)):
		return _fund_result(false, str(outcome.get("reason", "")),
			"contribute", fund_id, false)
	var candidate_funds: Dictionary = outcome.state
	var candidate: RefCounted = _farm_candidate_with_accounts([org_account])
	if candidate == null:
		return _fund_result(false, "not_open", "contribute", fund_id, false)
	var now: float = authority_now_utc()
	var payment: Dictionary = candidate.economy_pay("fund_pay_" + command_id, actor,
		org_account, int(_whole_amount(amount)), now)
	if not bool(payment.get("ok", false)):
		return _fund_result(false, _fund_pay_reason(str(payment.get("reason", ""))),
			"contribute", fund_id, false)
	if not _fund_balance_invariant(candidate_funds, candidate):
		return _fund_result(false, "balance_mismatch", "contribute", fund_id, false)
	var saved: Dictionary = store.save_state(candidate, decorations)
	if not saved.ok:
		return _fund_result(false, "save_" + str(saved.kind),
			"contribute", fund_id, false)
	farm.accept(candidate)
	shared_changed.emit()
	var funds_saved: Dictionary = funds_store.save_state(candidate_funds)
	if not funds_saved.ok:
		# 农场已落盘：接受同一候选让内存与磁盘一致；基金文档仍为旧版本，下一次
		# 同 id 重试会用 `fund_pay_<id>` 分录补写且绝不二次转账。
		return _fund_result(false, "save_funds_" + str(funds_saved.kind),
			"contribute", fund_id, false)
	funds = candidate_funds
	return _fund_result(true, "", "contribute", fund_id, false)


func _spend_fund(actor: String, args: Dictionary, command_id: String) -> Dictionary:
	var fund_id: String = _fund_id_from_args(args)
	var row: Dictionary = _fund_row(fund_id)
	if row.is_empty():
		return _fund_result(false, "unknown_fund", "spend", fund_id, false)
	var org_id: String = str(row.get("org_id", ""))
	var org_account: String = PublicFund.account_for(org_id)
	var project: Variant = args.get("project_id", "")
	var amount: Variant = args.get("amount")
	var event_id: String = "fund_spend_" + command_id
	var marker: Dictionary = _ledger_payment_marker(
		event_id, org_account, Economy.WORLD_OWNER)
	if not marker.is_empty():
		if _whole_amount(amount) != int(marker.get("amount", -1)):
			return _fund_result(false, "command_conflict", "spend", fund_id, false)
		if _fund_balance_matches_row(fund_id, farm):
			return _fund_result(true, "", "spend", fund_id, true)
		var rebuilt: Dictionary = PublicFund.authorize_spend(funds, fund_id, actor,
			project, int(marker.get("amount", 0)), float(marker.get("at_utc", 0.0)))
		if not bool(rebuilt.get("ok", false)):
			return _fund_result(false, str(rebuilt.get("reason", "")),
				"spend", fund_id, false)
		return _commit_recovered_funds(rebuilt.state, "spend", fund_id)
	var now: float = authority_now_utc()
	var outcome: Dictionary = PublicFund.authorize_spend(funds, fund_id, actor,
		project, amount, now)
	if not bool(outcome.get("ok", false)):
		return _fund_result(false, str(outcome.get("reason", "")),
			"spend", fund_id, false)
	# keeper 身份还不够：组织当前职位必须仍可支出。换届或退出后，旧 keeper 立即
	# 失去把公共账户现金转出的能力。
	var permission: String = _org_spend_permission(org_id, actor)
	if not permission.is_empty():
		return _fund_result(false, permission, "spend", fund_id, false)
	var candidate_funds: Dictionary = outcome.state
	var candidate: RefCounted = _farm_candidate_with_accounts(
		[org_account, Economy.WORLD_OWNER])
	if candidate == null:
		return _fund_result(false, "not_open", "spend", fund_id, false)
	var payment: Dictionary = candidate.economy_pay(event_id, org_account,
		Economy.WORLD_OWNER, int(_whole_amount(amount)), now)
	if not bool(payment.get("ok", false)):
		return _fund_result(false, _fund_pay_reason(str(payment.get("reason", ""))),
			"spend", fund_id, false)
	if not _fund_balance_invariant(candidate_funds, candidate):
		return _fund_result(false, "balance_mismatch", "spend", fund_id, false)
	var saved: Dictionary = store.save_state(candidate, decorations)
	if not saved.ok:
		return _fund_result(false, "save_" + str(saved.kind), "spend", fund_id, false)
	farm.accept(candidate)
	shared_changed.emit()
	var funds_saved: Dictionary = funds_store.save_state(candidate_funds)
	if not funds_saved.ok:
		return _fund_result(false, "save_funds_" + str(funds_saved.kind),
			"spend", fund_id, false)
	funds = candidate_funds
	return _fund_result(true, "", "spend", fund_id, false)


func _rotate_fund_keeper(actor: String, args: Dictionary, command_id: String) -> Dictionary:
	var fund_id: String = _fund_id_from_args(args)
	var row: Dictionary = _fund_row(fund_id)
	if row.is_empty():
		return _fund_result(false, "unknown_fund", "rotate", fund_id, false)
	var new_keeper: Variant = args.get("new_keeper")
	var outcome: Dictionary = PublicFund.rotate_keeper(funds, fund_id, actor, new_keeper)
	if not bool(outcome.get("ok", false)):
		return _fund_result(false, str(outcome.get("reason", "")),
			"rotate", fund_id, false)
	# 新 keeper 必须仍是组织成员；规则只要求新 keeper 是基金缴入者。
	var membership: String = _org_membership_reason(
		str(row.get("org_id", "")), str(new_keeper))
	if not membership.is_empty():
		return _fund_result(false, membership, "rotate", fund_id, false)
	var candidate: Dictionary = outcome.state
	if not _fund_balance_invariant(candidate, farm):
		return _fund_result(false, "balance_mismatch", "rotate", fund_id, false)
	var saved: Dictionary = funds_store.save_state(candidate)
	if not saved.ok:
		return _fund_result(false, "save_funds_" + str(saved.kind),
			"rotate", fund_id, false)
	funds = candidate
	return _fund_result(true, "", "rotate", fund_id, false)


## 农场侧已提交、基金文档缺失时的补写。账本分录已证明转账，这里只把同一规则
## 重新应用到旧基金文档并落盘；不调用 economy_pay，因此不可能二次转移现金。
func _commit_recovered_funds(candidate: Dictionary, action: String,
		fund_id: String) -> Dictionary:
	if not _fund_balance_invariant(candidate, farm):
		return _fund_result(false, "balance_mismatch", action, fund_id, false)
	var saved: Dictionary = funds_store.save_state(candidate)
	if not saved.ok:
		return _fund_result(false, "save_funds_" + str(saved.kind), action, fund_id, false)
	funds = candidate
	return _fund_result(true, "", action, fund_id, true)


func _replay_fund(command_id: String, payload: String) -> Dictionary:
	var entry: Variant = _fund_results.get(command_id)
	if not entry is Dictionary:
		return {}
	var first: Variant = (entry as Dictionary).get("result")
	if not first is Dictionary:
		return {}
	var stored: Dictionary = first
	if str((entry as Dictionary).get("payload", "")) != payload:
		return _fund_result(false, "command_conflict",
			str(stored.get("action", "")), str(stored.get("fund_id", "")), false)
	return _fund_result(bool(stored.get("ok", false)), str(stored.get("reason", "")),
		str(stored.get("action", "")), str(stored.get("fund_id", "")), true)


func _remember_fund_command(command_id: String, payload: String,
		result: Dictionary) -> void:
	_fund_results[command_id] = {"payload": payload, "result": result.duplicate(true)}
	while _fund_results.size() > MAX_FUND_RESULTS:
		_fund_results.erase(_fund_results.keys()[0])


static func _fund_result(ok: bool, reason: String, action: String,
		fund_id: String, duplicate: bool) -> Dictionary:
	return {
		"ok": ok, "reason": reason, "action": action,
		"fund_id": fund_id, "duplicate": duplicate,
	}


static func _valid_fund_command_id(value: String) -> bool:
	return not value.is_empty() and value.length() <= FarmCommand.MAX_ID_LENGTH


static func _fund_id_from_args(args: Dictionary) -> String:
	var fund_id: String = str(args.get("fund_id", ""))
	if not fund_id.is_empty():
		return fund_id
	var org_id: String = str(args.get("org_id", ""))
	if org_id.is_empty():
		return ""
	return PublicFund.fund_for(org_id)


func _fund_row(fund_id: String) -> Dictionary:
	var funds_value: Variant = funds.get("funds")
	if not funds_value is Dictionary:
		return {}
	var row_value: Variant = (funds_value as Dictionary).get(fund_id)
	if row_value is Dictionary:
		return row_value
	return {}


## 饲料/缴入/支出之后，每支基金的账面余额必须等于其组织真实账户现金。加载与
## 每次提交都用同一份检查；不一致时拒绝而不是静默创造或抹掉资金。
func _fund_balance_invariant(source_funds: Dictionary, source_farm: RefCounted) -> bool:
	if source_farm == null:
		return false
	var funds_value: Variant = source_funds.get("funds")
	if not funds_value is Dictionary:
		return false
	var by_id: Dictionary = funds_value
	for fund_id: Variant in by_id:
		var row_value: Variant = by_id[fund_id]
		if not row_value is Dictionary:
			return false
		var row: Dictionary = row_value
		if int(row.get("balance", -1)) != source_farm.economy_cash(
				PublicFund.account_for(str(row.get("org_id", "")))):
			return false
	return true


func _funds_match_farm(source_farm: RefCounted) -> bool:
	return _fund_balance_invariant(funds, source_farm)


func _fund_balance_matches_row(fund_id: String, source_farm: RefCounted) -> bool:
	var row: Dictionary = _fund_row(fund_id)
	if row.is_empty() or source_farm == null:
		return false
	return int(row.get("balance", -1)) == source_farm.economy_cash(
		PublicFund.account_for(str(row.get("org_id", ""))))


## 组织当前职位是否允许支出。使用 `OrganizationState` 的同一份角色权限表，不新建
## 权限表；未知组织、非成员与无支出权分别具名。
func _org_spend_permission(org_id: String, actor: String) -> String:
	var organizations_value: Variant = organizations.get("organizations")
	if org_id.is_empty() or not organizations_value is Dictionary \
			or not (organizations_value as Dictionary).has(org_id):
		return "unknown_org"
	var role: String = Organization.role_of(organizations, org_id, actor)
	if role.is_empty():
		return "not_member"
	var permissions: Variant = Organization.ROLE_PERMISSIONS.get(role)
	if not permissions is Dictionary \
			or not bool((permissions as Dictionary).get("can_spend", false)):
		return "role_forbidden"
	return ""


func _org_membership_reason(org_id: String, player_id: String) -> String:
	var organizations_value: Variant = organizations.get("organizations")
	if org_id.is_empty() or not organizations_value is Dictionary \
			or not (organizations_value as Dictionary).has(org_id):
		return "unknown_org"
	if Organization.role_of(organizations, org_id, player_id).is_empty():
		return "not_member"
	return ""


## 只读的公共项目视图。项目类型、地块、承诺与固定成本覆盖额、状态和建成时间
## 都是公开事实；命令记录与内部重放结构都不下发。按项目 id 排序，相同项目集合
## 产生逐字节相同的载荷。
func public_works_view() -> Dictionary:
	var rows: Array = []
	var projects_value: Variant = public_works.get("projects")
	if projects_value is Dictionary:
		var by_id: Dictionary = projects_value
		for project_id: String in by_id.keys():
			var row_value: Variant = by_id[project_id]
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			rows.append({
				"project_id": project_id,
				"kind": str(row.get("kind", "")),
				"parcel_id": str(row.get("parcel_id", "")),
				"funded": int(row.get("funded", 0)),
				"pledged": int(row.get("pledged", 0)),
				"status": str(row.get("status", "")),
				"built_utc": float(row.get("built_utc", 0.0)),
			})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.project_id) < str(b.project_id))
	return {"projects": rows}


## 通过权威时钟执行一次公共项目操作。操作者由调用方（连接层）解析传入，参数里
## 的任何 actor/owner 字段都不参与授权。open/pledge/release 只写项目文档，不动
## 现金；build 先由 `execute_fund("spend")` 把组织账户现金真实转入 `@world`，成功
## 后才用同一权威时刻标记建成并保存项目文档。同一命令 id 的即时重放返回首次结果
## 并标记 `duplicate`；跨重启的 build 重试由账本分录与基金 history 补写，绝不二次
## 支出。
func execute_public_works(action: String, actor: String, args: Dictionary,
		command_id: String) -> Dictionary:
	if public_works_store == null or farm == null:
		return _public_works_result(false, "not_open", action, "", false)
	if action == "state":
		return {
			"ok": true, "reason": "", "action": "state", "project_id": "",
			"duplicate": false, "state": public_works_view(),
		}
	if action != "open" and action != "pledge" and action != "release" \
			and action != "build":
		return _public_works_result(false, "unknown_action", action, "", false)
	if not _valid_fund_command_id(command_id):
		return _public_works_result(false, "invalid_command", action, "", false)
	if actor.is_empty():
		return _public_works_result(false, "invalid_player", action, "", false)
	var project_id: String = str(args.get("project_id", ""))
	# 项目文档的 `state` 形状必须保持严格，且本切片不在文档里另存命令表：重放
	# 窗口只存在内存里，payload 由动作、操作者与参数直接生成。
	var payload: String = JSON.stringify([action, actor, args])
	var replayed: Dictionary = _replay_public_works(command_id, payload)
	if not replayed.is_empty():
		return replayed
	var result: Dictionary
	match action:
		"open":
			result = _open_public_works(args)
		"pledge":
			result = _pledge_public_works(args, false)
		"release":
			result = _pledge_public_works(args, true)
		_:
			result = _build_public_works(actor, args, command_id)
	if bool(result.get("ok", false)):
		_remember_public_works_command(command_id, payload, result)
	return result


func _open_public_works(args: Dictionary) -> Dictionary:
	var project_id: String = str(args.get("project_id", ""))
	var parcel: Variant = args.get("parcel_id", "")
	if parcel == null:
		parcel = ""
	var outcome: Dictionary = PublicWorks.open_project(public_works,
		args.get("project_id", ""), args.get("kind", ""), parcel)
	if not bool(outcome.get("ok", false)):
		return _public_works_result(false, str(outcome.get("reason", "")),
			"open", project_id, false)
	return _commit_public_works(outcome.state, "open", project_id, false)


func _pledge_public_works(args: Dictionary, release: bool) -> Dictionary:
	var action: String = "release" if release else "pledge"
	var project_id: String = str(args.get("project_id", ""))
	var amount: Variant = args.get("amount")
	var outcome: Dictionary
	if release:
		outcome = PublicWorks.release_pledge(public_works,
			args.get("project_id", ""), amount)
	else:
		outcome = PublicWorks.pledge(public_works, args.get("project_id", ""), amount)
	if not bool(outcome.get("ok", false)):
		return _public_works_result(false, str(outcome.get("reason", "")),
			action, project_id, false)
	return _commit_public_works(outcome.state, action, project_id, false)


## 建成一个已足额的项目。支出金额固定取自 `PublicWorks.cost_of(kind)`，客户端
## 传入的 amount 不参与计算。跨文档顺序：真实转账（农场落盘）→ 基金文档 →
## 项目文档。项目保存失败时现金已经支出，重试只会补写项目，不会再付一次。
func _build_public_works(actor: String, args: Dictionary,
		command_id: String) -> Dictionary:
	var project_id: String = str(args.get("project_id", ""))
	var projects_value: Variant = public_works.get("projects")
	if not projects_value is Dictionary \
			or not (projects_value as Dictionary).has(project_id):
		return _public_works_result(false, "unknown_project", "build", project_id, false)
	var row: Dictionary = (projects_value as Dictionary)[project_id]
	var cost: int = PublicWorks.cost_of(row.get("kind"))
	if cost <= 0:
		return _public_works_result(false, "invalid_state", "build", project_id, false)
	var status: String = str(row.get("status", ""))
	# 未足额在定位基金之前就拒绝：项目状态是项目文档事实，与付款基金无关。
	if status != PublicWorks.STATUS_BUILT and status != PublicWorks.STATUS_FUNDED:
		return _public_works_result(false, "underfunded", "build", project_id, false)
	var fund_id: String = _fund_id_from_args(args)
	var fund_row: Dictionary = _fund_row(fund_id)
	if fund_row.is_empty():
		# 已建成的项目不因付款参数缺失而改变；它不会再支出任何现金。
		if status == PublicWorks.STATUS_BUILT:
			return _public_works_result(false, "already_built", "build", project_id, false)
		return _public_works_result(false, "unknown_fund", "build", project_id, false)
	var org_account: String = PublicFund.account_for(str(fund_row.get("org_id", "")))
	# `fund_spend_<inner_id>` 是农场账本里现金已支出的耐久标记。build 内部命令
	# id 是 `pw_spend_<id>`，因此完整分录 id 见下。金额、付款方与 @world 收款
	# 三方都必须匹配，才能把这次命令当成已支出。
	var event_id: String = "fund_spend_pw_spend_" + command_id
	var marker: Dictionary = _ledger_payment_marker(event_id,
		org_account, Economy.WORLD_OWNER)
	if status == PublicWorks.STATUS_BUILT:
		# 同一 build 命令在重启后的重放：项目已建成，基金历史与账本分录都指向
		# 这笔固定成本，返回 duplicate。金额或项目对不上则是同 id 换参数。
		if marker.is_empty():
			return _public_works_result(false, "already_built", "build", project_id, false)
		if int(marker.get("amount", -1)) != cost \
				or not _public_works_history_has(fund_id, project_id, cost):
			return _public_works_result(false, "command_conflict", "build", project_id, false)
		return _public_works_result(true, "", "build", project_id, true)
	# 现金可能已经支出（基金文档或项目文档保存失败后的重试）。账本金额与固定
	# 成本不一致说明同 id 被换成另一笔支出，必须拒绝且不再动现金。
	if not marker.is_empty() and int(marker.get("amount", -1)) != cost:
		return _public_works_result(false, "command_conflict", "build", project_id, false)
	var inner_id: String = "pw_spend_" + command_id
	var spent: Dictionary = execute_fund("spend", actor, {
		"fund_id": fund_id,
		"project_id": project_id,
		"amount": cost,
		"command_id": inner_id,
	}, inner_id)
	if not bool(spent.get("ok", false)):
		# 非 keeper、无组织支出权、余额不足等失败都在转账之前，现金与项目不变。
		return _public_works_result(false, str(spent.get("reason", "")),
			"build", project_id, false)
	# 正常提交与 `execute_fund` 的标记补写都会让基金 history 出现这笔项目支出。
	# 对不上说明账本分录属于另一套参数，不能借机把别的项目标成建成。
	if not _public_works_history_has(fund_id, project_id, cost):
		return _public_works_result(false, "command_conflict", "build", project_id, false)
	# 建成时间取这笔支出在账本里的权威时刻；重试补写时也复用首次付款时间，
	# 而不是让重试时刻改写项目事实。缺少分录（理论上不会发生）才退回当前时钟。
	var settled: Dictionary = _ledger_payment_marker(event_id,
		org_account, Economy.WORLD_OWNER)
	var now: float = float(settled.get("at_utc", 0.0)) if not settled.is_empty() \
		else authority_now_utc()
	var outcome: Dictionary = PublicWorks.mark_built(public_works, project_id, now)
	if not bool(outcome.get("ok", false)):
		return _public_works_result(false, str(outcome.get("reason", "")),
			"build", project_id, false)
	return _commit_public_works(outcome.state, "build", project_id, false)


func _commit_public_works(candidate: Dictionary, action: String,
		project_id: String, duplicate: bool) -> Dictionary:
	var saved: Dictionary = public_works_store.save_state(candidate)
	if not saved.ok:
		return _public_works_result(false, "save_public_works_" + str(saved.kind),
			action, project_id, duplicate)
	public_works = candidate
	return _public_works_result(true, "", action, project_id, duplicate)


func _replay_public_works(command_id: String, payload: String) -> Dictionary:
	var entry: Variant = _public_works_results.get(command_id)
	if not entry is Dictionary:
		return {}
	var first: Variant = (entry as Dictionary).get("result")
	if not first is Dictionary:
		return {}
	var stored: Dictionary = first
	if str((entry as Dictionary).get("payload", "")) != payload:
		return _public_works_result(false, "command_conflict",
			str(stored.get("action", "")), str(stored.get("project_id", "")), false)
	return _public_works_result(bool(stored.get("ok", false)),
		str(stored.get("reason", "")), str(stored.get("action", "")),
		str(stored.get("project_id", "")), true)


func _remember_public_works_command(command_id: String, payload: String,
		result: Dictionary) -> void:
	_public_works_results[command_id] = {"payload": payload, "result": result.duplicate(true)}
	while _public_works_results.size() > MAX_PUBLIC_WORKS_RESULTS:
		_public_works_results.erase(_public_works_results.keys()[0])


static func _public_works_result(ok: bool, reason: String, action: String,
		project_id: String, duplicate: bool) -> Dictionary:
	return {
		"ok": ok, "reason": reason, "action": action,
		"project_id": project_id, "duplicate": duplicate,
	}


## 基金 history 是否已经记录了该项目的这笔固定成本支出。history 行不含命令 id，
## 因此这里同时核对项目与金额；命令身份由账本 `fund_spend_...` 分录确认。
func _public_works_history_has(fund_id: String, project_id: String, cost: int) -> bool:
	var row: Dictionary = _fund_row(fund_id)
	if row.is_empty():
		return false
	var history_value: Variant = row.get("history")
	if not history_value is Array:
		return false
	for entry_value: Variant in history_value:
		if not entry_value is Dictionary:
			continue
		var entry: Dictionary = entry_value
		if str(entry.get("kind", "")) != PublicFund.HISTORY_KIND_SPEND:
			continue
		if str(entry.get("project", "")) == project_id \
				and int(entry.get("amount", -1)) == cost:
			return true
	return false


## 只读参与制度视图：风险声明、区域、窗口、成员同意与已结算损失都是公开的
## 房间事实。不下发命令窗口、命令载荷或内部重放结构。
func participation_view() -> Dictionary:
	if participation.is_empty():
		return {
			"available": false, "host": "", "sequence": 0,
			"now_utc": authority_now_utc(), "regime": {},
			"areas": [], "windows": [], "participants": [], "losses": [],
		}
	var regime_value: Variant = participation.get("regime")
	var regime: Dictionary = {}
	if regime_value is Dictionary:
		var source: Dictionary = regime_value
		regime = {
			"tier": str(source.get("tier", Participation.TIER_PEACE)),
			"revision": int(source.get("revision", 0)),
			"declaration_id": str(source.get("declaration_id", "")),
			"declared_by": str(source.get("declared_by", "")),
			"declared_utc": float(source.get("declared_utc", 0.0)),
			"effective_utc": float(source.get("effective_utc", 0.0)),
			"higher_risk": bool(source.get("higher_risk", false)),
			"area_ids": _sorted_strings(source.get("area_ids")),
			"window_ids": _sorted_strings(source.get("window_ids")),
			"loss_cap": int(source.get("loss_cap", 0)),
			"offline_loss_cap": int(source.get("offline_loss_cap", 0)),
		}
	var areas: Array = []
	var areas_value: Variant = participation.get("areas")
	if areas_value is Dictionary:
		for area_id: String in (areas_value as Dictionary).keys():
			var row_value: Variant = (areas_value as Dictionary)[area_id]
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			areas.append({
				"id": area_id, "min_x": int(row.get("min_x", 0)),
				"min_z": int(row.get("min_z", 0)), "max_x": int(row.get("max_x", 0)),
				"max_z": int(row.get("max_z", 0)),
			})
	areas.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.id) < str(b.id))
	var windows: Array = []
	var windows_value: Variant = participation.get("windows")
	if windows_value is Dictionary:
		for window_id: String in (windows_value as Dictionary).keys():
			var row_value: Variant = (windows_value as Dictionary)[window_id]
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			windows.append({
				"id": window_id, "start_utc": float(row.get("start_utc", 0.0)),
				"end_utc": float(row.get("end_utc", 0.0)),
			})
	windows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.id) < str(b.id))
	var participants: Array = []
	var participants_value: Variant = participation.get("participants")
	if participants_value is Dictionary:
		for player_id: String in (participants_value as Dictionary).keys():
			var row_value: Variant = (participants_value as Dictionary)[player_id]
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			participants.append({
				"participant": player_id,
				"attacker": bool(row.get("attacker", false)),
				"defender": bool(row.get("defender", false)),
				"consent_revision": int(row.get("consent_revision", 0)),
				"consent_utc": float(row.get("consent_utc", 0.0)),
				"withdraw_utc": float(row.get("withdraw_utc", 0.0)),
				"withdraw_effective_utc": float(row.get("withdraw_effective_utc", 0.0)),
			})
	participants.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.participant) < str(b.participant))
	var losses: Array = []
	var losses_value: Variant = participation.get("losses")
	if losses_value is Dictionary:
		for key: String in (losses_value as Dictionary).keys():
			var row_value: Variant = (losses_value as Dictionary)[key]
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			losses.append({
				"target": str(row.get("target", "")),
				"window_id": str(row.get("window_id", "")),
				"amount": int(row.get("amount", 0)),
			})
	losses.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if str(a.target) != str(b.target):
			return str(a.target) < str(b.target)
		return str(a.window_id) < str(b.window_id))
	return {
		"available": true,
		"host": str(participation.get("host", "")),
		"sequence": int(participation.get("sequence", 0)),
		# 客户端出生时钟与世界时钟可能不同（生长时钟只随农事推进）。声明时间
		# 由权威比较，所以视图直接带上权威当前时刻，客户端不必猜。
		"now_utc": authority_now_utc(),
		"regime": regime,
		"areas": areas,
		"windows": windows,
		"participants": participants,
		"losses": losses,
	}


## 通过权威时钟执行一次参与制度操作。操作者由调用方（连接层）解析传入，参数里的
## actor/host 字段都不参与授权；房主判定仍由规则拿文档里的 `host` 比较。规则在
## 副本上计算，保存成功后才替换活文档；失败不写盘、不改内存。
func execute_participation(action: String, actor: String, args: Dictionary,
		command_id: String) -> Dictionary:
	if participation_store == null or farm == null:
		return _participation_result(false, "not_open", action, false)
	if participation.is_empty():
		return _participation_result(false, "no_host", action, false)
	if action == "state":
		return {
			"ok": true, "reason": "", "action": "state", "duplicate": false,
			"state": participation_view(),
		}
	if action != "regime" and action != "declare" and action != "withdraw":
		return _participation_result(false, "unknown_action", action, false)
	if not _valid_participation_command_id(command_id):
		return _participation_result(false, "invalid_command", action, false)
	var candidate: Dictionary = participation.duplicate(true)
	var now: float = _participation_action_time(action, actor, command_id)
	var result: Dictionary
	match action:
		"regime":
			result = Participation.declare_regime(candidate, world_id, actor,
				args.get("declaration"), command_id, now)
		"declare":
			result = Participation.declare_participation(candidate, world_id, actor,
				str(args.get("role", "")), command_id, now)
		_:
			result = Participation.withdraw(candidate, world_id, actor, command_id, now)
	if not bool(result.get("ok", false)):
		return _participation_result(false, str(result.get("reason", "")), action,
			false, result)
	if not bool(result.get("duplicate", false)):
		var saved: Dictionary = participation_store.save_state(candidate)
		if not saved.ok:
			return _participation_result(false,
				"save_participation_" + str(saved.kind), action, false)
		participation = candidate
	return _participation_result(true, "", action,
		bool(result.get("duplicate", false)), result)


## 同一命令 id 的重试必须复用首次时间：规则把时间写进幂等载荷，若每次取新时钟，
## 同参数重试会被误判成 command_conflict，网络的正常重试与换参数冲突就不可区分。
## 声明/同意/退战都把首个 command id 与时间持久化在同一份文档里，重启后仍成立；
## 只有 id 对得上时才复用旧时间，规则随即走自己的重放分支。
func _participation_action_time(action: String, actor: String,
		command_id: String) -> float:
	if participation.is_empty():
		return authority_now_utc()
	if action == "regime":
		var regime_value: Variant = participation.get("regime")
		if regime_value is Dictionary \
				and str((regime_value as Dictionary).get("command_id", "")) == command_id:
			return float((regime_value as Dictionary).get("declared_utc", 0.0))
	elif action == "declare" or action == "withdraw":
		var participants_value: Variant = participation.get("participants")
		if participants_value is Dictionary:
			var row_value: Variant = (participants_value as Dictionary).get(actor)
			if row_value is Dictionary:
				var row: Dictionary = row_value
				var id_key: String = "consent_command_id" if action == "declare" \
					else "withdraw_command_id"
				var stamp_key: String = "consent_utc" if action == "declare" \
					else "withdraw_utc"
				if str(row.get(id_key, "")) == command_id:
					return float(row.get(stamp_key, 0.0))
	# 命令已被后续制度或退战取代，但仍留在 `command_results` 窗口里：同 id 重试
	# 必须复用首次时间，否则权威时钟前进会把正常重试判成 command_conflict。
	var recorded: float = _participation_recorded_time(action, actor, command_id)
	if recorded >= 0.0:
		return recorded
	return authority_now_utc()


## 从规则保存的命令载荷里取出首次执行时间。载荷是固定形状的 JSON 数组：
## regime `[kind, world_id, actor, declared_utc, declaration]`，declare
## `[kind, world_id, actor, role, consent_utc]`，withdraw
## `[kind, world_id, actor, withdraw_utc]`。类型、世界和操作者必须都对上。
func _participation_recorded_time(action: String, actor: String,
		command_id: String) -> float:
	var results_value: Variant = participation.get("command_results")
	if not results_value is Dictionary:
		return -1.0
	var entry_value: Variant = (results_value as Dictionary).get(command_id)
	if not entry_value is Dictionary:
		return -1.0
	var payload_value: Variant = (entry_value as Dictionary).get("payload")
	if not payload_value is String:
		return -1.0
	var parts: Variant = JSON.parse_string(payload_value)
	if not parts is Array:
		return -1.0
	var values: Array = parts
	var kind: String = ""
	var time_index: int = -1
	match action:
		"regime":
			kind = Participation.KIND_REGIME
			time_index = 3
		"declare":
			kind = Participation.KIND_PARTICIPATE
			time_index = 4
		"withdraw":
			kind = Participation.KIND_WITHDRAW
			time_index = 3
		_:
			return -1.0
	if values.size() <= time_index or str(values[0]) != kind \
			or str(values[1]) != world_id or str(values[2]) != actor:
		return -1.0
	var value: Variant = values[time_index]
	if not value is float and not value is int:
		return -1.0
	var at_utc: float = float(value)
	return at_utc if _valid_time(at_utc) else -1.0


func _participation_result(ok: bool, reason: String, action: String, duplicate: bool,
		extra: Dictionary = {}) -> Dictionary:	return {
		"ok": ok, "reason": reason, "action": action, "duplicate": duplicate,
		"subject": str(extra.get("subject", "")),
		"window_id": str(extra.get("window_id", "")),
		"loss_total": int(extra.get("loss_total", 0)),
		"cap": int(extra.get("cap", 0)),
	}


func _valid_participation_command_id(value: String) -> bool:
	return not value.is_empty() and value.length() <= Participation.MAX_COMMAND_ID_LENGTH


static func _sorted_strings(value: Variant) -> Array:
	var rows: Array = []
	if value is Array:
		for entry: Variant in value:
			rows.append(str(entry))
	rows.sort()
	return rows


## 只读纠纷视图。管理员（文档花名册里的 admin/arbiter）看全部案件；普通玩家
## 只看与自身相关的案件（立案人、被举报人或证据提交人）；没有任何玩家身份的
## 连接只看公开状态行。公开行只含案件编号、状态与立案时间，不下发证据、裁定、
## 申诉或审计细节。相同输入产生逐字节相同的视图。
func disputes_view(viewer: String = "") -> Dictionary:
	var roles: Dictionary = {}
	var roles_value: Variant = disputes.get("authority_roles")
	if roles_value is Dictionary:
		roles = roles_value
	var authority: bool = _dispute_is_authority(roles, viewer)
	var rows: Array = []
	var public_rows: Array = []
	var cases_value: Variant = disputes.get("cases")
	if cases_value is Dictionary:
		var by_id: Dictionary = cases_value
		var case_ids: Array = by_id.keys()
		case_ids.sort()
		for case_id_value: Variant in case_ids:
			var case_id: String = str(case_id_value)
			var row_value: Variant = by_id[case_id_value]
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			public_rows.append({
				"case_id": case_id,
				"status": str(row.get("status", "")),
				"filed_utc": float(row.get("filed_utc", 0.0)),
			})
			if authority or _dispute_related(row, viewer):
				var full: Dictionary = row.duplicate(true)
				full["case_id"] = case_id
				rows.append(full)
	return {
		"available": not disputes.is_empty(),
		"now_utc": authority_now_utc(),
		"viewer": viewer,
		"is_authority": authority,
		"authority_roles": roles.duplicate(true),
		"cases": rows,
		"public": public_rows,
	}


static func _dispute_is_authority(roles: Dictionary, player: String) -> bool:
	if player.is_empty():
		return false
	for key: String in Disputes.ROLE_KEYS:
		var ids: Variant = roles.get(key)
		if ids is Array and (ids as Array).has(player):
			return true
	return false


static func _dispute_related(row: Dictionary, viewer: String) -> bool:
	if viewer.is_empty():
		return false
	if str(row.get("filed_by", "")) == viewer or str(row.get("against", "")) == viewer:
		return true
	var evidence_value: Variant = row.get("evidence")
	if evidence_value is Array:
		for item: Variant in evidence_value:
			if item is Dictionary \
					and str((item as Dictionary).get("submitted_by", "")) == viewer:
				return true
	return false


## 通过权威时钟执行一次纠纷操作。操作者由连接层解析传入，参数里的
## actor/submitted_by 一律不参与授权或归属；证据的提交人与时间也由权威重写。
## 规则在副本上计算，保存成功后才替换活文档；保存失败不写盘、不改内存。
##
## 只读 `state`/`view` 对成员开放（含访客与匿名成员）。`file`、`evidence` 和
## `appeal` 是当事人动作；`accept`、`reject`、`rule`（权威模式）、`correct` 和
## `close` 只认文档花名册里的 admin/arbiter，其他身份统一返回 `forbidden`。
## `advisor: true` 的裁定在读取案件前结束，固定返回 `advisory_only` 且零变化。
func execute_dispute(action: String, actor: String, args: Dictionary,
		command_id: String) -> Dictionary:
	if disputes_store == null or farm == null:
		return _dispute_result(false, "not_open", action, "", false, "")
	if action == "state" or action == "view":
		return {
			"ok": true, "reason": "", "action": action, "case_id": "",
			"duplicate": false, "status": "", "state": disputes_view(actor),
		}
	if disputes.is_empty():
		return _dispute_result(false, "no_host", action,
			str(args.get("case_id", "")), false, "")
	if not DISPUTE_ACTIONS.has(action):
		return _dispute_result(false, "unknown_action", action,
			str(args.get("case_id", "")), false, "")
	if not _valid_dispute_command_id(command_id):
		return _dispute_result(false, "invalid_command", action,
			str(args.get("case_id", "")), false, "")
	if not _valid_dispute_player(actor):
		return _dispute_result(false, "invalid_player", action,
			str(args.get("case_id", "")), false, "")
	# 重放窗口只存在内存里：同一命令 id 的即时重试返回首次结果，换参数拒绝。
	var payload: String = JSON.stringify([action, actor, args])
	var replayed: Dictionary = _replay_dispute(command_id, payload)
	if not replayed.is_empty():
		return replayed
	var result: Dictionary
	match action:
		"file":
			result = _file_dispute(actor, args)
		"accept":
			result = _decide_dispute(action, actor, args)
		"reject":
			result = _decide_dispute(action, actor, args)
		"evidence":
			result = _evidence_dispute(actor, args)
		"rule":
			result = _rule_dispute(actor, args)
		"appeal":
			result = _appeal_dispute(actor, args)
		"correct":
			result = _correct_dispute(actor, args)
		_:
			result = _close_dispute(actor, args)
	if not bool(result.get("ok", false)) or bool(result.get("duplicate", false)):
		return result
	# 规则成功后才把候选与命令日志放进同一次原子保存。保存失败时活文档与内存
	# 重放窗口都保持操作前的状态，不会出现“状态已写、重放窗口没写”的半提交。
	var candidate_value: Variant = result.get("candidate")
	if not candidate_value is Dictionary:
		return _dispute_result(false, "invalid_state", action,
			str(result.get("case_id", "")), false, "")
	var candidate: Dictionary = candidate_value
	var final_result: Dictionary = _dispute_result(true, "", action,
		str(result.get("case_id", "")), false, str(result.get("status", "")))
	var journal: Array = _dispute_journal_with(command_id, payload, final_result)
	var compensation_value: Variant = result.get("compensation")
	if compensation_value is Dictionary:
		return _commit_dispute_compensation(action, candidate, journal,
			final_result, compensation_value)
	var saved: Dictionary = disputes_store.save_state(candidate, journal,
		_dispute_enforcement)
	if not saved.ok:
		return _dispute_result(false, "save_disputes_" + str(saved.kind), action,
			str(final_result.get("case_id", "")), false, "")
	disputes = candidate
	_sync_dispute_journal(journal)
	return final_result


## 裁定补偿的两文档提交。顺序固定为 disputes 先、farm 后：
##
## 1. 案件、命令日志和 `paid=false` 的补偿记录一次原子写入 disputes.json；
## 2. 农场候选用同一权威时刻完成一笔平衡转账，再原子写入 farm.json；
## 3. 转账落盘后才把 `paid` 改为真并再次保存 disputes.json。
##
## 任一步失败都不会把农场候选留在内存里。第 2 步失败时回滚第 1 步；如果回滚
## 也失败，重启时的 `_recover_dispute_compensations()` 会按 `paid=false` 记录
## 补付。第 3 步失败时案件与现金已经同时生效，内存接受同一次结果；重启后
## 账本事件仍在，恢复只补写 paid 标记，不会二次转账。
func _commit_dispute_compensation(action: String, candidate: Dictionary,
		journal: Array, final_result: Dictionary,
		compensation: Dictionary) -> Dictionary:
	var case_id: String = str(final_result.get("case_id", ""))
	var payer: String = str(compensation.get("from", ""))
	var payee: String = str(compensation.get("to", ""))
	var amount: int = int(compensation.get("amount", 0))
	var at_utc: float = float(compensation.get("at_utc", 0.0))
	var enforcement: Dictionary = _dispute_enforcement.duplicate(true)
	enforcement[case_id] = {"amount": amount, "at_utc": at_utc, "paid": false}
	var saved: Dictionary = disputes_store.save_state(candidate, journal, enforcement)
	if not saved.ok:
		return _dispute_result(false, "save_disputes_" + str(saved.kind), action,
			case_id, false, "")
	var existing: Dictionary = _dispute_compensation_entry(case_id)
	if not existing.is_empty():
		# An interrupted earlier attempt already moved the exact amount. Do not
		# move it again; only write the durable paid marker with this case state.
		if not _dispute_compensation_matches_entry(existing, payer, payee, amount):
			_rollback_dispute_save()
			return _dispute_result(false, "compensation_conflict", action,
				case_id, false, "")
	else:
		var farm_candidate: RefCounted = farm.copy()
		var paid: Dictionary = farm_candidate.economy_authority_pay(payer, payee,
			amount, _dispute_compensation_event(case_id), at_utc)
		if not bool(paid.get("ok", false)):
			_rollback_dispute_save()
			return _dispute_result(false, "compensation_" + str(paid.get("reason", "")),
				action, case_id, false, "")
		var farm_saved: Dictionary = store.save_state(farm_candidate, decorations)
		if not farm_saved.ok:
			_rollback_dispute_save()
			return _dispute_result(false, "save_compensation_" + str(farm_saved.kind),
				action, case_id, false, "")
		farm.accept(farm_candidate)
	# The transfer is durable. A crash before the flag update is handled on open.
	enforcement[case_id]["paid"] = true
	# The case and cash are already durable. If this marker save fails, keep the
	# in-memory paid flag so the next successful save repairs it, and still report
	# success: a failure reply would invite a duplicate ruling attempt.
	disputes_store.save_state(candidate, journal, enforcement)
	disputes = candidate
	_sync_dispute_journal(journal)
	_dispute_enforcement = enforcement
	shared_changed.emit()
	return final_result


## Best-effort rollback of the first disputes write after the farm leg failed.
## The in-memory document was never replaced, so this rewrites exactly it. A
## failed rollback leaves a `paid=false` record that the next open repairs.
func _rollback_dispute_save() -> void:
	disputes_store.save_state(disputes, _dispute_journal_rows(), _dispute_enforcement)


## 立案。案件 id 重复由规则返回 `duplicate_case`；同一命令 id 的重放已经在
## 内存与持久化命令日志里提前返回。
func _file_dispute(actor: String, args: Dictionary) -> Dictionary:
	var case_id: String = str(args.get("case_id", ""))
	var against: String = str(args.get("against", ""))
	var event_ids: Variant = args.get("event_ids", [])
	var outcome: Dictionary = Disputes.file(disputes, case_id, actor, against,
		event_ids, authority_now_utc())
	if not bool(outcome.get("ok", false)):
		return _apply_dispute(outcome, "file", case_id)
	# 规则层只校验事件 id 的格式、非空和唯一；事件是否真的发生过必须由权威
	# 现有的世界日志确认：已接受的农场/经济命令、交战 consumed 与账本审计。
	# 客户端不能用一个自报编号或另一个世界的历史来立案。
	for event_id: Variant in event_ids:
		if not _dispute_event_exists(str(event_id)):
			return _dispute_result(false, "unknown_event", "file", case_id, false, "")
	return _apply_dispute(outcome, "file", case_id)


## 权威事件核验。三个来源都是世界已有的持久事实，且都归属于当前 world：
## `farm.command_result()` 是已接受命令的有界日志，`conflicts.consumed` 是已
## 落盘交战的命令表，经济账本的 `event_id` 是更长的审计链。它们都不是客户端
## 自报数据，也没有引入新的外部事件源。
func _dispute_event_exists(event_id: String) -> bool:
	if event_id.is_empty() or farm == null:
		return false
	if not farm.command_result(event_id).is_empty():
		return true
	var consumed_value: Variant = conflicts.get("consumed")
	if consumed_value is Dictionary and (consumed_value as Dictionary).has(event_id):
		return true
	for entry_value: Variant in farm.economy_ledger_entries():
		if entry_value is Dictionary \
				and str((entry_value as Dictionary).get("event_id", "")) == event_id:
			return true
	return false


## 受理或驳回。重复执行由规则返回 `invalid_status`；命令重放由命令日志返回。
func _decide_dispute(action: String, actor: String, args: Dictionary) -> Dictionary:
	var case_id: String = str(args.get("case_id", ""))
	var outcome: Dictionary
	if action == "accept":
		outcome = Disputes.accept(disputes, case_id, actor, authority_now_utc())
	else:
		outcome = Disputes.reject(disputes, case_id, actor, authority_now_utc())
	return _apply_dispute(outcome, action, case_id)


## 提交证据。`submitted_by` 与 `at_utc` 由权威重写，客户端不能冒用他人身份或
## 回填窗口外时间。重复证据 id 由规则返回 `duplicate_evidence`。
func _evidence_dispute(actor: String, args: Dictionary) -> Dictionary:
	var case_id: String = str(args.get("case_id", ""))
	var evidence: Dictionary = {
		"id": str(args.get("evidence_id", "")),
		"kind": str(args.get("kind", "")),
		"source": str(args.get("source", "")),
		"submitted_by": actor,
		"at_utc": authority_now_utc(),
	}
	return _apply_dispute(
		Disputes.submit_evidence(disputes, case_id, evidence), "evidence", case_id)


## 裁定。`advisor: true` 交给规则在读取案件前返回 `advisory_only`，不会被这里
## 的权限映射改写。
func _rule_dispute(actor: String, args: Dictionary) -> Dictionary:
	var case_id: String = str(args.get("case_id", ""))
	var decision: Variant = args.get("decision")
	# 裁定与补偿使用同一个权威时刻：重启补付时直接复用裁定时间，账本与审计
	# 指向同一次决定。
	var at_utc: float = authority_now_utc()
	var outcome: Dictionary = Disputes.rule(disputes, case_id, actor, decision, at_utc)
	var reply: Dictionary = _apply_dispute(outcome, "rule", case_id)
	if not bool(reply.get("ok", false)) or bool(reply.get("duplicate", false)):
		return reply
	# 规则成功后才检查是否需要真实补偿；建议、非法裁定和越权裁定都不会走到这里。
	if str((decision as Dictionary).outcome) != Disputes.OUTCOME_COMPENSATION:
		return reply
	var amount_value: Variant = args.get("amount")
	if not _valid_compensation_amount(amount_value):
		return _dispute_result(false, "invalid_compensation", "rule", case_id, false, "")
	var entry_value: Variant = disputes.cases.get(case_id)
	if not entry_value is Dictionary:
		return _dispute_result(false, "invalid_state", "rule", case_id, false, "")
	var entry: Dictionary = entry_value
	var payer: String = str(entry.against)
	var payee: String = str(entry.filed_by)
	# 不自动开户：开户会发行一笔新的赠款。缺少账户直接拒绝裁定，由玩家先开户。
	var snapshot: Dictionary = farm.economy_snapshot()
	if not _has_economy_account(snapshot, payer) \
			or not _has_economy_account(snapshot, payee):
		return _dispute_result(false, "compensation_no_account", "rule", case_id, false, "")
	# 明确拒绝而不是部分扣款或暗中增发；案件保持可受理前的 accepted 状态。
	if farm.economy_cash(payer) < int(amount_value):
		return _dispute_result(false, "compensation_insufficient", "rule", case_id, false, "")
	reply["compensation"] = {
		"from": payer, "to": payee, "amount": int(amount_value), "at_utc": at_utc,
	}
	return reply


func _appeal_dispute(actor: String, args: Dictionary) -> Dictionary:
	var case_id: String = str(args.get("case_id", ""))
	var reason: String = str(args.get("reason", ""))
	return _apply_dispute(
		Disputes.appeal(disputes, case_id, actor, reason, authority_now_utc()),
		"appeal", case_id)


func _correct_dispute(actor: String, args: Dictionary) -> Dictionary:
	var case_id: String = str(args.get("case_id", ""))
	var reason: String = str(args.get("reason", ""))
	return _apply_dispute(
		Disputes.correct(disputes, case_id, actor, reason, authority_now_utc()),
		"correct", case_id)


func _close_dispute(actor: String, args: Dictionary) -> Dictionary:
	var case_id: String = str(args.get("case_id", ""))
	return _apply_dispute(
		Disputes.close(disputes, case_id, actor, authority_now_utc()),
		"close", case_id)


## 规则成功时只把候选交回 `execute_dispute()`；保存与命令日志由那里一次完成。
## `not_authority` 在连接边界统一显示为 `forbidden`。
func _apply_dispute(outcome: Dictionary, action: String, case_id: String) -> Dictionary:
	if not bool(outcome.get("ok", false)):
		var reason: String = str(outcome.get("reason", ""))
		if reason == "not_authority":
			reason = "forbidden"
		return _dispute_result(false, reason, action,
			str(outcome.get("case_id", case_id)), false, "")
	var candidate_value: Variant = outcome.get("state")
	if not candidate_value is Dictionary:
		return _dispute_result(false, "invalid_state", action, case_id, false, "")
	var reply: Dictionary = _dispute_result(true, "", action, case_id, false,
		str(outcome.get("status", "")))
	reply["candidate"] = candidate_value
	return reply


func _replay_dispute(command_id: String, payload: String) -> Dictionary:
	var entry_value: Variant = _disputes_results.get(command_id)
	if not entry_value is Dictionary:
		return {}
	var first_value: Variant = (entry_value as Dictionary).get("result")
	if not first_value is Dictionary:
		return {}
	var stored: Dictionary = first_value
	if str((entry_value as Dictionary).get("payload", "")) != payload:
		return _dispute_result(false, "command_conflict",
			str(stored.get("action", "")), str(stored.get("case_id", "")), false, "")
	var reply: Dictionary = stored.duplicate(true)
	reply["duplicate"] = true
	return reply


## 从持久化的命令日志恢复重放窗口。存储层已经校验过形状，这里只做内存索引。
func _load_dispute_commands(value: Variant) -> void:
	_disputes_results.clear()
	if not value is Array:
		return
	for row_value: Variant in value:
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		var result_value: Variant = row.get("result")
		_disputes_results[str(row.get("command_id", ""))] = {
			"payload": str(row.get("payload", "")),
			"result": (result_value as Dictionary).duplicate(true) \
				if result_value is Dictionary else {},
		}


## 下一次保存要写出的命令日志：现有窗口加上本次成功命令，超出上限时丢弃最旧
## 的一条。先在副本上计算，保存失败时内存窗口不受影响。
func _dispute_journal_with(command_id: String, payload: String,
		result: Dictionary) -> Array:
	var rows: Array = _dispute_journal_rows()
	rows.append({
		"command_id": command_id, "payload": payload,
		"result": result.duplicate(true),
	})
	while rows.size() > MAX_DISPUTES_RESULTS:
		rows.pop_front()
	return rows


func _dispute_journal_rows() -> Array:
	var rows: Array = []
	for key: Variant in _disputes_results.keys():
		var entry: Dictionary = _disputes_results[key]
		var result_value: Variant = entry.get("result")
		rows.append({
			"command_id": str(key),
			"payload": str(entry.get("payload", "")),
			"result": (result_value as Dictionary).duplicate(true) \
				if result_value is Dictionary else {},
		})
	return rows


func _sync_dispute_journal(rows: Array) -> void:
	_disputes_results.clear()
	for row_value: Variant in rows:
		var row: Dictionary = row_value
		_disputes_results[str(row.get("command_id", ""))] = {
			"payload": str(row.get("payload", "")),
			"result": (row.get("result") as Dictionary).duplicate(true),
		}


static func _valid_dispute_command_id(value: String) -> bool:
	return not value.is_empty() and value.length() <= FarmCommand.MAX_ID_LENGTH


static func _valid_dispute_player(value: String) -> bool:
	return not value.is_empty() and value != "public" and OwnerIds.valid(value)


static func _dispute_result(ok: bool, reason: String, action: String,
		case_id: String, duplicate: bool, status: String) -> Dictionary:
	return {
		"ok": ok, "reason": reason, "action": action, "case_id": case_id,
		"duplicate": duplicate, "status": status,
	}


## 补偿金额必须是正整数。JSON 数字读回可能是 float，因此接受整数值的 float。
static func _valid_compensation_amount(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 1.0 \
		and number <= float(Disputes.MAX_SAFE_INTEGER) and number == floorf(number)


static func _has_economy_account(snapshot: Dictionary, owner: String) -> bool:
	var accounts: Variant = snapshot.get("accounts")
	return accounts is Dictionary \
		and (accounts as Dictionary).get(owner) is Dictionary


## 每个案件的补偿转账事件 id 由案件 id 派生，且使用账本保留前缀；客户端命令
## id 不能占用同一命名空间（见 `Ledger.RESERVED_EVENT_PREFIXES`）。
static func _dispute_compensation_event(case_id: String) -> String:
	return DisputesStore.COMPENSATION_EVENT_PREFIX + case_id


func _dispute_compensation_entry(case_id: String) -> Dictionary:
	if farm == null:
		return {}
	var marker: String = _dispute_compensation_event(case_id)
	for entry_value: Variant in farm.economy_ledger_entries():
		if entry_value is Dictionary \
				and str((entry_value as Dictionary).get("event_id", "")) == marker:
			return (entry_value as Dictionary).duplicate(true)
	return {}


## 已有的同名账本条目必须正好是“付款方 -> 收款方”的同额转账；否则视为冲突，
## 绝不把另一笔现金移动当作这次补偿已经执行。
static func _dispute_compensation_matches_entry(entry: Dictionary, payer: String,
		payee: String, amount: int) -> bool:
	var lines_value: Variant = entry.get("lines")
	if not lines_value is Array or (lines_value as Array).size() != 2:
		return false
	var debit_ok: bool = false
	var credit_ok: bool = false
	for line_value: Variant in lines_value:
		if not line_value is Dictionary:
			return false
		var line: Dictionary = line_value
		if str(line.get("account", "")) == Ledger.owner_code(payee) \
				and int(line.get("debit", 0)) == amount \
				and int(line.get("credit", 0)) == 0:
			debit_ok = true
		elif str(line.get("account", "")) == Ledger.owner_code(payer) \
				and int(line.get("credit", 0)) == amount \
				and int(line.get("debit", 0)) == 0:
			credit_ok = true
	return debit_ok and credit_ok


## 打开世界时补齐中断的补偿。`paid=false` 的记录只有两种合法历史：
##   - 账本已有对应事件：上次在农场保存后、`paid=true` 写回前中断，只需补标记；
##   - 账本没有对应事件：上次在 disputes 保存后、农场保存前中断，先补付。
## 所有待补付先在同一农场候选上执行，再各写一次 farm.json 与 disputes.json，
## 因此失败不会留下部分补偿；重复打开时账本事件与 `paid=true` 都会阻止二次转账。
func _recover_dispute_compensations() -> Dictionary:
	if farm == null or _dispute_enforcement.is_empty():
		return {"ok": true}
	var cases_value: Variant = disputes.get("cases")
	if not cases_value is Dictionary:
		return {"ok": false, "reason": "invalid_state"}
	var cases: Dictionary = cases_value
	var pending: Array[String] = []
	var changed: bool = false
	for case_id_value: Variant in _dispute_enforcement.keys():
		var case_id: String = str(case_id_value)
		var row_value: Variant = _dispute_enforcement[case_id_value]
		var case_value: Variant = cases.get(case_id)
		if not row_value is Dictionary or not case_value is Dictionary:
			return {"ok": false, "reason": "invalid_state"}
		var row: Dictionary = row_value
		var case_row: Dictionary = case_value
		var ruling_value: Variant = case_row.get("ruling")
		if not ruling_value is Dictionary:
			return {"ok": false, "reason": "invalid_state"}
		if bool(row.get("paid", false)):
			continue
		var payer: String = str(case_row.get("against", ""))
		var payee: String = str(case_row.get("filed_by", ""))
		var amount: int = int(row.get("amount", 0))
		var existing: Dictionary = _dispute_compensation_entry(case_id)
		if not existing.is_empty():
			if not _dispute_compensation_matches_entry(existing, payer, payee, amount):
				return {"ok": false, "reason": "compensation_conflict"}
			row["paid"] = true
			_dispute_enforcement[case_id] = row
			changed = true
			continue
		pending.append(case_id)
	if not pending.is_empty():
		var farm_candidate: RefCounted = farm.copy()
		for case_id: String in pending:
			var row: Dictionary = _dispute_enforcement[case_id]
			var case_row: Dictionary = cases[case_id]
			var paid: Dictionary = farm_candidate.economy_authority_pay(
				str(case_row.get("against", "")), str(case_row.get("filed_by", "")),
				int(row.get("amount", 0)), _dispute_compensation_event(case_id),
				float(row.get("at_utc", 0.0)))
			if not bool(paid.get("ok", false)):
				return {"ok": false,
					"reason": "compensation_" + str(paid.get("reason", ""))}
		var farm_saved: Dictionary = store.save_state(farm_candidate, decorations)
		if not farm_saved.ok:
			return {"ok": false, "reason": "save_" + str(farm_saved.kind)}
		farm.accept(farm_candidate)
		for case_id: String in pending:
			var row: Dictionary = _dispute_enforcement[case_id]
			row["paid"] = true
			_dispute_enforcement[case_id] = row
		changed = true
	if not changed:
		return {"ok": true}
	var saved: Dictionary = disputes_store.save_state(disputes,
		_dispute_journal_rows(), _dispute_enforcement)
	if not saved.ok:
		return {"ok": false, "reason": "save_disputes_" + str(saved.kind)}
	return {"ok": true}


## 规则决议可执行的动作。`state` / `view` 是只读分支，不进入这里。
const RESOLUTION_ACTIONS: Array[String] = [
	"propose", "vote", "close", "activate", "withdraw", "revoke",
]


## 规则决议只读视图。`rules_version` 是世界级规则版本，始终公开。每条决议公开
## id、类型、标题、提案人（公开事实）、状态、三个时刻、revision、生效与撤销
## 版本字段，以及已撤销决议的失效时刻 `ends_utc`（其他状态为 0）。
##
## 隐私分级（与纠纷视图的分层思路一致，但阈值不同）：
## - 非成员与匿名读取（`is_member=false`）只拿公开行，没有计票人数，也没有
##   任何投票人身份；
## - 已加入成员（含匿名成员）额外拿到赞成/反对**人数**，但没有身份明细；
## - 与该决议相关的查看者（提案人、赞成者或反对者）才拿到投票人 id 列表。
## 视图不包含命令日志：重放窗口是存储层事实，不是世界公开事实。
## `is_member` 表示“已加入”，隐私分级靠它给已加入连接下发计票人数；`can_write`
## 是连接层解析出的写入权限，只用来告诉客户端该摆出哪些写入按钮。二者都不是
## 授权来源：每次写入仍由 `WorldHost` 重新判定角色、只读与玩家身份。
func resolutions_view(viewer: String = "", is_member: bool = false,
		can_write: bool = false) -> Dictionary:
	var by_id: Dictionary = {}
	var resolutions_value: Variant = resolutions.get("resolutions")
	if resolutions_value is Dictionary:
		by_id = resolutions_value
	var ids: Array = by_id.keys()
	ids.sort()
	var rows: Array = []
	for id_value: Variant in ids:
		var resolution_id: String = str(id_value)
		var row_value: Variant = by_id[id_value]
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		var status: String = str(row.get("status", ""))
		var row_view: Dictionary = {
			"resolution_id": resolution_id,
			"kind": str(row.get("kind", "")),
			"title": str(row.get("title", "")),
			"proposed_by": str(row.get("proposed_by", "")),
			"proposed_utc": float(row.get("proposed_utc", 0.0)),
			"vote_start_utc": float(row.get("vote_start_utc", 0.0)),
			"vote_end_utc": float(row.get("vote_end_utc", 0.0)),
			"effective_utc": float(row.get("effective_utc", 0.0)),
			"status": status,
			"revision": int(row.get("revision", 0)),
			"effective_version": int(row.get("effective_version", 0)),
			"revoked_by": str(row.get("revoked_by", "")),
			"revoked_utc": float(row.get("revoked_utc", 0.0)),
			"revoked_version": int(row.get("revoked_version", 0)),
		}
		# 已撤销决议的失效时刻就是撤销时刻；其他状态为 0（从未失效）。
		row_view["ends_utc"] = float(row.get("revoked_utc", 0.0)) \
			if status == ResolutionState.STATUS_REVOKED else 0.0
		var approvals: Array = row.get("approvals", []) \
			if row.get("approvals") is Array else []
		var rejections: Array = row.get("rejections", []) \
			if row.get("rejections") is Array else []
		if is_member:
			# 计票人数是已加入成员可见的公共统计，不暴露具体是谁。
			row_view["approvals"] = approvals.size()
			row_view["rejections"] = rejections.size()
		var related: bool = not viewer.is_empty() \
			and (str(row.get("proposed_by", "")) == viewer
				or approvals.has(viewer) or rejections.has(viewer))
		if related:
			row_view["approvers"] = approvals.duplicate()
			row_view["rejecters"] = rejections.duplicate()
		rows.append(row_view)
	return {
		"available": not resolutions.is_empty(),
		"now_utc": authority_now_utc(),
		"viewer": viewer,
		"is_member": is_member,
		"can_write": can_write,
		"rules_version": int(resolutions.get("rules_version", 0)),
		"versions": _resolutions_version_summary(by_id),
		"effects": _resolution_effects_view(authority_now_utc()),
		"resolutions": rows,
	}


## 顶层效果块：只读推导，供客户端预告税费与折减。它不进每行决议：效果由整个
## 已应用集合计，单行看不到税额或系数。没有效果文档时费率与系数都是 0。
func _resolution_effects_view(at_utc: float) -> Dictionary:
	var applied_version: int = int(resolution_effects.get("applied_version", 0)) \
		if not resolution_effects.is_empty() else 0
	var tax_permille: int = 0
	var coefficients: Dictionary = {}
	for kind: String in ResolutionEffects.EFFECT_KINDS:
		coefficients[kind] = 0
	if not resolution_effects.is_empty():
		var rate: Dictionary = ResolutionEffects.tax_rate(
			resolution_effects, resolutions, at_utc)
		# 超限时仍然报告实际费率，视图只读，不在这里截断。
		tax_permille = int(rate.get("rate_permille", 0))
		for kind: String in ResolutionEffects.EFFECT_KINDS:
			var result: Dictionary = ResolutionEffects.coefficient_for(
				resolution_effects, resolutions, kind, at_utc)
			if bool(result.get("ok", false)):
				coefficients[kind] = int(result.get("permille", 0))
	return {
		"applied_version": applied_version,
		"tax_rate_permille": tax_permille,
		"coefficients": coefficients,
	}


## 版本差异摘要：按版本号升序列出每次版本推进由哪条决议、哪种动作消费。顶层
## `rules_version` 已经覆盖全部版本；摘要只从严格文档推导，不另存历史快照。
static func _resolutions_version_summary(by_id: Dictionary) -> Array:
	var rows: Array = []
	for id_value: Variant in by_id.keys():
		var row_value: Variant = by_id[id_value]
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		var effective_version: int = int(row.get("effective_version", 0))
		if effective_version < 1:
			continue
		rows.append({
			"version": effective_version,
			"resolution_id": str(id_value),
			"change": "effective",
		})
		var revoked_version: int = int(row.get("revoked_version", 0))
		if revoked_version >= 1:
			rows.append({
				"version": revoked_version,
				"resolution_id": str(id_value),
				"change": "revoked",
			})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.version) < int(b.version))
	return rows


## 通过权威时钟执行一次规则决议命令。操作者由连接层解析传入，参数里的任何
## actor/proposer/voter 字段都不参与授权或归属。规则在文档副本上计算，候选与
## 命令日志在同一次原子保存中写盘，保存成功后才替换活文档；保存失败不写盘、
## 不改内存。同一 command id 重放返回首次结果且不追加日志，换参数返回
## `command_conflict`；日志超过 `ResolutionsStore.MAX_COMMANDS` 行时淘汰最旧。
##
## `is_member` 只影响只读分支的隐私分级：它由连接层按房间角色解析传入，绝不从
## 命令参数读取。`can_write` 同样是连接层解析的只读事实，只随视图下发。写入
## 只要求具名玩家身份，成员资格、只读状态与角色门由 `WorldHost` 在调用前判定。
func execute_resolution(action: String, actor: String, args: Dictionary,
		command_id: String, is_member: bool = false,
		can_write: bool = false) -> Dictionary:
	if resolutions_store == null:
		return _resolution_result(false, "not_open", action, "", false, "")
	if action == "state" or action == "view":
		return {
			"ok": true, "reason": "", "action": action, "resolution_id": "",
			"duplicate": false, "status": "",
			"state": resolutions_view(actor, is_member, can_write),
		}
	if not RESOLUTION_ACTIONS.has(action):
		return _resolution_result(false, "unknown_action", action,
			str(args.get("resolution_id", "")), false, "")
	if not _valid_resolution_command_id(command_id):
		return _resolution_result(false, "invalid_command", action,
			str(args.get("resolution_id", "")), false, "")
	if not _valid_dispute_player(actor):
		return _resolution_result(false, "invalid_player", action,
			str(args.get("resolution_id", "")), false, "")
	var payload: String = JSON.stringify([action, actor, args])
	var replayed: Dictionary = _replay_resolution(command_id, payload)
	if not replayed.is_empty():
		return replayed
	var resolution_id: String = str(args.get("resolution_id", ""))
	var now: float = authority_now_utc()
	var outcome: Dictionary
	match action:
		"propose":
			outcome = ResolutionState.propose(resolutions,
				args.get("resolution_id", ""), actor, args.get("proposal"), now)
		"vote":
			var approve_value: Variant = args.get("approve")
			if not approve_value is bool:
				return _resolution_result(false, "invalid_request", action,
					resolution_id, false, "")
			outcome = ResolutionState.vote(resolutions,
				args.get("resolution_id", ""), actor, bool(approve_value), now)
		"close":
			outcome = ResolutionState.close(resolutions,
				args.get("resolution_id", ""), now)
		"activate":
			outcome = ResolutionState.activate(resolutions,
				args.get("resolution_id", ""), now)
		"withdraw":
			outcome = ResolutionState.withdraw(resolutions,
				args.get("resolution_id", ""), actor, now)
		_:
			outcome = ResolutionState.revoke(resolutions,
				args.get("resolution_id", ""), actor, now)
	if not bool(outcome.get("ok", false)):
		return _resolution_result(false, str(outcome.get("reason", "")), action,
			resolution_id, false, "")
	var candidate_value: Variant = outcome.get("state")
	if not candidate_value is Dictionary:
		return _resolution_result(false, "invalid_state", action, resolution_id, false, "")
	var candidate: Dictionary = candidate_value
	var final_result: Dictionary = _resolution_result(true, "", action, resolution_id,
		false, _resolution_status(candidate, resolution_id))
	var journal: Array = _resolution_journal_with(command_id, payload, final_result)
	var saved: Dictionary = resolutions_store.save_state(candidate, journal)
	if not saved.ok:
		return _resolution_result(false, "save_resolutions_" + str(saved.kind), action,
			resolution_id, false, "")
	# 效果只在 activate 成功后登记。`apply()` 要求效果水位不超过候选的
	# `rules_version`，所以决议必须先成功落盘；效果自己的失败不会让规则退回
	# 未生效状态，而是保留与磁盘一致的两份文档并在下次打开时按水位补齐。
	if action == "activate":
		var applied: Dictionary = _apply_resolution_effects(candidate, now)
		if not bool(applied.get("ok", false)):
			resolutions = candidate
			_sync_resolution_journal(journal)
			return _resolution_result(false,
				"resolution_effects_" + str(applied.get("reason", "")), action,
				resolution_id, false, "")
		if bool(applied.get("changed", false)):
			var effects_saved: Dictionary = resolution_effects_store.save_state(
				applied.state)
			if not effects_saved.ok:
				resolutions = candidate
				_sync_resolution_journal(journal)
				return _resolution_result(false,
					"save_resolution_effects_" + str(effects_saved.kind), action,
					resolution_id, false, "")
		resolution_effects = applied.state
	resolutions = candidate
	_sync_resolution_journal(journal)
	return final_result


## 打开世界时补齐效果文档：按 `effective_version` 升序遍历，对已生效、已到
## 生效时刻且尚未登记的决议调用 `apply()`。当低版本还没到生效时刻就停止，
## 不能跳过：版本水位是全局的，跳过后补应用低版本会被判为已应用，那条决议将
## 永久失去效果。已撤销行不推进水位，因为它可能从未生效过。没有变化时不写盘。
func _backfill_resolution_effects(now_utc_seconds: float) -> Dictionary:
	var applied: Dictionary = _apply_resolution_effects(resolutions, now_utc_seconds)
	if not bool(applied.get("ok", false)) \
			or not bool(applied.get("changed", false)):
		return applied
	var saved: Dictionary = resolution_effects_store.save_state(applied.state)
	if not saved.ok:
		return {"ok": false, "reason": str(saved.kind)}
	resolution_effects = applied.state
	return {"ok": true}


## 在给定决议文档上按生效版本补齐效果，不写盘。返回 {ok, state, changed}，
## `changed` 为真时调用方负责把 `state` 落盘；失败时 `reason` 是规则原因。
func _apply_resolution_effects(resolutions_document: Dictionary,
		now_utc_seconds: float) -> Dictionary:
	var rows: Variant = resolutions_document.get("resolutions")
	if not rows is Dictionary:
		return {"ok": true, "state": resolution_effects, "changed": false}
	var ordered: Array = []
	for id_value: Variant in (rows as Dictionary).keys():
		var row_value: Variant = (rows as Dictionary)[id_value]
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		var version: int = int(row.get("effective_version", 0))
		if version < 1:
			continue
		ordered.append({"resolution_id": str(id_value), "version": version,
			"status": str(row.get("status", "")),
			"effective_utc": float(row.get("effective_utc", 0.0))})
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.version) != int(b.version):
			return int(a.version) < int(b.version)
		return str(a.resolution_id) < str(b.resolution_id))
	var candidate: Dictionary = resolution_effects
	var changed: bool = false
	for entry: Dictionary in ordered:
		if str(entry.status) != ResolutionState.STATUS_EFFECTIVE:
			continue
		if int(entry.version) <= int(candidate.get("applied_version", 0)):
			continue
		# 低版本尚未到生效时刻：后面的版本也一并等待，不跳过水位。
		if now_utc_seconds < float(entry.effective_utc):
			break
		var applied: Dictionary = ResolutionEffects.apply(candidate,
			resolutions_document, str(entry.resolution_id), now_utc_seconds)
		if not bool(applied.get("ok", false)):
			return {"ok": false, "reason": str(applied.get("reason", ""))}
		candidate = applied.state
		changed = true
	if not changed:
		return {"ok": true, "state": candidate, "changed": false}
	return {"ok": true, "state": candidate, "changed": true}


static func _resolution_status(document: Dictionary, resolution_id: String) -> String:
	var rows: Variant = document.get("resolutions")
	if not rows is Dictionary:
		return ""
	var row: Variant = (rows as Dictionary).get(resolution_id)
	return str((row as Dictionary).get("status", "")) if row is Dictionary else ""


func _replay_resolution(command_id: String, payload: String) -> Dictionary:
	var entry_value: Variant = _resolution_results.get(command_id)
	if not entry_value is Dictionary:
		return {}
	var first_value: Variant = (entry_value as Dictionary).get("result")
	if not first_value is Dictionary:
		return {}
	var stored: Dictionary = first_value
	if str((entry_value as Dictionary).get("payload", "")) != payload:
		return _resolution_result(false, "command_conflict",
			str(stored.get("action", "")), str(stored.get("resolution_id", "")), false, "")
	var reply: Dictionary = stored.duplicate(true)
	reply["duplicate"] = true
	return reply


## 从持久化的命令日志恢复重放窗口。存储层已经校验过形状，这里只做内存索引。
func _load_resolution_commands(value: Variant) -> void:
	_resolution_results.clear()
	if not value is Array:
		return
	for row_value: Variant in value:
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		var result_value: Variant = row.get("result")
		_resolution_results[str(row.get("command_id", ""))] = {
			"payload": str(row.get("payload", "")),
			"result": (result_value as Dictionary).duplicate(true) \
				if result_value is Dictionary else {},
		}


## 下一次保存要写出的命令日志：现有窗口加上本次成功命令，超出上限时丢弃最旧
## 的一条。先在副本上计算，保存失败时内存窗口不受影响。
func _resolution_journal_with(command_id: String, payload: String,
		result: Dictionary) -> Array:
	var rows: Array = _resolution_journal_rows()
	rows.append({
		"command_id": command_id, "payload": payload,
		"result": result.duplicate(true),
	})
	while rows.size() > ResolutionsStore.MAX_COMMANDS:
		rows.pop_front()
	return rows


func _resolution_journal_rows() -> Array:
	var rows: Array = []
	for key: Variant in _resolution_results.keys():
		var entry: Dictionary = _resolution_results[key]
		var result_value: Variant = entry.get("result")
		rows.append({
			"command_id": str(key),
			"payload": str(entry.get("payload", "")),
			"result": (result_value as Dictionary).duplicate(true) \
				if result_value is Dictionary else {},
		})
	return rows


func _sync_resolution_journal(rows: Array) -> void:
	_resolution_results.clear()
	for row_value: Variant in rows:
		var row: Dictionary = row_value
		var result_value: Variant = row.get("result")
		_resolution_results[str(row.get("command_id", ""))] = {
			"payload": str(row.get("payload", "")),
			"result": (result_value as Dictionary).duplicate(true) \
				if result_value is Dictionary else {},
		}


static func _valid_resolution_command_id(value: String) -> bool:
	return not value.is_empty() and value.length() <= FarmCommand.MAX_ID_LENGTH


static func _resolution_result(ok: bool, reason: String, action: String,
		resolution_id: String, duplicate: bool, status: String) -> Dictionary:
	return {
		"ok": ok, "reason": reason, "action": action,
		"resolution_id": resolution_id, "duplicate": duplicate, "status": status,
	}


## 只读的交战视图。目标预算按 key 排序；近期结果取 consumed 中最后 20 条，
## 按命令 id 升序输出。consumed 的 payload 与 freeze 是结算内部证据，不下发。
func conflicts_view() -> Dictionary:
	var targets: Array = []
	var targets_value: Variant = conflicts.get("targets")
	if targets_value is Dictionary:
		for key: String in (targets_value as Dictionary).keys():
			var row_value: Variant = (targets_value as Dictionary)[key]
			if not row_value is Dictionary:
				continue
			var row: Dictionary = row_value
			targets.append({
				"key": key,
				"target": str(row.get("target", "")),
				"parcel_id": str(row.get("parcel_id", "")),
				"lost": int(row.get("lost", 0)),
				"cap": int(row.get("cap", 0)),
			})
	targets.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.key) < str(b.key))
	var recent: Array = []
	var consumed_value: Variant = conflicts.get("consumed")
	if consumed_value is Dictionary:
		var by_id: Dictionary = consumed_value
		for command_id: String in by_id.keys():
			var entry_value: Variant = by_id[command_id]
			if not entry_value is Dictionary:
				continue
			var outcome_value: Variant = (entry_value as Dictionary).get("outcome")
			if not outcome_value is Dictionary:
				continue
			recent.append(_conflict_outcome_summary(str(command_id), outcome_value))
	recent.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.command_id) < str(b.command_id))
	if recent.size() > CONFLICT_RECENT_RESULTS:
		recent = recent.slice(recent.size() - CONFLICT_RECENT_RESULTS, recent.size())
	return {
		"sequence": int(conflicts.get("sequence", 0)),
		"targets": targets,
		"recent": recent,
	}


static func _conflict_outcome_summary(command_id: String, outcome: Dictionary) -> Dictionary:
	return {
		"command_id": command_id,
		"attacker": str(outcome.get("attacker", "")),
		"defender": str(outcome.get("defender", "")),
		"parcel_id": str(outcome.get("parcel_id", "")),
		"troops": int(outcome.get("troops", 0)),
		"losses": int(outcome.get("losses", 0)),
		"taken_cash": int(outcome.get("taken_cash", 0)),
		"taken_supplies": int(outcome.get("taken_supplies", 0)),
		"spoils_cash": int(outcome.get("spoils_cash", 0)),
		"spoils_supplies": int(outcome.get("spoils_supplies", 0)),
		"destroyed": int(outcome.get("destroyed", 0)),
		"supply_cost": int(outcome.get("supply_cost", 0)),
		"at_utc": float(outcome.get("at_utc", 0.0)),
		"defender_online": bool(outcome.get("defender_online", false)),
		"target_lost_after": int(outcome.get("target_lost_after", 0)),
		"target_cap": int(outcome.get("target_cap", 0)),
		"window_id": str(outcome.get("window_id", "")),
	}


## 通过权威时钟执行一次交战。除只读 `state`/`view` 外只支持 `engage`。操作者
## 由连接层解析传入；`defender_online` 也由连接层按在线成员表计算。客户端载荷
## 里的 actor/owner/resources 一律不参与授权或结算。
func execute_conflict(action: String, actor: String, args: Dictionary,
		command_id: String, defender_online: bool) -> Dictionary:
	if conflicts_store == null or units_store == null or participation_store == null \
			or farm == null:
		return _conflict_result(false, "not_open", action, false)
	if action == "state" or action == "view":
		return {
			"ok": true, "reason": "", "action": action, "duplicate": false,
			"state": conflicts_view(),
		}
	if action != "engage":
		return _conflict_result(false, "unknown_action", action, false)
	return _engage_conflict(actor, args, command_id, defender_online)


func _engage_conflict(actor: String, args: Dictionary, command_id: String,
		defender_online: bool) -> Dictionary:
	if participation.is_empty():
		return _conflict_result(false, "no_host", "engage", false)
	if command_id.is_empty() \
			or command_id.length() > ConflictSettlement.MAX_COMMAND_ID_LENGTH:
		return _conflict_result(false, "invalid_command", "engage", false)
	var parsed: Dictionary = _parse_conflict_request(actor, args)
	if not bool(parsed.get("ok", false)):
		return _conflict_result(false, str(parsed.get("reason", "invalid_request")),
			"engage", false)
	var request: Dictionary = parsed.request
	var defender: String = str(request.defender)

	# 已结算的命令 id 先于任何单位/资产读取处理：重试时进攻方人数可能已经因
	# 战损减少，若重新投影兵力就会出现假冲突或二次扣损失。
	var existing: Dictionary = _conflict_outcome(command_id)
	if not existing.is_empty():
		var stored_at: float = float(existing.get("at_utc", 0.0))
		var stored_signature: String = _conflict_signature(actor, request, stored_at)
		var entry_value: Variant = _conflict_applied.get(command_id)
		if not entry_value is Dictionary:
			return _conflict_result(false, "invalid_context", "engage", false)
		var entry: Dictionary = entry_value
		if str(entry.get("signature", "")) != stored_signature:
			return _conflict_result(false, "command_conflict", "engage", false)
		if bool(entry.get("applied", false)):
			return _conflict_duplicate(existing, false)
		return _recover_conflict(command_id, existing, entry)

	# 有未完成提交时不允许开新战：恢复依赖冲突上下文里保存的前后资源值，新的
	# 交战会改写这些行，使旧命令既无法判定也无法安全补齐。
	if not _pending_conflict_id().is_empty():
		return _conflict_result(false, "recovery_required", "engage", false)
	var owner_reason: String = _conflict_owner_reason(request.attacker_units, actor)
	if not owner_reason.is_empty():
		return _conflict_result(false, owner_reason, "engage", false)
	owner_reason = _conflict_owner_reason(request.defender_units, defender)
	if not owner_reason.is_empty():
		return _conflict_result(false, owner_reason, "engage", false)

	var context: Dictionary = conflicts.duplicate(true)
	context["participation"] = participation.duplicate(true)
	if not ConflictSettlement.valid_context(context):
		return _conflict_result(false, "invalid_context", "engage", false)
	var parcel: String = str(request.get("target_parcel", ""))
	var key: String = ConflictSettlement.target_key(defender, parcel)
	var targets: Dictionary = context["targets"]
	if not targets.has(key):
		if targets.size() >= ConflictSettlement.MAX_TARGETS:
			return _conflict_result(false, "capacity", "engage", false)
		targets[key] = {
			"key": key, "target": defender, "parcel_id": parcel,
			"lost": 0, "cap": CONFLICT_TARGET_LOSS_CAP,
		}
	if not ConflictSettlement.valid_context(context):
		return _conflict_result(false, "invalid_context", "engage", false)

	var at_utc: float = authority_now_utc()
	var signature: String = _conflict_signature(actor, request, at_utc)
	var settle_request: Dictionary = {
		"id": command_id,
		"attacker": actor,
		"defender": defender,
		"attacker_units": request.attacker_units.duplicate(),
		"defender_units": request.defender_units.duplicate(),
		# 资源完全由权威从农场读取；客户端载荷里的任何资源值都不参与。
		"resources": {
			actor: _actor_stock(actor),
			defender: _actor_stock(defender),
		},
		"x": int(request.x),
		"z": int(request.z),
		"defender_online": defender_online,
		"at_utc": at_utc,
	}
	if bool(request.has_target_parcel):
		settle_request["target_parcel"] = parcel
	var engagement: Dictionary = UnitConflict.engage(units, participation, context,
		settle_request, at_utc)
	if not bool(engagement.get("ok", false)):
		return _conflict_result(false,
			_conflict_rule_reason(str(engagement.get("reason", "invalid_context"))),
			"engage", false)
	var outcome: Dictionary = engagement.outcome
	var next_context: Dictionary = engagement.settlement.next_context
	var next_units: Dictionary = engagement.units

	var applied_map: Dictionary = _conflict_applied.duplicate(true)
	applied_map[command_id] = {
		"applied": false,
		"signature": signature,
		"unit_plan": _conflict_unit_plan(request.attacker_units,
			request.defender_units, next_units),
	}
	# 事务顺序：先落盘意图（含 consumed 与 applied=false），再动真实资产；任何
	# 后续失败都能凭这份记录判断哪些步骤已完成。
	var intent_saved: Dictionary = conflicts_store.save_state(next_context, applied_map)
	if not intent_saved.ok:
		return _conflict_result(false, "save_conflicts_" + str(intent_saved.kind),
			"engage", false)
	conflicts = next_context
	_conflict_applied = applied_map

	var committed: Dictionary = _commit_conflict_assets(outcome, next_units)
	if not bool(committed.get("ok", false)):
		return _conflict_result(false, str(committed.get("reason", "")),
			"engage", false)
	var marked: Dictionary = _conflict_mark_applied(command_id, true)
	if not marked.ok:
		return _conflict_result(false, "save_conflicts_" + str(marked.kind),
			"engage", false)
	return {
		"ok": true, "reason": "", "action": "engage", "duplicate": false,
		"outcome": outcome.duplicate(true), "state": conflicts_view(),
	}


## 校验交战请求的纯形状。单位归属、资源与参与资格在结算层判定；这里只保证
## 攻击者、防守者、单位列表、坐标与可选地块是格式合法的权威输入。
func _parse_conflict_request(actor: String, args: Dictionary) -> Dictionary:
	if not _conflict_player(actor):
		return _conflict_failure("invalid_attacker")
	var defender_value: Variant = args.get("defender", "")
	if not _conflict_player(defender_value):
		return _conflict_failure("invalid_defender")
	if str(defender_value) == actor:
		return _conflict_failure("same_player")
	var attacker_ids: Dictionary = _parse_conflict_ids(args.get("attacker_units"))
	if not bool(attacker_ids.get("ok", false)):
		return attacker_ids
	var defender_ids: Dictionary = _parse_conflict_ids(args.get("defender_units"))
	if not bool(defender_ids.get("ok", false)):
		return defender_ids
	var seen: Dictionary = {}
	for unit_id: Variant in attacker_ids.ids:
		seen[str(unit_id)] = true
	for unit_id: Variant in defender_ids.ids:
		if seen.has(str(unit_id)):
			return _conflict_failure("duplicate_unit")
	if not _conflict_coord(args.get("x")) or not _conflict_coord(args.get("z")):
		return _conflict_failure("invalid_position")
	var parcel: String = ""
	var has_parcel: bool = args.has("target_parcel")
	if has_parcel:
		var raw: Variant = args["target_parcel"]
		if not raw is String:
			return _conflict_failure("invalid_target")
		parcel = str(raw)
		if not parcel.is_empty() and not _conflict_entry_id(parcel):
			return _conflict_failure("invalid_target")
	return {
		"ok": true, "reason": "",
		"request": {
			"attacker": actor,
			"defender": str(defender_value),
			"attacker_units": attacker_ids.ids,
			"defender_units": defender_ids.ids,
			"x": int(args.get("x")),
			"z": int(args.get("z")),
			"target_parcel": parcel,
			"has_target_parcel": has_parcel,
		},
	}


static func _parse_conflict_ids(value: Variant) -> Dictionary:
	if not value is Array:
		return _conflict_failure("invalid_units")
	var raw_ids: Array = value
	if raw_ids.is_empty():
		return _conflict_failure("empty_units")
	var ids: Array = []
	var seen: Dictionary = {}
	for raw: Variant in raw_ids:
		if not raw is String or str(raw).is_empty() \
				or str(raw).length() > UnitState.MAX_UNIT_ID_LENGTH:
			return _conflict_failure("invalid_units")
		var unit_id: String = str(raw)
		if seen.has(unit_id):
			return _conflict_failure("duplicate_unit")
		seen[unit_id] = true
		ids.append(unit_id)
	ids.sort()
	return {"ok": true, "reason": "", "ids": ids}


static func _conflict_signature(actor: String, request: Dictionary,
		at_utc: float) -> String:
	# defender_online 由连接层按当前在线表推导，重试时防守方可能已经离线；它不是
	# 客户端参数，不进入“同参数”比较，否则正常重试会被误判成换载荷。
	return JSON.stringify([
		actor, str(request.defender), request.attacker_units, request.defender_units,
		int(request.x), int(request.z), bool(request.has_target_parcel),
		str(request.target_parcel), float(at_utc),
	])


func _conflict_owner_reason(ids: Array, owner: String) -> String:
	var rows_value: Variant = units.get("units")
	if not rows_value is Dictionary:
		return UnitState.REASON_INVALID_STATE
	var rows: Dictionary = rows_value
	for raw: Variant in ids:
		var unit_id: String = str(raw)
		if not rows.has(unit_id):
			return UnitState.REASON_UNKNOWN_UNIT
		var row_value: Variant = rows[unit_id]
		if not row_value is Dictionary \
				or str((row_value as Dictionary).get("owner", "")) != owner:
			return UnitState.REASON_NOT_OWNER
	return ""


## 出征与防守两边的战损都要落盘：只记进攻方时，防守单位的人数变化在意图里
## 没有记录，恢复路径会认为“未写”，重试就把同一份战损再摊一次。名单里没有
## 实际损失的单位前后相同，`_conflict_units_status` 会跳过，不会误判为已写。
func _conflict_unit_plan(attacker_ids: Array, defender_ids: Array,
		next_units: Dictionary) -> Dictionary:
	var plan: Dictionary = {}
	var rows_value: Variant = units.get("units")
	var rows: Dictionary = rows_value if rows_value is Dictionary else {}
	var next_value: Variant = next_units.get("units")
	var next_rows: Dictionary = next_value if next_value is Dictionary else {}
	var ids: Array = attacker_ids.duplicate()
	for raw: Variant in defender_ids:
		if not ids.has(raw):
			ids.append(raw)
	for raw: Variant in ids:
		var unit_id: String = str(raw)
		var before: int = 0
		var before_value: Variant = rows.get(unit_id)
		if before_value is Dictionary:
			before = int((before_value as Dictionary).get("people", 0))
		var after: int = 0
		var after_value: Variant = next_rows.get(unit_id)
		if after_value is Dictionary:
			after = int((after_value as Dictionary).get("people", 0))
		plan[unit_id] = [before, after]
	return plan


## 把一次成功结算的全部真实资产一次写入：进攻方出征消耗、防守方现金与物资
## 损失、现金与物资战利品。现金总额/发行量与双方资源减少量在写盘前校验；失败
## 不修改活农场。农场先保存，随后单位文档，最后参与文档。
func _commit_conflict_assets(outcome: Dictionary, next_units: Dictionary) -> Dictionary:
	var farm_applied: Dictionary = _apply_conflict_farm(outcome)
	if not bool(farm_applied.get("ok", false)):
		return farm_applied
	var units_saved: Dictionary = units_store.save_state(next_units)
	if not units_saved.ok:
		# 农场已经落盘；冲突意图仍是 applied=false，重试会先识别农场已完成，
		# 只补写单位与参与文档，绝不再次扣款或发战利品。
		return {"ok": false, "reason": "save_units_" + str(units_saved.kind)}
	units = next_units
	var next_participation: Variant = conflicts.get("participation")
	if not next_participation is Dictionary \
			or not Participation.valid(next_participation):
		return {"ok": false, "reason": "invalid_participation"}
	var participation_saved: Dictionary = participation_store.save_state(next_participation)
	if not participation_saved.ok:
		return {"ok": false,
			"reason": "save_participation_" + str(participation_saved.kind)}
	participation = next_participation
	return {"ok": true, "reason": ""}


## 只在候选农场上完成并保存资产部分。恢复路径也复用这一份，确保正常提交与
## 崩溃补齐使用同一套扣款、战利品和守恒校验。
func _apply_conflict_farm(outcome: Dictionary) -> Dictionary:
	var attacker: String = str(outcome.attacker)
	var defender: String = str(outcome.defender)
	var command_id: String = str(outcome.command_id)
	var supply_cost: int = int(outcome.supply_cost)
	var taken_cash: int = int(outcome.taken_cash)
	var taken_supplies: int = int(outcome.taken_supplies)
	var spoils_cash: int = int(outcome.spoils_cash)
	var spoils_supplies: int = int(outcome.spoils_supplies)
	var destroyed: int = int(outcome.destroyed)
	var pre_attacker: Dictionary = _actor_stock(attacker)
	var pre_defender: Dictionary = _actor_stock(defender)

	var candidate: RefCounted = _farm_candidate_with_accounts([Economy.WORLD_OWNER])
	if candidate == null:
		return {"ok": false, "reason": "not_open"}
	# 出征消耗与防守方物资损失按目录顺序从各自口袋扣除；战利品物资加入进攻方
	# 口袋。三者都先在私有候选上完成，任何一步不足都让整笔候选作废。
	if not _deduct_supplies(candidate, attacker, supply_cost):
		return {"ok": false, "reason": "insufficient_supply"}
	if not _deduct_supplies(candidate, defender, taken_supplies):
		return {"ok": false, "reason": "insufficient_supply"}
	if not _add_supplies(candidate, attacker, spoils_supplies):
		return {"ok": false, "reason": "invalid_supply"}
	var now: float = float(outcome.at_utc)
	if taken_cash > 0:
		var taken: Dictionary = candidate.economy_pay("conflict_take_" + command_id,
			defender, Economy.WORLD_OWNER, taken_cash, now)
		if not bool(taken.get("ok", false)):
			return {"ok": false,
				"reason": _conflict_pay_reason(str(taken.get("reason", "")))}
	if spoils_cash > 0:
		var spoils: Dictionary = candidate.economy_pay("conflict_spoil_" + command_id,
			Economy.WORLD_OWNER, attacker, spoils_cash, now)
		if not bool(spoils.get("ok", false)):
			return {"ok": false,
				"reason": _conflict_pay_reason(str(spoils.get("reason", "")))}

	# 现金只是转移，发行量不变；双方资源总量必须正好减少 destroyed。
	if candidate.economy_total_cash() != candidate.economy_issued():
		return {"ok": false, "reason": "cash_invariant"}
	var post_attacker_supplies: int = _owner_supplies_of(candidate, attacker)
	var post_defender_supplies: int = _owner_supplies_of(candidate, defender)
	if post_attacker_supplies \
			!= int(pre_attacker.supplies) - supply_cost + spoils_supplies:
		return {"ok": false, "reason": "resource_invariant"}
	if post_defender_supplies != int(pre_defender.supplies) - taken_supplies:
		return {"ok": false, "reason": "resource_invariant"}
	var pre_combined: int = int(pre_attacker.cash) + int(pre_attacker.supplies) \
		+ int(pre_defender.cash) + int(pre_defender.supplies)
	var post_combined: int = candidate.economy_cash(attacker) + post_attacker_supplies \
		+ candidate.economy_cash(defender) + post_defender_supplies
	if pre_combined - post_combined != destroyed:
		return {"ok": false, "reason": "resource_invariant"}

	var saved: Dictionary = store.save_state(candidate, decorations)
	if not saved.ok:
		return {"ok": false, "reason": "save_" + str(saved.kind)}
	farm.accept(candidate)
	shared_changed.emit()
	return {"ok": true, "reason": ""}


## 从冲突上下文保存的前后资源值判断农场侧是否已经提交。现金以账本
## `conflict_take_`/`conflict_spoil_` 分录为耐久标记（同一笔农场保存写入）；
## 物资没有独立标记，只能用“当前口袋总量等于 post 还是由 outcome 反推的 pre”
## 判断，两边都不匹配就拒绝，绝不猜一次重放。
func _conflict_supplies_status(outcome: Dictionary) -> Dictionary:
	var resources_value: Variant = conflicts.get("resources")
	if not resources_value is Dictionary:
		return {"ok": false, "reason": "stale_resources"}
	var resources: Dictionary = resources_value
	var attacker_row: Variant = resources.get(str(outcome.attacker))
	var defender_row: Variant = resources.get(str(outcome.defender))
	if not attacker_row is Dictionary or not defender_row is Dictionary:
		return {"ok": false, "reason": "stale_resources"}
	var post_attacker: int = int((attacker_row as Dictionary).get("supplies", -1))
	var post_defender: int = int((defender_row as Dictionary).get("supplies", -1))
	if post_attacker < 0 or post_defender < 0:
		return {"ok": false, "reason": "stale_resources"}
	var pre_attacker: int = post_attacker + int(outcome.supply_cost) \
		- int(outcome.spoils_supplies)
	var pre_defender: int = post_defender + int(outcome.taken_supplies)
	var current_attacker: int = _owner_supplies(str(outcome.attacker))
	var current_defender: int = _owner_supplies(str(outcome.defender))
	var post_ok: bool = current_attacker == post_attacker \
		and current_defender == post_defender
	if post_ok:
		return {"ok": true, "applied": true}
	var pre_ok: bool = current_attacker == pre_attacker \
		and current_defender == pre_defender
	if pre_ok:
		return {"ok": true, "applied": false}
	return {"ok": false, "reason": "stale_resources"}


func _conflict_cash_status(outcome: Dictionary) -> Dictionary:
	var command_id: String = str(outcome.command_id)
	var taken_cash: int = int(outcome.taken_cash)
	var spoils_cash: int = int(outcome.spoils_cash)
	var required: int = 0
	var found: int = 0
	if taken_cash > 0:
		required += 1
		var marker: Dictionary = _ledger_payment_marker("conflict_take_" + command_id,
			str(outcome.defender), Economy.WORLD_OWNER)
		if not marker.is_empty():
			if int(marker.get("amount", -1)) != taken_cash:
				return {"ok": false, "reason": "stale_resources"}
			found += 1
	if spoils_cash > 0:
		required += 1
		var marker: Dictionary = _ledger_payment_marker("conflict_spoil_" + command_id,
			Economy.WORLD_OWNER, str(outcome.attacker))
		if not marker.is_empty():
			if int(marker.get("amount", -1)) != spoils_cash:
				return {"ok": false, "reason": "stale_resources"}
			found += 1
	return {
		"ok": true, "applied": found == required,
		"partial": found > 0 and found < required,
		"required": required,
	}


func _conflict_units_status(plan: Dictionary) -> Dictionary:
	var rows_value: Variant = units.get("units")
	if not rows_value is Dictionary:
		return {"ok": false, "reason": "invalid_units"}
	var rows: Dictionary = rows_value
	var changed: int = 0
	var applied: int = 0
	var missing: int = 0
	for unit_id: String in plan.keys():
		var pair_value: Variant = plan[unit_id]
		if not pair_value is Array or (pair_value as Array).size() != 2:
			return {"ok": false, "reason": "invalid_units"}
		var pair: Array = pair_value
		var before: int = int(pair[0])
		var after: int = int(pair[1])
		# 按比例分摊时，小单位可能分不到损失，计划里 before==after。这样的行
		# 不能作为“已写/未写”的证据，否则会和多单位战损的真实情况混淆。
		if before == after:
			continue
		changed += 1
		var current: int = 0
		var row_value: Variant = rows.get(unit_id)
		if row_value is Dictionary:
			current = int((row_value as Dictionary).get("people", 0))
		if current == after:
			applied += 1
		elif current == before:
			missing += 1
		else:
			return {"ok": false, "reason": "invalid_units"}
	if changed == 0 or applied == changed:
		return {"ok": true, "applied": true}
	if missing == changed:
		return {"ok": true, "applied": false}
	return {"ok": false, "reason": "invalid_units"}


func _participation_has_engagement(outcome: Dictionary) -> bool:
	var engagements_value: Variant = participation.get("engagements")
	if not engagements_value is Dictionary:
		return false
	var row_value: Variant = (engagements_value as Dictionary).get(
		str(outcome.command_id))
	if not row_value is Dictionary:
		return false
	var row: Dictionary = row_value
	return str(row.get("attacker", "")) == str(outcome.attacker) \
		and str(row.get("target", "")) == str(outcome.defender) \
		and int(row.get("x", -1)) == int(outcome.x) \
		and int(row.get("z", -1)) == int(outcome.z) \
		and float(row.get("at_utc", -1.0)) == float(outcome.at_utc) \
		and int(row.get("amount", 0)) == int(outcome.losses) \
		and bool(row.get("defender_online", false)) == bool(outcome.defender_online) \
		and str(row.get("window_id", "")) == str(outcome.window_id)


## 参与文档缺失这份耐久交战行时，用实时文档重新执行同一条 `engage`，而不是
## 写回意图时刻的旧快照；这样崩溃期间发生的其它参与制度变更不会被悄悄覆盖。
func _rebuild_participation(outcome: Dictionary) -> Dictionary:
	if participation.is_empty():
		return {"ok": false, "reason": "stale_participation"}
	var candidate: Dictionary = participation.duplicate(true)
	var engaged: Dictionary = Participation.engage(candidate, world_id,
		str(outcome.attacker), str(outcome.defender), int(outcome.x), int(outcome.z),
		float(outcome.at_utc), int(outcome.losses), bool(outcome.defender_online),
		str(outcome.command_id))
	if not bool(engaged.get("ok", false)):
		return {"ok": false, "reason": "stale_participation"}
	if str(engaged.get("window_id", "")) != str(outcome.window_id) \
			or int(engaged.get("loss_total", 0)) \
				!= int(outcome.participation_loss_before) + int(outcome.losses) \
			or int(engaged.get("cap", 0)) != int(outcome.participation_cap):
		return {"ok": false, "reason": "stale_participation"}
	return {"ok": true, "state": candidate}


func _recover_conflict(command_id: String, outcome: Dictionary,
		entry: Dictionary) -> Dictionary:
	var cash: Dictionary = _conflict_cash_status(outcome)
	if not bool(cash.get("ok", false)):
		return _conflict_result(false, str(cash.get("reason", "stale_resources")),
			"engage", false)
	if bool(cash.get("partial", false)):
		return _conflict_result(false, "stale_resources", "engage", false)
	var supplies: Dictionary = _conflict_supplies_status(outcome)
	if not bool(supplies.get("ok", false)):
		return _conflict_result(false, str(supplies.get("reason", "stale_resources")),
			"engage", false)
	# 没有现金分录时（防守方现金为 0）`cash.applied` 只是空真：此时农场是否
	# 已提交只能由物资前后值判断。现金与物资都有证据却相互矛盾时，磁盘已被
	# 外部改动，不能猜哪一半生效。
	var cash_known: bool = int(cash.get("required", 0)) > 0
	if cash_known \
			and bool(cash.applied) != bool(supplies.applied):
		return _conflict_result(false, "stale_resources", "engage", false)
	var farm_applied: bool = bool(cash.applied) if cash_known \
		else bool(supplies.applied)

	var plan_value: Variant = entry.get("unit_plan", {})
	if not plan_value is Dictionary:
		return _conflict_result(false, "invalid_units", "engage", false)
	var units_status: Dictionary = _conflict_units_status(plan_value)
	if not bool(units_status.get("ok", false)):
		return _conflict_result(false, str(units_status.get("reason", "invalid_units")),
			"engage", false)
	var participation_applied: bool = _participation_has_engagement(outcome)

	if not farm_applied:
		if bool(units_status.applied) or participation_applied:
			return _conflict_result(false, "stale_resources", "engage", false)
		var farm_result: Dictionary = _apply_conflict_farm(outcome)
		if not bool(farm_result.get("ok", false)):
			return _conflict_result(false, str(farm_result.get("reason", "")),
				"engage", false)
	if not bool(units_status.applied):
		var units_result: Dictionary = _apply_conflict_unit_plan(plan_value)
		if not bool(units_result.get("ok", false)):
			return _conflict_result(false, str(units_result.get("reason", "")),
				"engage", false)
	if not participation_applied:
		var rebuilt: Dictionary = _rebuild_participation(outcome)
		if not bool(rebuilt.get("ok", false)):
			return _conflict_result(false, str(rebuilt.get("reason", "")),
				"engage", false)
		var candidate_state: Dictionary = conflicts.duplicate(true)
		candidate_state["participation"] = rebuilt.state
		if not ConflictSettlement.valid_context(candidate_state):
			return _conflict_result(false, "stale_participation", "engage", false)
		var participation_saved: Dictionary = participation_store.save_state(
			rebuilt.state)
		if not participation_saved.ok:
			return _conflict_result(false,
				"save_participation_" + str(participation_saved.kind), "engage", false)
		participation = rebuilt.state
		conflicts = candidate_state
	var marked: Dictionary = _conflict_mark_applied(command_id, true)
	if not marked.ok:
		return _conflict_result(false, "save_conflicts_" + str(marked.kind),
			"engage", false)
	return _conflict_duplicate(outcome, true)


func _apply_conflict_unit_plan(plan: Dictionary) -> Dictionary:
	var next: Dictionary = units.duplicate(true)
	var rows_value: Variant = next.get("units")
	if not rows_value is Dictionary:
		return {"ok": false, "reason": "invalid_units"}
	var rows: Dictionary = rows_value
	for unit_id: String in plan.keys():
		var pair_value: Variant = plan[unit_id]
		if not pair_value is Array or (pair_value as Array).size() != 2:
			return {"ok": false, "reason": "invalid_units"}
		var after: int = int((pair_value as Array)[1])
		if after <= 0:
			rows.erase(unit_id)
			continue
		var row_value: Variant = rows.get(unit_id)
		if not row_value is Dictionary:
			return {"ok": false, "reason": "invalid_units"}
		var row: Dictionary = row_value
		row["people"] = after
		rows[unit_id] = row
	next["sequence"] = int(next.get("sequence", 0)) + 1
	if not UnitState.valid(next):
		return {"ok": false, "reason": "invalid_units"}
	var saved: Dictionary = units_store.save_state(next)
	if not saved.ok:
		return {"ok": false, "reason": "save_units_" + str(saved.kind)}
	units = next
	return {"ok": true, "reason": ""}


func _conflict_mark_applied(command_id: String, applied: bool) -> Dictionary:
	var entry_value: Variant = _conflict_applied.get(command_id)
	if not entry_value is Dictionary:
		return {"ok": false, "kind": "missing"}
	var applied_map: Dictionary = _conflict_applied.duplicate(true)
	var entry: Dictionary = applied_map[command_id]
	entry["applied"] = applied
	# 完成后不再需要逐单位恢复数据；签名保留，用于区分正常重放与换载荷冲突。
	entry.erase("unit_plan")
	applied_map[command_id] = entry
	var saved: Dictionary = conflicts_store.save_state(conflicts, applied_map)
	if not saved.ok:
		return saved
	_conflict_applied = applied_map
	return {"ok": true, "kind": "saved"}


func _pending_conflict_id() -> String:
	for command_id: Variant in _conflict_applied:
		var entry_value: Variant = _conflict_applied[command_id]
		if entry_value is Dictionary \
				and not bool((entry_value as Dictionary).get("applied", true)):
			return str(command_id)
	return ""


func _conflict_outcome(command_id: String) -> Dictionary:
	var consumed_value: Variant = conflicts.get("consumed")
	if not consumed_value is Dictionary:
		return {}
	var entry_value: Variant = (consumed_value as Dictionary).get(command_id)
	if not entry_value is Dictionary:
		return {}
	var outcome_value: Variant = (entry_value as Dictionary).get("outcome")
	if not outcome_value is Dictionary:
		return {}
	return (outcome_value as Dictionary).duplicate(true)


func _conflict_duplicate(outcome: Dictionary, recovered: bool) -> Dictionary:
	return {
		"ok": true, "reason": "", "action": "engage", "duplicate": true,
		"recovered": recovered, "outcome": outcome.duplicate(true),
		"state": conflicts_view(),
	}


static func _conflict_result(ok: bool, reason: String, action: String,
		duplicate: bool) -> Dictionary:
	return {"ok": ok, "reason": reason, "action": action, "duplicate": duplicate}


static func _conflict_failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


static func _conflict_pay_reason(reason: String) -> String:
	match reason:
		"insufficient", "unknown_account":
			return "insufficient_cash"
		"command_conflict", "duplicate_event":
			return "command_conflict"
	return "pay_" + reason


## 结算层把和平档叫作 `peace_time`（它同时承担时间窗口语义）；对外权威回复
## 统一成 `peace`，避免客户端同时处理两套词表。规则本身不改。
static func _conflict_rule_reason(reason: String) -> String:
	match reason:
		"peace_time":
			return "peace"
		"duplicate_command":
			return "command_conflict"
	return reason


func _owner_supplies_of(candidate: RefCounted, owner: String) -> int:
	var goods: Dictionary = candidate.economy_goods(owner)
	var total: int = 0
	for good_id: String in EconomyCatalog.goods_ids():
		total += int(goods.get(good_id, 0))
	return total


## 战利品物资没有按商品记账：按 EconomyCatalog 的稳定顺序加入第一项，保持
## 确定性，并且总量与结算 outcome 一致。
func _add_supplies(candidate: RefCounted, owner: String, amount: int) -> bool:
	if amount <= 0:
		return true
	var goods_ids: Array[String] = EconomyCatalog.goods_ids()
	if goods_ids.is_empty():
		return false
	var data: Dictionary = candidate.snapshot()
	var bags_value: Variant = data.get("bags")
	if not bags_value is Dictionary:
		return false
	var bags: Dictionary = bags_value
	var pocket_value: Variant = bags.get(owner)
	var pocket: Dictionary = pocket_value if pocket_value is Dictionary else {}
	var good_id: String = goods_ids[0]
	pocket[good_id] = int(pocket.get(good_id, 0)) + amount
	bags[owner] = pocket
	data["bags"] = bags
	return candidate.restore_snapshot(data)


static func _conflict_player(value: Variant) -> bool:
	return value is String and str(value) != "public" and OwnerIds.valid(value)


static func _conflict_coord(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number == floorf(number) \
		and number >= 0.0 and number <= float(ConflictSettlement.MAX_COORD)


static func _conflict_entry_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= ConflictSettlement.MAX_ENTRY_ID_LENGTH \
		and OwnerIds.valid(value)


## 组织账户与 `@world` 一样不是初始经济文档预置的账户。候选农场上按空账户补齐，
## 0 现金不改变 `total_cash == issued`；真正的资金仍由 `economy_pay` 转移。
func _farm_candidate_with_accounts(account_ids: Array) -> RefCounted:
	if farm == null or account_ids.is_empty():
		return null
	var candidate: RefCounted = farm.copy()
	var data: Dictionary = candidate.snapshot()
	var economy_value: Variant = data.get("economy")
	if not economy_value is Dictionary:
		return null
	var economy: Dictionary = economy_value
	var accounts_value: Variant = economy.get("accounts")
	if not accounts_value is Dictionary:
		return null
	var accounts: Dictionary = accounts_value
	for value: Variant in account_ids:
		var account_id: String = str(value)
		if not account_id.is_empty() and not accounts.has(account_id):
			accounts[account_id] = {"cash": 0, "granted": false}
	if not candidate.restore_snapshot(data):
		return null
	return candidate


static func _whole_amount(value: Variant) -> int:
	if not value is int and not value is float:
		return -1
	var number: float = float(value)
	if not is_finite(number) or number != floorf(number):
		return -1
	if number < 0.0 or number > float(PublicFund.MAX_SAFE_INTEGER):
		return -1
	return int(number)


static func _fund_pay_reason(reason: String) -> String:
	match reason:
		"insufficient", "unknown_account":
			return "insufficient_cash"
		"command_conflict", "duplicate_event":
			return "command_conflict"
	return "pay_" + reason


## @world 是公共库存的账户，但初始经济文档不会预先创建它。招募把现金转入这个
## 账户，所以在候选农场上按空账户补齐；0 现金不改变 `total_cash == issued`，也不
## 需要账本分录。真正转账仍由 `economy_pay` 完成并写入平衡分录。
func _farm_candidate_with_world_account() -> RefCounted:
	if farm == null:
		return null
	var candidate: RefCounted = farm.copy()
	var data: Dictionary = candidate.snapshot()
	var economy_value: Variant = data.get("economy")
	if not economy_value is Dictionary:
		return null
	var economy: Dictionary = economy_value
	var accounts_value: Variant = economy.get("accounts")
	if not accounts_value is Dictionary:
		return null
	var accounts: Dictionary = accounts_value
	if not accounts.has(Economy.WORLD_OWNER):
		accounts[Economy.WORLD_OWNER] = {"cash": 0, "granted": false}
	if not candidate.restore_snapshot(data):
		return null
	return candidate


## 按 EconomyCatalog 的稳定目录顺序从 owner 口袋扣除粮草。调用方已经确认总额
## 足够；这里再逐项取最小值，任何缺口都让整次候选作废而不是留下负库存。
func _deduct_supplies(candidate: RefCounted, owner: String, amount: int) -> bool:
	if amount <= 0:
		return true
	var data: Dictionary = candidate.snapshot()
	var bags_value: Variant = data.get("bags")
	if not bags_value is Dictionary:
		return false
	var bags: Dictionary = bags_value
	var pocket_value: Variant = bags.get(owner)
	if not pocket_value is Dictionary:
		return false
	var pocket: Dictionary = pocket_value
	var remaining: int = amount
	for good_id: String in EconomyCatalog.goods_ids():
		var have: int = int(pocket.get(good_id, 0))
		var take: int = mini(have, remaining)
		if take > 0:
			pocket[good_id] = have - take
			remaining -= take
		if remaining <= 0:
			break
	if remaining > 0:
		return false
	return candidate.restore_snapshot(data)


func _actor_stock(actor: String) -> Dictionary:
	var cash: int = farm.economy_cash(actor) if farm != null else 0
	var total: int = _owner_supplies(actor)
	return {"cash": cash, "supplies": total}


func _owner_supplies(owner: String) -> int:
	if farm == null:
		return 0
	var goods: Dictionary = farm.economy_goods(owner)
	var total: int = 0
	for good_id: String in EconomyCatalog.goods_ids():
		total += int(goods.get(good_id, 0))
	return total


## 把主文档拆成只含一名 owner 的合法子文档，供 `UnitState.upkeep` 按该 owner 的
## 口袋独立结算。招募记录与已解散记录一起保留，否则严格校验会因为缺少来源而拒绝。
func _owner_document(owner: String) -> Dictionary:
	var units_value: Variant = units.get("units")
	var commands_value: Variant = units.get("commands")
	if not units_value is Dictionary or not commands_value is Dictionary:
		return {}
	var by_id: Dictionary = units_value
	var commands: Dictionary = commands_value
	var own_units: Dictionary = {}
	var disbanded: Dictionary = {}
	for unit_id: Variant in by_id:
		var row_value: Variant = by_id[unit_id]
		if row_value is Dictionary \
				and str((row_value as Dictionary).get("owner", "")) == owner:
			own_units[str(unit_id)] = (row_value as Dictionary).duplicate(true)
	for command_id: Variant in commands:
		var entry_value: Variant = commands[command_id]
		if not entry_value is Dictionary:
			continue
		var result_value: Variant = (entry_value as Dictionary).get("result")
		if not result_value is Dictionary:
			continue
		var result: Dictionary = result_value
		if str(result.get("kind", "")) != UnitState.RECORD_DISBAND:
			continue
		var parsed: Variant = _parse_json_text(
			str((entry_value as Dictionary).get("payload", "")))
		if parsed is Array and (parsed as Array).size() == 3 \
				and str((parsed as Array)[2]) == owner:
			disbanded[str(result.get("unit_id", ""))] = true
	var own_commands: Dictionary = {}
	for command_id: Variant in commands:
		var entry_value: Variant = commands[command_id]
		if not entry_value is Dictionary:
			continue
		var result_value: Variant = (entry_value as Dictionary).get("result")
		if not result_value is Dictionary:
			continue
		var result: Dictionary = result_value
		var result_unit: String = str(result.get("unit_id", ""))
		if str(result.get("kind", "")) == UnitState.RECORD_RECRUIT:
			if own_units.has(result_unit) or disbanded.has(result_unit):
				own_commands[str(command_id)] = (entry_value as Dictionary).duplicate(true)
		elif str(result.get("kind", "")) == UnitState.RECORD_DISBAND \
				and disbanded.has(result_unit):
			own_commands[str(command_id)] = (entry_value as Dictionary).duplicate(true)
	var document: Dictionary = {
		"world_id": str(units.get("world_id", "")),
		"sequence": int(units.get("sequence", 0)),
		"last_upkeep_utc": float(units.get("last_upkeep_utc", -1.0)),
		"units": own_units,
		"commands": own_commands,
	}
	return document if UnitState.valid(document) else {}


## 同一命令 id 的重试必须复用首次记录的时刻，否则规则会把新的 `now_utc` 视为
## 不同 payload 并返回 `command_conflict`。解散 payload 不带时间，不受影响。
## 新记录量化到整秒：招募时 `last_wage_utc` 就取这个时刻，工资按整日累计，
## 不足一秒的零头会让「恰好一整天」算成 0 天，与补给结算的量化保持一致。
func _unit_action_time(command_id: String) -> float:
	var commands_value: Variant = units.get("commands")
	if commands_value is Dictionary \
			and (commands_value as Dictionary).has(command_id):
		var entry_value: Variant = (commands_value as Dictionary)[command_id]
		if entry_value is Dictionary:
			var parsed: Variant = _parse_json_text(
				str((entry_value as Dictionary).get("payload", "")))
			if parsed is Array and (parsed as Array).size() == 7:
				var stamp: Variant = (parsed as Array)[6]
				if stamp is int or stamp is float:
					return float(stamp)
	return floorf(authority_now_utc())


## 查找农场账本里本命令的 `unit_pay_<id>` 分录。只有金额、付款方与 @world 收款
## 三方都匹配才算“已付款”，避免其它命令 id 或另一个 actor 冒用同一单位 id。
func _unit_payment_marker(command_id: String, actor: String) -> Dictionary:
	return _ledger_payment_marker(_unit_payment_id(command_id), actor,
		Economy.WORLD_OWNER)


## 某个业务事件在农场账本中的付款证据。金额、付款方与收款方三方都匹配才返回
## {amount, at_utc}；基金缴入/支出与单位招募共用这一份核对。
func _ledger_payment_marker(event_id: String, from_owner: String,
		to_owner: String) -> Dictionary:
	if farm == null:
		return {}
	var expected_from: String = Ledger.owner_code(from_owner)
	var expected_to: String = Ledger.owner_code(to_owner)
	for value: Variant in farm.economy_ledger_entries():
		if not value is Dictionary:
			continue
		var entry: Dictionary = value
		if str(entry.get("event_id", "")) != event_id:
			continue
		if str(entry.get("kind", "")) != Ledger.KIND_PAY:
			return {}
		var amount: int = int(entry.get("debit", 0))
		if amount <= 0:
			return {}
		var lines_value: Variant = entry.get("lines")
		if not lines_value is Array:
			return {}
		var from_ok: bool = false
		var to_ok: bool = false
		for line_value: Variant in lines_value:
			if not line_value is Dictionary:
				return {}
			var line: Dictionary = line_value
			if str(line.get("account", "")) == expected_to \
					and int(line.get("debit", 0)) == amount:
				to_ok = true
			if str(line.get("account", "")) == expected_from \
					and int(line.get("credit", 0)) == amount:
				from_ok = true
		if not (from_ok and to_ok):
			return {}
		return {"amount": amount, "at_utc": float(entry.get("at_utc", 0.0))}
	return {}


## UnitState 的招募成本在这里只用于“农场已付款、单位未写盘”的重试路径；正常
## 路径始终以规则返回的 cost 为准。
static func _recruit_cost(command: Dictionary) -> Dictionary:
	var kind: String = str(command.get("kind", ""))
	var equipment: String = str(command.get("equipment", ""))
	if not UnitState.CATALOG.has(kind) or not UnitState.EQUIPMENT.has(equipment):
		return {}
	var people_value: Variant = command.get("people")
	if not (people_value is int or people_value is float):
		return {}
	var number: float = float(people_value)
	if not is_finite(number) or number != floorf(number):
		return {}
	var people: int = int(number)
	if people < 1 or people > UnitState.MAX_PEOPLE_PER_UNIT:
		return {}
	var per_person: int = int(UnitState.CATALOG[kind]["cash_cost_per_person"]) \
		+ int(UnitState.EQUIPMENT[equipment]["cash_cost_per_person"])
	return {
		"cash": per_person * people,
		"supplies": int(UnitState.CATALOG[kind]["daily_supply_per_person"]) * people,
	}


static func _unit_payment_id(command_id: String) -> String:
	return "unit_pay_" + command_id


## 一次工资发放的持久事件 id。只由 owner 与结算前各单位的 `last_wage_utc` 决定，
## 与调用方的命令 id 和真实时间无关：单位文档没写成功时前状态不变，重试会复用
## 同一条分录。摘要取 64 个字符，长度远低于账本 160 字符上限。
static func _wage_payment_id(owner: String, document: Dictionary) -> String:
	var clocks: Array[String] = []
	var rows_value: Variant = document.get("units")
	if rows_value is Dictionary:
		var by_id: Dictionary = rows_value
		for unit_id: Variant in by_id:
			var row_value: Variant = by_id[unit_id]
			if not row_value is Dictionary:
				continue
			clocks.append("%s@%.0f" % [str(unit_id),
				float((row_value as Dictionary).get("last_wage_utc", 0.0))])
	clocks.sort()
	return "unit_wage_" + (owner + "|" + ",".join(clocks)).sha256_text()


static func _unit_pay_reason(reason: String) -> String:
	match reason:
		"insufficient", "unknown_account":
			return UnitState.REASON_INSUFFICIENT_CASH
		"command_conflict", "duplicate_event":
			return "command_conflict"
	return "pay_" + reason


static func _unit_result(ok: bool, reason: String, action: String,
		unit_id: String, duplicate: bool) -> Dictionary:
	return {
		"ok": ok, "reason": reason, "action": action,
		"unit_id": unit_id, "duplicate": duplicate,
	}


static func _parse_json_text(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


func _ensure_nature_persisted() -> Dictionary:
	if nature == null or nature_store == null:
		return {"ok": false, "kind": "not_open"}
	if _nature_persisted:
		return {"ok": true, "kind": "already_saved"}
	# Re-read before writing. If another authority won a first-creation race, its
	# seed is the one this world must keep; the farm commit below will be refused
	# by the existing expected-file check, so adopting the seed cannot fork the
	# weather history even though it changes this session's in-memory value.
	var current: Dictionary = nature_store.load_state()
	if not current.ok:
		return {"ok": false, "kind": "reread_" + str(current.kind)}
	if current.kind == "loaded":
		if not nature.restore_snapshot(current.state):
			return {"ok": false, "kind": "corrupt"}
		_nature_persisted = true
		return {"ok": true, "kind": "adopted"}
	var saved: Dictionary = nature_store.save_state(nature.snapshot())
	if saved.ok:
		_nature_persisted = true
	return saved


## The full restorable authority as one document: the farm, decorations and
## deterministic nature seed, plus the logical clock. A member that lost the
## event tail restores from this instead of accepting a hole in its history.
func state_snapshot() -> Dictionary:
	if farm == null:
		return {}
	return {
		"now_utc": now_utc,
		"farm": farm.snapshot(),
		"decorations": decorations.snapshot(),
		"nature": nature.snapshot(),
	}


## The cadastre as members see it: which yard slot holds whose land.
## Ownership is public so the housing panel can say who a yard belongs to before
## a build is refused. Claim command ids stay in the authority document.
func territory_display() -> Dictionary:
	if territory.is_empty():
		return {}
	var parcels: Array = []
	var stored: Variant = territory.get("parcels")
	if stored is Dictionary:
		var by_id: Dictionary = stored
		for parcel_id: String in by_id.keys():
			var parcel: Variant = by_id[parcel_id]
			if not parcel is Dictionary:
				continue
			var row: Dictionary = parcel
			parcels.append({
				"id": parcel_id,
				"slot": TerritoryState.parcel_slot_id(parcel_id),
				"owner": str(row.get("owner", "")),
				"status": str(row.get("status", "")),
				"claimed_utc": float(row.get("claimed_utc", 0.0)),
				"rect": (row.get("rect", {}) as Dictionary).duplicate(true),
			})
	parcels.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.id) < str(b.id))
	return {"sequence": int(territory.get("sequence", 0)), "parcels": parcels}


func summary() -> Dictionary:
	if farm == null:
		return {}
	var hud: Dictionary = farm.hud_state()
	var snapshot: Dictionary = farm.snapshot()
	var fields: Dictionary = {}
	for field_id: String in snapshot.fields:
		var cells: Dictionary = {}
		for cell_id: String in snapshot.fields[field_id].cells:
			var cell: Dictionary = farm.get_cell(field_id, cell_id)
			cells[cell_id] = {
				"crop_id": cell.crop_id, "stage": cell.stage, "ground": cell.ground,
				"growth_seconds": cell.growth_seconds, "watered": cell.watered,
				"moisture": cell.moisture, "moisture_label": cell.moisture_label,
				"growth_rate": cell.growth_rate,
			}
		fields[field_id] = cells
	var next_event: float = next_event_utc()
	return {
		"now_utc": now_utc, "inventory": hud.inventory, "harvested": hud.harvested,
		"bags": snapshot.bags.duplicate(true),
		"buildings": farm.buildings_at(now_utc),
		"fields": fields, "committed_commands": farm.committed_command_count(),
		"committed_sequence": farm.event_sequence(),
		"next_event_utc": next_event if is_finite(next_event) else null,
		"nature": nature_view(),
		"territory": territory_display(),
	}


## Read-only natural-time interpretation at the session clock. Online members,
## offline settlement and the single-player store all read the same seed, so
## these values never depend on which mode asked.
func nature_view() -> Dictionary:
	if nature == null:
		return {}
	var weather: Dictionary = nature.weather_at(now_utc)
	var next_weather: float = INF
	if not weather.is_empty():
		next_weather = float(weather.end_utc)
	var hazards: Dictionary = disaster_view()
	return {
		"weather": weather,
		"next_weather_utc": next_weather if is_finite(next_weather) else null,
		"season": nature.season_at(now_utc),
		"daylight": nature.daylight_at(now_utc),
		"disaster": hazards.disaster,
		"warning": hazards.warning,
		"disaster_mode": nature.get_disaster_mode(),
	}


## Read-only disaster view at the session clock. `disaster` is the event
## covering now; `warning` is an event starting inside the next block (the
## only block a warning can cover, because events align to block boundaries).
## Both are {}, and lead_seconds is only present when a warning has a start.
func disaster_view() -> Dictionary:
	if nature == null:
		return {"disaster": {}, "warning": {}}
	var current: Dictionary = nature.disaster_at(now_utc)
	var disaster: Dictionary = {}
	if not current.is_empty():
		disaster = {
			"kind": str(current.kind), "severity": int(current.severity),
			"starts_utc": float(current.start_utc), "ends_utc": float(current.end_utc),
		}
	var warning: Dictionary = {}
	var next_start: float = nature.next_disaster_at(now_utc)
	if next_start >= 0.0:
		var weather: Dictionary = nature.weather_at(now_utc)
		var block_end: float = float(weather.end_utc) if not weather.is_empty() else INF
		if next_start <= block_end + 0.001:
			var event: Dictionary = nature.disaster_at(next_start)
			if not event.is_empty():
				warning = {
					"kind": str(event.kind), "severity": int(event.severity),
					"starts_utc": float(event.start_utc), "ends_utc": float(event.end_utc),
					"lead_seconds": maxf(0.0, next_start - now_utc),
				}
	return {"disaster": disaster, "warning": warning}


## Authority-only world switch: stops or resumes future disasters and persists
## the document before the in-memory state changes. Already-settled moisture and
## growth are untouched. No network message is defined; a shared world's clients
## read the resulting authoritative disaster view instead of setting this.
func set_disaster_mode(mode: String) -> Dictionary:
	if farm == null or nature == null or nature_store == null:
		return _failure("not_open")
	if not NatureState.valid_disaster_mode(mode):
		return _failure("invalid_mode")
	if nature.get_disaster_mode() == mode:
		return {"ok": true, "kind": "unchanged", "mode": mode}
	var candidate := NatureState.new()
	if not candidate.restore_snapshot(nature.snapshot()):
		return _failure("corrupt")
	candidate.set_disaster_mode(mode)
	var saved: Dictionary = nature_store.save_state(candidate.snapshot())
	if not saved.ok:
		return _failure("save_nature_" + str(saved.kind))
	nature.set_disaster_mode(mode)
	_nature_persisted = true
	return {"ok": true, "kind": "saved", "mode": mode}


static func _merge_names(into: Array[String], values: Variant) -> void:
	if not values is Array:
		return
	for value: Variant in values:
		if value is String and not into.has(value):
			into.append(value)


static func _result(ok: bool, reason: String, duplicate: bool, command_id: String) -> Dictionary:
	return {"ok": ok, "reason": reason, "duplicate": duplicate, "command_id": command_id}


static func _failure(kind: String) -> Dictionary:
	return {"ok": false, "reason": kind}


static func _valid_time(value: float) -> bool:
	return is_finite(value) and value >= 0.0
