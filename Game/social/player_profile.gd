extends RefCounted
## 本机玩家档案：跨启动稳定的玩家 ID 与显示名。
##
## 社交记录按玩家 ID 归属，所以 ID 一旦生成就跟着这台机器走；显示名可以随时
## 改，改之前留下的联系人仍然记得你。档案和农场存档、界面设置都不是一回事：
## 丢了这个文件，你会变成一个新邻居，但不会丢一块地。
##
## 文件只在这三个字段上做校验，不做迁移：版本不认识就当作不可读，不覆盖。

const VERSION: int = 1
const MAX_BYTES: int = 4096
const FILE_NAME: String = "player.json"
## Damaged originals are renamed to player.corrupt.<unix_us>.<sha256_prefix>.json
## before a new identity is written. Old archives are deleted beyond MAX_ARCHIVES
## (newest kept), so a file that keeps getting corrupted cannot grow the directory
## without bound. The timestamp and hash make the remaining files diagnosable.
const ARCHIVE_PREFIX: String = "player.corrupt."
const MAX_ARCHIVES: int = 5
const ID_PREFIX: String = "player_"
const ID_HEX_LENGTH: int = 32
const MAX_NAME: int = 24

var directory: String
var player_id: String = ""
var display_name: String = ""
var kind: String = "not_loaded"


func _init(profile_directory: String = "user://player") -> void:
	directory = ProjectSettings.globalize_path(profile_directory).simplify_path()


## Reads the profile, creating one on first run. A readable profile always
## yields the same id; only a missing or broken file makes a new one.
func load_profile() -> Dictionary:
	if not directory.is_absolute_path():
		kind = "unsafe_path"
		return _failure(kind)
	var path: String = _path()
	var text: String = ""
	if FileAccess.file_exists(path):
		var size: int = FileAccess.get_file_as_bytes(path).size()
		if size > MAX_BYTES:
			return _recover("oversized")
		text = FileAccess.get_file_as_string(path)
		if text.is_empty() and size > 0:
			return _recover("unreadable")
	var parsed: Variant = JSON.parse_string(text) if not text.is_empty() else null
	if FileAccess.file_exists(path):
		if not parsed is Dictionary:
			return _recover("corrupt")
		var data: Dictionary = parsed
		if int(data.get("version", 0)) != VERSION:
			kind = "unsupported"
			return _failure(kind)
		if not valid_id(str(data.get("player_id", ""))):
			return _recover("invalid_id")
		var stored: String = str(data.get("name", ""))
		if not stored.is_empty() and not valid_name(stored):
			return _recover("invalid_name")
		player_id = str(data.get("player_id", ""))
		display_name = stored
		kind = "loaded"
		return {"ok": true, "kind": kind, "player_id": player_id, "name": display_name}
	return _create("created")


## Stores the display name under the current id. A blank name is allowed and
## means anonymous; it never removes the id.
func save_profile(next_name: String) -> Dictionary:
	if player_id.is_empty() or not valid_id(player_id):
		return _failure("not_loaded")
	var name: String = next_name.strip_edges()
	if not name.is_empty() and not valid_name(name):
		return _failure("invalid_name")
	if not directory.is_absolute_path():
		return _failure("unsafe_path")
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return _failure("create_directory")
	var text: String = JSON.stringify(
		{"version": VERSION, "player_id": player_id, "name": name}, "\t")
	var file := FileAccess.open(_path(), FileAccess.WRITE)
	if file == null:
		return _failure("write")
	file.store_string(text)
	file.flush()
	var error: Error = file.get_error()
	file.close()
	if error != OK:
		return _failure("write")
	display_name = name
	return {"ok": true, "name": display_name}


## Writes a fresh profile. The id is random, not derived from the machine: two
## installs on the same Mac are still two different neighbours.
func _create(reason: String) -> Dictionary:
	player_id = new_id()
	display_name = ""
	kind = "created"
	var saved: Dictionary = save_profile("")
	if not saved.ok:
		# The id still works for this session; the next launch simply makes one.
		kind = "created_unsaved"
		return {"ok": true, "kind": kind, "player_id": player_id, "name": "",
			"warning": str(saved.get("reason", ""))}
	return {"ok": true, "kind": kind, "player_id": player_id, "name": "",
		"reason": reason}


