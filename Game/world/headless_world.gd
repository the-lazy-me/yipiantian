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


## `world_identity` names the cadastre document's world. An empty value adopts
## the identity already stored on disk (or "world" for a fresh directory), so
## old headless callers keep working without knowing the world id. An explicit
## identity must match the stored document instead of silently relabelling land.
func open(save_directory: String, now_utc_seconds: float,
		world_identity: String = "") -> Dictionary:
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
