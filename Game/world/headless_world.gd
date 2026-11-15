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
const Organization = preload("res://world/organization_state.gd")
const OrganizationStore = preload("res://world/organization_store.gd")
const UnitState = preload("res://conflict/unit_state.gd")
const UnitStore = preload("res://world/unit_store.gd")
const PublicFund = preload("res://world/public_fund.gd")
const FundStore = preload("res://world/fund_store.gd")
const Participation = preload("res://conflict/participation_state.gd")
const ParticipationStore = preload("res://world/participation_store.gd")
const Economy = preload("res://farm/economy_state.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")
const Ledger = preload("res://farm/ledger_state.gd")
const Market = preload("res://farm/market_state.gd")
const NpcIntent = preload("res://npc/npc_intent.gd")
const NpcResidentLedger = preload("res://npc/npc_resident_ledger.gd")
const NpcResidentLedgerStore = preload("res://npc/npc_resident_ledger_store.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")

# 一次成功消费后的居民冷却。意图自身的过期窗口只有 120 秒；冷却稍长，保证同一
# 权威时刻的重复扫描不会重新规划同一件事，同时给后续行为切片留下可调常量。
const RESIDENT_COOLDOWN_SECONDS: float = 300.0

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
## 参与制度文档（M12-02）。与 territory.json 同级的 world 级 sidecar；房间没有
## 房主玩家时保持为空，所有声明/同意操作返回 `no_host`。房主身份是该文档的持久
## 事实，可用启动参数显式绑定，但显式值必须与已存文档一致。
var participation: Dictionary = {}
var participation_store: ParticipationStore


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
	# 组织表同样是 world 级 sidecar。缺失是合法的空表；存在但损坏或版本不支持
	# 必须让权威停止启动，否则重启会用空表覆盖已有成员与负责人。
	organizations_store = OrganizationStore.new(directory)
	var organizations_loaded: Dictionary = organizations_store.load_state()
	if not organizations_loaded.ok:
		return _failure("load_organizations_" + str(organizations_loaded.kind))
	organizations = organizations_loaded.state
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
	var execution: Dictionary = commands.execute(farm, command, actor)
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
	if FarmCommand.is_economy_kind(str(command.kind)) or bool(scan.changed) or land_claimed:
		shared_changed.emit()
	return {
		"ok": true, "reason": "", "stage": "committed", "duplicate": false, "command_id": command.id,
		"reward_crop_id": execution.result.get("reward_crop_id", ""),
		"reward_amount": execution.result.get("reward_amount", 0),
		"market_expired": int(scan.counts.get("expired", 0)),
		"market_matched": int(scan.counts.get("matched", 0)),
		"market_delivered": int(scan.counts.get("delivered", 0)),
		"market_lost": int(scan.counts.get("lost", 0)),
		"loans_settled": int(scan.counts.get("loans", 0)),
	}


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
		"ledger_changed": false, "candidate": candidate, "document": residents,
		"counts": {}, "failures": [], "intents": []}
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
	# 农场保存成功后写居民账本。账本写失败时农场文件已经落盘，因此接受同一候选
	# 并广播，避免“磁盘领先、内存落后”的分歧；失败原因照实返回。下一次结算会
	# 重新规划同一意图，市场命令 id 仍是与该意图相同的值，重放不会产生第二笔成交，
	# 账本随后补记。
	if residents_enabled and bool(resident_outcome.ledger_changed):
		var ledger_saved: Dictionary = residents_store.save_state(resident_outcome.document)
		if not ledger_saved.ok:
			farm.accept(candidate)
			shared_changed.emit()
			return {"ok": false,
				"reason": "save_residents_" + str(ledger_saved.kind),
				"changed": true, "counts": scan.counts}
	farm.accept(candidate)
	if residents_enabled and bool(resident_outcome.ledger_changed):
		residents = resident_outcome.document
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
## 整批完成后才写盘：先确保自然种子，再保存农场，随后保存居民账本，最后更新
## 内存并广播。账本写失败时农场已经落盘，因此接受同一候选、保持内存与磁盘一致，
## 并照实返回 `save_residents_<kind>`；重试不会二次成交，账本会在后续结算补记。
func settle_residents(at_utc_seconds: float) -> Dictionary:
	if farm == null:
		return _resident_failure("not_open")
	if not is_finite(at_utc_seconds) or at_utc_seconds < 0.0:
		return _resident_failure("invalid_time")
	if not residents_enabled:
		return {"ok": true, "reason": "disabled", "changed": false,
			"counts": {"opened": 0, "purchased": 0, "failed": 0},
			"failures": [], "intents": []}
	var candidate: RefCounted = farm.copy()
	var outcome: Dictionary = _apply_residents(candidate, at_utc_seconds)
	if not bool(outcome.ok):
		return _resident_failure(str(outcome.reason))
	if not bool(outcome.changed):
		return {"ok": true, "reason": "", "changed": false,
			"counts": outcome.counts, "failures": outcome.failures,
			"intents": outcome.intents}
	var nature_saved: Dictionary = _ensure_nature_persisted()
	if not nature_saved.ok:
		return _resident_failure("save_nature_" + str(nature_saved.kind))
	var saved: Dictionary = store.save_state(outcome.candidate, decorations)
	if not saved.ok:
		return _resident_failure("save_" + str(saved.kind))
	if bool(outcome.ledger_changed):
		var ledger_saved: Dictionary = residents_store.save_state(outcome.document)
		if not ledger_saved.ok:
			# 农场文件已落盘：接受同一候选以保持内存与磁盘一致。同一意图重试时
			# 市场命令 id 不变，不会二次成交；账本在后续结算里补记。
			farm.accept(outcome.candidate)
			shared_changed.emit()
			return {"ok": false,
				"reason": "save_residents_" + str(ledger_saved.kind),
				"changed": true, "counts": outcome.counts,
				"failures": outcome.failures, "intents": outcome.intents}
	farm.accept(outcome.candidate)
	if bool(outcome.ledger_changed):
		residents = outcome.document
	shared_changed.emit()
	return {"ok": true, "reason": "", "changed": true,
		"counts": outcome.counts, "failures": outcome.failures,
		"intents": outcome.intents}


