extends SceneTree
## M10-03 意图执行账本。无头、隔离：不读真实时钟，不接模型/网络/主循环，
## 也不触碰农场存档。临时文件写在 .local/verification 下。

const IntentState = preload("res://npc/npc_intent_state.gd")
const IntentStore = preload("res://npc/npc_intent_store.gd")

const START: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []
var root_dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = _repo().path_join(
		".local/verification/npc-intent-state-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)
	_test_empty_and_valid()
	_test_invalid_shapes()
	_test_record_and_cooldown()
	_test_bound_and_eviction()
	_test_read_only()
	_test_store_roundtrip()
	_test_store_corruption()
	_test_store_atomic_failure()
	for failure: String in failures:
		push_error(failure)
	print("NPC_INTENT_STATE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_empty_and_valid() -> void:
	var empty: Dictionary = IntentState.empty_state()
	_expect(IntentState.valid(empty), "空账本是合法文档")
	_expect(float(empty.until_utc) == 0.0, "空账本的冷却时刻为 0")
	_expect((empty.intents as Dictionary).is_empty(), "空账本没有消费记录")
	_expect(IntentState.valid({"until_utc": START, "intents": {"intent_a": START - 10.0}}),
		"历史消费早于冷却时刻时合法")
	_expect(IntentState.valid({"until_utc": 5, "intents": {"intent_a": 3}}),
		"整数时间字段同样合法")


func _test_invalid_shapes() -> void:
	_expect(not IntentState.valid(null), "null 文档被拒绝")
	_expect(not IntentState.valid([]), "数组文档被拒绝")
	_expect(not IntentState.valid({"until_utc": 0.0}), "缺少 intents 键被拒绝")
	_expect(not IntentState.valid({"until_utc": 0.0, "intents": {}, "extra": 1}),
		"未知键被拒绝")
	_expect(not IntentState.valid({"until_utc": -1.0, "intents": {}}),
		"负冷却时刻被拒绝")
	_expect(not IntentState.valid({"until_utc": INF, "intents": {}}),
		"非有限冷却时刻被拒绝")
	_expect(not IntentState.valid({"until_utc": "soon", "intents": {}}),
		"非数字冷却时刻被拒绝")
	_expect(not IntentState.valid({"until_utc": START, "intents": []}),
		"intents 不是字典被拒绝")
	_expect(not IntentState.valid({"until_utc": START, "intents": {"intent_a": -1.0}}),
		"负消费时刻被拒绝")
	_expect(not IntentState.valid({"until_utc": START, "intents": {"intent_a": "now"}}),
		"非数字消费时刻被拒绝")
	_expect(not IntentState.valid({"until_utc": START, "intents": {5: START}}),
		"非字符串 id 被拒绝")
	_expect(not IntentState.valid({"until_utc": START, "intents": {"": START}}),
		"空字符串 id 被拒绝")
	var long_id: String = "x".repeat(IntentState.MAX_ID_LENGTH + 1)
	_expect(not IntentState.valid({"until_utc": START, "intents": {long_id: START}}),
		"超长 id 被拒绝")
	_expect(not IntentState.valid({"until_utc": START, "intents": {"intent_a": START + 1.0}}),
		"消费时刻晚于冷却时刻被拒绝")
	var too_many: Dictionary = {"until_utc": float(IntentState.MAX_RECORDS + 1), "intents": {}}
	for index: int in IntentState.MAX_RECORDS + 1:
		too_many.intents["intent_%04d" % index] = float(index)
	_expect(not IntentState.valid(too_many), "超过记录上限的文档被拒绝")


func _test_record_and_cooldown() -> void:
	var empty: Dictionary = IntentState.empty_state()
	var first: Dictionary = IntentState.record(empty, "intent_one", START, START + 30.0)
	_expect(first.ok and str(first.reason).is_empty(), "合法消费被接受")
	_expect(IntentState.valid(first.state), "记录后的候选文档合法")
	_expect((first.state.intents as Dictionary).has("intent_one"), "记录后 id 存在")
	_expect(float(first.state.intents.intent_one) == START, "消费时刻按传入值记录")
	_expect(float(first.state.until_utc) == START + 30.0, "记录同时推进冷却时刻")
	_expect(float(empty.until_utc) == 0.0
		and (empty.intents as Dictionary).is_empty(), "record 不修改输入文档")

	var free: Dictionary = IntentState.cooling(empty, START)
	_expect(free.ok and not bool(free.cooling), "冷却时刻之前居民可用")
	var waiting: Dictionary = IntentState.cooling(first.state, START)
	_expect(waiting.ok and bool(waiting.cooling), "冷却时刻未到时居民冷却中")
	var boundary: Dictionary = IntentState.cooling(first.state, START + 30.0)
	_expect(boundary.ok and not bool(boundary.cooling), "到达冷却时刻即恢复可用")
	var bad_time: Dictionary = IntentState.cooling(empty, -1.0)
	_expect(not bad_time.ok and str(bad_time.reason) == "invalid_time"
		and bool(bad_time.cooling), "非法时间按冷却失败关闭")
	var bad_state: Dictionary = IntentState.cooling({}, START)
	_expect(not bad_state.ok and str(bad_state.reason) == "invalid_state",
		"非法文档冷却判定拒绝")

	var duplicate: Dictionary = IntentState.record(first.state, "intent_one",
		START + 30.0, START + 60.0)
	_expect(not duplicate.ok and str(duplicate.reason) == "duplicate_intent",
		"重复 id 被拒绝")
	var cooling_record: Dictionary = IntentState.record(first.state, "intent_two",
		START + 1.0, START + 31.0)
	_expect(not cooling_record.ok and str(cooling_record.reason) == "cooldown",
		"冷却中不得记录消费")
	var bad_until: Dictionary = IntentState.record(empty, "intent_two", START, START - 1.0)
	_expect(not bad_until.ok and str(bad_until.reason) == "invalid_cooldown",
		"冷却时刻早于本次消费被拒绝")
	var regressed: Dictionary = IntentState.record(first.state, "intent_two",
		START + 30.0, START + 10.0)
	_expect(not regressed.ok and str(regressed.reason) == "invalid_cooldown",
		"冷却时刻倒退被拒绝")
	var empty_id: Dictionary = IntentState.record(empty, "", START, START)
	_expect(not empty_id.ok and str(empty_id.reason) == "invalid_intent",
		"空 id 被拒绝")
	var non_string_id: Dictionary = IntentState.record(empty, 5, START, START)
	_expect(not non_string_id.ok and str(non_string_id.reason) == "invalid_intent",
		"非字符串 id 被拒绝")
	var negative_time: Dictionary = IntentState.record(empty, "intent_two", -1.0, START)
	_expect(not negative_time.ok and str(negative_time.reason) == "invalid_time",
		"负消费时刻被拒绝")
	var bad_document: Dictionary = IntentState.record({}, "intent_two", START, START)
	_expect(not bad_document.ok and str(bad_document.reason) == "invalid_state",
		"非法文档不得记录")

	var second: Dictionary = IntentState.record(first.state, "intent_two",
		START + 30.0, START + 60.0)
	_expect(second.ok, "冷却结束后可记录下一次消费")
	_expect((second.state.intents as Dictionary).size() == 2,
		"多次消费累积在账本里")
	_expect(float(second.state.until_utc) == START + 60.0, "第二次消费推进冷却时刻")


func _test_bound_and_eviction() -> void:
	var state: Dictionary = IntentState.empty_state()
	var all_ok: bool = true
	for index: int in IntentState.MAX_RECORDS:
		var at_utc: float = START + float(index) * 10.0
		var result: Dictionary = IntentState.record(state, "intent_%04d" % index,
			at_utc, at_utc)
		all_ok = all_ok and bool(result.ok)
		if result.ok:
			state = result.state
	_expect(all_ok, "连续记录上限内每一笔都成功")
	_expect(IntentState.valid(state), "满额账本仍然合法")
	_expect((state.intents as Dictionary).size() == IntentState.MAX_RECORDS,
		"账本恰好停在上限")

	var newest_at: float = START + float(IntentState.MAX_RECORDS) * 10.0
	var overflow: Dictionary = IntentState.record(state, "intent_9999", newest_at, newest_at)
	_expect(overflow.ok, "满额后新记录仍被接受")
	_expect(IntentState.valid(overflow.state), "淘汰后的候选文档合法")
	_expect((overflow.state.intents as Dictionary).size() == IntentState.MAX_RECORDS,
		"满额淘汰后仍不超过上限")
	_expect(not (overflow.state.intents as Dictionary).has("intent_0000"),
		"消费时刻最旧的记录被淘汰")
	_expect((overflow.state.intents as Dictionary).has("intent_0001"),
		"只淘汰一条最旧记录")
	_expect((overflow.state.intents as Dictionary).has("intent_9999"),
		"新记录保留")
	_expect(float(overflow.state.until_utc) == newest_at, "新记录推进冷却时刻")

	# 同一时刻的记录按 id 升序淘汰，结果不依赖字典遍历顺序。
	var tied: Dictionary = IntentState.empty_state()
	for index: int in IntentState.MAX_RECORDS:
		tied = IntentState.record(tied, "intent_%04d" % index, START, START).state
	var tied_overflow: Dictionary = IntentState.record(tied, "intent_9999", START, START)
	_expect(tied_overflow.ok, "同一消费时刻的满额账本仍可记录")
	_expect(not (tied_overflow.state.intents as Dictionary).has("intent_0000"),
		"同一时刻按 id 升序淘汰最小 id")
	_expect((tied_overflow.state.intents as Dictionary).has("intent_9999"),
		"同一时刻的新记录保留")


func _test_read_only() -> void:
	var state: Dictionary = {"until_utc": START + 100.0, "intents": {"intent_a": START}}
	var before: String = JSON.stringify(state)
	_expect(IntentState.valid(state), "只读夹具文档合法")
	var recorded: Dictionary = IntentState.record(state, "intent_b",
		START + 100.0, START + 200.0)
	_expect(recorded.ok, "只读夹具上的记录成功")
	_expect(JSON.stringify(state) == before, "record 不修改输入文档")
	recorded.state.intents["intent_c"] = 1.0
	_expect(not (state.intents as Dictionary).has("intent_c"),
		"候选文档与输入深拷贝隔离")
	IntentState.cooling(state, START)
	_expect(JSON.stringify(state) == before, "cooling 不修改输入文档")


func _test_store_roundtrip() -> void:
	var store := IntentStore.new(root_dir.path_join("roundtrip"))
	var missing: Dictionary = store.load_state()
	_expect(missing.ok and str(missing.kind) == "missing", "缺失文件返回空账本")
	_expect(IntentState.valid(missing.state), "缺失文件的空账本合法")
	_expect(float(missing.state.until_utc) == 0.0
		and (missing.state.intents as Dictionary).is_empty(), "缺失文件不伪造历史")

	var state: Dictionary = {"until_utc": START + 60.0, "intents": {"intent_a": START}}
	var saved: Dictionary = store.save_state(state)
	_expect(saved.ok and str(saved.kind) == "saved", "合法账本原子保存成功")
	_expect(FileAccess.file_exists(root_dir.path_join("roundtrip").path_join(IntentStore.MAIN)),
		"主文档已写入")
	_expect(not FileAccess.file_exists(
		root_dir.path_join("roundtrip").path_join(IntentStore.PENDING)),
		"成功后不残留 pending 文件")

	var reopened := IntentStore.new(root_dir.path_join("roundtrip"))
	var loaded: Dictionary = reopened.load_state()
	_expect(loaded.ok and str(loaded.kind) == "loaded", "重新打开后加载成功")
	_expect(loaded.state == state, "保存后重开得到同一文档")
	_expect(typeof(loaded.state.until_utc) == TYPE_FLOAT, "加载后冷却时刻归一为 float")

	var replaced: Dictionary = reopened.save_state({"until_utc": START + 90.0, "intents": {}})
	_expect(replaced.ok, "已有主文档可被新文档原子替换")
	_expect(float(reopened.load_state().state.until_utc) == START + 90.0,
		"替换后的文档再次加载一致")

	var invalid_dir: String = root_dir.path_join("invalid-save")
	var invalid_store := IntentStore.new(invalid_dir)
	var refused: Dictionary = invalid_store.save_state({"until_utc": -1.0, "intents": {}})
	_expect(not refused.ok and str(refused.kind) == "invalid_state",
		"非法文档在落盘前被拒绝")
	_expect(not FileAccess.file_exists(invalid_dir.path_join(IntentStore.MAIN)),
		"被拒绝的文档不产生主文件")


func _test_store_corruption() -> void:
	var corrupt_dir: String = root_dir.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	var corrupt_path: String = corrupt_dir.path_join(IntentStore.MAIN)
	_write(corrupt_path, "{not json")
	var before: String = FileAccess.get_file_as_string(corrupt_path)
	var corrupt: Dictionary = IntentStore.new(corrupt_dir).load_state()
	_expect(not corrupt.ok and str(corrupt.kind) == "corrupt", "损坏 JSON 具名拒绝")
	_expect(FileAccess.get_file_as_string(corrupt_path) == before,
		"损坏文档不会被空账本覆盖")

	var old_dir: String = root_dir.path_join("unsupported")
	DirAccess.make_dir_recursive_absolute(old_dir)
	_write(old_dir.path_join(IntentStore.MAIN),
		JSON.stringify({"version": IntentStore.VERSION + 1, "state": IntentState.empty_state()}))
	var unsupported: Dictionary = IntentStore.new(old_dir).load_state()
	_expect(not unsupported.ok and str(unsupported.kind) == "unsupported",
		"不支持的版本具名拒绝")

	var missing_version_dir: String = root_dir.path_join("missing-version")
	DirAccess.make_dir_recursive_absolute(missing_version_dir)
	_write(missing_version_dir.path_join(IntentStore.MAIN),
		JSON.stringify({"state": IntentState.empty_state()}))
	_expect(str(IntentStore.new(missing_version_dir).load_state().kind) == "unsupported",
		"缺少版本号按不支持版本拒绝")

	var shape_dir: String = root_dir.path_join("bad-shape")
	DirAccess.make_dir_recursive_absolute(shape_dir)
	_write(shape_dir.path_join(IntentStore.MAIN),
		JSON.stringify({"version": IntentStore.VERSION,
			"state": {"until_utc": -1.0, "intents": {}}}))
	_expect(str(IntentStore.new(shape_dir).load_state().kind) == "corrupt",
		"版本正确但状态非法按损坏拒绝")

	var array_dir: String = root_dir.path_join("array-state")
	DirAccess.make_dir_recursive_absolute(array_dir)
	_write(array_dir.path_join(IntentStore.MAIN),
		JSON.stringify({"version": IntentStore.VERSION, "state": []}))
	_expect(str(IntentStore.new(array_dir).load_state().kind) == "corrupt",
		"状态不是字典按损坏拒绝")

	var blank_dir: String = root_dir.path_join("blank")
	DirAccess.make_dir_recursive_absolute(blank_dir)
	_write(blank_dir.path_join(IntentStore.MAIN), "")
	_expect(str(IntentStore.new(blank_dir).load_state().kind) == "corrupt",
		"空文件按损坏拒绝")

	var huge_dir: String = root_dir.path_join("huge")
	DirAccess.make_dir_recursive_absolute(huge_dir)
	_write(huge_dir.path_join(IntentStore.MAIN), "x".repeat(IntentStore.MAX_BYTES + 1))
	_expect(str(IntentStore.new(huge_dir).load_state().kind) == "corrupt",
		"超过字节上限的文件按损坏拒绝")


func _test_store_atomic_failure() -> void:
	var atomic_dir: String = root_dir.path_join("atomic")
	DirAccess.make_dir_recursive_absolute(atomic_dir)
	var store := IntentStore.new(atomic_dir)
	var pending_path: String = atomic_dir.path_join(IntentStore.PENDING)
	# 用同名目录占住 pending 路径，让 FileAccess 无法创建文件，稳定进入 io 分支。
	var occupied: Error = DirAccess.make_dir_recursive_absolute(pending_path)
	_expect(occupied == OK, "测试成功占住 pending 路径")
	var state: Dictionary = {"until_utc": START, "intents": {"intent_a": START}}
	var failed: Dictionary = store.save_state(state)
	_expect(not failed.ok and str(failed.kind) == "io", "pending 写入失败具名拒绝")
	_expect(not FileAccess.file_exists(atomic_dir.path_join(IntentStore.MAIN)),
		"pending 失败不产生主文档")

	DirAccess.remove_absolute(pending_path)
	var retried: Dictionary = store.save_state(state)
	_expect(retried.ok and str(retried.kind) == "saved", "恢复后重试保存成功")
	_expect(FileAccess.file_exists(atomic_dir.path_join(IntentStore.MAIN)), "重试写入主文档")
	_expect(not FileAccess.file_exists(pending_path), "重试后不残留 pending 文件")
	var reloaded: Dictionary = store.load_state()
	_expect(reloaded.ok and reloaded.state == state, "重试写入的文档可重新加载")


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
