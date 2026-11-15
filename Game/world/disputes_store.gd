extends RefCounted
## Versioned storage for the world's dispute document (M12-04). Cases, evidence,
## rulings and their audit trail are world-level facts with their own lifecycle,
## so they live beside the farm save instead of inside the exact-key-count v27
## farm document.
##
## The authoritative world is the only writer. A save goes to a pending file, is
## read back and compared, and only then replaces the main document, so a crash
## cannot leave a half-written case table. A document that exists but cannot be
## validated stops the authority instead of being replaced by a fresh roster:
## an administrator list and an audit trail are durable room facts, not defaults.
##
## The envelope also carries the world identity. DisputeState itself has no
## world field, so without this the store could not refuse a case table copied
## from another world the way the other world-level sidecars do.

const Disputes = preload("res://world/dispute_state.gd")

const VERSION: int = 1
const MAX_BYTES: int = 65536
## 与 HeadlessWorld 的重放窗口一致。日志只保存最近的成功命令，让重启后的同一
## command id 仍能返回首次结果；它不进入 `state`，案件文档继续保持严格形状。
const MAX_COMMANDS: int = 64
const MAIN: String = "disputes.json"
const PENDING: String = "disputes.pending.json"
const COMMAND_KEYS: Array[String] = ["command_id", "payload", "result"]
const RESULT_KEYS: Array[String] = [
	"ok", "reason", "action", "case_id", "duplicate", "status",
]

var directory: String
## The world this store belongs to, fixed by the last successful load and written
## into every save.
var world_id: String = ""
var _filesystem: DirAccess


func _init(save_directory: String) -> void:
	directory = ProjectSettings.globalize_path(save_directory).simplify_path()
	var root: String = directory
	while root != root.get_base_dir():
		root = root.get_base_dir()
	_filesystem = DirAccess.open(root)


## Returns {ok, kind, state}. A missing document is only legal when the room has
## no host player: an empty roster cannot authorize anyone, so the authority
## reports `hostless` and refuses dispute writes instead of inventing an
## administrator. A hosted room starts with the host as its only authority.
##
## The dispute rules keep one player out of both roles, so the host is written to
## `admin` only; `is_authority()` accepts either list, and an explicit
## `authority_roles` in an existing document is respected as-is.
func load_state(world_identity: String, host: String) -> Dictionary:
	if not _safe_paths():
		return _failure("unsafe_path")
	var path: String = _path(MAIN)
	if not FileAccess.file_exists(path):
		if host.is_empty():
			return {"ok": true, "kind": "hostless", "state": {}, "commands": []}
		var fresh: Dictionary = Disputes.empty([host], [])
		if not Disputes.valid(fresh):
			return _failure("invalid_host")
		world_id = world_identity
		return {"ok": true, "kind": "missing", "state": fresh, "commands": []}
	var read: Dictionary = _read(path)
	if not read.ok:
		return read
	if int(read.document.get("version", -1)) != VERSION:
		return _failure("unsupported")
	if str(read.document.get("world_id", "")) != world_identity:
		return _failure("world_mismatch")
	var state: Variant = read.document.get("state")
	if not state is Dictionary or not Disputes.valid(state):
		return _failure("corrupt")
	# A document written before the replay journal existed simply has none.
	var commands: Variant = read.document.get("commands", [])
	if not _valid_commands(commands):
		return _failure("corrupt")
	world_id = world_identity
	return {"ok": true, "kind": "loaded", "state": state, "commands": commands}


## Saves only a document that passes the same validation a load performs, so a
## caller cannot write a case table the next load will refuse. The bounded
## command journal is written in the same atomic replace as the state, so a
## replay can never outlive the state it first returned.
func save_state(state: Dictionary, commands: Array = []) -> Dictionary:
	if not Disputes.valid(state):
		return _failure("invalid_state")
	if not _valid_commands(commands):
		return _failure("invalid_commands")
	if not _safe_paths():
		return _failure("unsafe_path")
	var create_error: Error = OK if _filesystem.dir_exists(directory) \
		else _filesystem.make_dir_recursive(directory)
	if create_error != OK:
		return _failure("create_directory", create_error)
	var text: String = JSON.stringify({
		"version": VERSION, "world_id": world_id, "state": state,
		"commands": commands,
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


## The journal is storage, not rules: it must have the exact shape the loader
## will read back, but its result is replayed, never applied. A malformed entry
## is corruption, not a reason to silently drop a durable replay window.
static func _valid_commands(value: Variant) -> bool:
	if not value is Array or (value as Array).size() > MAX_COMMANDS:
		return false
	var seen: Dictionary = {}
	for row_value: Variant in value:
		if not row_value is Dictionary \
				or (row_value as Dictionary).size() != COMMAND_KEYS.size():
			return false
		for key: String in COMMAND_KEYS:
			if not (row_value as Dictionary).has(key):
				return false
		var command_id: Variant = (row_value as Dictionary).get("command_id")
		if not command_id is String or str(command_id).is_empty() \
				or str(command_id).length() > 128:
			return false
		if not (row_value as Dictionary).get("payload") is String:
			return false
		var result_value: Variant = (row_value as Dictionary).get("result")
		if not result_value is Dictionary \
				or (result_value as Dictionary).size() != RESULT_KEYS.size():
			return false
		for key: String in RESULT_KEYS:
			if not (result_value as Dictionary).has(key):
				return false
		if not (result_value as Dictionary).get("ok") is bool \
				or not (result_value as Dictionary).get("duplicate") is bool:
			return false
		for key: String in ["reason", "action", "case_id", "status"]:
			if not (result_value as Dictionary).get(key) is String:
				return false
		if seen.has(str(command_id)):
			return false
		seen[str(command_id)] = true
	return true


func _safe_paths() -> bool:
	# An absolute path below a real parent; a missing directory is legal because
	# save_state creates it. This mirrors the other sidecar document stores.
	return directory.is_absolute_path() and directory.get_base_dir() != directory


func _path(filename: String) -> String:
	return directory.path_join(filename)


static func _failure(kind: String, error: Error = OK) -> Dictionary:
	var result: Dictionary = {"ok": false, "kind": kind}
	if error != OK:
		result["error"] = error
	return result
