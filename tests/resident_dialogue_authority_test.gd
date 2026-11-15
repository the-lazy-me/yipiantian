extends SceneTree
## M10-04 居民确定性对话接入世界权威的切片测试。无头、隔离：临时目录写在
## `.local/verification` 下，使用真实 `HeadlessWorld` 与 `residents.json`
## sidecar，不启动网络。
##
## 覆盖：
##   - 成功回复把关系增量与一条 `dialogue` 记忆落盘，并更新对话状态；
##   - 冷却拒绝零副作用；日上限与 UTC 日切；
##   - 同一 command id 重放不二次写；换参数返回 `command_conflict`；
##   - 重启后关系、记忆与对话状态保留，冷却继续生效；
##   - 损坏 / 异世界 / 超限 / 旧信封拒绝或兼容启动；
##   - 保存失败不改内存；未知类别、非法居民、非法玩家被拒绝；
##   - `visible` 由权威从真实农场与市场投影，客户端传入的事实被忽略；
##   - 视图只暴露查看者本人的对话状态。

const World = preload("res://world/headless_world.gd")
const ResidentsStore = preload("res://world/residents_store.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Market = preload("res://farm/market_state.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")
const NpcDialogue = preload("res://npc/npc_dialogue.gd")
const NpcMemory = preload("res://npc/npc_memory.gd")
const NpcSocial = preload("res://npc/npc_social.gd")

const START: float = 1800072000.0
const AT: float = START + 10.0
const DAY: float = 86400.0
const SEED: int = 42017
const RULES_VERSION: int = 2
const WORLD_ID: String = "resident-dialogue-authority"
const HOST: String = "resident_dialogue_host"
const PLAYER_A: String = "player_00000000000000000000000000000401"
const PLAYER_B: String = "player_00000000000000000000000000000402"
const LIN: String = NpcRoster.NPC_LIN_SHEN
const VIEW_KEYS: Array[String] = [
	"id", "display_name", "affinity", "last_dialogue_utc", "daily_affinity",
	"daily_limit", "cooldown_seconds", "cooldown_remaining", "ready",
]

var checks: int = 0
var failures: Array[String] = []
var base_root: String = ""
var closed_world: RefCounted


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	base_root = project_root.get_base_dir().path_join(
		".local/verification/resident-dialogue-authority-%d-%d"
		% [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(base_root)
	_run()
	for failure: String in failures:
		push_error(failure)
	print("RESIDENT_DIALOGUE_AUTHORITY_TEST checks=%d failures=%d"
		% [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run() -> void:
	_test_disabled()
	_test_success_writes_relation_memory_and_state()
	_test_cooldown_and_replay()
	_test_daily_cap_and_day_cut()
	_test_visible_is_authoritative()
	_test_restart_persists()
	_test_capacity_legacy_and_corrupt()
	_test_save_failure()
	_test_rejections()
	_test_view_privacy()


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

func _test_disabled() -> void:
	var directory: String = base_root.path_join("disabled")
	var world := World.new()
	var opened: Dictionary = world.open(directory, START, WORLD_ID, HOST)
	_expect(bool(opened.ok), "disabled: the world opens: "
		+ str(opened.get("reason", "")))
	var result: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_GREET, "disabled-greet-1")
	_expect(not bool(result.get("ok", true)),
		"disabled: a dialogue is refused when residents are off")
	_expect(str(result.get("reason", "")) == "disabled",
		"disabled: the refusal is named disabled")
	_expect(not str(result.get("reason_text", "")).is_empty(),
		"disabled: the refusal carries Chinese text")
	_expect(not FileAccess.file_exists(directory.path_join("residents.json")),
		"disabled: a refused dialogue writes no sidecar")
	_expect((world.resident_dialogues as Dictionary).is_empty(),
		"disabled: no dialogue state is created")
	var view: Dictionary = world.dialogues_view(PLAYER_A, true)
	_expect(not bool(view.get("available", true))
			and str(view.get("reason", "")) == "disabled",
		"disabled: the view reports disabled")


func _test_success_writes_relation_memory_and_state() -> void:
	var directory: String = base_root.path_join("success")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	var affinity_before: int = _affinity(world, LIN, PLAYER_A)
	var result: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_GREET, "success-greet-1")
	_expect(bool(result.get("ok", false)), "success: the greeting succeeds: "
		+ str(result.get("reason", "")))
	_expect(NpcDialogue.valid_reply_kind(str(result.get("reply_kind", ""))),
		"success: the reply names a fixed template")
	_expect(int(result.get("affinity_delta", 0)) == 1,
		"success: greet grants the fixed +1")
	var affinity_after: int = _affinity(world, LIN, PLAYER_A)
	_expect(affinity_after == affinity_before + 1,
		"success: the relation affinity grew by the reported delta")
	var state: Dictionary = _dialogue_row(world, PLAYER_A, LIN)
	_expect(state.size() == ResidentsStore.DIALOGUE_KEYS.size(),
		"success: the dialogue row has exactly the documented fields")
	_expect(is_equal_approx(float(state.get("last_dialogue_utc", 0.0)),
		world.authority_now_utc()),
		"success: the dialogue row stamps the authority clock")
	_expect(int(state.get("daily_affinity", -1)) == 1,
		"success: the daily counter is one after the first dialogue")
	_expect(int(state.get("day_utc", -1)) == int(floorf(
		world.authority_now_utc() / DAY)),
		"success: the stored day is the UTC day of the dialogue")
	var memories: Array = _dialogue_memories(world, LIN, PLAYER_A)
	_expect(memories.size() == 1, "success: exactly one dialogue memory is written")
	_expect(str(memories[0].get("kind", "")) == NpcMemory.KIND_DIALOGUE,
		"success: the memory uses the existing dialogue kind")
	_expect(str(memories[0].get("summary", "")) != "",
		"success: the memory carries the fixed summary")
	_expect((memories[0].get("participants", []) as Array).has(PLAYER_A),
		"success: the memory names the player as a participant")
	_expect(_file_valid(directory, world.authority_now_utc()),
		"success: the saved sidecar passes the envelope validator")

	# 第二名玩家的关系与状态互不混合。
	var other: Dictionary = world.execute_dialogue(
		PLAYER_B, LIN, NpcDialogue.CATEGORY_GREET, "success-greet-2")
	_expect(bool(other.get("ok", false)), "success: a second player may greet")
	_expect(_affinity(world, LIN, PLAYER_B) == 1,
		"success: the second player has their own affinity row")
	_expect(_affinity(world, LIN, PLAYER_A) == affinity_after,
		"success: the second player's dialogue does not change the first's affinity")
	_expect(_dialogue_memories(world, LIN, PLAYER_A).size() == 1,
		"success: the second player's dialogue adds no memory for the first")


func _test_cooldown_and_replay() -> void:
	var directory: String = base_root.path_join("cooldown")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	var first: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_GREET, "cooldown-greet-1")
	_expect(bool(first.get("ok", false)), "cooldown: the first dialogue succeeds")
	var social_before: String = JSON.stringify(world.resident_social)
	var memories_before: String = JSON.stringify(world.resident_memories)
	var dialogues_before: String = JSON.stringify(world.resident_dialogues)
	var bytes_before: PackedByteArray = FileAccess.get_file_as_bytes(
		directory.path_join("residents.json"))

	# 冷却内换一个新 command id 会被拒绝且零副作用。
	var blocked: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_THANK, "cooldown-thank-2")
	_expect(not bool(blocked.get("ok", true)), "cooldown: a second dialogue is refused")
	_expect(str(blocked.get("reason", "")) == "cooldown",
		"cooldown: the refusal names cooldown")
	_expect(str(blocked.get("cooldown_reason", "")) == "cooldown",
		"cooldown: the refusal carries the cooldown reason")
	_expect(JSON.stringify(world.resident_social) == social_before,
		"cooldown: a refused dialogue leaves the relation document alone")
	_expect(JSON.stringify(world.resident_memories) == memories_before,
		"cooldown: a refused dialogue writes no memory")
	_expect(JSON.stringify(world.resident_dialogues) == dialogues_before,
		"cooldown: a refused dialogue changes no dialogue state")
	_expect(FileAccess.get_file_as_bytes(directory.path_join("residents.json"))
			== bytes_before,
		"cooldown: a refused dialogue writes no file")

	# 同一 command id 重放返回首次回复，且不二次写。
	var replay: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_GREET, "cooldown-greet-1")
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"replay: the same command id returns the first reply as a duplicate")
	_expect(int(replay.get("affinity_delta", -1)) == int(first.get("affinity_delta", 0)),
		"replay: the duplicate repeats the first delta")
	_expect(JSON.stringify(world.resident_social) == social_before,
		"replay: the duplicate does not apply the delta again")
	_expect(JSON.stringify(world.resident_memories) == memories_before,
		"replay: the duplicate appends no second memory")
	var conflict: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_THANK, "cooldown-greet-1")
	_expect(not bool(conflict.get("ok", true))
			and str(conflict.get("reason", "")) == "command_conflict",
		"replay: reusing the id with different arguments is a named conflict")


