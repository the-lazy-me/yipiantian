extends SceneTree
## M10-05 居民长期行为评估切片。无头、隔离：临时目录写在
## `.local/verification` 下；模型关闭，全部决策来自既有规则模块。
##
## 每个 60 逻辑日的世界都使用真实的 `HeadlessWorld`：
##   - 每天 `advance_to` 推进天气、作物与市场/经济扫描；
##   - 启用居民后每天用真实现金、口袋与公开卖单执行 `settle_residents()`；
##   - 社交动作和记忆写入由测试按权威状态投影后调用纯规则模块，不读墙钟。
##
## 每日断言：
##   1. total_cash == issued，居民采购不超预算、同一 intent 不二次成交；
##   2. 意图账本、冷却与失败等待有界，重放 intent id 返回 duplicate_intent；
##   3. 记忆条数不超过既有 64 条上限，事件 id 去重，社交/记忆写入不改公开账本；
##   4. 关系与社交动作有界，无自我社交、无无限赠礼（固定冷却与每日上限）；
##   5. 世界经济、意图、记忆、社交文档仍通过各自 valid()；
##   6. 固定 seed/命令/逻辑时钟下两次独立运行指纹一致；
##   7. 市场订单/成交/复式账、记忆、社交表均沿用既有容量常数。
##
## 不覆盖：模型、UI、网络、Windows、真实墙钟驻留。

const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const Economy = preload("res://farm/economy_state.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")
const Ledger = preload("res://farm/ledger_state.gd")
const Market = preload("res://farm/market_state.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")
const NpcIntent = preload("res://npc/npc_intent.gd")
const IntentState = preload("res://npc/npc_intent_state.gd")
const ResidentLedger = preload("res://npc/npc_resident_ledger.gd")
const Memory = preload("res://npc/npc_memory.gd")
const MemoryFeed = preload("res://npc/npc_memory_feed.gd")
const Social = preload("res://npc/npc_social.gd")
const SocialMemory = preload("res://npc/npc_social_memory.gd")

const START: float = 1800028800.0
const DAY: float = 86400.0
const DAYS: int = 60
const RULES_VERSION: int = 2
const SEED: int = 42017
const WORLD_ID: String = "resident-long-run"
const HOST: String = "resident_host"
const RUNS: int = 2

## 调用方每天最多尝试的社交次数（目录恰好四种动作；同一时刻每种动作受
## 既有冷却约束，因此 4 是固定目录上的硬上界）。
const DAILY_SOCIAL_CAP: int = 4
## 调用方每天给每位居民的赠礼预算；赠礼目录本身还有每对 8 次上限。
const GIFT_BUDGET_PER_DAY: int = 1
const MAX_FAILURES_PER_SWEEP: int = 3
const GOODS_TOTAL: int = 120
## `HeadlessWorld.RESIDENT_COOLDOWN_SECONDS`；在这里固定一份，避免测试依赖
## 运行时常量路径。
const RESIDENT_COOLDOWN_SECONDS: float = 300.0

