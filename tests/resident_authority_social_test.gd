extends SceneTree
## M10-04 居民社交与记忆接入世界权威的切片测试。无头、隔离：临时目录写在
## `.local/verification` 下，使用真实 `HeadlessWorld`、真实经济账户/市场与新增的
## `residents.json` sidecar。
##
## 覆盖：
##   - 默认关闭：不写 residents.json，不产生关系/记忆；
##   - 启用后一次真实扫描产生关系与本人记忆；
##   - 同一时刻重复扫描与同一 act id 重放不二次写入；
##   - 重启后关系、记忆与冷却仍在，同一时刻重放不改变状态；
##   - world_id 不一致、损坏、版本不支持与超容量拒绝启动且不覆盖；
##   - 社交与记忆不移动现金、货物或市场成交；
##   - 滚动 24 小时的动作上限继续生效。

const World = preload("res://world/headless_world.gd")
const ResidentsStore = preload("res://world/residents_store.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")
const Market = preload("res://farm/market_state.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")
const NpcSocial = preload("res://npc/npc_social.gd")
const NpcSocialMemory = preload("res://npc/npc_social_memory.gd")
const NpcMemory = preload("res://npc/npc_memory.gd")
const ResidentLedger = preload("res://npc/npc_resident_ledger.gd")

const START: float = 1800043200.0
const AT: float = START + 10.0
const DAY: float = 86400.0
const SEED: int = 42017
const RULES_VERSION: int = 2
const WORLD_ID: String = "resident-authority-social"
const HOST: String = "resident_social_host"
const COOLDOWN: float = 300.0
const GOODS_TOTAL: int = 120
## Mirrors HeadlessWorld.RESIDENT_SOCIAL_DAILY_CAP.
const DAILY_CAP: int = 4

var checks: int = 0
var failures: Array[String] = []
var base_root: String = ""