func _test_daily_cap_and_day_cut() -> void:
	var directory: String = base_root.path_join("daily")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	var now: float = _set_clock(world, AT)
	var got: int = 0
	for index: int in NpcDialogue.MAX_DAILY_AFFINITY + 3:
		now = _set_clock(world, now + NpcDialogue.COOLDOWN_SECONDS + 1.0)
		var result: Dictionary = world.execute_dialogue(PLAYER_A, LIN,
			NpcDialogue.CATEGORY_THANK, "daily-thank-%d" % index)
		_expect(bool(result.get("ok", false)),
			"daily: dialogue %d is accepted: " % index
			+ str(result.get("reason", "")))
		got += int(result.get("affinity_delta", 0))
	_expect(got == NpcDialogue.MAX_DAILY_AFFINITY,
		"daily: the sum of accepted deltas equals the daily cap")
	_expect(_affinity(world, LIN, PLAYER_A) == NpcDialogue.MAX_DAILY_AFFINITY,
		"daily: the relation grew by exactly the cap")
	# 额度用尽后道歉（基础增量 2）被截断为 0，并报告日上限原因。
	now = _set_clock(world, now + NpcDialogue.COOLDOWN_SECONDS + 1.0)
	var capped: Dictionary = world.execute_dialogue(PLAYER_A, LIN,
		NpcDialogue.CATEGORY_APOLOGIZE, "daily-apologize-capped")
	_expect(bool(capped.get("ok", false)),
		"daily: a further dialogue still succeeds at zero delta: "
		+ str(capped.get("reason", "")))
	_expect(int(capped.get("affinity_delta", -1)) == 0,
		"daily: the capped dialogue grants no more affinity")
	_expect(str(capped.get("capped_reason", "")) == "daily",
		"daily: the capped dialogue reports the daily reason")
	_expect(_affinity(world, LIN, PLAYER_A) == NpcDialogue.MAX_DAILY_AFFINITY,
		"daily: the relation does not exceed the cap")

	# UTC 日切后额度惰性归零。
	var next_day: float = floorf(world.authority_now_utc() / DAY) * DAY + DAY + 10.0
	now = _set_clock(world, next_day + NpcDialogue.COOLDOWN_SECONDS + 1.0)
	var after_cut: Dictionary = world.execute_dialogue(PLAYER_A, LIN,
		NpcDialogue.CATEGORY_GREET, "daily-next-day")
	_expect(bool(after_cut.get("ok", false)), "day-cut: the next day's dialogue succeeds")
	_expect(int(after_cut.get("affinity_delta", 0)) == 1,
		"day-cut: the daily budget restarts at zero")
	_expect(int(after_cut.get("daily_affinity_after", -1)) == 1,
		"day-cut: the reported daily counter restarts")
	var view: Dictionary = world.dialogues_view(PLAYER_A, true)
	var row: Dictionary = _view_row(view, LIN)
	_expect(int(row.get("daily_affinity", -1)) == 1,
		"day-cut: the view projects the new day's counter")


