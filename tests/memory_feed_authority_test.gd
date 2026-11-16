extends SceneTree
## M10-03 权威接线：已提交的农场/赠予/建造命令写入居民有界记忆。无头、隔离，
## 临时目录写在 `.local/verification` 下，使用真实 `HeadlessWorld`、
## `residents.json` sidecar 与已有 `NpcMemoryFeed` 规则。
##
## 覆盖：
##   - 默认关闭时不写记忆 sidecar，返回值没有新增字段；
##   - 玩家收获/播种/浇水后每名居民各得一条旁观记忆，行 id 来自命令 id；
##   - 赠予给受赠居民高显著度记忆，建造给居民可读的建造记忆；
##   - 被拒命令与非法载荷不留下任何记忆行；
##   - 同一命令重放不新增行、不第二次写盘；
##   - 记忆落盘后重开世界仍在；
##   - 记忆保存失败时命令仍 committed，只有 memory 字段报告原因；
##   - 合法但不映射的命令与空名册不报错。

const World = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const ResidentsStore = preload("res://world/residents_store.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")
const NpcMemory = preload("res://npc/npc_memory.gd")
const NpcMemoryFeed = preload("res://npc/npc_memory_feed.gd")

const START: float = 1800070000.0
const AT: float = START + 10.0
const SEED: int = 42017
const RULES_VERSION: int = 2
const WORLD_ID: String = "memory-feed-authority"
const HOST: String = "memory_feed_host"
const PLAYER: String = "player_00000000000000000000000000000042"
const LIN: String = NpcRoster.NPC_LIN_SHEN
const XU: String = NpcRoster.NPC_XU_BO
const ZHOU: String = NpcRoster.NPC_A_ZHOU

var checks: int = 0
var failures: Array[String] = []
var base_root: String = ""


## Test double for the one boundary this slice must prove: how many times the
## resident sidecar is saved. Everything else delegates to the real store.
class CountingStore extends ResidentsStore:
	var saves: int = 0

	func save_state(state: Dictionary, now_utc: float) -> Dictionary:
		saves += 1
		return super.save_state(state, now_utc)


