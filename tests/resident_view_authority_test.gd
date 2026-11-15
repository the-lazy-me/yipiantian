extends SceneTree
## M10-04 居民只读视图的纯权威测试。无头、隔离：临时目录写在
## `.local/verification` 下，使用真实 `HeadlessWorld`、真实经济/市场与
## `residents.json` sidecar。
##
## 覆盖：
##   - 未启用：返回 disabled、空居民表，且不创建 sidecar；
##   - 启用后：按名册固定顺序、角色、五维人格、两名邻居关系、记忆条数、
##     已消费意图与最近购买；
##   - 隐私：不出现记忆正文，也不出现现金、账户、货物或权属字段；
##   - 只读：视图不改变关系、记忆或意图账本；
##   - 重启：文档恢复后同一时刻的视图逐字节一致。

const World = preload("res://world/headless_world.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")
const NpcPersonality = preload("res://npc/npc_personality.gd")
const NpcRoles = preload("res://npc/npc_roles.gd")

const START: float = 1800052800.0
const AT: float = START + 10.0
const SEED: int = 42017
const RULES_VERSION: int = 2
const WORLD_ID: String = "resident-view-authority"
const HOST: String = "resident_view_host"
const VIEWER: String = "player_00000000000000000000000000000101"
const ROW_KEYS: Array[String] = [
	"id", "display_name", "role", "traits", "relations", "memory_count",
	"last_memory_utc", "intents_consumed", "last_purchase",
]
const RELATION_KEYS: Array[String] = [
	"id", "display_name", "affinity", "last_utc", "acts", "gifts",
]
## 任何一层出现这些键都意味着视图越过了只读公开事实的边界。
const FORBIDDEN_KEYS: Array[String] = [
	"cash", "accounts", "account", "owner", "bag", "goods", "summary",
	"entries", "intents", "gifts_utc", "state_version", "dialogue",
]