var world: RefCounted
var directory: String = ""
var social_at_restart: String = ""
var memory_at_restart: String = ""
var captured_act: Dictionary = {}
var captured_resident: String = ""


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	base_root = project_root.get_base_dir().path_join(
		".local/verification/resident-authority-social-%d-%d"
		% [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(base_root)
	_run()
	for failure: String in failures:
		push_error(failure)
	print("RESIDENT_AUTHORITY_SOCIAL_TEST checks=%d failures=%d"
		% [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run() -> void:
	_test_disabled_writes_nothing()
	_test_enabled_sweep()
	_test_same_instant_and_act_replay()
	_test_social_only_conservation()
	_test_restart_persistence_and_cooldown()
	_test_daily_cap()
	_test_world_mismatch_refused()
	_test_corrupt_and_over_limit_refused()


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

func _test_disabled_writes_nothing() -> void:
	var disabled_dir: String = base_root.path_join("disabled")
	var closed := World.new()
	var opened: Dictionary = closed.open(disabled_dir, START, WORLD_ID, HOST)
	_expect(bool(opened.ok), "disabled: the world opens: " + str(opened.get("reason", "")))
	_expect(not closed.residents_enabled, "disabled: residents start disabled")
	_expect(not FileAccess.file_exists(disabled_dir.path_join("residents.json")),
		"disabled: opening a fresh world writes no residents.json")
	_expect(not FileAccess.file_exists(disabled_dir.path_join("npc_residents.json")),
		"disabled: opening a fresh world writes no intent ledger")
	_expect(closed.resident_social.has("relations")
		and (closed.resident_social.relations as Dictionary).size() == NpcRoster.IDS.size(),
		"disabled: the missing sidecar initializes roster relations")
	_expect((closed.resident_memories.npcs as Dictionary).is_empty(),
		"disabled: the missing sidecar initializes empty memories")
	var settled: Dictionary = closed.settle_residents(AT)
	_expect(bool(settled.ok), "disabled: settle_residents is a benign no-op")
	_expect(str(settled.get("reason", "")) == "disabled",
		"disabled: the resident sweep reports disabled")
	_expect(not bool(settled.get("changed", true)),
		"disabled: the resident sweep changes nothing")
	closed.settle_economy_now(AT)
	_expect(not FileAccess.file_exists(disabled_dir.path_join("residents.json")),
		"disabled: neither sweep writes the social sidecar")


func _test_enabled_sweep() -> void:
	directory = base_root.path_join("authority")
	DirAccess.make_dir_recursive_absolute(directory)
	var seeded: Dictionary = NatureStore.new(directory).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	_expect(bool(seeded.get("ok", false)),
		"enabled: the fixed seed is persisted before the world opens")
	world = World.new()
	var opened: Dictionary = world.open(directory, START, WORLD_ID, HOST)
	_expect(bool(opened.ok), "enabled: the world opens: " + str(opened.get("reason", "")))
	var market: Dictionary = world.execute(
		FarmCommand.make_market_open("authority-market", START))
	_expect(bool(market.ok), "enabled: the merchant market opens: "
		+ str(market.get("reason", "")))
	world.enable_residents()

	var settled: Dictionary = world.settle_residents(AT)
	_expect(bool(settled.ok), "enabled: the resident sweep succeeds: "
		+ str(settled.get("reason", "")))
	_expect(bool(settled.get("changed", false)), "enabled: the sweep reports a change")
	_expect(int(settled.counts.get("opened", 0)) == NpcRoster.IDS.size(),
		"enabled: all residents opened real accounts")
	_expect(int(settled.counts.get("purchased", 0)) == NpcRoster.IDS.size(),
		"enabled: all residents completed a real purchase")
	_expect(int(settled.counts.get("socialized", 0)) >= NpcRoster.IDS.size(),
		"enabled: every resident produced at least one social action")
	_expect((settled.failures as Array).is_empty(),
		"enabled: no resident failed: " + str(settled.failures))
	_expect(FileAccess.file_exists(directory.path_join("residents.json")),
		"enabled: the social/memory sidecar is written")
	_expect(NpcSocial.valid(world.resident_social),
		"enabled: the persisted relation document is valid")
	_expect(NpcMemory.valid_document(world.resident_memories, AT),
		"enabled: the persisted memory document is valid")
	_expect(ResidentLedger.valid(world.residents),
		"enabled: the intent ledger stays valid")

	for npc_id: String in NpcRoster.IDS:
		var acts: int = _act_count(world.resident_social, npc_id)
		_expect(acts >= 1, "enabled: %s performed at least one social action" % npc_id)
		_expect(_apology_count(world.resident_social, npc_id) == 1,
			"enabled: the first priority action is one apology per resident")
		var entries: Dictionary = _memory_entries(world.resident_memories, npc_id)
		_expect(entries.size() == acts,
			"enabled: %s writes exactly one memory row per social action" % npc_id)
		_expect(_has_summary(entries, "道了歉"),
			"enabled: %s remembers its apology" % npc_id)
		for peer: Variant in (world.resident_social.relations[npc_id] as Dictionary):
			var row: Dictionary = world.resident_social.relations[npc_id][peer]
			_expect(str(peer) != npc_id and int(row.affinity) > 0,
				"enabled: %s has a positive relation to %s" % [npc_id, str(peer)])

	var envelope_text: String = FileAccess.get_file_as_string(
		directory.path_join("residents.json"))
	var envelope: Variant = JSON.parse_string(envelope_text)
	_expect(envelope is Dictionary, "enabled: the sidecar is JSON")
	if envelope is Dictionary:
		_expect((envelope as Dictionary).keys().size() == 5,
			"enabled: the envelope has exactly five keys")
		for key: String in ["version", "world_id", "social", "memories", "invitations"]:
			_expect((envelope as Dictionary).has(key),
				"enabled: the envelope has %s" % key)
		_expect((envelope as Dictionary).get("invitations") is Dictionary
				and ((envelope as Dictionary).get("invitations") as Dictionary).is_empty(),
			"enabled: the envelope carries an empty invitation table")
		_expect(str((envelope as Dictionary).get("world_id", "")) == WORLD_ID,
			"enabled: the envelope names the world")
		for absent: String in ["cash", "goods", "accounts", "owner", "parcels"]:
			_expect(not (envelope as Dictionary).has(absent),
				"enabled: the sidecar copies no %s fact" % absent)

	_expect(world.farm.market_trades().size() == NpcRoster.IDS.size(),
		"enabled: social writing produced no extra trade")
	_expect(world.farm.economy_total_cash() == world.farm.economy_issued(),
		"enabled: total cash equals issued cash")
	_expect(bool(world.farm.economy_reconcile().ok),
		"enabled: the double-entry ledger reconciles")
	_expect(_goods_total(world.farm) == GOODS_TOTAL,
		"enabled: goods conservation holds after social actions")

	var actions: Array = settled.get("social", [])
	_expect(not actions.is_empty(), "enabled: the sweep reports the social actions")
	if not actions.is_empty():
		var first: Dictionary = actions[0]
		captured_resident = str(first.get("resident", ""))
		captured_act = {
			"id": str(first.get("act", "")),
			"kind": str(first.get("kind", "")),
			"from": captured_resident,
			"to": str(first.get("to", "")),
			"expires_utc": AT + NpcSocial.ACT_TTL_SECONDS,
		}
	social_at_restart = JSON.stringify(world.resident_social)
	memory_at_restart = JSON.stringify(world.resident_memories)


func _test_same_instant_and_act_replay() -> void:
	var social_before: String = JSON.stringify(world.resident_social)
	var memory_before: String = JSON.stringify(world.resident_memories)
	var cash_before: Dictionary = _cash_map(world.farm)
	var bags_before: Dictionary = _bag_map(world.farm)
	var trades_before: int = world.farm.market_trades().size()

	var again: Dictionary = world.settle_residents(AT)
	_expect(bool(again.ok), "replay: a second sweep at the same instant succeeds")
	_expect(not bool(again.get("changed", true)),
		"replay: the second sweep reports no change")
	_expect(int(again.counts.get("purchased", -1)) == 0,
		"replay: no resident buys twice")
	_expect(int(again.counts.get("socialized", -1)) == 0,
		"replay: no social action runs twice at the same instant")
	_expect(JSON.stringify(world.resident_social) == social_before,
		"replay: the relation document is unchanged")
	_expect(JSON.stringify(world.resident_memories) == memory_before,
		"replay: the memory document is unchanged")
	_expect(_cash_map(world.farm) == cash_before, "replay: no cash moved")
	_expect(_bag_map(world.farm) == bags_before, "replay: no goods moved")
	_expect(world.farm.market_trades().size() == trades_before,
		"replay: no new trade settled")

	_expect(not captured_act.is_empty(), "replay: a captured act exists")
	if captured_act.is_empty():
		return
	var context: Dictionary = _context_for(world.resident_social,
		captured_resident, 0)
	var checked: Dictionary = NpcSocial.validate(captured_act, context, AT)
	_expect(not bool(checked.get("ok", true)),
		"replay: the consumed act id is refused")
	_expect(str(checked.get("reason", "")) == "duplicate_intent",
		"replay: the refusal is named duplicate_intent")
	var applied: Dictionary = NpcSocial.apply(captured_act,
		world.resident_social, AT)
	_expect(not bool(applied.get("ok", true))
		and str(applied.get("reason", "")) == "duplicate_intent",
		"replay: applying the same act id does not change relations")
	var written: Dictionary = _memory_result(world.resident_memories, AT)
	_expect(bool(written.get("ok", false)) and bool(written.get("duplicate", false))
		and not bool(written.get("written", true)),
		"replay: the same act id is a duplicate memory row")
	_expect(JSON.stringify(written.get("memory", {})) == memory_before,
		"replay: the duplicate memory write leaves the document unchanged")


func _test_social_only_conservation() -> void:
	var quiet_dir: String = base_root.path_join("no-market")
	DirAccess.make_dir_recursive_absolute(quiet_dir)
	NatureStore.new(quiet_dir).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	var quiet := World.new()
	var opened: Dictionary = quiet.open(quiet_dir, START, WORLD_ID, HOST)
	_expect(bool(opened.ok), "conservation: the no-market world opens")
	quiet.enable_residents()
	var first: Dictionary = quiet.settle_residents(AT)
	_expect(bool(first.ok), "conservation: the first sweep succeeds")
	_expect(int(first.counts.get("purchased", -1)) == 0,
		"conservation: with no public asks no resident buys")
	_expect(int(first.counts.get("socialized", 0)) > 0,
		"conservation: social actions still happen without a market")
	var cash_before: Dictionary = _cash_map(quiet.farm)
	var bags_before: Dictionary = _bag_map(quiet.farm)
	var goods_before: int = _goods_total(quiet.farm)
	var issued_before: int = quiet.farm.economy_issued()

	var later: Dictionary = quiet.settle_residents(AT + COOLDOWN + 100.0)
	_expect(bool(later.ok), "conservation: a later social sweep succeeds")
	_expect(bool(later.get("changed", false)),
		"conservation: the later sweep changes social state")
	_expect(_cash_map(quiet.farm) == cash_before,
		"conservation: social actions move no cash")
	_expect(_bag_map(quiet.farm) == bags_before,
		"conservation: social actions move no goods")
	_expect(quiet.farm.market_trades().is_empty(),
		"conservation: social actions produce no trade")
	_expect(_goods_total(quiet.farm) == goods_before,
		"conservation: the goods total is unchanged")
	_expect(quiet.farm.economy_total_cash() == quiet.farm.economy_issued()
		and quiet.farm.economy_issued() == issued_before,
		"conservation: total cash still equals issued cash")


func _test_restart_persistence_and_cooldown() -> void:
	var reopened := World.new()
	var opened: Dictionary = reopened.open(directory, AT, WORLD_ID, HOST)
	_expect(bool(opened.ok), "restart: the world reopens: "
		+ str(opened.get("reason", "")))
	_expect(str(opened.get("kind", "")) == "loaded",
		"restart: the sidecar is loaded from disk")
	_expect(not reopened.residents_enabled,
		"restart: residents stay disabled until explicitly enabled")
	_expect(JSON.stringify(reopened.resident_social) == social_at_restart,
		"restart: the relation document survived the restart")
	_expect(JSON.stringify(reopened.resident_memories) == memory_at_restart,
		"restart: the memory document survived the restart")
	_expect(NpcSocial.valid(reopened.resident_social)
		and NpcMemory.valid_document(reopened.resident_memories, AT),
		"restart: both loaded documents are still valid")

	reopened.enable_residents()
	var settled: Dictionary = reopened.settle_residents(AT)
	_expect(bool(settled.ok), "restart: the sweep still runs")
	_expect(not bool(settled.get("changed", true)),
		"restart: the same instant does not repeat an act or a purchase")
	_expect(JSON.stringify(reopened.resident_social) == social_at_restart,
		"restart: the same-instant sweep changes no relation")
	_expect(JSON.stringify(reopened.resident_memories) == memory_at_restart,
		"restart: the same-instant sweep changes no memory")

	for npc_id: String in NpcRoster.IDS:
		var kind_times: Dictionary = reopened.resident_social.actions.get(
			npc_id, {})
		_expect(is_equal_approx(float(kind_times.get("apologize", -1.0)), AT),
			"restart: %s's apology cooldown stamp survived" % npc_id)
		var context: Dictionary = _context_for(reopened.resident_social, npc_id, 1)
		var planned: Dictionary = NpcSocial.plan(context, AT + 10.0)
		if bool(planned.get("ok", false)):
			_expect(str(planned.act.kind) != NpcSocial.KIND_APOLOGIZE,
				"restart: %s's apology is still cooling down" % npc_id)
		else:
			_expect(str(planned.get("reason", "")) == "nothing_to_do",
				"restart: %s has no ready social action for a named reason" % npc_id)

	_expect(not captured_act.is_empty(), "restart: a captured act exists")
	if captured_act.is_empty():
		return
	var context: Dictionary = _context_for(reopened.resident_social,
		captured_resident, 1)
	var checked: Dictionary = NpcSocial.validate(captured_act, context, AT + 10.0)
	_expect(not bool(checked.get("ok", true))
		and str(checked.get("reason", "")) == "duplicate_intent",
		"restart: replaying the act id is refused after a restart")
	var written: Dictionary = _memory_result(
		reopened.resident_memories, AT + 10.0)
	_expect(bool(written.get("ok", false)) and bool(written.get("duplicate", false))
		and not bool(written.get("written", true)),
		"restart: replaying the act id is a duplicate memory row")
	_expect(JSON.stringify(written.get("memory", {})) == memory_at_restart,
		"restart: the duplicate replay leaves memory unchanged")
	_expect(reopened.farm.market_trades().size()
		== world.farm.market_trades().size(),
		"restart: no trade is replayed")


func _test_daily_cap() -> void:
	var caps_dir: String = base_root.path_join("caps")
	DirAccess.make_dir_recursive_absolute(caps_dir)
	NatureStore.new(caps_dir).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	var capped := World.new()
	var opened: Dictionary = capped.open(caps_dir, START, WORLD_ID, HOST)
	_expect(bool(opened.ok), "cap: the world opens")
	capped.enable_residents()
	var times: Array[float] = [AT, AT + 400.0, AT + 800.0, AT + 1200.0, AT + 1600.0]
	var before_last: String = ""
	for at_utc: float in times:
		var swept: Dictionary = capped.settle_residents(at_utc)
		_expect(bool(swept.ok), "cap: the sweep at %.1f succeeds" % at_utc)
		for npc_id: String in NpcRoster.IDS:
			_expect(_acts_since(capped.resident_social, npc_id,
				at_utc - DAY) <= DAILY_CAP,
				"cap: %s stays within the rolling daily action cap" % npc_id)
		if is_equal_approx(at_utc, AT + 1200.0):
			before_last = JSON.stringify(capped.resident_social)
	_expect(JSON.stringify(capped.resident_social) == before_last,
		"cap: once the daily cap is reached no further action is recorded")


func _test_world_mismatch_refused() -> void:
	var mismatch_dir: String = base_root.path_join("world-mismatch")
	DirAccess.make_dir_recursive_absolute(mismatch_dir)
	var other: Dictionary = ResidentsStore.empty_state("another-world")
	_write_text(mismatch_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": "another-world",
		"social": other.social, "memories": other.memories,
	}))
	var text_before: String = FileAccess.get_file_as_string(
		mismatch_dir.path_join("residents.json"))
	var mismatch := World.new()
	var refused: Dictionary = mismatch.open(mismatch_dir, START, WORLD_ID, HOST)
	_expect(not bool(refused.ok), "mismatch: another world's sidecar refuses the open")
	_expect(str(refused.get("reason", "")) == "load_resident_state_world_mismatch",
		"mismatch: the refusal is named load_resident_state_world_mismatch")
	_expect(FileAccess.get_file_as_string(mismatch_dir.path_join("residents.json"))
		== text_before, "mismatch: the refused document is never overwritten")


func _test_corrupt_and_over_limit_refused() -> void:
	var corrupt_dir: String = base_root.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	_write_text(corrupt_dir.path_join("residents.json"), "{not json")
	var corrupt := World.new()
	var refused: Dictionary = corrupt.open(corrupt_dir, START, WORLD_ID, HOST)
	_expect(not bool(refused.ok), "corrupt: a corrupt sidecar refuses the open")
	_expect(str(refused.get("reason", "")) == "load_resident_state_corrupt",
		"corrupt: the refusal is named load_resident_state_corrupt")

	var unsupported_dir: String = base_root.path_join("unsupported")
	DirAccess.make_dir_recursive_absolute(unsupported_dir)
	var fresh: Dictionary = ResidentsStore.empty_state(WORLD_ID)
	_write_text(unsupported_dir.path_join("residents.json"), JSON.stringify({
		"version": 2, "world_id": WORLD_ID,
		"social": fresh.social, "memories": fresh.memories,
	}))
	var unsupported := World.new()
	var refused_version: Dictionary = unsupported.open(
		unsupported_dir, START, WORLD_ID, HOST)
	_expect(not bool(refused_version.ok),
		"unsupported: a newer sidecar version refuses the open")
	_expect(str(refused_version.get("reason", ""))
		== "load_resident_state_unsupported",
		"unsupported: the refusal is named load_resident_state_unsupported")

	var over_dir: String = base_root.path_join("over-limit")
	DirAccess.make_dir_recursive_absolute(over_dir)
	var social: Dictionary = {"relations": {}, "actions": {}}
	for index: int in 17:
		social.relations["npc_extra_%02d" % index] = {}
	_write_text(over_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": WORLD_ID,
		"social": social, "memories": fresh.memories,
	}))
	var over := World.new()
	var refused_over: Dictionary = over.open(over_dir, START, WORLD_ID, HOST)
	_expect(not bool(refused_over.ok),
		"over-limit: a relation table beyond capacity refuses the open")
	_expect(str(refused_over.get("reason", "")) == "load_resident_state_corrupt",
		"over-limit: the refusal is named load_resident_state_corrupt")


# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------

func _context_for(social: Dictionary, npc_id: String,
		gift_remaining: int) -> Dictionary:
	var relations: Dictionary = {}
	var applied: Dictionary = {}
	var peers: Dictionary = social.relations.get(npc_id, {})
	for peer: Variant in peers:
		var row: Dictionary = peers[peer]
		var acts: Dictionary = row.acts
		for act_id: Variant in acts:
			applied[act_id] = float(acts[act_id])
		if acts.size() >= NpcSocial.MAX_ACTS_PER_PEER:
			continue
		relations[peer] = {
			"affinity": int(row.affinity),
			"last_utc": float(row.last_utc),
			"gifts": (row.gifts_utc as Array).size(),
			"acts": acts.size(),
		}
	var action_times: Dictionary = {}
	if social.actions.get(npc_id) is Dictionary:
		action_times = (social.actions[npc_id] as Dictionary).duplicate(true)
	return {
		"resident": {
			"id": npc_id,
			"traits": {
				"diligence": 50, "warmth": 50, "suspicion": 50,
				"curiosity": 50, "generosity": 50,
			},
			"relations": relations,
		},
		"cooldowns": {"actions": action_times, "acts": applied},
		"limits": {"gift_remaining": gift_remaining},
	}


func _memory_result(memory: Dictionary, now_utc: float) -> Dictionary:
	var context: Dictionary = {
		"now_utc": now_utc, "world_id": WORLD_ID,
		"resident_id": captured_resident,
		"names": NpcRoster.DISPLAY_NAMES.duplicate(true),
	}
	return NpcSocialMemory.apply(
		memory, {"ok": true, "act": captured_act.duplicate(true)}, context)