## A store whose write always fails after the farm document already committed.
class FailingStore extends ResidentsStore:
	var saves: int = 0

	func save_state(_state: Dictionary, _now_utc: float) -> Dictionary:
		saves += 1
		return {"ok": false, "kind": "io"}


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	base_root = project_root.get_base_dir().path_join(
		".local/verification/memory-feed-authority-%d-%d"
		% [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(base_root)
	_run()
	for failure: String in failures:
		push_error(failure)
	print("MEMORY_FEED_AUTHORITY_TEST checks=%d failures=%d"
		% [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run() -> void:
	_test_disabled_writes_nothing()
	_test_farm_actions_are_remembered()
	_test_memory_clock_after_resident_rows()
	_test_gift_and_build()
	_test_rejected_commands_leave_no_memory()
	_test_replay_and_single_save()
	_test_restart_persistence()
	_test_memory_save_failure_is_isolated()
	_test_unmapped_and_empty_roster()


func _test_disabled_writes_nothing() -> void:
	var directory: String = base_root.path_join("disabled")
	_seed_nature(directory)
	var world := World.new()
	var opened: Dictionary = world.open(directory, START, WORLD_ID, HOST)
	_expect(bool(opened.ok), "disabled: the world opens: "
		+ str(opened.get("reason", "")))
	_expect(not world.residents_enabled, "disabled: residents start disabled")
	var harvested: Dictionary = world.execute(FarmCommand.make(
		"disabled-harvest", "field_03", "cell_06", AT), PLAYER)
	_expect(bool(harvested.ok) and str(harvested.get("stage", "")) == "committed",
		"disabled: the command still commits")
	_expect(not harvested.has("memory"),
		"disabled: the committed result keeps its old shape")
	_expect(not FileAccess.file_exists(directory.path_join("residents.json")),
		"disabled: no memory sidecar is written")
	_expect(_memory_count(world) == 0,
		"disabled: the in-memory memory document stays empty")


func _test_farm_actions_are_remembered() -> void:
	var directory: String = base_root.path_join("farm-actions")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	var cases: Array[Dictionary] = [
		{"command": FarmCommand.make("mem-harvest", "field_03", "cell_06", AT),
			"at": AT, "fragment": "收获"},
		{"command": FarmCommand.make_sow("mem-sow", "field_01", "cell_01",
			"greens", AT + 1.0), "at": AT + 1.0, "fragment": "播下"},
		{"command": FarmCommand.make_water("mem-water", "field_04", "cell_06",
			AT + 2.0), "at": AT + 2.0, "fragment": "浇了水"},
	]
	for row: Dictionary in cases:
		var command: Dictionary = row.command
		var result: Dictionary = world.execute(command, PLAYER)
		_expect(bool(result.ok) and str(result.get("stage", "")) == "committed",
			"%s: the command commits: %s" % [command.id, str(result.get("reason", ""))])
		var memory: Dictionary = result.get("memory", {})
		_expect(bool(memory.get("ok", false)),
			"%s: the memory stage reports success" % command.id)
		_expect(int(memory.get("written", -1)) == NpcRoster.IDS.size(),
			"%s: every resident receives one row" % command.id)
		_expect(int(memory.get("duplicates", -1)) == 0,
			"%s: a first commit has no duplicate row" % command.id)
		_expect(str(memory.get("source_event_id", "")) == str(command.id),
			"%s: the memory result names the committed command" % command.id)
		for npc_id: String in NpcRoster.IDS:
			var entry: Dictionary = _entry(world, npc_id, str(command.id))
			_expect(not entry.is_empty(),
				"%s: %s remembers the committed event" % [command.id, npc_id])
			if entry.is_empty():
				continue
			_expect(str(entry.kind) == NpcMemory.KIND_OBSERVATION,
				"%s: a player action is an observation for %s" % [command.id, npc_id])
			_expect(int(entry.salience) == NpcMemoryFeed.SALIENCE_OBSERVER,
				"%s: a bystander row uses observer salience" % command.id)
			_expect(str(entry.world_id) == WORLD_ID,
				"%s: the row names the world" % command.id)
			_expect(is_equal_approx(float(entry.at_utc), float(row.at)),
				"%s: the row uses the command timestamp" % command.id)
			_expect(str(entry.summary).begins_with("看见")
				and str(entry.summary).contains(str(row.fragment)),
				"%s: the summary reports the sighting" % command.id)
		_expect(not (world.resident_memories.npcs as Dictionary).has(PLAYER),
			"%s: the acting player never becomes a resident" % command.id)
	for npc_id: String in NpcRoster.IDS:
		_expect(_memory_entries(world, npc_id).size() == 3,
			"farm-actions: %s has exactly one row per event" % npc_id)


## 居民结算可能把记忆行写到命令时刻之后（玩家时钟本身也允许小幅落后），而记忆
## 文档拒绝任何晚于保存时刻的行。新行时刻要抬到已存在的事实时间，否则整份
## sidecar 会因 `future_time` 拒绝保存、这次命令的记忆静默丢失。
func _test_memory_clock_after_resident_rows() -> void:
	var directory: String = base_root.path_join("clock-bump")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	var resident: String = NpcRoster.IDS[0]
	var recorded: Dictionary = NpcMemory.remember(world.resident_memories, resident, {
		"id": "existing-row", "kind": NpcMemory.KIND_OBSERVATION,
		"participants": [resident], "summary": "already seen",
		"salience": 5, "at_utc": AT + 30.0, "world_id": WORLD_ID,
		"state_version": 0,
	}, AT + 40.0)
	_expect(bool(recorded.get("ok", false)),
		"clock-bump: the resident already holds a later row")
	var result: Dictionary = world.execute(
		FarmCommand.make("mem-late-clock", "field_03", "cell_06", AT), PLAYER)
	var memory: Dictionary = result.get("memory", {})
	_expect(bool(result.ok) and bool(memory.get("ok", false)),
		"clock-bump: a command older than existing rows still saves memories")
	_expect(int(memory.get("written", -1)) == NpcRoster.IDS.size(),
		"clock-bump: every resident still receives one row")
	var entry: Dictionary = _entry(world, resident, "mem-late-clock")
	_expect(not entry.is_empty()
		and is_equal_approx(float(entry.at_utc), AT + 30.0),
		"clock-bump: the new row moves up to the latest known memory time")


func _test_gift_and_build() -> void:
	var directory: String = base_root.path_join("gift-build")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	var harvested: Dictionary = world.execute(FarmCommand.make(
		"gift-harvest", "field_03", "cell_06", AT), PLAYER)
	_expect(bool(harvested.ok), "gift: the harvest fills the player's bag")
	var gift: Dictionary = world.execute(FarmCommand.make_gift(
		"mem-gift", XU, "greens", 1, AT + 1.0), PLAYER)
	_expect(bool(gift.ok), "gift: the gift commits: " + str(gift.get("reason", "")))
	_expect(int((gift.get("memory", {}) as Dictionary).get("written", -1)) == 3,
		"gift: every resident receives a row")
	var recipient: Dictionary = _entry(world, XU, "mem-gift")
	_expect(not recipient.is_empty(), "gift: the recipient remembers receiving")
	_expect(str(recipient.get("kind", "")) == NpcMemory.KIND_GIFT,
		"gift: the recipient row is a gift memory")
	_expect(int(recipient.get("salience", -1)) == NpcMemoryFeed.SALIENCE_GIFT_RECEIVED,
		"gift: receiving uses the high recipient salience")
	_expect(str(recipient.get("summary", "")).contains("送来了"),
		"gift: the recipient summary names the gift")
	var bystander: Dictionary = _entry(world, LIN, "mem-gift")
	_expect(not bystander.is_empty()
		and int(bystander.get("salience", -1)) == NpcMemoryFeed.SALIENCE_OBSERVER,
		"gift: an uninvolved resident only observes")

	var build: Dictionary = world.execute(FarmCommand.make_build(
		"mem-build", "yard_a", "cottage", AT + 2.0), PLAYER)
	_expect(bool(build.ok), "build: the build commits: " + str(build.get("reason", "")))
	_expect(int((build.get("memory", {}) as Dictionary).get("written", -1)) == 3,
		"build: every resident receives a row")
	var parcel: Variant = (world.territory.get("parcels", {}) as Dictionary).get("parcel_01")
	_expect(parcel is Dictionary and str((parcel as Dictionary).get("owner", "")) == PLAYER,
		"build: the first build claims the parcel for the player")
	for npc_id: String in NpcRoster.IDS:
		var entry: Dictionary = _entry(world, npc_id, "mem-build")
		_expect(not entry.is_empty() and str(entry.get("summary", "")).contains("建起"),
			"build: %s remembers the construction" % npc_id)


func _test_rejected_commands_leave_no_memory() -> void:
	var directory: String = base_root.path_join("rejected")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	var before: int = _memory_count(world)
	var rejected: Dictionary = world.execute(FarmCommand.make(
		"reject-empty", "field_01", "cell_01", AT), PLAYER)
	_expect(not bool(rejected.ok), "rejected: harvesting an empty cell is refused")
	_expect(str(rejected.get("reason", "")) == "empty",
		"rejected: the rule reason is empty")
	_expect(not rejected.has("memory"),
		"rejected: a refused command has no memory result")
	var malformed: Dictionary = world.execute({
		"id": "reject-malformed", "kind": "harvest", "at_utc": AT,
	}, PLAYER)
	_expect(not bool(malformed.ok), "rejected: a malformed payload is refused")
	_expect(str(malformed.get("reason", "")) == "invalid_command",
		"rejected: the malformed reason is invalid_command")
	_expect(_memory_count(world) == before,
		"rejected: no memory row is left behind")


func _test_replay_and_single_save() -> void:
	var directory: String = base_root.path_join("replay")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	var counter := CountingStore.new(world.directory)
	counter.world_id = world.world_id
	world.residents_state_store = counter
	var command: Dictionary = FarmCommand.make(
		"mem-replay", "field_03", "cell_06", AT)
	var first: Dictionary = world.execute(command, PLAYER)
	_expect(bool(first.ok), "replay: the first commit succeeds")
	_expect(counter.saves == 1, "replay: the memory change writes once")
	_expect(_memory_count(world) == NpcRoster.IDS.size(),
		"replay: the first commit adds one row per resident")
	var second: Dictionary = world.execute(command, PLAYER)
	_expect(bool(second.ok) and bool(second.get("duplicate", false)),
		"replay: the same command id is a replay")
	_expect(str(second.get("stage", "")) == "duplicate",
		"replay: the replay reports the duplicate stage")
	_expect(counter.saves == 1, "replay: the replay writes no second time")
	_expect(_memory_count(world) == NpcRoster.IDS.size(),
		"replay: the replay adds no memory row")
	for npc_id: String in NpcRoster.IDS:
		_expect(_memory_entries(world, npc_id).size() == 1,
			"replay: %s keeps exactly one row" % npc_id)


func _test_restart_persistence() -> void:
	var directory: String = base_root.path_join("restart")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	world.execute(FarmCommand.make(
		"persist-harvest", "field_03", "cell_06", AT), PLAYER)
	world.execute(FarmCommand.make_gift(
		"persist-gift", ZHOU, "greens", 1, AT + 1.0), PLAYER)
	_expect(FileAccess.file_exists(directory.path_join("residents.json")),
		"restart: the memory sidecar was written")
	var snapshot: String = JSON.stringify(world.resident_memories)
	var reopened := World.new()
	var opened: Dictionary = reopened.open(directory, AT + 100.0, WORLD_ID, HOST)
	_expect(bool(opened.ok), "restart: the world reopens: "
		+ str(opened.get("reason", "")))
	_expect(str(opened.get("kind", "")) == "loaded",
		"restart: the sidecar is loaded from disk")
	_expect(JSON.stringify(reopened.resident_memories) == snapshot,
		"restart: every memory row survives byte-for-byte")
	var entry: Dictionary = _entry(reopened, ZHOU, "persist-gift")
	_expect(not entry.is_empty() and str(entry.kind) == NpcMemory.KIND_GIFT,
		"restart: the recipient's gift memory survived")


func _test_memory_save_failure_is_isolated() -> void:
	var directory: String = base_root.path_join("save-failure")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	var failing := FailingStore.new(world.directory)
	failing.world_id = world.world_id
	world.residents_state_store = failing
	var result: Dictionary = world.execute(FarmCommand.make(
		"fail-harvest", "field_03", "cell_06", AT), PLAYER)
	_expect(bool(result.ok) and str(result.get("stage", "")) == "committed",
		"failure: the farm command still commits")
	_expect(not bool(result.get("duplicate", true)),
		"failure: the commit is not turned into a replay")
	var memory: Dictionary = result.get("memory", {})
	_expect(not bool(memory.get("ok", true)),
		"failure: the memory field reports the failed save")
	_expect(str(memory.get("reason", "")).begins_with("save_resident_state_"),
		"failure: the reason names the sidecar write")
	_expect(int(memory.get("written", -1)) == 0,
		"failure: no rows are reported as stored")
	_expect(failing.saves == 1, "failure: exactly one sidecar write was attempted")
	_expect(_memory_count(world) == 0,
		"failure: the live memory document was not advanced")
	_expect(int(world.farm.snapshot().harvested.get("greens", 0)) == 1,
		"failure: the accepted farm state carries the harvest")
	var reopened := World.new()
	var opened: Dictionary = reopened.open(directory, AT + 1.0, WORLD_ID, HOST)
	_expect(bool(opened.ok), "failure: the world reopens after the failed save")
	_expect(int(reopened.farm.snapshot().harvested.get("greens", 0)) == 1,
		"failure: the harvest is on disk even though memory was not")
	_expect(_memory_count(reopened) == 0,
		"failure: reopening finds no memory row")


func _test_unmapped_and_empty_roster() -> void:
	var directory: String = base_root.path_join("unmapped")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	var counter := CountingStore.new(world.directory)
	counter.world_id = world.world_id
	world.residents_state_store = counter
	var account: Dictionary = world.execute(FarmCommand.make_account_open(
		"mem-account", AT), PLAYER)
	_expect(bool(account.ok), "unmapped: a legal economy command commits: "
		+ str(account.get("reason", "")))
	var memory: Dictionary = account.get("memory", {})
	_expect(bool(memory.get("ok", false)) and int(memory.get("written", -1)) == 0,
		"unmapped: the memory result is a successful no-op")
	_expect(str(memory.get("skipped", "")) == "unmapped_kind",
		"unmapped: the no-op names the unmapped kind")
	_expect(str(memory.get("source_event_id", "x")).is_empty(),
		"unmapped: the no-op names no source event")
	_expect(counter.saves == 0, "unmapped: no sidecar write is attempted")
	_expect(_memory_count(world) == 0, "unmapped: no memory row is created")

	# 空名册没有可写的居民：规则层仍应成功，不报错、不新增行。
	var document: Dictionary = NpcMemory.create(WORLD_ID).document
	var applied: Dictionary = NpcMemoryFeed.apply(document, {
		"kind": NpcMemoryFeed.KIND_HARVEST, "id": "empty-roster",
		"actor": PLAYER, "target": "field_03", "ok": true,
	}, {
		"now_utc": AT, "world_id": WORLD_ID,
		"roster": {"world_id": WORLD_ID, "npcs": {}},
	})
	_expect(bool(applied.get("ok", false)) and int(applied.get("written", -1)) == 0,
		"empty-roster: the feed is a successful no-op")


# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------

func _seed_nature(directory: String) -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	var seeded: Dictionary = NatureStore.new(directory).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	_expect(bool(seeded.get("ok", false)),
		"%s: the fixed seed is persisted" % directory.get_file())


func _open_enabled(directory: String, at_utc: float) -> RefCounted:
	_seed_nature(directory)
	var world := World.new()
	var opened: Dictionary = world.open(directory, at_utc, WORLD_ID, HOST)
	_expect(bool(opened.ok), "%s: the world opens: %s"
		% [directory.get_file(), str(opened.get("reason", ""))])
	if not bool(opened.ok):
		return null
	world.enable_residents()
	return world


func _memory_entries(world: RefCounted, npc_id: String) -> Dictionary:
	var npcs: Variant = (world.resident_memories as Dictionary).get("npcs", {})
	if not npcs is Dictionary:
		return {}
	var row: Variant = (npcs as Dictionary).get(npc_id, {})
	if not row is Dictionary:
		return {}
	var entries: Variant = (row as Dictionary).get("entries", {})
	return entries if entries is Dictionary else {}


func _memory_count(world: RefCounted) -> int:
	var total: int = 0
	for npc_id: String in NpcRoster.IDS:
		total += _memory_entries(world, npc_id).size()
	return total


## The feed derives the stored id from (event id, resident id); reading through
## the same function proves the row belongs to this exact committed command.
func _entry(world: RefCounted, npc_id: String, event_id: String) -> Dictionary:
	var entries: Dictionary = _memory_entries(world, npc_id)
	var memory_id: String = NpcMemoryFeed.memory_id(event_id, npc_id)
	var row: Variant = entries.get(memory_id, {})
	return row if row is Dictionary else {}


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
