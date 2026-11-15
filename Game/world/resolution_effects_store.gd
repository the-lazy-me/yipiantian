extends RefCounted
## Versioned storage for the world's resolution-effect document (M11-03).
##
## The effect document is derived from the resolution table, but it still has to
## be durable: the application watermark is what makes a restart idempotent and
## what stops a revoked rule from being applied a second time. It therefore lives
## in its own sidecar beside `resolutions.json`, with the same storage rules as
## the other world-level documents.
##
## Envelope:
##
##   {
##     "version": 1,
##     "world_id": "<world id>",
##     "state": { "applied_version": 0, "applied": [] },
##   }
##
## The authoritative world is the only writer. A save goes to a pending file, is
## read back and compared, and only then replaces the main document, so a crash
## cannot leave a half-written effect document. A document that exists but cannot
## be read, belongs to another world, has an unsupported version, exceeds the
## byte budget, or fails `ResolutionEffects.valid()` stops the authority instead
## of being replaced by an empty document.
##
## A missing document is a legal empty effect document for the given world, and a
## load never writes one. A world whose resolutions never produced an effect
## leaves no `resolution_effects.json` behind.

const ResolutionEffects = preload("res://world/resolution_effects.gd")

const VERSION: int = 1
const MAX_BYTES: int = 65536
const MAX_WORLD_ID_LENGTH: int = 128
const MAIN: String = "resolution_effects.json"
const PENDING: String = "resolution_effects.pending.json"
const ENVELOPE_KEYS: Array[String] = ["version", "world_id", "state"]

var directory: String
## The world this store belongs to, fixed by the last successful load and
## written into every save.
var world_id: String = ""
var _filesystem: DirAccess


func _init(save_directory: String) -> void:
	directory = ProjectSettings.globalize_path(save_directory).simplify_path()
	var root: String = directory
	while root != root.get_base_dir():
		root = root.get_base_dir()
	_filesystem = DirAccess.open(root)


## Returns {ok, kind, state}. A missing document is an empty effect document for
## `world_identity`, not a failure: a world that never applied a resolution simply
## has no effects. An existing document must name this world; a foreign one is
## refused rather than adopted.
func load_state(world_identity: String) -> Dictionary:
	if not _safe_paths():
		return _failure("unsafe_path")
	if not _valid_world_id(world_identity):
		return _failure("invalid_world")
	var path: String = _path(MAIN)
	if not FileAccess.file_exists(path):
		var fresh: Dictionary = ResolutionEffects.empty()
		if not ResolutionEffects.valid(fresh):
			return _failure("invalid_state")
		world_id = world_identity
		return {"ok": true, "kind": "missing", "state": fresh}
	var read: Dictionary = _read(path)
	if not read.ok:
		return read
	var envelope: Dictionary = read.document
	if not _exact_keys(envelope, ENVELOPE_KEYS):
		return _failure("corrupt")
	if int(envelope.get("version", -1)) != VERSION:
		return _failure("unsupported")
	if str(envelope.get("world_id", "")) != world_identity:
		return _failure("world_mismatch")
	var state: Variant = envelope.get("state")
	if not state is Dictionary or not ResolutionEffects.valid(state):
		return _failure("corrupt")
	world_id = world_identity
	# JSON numbers arrive as floats; restore the integer shape before the caller
	# compares documents or writes them again, so a reload is byte-stable.
	var document: Dictionary = state
	normalize(document)
	return {"ok": true, "kind": "loaded", "state": document}


## Saves only a document that passes the same validation a load performs, so a
## caller cannot write an effect document the next load will refuse.
func save_state(state: Dictionary) -> Dictionary:
	if world_id.is_empty():
		return _failure("invalid_world")
	if not ResolutionEffects.valid(state):
		return _failure("invalid_state")
	if not _safe_paths():
		return _failure("unsafe_path")
	var create_error: Error = OK if _filesystem.dir_exists(directory) \
		else _filesystem.make_dir_recursive(directory)
	if create_error != OK:
		return _failure("create_directory", create_error)
	var text: String = JSON.stringify({
		"version": VERSION, "world_id": world_id, "state": state,
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


## Restores the integer shape JSON decoding loses. `valid()` already accepted
## integral floats; normalizing before a rewrite keeps `1` from becoming `1.0`
## and therefore keeps an unchanged document byte-identical across reloads.
static func normalize(state: Dictionary) -> void:
	var applied_version: Variant = state.get("applied_version")
	if applied_version is float and is_finite(float(applied_version)) \
			and float(applied_version) == floorf(float(applied_version)):
		state["applied_version"] = int(applied_version)
	var applied: Variant = state.get("applied")
	if not applied is Array:
		return
	for entry_value: Variant in applied:
		if not entry_value is Dictionary:
			continue
		var entry: Dictionary = entry_value
		var version: Variant = entry.get("version")
		if version is float and is_finite(float(version)) \
				and float(version) == floorf(float(version)):
			entry["version"] = int(version)


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
	if length <= 0:
		file.close()
		return _failure("corrupt")
	if length > MAX_BYTES:
		file.close()
		return _failure("too_large")
	var text: String = file.get_as_text()
	var read_error: Error = file.get_error()
	file.close()
	if read_error != OK and read_error != ERR_FILE_EOF:
		return _failure("io")
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return _failure("corrupt")
	return {"ok": true, "kind": "read", "document": json.data}


static func _valid_world_id(value: Variant) -> bool:
	return value is String and not str(value).is_empty() \
		and str(value).length() <= MAX_WORLD_ID_LENGTH


static func _exact_keys(value: Dictionary, keys: Array[String]) -> bool:
	if value.size() != keys.size():
		return false
	for key: String in keys:
		if not value.has(key):
			return false
	return true


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