var checks: int = 0
var failures: Array[String] = []
var base_root: String = ""


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	base_root = project_root.get_base_dir().path_join(
		".local/verification/resident-long-run-%d-%d"
		% [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(base_root)
	var started_ms: int = Time.get_ticks_msec()
	_run()
	var elapsed_ms: int = Time.get_ticks_msec() - started_ms
	for failure: String in failures:
		push_error(failure)
	print("ELAPSED_MS=%d" % elapsed_ms)
	print("RESIDENT_LONG_RUN_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run() -> void:
	var first: Dictionary = _simulate("run-a")
	var second: Dictionary = _simulate("run-b")
	_expect(str(first.fingerprint) == str(second.fingerprint),
		"determinism: the two independent runs must share one fingerprint")
	_expect(int(first.issued) == int(second.issued)
		and int(first.total) == int(second.total),
		"determinism: the two runs must keep the same issued/total cash")
	print("DETERMINISM first=%s second=%s equal=%s" % [
		str(first.fingerprint), str(second.fingerprint),
		str(str(first.fingerprint) == str(second.fingerprint))])
	print("MEASURE residents=%d days=%d trades=%d intents=%d memories=%d "
		% [NpcRoster.IDS.size(), DAYS, int(first.trades), int(first.intents),
		int(first.memories)]
		+ "social=%d cash_issued=%d final_total=%d fingerprint=%s" % [
		int(first.social), int(first.issued), int(first.total),
		str(first.fingerprint)])


# ---------------------------------------------------------------------------
# One 60-day world.
# ---------------------------------------------------------------------------

func _simulate(run_name: String) -> Dictionary:
	var directory: String = base_root.path_join(run_name)
	DirAccess.make_dir_recursive_absolute(directory)
	var seeded: Dictionary = NatureStore.new(directory).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	_expect(bool(seeded.get("ok", false)),
		"%s: the fixed seed is persisted before the world opens" % run_name)
	var world = HeadlessWorld.new()
	var opened: Dictionary = world.open(directory, START, WORLD_ID, HOST)
	_expect(bool(opened.get("ok", false)),
		"%s: the authority opens the world (reason=%s)"
		% [run_name, str(opened.get("reason", ""))])
	_expect(str(opened.get("kind", "")) == "created",
		"%s: the directory starts fresh" % run_name)

	var initialized: Dictionary = NpcRoster.initialize(WORLD_ID, SEED)
	_expect(bool(initialized.get("ok", false)),
		"%s: the roster and baseline memory initialize" % run_name)
	var roster: Dictionary = initialized.roster
	var memory: Dictionary = initialized.memory
	var social: Dictionary = _initial_social()
	_expect(Social.valid(social), "%s: the initial relation document is valid" % run_name)
	_expect(Memory.valid_document(memory, START + DAY),
		"%s: the baseline memory document is valid" % run_name)

	world.enable_residents()
	_expect(world.residents_enabled, "%s: the authority enables residents" % run_name)

	var advanced: Dictionary = world.advance_to(START + DAY)
	_expect(bool(advanced.get("ok", false)), "%s: the logical clock reaches day 1" % run_name)

	var seen_intent_ids: Dictionary = {}
	var seen_act_ids: Dictionary = {}
	var purchased: Dictionary = {}
	var dropped_watermark: Dictionary = {}
	for npc_id: String in NpcRoster.IDS:
		purchased[npc_id] = 0
		dropped_watermark[npc_id] = 0
	var total_actions: int = 0
	var total_gifts: int = 0
	var total_feed_writes: int = 0

	for day: int in range(1, DAYS + 1):
		var now: float = START + float(day) * DAY
		if day > 1:
			var moved: Dictionary = world.advance_to(now)
			_expect(bool(moved.get("ok", false)),
				"%s day %d: advance to the next logical day" % [run_name, day])
		if day == 1:
			var market: Dictionary = world.execute(
				FarmCommand.make_market_open("resident-market-open", now))
			_expect(bool(market.get("ok", false)),
				"%s day 1: the merchant market opens with public asks (reason=%s)"
				% [run_name, str(market.get("reason", ""))])

		var cash_before: Dictionary = {}
		var existed_before: Dictionary = {}
		for npc_id: String in NpcRoster.IDS:
			cash_before[npc_id] = world.farm.economy_cash(npc_id)
			existed_before[npc_id] = _account_exists(world.farm, npc_id)
		var trades_before: int = world.farm.market_trades().size()

		var swept: Dictionary = world.settle_residents(now)
		_expect(bool(swept.get("ok", false)),
			"%s day %d: the resident sweep succeeds (reason=%s)"
			% [run_name, day, str(swept.get("reason", ""))])
		var counts: Dictionary = swept.get("counts", {})
		var daily_failures: Array = swept.get("failures", [])
		var daily_intents: Array = swept.get("intents", [])
		_expect(int(counts.get("purchased", 0)) == daily_intents.size(),
			"%s day %d: every reported purchase has one intent" % [run_name, day])
		_expect(int(counts.get("purchased", 0)) + int(counts.get("failed", 0))
			== NpcRoster.IDS.size(),
			"%s day %d: every resident has exactly one terminal outcome"
			% [run_name, day])
		_expect(daily_failures.size() <= MAX_FAILURES_PER_SWEEP,
			"%s day %d: at most %d residents fail in one sweep"
			% [run_name, day, MAX_FAILURES_PER_SWEEP])

		# One resident cannot be both purchased and failed in the same sweep.
		var outcome_ids: Dictionary = {}
		for row: Variant in daily_intents:
			var intent_row: Dictionary = row
			var resident: String = str(intent_row.get("resident", ""))
			_expect(not outcome_ids.has(resident),
				"%s day %d: %s has one outcome only" % [run_name, day, resident])
			outcome_ids[resident] = true
		for row: Variant in daily_failures:
			var failure_row: Dictionary = row
			var resident: String = str(failure_row.get("resident", ""))
			_expect(not outcome_ids.has(resident),
				"%s day %d: %s cannot both buy and fail" % [run_name, day, resident])
			outcome_ids[resident] = true
			_expect(not str(failure_row.get("reason", "")).is_empty(),
				"%s day %d: %s's failure is named" % [run_name, day, resident])
		_expect(outcome_ids.size() == NpcRoster.IDS.size(),
			"%s day %d: every resident is accounted for" % [run_name, day])

		# Purchases: unique intent id, real budget, exact cash movement.
		var spend_by_resident: Dictionary = {}
		for npc_id: String in NpcRoster.IDS:
			spend_by_resident[npc_id] = 0
		for row: Variant in daily_intents:
			var intent_row: Dictionary = row
			var resident: String = str(intent_row.get("resident", ""))
			var intent_id: String = str(intent_row.get("intent", ""))
			var quantity: int = int(intent_row.get("quantity", 0))
			var price: int = int(intent_row.get("price", 0))
			_expect(not intent_id.is_empty() and not seen_intent_ids.has(intent_id),
				"%s day %d: intent %s is executed at most once"
				% [run_name, day, intent_id])
			seen_intent_ids[intent_id] = true
			_expect(quantity > 0 and price > 0,
				"%s day %d: a purchase has a positive quantity and price"
				% [run_name, day])
			spend_by_resident[resident] = int(spend_by_resident[resident]) \
				+ quantity * price
			purchased[resident] = int(purchased[resident]) + 1
			var order: Dictionary = world.farm.market_order(intent_id)
			_expect(str(order.get("owner", "")) == resident,
				"%s day %d: the order is owned by the buying resident"
				% [run_name, day])
			_expect(str(order.get("side", "")) == Market.SIDE_BUY \
				and str(order.get("status", "")) == Market.STATUS_FILLED,
				"%s day %d: the intent is a filled buy" % [run_name, day])
			var replay: Dictionary = _replay_intent(world, intent_row, now)
			_expect(not bool(replay.get("ok", true)),
				"%s day %d: replaying the consumed intent is refused"
				% [run_name, day])
			_expect(str(replay.get("reason", "")) == "duplicate_intent",
				"%s day %d: the refusal is named duplicate_intent"
				% [run_name, day])

		for npc_id: String in NpcRoster.IDS:
			var grant: int = 0 if bool(existed_before[npc_id]) else Economy.OPENING_GRANT
			var expected: int = int(cash_before[npc_id]) + grant \
				- int(spend_by_resident[npc_id])
			var cash_after: int = world.farm.economy_cash(npc_id)
			_expect(cash_after == expected,
				"%s day %d: %s spends exactly its intent total (%d vs %d)"
				% [run_name, day, npc_id, cash_after, expected])
			_expect(cash_after >= 0,
				"%s day %d: %s cash never goes negative" % [run_name, day, npc_id])
			_expect(int(spend_by_resident[npc_id]) <= int(cash_before[npc_id]) + grant,
				"%s day %d: %s never spends beyond budget" % [run_name, day, npc_id])

		# Same-instant replay: cooldown/ledger stop a second sweep.
		var second_sweep: Dictionary = world.settle_residents(now)
		_expect(bool(second_sweep.get("ok", false)),
			"%s day %d: the repeated sweep is accepted" % [run_name, day])
		_expect(not bool(second_sweep.get("changed", true)),
			"%s day %d: the repeated sweep changes nothing" % [run_name, day])
		_expect(world.farm.market_trades().size() == trades_before \
			+ daily_intents.size(),
			"%s day %d: exactly the reported purchases settled"
			% [run_name, day])

		# Intent ledger and cooldown bounds.
		_expect(ResidentLedger.valid(world.residents),
			"%s day %d: the resident intent ledger stays valid" % [run_name, day])
		for npc_id: String in NpcRoster.IDS:
			var state: Dictionary = ResidentLedger.state_for(world.residents, npc_id)
			_expect(IntentState.valid(state),
				"%s day %d: %s's intent state stays valid" % [run_name, day, npc_id])
			_expect((state.intents as Dictionary).size()
				<= IntentState.MAX_RECORDS,
				"%s day %d: %s's intent ledger stays bounded"
				% [run_name, day, npc_id])
			_expect(float(state.until_utc)
				<= now + RESIDENT_COOLDOWN_SECONDS + 0.001,
				"%s day %d: %s's cooldown never runs past one purchase + 300s"
				% [run_name, day, npc_id])
			for intent_id: Variant in state.intents:
				_expect(float(state.intents[intent_id]) <= float(state.until_utc),
					"%s day %d: %s's consumption is never later than its cooldown"
					% [run_name, day, npc_id])
			_expect((state.intents as Dictionary).size() == int(purchased[npc_id]),
				"%s day %d: %s's ledger records every purchase exactly once"
				% [run_name, day, npc_id])

		# Social + memory: private documents never touch the public ledger.
		var ledger_before_private: String = JSON.stringify(world.residents)
		var economy_before_private: String = JSON.stringify(world.farm.economy_snapshot())
		var day_result: Dictionary = _social_and_memory_day(
			world, roster, social, memory, run_name, day, now, seen_act_ids)
		social = day_result.social
		memory = day_result.memory
		total_actions += int(day_result.actions)
		total_gifts += int(day_result.gifts)
		total_feed_writes += int(day_result.feed_written)
		_expect(JSON.stringify(world.residents) == ledger_before_private,
			"%s day %d: social and memory never change the intent ledger"
			% [run_name, day])
		_expect(JSON.stringify(world.farm.economy_snapshot())
			== economy_before_private,
			"%s day %d: social and memory never change the public economy"
			% [run_name, day])

		# Memory capacity and monotonic eviction counter.
		for npc_id: String in NpcRoster.IDS:
			var row: Dictionary = _memory_row(memory, npc_id)
			var entries: Dictionary = row.get("entries", {})
			_expect(entries.size() <= Memory.MAX_ENTRIES,
				"%s day %d: %s's memory stays within %d entries"
				% [run_name, day, npc_id, Memory.MAX_ENTRIES])
			var dropped: int = int(row.get("dropped", 0))
			_expect(dropped >= int(dropped_watermark[npc_id]),
				"%s day %d: %s's dropped counter never decreases"
				% [run_name, day, npc_id])
			dropped_watermark[npc_id] = dropped
		_expect(bool(Memory.validate_document(memory, now).get("ok", false)),
			"%s day %d: the memory document stays valid" % [run_name, day])
		_expect(Social.valid(social),
			"%s day %d: the relation document stays valid" % [run_name, day])

		# World and economy invariants.
		_expect(world.farm.economy_total_cash() == world.farm.economy_issued(),
			"%s day %d: total cash equals issued" % [run_name, day])
		_expect(bool(world.farm.economy_reconcile().get("ok", false)),
			"%s day %d: the double-entry ledger reconciles" % [run_name, day])
		_expect(_goods_total(world.farm) == GOODS_TOTAL,
			"%s day %d: goods conservation stays at %d" % [run_name, day, GOODS_TOTAL])
		_expect(Economy.valid(world.farm.economy_snapshot()),
			"%s day %d: the economy document is valid" % [run_name, day])
		_expect(Market.valid(world.farm.economy_snapshot()),
			"%s day %d: the market document is valid" % [run_name, day])

		# Existing capacity constants bound every event table.
		_expect(world.farm.market_orders().size() <= Market.MAX_ORDERS,
			"%s day %d: market orders stay within MAX_ORDERS" % [run_name, day])
		_expect(world.farm.market_trades().size() <= Market.MAX_TRADES,
			"%s day %d: market trades stay within MAX_TRADES" % [run_name, day])
		_expect(world.farm.market_shipments().size() <= Market.MAX_SHIPMENTS,
			"%s day %d: shipments stay within MAX_SHIPMENTS" % [run_name, day])
		_expect(world.farm.market_deliveries().size() <= Market.MAX_DELIVERIES,
			"%s day %d: deliveries stay within MAX_DELIVERIES" % [run_name, day])
		_expect(world.farm.market_losses().size() <= Market.MAX_LOSSES,
			"%s day %d: losses stay within MAX_LOSSES" % [run_name, day])
		_expect(world.farm.economy_ledger_entries().size() <= Ledger.MAX_ENTRIES,
			"%s day %d: journal entries stay within MAX_ENTRIES" % [run_name, day])
		_expect(world.farm.committed_command_count() <= 64,
			"%s day %d: committed command results stay bounded" % [run_name, day])

	var now: float = START + float(DAYS) * DAY
	_expect(world.now_utc == now,
		"%s final: the logical clock is exactly day %d" % [run_name, DAYS])

	# 60-day structural validation.
	_expect(Economy.valid(world.farm.economy_snapshot()),
		"%s final: the economy document is still valid" % run_name)
	_expect(Market.valid(world.farm.economy_snapshot()),
		"%s final: the market document is still valid" % run_name)
	_expect(ResidentLedger.valid(world.residents),
		"%s final: the intent ledger is still valid" % run_name)
	_expect(bool(Memory.validate_document(memory, now).get("ok", false)),
		"%s final: the memory document is still valid" % run_name)
	_expect(Social.valid(social),
		"%s final: the relation document is still valid" % run_name)
	_expect(world.farm.economy_total_cash() == world.farm.economy_issued(),
		"%s final: total cash equals issued after %d days" % [run_name, DAYS])
	_expect(bool(world.farm.economy_reconcile().get("ok", false)),
		"%s final: the double-entry ledger reconciles after %d days"
		% [run_name, DAYS])
	_expect(_goods_total(world.farm) == GOODS_TOTAL,
		"%s final: goods conservation holds after %d days" % [run_name, DAYS])

	# Social/relation bounds at the end of the run.
	var relation_acts: int = _social_total(social)
	_expect(total_actions == relation_acts,
		"%s final: every applied social act is recorded once" % run_name)
	_expect(total_actions <= NpcRoster.IDS.size() * DAYS * DAILY_SOCIAL_CAP,
		"%s final: total social actions stay under the daily cap" % run_name)
	_expect(total_gifts <= NpcRoster.IDS.size() * DAYS * GIFT_BUDGET_PER_DAY,
		"%s final: total gifts stay under the daily gift budget" % run_name)
	for from_id: String in social.relations:
		_expect(not (social.relations[from_id] as Dictionary).has(from_id),
			"%s final: %s has no self relation" % [run_name, from_id])
		for peer: Variant in social.relations[from_id]:
			var row: Dictionary = social.relations[from_id][peer]
			_expect((row.get("acts", {}) as Dictionary).size()
				<= Social.MAX_ACTS_PER_PEER,
				"%s final: %s -> %s acts stay within MAX_ACTS_PER_PEER"
				% [run_name, from_id, str(peer)])
			_expect((row.get("gifts_utc", []) as Array).size()
				<= Social.MAX_GIFTS_PER_PEER,
				"%s final: %s -> %s gifts stay within MAX_GIFTS_PER_PEER"
				% [run_name, from_id, str(peer)])

	var intent_total: int = 0
	var purchased_total: int = 0
	for npc_id: String in NpcRoster.IDS:
		var state: Dictionary = ResidentLedger.state_for(world.residents, npc_id)
		intent_total += (state.intents as Dictionary).size()
		purchased_total += int(purchased[npc_id])
	_expect(intent_total == purchased_total,
		"%s final: the ledger intent total equals the purchases seen" % run_name)

	var fingerprint: String = _fingerprint(world, memory, social)
	var issued: int = world.farm.economy_issued()
	var total: int = world.farm.economy_total_cash()
	var memories: int = _memory_total(memory)
	print("DETAIL run=%s trades=%d intents=%d actions=%d gifts=%d feed=%d "
		% [run_name, world.farm.market_trades().size(), intent_total,
		total_actions, total_gifts, total_feed_writes]
		+ "memories=%d dropped=%d orders=%d ledger=%d fingerprint=%s"
		% [memories, _memory_dropped_total(memory),
		world.farm.market_orders().size(), world.farm.economy_ledger_entries().size(),
		fingerprint])
	return {
		"fingerprint": fingerprint, "issued": issued, "total": total,
		"trades": world.farm.market_trades().size(), "intents": intent_total,
		"memories": memories, "social": relation_acts,
	}


# ---------------------------------------------------------------------------
# Social + memory day.
# ---------------------------------------------------------------------------

func _social_and_memory_day(world, roster: Dictionary, social: Dictionary,
		memory: Dictionary, run_name: String, day: int, now: float,
		seen_act_ids: Dictionary) -> Dictionary:
	var actions: int = 0
	var gifts: int = 0
	for npc_id: String in NpcRoster.IDS:
		var daily_actions: int = 0
		var gifts_today: int = 0
		for _attempt: int in DAILY_SOCIAL_CAP:
			var remaining: int = maxi(0, GIFT_BUDGET_PER_DAY - gifts_today)
			var context: Dictionary = _social_context(social, roster, npc_id, remaining)
			var planned: Dictionary = Social.plan(context, now)
			if not bool(planned.get("ok", false)):
				_expect(str(planned.get("reason", "")) == "nothing_to_do",
					"%s day %d: %s has no social action for a named reason"
					% [run_name, day, npc_id])
				break
			var act: Dictionary = planned.act
			_expect(str(act.get("from", "")) == npc_id,
				"%s day %d: the social actor is the planning resident"
				% [run_name, day])
			_expect(str(act.get("to", "")) != npc_id,
				"%s day %d: %s never targets itself" % [run_name, day, npc_id])
			_expect(not seen_act_ids.has(str(act.get("id", ""))),
				"%s day %d: social act ids are unique" % [run_name, day])
			seen_act_ids[str(act.id)] = true

			var checked: Dictionary = Social.validate(act, context, now)
			_expect(bool(checked.get("ok", false)),
				"%s day %d: the planned act passes validate (reason=%s)"
				% [run_name, day, str(checked.get("reason", ""))])
			if not bool(checked.get("ok", false)):
				break
			var applied: Dictionary = Social.apply(act, social, now)
			_expect(bool(applied.get("ok", false)),
				"%s day %d: the act applies to a candidate document (reason=%s)"
				% [run_name, day, str(applied.get("reason", ""))])
			if not bool(applied.get("ok", false)):
				break
			var before_text: String = JSON.stringify(social)
			social = applied.document
			_expect(JSON.stringify(social) != before_text,
				"%s day %d: an applied act advances the relation document"
				% [run_name, day])
			_expect(Social.valid(social),
				"%s day %d: the relation document is valid after every act"
				% [run_name, day])
			daily_actions += 1
			actions += 1
			if str(act.kind) == Social.KIND_GIFT:
				gifts += 1
				gifts_today += 1
			_expect(gifts_today <= GIFT_BUDGET_PER_DAY,
				"%s day %d: %s gifts at most %d per day"
				% [run_name, day, npc_id, GIFT_BUDGET_PER_DAY])

			# The initiator's own view: write one memory row, then replay the id.
			var result: Dictionary = {"ok": true, "act": act.duplicate(true)}
			var memory_context: Dictionary = {
				"now_utc": now, "world_id": WORLD_ID,
				"resident_id": npc_id,
				"names": NpcRoster.DISPLAY_NAMES.duplicate(true),
			}
			var written: Dictionary = SocialMemory.apply(
				memory, result, memory_context)
			_expect(bool(written.get("ok", false)) and bool(written.get("written", false)),
				"%s day %d: the social act is written to the initiator's memory"
				% [run_name, day])
			if bool(written.get("written", false)):
				memory = written.memory
			_expect(bool(Memory.validate_document(memory, now).get("ok", false)),
				"%s day %d: the memory document is valid after a social row"
				% [run_name, day])
			var duplicate: Dictionary = SocialMemory.apply(
				memory, result, memory_context)
			_expect(bool(duplicate.get("ok", false))
				and bool(duplicate.get("duplicate", false))
				and not bool(duplicate.get("written", true)),
				"%s day %d: replaying the social act is a duplicate"
				% [run_name, day])
			_expect(JSON.stringify(duplicate.get("memory", {}))
				== JSON.stringify(memory),
				"%s day %d: a duplicate social replay leaves memory unchanged"
				% [run_name, day])

		_expect(daily_actions <= DAILY_SOCIAL_CAP,
			"%s day %d: %s stays under the daily social cap"
			% [run_name, day, npc_id])
		# If the cap was reached, no fifth action may be planned at this instant.
		if daily_actions == DAILY_SOCIAL_CAP:
			var context_final: Dictionary = _social_context(
				social, roster, npc_id, 0)
			_expect(not bool(Social.plan(context_final, now).get("ok", false)),
				"%s day %d: no fifth social action is possible at the same instant"
				% [run_name, day])
		# Per-pair caps hold after the day's writes.
		for peer: Variant in social.relations[npc_id]:
			var row: Dictionary = social.relations[npc_id][peer]
			_expect((row.acts as Dictionary).size() <= Social.MAX_ACTS_PER_PEER,
				"%s day %d: %s -> %s acts stay bounded"
				% [run_name, day, npc_id, str(peer)])
			_expect((row.gifts_utc as Array).size() <= Social.MAX_GIFTS_PER_PEER,
				"%s day %d: %s -> %s gifts stay bounded"
				% [run_name, day, npc_id, str(peer)])

	# One committed world event is projected into memory, then replayed.
	var actor: String = NpcRoster.IDS[(day - 1) % NpcRoster.IDS.size()]
	var event: Dictionary = {
		"kind": MemoryFeed.KIND_HARVEST, "id": "resident-harvest-%02d" % day,
		"actor": actor, "target": "field_01/cell_01", "ok": true,
	}
	var feed_context: Dictionary = {
		"now_utc": now, "world_id": WORLD_ID, "roster": roster,
	}
	var feed: Dictionary = MemoryFeed.apply(memory, event, feed_context)
	_expect(bool(feed.get("ok", false)),
		"%s day %d: the world event writes memory (reason=%s)"
		% [run_name, day, str(feed.get("reason", ""))])
	var feed_written: int = int(feed.get("written", 0))
	_expect(feed_written == NpcRoster.IDS.size(),
		"%s day %d: one event writes one row per roster resident"
		% [run_name, day])
	_expect(bool(Memory.validate_document(memory, now).get("ok", false)),
		"%s day %d: the memory document is valid after a world event"
		% [run_name, day])
	var memory_before_replay: String = JSON.stringify(memory)
	var feed_replay: Dictionary = MemoryFeed.apply(memory, event, feed_context)
	_expect(bool(feed_replay.get("ok", false))
		and int(feed_replay.get("duplicates", 0)) == NpcRoster.IDS.size()
		and int(feed_replay.get("written", -1)) == 0,
		"%s day %d: replaying the world event id writes nothing new"
		% [run_name, day])
	_expect(JSON.stringify(memory) == memory_before_replay,
		"%s day %d: a duplicate world event leaves memory unchanged"
		% [run_name, day])

	return {
		"social": social, "memory": memory, "actions": actions,
		"gifts": gifts, "feed_written": feed_written,
	}


func _social_context(social: Dictionary, roster: Dictionary, npc_id: String,
		gift_remaining: int) -> Dictionary:
	var resident_row: Dictionary = roster.npcs[npc_id]
	var relations: Dictionary = {}
	var applied_acts: Dictionary = {}
	for peer: Variant in social.relations[npc_id]:
		var row: Dictionary = social.relations[npc_id][peer]
		var acts: Dictionary = row.acts
		for act_id: Variant in acts:
			applied_acts[act_id] = float(acts[act_id])
		# 调用方只投影仍有动作余量的对象：每对关系 16 条动作是既有上限，
		# 满额对象不再进入规则选择，避免把必然被 validate 拒绝的动作当成新意图。
		if acts.size() >= Social.MAX_ACTS_PER_PEER:
			continue
		relations[peer] = {
			"affinity": int(row.affinity),
			"last_utc": float(row.last_utc),
			"gifts": (row.gifts_utc as Array).size(),
			"acts": acts.size(),
		}
	return {
		"resident": {
			"id": npc_id,
			"traits": (resident_row.traits as Dictionary).duplicate(true),
			"relations": relations,
		},
		"cooldowns": {
			"actions": ((social.actions[npc_id] as Dictionary).duplicate(true)
				if social.actions.has(npc_id) else {}),
			"acts": applied_acts,
		},
		"limits": {"gift_remaining": gift_remaining},
	}


func _initial_social() -> Dictionary:
	var relations: Dictionary = {}
	for npc_id: String in NpcRoster.IDS:
		var peers: Dictionary = {}
		for peer: String in NpcRoster.IDS:
			if peer == npc_id:
				continue
			peers[peer] = {
				"affinity": 0, "last_utc": 0.0, "acts": {}, "gifts_utc": [],
			}
		relations[npc_id] = peers
	return {"relations": relations, "actions": {}}


func _replay_intent(world, intent_row: Dictionary, now: float) -> Dictionary:
	var resident: String = str(intent_row.get("resident", ""))
	var intent: Dictionary = {
		"id": str(intent_row.get("intent", "")),
		"kind": NpcIntent.KIND_BUY,
		"good": str(intent_row.get("good", "")),
		"quantity": int(intent_row.get("quantity", 0)),
		"price": int(intent_row.get("price", 0)),
		"reason": NpcIntent.REASON_RESTOCK,
		"expires_utc": now + NpcIntent.INTENT_TTL_SECONDS,
	}
	var context: Dictionary = {
		"resident": {
			"id": resident, "cash": world.farm.economy_cash(resident),
			"bag": world.farm.economy_goods(resident),
		},
		"market": {"orders": _offers(world.farm)},
		"cooldowns": ResidentLedger.state_for(world.residents, resident),
	}
	return NpcIntent.validate(intent, context, now)


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

func _offers(farm) -> Array:
	var result: Array = []
	for row: Variant in farm.market_orders():
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
		result.append({"good": str(order.good), "price": price, "remaining": remaining})
	return result


func _account_exists(farm, npc_id: String) -> bool:
	var accounts: Variant = farm.economy_snapshot().get("accounts")
	return accounts is Dictionary and (accounts as Dictionary).has(npc_id)


func _goods_total(farm) -> int:
	var total: int = 0
	var merchant: Dictionary = farm.market_merchant()
	var stock: Variant = merchant.get("goods")
	if stock is Dictionary:
		for good_id: String in EconomyCatalog.goods_ids():
			total += int((stock as Dictionary).get(good_id, 0))
	for npc_id: String in NpcRoster.IDS:
		var bag: Dictionary = farm.economy_goods(npc_id)
		for good_id: String in EconomyCatalog.goods_ids():
			total += int(bag.get(good_id, 0))
	for row: Variant in farm.market_orders():
		if row is Dictionary \
				and str(row.get("side", "")) == Market.SIDE_SELL \
				and str(row.get("status", "")) == Market.STATUS_OPEN:
			total += int(row.get("remaining", 0))
	for shipment: Variant in farm.market_shipments():
		if shipment is Dictionary \
				and str(shipment.get("status", "")) == Market.SHIPMENT_STATUS_TRANSIT:
			total += int(shipment.get("quantity", 0))
	return total


func _memory_row(memory: Dictionary, npc_id: String) -> Dictionary:
	var npcs: Dictionary = memory.get("npcs", {})
	var row: Variant = npcs.get(npc_id, {})
	return row if row is Dictionary else {}


func _memory_total(memory: Dictionary) -> int:
	var total: int = 0
	for npc_id: String in NpcRoster.IDS:
		total += (_memory_row(memory, npc_id).get("entries", {}) as Dictionary).size()
	return total


func _memory_dropped_total(memory: Dictionary) -> int:
	var total: int = 0
	for npc_id: String in NpcRoster.IDS:
		total += int(_memory_row(memory, npc_id).get("dropped", 0))
	return total


func _social_total(social: Dictionary) -> int:
	var total: int = 0
	var relations: Dictionary = social.get("relations", {})
	for from_id: Variant in relations:
		var peers: Dictionary = relations[from_id]
		for peer: Variant in peers:
			total += ((peers[peer] as Dictionary).get("acts", {}) as Dictionary).size()
	return total


## Fingerprint over every durable document of this fixture and the logical
## clock. It excludes directories, wall time, process ids and session-only maps.
func _fingerprint(world, memory: Dictionary, social: Dictionary) -> String:
	var document: Dictionary = {
		"now_utc": world.now_utc,
		"farm": world.farm.snapshot(),
		"economy": world.farm.economy_snapshot(),
		"orders": world.farm.market_orders(),
		"trades": world.farm.market_trades(),
		"residents": world.residents,
		"memory": memory,
		"social": social,
	}
	return JSON.stringify(document).sha256_text().substr(0, 16)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		return
	failures.append(message)
