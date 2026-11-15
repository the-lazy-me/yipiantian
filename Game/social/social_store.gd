extends RefCounted
## Versioned storage for the social document. The authoritative world is the only
## writer: a save goes to a pending file, is read back and compared, and only
## then replaces the main document, so a crash cannot leave a social record that
## was never fully written.

const SocialState = preload("res://social/social_state.gd")

const VERSION: int = SocialState.VERSION
## The cap must cover any document `SocialState.valid()` accepts, not only the
## common case, otherwise a legal record can be built in memory and then fail to
## save. The limiting legal shape is constructed in `social_state_test.gd`
## (64 players × 63 blocks, 128 grants × 32 fields, 256 messages × all viewer
## marks) and measures 4,803,771 UTF-8 bytes. 8 MiB leaves headroom while the
## fixture fails if a future rule makes the worst case larger.
const MAX_BYTES: int = 8 * 1024 * 1024
const MAIN: String = "social.json"
const PENDING: String = "social.pending.json"
# The previous committed document. A save keeps it so a damaged main can be
# restored explicitly; loading never rolls back on its own.
const BACKUP: String = "social.backup.json"

var directory: String
var _filesystem: DirAccess


func _init(save_directory: String) -> void:
	directory = ProjectSettings.globalize_path(save_directory).simplify_path()
	var root: String = directory
	while root != root.get_base_dir():
		root = root.get_base_dir()
	_filesystem = DirAccess.open(root)


func load_state() -> Dictionary:
	if not _safe_paths():
		return _failure("unsafe_path")
	var main_path: String = _path(MAIN)
	var main_exists: bool = FileAccess.file_exists(main_path)
	if main_exists:
		var main: Dictionary = _read(main_path)
		if main.ok:
			var decoded: Dictionary = _decode(main.document)
			if decoded.ok:
				return decoded
			if decoded.kind == "unsupported":
				return decoded
		elif main.kind == "io":
			return _failure("io")
	var backup_path: String = _path(BACKUP)
	var backup_exists: bool = FileAccess.file_exists(backup_path)
	if backup_exists:
		var backup: Dictionary = _read(backup_path)
		if backup.ok:
			var decoded: Dictionary = _decode(backup.document)
			if decoded.ok:
				return {"ok": false, "kind": "recovery_available", "source": BACKUP}
			if decoded.kind == "unsupported":
				return decoded
		elif backup.kind == "io":
			return _failure("io")
	if not main_exists and not backup_exists:
		return {"ok": true, "kind": "missing", "state": SocialState.initial_state()}
	return _failure("corrupt")


## Saves only a document that passes the same validation a load performs, so a
## caller cannot write a record the next load will refuse.
func save_state(state: Dictionary) -> Dictionary:
	if not SocialState.valid(state):
		return _failure("invalid_state")
	if not _safe_paths():
		return _failure("unsafe_path")
	var create_error: Error = OK if _filesystem.dir_exists(directory) \
		else _filesystem.make_dir_recursive(directory)
	if create_error != OK:
		return _failure("create_directory", create_error)
	var text: String = JSON.stringify({"version": VERSION, "state": SocialState.canonical(state)}, "\t")
	if text.to_utf8_buffer().size() > MAX_BYTES:
		return _failure("too_large")
	var staged: Dictionary = _write_verified(_path(PENDING), text)
	if not staged.ok:
		return staged
	# Keep the previous committed document for explicit recovery. Only a
	# decodable main is copied: a damaged or newer file must never overwrite a
	# good backup, so the copy is verified before the main replacement.
	var main_path: String = _path(MAIN)
	var previous: Dictionary = _read(main_path) if FileAccess.file_exists(main_path) else {"kind": "missing"}
	if bool(previous.get("ok", false)) and _decode(previous.document).ok:
		var backup_path: String = _path(BACKUP)
		var copy_error: Error = DirAccess.copy_absolute(main_path, backup_path)
		if copy_error != OK \
				or FileAccess.get_sha256(main_path) != FileAccess.get_sha256(backup_path):
			return _failure("backup", copy_error)
	var replace_error: Error = _filesystem.rename(_path(PENDING), main_path)
	if replace_error != OK:
		return _failure("replace_main", replace_error)
	return {"ok": true, "kind": "saved"}


## Explicit recovery from the previous committed document. The damaged main is
## preserved for diagnosis; a load or save never performs this automatically.
func recover() -> Dictionary:
	if not _safe_paths():
		return _failure("unsafe_path")
	var state: Dictionary = load_state()
	if state.kind != "recovery_available":
		return state if not state.ok else _failure("no_recovery")
	var source: Dictionary = _read(_path(str(state.source)))
	if not source.ok:
		return _failure("recovery_changed")
	var decoded: Dictionary = _decode(source.document)
	if not decoded.ok:
		return _failure("recovery_changed")
	var main_path: String = _path(MAIN)
	if FileAccess.file_exists(main_path):
		var archive: String = "social.unreadable.%d.%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
		if FileAccess.file_exists(_path(archive)):
			return _failure("preserve_original")
		var copy_error: Error = DirAccess.copy_absolute(main_path, _path(archive))
		if copy_error != OK \
				or FileAccess.get_sha256(main_path) != FileAccess.get_sha256(_path(archive)):
			return _failure("preserve_original", copy_error)
	var staged: Dictionary = _write_verified(_path(PENDING), source.text)
	if not staged.ok:
		return staged
	var replace_error: Error = DirAccess.rename_absolute(_path(PENDING), main_path)
	if replace_error != OK:
		return _failure("recover_replace", replace_error)
	return {"ok": true, "kind": "recovered", "state": decoded.state}


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
	return {"ok": true, "kind": "read", "document": json.data, "text": text}


func _decode(document: Dictionary) -> Dictionary:
	if int(document.get("version", -1)) != VERSION:
		return _failure("unsupported")
	var state: Variant = document.get("state")
	if not state is Dictionary or not SocialState.valid(state):
		return _failure("corrupt")
	return {"ok": true, "kind": "loaded", "state": SocialState.canonical(state)}


func _safe_paths() -> bool:
	# An absolute path below a real parent; a missing directory is legal because
	# save_state creates it. No ancestor or sidecar may be a symbolic link: the
	# pending write and the backup copy must never follow one to another file.
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
	for filename: String in [MAIN, PENDING, BACKUP]:
		if _filesystem.is_link(_path(filename)):
			return false
	return true


func _path(filename: String) -> String:
	return directory.path_join(filename)


static func _failure(kind: String, error: Error = OK) -> Dictionary:
	var result: Dictionary = {"ok": false, "kind": kind}
	if error != OK:
		result["error"] = error
	return result