func _test_visible_is_authoritative() -> void:
	var directory: String = base_root.path_join("visible")
	DirAccess.make_dir_recursive_absolute(directory)
	var seeded: Dictionary = NatureStore.new(directory).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	_expect(bool(seeded.get("ok", false)), "visible: the fixed seed is persisted")
	var world := World.new()
	var opened: Dictionary = world.open(directory, START, WORLD_ID, HOST)
	_expect(bool(opened.ok), "visible: the world opens: "
		+ str(opened.get("reason", "")))
	world.enable_residents()
	world._session_started_ms = 0
	world.now_utc = AT
	# 打开商人并制造一笔真实成交，让公开行情有定义。
	var market: Dictionary = world.execute(FarmCommand.make_market_open("visible-market", AT))
	_expect(bool(market.get("ok", false)), "visible: the merchant opens")
	var opened_account: Dictionary = world.execute(
		FarmCommand.make_account_open("visible-account-a", AT), PLAYER_A)
	_expect(bool(opened_account.get("ok", false)),
		"visible: a seller account opens: "
		+ str(opened_account.get("reason", "")))
	var opened_buyer: Dictionary = world.execute(
		FarmCommand.make_account_open("visible-account-b", AT), PLAYER_B)
	_expect(bool(opened_buyer.get("ok", false)),
		"visible: a buyer account opens: "
		+ str(opened_buyer.get("reason", "")))
	# 收获真实作物进入卖家自己的口袋，再挂出卖单。
	var harvest: Dictionary = world.execute(FarmCommand.make(
		"visible-harvest", "field_03", "cell_06", AT), PLAYER_A)
	_expect(bool(harvest.get("ok", false)), "visible: the seller harvests a crop: "
		+ str(harvest.get("reason", "")))
	var crop_id: String = str(harvest.get("reward_crop_id", ""))
	_expect(not crop_id.is_empty(), "visible: the harvest names a catalog crop")
	if crop_id.is_empty():
		return
	var sell: Dictionary = world.execute(FarmCommand.make_market_place(
		"visible-sell", Market.SIDE_SELL, crop_id, 40, 1, AT + 600.0, AT), PLAYER_A)
	_expect(bool(sell.get("ok", false)), "visible: the seller lists one unit: "
		+ str(sell.get("reason", "")))
	var buy: Dictionary = world.execute(FarmCommand.make_market_place(
		"visible-buy", Market.SIDE_BUY, crop_id, 50, 1, AT + 600.0, AT), PLAYER_B)
	_expect(bool(buy.get("ok", false)), "visible: the buyer places a crossing order: "
		+ str(buy.get("reason", "")))
	_expect(int(buy.get("market_matched", 0)) == 1,
		"visible: exactly one real trade settles")
	var trades: Array = world.farm.market_trades()
	_expect(not trades.is_empty(), "visible: the market recorded the trade")
	var real_price: int = int(trades[trades.size() - 1].get("price", 0))

	var asked: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_ASK_MARKET, "visible-market-ask")
	_expect(bool(asked.get("ok", false)), "visible: the market question succeeds")
	_expect(str(asked.get("reply_kind", "")) == NpcDialogue.REPLY_MARKET_RECORDED,
		"visible: the authority projected the real public price")
	var refs: Dictionary = asked.get("fact_refs", {})
	_expect(int(refs.get("market_price", -1)) == real_price,
		"visible: the reply cites the real last trade price")
	_expect(str(asked.get("memory_summary", "")).contains(str(real_price)),
		"visible: the memory summary names the real price")

	# 客户端不能传入可见事实：入口只接受 category，行情来自真实成交，农事来自
	# 真实已种植地块。带伪造事实的第二类问题仍得到权威投影的答案。
	world.now_utc = AT + NpcDialogue.COOLDOWN_SECONDS + 1.0
	var forged: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_ASK_WORK, "visible-work-ask")
	_expect(bool(forged.get("ok", false)), "visible: the farm question succeeds: "
		+ str(forged.get("reason", "")))
	_expect(!bool(forged.get("ok", false))
			or str(forged.get("reply_kind", "")) == NpcDialogue.REPLY_WORK_RECORDED,
		"visible: the authority projects real planted work, not client claims")
	_expect(not (forged.get("fact_refs", {}) as Dictionary).has("market_price"),
		"visible: the farm reply does not leak the market fact")
	var view: Dictionary = world.dialogues_view(PLAYER_A, true)
	var recent: Array = view.get("recent", [])
	for row_value: Variant in recent:
		_expect(not (row_value as Dictionary).has("visible"),
			"visible: recent replies do not echo the internal visible context")


