extends RefCounted
## M10-03 意图执行账本的 sidecar 持久化。账本与农场存档分开：农场 v27 有精确
## 的键集契约，而“居民消费了哪些意图、何时再行动”是世界级状态，有自己的生命
## 周期。本模块不修改农场存档格式。
##
## 当前权威写入的是多居民账本 `npc_resident_ledger_store.gd`（`npc_residents.json`）。
## 本模块只剩读取路径：`world_package.gd` 的 `npc_intents.json` 白名单与
## `world_transfer.gd` 的导入回读，用于搬运与校验最早按单居民格式写下的世界包。
## 新增的意图持久化不要再指向这里，除非明确要兼容那份旧形状。
##
## 权威端是唯一写入者。保存先写 pending 文件，读回比对通过后才替换主文档，
## 因此崩溃不会留下写了一半的账本。已存在但无法校验的文档会向上报告失败，
## 而不是被空账本覆盖——否则重启会悄悄忘掉所有已消费意图。
##
## 与 `world/territory_store.gd` 保持一致的拒绝语义：`unsafe_path`、
## `unsupported`、`corrupt`、`invalid_state`、`create_directory`、`io`、
## `verify`、`too_large`、`replace_main`。

const IntentState = preload("res://npc/npc_intent_state.gd")

const VERSION: int = 1
const MAX_BYTES: int = 65536
const MAIN: String = "npc_intents.json"
const PENDING: String = "npc_intents.pending.json"

var directory: String
var _filesystem: DirAccess


func _init(save_directory: String) -> void:
	directory = ProjectSettings.globalize_path(save_directory).simplify_path()
	var root: String = directory
	while root != root.get_base_dir():
		root = root.get_base_dir()
	_filesystem = DirAccess.open(root)


## 返回 {ok, kind, state}。缺失文件不是损坏：首次运行得到一个合法的空账本，
## 调用方可以在第一次成功消费时再落盘。
func load_state() -> Dictionary:
	if not _safe_paths():
		return _failure("unsafe_path")
	var path: String = _path(MAIN)
	if not FileAccess.file_exists(path):
		var fresh: Dictionary = IntentState.empty_state()
		if not IntentState.valid(fresh):
			return _failure("corrupt")
		return {"ok": true, "kind": "missing", "state": fresh}
	var read: Dictionary = _read(path)
	if not read.ok:
		return read
	if int(read.document.get("version", -1)) != VERSION:
		return _failure("unsupported")
	var state: Variant = read.document.get("state")
	if not IntentState.valid(state):
		return _failure("corrupt")
	var document: Dictionary = state
	IntentState.normalize(document)
	return {"ok": true, "kind": "loaded", "state": document}


## 只保存与加载同标准校验通过的文档，调用方无法写入下一次加载会拒绝的账本。
func save_state(state: Dictionary) -> Dictionary:
	if not IntentState.valid(state):
		return _failure("invalid_state")
	if not _safe_paths():
		return _failure("unsafe_path")
	var create_error: Error = OK if _filesystem.dir_exists(directory) \
		else _filesystem.make_dir_recursive(directory)
	if create_error != OK:
		return _failure("create_directory", create_error)
	var text: String = JSON.stringify({"version": VERSION, "state": state}, "\t")
	if text.to_utf8_buffer().size() > MAX_BYTES:
		return _failure("too_large")
	var staged: Dictionary = _write_verified(_path(PENDING), text)
	if not staged.ok:
		return staged
	var replace_error: Error = _filesystem.rename(_path(PENDING), _path(MAIN))
	if replace_error != OK:
		return _failure("replace_main", replace_error)
	return {"ok": true, "kind": "saved"}


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
	# 真实父目录下的绝对路径；目录缺失是合法的，save_state 会创建它。
	# 上级目录和两个文档名都不能是符号链接：暂存写入不能顺着链接写到别处。
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
