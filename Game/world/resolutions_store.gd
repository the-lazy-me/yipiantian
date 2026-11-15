extends RefCounted
## Versioned storage for the world's rule-resolution document (M11-03).
## Resolutions are world-level facts with their own lifecycle, so they live in
## their own sidecar instead of the exact-key-count v27 farm document.
##
## Envelope:
##
##   {
##     "version": 1,
##     "world_id": "<world id>",
##     "state": { "rules_version": 0, "resolutions": {...} },
##     "commands": [
##       {"command_id": "<id>", "payload": "<json>", "result": {...}},
##     ],
##   }
##
## `commands` is a bounded replay journal of the last successful commands, at
## most MAX_COMMANDS rows, so a restarted authority can answer the same command
## id with the result it first returned. It is not part of `state`: the rules
## document keeps its strict two-key shape, and the journal is storage, not
## rules. Each row carries a unique, non-empty command id; payload and result
## stay opaque here because their shape belongs to the authority slice that
## records them.
##
## The authoritative world is the only writer. A save goes to a pending file,
## is read back and compared, and only then replaces the main document, so a
## crash cannot leave a half-written resolution table. A document that exists
## but cannot be read, belongs to another world, has an unsupported version,
## exceeds the byte or row budget, or fails `ResolutionState.valid()` stops the
## authority instead of being replaced by an empty table.
##
## A missing document is a legal empty resolution table for the given world,
## and a load never writes one. A world that has never passed a resolution
## leaves no `resolutions.json` behind.

const ResolutionState = preload("res://world/resolution_state.gd")

const VERSION: int = 1
const MAX_BYTES: int = 65536
## Bounded replay window, matching the other sidecar stores.
const MAX_COMMANDS: int = 64
const MAX_COMMAND_ID_LENGTH: int = 128
const MAX_WORLD_ID_LENGTH: int = 128
const MAIN: String = "resolutions.json"
const PENDING: String = "resolutions.pending.json"
const ENVELOPE_KEYS: Array[String] = ["version", "world_id", "state", "commands"]
const COMMAND_KEYS: Array[String] = ["command_id", "payload", "result"]

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


## Returns {ok, kind, state, commands}. A missing document is an empty table for
## `world_identity`, not a failure: a world that has never resolved anything
## simply has no resolutions. An existing document must name this world; a
## foreign one is refused rather than adopted.
func load_state(world_identity: String) -> Dictionary:
	if not _safe_paths():
		return _failure("unsafe_path")
	if not _valid_world_id(world_identity):
		return _failure("invalid_world")
	var path: String = _path(MAIN)
	if not FileAccess.file_exists(path):
		var fresh: Dictionary = ResolutionState.empty()
		if not ResolutionState.valid(fresh):
			return _failure("invalid_state")
		world_id = world_identity
		return {"ok": true, "kind": "missing", "state": fresh, "commands": []}
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
	if not state is Dictionary or not ResolutionState.valid(state):
		return _failure("corrupt")
	var commands: Variant = envelope.get("commands")
	if not _valid_commands(commands):
		return _failure("corrupt")
	world_id = world_identity
	# JSON numbers arrive as floats; normalize after the strict check so the
	# in-memory document keeps the integer shape it was written with.
	var document: Dictionary = state
	ResolutionState.normalize(document)
	return {"ok": true, "kind": "loaded", "state": document, "commands": commands}


## Saves only a document that passes the same validation a load performs, so a
## caller cannot write a resolution table the next load will refuse. The command
## journal is part of the same atomic replace: a replay can never outlive the
## state it first returned.
func save_state(state: Dictionary, commands: Array = []) -> Dictionary:
	if world_id.is_empty():
		return _failure("invalid_world")
	if not ResolutionState.valid(state):
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
				or str(command_id).length() > MAX_COMMAND_ID_LENGTH:
			return false
		if seen.has(command_id):
			return false
		seen[command_id] = true
		if not (row_value as Dictionary).get("payload") is String:
			return false
		if not (row_value as Dictionary).get("result") is Dictionary:
			return false
	return true


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
	# save_state creates it. This mirrors the other sidecar document stores.
	return directory.is_absolute_path() and directory.get_base_dir() != directory


func _path(filename: String) -> String:
	return directory.path_join(filename)


static func _failure(kind: String, error: Error = OK) -> Dictionary:
	var result: Dictionary = {"ok": false, "kind": kind}
	if error != OK:
		result["error"] = error
	return result
