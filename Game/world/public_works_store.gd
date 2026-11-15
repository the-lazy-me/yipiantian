extends RefCounted
## Versioned storage for the world's public works document. Projects live in
## their own sidecar instead of the v27 farm document: the farm schema has an
## exact key-count contract shared with the importer, while projects, pledges
## and build state are world-level facts with their own lifecycle (M8-04a).
##
## The authoritative world is the only writer. A save goes to a pending file, is
## read back and compared, and only then replaces the main document, so a crash
## cannot leave a project table that was never fully written. A document that
## exists but cannot be validated stops the authority instead of being replaced
## by an empty table.

const PublicWorks = preload("res://world/public_works.gd")

const VERSION: int = 1
const MAX_BYTES: int = 65536
const MAIN: String = "public_works.json"
const PENDING: String = "public_works.pending.json"

var directory: String
var _filesystem: DirAccess


func _init(save_directory: String) -> void:
	directory = ProjectSettings.globalize_path(save_directory).simplify_path()
	var root: String = directory
	while root != root.get_base_dir():
		root = root.get_base_dir()
	_filesystem = DirAccess.open(root)


## Returns {ok, kind, state}. A missing document is a legal empty project table,
## not a failure: a world that has never opened a project simply has none.
func load_state() -> Dictionary:
	if not _safe_paths():
		return _failure("unsafe_path")
	var path: String = _path(MAIN)
	if not FileAccess.file_exists(path):
		var fresh: Dictionary = PublicWorks.empty()
		if not PublicWorks.valid(fresh):
			return _failure("invalid_state")
		return {"ok": true, "kind": "missing", "state": fresh}
	var read: Dictionary = _read(path)
	if not read.ok:
		return read
	if int(read.document.get("version", -1)) != VERSION:
		return _failure("unsupported")
	var state: Variant = read.document.get("state")
	if not state is Dictionary or not PublicWorks.valid(state):
		return _failure("corrupt")
	return {"ok": true, "kind": "loaded", "state": state}


## Saves only a document that passes the same validation a load performs, so a
## caller cannot write a project table the next load will refuse.
func save_state(state: Dictionary) -> Dictionary:
	if not PublicWorks.valid(state):
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
