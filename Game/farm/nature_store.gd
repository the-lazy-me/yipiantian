extends RefCounted
## Versioned storage for the deterministic nature document. Kept beside the farm
## and social documents instead of inside the farm schema: the farm document has
## an exact key-count contract shared with the v27 importer, while the natural
## seed and the world-level disaster mode are one small immutable fact. The seed
## is written once by the authority; events themselves are derived, not stored.
## The disaster mode defaults to "gentle" when absent, so pre-switch documents
## keep their exact shape and meaning.

const NatureState = preload("res://farm/nature_state.gd")

const VERSION: int = NatureState.RULES_VERSION
# The only older document accepted: M6-01/M6-02 wrote envelope and state
# version 1. It loads with the unchanged weather hash and is rewritten as the
# current version on the next save. Any other older version is refused.
const LEGACY_VERSION: int = NatureState.LEGACY_RULES_VERSION
const MAX_BYTES: int = 4096
const MAIN: String = "nature.json"
const PENDING: String = "nature.pending.json"

var directory: String
var _filesystem: DirAccess


func _init(save_directory: String) -> void:
	directory = ProjectSettings.globalize_path(save_directory).simplify_path()
	var root: String = directory
	while root != root.get_base_dir():
		root = root.get_base_dir()
	_filesystem = DirAccess.open(root)


## Returns {ok, kind, state} where kind is "missing" for a save that predates
## the nature document. A missing document is not a fresh random roll: the
## caller gets the fixed default snapshot and may persist it on the next save.
func load_state() -> Dictionary:
	if not _safe_paths():
		return _failure("unsafe_path")
	var path: String = _path(MAIN)
	if not FileAccess.file_exists(path):
		return {"ok": true, "kind": "missing", "state": NatureState.default_snapshot()}
	var read: Dictionary = _read(path)
	if not read.ok:
		return read
	var version: int = int(read.document.get("version", -1))
	if version != VERSION and version != LEGACY_VERSION:
		return _failure("unsupported")
	var state: Variant = read.document.get("state")
	var nature := NatureState.new()
	if not state is Dictionary or not nature.restore_snapshot(state):
		return _failure("corrupt")
	return {"ok": true, "kind": "loaded", "state": nature.snapshot()}


## Saves only a document that passes the same validation as a load.
func save_state(state: Dictionary) -> Dictionary:
	var nature := NatureState.new()
	if not nature.restore_snapshot(state):
		return _failure("invalid_state")
	if not _safe_paths():
		return _failure("unsafe_path")
	var create_error: Error = OK if _filesystem.dir_exists(directory) \
		else _filesystem.make_dir_recursive(directory)
	if create_error != OK:
		return _failure("create_directory", create_error)
	var text: String = JSON.stringify({"version": VERSION, "state": nature.snapshot()}, "\t")
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
