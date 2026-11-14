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
const HOLD_NAME: String = "player.unreadable.json"
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


## A broken file is preserved instead of overwritten: it may be the only copy of
## an id somebody's neighbours still know.
func _recover(reason: String) -> Dictionary:
	var path: String = _path()
	var hold: String = directory.path_join(HOLD_NAME)
	if not FileAccess.file_exists(hold):
		if DirAccess.copy_absolute(path, hold) != OK:
			# Never overwrite the only copy of an id neighbours still know.
			player_id = new_id()
			display_name = ""
			kind = "recovered_unsaved"
			return {"ok": true, "kind": kind, "player_id": player_id, "name": "",
				"warning": "preserve_original", "recovered": reason}
	kind = "recovered"
	var made: Dictionary = _create(reason)
	made["kind"] = "recovered"
	made["recovered"] = reason
	return made


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
