extends RefCounted
## Versioned storage for the world's player bindings. The document is a sidecar
## like the cadastre: the farm schema has an exact key contract, while player
## credentials are a world-level fact with their own lifecycle.
##
## The authoritative world is the only writer. A save goes to a pending file, is
## read back and compared, and only then replaces the main document. A document
## that exists but cannot be validated stops the authority instead of being
## replaced by an empty registry, which would silently unlock every identity.

const PlayerBindingState = preload("res://world/player_binding_state.gd")

const VERSION: int = 1
const MAX_BYTES: int = 65536
const MAIN: String = "player_bindings.json"
const PENDING: String = "player_bindings.pending.json"

var directory: String
var _filesystem: DirAccess


func _init(save_directory: String) -> void:
	directory = ProjectSettings.globalize_path(save_directory).simplify_path()
	var root: String = directory
	while root != root.get_base_dir():
		root = root.get_base_dir()
	_filesystem = DirAccess.open(root)


## Returns {ok, kind, state}. A missing document is a world where no identity
## has been bound yet; the empty registry is deterministic and need not be
## written until the first named player joins.
func load_state() -> Dictionary:
	if not _safe_paths():
		return _failure("unsafe_path")
	var path: String = _path(MAIN)
	if not FileAccess.file_exists(path):
		return {"ok": true, "kind": "missing", "state": PlayerBindingState.empty_state()}
	var read: Dictionary = _read(path)
	if not read.ok:
		return read
	if int(read.document.get("version", -1)) != VERSION:
		return _failure("unsupported")
	var state: Variant = read.document.get("state")
	if not PlayerBindingState.valid(state):
		return _failure("corrupt")
	var document: Dictionary = state
	PlayerBindingState.normalize(document)
	return {"ok": true, "kind": "loaded", "state": document}


## Saves only a document that passes the same validation a load performs, so a
## caller cannot write bindings the next load will refuse.
func save_state(state: Dictionary) -> Dictionary:
	if not PlayerBindingState.valid(state):
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
