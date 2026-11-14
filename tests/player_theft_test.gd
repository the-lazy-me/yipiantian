extends SceneTree
## M5-03 可选偷菜：默认和平关闭，所有者开启后他人可在限额与冷却内偷取。
##
## 只覆盖权威状态层、命令层与落盘，不加载任何美术或场景资源。
## 契约：具名播种记录归属；收获默认只允许所有者；所有者开启偷菜后他人可偷，
## 受“每个所有者每天最多 3 次损失”和“同一小偷对同一所有者 10 分钟冷却”约束；
## 所有拒绝都必须是原子无操作（格子、口袋、计数、命令序号都不变）。

const Farm = preload("res://farm/farm_state.gd")
const Crops = preload("res://farm/crop_catalog.gd")
const Command = preload("res://farm/farm_command.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")

# 2027-01-15 08:00 UTC 附近；推进 THEFT_COOLDOWN_SECONDS + 1 秒不会跨日。
const START: float = 1800000000.0
const OWNER: String = "player_00000000000000000000000000000001"
const THIEF_A: String = "player_0000000000000000000000000000000a"
const THIEF_B: String = "player_0000000000000000000000000000000b"
const THIEF_C: String = "player_0000000000000000000000000000000c"
const THIEF_D: String = "player_0000000000000000000000000000000d"
const THIEF_E: String = "player_0000000000000000000000000000000e"

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join("../.local/verification/player-theft-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_owner_attribution()
	_test_owner_harvest()
	_test_unenabled_rejects()
	_test_theft_toggle()
	_test_successful_theft()
	_test_daily_limit()
	_test_cooldown()
	_test_authorized_harvest()
	_test_unowned_cells()
	_test_command_layer()
	_test_persistence()
	for failure: String in failures:
		push_error(failure)
	_remove_tree(test_root)
	print("PLAYER_THEFT_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_owner_attribution() -> void:
	var farm := Farm.new(START)
	_expect(farm.owner_of("field_03", "cell_06") == "", "初始作物没有 planted_by，视为无主")
	_expect(farm.owner_of("field_01", "cell_01") == "", "空格返回空所有者")
	_expect(farm.owner_of("missing_field", "cell_01") == "", "不存在的田块返回空所有者")

	var sown: Dictionary = farm.sow("field_01", "cell_01", "greens", START, OWNER)
	_expect(sown.ok, "具名播种成功")
	_expect(farm.owner_of("field_01", "cell_01") == OWNER, "具名播种后 owner_of 返回播种者")
	_expect(str(farm.get_cell("field_01", "cell_01").get("planted_by", "")) == OWNER,
		"格子快照记录 planted_by")

	var anonymous := Farm.new(START)
	_expect(anonymous.sow("field_01", "cell_01", "greens", START).ok, "匿名播种仍成功")
	_expect(anonymous.owner_of("field_01", "cell_01") == "", "匿名播种的格子没有所有者")


func _test_owner_harvest() -> void:
	var farm := Farm.new(START)
	var common_before: int = int(farm.snapshot().inventory.greens)
	_expect(farm.sow("field_01", "cell_01", "greens", START, OWNER).ok, "所有者种下青菜")
	farm.mature_all_crops(START)
	var result: Dictionary = farm.harvest("field_01", "cell_01", START, OWNER)
	_expect(result.ok and result.reward_crop_id == "greens" and result.reward_amount == 1,
		"所有者收获自己的作物成功")
	_expect(int(farm.bag(OWNER).greens) == 1, "作物进入所有者自己的口袋")
	_expect(int(farm.snapshot().inventory.greens) == common_before, "所有者收获不经过公共库存")
	_expect(farm.get_cell("field_01", "cell_01").crop_id == "", "收获后格子清空")


func _test_unenabled_rejects() -> void:
	var farm := Farm.new(START)
	_expect(farm.sow("field_01", "cell_01", "greens", START, OWNER).ok, "所有者种下青菜")
	farm.mature_all_crops(START)
	var before: Dictionary = farm.snapshot()
	var harvested_before: int = int(farm.snapshot().harvested.greens)
	var result: Dictionary = farm.harvest("field_01", "cell_01", START, THIEF_A)
	_expect(not result.ok and result.reason == "not_owner",
		"所有者未开启偷菜时他人收获被拒绝为 not_owner")
	_expect(farm.snapshot() == before, "被拒绝的偷取不改变任何权威状态")
	_expect(farm.get_cell("field_01", "cell_01").stage == "mature", "被拒绝后作物仍留在格子里且成熟")
	_expect(int(farm.bag(THIEF_A).greens) == 0, "被拒绝后小偷口袋不变")
	_expect(int(farm.snapshot().harvested.greens) == harvested_before, "被拒绝后 harvested 计数不变")
	# 匿名收获同样不是所有者：默认和平规则对匿名成员一样生效。
	var anonymous: Dictionary = farm.harvest("field_01", "cell_01", START)
	_expect(not anonymous.ok and anonymous.reason == "not_owner",
		"匿名收获有主作物也被拒绝为 not_owner")
	_expect(farm.snapshot() == before, "匿名拒绝同样不改变状态")


func _test_theft_toggle() -> void:
	var farm := Farm.new(START)
	_expect(not farm.theft_enabled(OWNER), "偷菜开关默认关闭")
	var enabled: Dictionary = farm.set_theft(OWNER, true)
	_expect(enabled.ok and str(enabled.get("reason", "")) == "", "开启偷菜返回 ok")
	_expect(farm.theft_enabled(OWNER), "开启后 theft_enabled 为真")
	var disabled: Dictionary = farm.set_theft(OWNER, false)
	_expect(disabled.ok and not farm.theft_enabled(OWNER), "关闭后 theft_enabled 为假")
	var invalid: Dictionary = farm.set_theft("bad id", true)
	_expect(not invalid.ok and invalid.reason == "invalid_player", "非法玩家 ID 被拒绝为 invalid_player")
	var empty: Dictionary = farm.set_theft("", true)
	_expect(not empty.ok and empty.reason == "invalid_player", "空玩家 ID 被拒绝为 invalid_player")
	_expect(not farm.theft_enabled("bad id"), "非法 ID 查不到开启状态")
	# 给后面的用例留一个开启的开关。
	_expect(farm.set_theft(OWNER, true).ok and farm.theft_enabled(OWNER), "再次开启成功")


func _test_successful_theft() -> void:
	var farm := Farm.new(START)
	_expect(farm.sow("field_01", "cell_01", "greens", START, OWNER).ok, "所有者种下青菜")
	farm.mature_all_crops(START)
	_expect(farm.set_theft(OWNER, true).ok, "所有者开启偷菜")
	var common_before: int = int(farm.snapshot().inventory.greens)
	var harvested_before: int = int(farm.snapshot().harvested.greens)
	var lost_before: int = _lost(farm, OWNER)
	var result: Dictionary = farm.harvest("field_01", "cell_01", START, THIEF_A)
	_expect(result.ok and result.reward_crop_id == "greens" and result.reward_amount == 1,
		"开启后他人偷取成功并返回一份作物")
	_expect(int(farm.bag(THIEF_A).greens) == 1, "作物进入小偷自己的口袋")
	_expect(int(farm.bag(OWNER).greens) == 0, "作物没有进入所有者口袋")
	_expect(_lost(farm, OWNER) == lost_before + 1, "所有者当天的损失计数 +1")
	_expect(farm.get_cell("field_01", "cell_01").crop_id == "", "偷取成功后格子清空")
	_expect(farm.owner_of("field_01", "cell_01") == "", "清空后的格子没有所有者")
	_expect(int(farm.snapshot().inventory.greens) == common_before, "偷取不触碰公共库存")
	_expect(int(farm.snapshot().harvested.greens) == harvested_before + 1, "世界收获计数仍然推进")


func _test_daily_limit() -> void:
	var farm := Farm.new(START)
	for cell_id: String in ["cell_01", "cell_02", "cell_03", "cell_04"]:
		_expect(farm.sow("field_01", cell_id, "greens", START, OWNER).ok, "所有者种下第 %s 格" % cell_id)
	farm.mature_all_crops(START)
	_expect(farm.set_theft(OWNER, true).ok, "所有者开启偷菜")
	# 三个不同小偷各偷一格，绕开同一小偷的冷却，正好达到当天上限。
	for entry: Array in [[THIEF_A, "cell_01"], [THIEF_B, "cell_02"], [THIEF_C, "cell_03"]]:
		var allowed: Dictionary = farm.harvest("field_01", str(entry[1]), START, str(entry[0]))
		_expect(allowed.ok, "第 %s 个小偷在限额内偷取成功" % str(entry[0]))
	_expect(_lost(farm, OWNER) == Farm.MAX_THEFT_PER_DAY,
		"当天损失计数达到 MAX_THEFT_PER_DAY")
	var before: Dictionary = farm.snapshot()
	var blocked: Dictionary = farm.harvest("field_01", "cell_04", START, THIEF_D)
	_expect(not blocked.ok and blocked.reason == "theft_limit",
		"同一所有者当天第 4 次被偷拒绝为 theft_limit")
	_expect(farm.snapshot() == before, "超过每日上限的拒绝是原子无操作")
	_expect(int(farm.bag(THIEF_D).greens) == 0, "超限小偷口袋不变")
	_expect(farm.get_cell("field_01", "cell_04").stage == "mature", "超限后作物仍在")
	_expect(farm.theft_enabled(OWNER), "超限不改变偷菜开关")
	# “当天”按 UTC 日切分：跨日后上限重置，损失计数从零开始。
	var next_day: float = START + 86400.0
	var reset: Dictionary = farm.harvest("field_01", "cell_04", next_day, THIEF_D)
	_expect(reset.ok, "跨到下一个 UTC 日后损失上限重置")
	_expect(_lost(farm, OWNER) == 1, "新一天的损失计数从 1 开始")


func _test_cooldown() -> void:
	var farm := Farm.new(START)
	for cell_id: String in ["cell_01", "cell_02"]:
		_expect(farm.sow("field_01", cell_id, "greens", START, OWNER).ok, "所有者种下第 %s 格" % cell_id)
	farm.mature_all_crops(START)
	_expect(farm.set_theft(OWNER, true).ok, "所有者开启偷菜")
	_expect(farm.harvest("field_01", "cell_01", START, THIEF_A).ok, "小偷第一次偷取成功")
	var before: Dictionary = farm.snapshot()
	var early: Dictionary = farm.harvest("field_01", "cell_02", START, THIEF_A)
	_expect(not early.ok and early.reason == "theft_cooldown",
		"同一小偷立刻再偷同一所有者被拒绝为 theft_cooldown")
	_expect(farm.snapshot() == before, "冷却拒绝是原子无操作")
	_expect(farm.get_cell("field_01", "cell_02").stage == "mature", "冷却期间作物仍在")
	_expect(farm.sow("field_01", "cell_03", "greens", START, OWNER).ok, "所有者种下第三格")
	farm.mature_all_crops(START)
	var later: float = START + Farm.THEFT_COOLDOWN_SECONDS + 1.0
	var allowed: Dictionary = farm.harvest("field_01", "cell_02", later, THIEF_A)
	_expect(allowed.ok, "推进 THEFT_COOLDOWN_SECONDS + 1 秒后同一小偷可以再偷")
	_expect(_lost(farm, OWNER) == 2, "第二次成功偷取后损失计数为 2")
	# 冷却按“小偷 + 所有者”记录：同一时刻换一个小偷不受前一小偷的冷却限制。
	var other: Dictionary = farm.harvest("field_01", "cell_03", later, THIEF_B)
	_expect(other.ok, "不同小偷不受另一小偷的冷却影响")
	_expect(_lost(farm, OWNER) == 3, "第三个成功偷取后损失计数为 3")


func _test_authorized_harvest() -> void:
	var farm := Farm.new(START)
	_expect(farm.sow("field_01", "cell_01", "greens", START, OWNER).ok, "所有者种下青菜")
	farm.mature_all_crops(START)
	_expect(not farm.theft_enabled(OWNER), "授权收获不需要所有者开启偷菜")
	var lost_before: int = _lost(farm, OWNER)
	var result: Dictionary = farm.harvest("field_01", "cell_01", START, THIEF_A, true)
	_expect(result.ok, "authorized=true 时他人收获未开启偷菜的作物仍成功")
	_expect(int(farm.bag(THIEF_A).greens) == 1, "授权收获进入执行者口袋")
	_expect(_lost(farm, OWNER) == lost_before, "授权收获不计入偷菜损失")
	_expect(farm.get_cell("field_01", "cell_01").crop_id == "", "授权收获后格子清空")


func _test_unowned_cells() -> void:
	var farm := Farm.new(START)
	# 初始 field_03/cell_06 已经成熟且没有 planted_by：任何人都能收，行为与旧版一致。
	_expect(farm.owner_of("field_03", "cell_06") == "", "初始成熟作物没有所有者")
	var named: Dictionary = farm.harvest("field_03", "cell_06", START, THIEF_A)
	_expect(named.ok and int(farm.bag(THIEF_A).greens) == 1, "具名者可以收走无主初始作物")
	var anonymous := Farm.new(START)
	var plain: Dictionary = anonymous.harvest("field_03", "cell_06", START)
	_expect(plain.ok and int(anonymous.snapshot().inventory.greens) == 1,
		"匿名收获无主初始作物仍进公共库存")
	# 旧存档的格子没有 planted_by 键，恢复后同样视为无主。
	var data: Dictionary = Farm.new(START).snapshot()
	for field_id: String in data.fields:
		for cell_id: String in data.fields[field_id].cells:
			data.fields[field_id].cells[cell_id].erase("planted_by")
	var migrated := Farm.new()
	_expect(migrated.restore_snapshot(data), "缺少 planted_by 的旧格子快照仍可恢复")
	_expect(migrated.owner_of("field_03", "cell_06") == "", "旧快照恢复后格子视为无主")
	var old_result: Dictionary = migrated.harvest("field_03", "cell_06", START, THIEF_A)
	_expect(old_result.ok and int(migrated.bag(THIEF_A).greens) == 1,
		"旧快照中的无主成熟作物任何人可收")


func _test_command_layer() -> void:
	# set_theft 命令：形状、执行者来源、幂等与冲突。
	var farm := Farm.new(START)
	var commands := Command.new()
	var toggle: Dictionary = Command.make_set_theft("theft-on", true, START)
	_expect(toggle.size() == 4 and str(toggle.id) == "theft-on" and str(toggle.kind) == Command.SET_THEFT
		and bool(toggle.enabled) and float(toggle.at_utc) == START,
		"make_set_theft 产生 {id, kind, enabled, at_utc} 四个键")
	_expect(Command.SET_THEFT in Command.KINDS, "SET_THEFT 已加入 KINDS")
	_expect(Command.valid(toggle), "set_theft 命令形状合法")
	var first: Dictionary = _execute(commands, farm, toggle, OWNER)
	_expect(first.get("ok", false) and not first.get("duplicate", true), "set_theft 命令执行一次成功")
	_expect(_accept(farm, first), "set_theft 命令提交候选状态")
	_expect(farm.theft_enabled(OWNER), "命令执行后开关生效")
	var replay: Dictionary = _execute(commands, farm, toggle, OWNER)
	_expect(replay.get("ok", false) and replay.get("duplicate", false), "同一 set_theft id 重放返回 duplicate=true")
	var other_actor: Dictionary = _execute(commands, farm, toggle, THIEF_A)
	_expect(not other_actor.get("ok", true) and str(other_actor.get("reason", "")) == "command_conflict",
		"另一执行者用同一 id 重放被判为 command_conflict")
	var conflicting: Dictionary = Command.make_set_theft("theft-on", false, START)
	var conflict: Dictionary = _execute(commands, farm, conflicting, OWNER)
	_expect(not conflict.get("ok", true) and str(conflict.get("reason", "")) == "command_conflict"
		and conflict.get("duplicate", false),
		"同一 set_theft id 不同载荷被判为 command_conflict")
	_expect(farm.theft_enabled(OWNER), "冲突载荷不改变开关")

	var anonymous_command: Dictionary = Command.make_set_theft("theft-anon", false, START)
	var anonymous: Dictionary = _execute(commands, farm, anonymous_command, "")
	_expect(not anonymous.get("ok", true) and str(anonymous.get("reason", "")) == "invalid_player",
		"匿名执行 set_theft 被拒绝")
	_expect(farm.theft_enabled(OWNER), "匿名拒绝不改变开关")

	var with_sender: Dictionary = Command.make_set_theft("theft-sender", true, START)
	with_sender["from"] = OWNER
	_expect(not Command.valid(with_sender), "set_theft 命令不得携带发送者字段 from")
	var with_sender_id: Dictionary = Command.make_set_theft("theft-sender-id", true, START)
	with_sender_id["from_id"] = OWNER
	_expect(not Command.valid(with_sender_id), "set_theft 命令不得携带发送者字段 from_id")
	var with_player_id: Dictionary = Command.make_set_theft("theft-player-id", true, START)
	with_player_id["player_id"] = OWNER
	_expect(not Command.valid(with_player_id), "set_theft 的键集合严格为四个，额外 player_id 非法")
	var bad_enabled: Dictionary = Command.make_set_theft("theft-bad", true, START)
	bad_enabled.enabled = "yes"
	_expect(not Command.valid(bad_enabled), "enabled 必须是布尔值")

	# 命令层播种要带上执行者，否则联机时格子永远无主。
	var sow_commands := Command.new()
	var sow_farm := Farm.new(START)
	var sow: Dictionary = Command.make_sow("owner-sow", "field_01", "cell_01", "greens", START)
	_expect(Command.valid(sow), "播种命令形状合法")
	var sown: Dictionary = _execute(sow_commands, sow_farm, sow, OWNER)
	_expect(sown.get("ok", false) and not sown.get("duplicate", true), "命令层播种成功")
	_expect(_accept(sow_farm, sown), "命令层播种提交候选状态")
	_expect(sow_farm.owner_of("field_01", "cell_01") == OWNER,
		"命令层播种把执行者记为 planted_by")

	# 收获命令的 authorized 是可选第 6 键。
	var plain: Dictionary = Command.make("h-auth", "field_01", "cell_01", START)
	_expect(plain.size() == 5, "Command.make 仍产生 5 键收获命令")
	_expect(Command.valid(plain), "不带 authorized 的收获命令合法")
	var authorized: Dictionary = plain.duplicate(true)
	authorized["authorized"] = true
	_expect(authorized.size() == 6 and Command.valid(authorized), "带 authorized=true 的 6 键收获命令合法")
	var disabled_auth: Dictionary = plain.duplicate(true)
	disabled_auth["authorized"] = false
	_expect(Command.valid(disabled_auth), "带 authorized=false 的 6 键收获命令合法")
	var bad_auth: Dictionary = plain.duplicate(true)
	bad_auth["authorized"] = "yes"
	_expect(not Command.valid(bad_auth), "authorized 必须是布尔值")

	# authorized 参与幂等载荷：同 id 改变 authorized 必须冲突。
	var auth_farm := Farm.new(START)
	auth_farm.sow("field_01", "cell_01", "greens", START, OWNER)
	auth_farm.mature_all_crops(START)
	var auth_commands := Command.new()
	var committed_auth: Dictionary = Command.make("h-auth-payload", "field_01", "cell_01", START)
	committed_auth["authorized"] = true
	# 执行者是别人且所有者未开启偷菜；只有 authorized 才能让命令成功。
	var executed: Dictionary = _execute(auth_commands, auth_farm, committed_auth, THIEF_A)
	_expect(executed.get("ok", false) and not executed.get("duplicate", true),
		"命令层 authorized=true 的收获成功")
	_expect(_accept(auth_farm, executed), "命令层授权收获提交候选状态")
	_expect(int(auth_farm.bag(THIEF_A).greens) == 1, "命令层授权收获进入执行者口袋")
	var changed_auth: Dictionary = Command.make("h-auth-payload", "field_01", "cell_01", START)
	var auth_conflict: Dictionary = _execute(auth_commands, auth_farm, changed_auth, THIEF_A)
	_expect(not auth_conflict.get("ok", true) and str(auth_conflict.get("reason", "")) == "command_conflict"
		and auth_conflict.get("duplicate", false),
		"同 id 去掉 authorized 被判为 command_conflict")
	var auth_replay: Dictionary = _execute(auth_commands, auth_farm, committed_auth, THIEF_A)
	_expect(auth_replay.get("ok", false) and auth_replay.get("duplicate", false),
		"同 id 同 authorized 重放返回 duplicate=true")


func _test_persistence() -> void:
	var farm := Farm.new(START)
	for cell_id: String in ["cell_01", "cell_02"]:
		_expect(farm.sow("field_01", cell_id, "greens", START, OWNER).ok, "所有者种下第 %s 格" % cell_id)
	farm.mature_all_crops(START)
	_expect(farm.set_theft(OWNER, true).ok, "落盘前开启偷菜")
	_expect(farm.harvest("field_01", "cell_01", START, THIEF_A).ok, "落盘前偷取一格")
	_expect(_lost(farm, OWNER) == 1, "落盘前损失计数为 1")

	var store := FarmStore.new(test_root.path_join("store"))
	_expect(store.load_state().kind == "missing", "全新存档目录被接受")
	_expect(store.save(farm.snapshot(), Decorations.new().snapshot()).ok, "带偷菜状态的农场可以保存")
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok, "保存的农场可以加载")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(loaded.farm), "加载的农场可以恢复")
	_expect(restored.theft_enabled(OWNER), "落盘往返后偷菜开关保留")
	_expect(_lost(restored, OWNER) == 1, "落盘往返后损失计数保留")
	_expect(restored.owner_of("field_01", "cell_02") == OWNER, "落盘往返后 planted_by 保留")
	_expect(restored.owner_of("field_01", "cell_01") == "", "已被偷走的格子往返后仍无主")

	var via_json: Variant = JSON.parse_string(JSON.stringify(farm.snapshot()))
	_expect(via_json is Dictionary and restored.restore_snapshot(via_json), "JSON 快照可以恢复")
	_expect(restored.theft_enabled(OWNER) and _lost(restored, OWNER) == 1,
		"JSON 往返后开关与损失计数保持")

	# 旧文档没有 theft 键：恢复为空表，默认关闭。
	var old: Dictionary = farm.snapshot()
	old.erase("theft")
	var migrated := Farm.new()
	_expect(migrated.restore_snapshot(old), "缺少 theft 键的旧快照仍可恢复")
	_expect(migrated.snapshot().get("theft", null) == {}, "缺失的 theft 表恢复为空表")
	_expect(not migrated.theft_enabled(OWNER), "旧快照的偷菜开关默认关闭")
	_expect(migrated.owner_of("field_01", "cell_02") == OWNER, "旧快照仍保留 planted_by")


func _execute(commands: RefCounted, farm: RefCounted, command: Dictionary, actor: String) -> Dictionary:
	# 命令层当前实现有缺陷时可能返回 null；测试要能继续跑完并汇总，而不是中途崩溃。
	var result: Variant = commands.execute(farm, command, actor)
	return result if result is Dictionary else {}


func _accept(farm: RefCounted, result: Dictionary) -> bool:
	var candidate: Variant = result.get("candidate", null)
	if candidate == null:
		return false
	farm.accept(candidate)
	return true


func _lost(farm: RefCounted, player_id: String) -> int:
	# 契约只要求“当天的 lost 计数”，未规定表内键名；这里按权威快照读取。
	var theft: Dictionary = farm.snapshot().get("theft", {})
	var entry: Variant = theft.get(player_id)
	if not entry is Dictionary:
		return 0
	return int(entry.get("lost", 0))


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