func _test_restart_persists() -> void:
	var directory: String = base_root.path_join("restart")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	var now: float = _set_clock(world, AT)
	var first: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_GREET, "restart-greet-1")
	_expect(bool(first.get("ok", false)), "restart: the first dialogue succeeds")
	var social_at_restart: String = JSON.stringify(world.resident_social)
	var memories_at_restart: String = JSON.stringify(world.resident_memories)
	var dialogues_at_restart: String = JSON.stringify(world.resident_dialogues)
	var affinity_at_restart: int = _affinity(world, LIN, PLAYER_A)

	var reopened := World.new()
	var opened: Dictionary = reopened.open(directory, now, WORLD_ID, HOST)
	_expect(bool(opened.ok), "restart: the world reopens: "
		+ str(opened.get("reason", "")))
	reopened.enable_residents()
	reopened._session_started_ms = 0
	reopened.now_utc = now
	_expect(JSON.stringify(reopened.resident_social) == social_at_restart,
		"restart: the relation document is unchanged")
	_expect(JSON.stringify(reopened.resident_memories) == memories_at_restart,
		"restart: the memory document is unchanged")
	_expect(JSON.stringify(reopened.resident_dialogues) == dialogues_at_restart,
		"restart: the dialogue state is unchanged")
	_expect(_affinity(reopened, LIN, PLAYER_A) == affinity_at_restart,
		"restart: the affinity survives")
	# 重启后仍在冷却内：新 command id 被拒绝且零副作用。
	var cooled: Dictionary = reopened.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_GREET, "restart-greet-2")
	_expect(not bool(cooled.get("ok", true))
			and str(cooled.get("reason", "")) == "cooldown",
		"restart: the persisted cooldown still refuses a new dialogue")
	_expect(JSON.stringify(reopened.resident_social) == social_at_restart,
		"restart: the refused dialogue leaves the relation document alone")
	# 同一 command id 跨重启重试：冷却仍会先拦住，不会二次增长关系。
	var same_id: Dictionary = reopened.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_GREET, "restart-greet-1")
	_expect(not bool(same_id.get("ok", true)),
		"restart: the old command id is refused after the restart")
	_expect(_affinity(reopened, LIN, PLAYER_A) == affinity_at_restart,
		"restart: the old command id never applies a second delta")