func _act_count(social: Dictionary, npc_id: String) -> int:
	var total: int = 0
	var peers: Dictionary = social.relations.get(npc_id, {})
	for peer: Variant in peers:
		total += ((peers[peer] as Dictionary).acts as Dictionary).size()
	return total


func _apology_count(social: Dictionary, npc_id: String) -> int:
	# The first action is always an apology; this helper counts actions by kind
	# through the per-kind cooldown row (one apology at the first sweep).
	var actions: Dictionary = social.actions.get(npc_id, {})
	return 1 if actions.has(NpcSocial.KIND_APOLOGIZE) else 0


func _acts_since(social: Dictionary, npc_id: String, since_utc: float) -> int:
	var total: int = 0
	var peers: Dictionary = social.relations.get(npc_id, {})
	for peer: Variant in peers:
		var acts: Dictionary = (peers[peer] as Dictionary).acts
		for act_id: Variant in acts:
			if float(acts[act_id]) > since_utc:
				total += 1
	return total


func _memory_entries(memory: Dictionary, npc_id: String) -> Dictionary:
	var row: Variant = (memory.get("npcs", {}) as Dictionary).get(npc_id, {})
	if not row is Dictionary:
		return {}
	var entries: Variant = (row as Dictionary).get("entries", {})
	return entries if entries is Dictionary else {}


func _has_summary(entries: Dictionary, fragment: String) -> bool:
	for entry_id: Variant in entries:
		var entry: Variant = entries[entry_id]
		if entry is Dictionary and str((entry as Dictionary).get("summary", "")).contains(fragment):
			return true
	return false


func _cash_map(farm: RefCounted) -> Dictionary:
	var result: Dictionary = {}
	for npc_id: String in NpcRoster.IDS:
		result[npc_id] = farm.economy_cash(npc_id)
	return result


func _bag_map(farm: RefCounted) -> Dictionary:
	var result: Dictionary = {}
	for npc_id: String in NpcRoster.IDS:
		result[npc_id] = farm.economy_goods(npc_id)
	return result


func _goods_total(farm: RefCounted) -> int:
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


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		return
	failures.append(message)
