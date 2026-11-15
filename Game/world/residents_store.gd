extends RefCounted
## World-level sidecar for residents' social relations and bounded memories.
##
## Resident economy (accounts, bags, market orders) already lives in the farm
## document; this store deliberately copies none of it. It persists only the
## `NpcSocial` relation document and the `NpcMemory` document for the roster.
##
## Envelope:
##
##   {
##     "version": 1,
##     "world_id": "<world id>",
##     "social": {relations: {...}, actions: {...}},
##     "memories": {schema: 1, world_id: "<world id>", npcs: {...}},
##   }
##
## The authority is the only writer. Saving goes to `residents.pending.json`,
## is read back and compared, and only then replaces `residents.json`, so a
## crash cannot leave half a relation/memory document. A missing file is a
## fresh world: pairwise neighbour rows for the roster and empty memories. An
## existing file that cannot be validated, names another world, or uses an
## unsupported version stops the authority instead of being overwritten.
##
## Missing files are never written by a load. A world that never enables
## residents therefore leaves no `residents.json` behind.

const Social = preload("res://npc/npc_social.gd")
const Memory = preload("res://npc/npc_memory.gd")
const Roster = preload("res://npc/npc_roster.gd")

const VERSION: int = 1
const MAX_BYTES: int = 262144
const MAIN: String = "residents.json"
const PENDING: String = "residents.pending.json"
const ENVELOPE_KEYS: Array[String] = ["version", "world_id", "social", "memories"]
const STATE_KEYS: Array[String] = ["social", "memories"]

var directory: String
## Fixed by the last successful load and written into every save.
var world_id: String = ""
var _filesystem: DirAccess


func _init(save_directory: String) -> void:
	directory = ProjectSettings.globalize_path(save_directory).simplify_path()
	var root: String = directory
	while root != root.get_base_dir():
		root = root.get_base_dir()
	_filesystem = DirAccess.open(root)


## Fresh document for one world: the roster already knows each other, so every
## pair starts at affinity 0. Memory starts empty; authored baseline rows are
## the roster's own concern, not this storage layer.
static func empty_state(world_id_value: Variant) -> Dictionary:
	var created: Dictionary = Memory.create(world_id_value)
	if not created.ok:
		return {}
	var relations: Dictionary = {}
	for npc_id: String in Roster.IDS:
		var peers: Dictionary = {}
		for peer: String in Roster.IDS:
			if peer == npc_id:
				continue
			peers[peer] = {
				"affinity": 0, "last_utc": 0.0, "acts": {}, "gifts_utc": [],
			}
		relations[npc_id] = peers
	return {
		"social": {"relations": relations, "actions": {}},
		"memories": created.document,
	}


## Strict shape check shared by load and save. The social document follows
## `NpcSocial.valid()`; the memory document follows `NpcMemory` at `now_utc`;
## the memory world must be the envelope world.
static func valid_state(state: Variant, world_id_value: String,
		now_utc: float) -> bool:
	if not state is Dictionary or (state as Dictionary).size() != STATE_KEYS.size():
		return false
	for key: String in STATE_KEYS:
		if not (state as Dictionary).has(key):
			return false
	if not Social.valid((state as Dictionary).get("social")):
		return false
	var checked: Dictionary = Memory.validate_document(
		(state as Dictionary).get("memories"), now_utc)
	if not bool(checked.ok):
		return false
	var memories: Dictionary = (state as Dictionary).memories
	return str(memories.get("world_id", "")) == world_id_value


## Returns {ok, kind, state}. A missing file is a fresh world document; a file
## that exists but cannot be read is refused rather than replaced.
func load_state(world_id_value: String, now_utc: float) -> Dictionary:
	if not _safe_paths():
		return _failure("unsafe_path")
	if not _valid_time(now_utc):
		return _failure("invalid_time")
	world_id = world_id_value
	var path: String = _path(MAIN)
	if not FileAccess.file_exists(path):
		var fresh: Dictionary = empty_state(world_id_value)
		if fresh.is_empty() or not valid_state(fresh, world_id_value, now_utc):
			return _failure("invalid_world")
		return {"ok": true, "kind": "missing", "state": fresh}
	var read: Dictionary = _read(path)
	if not read.ok:
		return read
	var envelope: Dictionary = read.document
	if not _exact_keys(envelope, ENVELOPE_KEYS):
		return _failure("corrupt")
	if int(envelope.get("version", -1)) != VERSION:
		return _failure("unsupported")
	if str(envelope.get("world_id", "")) != world_id_value:
		return _failure("world_mismatch")
	var social: Variant = envelope.get("social")
	if not Social.valid(social):
		return _failure("corrupt")
	var restored: Dictionary = Memory.from_document(envelope.get("memories"), now_utc)
	if not bool(restored.ok):
		return _failure("corrupt")
	var memories: Dictionary = restored.document
	if str(memories.world_id) != world_id_value:
		return _failure("corrupt")
	var state: Dictionary = {
		"social": (social as Dictionary).duplicate(true),
		"memories": memories,
	}
	Social.normalize(state.social)
	return {"ok": true, "kind": "loaded", "state": state}


## Saves only a document that passes the same validation a load performs.
func save_state(state: Dictionary, now_utc: float) -> Dictionary:
	if world_id.is_empty():
		return _failure("invalid_world")
	if not valid_state(state, world_id, now_utc):
		return _failure("invalid_state")
	if not _safe_paths():
		return _failure("unsafe_path")
	var create_error: Error = OK if _filesystem.dir_exists(directory) \
		else _filesystem.make_dir_recursive(directory)
	if create_error != OK:
		return _failure("create_directory", create_error)
	var text: String = JSON.stringify({
		"version": VERSION, "world_id": world_id,
		"social": state.social, "memories": state.memories,
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


static func _exact_keys(value: Dictionary, keys: Array[String]) -> bool:
	if value.size() != keys.size():
		return false
	for key: String in keys:
		if not value.has(key):
			return false
	return true


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) >= 0.0 and float(value) <= float(Memory.MAX_SAFE_INTEGER)


func _safe_paths() -> bool:
	return directory.is_absolute_path() and directory.get_base_dir() != directory


func _path(filename: String) -> String:
	return directory.path_join(filename)


static func _failure(kind: String, error: Error = OK) -> Dictionary:
	var result: Dictionary = {"ok": false, "kind": kind}
	if error != OK:
		result["error"] = error
	return result
