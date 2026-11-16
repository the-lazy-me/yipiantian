extends RefCounted
## M12-03 世界权威交战结算的持久化边界。交战上下文本身是纯规则文档
## （`Game/world/conflict_settlement.gd`），形状必须保持严格；存储层自己的
## 恢复标记放在信封的 `applied` 里，绝不写进 `state`：
##
##   {"version": 1, "state": <ConflictSettlement 上下文>, "applied": {...}}
##
## `applied[command_id]` 记录一次已持久化交战的提交进度。`applied=true` 表示
## 农场、单位与参与文档都已完成；`applied=false` 表示只写了意图（冲突上下文），
## 重试必须按持久化标记与真实资产状态补齐，不能再次扣款或发战利品。
## `farm_applied`（可选）表示农场部分已经耐久落盘，恢复不再依赖环形账本里的
## 付款分录。`voided` 是已作废的意图编号：数据偏离到无法补齐时删除意图，同时
## 把编号记在这里，避免同一编号被当成新交战再次结算。
##
## 与其它 world sidecar 相同：权威是唯一写入者，先写 pending、回读比较，再
## rename 覆盖主文档。缺失文档是合法空上下文（`participation` 由调用方在交战
## 前用实时参与文档覆盖，因此空文档本身还不能通过 `valid_context()`）；存在但
## 损坏、版本不支持或属于另一个世界时停止启动，而不是静默覆盖。

const Settlement = preload("res://world/conflict_settlement.gd")

const VERSION: int = 1
## 作废编号只用于拒绝同一命令的再次结算，不需要无限增长；64 条与参与命令的
## 重放窗口同量级。
const MAX_VOIDED: int = 64
## 上下文可容纳 1024 条 consumed；单条 payload 上限 8 KiB，1 MiB 给 envelope、
## applied 进度和格式化后的 JSON 留出空间，同时仍能拒绝明显异常的大文档。
const MAX_BYTES: int = 1048576
const MAIN: String = "conflicts.json"
const PENDING: String = "conflicts.pending.json"

var directory: String
var _filesystem: DirAccess


func _init(save_directory: String) -> void:
	directory = ProjectSettings.globalize_path(save_directory).simplify_path()
	var root: String = directory
	while root != root.get_base_dir():
		root = root.get_base_dir()
	_filesystem = DirAccess.open(root)


## 返回 {ok, kind, state, applied}。缺失文档返回 world_id 已知的空上下文；
## `participation` 为空，调用方在交战前用实时参与制度覆盖它。
func load_state(world_id: String) -> Dictionary:
	if not _safe_paths():
		return _failure("unsafe_path")
	var path: String = _path(MAIN)
	if not FileAccess.file_exists(path):
		return {
			"ok": true, "kind": "missing",
			"state": initial_state(world_id), "applied": {}, "voided": [],
		}
	var read: Dictionary = _read(path)
	if not read.ok:
		return read
	if int(read.document.get("version", -1)) != VERSION:
		return _failure("unsupported")
	var state: Variant = read.document.get("state")
	if not state is Dictionary or not Settlement.valid_context(state):
		return _failure("corrupt")
	if str(state["world_id"]) != world_id:
		return _failure("world_mismatch")
	var applied: Variant = read.document.get("applied", {})
	if not _valid_applied(applied, state["consumed"]):
		return _failure("corrupt")
	var voided: Variant = read.document.get("voided", [])
	if not _valid_voided(voided):
		return _failure("corrupt")
	return {
		"ok": true, "kind": "loaded",
		"state": state, "applied": (applied as Dictionary).duplicate(true),
		"voided": (voided as Array).duplicate(),
	}