func _test_capacity_legacy_and_corrupt() -> void:
	# 旧五键信封（无 dialogues）按空表加载且不被改写。
	var legacy_dir: String = base_root.path_join("legacy")
	DirAccess.make_dir_recursive_absolute(legacy_dir)
	var fresh: Dictionary = ResidentsStore.empty_state(WORLD_ID)
	_write_text(legacy_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": WORLD_ID, "social": fresh.social,
		"memories": fresh.memories, "invitations": {},
	}))
	var legacy_text: String = FileAccess.get_file_as_string(
		legacy_dir.path_join("residents.json"))
	var legacy := World.new()
	var legacy_open: Dictionary = legacy.open(legacy_dir, START, WORLD_ID, HOST)
	_expect(bool(legacy_open.ok), "legacy: a five-key document still opens: "
		+ str(legacy_open.get("reason", "")))
	_expect((legacy.resident_dialogues as Dictionary).is_empty(),
		"legacy: a missing dialogue key reads as an empty table")
	_expect(FileAccess.get_file_as_string(legacy_dir.path_join("residents.json"))
			== legacy_text,
		"legacy: opening the old document never rewrites it")
	legacy.enable_residents()
	var upgraded: Dictionary = legacy.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_GREET, "legacy-greet")
	_expect(bool(upgraded.get("ok", false)), "legacy: the old world accepts a dialogue")
	var saved_text: String = FileAccess.get_file_as_string(
		legacy_dir.path_join("residents.json"))
	var saved: Variant = JSON.parse_string(saved_text)
	_expect(saved is Dictionary and (saved as Dictionary).has("dialogues"),
		"legacy: the next save writes the six-key envelope")

	# 超限：超过 MAX_DIALOGUE_PLAYERS 的对话表拒绝启动。
	var over_dir: String = base_root.path_join("over-players")
	DirAccess.make_dir_recursive_absolute(over_dir)
	var over_table: Dictionary = {}
	for index: int in ResidentsStore.MAX_DIALOGUE_PLAYERS + 1:
		over_table["player_%028d" % index] = {}
	_write_text(over_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": WORLD_ID, "social": fresh.social,
		"memories": fresh.memories, "invitations": {}, "dialogues": over_table,
	}))
	var over := World.new()
	var over_open: Dictionary = over.open(over_dir, START, WORLD_ID, HOST)
	_expect(not bool(over_open.ok), "capacity: an over-limit dialogue table refuses")
	_expect(str(over_open.get("reason", "")) == "load_resident_state_corrupt",
		"capacity: the refusal is named load_resident_state_corrupt")

	# 非法居民键：对话只允许名册居民。
	var bad_npc_dir: String = base_root.path_join("bad-npc")
	DirAccess.make_dir_recursive_absolute(bad_npc_dir)
	_write_text(bad_npc_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": WORLD_ID, "social": fresh.social,
		"memories": fresh.memories, "invitations": {},
		"dialogues": {PLAYER_A: {"npc_stranger": {
			"last_dialogue_utc": 0.0, "daily_affinity": 0, "day_utc": 0}}},
	}))
	var bad_npc := World.new()
	var bad_npc_open: Dictionary = bad_npc.open(bad_npc_dir, START, WORLD_ID, HOST)
	_expect(not bool(bad_npc_open.ok),
		"capacity: a non-roster resident key refuses the open")
	_expect(str(bad_npc_open.get("reason", "")) == "load_resident_state_corrupt",
		"capacity: the non-roster refusal is named corrupt")

	# 损坏 JSON 与异世界。
	var corrupt_dir: String = base_root.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	_write_text(corrupt_dir.path_join("residents.json"), "{not json")
	var corrupt := World.new()
	var corrupt_open: Dictionary = corrupt.open(corrupt_dir, START, WORLD_ID, HOST)
	_expect(str(corrupt_open.get("reason", "")) == "load_resident_state_corrupt",
		"corrupt: a broken sidecar refuses the open")

	var mismatch_dir: String = base_root.path_join("mismatch")
	DirAccess.make_dir_recursive_absolute(mismatch_dir)
	_write_text(mismatch_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": "another-world", "social": fresh.social,
		"memories": fresh.memories, "invitations": {}, "dialogues": {},
	}))
	var mismatch := World.new()
	var mismatch_open: Dictionary = mismatch.open(
		mismatch_dir, START, WORLD_ID, HOST)
	_expect(str(mismatch_open.get("reason", ""))
			== "load_resident_state_world_mismatch",
		"mismatch: another world's dialogue state refuses the open")