## 在候选农场与账本候选上完成三名居民的规划与成交，不写盘、不改活状态。
## 返回 {ok, reason, changed, ledger_changed, candidate, document, counts,
## failures, intents}。每次购买都在 `candidate.copy()` 上提交，只有下单与撮合
## 都成功才替换工作候选并记录账本，因此单个居民失败不会留下半笔订单。
func _apply_residents(candidate: RefCounted, at_utc_seconds: float) -> Dictionary:
	var counts: Dictionary = {"opened": 0, "purchased": 0, "failed": 0}
	var failures: Array = []
	var intents: Array = []
	var working: RefCounted = candidate
	var ledger: Dictionary = residents
	var changed: bool = false
	var ledger_changed: bool = false
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
	return {
		"ok": true, "reason": "", "changed": changed,
		"ledger_changed": ledger_changed, "candidate": working,
		"document": ledger, "counts": counts, "failures": failures,
		"intents": intents,
	}


static func _resident_failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "changed": false,
		"counts": {"opened": 0, "purchased": 0, "failed": 0},
		"failures": [], "intents": []}


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
		command_id, _territory_action_time(command_id))
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
	return _organization_result(bool(stored.get("ok", false)), str(stored.get("reason", "")),
		str(stored.get("action", "")), str(stored.get("org_id", "")), true)


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
	var owners: Array[String] = []
	for unit_id: Variant in by_id:
		var row_value: Variant = by_id[unit_id]
		if not row_value is Dictionary:
			continue
		var owner: String = str((row_value as Dictionary).get("owner", ""))
		if not owners.has(owner):
			owners.append(owner)
	owners.sort()

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


## 只读参与制度视图：风险声明、区域、窗口、成员同意与已结算损失都是公开的
## 房间事实。不下发命令窗口、命令载荷或内部重放结构。
func participation_view() -> Dictionary:
	if participation.is_empty():
		return {
			"available": false, "host": "", "sequence": 0, "regime": {},
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
	var now: float = authority_now_utc()
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


func _participation_result(ok: bool, reason: String, action: String, duplicate: bool,
		extra: Dictionary = {}) -> Dictionary:
	return {
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
	return authority_now_utc()


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