## A broken file is renamed aside before a new identity is written: it may be the
## only copy of an id somebody's neighbours still know, and it is the evidence for
## why the identity changed. Nothing is written over it; if preserving it or
## writing the replacement fails, the failure is named and no identity is invented
## as if this were a first launch.
func _recover(reason: String) -> Dictionary:
	var archived: Dictionary = _archive_original()
	if not archived.ok:
		return _recover_failed(str(archived.get("reason", "preserve_original")), reason)
	var made: Dictionary = _create(reason)
	if str(made.get("kind", "")) != "created":
		# The archive moved the old file away, but the replacement could not be
		# stored; recycling a fresh id for one session is not a successful recovery.
		return _recover_failed(str(made.get("warning", "write")), reason,
			str(archived.get("name", "")))
	kind = "recovered"
	return {"ok": true, "kind": kind, "player_id": player_id, "name": display_name,
		"recovered": reason, "archive": str(archived.get("name", ""))}


## Moves player.json to a timestamped, hashed archive name. The rename must be
## byte-preserving; if it is not, the original is put back and nothing is built.
func _archive_original() -> Dictionary:
	var path: String = _path()
	if not FileAccess.file_exists(path):
		return {"ok": false, "reason": "missing_original"}
	var digest: String = FileAccess.get_sha256(path)
	var stamp: int = int(Time.get_unix_time_from_system() * 1000000.0)
	var suffix: String = digest.substr(0, 12) if not digest.is_empty() else "unknown"
	var name: String = "%s%d.%s.json" % [ARCHIVE_PREFIX, stamp, suffix]
	var archive: String = directory.path_join(name)
	var duplicate: int = 0
	# Two writes in the same microsecond can produce the same name; keep both.
	while FileAccess.file_exists(archive):
		duplicate += 1
		name = "%s%d.%s.%03d.json" % [ARCHIVE_PREFIX, stamp, suffix, duplicate]
		archive = directory.path_join(name)
	var error: Error = DirAccess.rename_absolute(path, archive)
	if error != OK:
		return {"ok": false, "reason": "preserve_original", "error": int(error)}
	if not digest.is_empty() and FileAccess.get_sha256(archive) != digest:
		DirAccess.rename_absolute(archive, path)
		return {"ok": false, "reason": "preserve_original"}
	_trim_archives()
	return {"ok": true, "name": name}


## Keeps the newest MAX_ARCHIVES archives. Names start with a fixed-width Unix
## microsecond stamp, so lexical order is age order in this era.
func _trim_archives() -> void:
	var dir := DirAccess.open(directory)
	if dir == null:
		return
	var names: Array[String] = []
	for filename: String in dir.get_files():
		if filename.begins_with(ARCHIVE_PREFIX) and filename.ends_with(".json"):
			names.append(filename)
	if names.size() <= MAX_ARCHIVES:
		return
	names.sort()
	for index: int in range(names.size() - MAX_ARCHIVES):
		var removed: String = names[index]
		if DirAccess.remove_absolute(directory.path_join(removed)) != OK:
			push_warning("PLAYER_PROFILE stage=trim_archive file=%s" % removed)


func _recover_failed(reason: String, recovered: String, archive: String = "") -> Dictionary:
	kind = "recover_failed"
	# Play still needs an identity for this session. An id minted here is not
	# stored, so the next launch asks again rather than shipping a file this run
	# could not preserve or read back.
	if player_id.is_empty():
		player_id = new_id()
	push_warning("PLAYER_PROFILE stage=recover_failed reason=%s recovered=%s archive=%s" % [
		reason, recovered, archive])
	return {"ok": false, "kind": kind, "reason": reason, "recovered": recovered,
		"archive": archive, "player_id": player_id, "name": display_name}


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "kind": kind, "reason": reason}


func _path() -> String:
	return directory.path_join(FILE_NAME)


static func new_id() -> String:
	var parts := PackedStringArray()
	for byte: int in Crypto.new().generate_random_bytes(16):
		parts.append("%02x" % byte)
	return ID_PREFIX + "".join(parts)


static func valid_id(value: String) -> bool:
	if not value.begins_with(ID_PREFIX) or value.length() != ID_PREFIX.length() + ID_HEX_LENGTH:
		return false
	for index: int in range(ID_PREFIX.length(), value.length()):
		if not "0123456789abcdef".contains(value[index]):
			return false
	return true


## Names are what a neighbour sees in a list, so they are trimmed, bounded and
## free of control characters; everything else about them is the player's.
static func valid_name(value: String) -> bool:
	var name: String = value.strip_edges()
	if name.is_empty() or name.length() > MAX_NAME:
		return false
	for index: int in name.length():
		var code: int = name.unicode_at(index)
		if code < 32 or code == 127:
			return false
	return true