func _test_save_failure() -> void:
	var directory: String = base_root.path_join("save-failure")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	# A directory where the pending file should go makes the staged write fail
	# without relying on platform permission bits.
	DirAccess.make_dir_recursive_absolute(
		directory.path_join("residents.pending.json"))
	var social_before: String = JSON.stringify(world.resident_social)
	var memories_before: String = JSON.stringify(world.resident_memories)
	var dialogues_before: String = JSON.stringify(world.resident_dialogues)
	var failed: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_GREET, "save-failure-greet")
	_expect(not bool(failed.get("ok", true)),
		"save-failure: a failed save refuses the dialogue")
	_expect(str(failed.get("reason", "")).begins_with("save_resident_state_"),
		"save-failure: the refusal names the storage stage")
	_expect(JSON.stringify(world.resident_social) == social_before,
		"save-failure: the relation document is unchanged in memory")
	_expect(JSON.stringify(world.resident_memories) == memories_before,
		"save-failure: no memory is kept in memory")
	_expect(JSON.stringify(world.resident_dialogues) == dialogues_before,
		"save-failure: no dialogue state is kept in memory")
	_expect(_affinity(world, LIN, PLAYER_A) == 0,
		"save-failure: the affinity did not move")
	_expect(not FileAccess.file_exists(directory.path_join("residents.json")),
		"save-failure: no main document is created")
	# 同一 command id 在失败后没有被登记，重试（修好目录后）可以成功。
	DirAccess.remove_absolute(directory.path_join("residents.pending.json"))
	var retried: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_GREET, "save-failure-greet")
	_expect(bool(retried.get("ok", false)),
		"save-failure: the same command id is retriable after the fault clears")