var checks: int = 0
var failures: Array[String] = []
var base_root: String = ""
var directory: String = ""
var world: RefCounted
var view_before: Dictionary = {}


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	base_root = project_root.get_base_dir().path_join(
		".local/verification/resident-view-authority-%d-%d"
		% [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(base_root)
	_run()
	for failure: String in failures:
		push_error(failure)
	print("RESIDENT_VIEW_AUTHORITY_TEST checks=%d failures=%d"
		% [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run() -> void:
	_test_disabled()
	_test_enabled_view()
	_test_privacy_and_read_only()
	_test_restart_consistency()


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

func _test_disabled() -> void:
	var disabled_dir: String = base_root.path_join("disabled")
	var closed := World.new()
	var opened: Dictionary = closed.open(disabled_dir, START, WORLD_ID, HOST)
	_expect(bool(opened.ok), "disabled: the world opens: "
		+ str(opened.get("reason", "")))
	var view: Dictionary = closed.residents_view(VIEWER)
	_expect(not bool(view.get("available", true)),
		"disabled: the view reports unavailable")
	_expect(str(view.get("reason", "")) == "disabled",
		"disabled: the reason is disabled")
	_expect((view.get("residents", []) as Array).is_empty(),
		"disabled: no resident rows are exposed")
	_expect(str(view.get("viewer", "")) == VIEWER,
		"disabled: the viewer is echoed back")
	_expect(not FileAccess.file_exists(disabled_dir.path_join("residents.json")),
		"disabled: reading the view writes no residents.json")


func _test_enabled_view() -> void:
	directory = base_root.path_join("enabled")
	DirAccess.make_dir_recursive_absolute(directory)
	var seeded: Dictionary = NatureStore.new(directory).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	_expect(bool(seeded.get("ok", false)),
		"enabled: the fixed seed is persisted before the world opens")
	world = World.new()
	var opened: Dictionary = world.open(directory, START, WORLD_ID, HOST)
	_expect(bool(opened.ok), "enabled: the world opens: "
		+ str(opened.get("reason", "")))
	var market: Dictionary = world.execute(
		FarmCommand.make_market_open("resident-view-market", START))
	_expect(bool(market.ok), "enabled: the merchant market opens: "
		+ str(market.get("reason", "")))
	world.enable_residents()
	var settled: Dictionary = world.settle_residents(AT)
	_expect(bool(settled.get("ok", false)), "enabled: the resident sweep succeeds: "
		+ str(settled.get("reason", "")))
	_expect(int(settled.counts.get("purchased", 0)) == NpcRoster.IDS.size(),
		"enabled: every resident completed a real purchase")
	_expect(int(settled.counts.get("socialized", 0)) >= NpcRoster.IDS.size(),
		"enabled: every resident produced at least one social action")

	var view: Dictionary = world.residents_view(VIEWER)
	view_before = view.duplicate(true)
	_expect(bool(view.get("available", false)),
		"enabled: the view reports available")
	_expect(str(view.get("reason", "")) == "",
		"enabled: the available view carries no failure reason")
	_expect(str(view.get("viewer", "")) == VIEWER,
		"enabled: the viewer is echoed back")
	var rows: Array = view.get("residents", [])
	_expect(rows.size() == NpcRoster.IDS.size(),
		"enabled: the view has one row per roster resident")
	var ids: Array = []
	for row_value: Variant in rows:
		if row_value is Dictionary:
			ids.append(str((row_value as Dictionary).get("id", "")))
	_expect(JSON.stringify(ids) == JSON.stringify(NpcRoster.IDS),
		"enabled: rows follow NpcRoster.IDS order")

	var seed_value: int = world.nature.get_seed()
	var index: int = 0
	for npc_id: String in NpcRoster.IDS:
		var row: Dictionary = rows[index]
		index += 1
		_expect(row.size() == ROW_KEYS.size(),
			"%s: the row has exactly the documented fields" % npc_id)
		for key: String in ROW_KEYS:
			_expect(row.has(key), "%s: the row carries %s" % [npc_id, key])
		_expect(str(row.get("id", "")) == npc_id, "%s: the id is fixed" % npc_id)
		_expect(str(row.get("display_name", ""))
				== str(NpcRoster.DISPLAY_NAMES.get(npc_id, "")),
			"%s: the display name comes from the roster" % npc_id)
		_expect(str(row.get("role", "")) == NpcRoles.role_of(npc_id),
			"%s: the role comes from NpcRoles" % npc_id)
		var expected_traits: Dictionary = NpcPersonality.traits(
			npc_id, seed_value).traits
		_expect((row.get("traits", {}) as Dictionary) == expected_traits,
			"%s: traits are the existing derived profile" % npc_id)
		_expect((row.get("traits", {}) as Dictionary).size() == 5,
			"%s: traits keep five dimensions" % npc_id)
		var relations: Array = row.get("relations", [])
		_expect(relations.size() == 2,
			"%s: exactly the other two residents are related" % npc_id)
		var peer_ids: Array = []
		var total_acts: int = 0
		for peer_value: Variant in relations:
			var peer: Dictionary = peer_value
			_expect(peer.size() == RELATION_KEYS.size(),
				"%s: the relation row has exactly the documented fields" % npc_id)
			peer_ids.append(str(peer.get("id", "")))
			_expect(str(peer.get("id", "")) != npc_id,
				"%s: a relation never names the resident itself" % npc_id)
			_expect(not str(peer.get("display_name", "")).is_empty(),
				"%s: the relation names its peer" % npc_id)
			_expect(int(peer.get("affinity", 0)) >= -100
					and int(peer.get("affinity", 0)) <= 100,
				"%s: affinity stays in -100..100" % npc_id)
			_expect(float(peer.get("last_utc", -1.0)) >= 0.0,
				"%s: the relation time is non-negative" % npc_id)
			_expect(int(peer.get("acts", -1)) >= 0
					and int(peer.get("gifts", -1)) >= 0,
				"%s: action and gift counts are non-negative" % npc_id)
			total_acts += int(peer.get("acts", 0))
		var expected_peers: Array = []
		for other: String in NpcRoster.IDS:
			if other != npc_id:
				expected_peers.append(other)
		_expect(JSON.stringify(peer_ids) == JSON.stringify(expected_peers),
			"%s: relations keep the roster order" % npc_id)
		_expect(total_acts > 0,
			"%s: the settled social action is counted" % npc_id)
		_expect(int(row.get("memory_count", 0)) == total_acts,
			"%s: memory rows match the resident's own actions" % npc_id)
		_expect(is_equal_approx(float(row.get("last_memory_utc", -1.0)), AT),
			"%s: the latest memory time is the settlement instant" % npc_id)
		_expect(int(row.get("intents_consumed", 0)) == 1,
			"%s: one consumed purchase intent is reported" % npc_id)
		var purchase: Dictionary = row.get("last_purchase", {})
		_expect(not purchase.is_empty(),
			"%s: the completed purchase is projected" % npc_id)
		_expect(EconomyCatalog.goods_ids().has(str(purchase.get("good", ""))),
			"%s: the projected purchase names a catalog good" % npc_id)
		_expect(is_equal_approx(float(purchase.get("at_utc", -1.0)), AT),
			"%s: the projected purchase carries its time" % npc_id)


func _test_privacy_and_read_only() -> void:
	var view: Dictionary = world.residents_view(VIEWER)
	_expect(JSON.stringify(view) == JSON.stringify(view_before),
		"read-only: repeating the view returns byte-identical rows")
	_expect(_forbidden_path(view).is_empty(),
		"privacy: no cash, account, goods, ownership or memory-body key is exposed")
	var serialized: String = JSON.stringify(view)
	var leaked: String = _memory_text(world.resident_memories, serialized)
	_expect(leaked.is_empty(),
		"privacy: no memory summary text appears in the view (%s)" % leaked)
	_expect(not serialized.contains("\"entries\""),
		"privacy: the memory entry table is not serialized")
	_expect(not serialized.contains("\"cash\""),
		"privacy: cash is not serialized")
	_expect(not serialized.contains("\"owner\""),
		"privacy: ownership is not serialized")

	var social_before: String = JSON.stringify(world.resident_social)
	var memories_before: String = JSON.stringify(world.resident_memories)
	var ledger_before: String = JSON.stringify(world.residents)
	var other: Dictionary = world.residents_view("")
	_expect(JSON.stringify(world.resident_social) == social_before,
		"read-only: rendering the view does not change relations")
	_expect(JSON.stringify(world.resident_memories) == memories_before,
		"read-only: rendering the view does not change memories")
	_expect(JSON.stringify(world.residents) == ledger_before,
		"read-only: rendering the view does not change the intent ledger")
	_expect(str(other.get("viewer", "missing")) == "",
		"read-only: an empty viewer is still a valid read")
	_expect(JSON.stringify(other.get("residents", [])) \
			== JSON.stringify(view.get("residents", [])),
		"read-only: the viewer does not change the resident rows")


func _test_restart_consistency() -> void:
	var social_before: String = JSON.stringify(world.resident_social)
	var memories_before: String = JSON.stringify(world.resident_memories)
	var ledger_before: String = JSON.stringify(world.residents)
	var reopened := World.new()
	var opened: Dictionary = reopened.open(directory, AT, WORLD_ID, HOST)
	_expect(bool(opened.ok), "restart: the world reopens: "
		+ str(opened.get("reason", "")))
	_expect(str(opened.get("kind", "")) == "loaded",
		"restart: the sidecar is loaded from disk")
	_expect(not reopened.residents_enabled,
		"restart: residents stay disabled until explicitly enabled")
	var closed_view: Dictionary = reopened.residents_view(VIEWER)
	_expect(str(closed_view.get("reason", "")) == "disabled",
		"restart: the disabled view stays disabled")
	reopened.enable_residents()
	var view: Dictionary = reopened.residents_view(VIEWER)
	_expect(JSON.stringify(view) == JSON.stringify(view_before),
		"restart: the enabled view is identical after the restart")
	var settled: Dictionary = reopened.settle_residents(AT)
	_expect(bool(settled.ok), "restart: the same-instant sweep still runs")
	_expect(not bool(settled.get("changed", true)),
		"restart: the same instant repeats no purchase or social action")
	_expect(JSON.stringify(reopened.residents_view(VIEWER)) \
			== JSON.stringify(view_before),
		"restart: the view stays identical after a same-instant sweep")
	_expect(JSON.stringify(reopened.resident_social) == social_before \
			and JSON.stringify(reopened.resident_memories) == memories_before \
			and JSON.stringify(reopened.residents) == ledger_before,
		"restart: relations, memories and the intent ledger are unchanged")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Returns the first forbidden key found at any depth, or "".
func _forbidden_path(value: Variant) -> String:
	if value is Dictionary:
		for key: Variant in (value as Dictionary).keys():
			if str(key) in FORBIDDEN_KEYS:
				return str(key)
			var nested: String = _forbidden_path((value as Dictionary)[key])
			if not nested.is_empty():
				return nested
	elif value is Array:
		for item: Variant in value:
			var nested: String = _forbidden_path(item)
			if not nested.is_empty():
				return nested
	return ""


## Returns the first memory summary that leaked into `serialized`, or "".
func _memory_text(memories: Dictionary, serialized: String) -> String:
	var npcs: Variant = memories.get("npcs", {})
	if not npcs is Dictionary:
		return ""
	for row_value: Variant in (npcs as Dictionary).values():
		if not row_value is Dictionary:
			continue
		var entries: Variant = (row_value as Dictionary).get("entries", {})
		if not entries is Dictionary:
			continue
		for entry_value: Variant in (entries as Dictionary).values():
			if not entry_value is Dictionary:
				continue
			var summary: String = str((entry_value as Dictionary).get("summary", ""))
			if not summary.is_empty() and serialized.contains(summary):
				return summary
	return ""


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)