## 只保存能通过同一份严格校验的上下文与恢复标记。调用方必须先把本次命令写进
## `state.consumed`，因此每个 applied 键都应对应一条已持久化的交战。
func save_state(state: Dictionary, applied: Dictionary,
		voided: Array = []) -> Dictionary:
	if not Settlement.valid_context(state):
		return _failure("invalid_state")
	if not _valid_applied(applied, state.get("consumed", {})):
		return _failure("invalid_applied")
	if not _valid_voided(voided):
		return _failure("invalid_voided")
	if not _safe_paths():
		return _failure("unsafe_path")
	var create_error: Error = OK if _filesystem.dir_exists(directory) \
		else _filesystem.make_dir_recursive(directory)
	if create_error != OK:
		return _failure("create_directory", create_error)
	var text: String = JSON.stringify({
		"version": VERSION, "state": state, "applied": applied, "voided": voided,
	}, "\t")
	if text.to_utf8_buffer().size() > MAX_BYTES:
		return _failure("too_large")
	var staged: Dictionary = _write_verified(_path(PENDING), text)
	if not staged.ok:
		return staged
	var replace_error: Error = _filesystem.rename(_path(PENDING), _path(MAIN))
	if replace_error != OK:
		return _failure("replace_main", replace_error)
	return {"ok": true, "kind": "saved"}


## 空上下文。`participation` 故意留空：它不是一份合法参与制度文档，调用方必须
## 在交战前覆盖成权威实时文档，`save_state()` 才会接受它。
static func initial_state(world_id: String) -> Dictionary:
	return {
		"world_id": world_id,
		"sequence": 0,
		"resources": {},
		"targets": {},
		"participation": {},
		"consumed": {},
	}


static func _valid_applied(value: Variant, consumed: Variant) -> bool:
	if not value is Dictionary or not consumed is Dictionary:
		return false
	var applied: Dictionary = value
	var entries: Dictionary = consumed
	for command_id: Variant in applied:
		if not command_id is String or not entries.has(str(command_id)):
			return false
		var entry: Variant = applied[command_id]
		if not entry is Dictionary:
			return false
		if not entry.get("applied") is bool:
			return false
		if not entry.get("signature") is String:
			return false
		# 农场提交标记只在写入方确认农场已落盘后出现；缺失按未提交处理，
		# 这样旧文档无需迁移。
		if entry.has("farm_applied") and not entry["farm_applied"] is bool:
			return false
	return true


static func _valid_voided(value: Variant) -> bool:
	if not value is Array or (value as Array).size() > MAX_VOIDED:
		return false
	var seen: Dictionary = {}
	for command_id: Variant in value:
		if not command_id is String:
			return false
		var text: String = str(command_id)
		if text.is_empty() or text.length() > Settlement.MAX_COMMAND_ID_LENGTH \
				or seen.has(text):
			return false
		seen[text] = true
	return true


func _write_verified(path: String, text: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _failure("io")
	file.store_string(text)
	file.flush()
	var error: Error = file.get_error()
	file.close()
	if error != OK:
		return _failure("io", error)
	if FileAccess.get_file_as_string(path) != text:
		return _failure("verify")
	return {"ok": true, "kind": "written"}


func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("io")
	var length: int = file.get_length()
	if length <= 0 or length > MAX_BYTES:
		file.close()
		return _failure("corrupt")
	var text: String = file.get_as_text()
	var read_error: Error = file.get_error()
	file.close()
	if read_error != OK and read_error != ERR_FILE_EOF:
		return _failure("io")
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return _failure("corrupt")
	return {"ok": true, "kind": "read", "document": json.data}


func _safe_paths() -> bool:
	# An absolute path below a real parent; a missing directory is legal because
	# save_state creates it. No ancestor or sidecar may be a symbolic link: the
	# pending write must never follow one to another file.
	if not directory.is_absolute_path() or directory.get_base_dir() == directory \
			or _filesystem == null:
		return false
	var cursor: String = directory
	while cursor != cursor.get_base_dir():
		if _filesystem.is_link(cursor):
			return false
		cursor = cursor.get_base_dir()
	if not _filesystem.dir_exists(directory):
		return not FileAccess.file_exists(directory)
	return not _filesystem.is_link(_path(MAIN)) \
		and not _filesystem.is_link(_path(PENDING))


func _path(filename: String) -> String:
	return directory.path_join(filename)


static func _failure(kind: String, error: Error = OK) -> Dictionary:
	var result: Dictionary = {"ok": false, "kind": kind}
	if error != OK:
		result["error"] = error
	return result