func _test_rejections() -> void:
	var directory: String = base_root.path_join("rejections")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	var unknown_category: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, "buy", "reject-category")
	_expect(str(unknown_category.get("reason", "")) == "invalid_category",
		"rejection: an unregistered category is refused")
	var unknown_npc: Dictionary = world.execute_dialogue(
		PLAYER_A, "npc_stranger", NpcDialogue.CATEGORY_GREET, "reject-npc")
	_expect(str(unknown_npc.get("reason", "")) == "invalid_npc",
		"rejection: an unknown resident is refused")
	var bad_player: Dictionary = world.execute_dialogue(
		"", LIN, NpcDialogue.CATEGORY_GREET, "reject-player")
	_expect(str(bad_player.get("reason", "")) == "invalid_player",
		"rejection: an empty player id is refused")
	var reserved_player: Dictionary = world.execute_dialogue(
		Market.MERCHANT, LIN, NpcDialogue.CATEGORY_GREET, "reject-reserved")
	_expect(str(reserved_player.get("reason", "")) == "invalid_player",
		"rejection: the merchant pseudo-owner is not a player")
	var bad_command: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_GREET, "")
	_expect(str(bad_command.get("reason", "")) == "invalid_command",
		"rejection: an empty command id is refused")
	_expect((world.resident_dialogues as Dictionary).is_empty(),
		"rejection: none of the refused calls created dialogue state")
	# invite 在关系不足时按规则拒绝。
	var invite: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_INVITE, "reject-invite")
	_expect(not bool(invite.get("ok", true))
			and str(invite.get("reason", "")) == "low_affinity",
		"rejection: invite below the relation gate is refused")
	_expect(not (world.resident_dialogues as Dictionary).has(PLAYER_A),
		"rejection: a refused invite creates no dialogue state")


func _test_view_privacy() -> void:
	var directory: String = base_root.path_join("privacy")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	var result: Dictionary = world.execute_dialogue(
		PLAYER_A, LIN, NpcDialogue.CATEGORY_GREET, "privacy-greet-1")
	_expect(bool(result.get("ok", false)), "privacy: the dialogue succeeds")
	var view_a: Dictionary = world.dialogues_view(PLAYER_A, true)
	_expect(bool(view_a.get("available", false)), "privacy: a member reads the view")
	_expect(str(view_a.get("viewer", "")) == PLAYER_A,
		"privacy: the view names the viewer")
	var rows: Array = view_a.get("residents", [])
	_expect(rows.size() == NpcRoster.IDS.size(),
		"privacy: one row per resident")
	for row_value: Variant in rows:
		var row: Dictionary = row_value
		_expect(row.size() == VIEW_KEYS.size(),
			"privacy: the row has exactly the documented fields")
		for key: String in VIEW_KEYS:
			_expect(row.has(key), "privacy: the row carries %s" % key)
	var lin_row: Dictionary = _view_row(view_a, LIN)
	_expect(int(lin_row.get("affinity", -1)) == 1,
		"privacy: the viewer sees their own affinity")
	_expect(float(lin_row.get("last_dialogue_utc", 0.0)) > 0.0,
		"privacy: the viewer sees their own last dialogue time")
	var recent: Array = view_a.get("recent", [])
	_expect(not recent.is_empty(), "privacy: the viewer sees their own recent reply")

	# 另一名玩家没有对话过：看不到第一名的任何对话事实。
	var view_b: Dictionary = world.dialogues_view(PLAYER_B, true)
	var lin_b: Dictionary = _view_row(view_b, LIN)
	_expect(int(lin_b.get("affinity", -1)) == 0,
		"privacy: another player does not see the first player's affinity")
	_expect(float(lin_b.get("last_dialogue_utc", -1.0)) == 0.0,
		"privacy: another player does not see the first player's dialogue time")
	_expect((view_b.get("recent", []) as Array).is_empty(),
		"privacy: another player sees none of the first player's replies")
	_expect(not JSON.stringify(view_b).contains(PLAYER_A),
		"privacy: the other player's view never serializes the first player's id")

	# 未加入与匿名：没有可用视图。
	var outsider: Dictionary = world.dialogues_view(PLAYER_A, false)
	_expect(not bool(outsider.get("available", true)),
		"privacy: an unjoined reader gets no view")
	var anonymous: Dictionary = world.dialogues_view("", true)
	_expect(not bool(anonymous.get("available", true)),
		"privacy: an anonymous reader gets no view")
	_expect((anonymous.get("residents", []) as Array).is_empty(),
		"privacy: the anonymous view exposes no rows")


# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------

func _open_enabled(directory: String, now: float) -> RefCounted:
	DirAccess.make_dir_recursive_absolute(directory)
	var seeded: Dictionary = NatureStore.new(directory).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	_expect(bool(seeded.get("ok", false)),
		"%s: the fixed seed is persisted" % directory.get_file())
	closed_world = World.new()
	var opened: Dictionary = closed_world.open(directory, now, WORLD_ID, HOST)
	_expect(bool(opened.ok), "%s: the world opens: %s"
		% [directory.get_file(), str(opened.get("reason", ""))])
	if not bool(opened.ok):
		return null
	closed_world.enable_residents()
	closed_world._session_started_ms = 0
	closed_world.now_utc = now
	return closed_world


## 固定会话时钟：把逻辑时间钉在 `at_utc`，避免真实墙钟让冷却与日切抖动。
func _set_clock(world: RefCounted, at_utc: float) -> float:
	world._session_started_ms = 0
	world.now_utc = at_utc
	return at_utc


func _affinity(world: RefCounted, npc_id: String, player: String) -> int:
	var relations: Variant = world.resident_social.get("relations", {})
	var peers: Variant = relations.get(npc_id) if relations is Dictionary else null
	if not peers is Dictionary:
		return 0
	var row: Variant = (peers as Dictionary).get(player)
	return int((row as Dictionary).get("affinity", 0)) if row is Dictionary else 0


func _dialogue_row(world: RefCounted, player: String, npc_id: String) -> Dictionary:
	var rows: Variant = (world.resident_dialogues as Dictionary).get(player)
	if not rows is Dictionary:
		return {}
	var row: Variant = (rows as Dictionary).get(npc_id)
	return row if row is Dictionary else {}


func _view_row(view: Dictionary, npc_id: String) -> Dictionary:
	for row_value: Variant in view.get("residents", []):
		if row_value is Dictionary \
				and str((row_value as Dictionary).get("id", "")) == npc_id:
			return row_value
	return {}


func _dialogue_memories(world: RefCounted, npc_id: String, player: String) -> Array:
	var npcs: Variant = world.resident_memories.get("npcs", {})
	var rows: Variant = npcs.get(npc_id, {}) if npcs is Dictionary else null
	if not rows is Dictionary:
		return []
	var entries: Variant = (rows as Dictionary).get("entries", {})
	if not entries is Dictionary:
		return []
	var matched: Array = []
	for entry_value: Variant in (entries as Dictionary).values():
		if not entry_value is Dictionary:
			continue
		var entry: Dictionary = entry_value
		if str(entry.get("kind", "")) != NpcMemory.KIND_DIALOGUE:
			continue
		if (entry.get("participants", []) as Array).has(player):
			matched.append(entry)
	return matched


func _file_valid(directory: String, now: float) -> bool:
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(directory.path_join("residents.json")))
	if not parsed is Dictionary:
		return false
	var envelope: Dictionary = parsed
	var state: Dictionary = {
		"social": envelope.get("social"), "memories": envelope.get("memories"),
		"invitations": envelope.get("invitations"),
		"dialogues": envelope.get("dialogues"),
	}
	return ResidentsStore.valid_state(state, WORLD_ID, now)


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)
