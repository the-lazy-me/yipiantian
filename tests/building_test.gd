extends SceneTree
## M5-04 住宅首版核心：固定宅基槽位、建造占用与工期、拆除。
##
## 只覆盖权威状态层、命令层与落盘，不加载任何美术或场景资源。
## 契约：首版没有材料账本，建造不扣资源也不产生回收物；只有具名成员能建造，
## 建造者即房主，只有房主能拆除；工期由 started_utc/done_utc 直接比较得出。

const Farm = preload("res://farm/farm_state.gd")
const Buildings = preload("res://farm/building_catalog.gd")
const Command = preload("res://farm/farm_command.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")

const START: float = 1800000000.0
const OWNER: String = "player_00000000000000000000000000000001"
const OTHER: String = "player_00000000000000000000000000000002"

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join("../.local/verification/building-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_catalog()
	_test_build_lifecycle()
	_test_build_rejections()
	_test_occupied()
	_test_concurrent_commands()
	_test_demolish()
	_test_command_layer()
	_test_buildings_at()
	_test_persistence()
	for failure: String in failures:
		push_error(failure)
	_remove_tree(test_root)
	print("BUILDING_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_catalog() -> void:
	_expect(Buildings.SLOTS.size() == 6, "宅基槽位数量为 6")
	var unique: Dictionary = {}
	for slot_id: String in Buildings.SLOTS:
		unique[slot_id] = true
	_expect(unique.size() == Buildings.SLOTS.size(), "宅基槽位唯一")
	var names: Dictionary = Buildings.slot_names()
	_expect(names.size() == Buildings.SLOTS.size(), "slot_names 覆盖全部槽位")
	for slot_id: String in Buildings.SLOTS:
		_expect(names.has(slot_id) and not str(names[slot_id]).is_empty(),
			"槽位 %s 有中文名" % slot_id)
		_expect(Buildings.name_of_slot(slot_id) == str(names.get(slot_id, "")),
			"name_of_slot(%s) 与 slot_names 一致" % slot_id)
	_expect(Buildings.name_of_slot("yard_z") == "", "未知槽位名称为空")

	var ids: Array[String] = Buildings.blueprint_ids()
	_expect(not ids.is_empty(), "蓝图目录非空")
	for blueprint_id: String in ["cottage", "workshop", "pavilion"]:
		_expect(blueprint_id in ids, "蓝图目录包含 %s" % blueprint_id)
	for blueprint_id: String in ids:
		var definition: Dictionary = Buildings.definition(blueprint_id)
		_expect(not str(definition.get("name", "")).is_empty(),
			"蓝图 %s 有名称" % blueprint_id)
		var seconds: Variant = definition.get("build_seconds")
		_expect((seconds is int or seconds is float) and is_finite(float(seconds)) and float(seconds) > 0.0,
			"蓝图 %s 的 build_seconds 是正数" % blueprint_id)
		_expect(Buildings.duration(blueprint_id) == float(seconds),
			"duration(%s) 与定义一致" % blueprint_id)
	_expect(Buildings.definition("mansion").is_empty(), "未知蓝图返回空定义")
	_expect(Buildings.duration("mansion") == 0.0, "未知蓝图工期为 0")


func _test_build_lifecycle() -> void:
	var farm := Farm.new(START)
	var before: Dictionary = farm.snapshot()
	var result: Dictionary = farm.build("yard_a", "cottage", START, OWNER)
	_expect(result.ok and str(result.get("reason", "")) == "", "具名成员建造成功")
	_expect(farm.building_state("yard_a", START) == "building", "建造后状态为 building")
	var duration: float = Buildings.duration("cottage")
	_expect(farm.building_state("yard_a", START + duration - 1.0) == "building",
		"done_utc 之前仍为 building")
	_expect(farm.building_state("yard_a", START + duration) == "done",
		"到 done_utc 时状态为 done")
	_expect(farm.building_state("yard_a", START + duration + 1.0) == "done",
		"done_utc 之后保持 done")
	_expect(farm.building_state("yard_b", START) == "empty", "未占用槽位状态为 empty")
	_expect(farm.building_state("yard_z", START) == "empty", "未知槽位状态为 empty")

	var record: Dictionary = farm.snapshot().buildings.yard_a
	_expect(str(record.blueprint) == "cottage" and str(record.owner) == OWNER,
		"记录保存蓝图与房主")
	_expect(float(record.started_utc) == START and float(record.done_utc) == START + duration,
		"记录保存起止时间")

	var after: Dictionary = farm.snapshot()
	after.erase("buildings")
	before.erase("buildings")
	_expect(after == before, "建造不改变其它状态（首版没有材料账本）")


func _test_build_rejections() -> void:
	var farm := Farm.new(START)
	var before: Dictionary = farm.snapshot()
	_expect(farm.build("yard_a", "cottage", START, "").reason == "invalid_player",
		"匿名建造被拒绝为 invalid_player")
	_expect(farm.build("yard_a", "cottage", START, "bad id").reason == "invalid_player",
		"非法玩家 ID 被拒绝为 invalid_player")
	_expect(farm.build("yard_z", "cottage", START, OWNER).reason == "invalid_slot",
		"未知槽位被拒绝为 invalid_slot")
	_expect(farm.build("yard_a", "mansion", START, OWNER).reason == "invalid_blueprint",
		"未知蓝图被拒绝为 invalid_blueprint")
	_expect(farm.build("yard_a", "cottage", -1.0, OWNER).reason == "invalid_time",
		"负时间被拒绝为 invalid_time")
	_expect(farm.build("yard_a", "cottage", INF, OWNER).reason == "invalid_time",
		"非有限时间被拒绝为 invalid_time")
	_expect(farm.snapshot() == before, "所有建造拒绝都是原子无操作")


func _test_occupied() -> void:
	var farm := Farm.new(START)
	_expect(farm.build("yard_a", "cottage", START, OWNER).ok, "第一次建造成功")
	var snapshot: Dictionary = farm.snapshot()
	var during: Dictionary = farm.build("yard_a", "workshop", START + 10.0, OTHER)
	_expect(not during.ok and during.reason == "occupied",
		"施工中同一槽位再建得 occupied")
	_expect(farm.snapshot() == snapshot, "施工中占用拒绝不改变原记录")
	var done_time: float = START + Buildings.duration("cottage")
	var after: Dictionary = farm.build("yard_a", "pavilion", done_time, OTHER)
	_expect(not after.ok and after.reason == "occupied",
		"完工后同一槽位再建得 occupied")
	_expect(farm.snapshot() == snapshot, "完工后占用拒绝不改变原记录")
	_expect(farm.building_state("yard_a", done_time) == "done", "原建筑仍按时间完工")
	_expect(farm.snapshot().buildings.yard_a.owner == OWNER
		and farm.snapshot().buildings.yard_a.blueprint == "cottage",
		"原记录仍属于第一位建造者")


func _test_concurrent_commands() -> void:
	var farm := Farm.new(START)
	var commands := Command.new()
	var first: Dictionary = _execute(commands, farm,
		Command.make_build("build-a", "yard_a", "cottage", START), OWNER)
	_expect(first.get("ok", false) and _accept(farm, first), "第一条建造命令提交成功")
	var second: Dictionary = _execute(commands, farm,
		Command.make_build("build-b", "yard_a", "workshop", START + 1.0), OTHER)
	_expect(not second.get("ok", true) and str(second.get("reason", "")) == "occupied",
		"同一槽位的第二条命令得 occupied")
	_expect(second.get("candidate", null) == null, "失败命令不产生候选状态")
	_expect(farm.snapshot().buildings.yard_a.owner == OWNER
		and farm.snapshot().buildings.yard_a.blueprint == "cottage",
		"权威命令通道串行化后只有第一条生效")


func _test_demolish() -> void:
	var farm := Farm.new(START)
	_expect(farm.demolish("yard_a", START, OWNER).reason == "empty",
		"空槽位拆除得 empty")
	_expect(farm.build("yard_a", "cottage", START, OWNER).ok, "房主建下小屋")
	var snapshot: Dictionary = farm.snapshot()
	var stranger: Dictionary = farm.demolish("yard_a", START + 1.0, OTHER)
	_expect(not stranger.ok and stranger.reason == "not_owner",
		"非房主拆除得 not_owner")
	_expect(farm.snapshot() == snapshot, "非房主拒绝不改变记录")
	_expect(farm.demolish("yard_a", START + 1.0, OWNER).ok, "施工中房主可以拆除")
	_expect(farm.building_state("yard_a", START + 1.0) == "empty", "拆除后槽位回到 empty")
	_expect(not farm.snapshot().buildings.has("yard_a"), "拆除删除该槽位记录")

	var done_time: float = START + Buildings.duration("workshop") + 1.0
	_expect(farm.build("yard_b", "workshop", START, OWNER).ok, "房主建下工坊")
	_expect(farm.building_state("yard_b", done_time) == "done", "工坊按工期完工")
	_expect(farm.demolish("yard_b", done_time, OTHER).reason == "not_owner",
		"完工后他人仍不能拆")
	_expect(farm.demolish("yard_b", done_time, OWNER).ok, "完工后房主可以拆除")
	_expect(farm.building_state("yard_b", done_time) == "empty", "完工拆除后槽位回到 empty")

	_expect(farm.demolish("yard_z", START, OWNER).reason == "invalid_slot",
		"拆除未知槽位得 invalid_slot")
	_expect(farm.demolish("yard_a", START, "").reason == "invalid_player",
		"匿名拆除得 invalid_player")
	_expect(farm.demolish("yard_a", -1.0, OWNER).reason == "invalid_time",
		"拆除负时间得 invalid_time")


func _test_command_layer() -> void:
	var farm := Farm.new(START)
	var commands := Command.new()
	var build: Dictionary = Command.make_build("cmd-build", "yard_a", "cottage", START)
	_expect(build.size() == 5 and str(build.id) == "cmd-build" and str(build.kind) == Command.BUILD
		and str(build.slot_id) == "yard_a" and str(build.blueprint) == "cottage"
		and float(build.at_utc) == START,
		"make_build 产生 {id, kind, slot_id, blueprint, at_utc} 五个键")
	_expect(Command.BUILD in Command.KINDS and Command.DEMOLISH in Command.KINDS,
		"BUILD 与 DEMOLISH 已加入 KINDS")
	_expect(Command.valid(build), "build 命令形状合法")
	var demolish: Dictionary = Command.make_demolish("cmd-demolish", "yard_a", START + 5.0)
	_expect(demolish.size() == 4 and str(demolish.kind) == Command.DEMOLISH
		and str(demolish.slot_id) == "yard_a" and float(demolish.at_utc) == START + 5.0,
		"make_demolish 产生 {id, kind, slot_id, at_utc} 四个键")
	_expect(Command.valid(demolish), "demolish 命令形状合法")

	var with_from: Dictionary = Command.make_build("cmd-from", "yard_a", "cottage", START)
	with_from["from"] = OWNER
	_expect(not Command.valid(with_from), "build 命令不得携带 from")
	var demolish_from: Dictionary = Command.make_demolish("cmd-from-id", "yard_a", START)
	demolish_from["from_id"] = OWNER
	_expect(not Command.valid(demolish_from), "demolish 命令不得携带 from_id")
	var with_field: Dictionary = Command.make_build("cmd-field", "yard_a", "cottage", START)
	with_field["field_id"] = "field_01"
	_expect(not Command.valid(with_field), "build 命令不得携带 field_id")
	var with_cell: Dictionary = Command.make_demolish("cmd-cell", "yard_a", START)
	with_cell["cell_id"] = "cell_01"
	_expect(not Command.valid(with_cell), "demolish 命令不得携带 cell_id")
	_expect(not Command.valid(Command.make_build("cmd-empty-slot", "", "cottage", START)),
		"build 的 slot_id 不能为空")
	_expect(not Command.valid(Command.make_build("cmd-empty-blueprint", "yard_a", "", START)),
		"build 的 blueprint 不能为空")
	_expect(not Command.valid(Command.make_demolish("cmd-empty-demolish", "", START)),
		"demolish 的 slot_id 不能为空")
	var long_blueprint: String = "x".repeat(Command.MAX_ID_LENGTH + 1)
	_expect(not Command.valid(Command.make_build("cmd-long", "yard_a", long_blueprint, START)),
		"blueprint 超过 MAX_ID_LENGTH 非法")
	_expect(not Command.valid(Command.make_demolish("cmd-long-slot", long_blueprint, START)),
		"slot_id 超过 MAX_ID_LENGTH 非法")

	var first: Dictionary = _execute(commands, farm, build, OWNER)
	_expect(first.get("ok", false) and not first.get("duplicate", true),
		"build 命令执行一次成功")
	_expect(_accept(farm, first), "build 命令提交候选状态")
	_expect(farm.building_state("yard_a", START) == "building", "命令执行后建筑进入施工中")
	var replay: Dictionary = _execute(commands, farm, build, OWNER)
	_expect(replay.get("ok", false) and replay.get("duplicate", false),
		"同一 build id 重放返回 duplicate=true")
	var changed: Dictionary = Command.make_build("cmd-build", "yard_a", "workshop", START)
	var conflict: Dictionary = _execute(commands, farm, changed, OWNER)
	_expect(not conflict.get("ok", true) and str(conflict.get("reason", "")) == "command_conflict"
		and conflict.get("duplicate", false),
		"同一 build id 不同蓝图被判为 command_conflict")
	var other_actor: Dictionary = _execute(commands, farm, build, OTHER)
	_expect(not other_actor.get("ok", true) and str(other_actor.get("reason", "")) == "command_conflict"
		and other_actor.get("duplicate", false),
		"同一 build id 换执行者被判为 command_conflict")
	_expect(farm.snapshot().buildings.yard_a.blueprint == "cottage"
		and farm.snapshot().buildings.yard_a.owner == OWNER,
		"冲突载荷不改变建筑记录")

	var anonymous: Dictionary = _execute(commands, farm,
		Command.make_build("cmd-anon", "yard_b", "cottage", START), "")
	_expect(not anonymous.get("ok", true) and str(anonymous.get("reason", "")) == "invalid_player",
		"匿名 build 命令被拒绝")
	_expect(farm.building_state("yard_b", START) == "empty", "匿名拒绝不占用槽位")

	var demolished: Dictionary = _execute(commands, farm, demolish, OWNER)
	_expect(demolished.get("ok", false) and _accept(farm, demolished),
		"demolish 命令执行一次成功")
	_expect(farm.building_state("yard_a", START) == "empty", "命令拆除后槽位回到 empty")
	var demolish_replay: Dictionary = _execute(commands, farm, demolish, OWNER)
	_expect(demolish_replay.get("ok", false) and demolish_replay.get("duplicate", false),
		"同一 demolish id 重放返回 duplicate=true")
	var demolish_other: Dictionary = _execute(commands, farm, demolish, OTHER)
	_expect(not demolish_other.get("ok", true)
		and str(demolish_other.get("reason", "")) == "command_conflict"
		and demolish_other.get("duplicate", false),
		"同一 demolish id 换执行者被判为 command_conflict")
	var demolish_changed: Dictionary = Command.make_demolish("cmd-demolish", "yard_a", START + 6.0)
	var demolish_conflict: Dictionary = _execute(commands, farm, demolish_changed, OWNER)
	_expect(not demolish_conflict.get("ok", true)
		and str(demolish_conflict.get("reason", "")) == "command_conflict"
		and demolish_conflict.get("duplicate", false),
		"同一 demolish id 不同时间被判为 command_conflict")


func _test_buildings_at() -> void:
	var farm := Farm.new(START)
	_expect(farm.buildings_at(START).is_empty(), "没有建筑时 buildings_at 为空")
	_expect(farm.build("yard_c", "cottage", START, OWNER).ok, "建下小屋")
	_expect(farm.build("yard_d", "pavilion", START + 10.0, OTHER).ok, "建下凉亭")
	var during: Dictionary = farm.buildings_at(START + 10.0)
	_expect(during.size() == 2 and during.has("yard_c") and during.has("yard_d"),
		"buildings_at 只列出已占用槽位")
	_expect(not during.has("yard_a"), "空槽位不在 buildings_at 中")
	var cottage: Dictionary = during.yard_c
	_expect(str(cottage.blueprint) == "cottage" and str(cottage.name) == "小屋"
		and str(cottage.owner) == OWNER and str(cottage.state) == "building",
		"buildings_at 带蓝图、中文名、房主与状态")
	_expect(float(cottage.started_utc) == START and float(cottage.done_utc) == START + 600.0,
		"buildings_at 带起止时间")
	var later: Dictionary = farm.buildings_at(START + 400.0)
	_expect(str(later.yard_c.state) == "building" and str(later.yard_d.state) == "done",
		"状态按传入时间分别计算")
	var finished: Dictionary = farm.buildings_at(START + 600.0)
	_expect(str(finished.yard_c.state) == "done" and str(finished.yard_d.state) == "done",
		"两个建筑到各自 done_utc 后都为 done")


func _test_persistence() -> void:
	var farm := Farm.new(START)
	_expect(farm.build("yard_a", "cottage", START, OWNER).ok, "落盘前建下小屋")
	_expect(farm.build("yard_b", "pavilion", START + 10.0, OTHER).ok, "落盘前建下凉亭")

	var store := FarmStore.new(test_root.path_join("store"))
	_expect(store.load_state().kind == "missing", "全新存档目录被接受")
	_expect(store.save(farm.snapshot(), Decorations.new().snapshot()).ok,
		"带建筑的农场可以保存")
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok, "保存的农场可以加载")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(loaded.farm), "加载的农场可以恢复")
	_expect(restored.snapshot().buildings == farm.snapshot().buildings,
		"落盘往返后建筑与时间不丢")
	_expect(restored.building_state("yard_a", START) == "building"
		and restored.building_state("yard_a", START + 600.0) == "done",
		"落盘往返后工期仍按时间计算")
	_expect(str(restored.snapshot().buildings.yard_b.owner) == OTHER,
		"落盘往返后房主保留")

	var via_json: Variant = JSON.parse_string(JSON.stringify(farm.snapshot()))
	_expect(via_json is Dictionary and restored.restore_snapshot(via_json),
		"JSON 快照可以恢复")
	_expect(restored.snapshot().buildings == farm.snapshot().buildings,
		"JSON 往返后建筑保持")
	_expect(typeof(restored.snapshot().buildings.yard_a.started_utc) == TYPE_FLOAT
		and typeof(restored.snapshot().buildings.yard_a.done_utc) == TYPE_FLOAT,
		"恢复时时间归一化为 float")

	# 旧文档没有 buildings 键：恢复为空表。
	var old: Dictionary = farm.snapshot()
	old.erase("buildings")
	var migrated := Farm.new()
	_expect(migrated.restore_snapshot(old), "缺少 buildings 键的旧快照仍可恢复")
	_expect(migrated.snapshot().get("buildings", null) == {}, "缺失的 buildings 表恢复为空表")
	_expect(migrated.buildings_at(START).is_empty(), "旧快照没有建筑")

	# 整数时间戳同样是合法文档，恢复后归一化为 float。
	var int_times: Dictionary = farm.snapshot()
	int_times.buildings.yard_a.started_utc = int(START)
	int_times.buildings.yard_a.done_utc = int(START + 600.0)
	var int_restored := Farm.new()
	_expect(int_restored.restore_snapshot(int_times), "整数时间戳的 buildings 可恢复")
	_expect(typeof(int_restored.snapshot().buildings.yard_a.started_utc) == TYPE_FLOAT,
		"恢复时整数时间戳归一化为 float")

	# 非法的 buildings 整份拒绝，且不改动当前状态。
	var cases: Array[Dictionary] = []
	var unknown_slot: Dictionary = farm.snapshot()
	unknown_slot.buildings["yard_z"] = unknown_slot.buildings.yard_a.duplicate(true)
	cases.append(unknown_slot)
	var missing_field: Dictionary = farm.snapshot()
	missing_field.buildings.yard_a.erase("owner")
	cases.append(missing_field)
	var extra_field: Dictionary = farm.snapshot()
	extra_field.buildings.yard_a["extra"] = true
	cases.append(extra_field)
	var stranger: Dictionary = farm.snapshot()
	stranger.buildings.yard_a.owner = "bad id"
	cases.append(stranger)
	var reversed_time: Dictionary = farm.snapshot()
	reversed_time.buildings.yard_a.done_utc = float(reversed_time.buildings.yard_a.started_utc) - 1.0
	cases.append(reversed_time)
	var unknown_blueprint: Dictionary = farm.snapshot()
	unknown_blueprint.buildings.yard_a.blueprint = "mansion"
	cases.append(unknown_blueprint)
	var not_a_table: Dictionary = farm.snapshot()
	not_a_table.buildings = []
	cases.append(not_a_table)
	for index: int in cases.size():
		var target := Farm.new(START)
		_expect(target.build("yard_c", "cottage", START, OWNER).ok, "拒绝用例前先有合法建筑")
		var before: Dictionary = target.snapshot()
		_expect(not target.restore_snapshot(cases[index]),
			"非法 buildings 第 %d 例整份拒绝" % (index + 1))
		_expect(target.snapshot() == before, "整份拒绝后当前状态不变")


func _execute(commands: RefCounted, farm: RefCounted, command: Dictionary, actor: String) -> Dictionary:
	var result: Variant = commands.execute(farm, command, actor)
	return result if result is Dictionary else {}


func _accept(farm: RefCounted, result: Dictionary) -> bool:
	var candidate: Variant = result.get("candidate", null)
	if candidate == null:
		return false
	farm.accept(candidate)
	return true


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for name: String in directory.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name: String in directory.get_directories():
		_remove_tree(path.path_join(name))
	DirAccess.remove_absolute(path)
