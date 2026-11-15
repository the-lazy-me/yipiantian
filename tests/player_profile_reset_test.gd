extends SceneTree
## Interfaceable identity reset: a new id and credential, old files archived
## intact, and failed resets that leave the previous profile in place.

const PlayerProfile = preload("res://social/player_profile.gd")

var checks: int = 0
var failures: Array[String] = []
var base: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	base = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/player-profile-reset").simplify_path()
	_remove_tree(base)
	DirAccess.make_dir_recursive_absolute(base)

	var profile := PlayerProfile.new(base)
	var created: Dictionary = profile.load_profile()
	_expect(bool(created.get("ok", false)), "A profile is created before the reset")
	_expect(profile.save_profile("阿青").ok, "The old identity has a name")
	var old_id: String = profile.player_id
	var old_secret: PackedByteArray = profile.player_secret.duplicate()
	var json_path: String = base.path_join(PlayerProfile.FILE_NAME)
	var key_path: String = base.path_join(PlayerProfile.SECRET_FILE)
	var old_json: String = FileAccess.get_file_as_string(json_path)
	var old_key: String = FileAccess.get_file_as_string(key_path)
	_expect(old_secret.size() == PlayerProfile.SECRET_BYTES, "The original key is 32 bytes")
	var old_shape: Variant = JSON.parse_string(old_json)
	_expect(old_shape is Dictionary and int(old_shape.get("version", 0)) == PlayerProfile.VERSION,
		"The original document uses the current version")
	# World data and world-side binding documents are not identity files; a reset
	# must leave them exactly where they are.
	var world_path: String = base.path_join("world.json")
	var bindings_path: String = base.path_join("player_bindings.json")
	_write(world_path, "{\"world\":1}")
	_write(bindings_path, "{\"players\":{}}")

	var first: Dictionary = profile.reset_identity()
	_expect(bool(first.get("ok", false)), "A reset succeeds")
	_expect(str(first.get("reason", "")) == "reset", "A successful reset names its reason")
	_expect(str(first.get("id", "")) == profile.player_id, "The result reports the new id")
	_expect(PlayerProfile.valid_id(profile.player_id), "The new id has the player_<32 hex> shape")
	_expect(profile.player_id != old_id, "The reset changes the player id")
	_expect(profile.player_secret.size() == PlayerProfile.SECRET_BYTES,
		"The reset creates a 32-byte credential")
	_expect(profile.player_secret != old_secret, "The reset changes the credential")
	_expect(bool(first.get("secret_created", false)), "The result reports the new credential")
	var first_archived: Array = first.get("archived", [])
	_expect(first_archived.size() == 2, "Both the id and the key are archived")

	var archived_json: PackedStringArray = _archives("json")
	var archived_key: PackedStringArray = _archives("key")
	_expect(archived_json.size() == 1, "The old id is archived once")
	_expect(archived_key.size() == 1, "The old key is archived once")
	_expect(archived_json[0].begins_with(PlayerProfile.RESET_ARCHIVE_PREFIX)
		and archived_json[0].contains("identity_reset"), "The id archive names the reset")
	_expect(archived_key[0].begins_with(PlayerProfile.RESET_ARCHIVE_PREFIX)
		and archived_key[0].contains("identity_reset"), "The key archive names the reset")
	_expect(FileAccess.get_file_as_string(base.path_join(archived_json[0])) == old_json,
		"The archived id is the original, byte for byte")
	_expect(FileAccess.get_file_as_string(base.path_join(archived_key[0])) == old_key,
		"The archived key is the original, byte for byte")
	_expect(FileAccess.get_file_as_string(world_path) == "{\"world\":1}",
		"A reset leaves world data untouched")
	_expect(FileAccess.get_file_as_string(bindings_path) == "{\"players\":{}}",
		"A reset leaves world-side bindings untouched")

	var reloaded := PlayerProfile.new(base)
	var loaded: Dictionary = reloaded.load_profile()
	_expect(str(loaded.get("kind", "")) == "loaded", "The new identity is readable")
	_expect(str(loaded.get("player_id", "")) == profile.player_id,
		"The new identity keeps the id the reset reported")
	_expect(reloaded.player_secret == profile.player_secret,
		"The new credential is the one stored on disk")
	var new_shape: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	_expect(new_shape is Dictionary, "The stored identity is still a JSON object")
	if new_shape is Dictionary:
		var document: Dictionary = new_shape
		_expect(document.keys().size() == 3 and document.has("version")
			and document.has("player_id") and document.has("name"),
			"The document shape is unchanged")
		_expect(int(document.get("version", 0)) == PlayerProfile.VERSION,
			"The new document keeps the current version")
		_expect(str(document.get("player_id", "")) == profile.player_id,
			"The new document stores the new id")
		_expect(str(document.get("name", "")) == "", "The new identity starts anonymous")

	# A second reset archives the first reset's files too; earlier archives stay
	# recoverable by hand.
	var second_old_json: String = FileAccess.get_file_as_string(json_path)
	var second_old_key: String = FileAccess.get_file_as_string(key_path)
	var second_id: String = profile.player_id
	var second: Dictionary = profile.reset_identity()
	_expect(bool(second.get("ok", false)), "A second reset succeeds")
	_expect(profile.player_id != second_id, "A second reset changes the id again")
	archived_json = _archives("json")
	archived_key = _archives("key")
	_expect(archived_json.size() == 2, "Each reset archives its own id")
	_expect(archived_key.size() == 2, "Each reset archives its own key")
	_expect(_contains(archived_json, second_old_json),
		"The second reset archives the file it replaced")
	_expect(_contains(archived_key, second_old_key),
		"The second reset archives the key it replaced")
	_expect(_contains(archived_json, old_json),
		"The first reset archive survives the second reset")

	# No old files is a normal first reset, not a failure.
	var empty: String = base.path_join("empty")
	var fresh := PlayerProfile.new(empty)
	var fresh_result: Dictionary = fresh.reset_identity()
	_expect(bool(fresh_result.get("ok", false)), "A reset without previous files succeeds")
	var fresh_archived: Array = fresh_result.get("archived", [])
	_expect(fresh_archived.is_empty(), "A reset without previous files archives nothing")
	_expect(FileAccess.file_exists(empty.path_join(PlayerProfile.FILE_NAME))
		and FileAccess.file_exists(empty.path_join(PlayerProfile.SECRET_FILE)),
		"A reset without previous files writes both identity files")
	_expect(fresh.player_secret.size() == PlayerProfile.SECRET_BYTES,
		"A reset without previous files still creates a credential")
	var fresh_loaded := PlayerProfile.new(empty)
	var fresh_result_load: Dictionary = fresh_loaded.load_profile()
	_expect(str(fresh_result_load.get("player_id", "")) == fresh.player_id,
		"A reset without previous files is readable")

	# A failed replacement refuses instead of leaving a half-written identity.
	# The old key is kept aside by the test and a directory blocks the new key
	# path, so the rename into place cannot succeed.
	var failure_base: String = base.path_join("failure")
	var victim := PlayerProfile.new(failure_base)
	victim.load_profile()
	var before_json: String = FileAccess.get_file_as_string(failure_base.path_join(PlayerProfile.FILE_NAME))
	var before_key: String = FileAccess.get_file_as_string(failure_base.path_join(PlayerProfile.SECRET_FILE))
	DirAccess.rename_absolute(failure_base.path_join(PlayerProfile.SECRET_FILE),
		failure_base.path_join("kept.key"))
	DirAccess.make_dir_absolute(failure_base.path_join(PlayerProfile.SECRET_FILE))
	var failed: Dictionary = victim.reset_identity()
	_expect(not bool(failed.get("ok", false)), "A blocked key write fails the reset")
	_expect(str(failed.get("reason", "")) == "key_write", "The failure is named")
	var failed_archived: Array = failed.get("archived", [])
	_expect(failed_archived.is_empty(), "A fully rolled back failure reports no archive")
	_expect(FileAccess.get_file_as_string(failure_base.path_join(PlayerProfile.FILE_NAME))
		== before_json, "A failed reset restores the old id file")
	_expect(_archives_in(failure_base, "json").is_empty(),
		"A failed reset leaves no id archive behind")
	_expect(FileAccess.get_file_as_string(failure_base.path_join("kept.key")) == before_key,
		"The test's saved key copy is untouched")
	_expect(DirAccess.dir_exists_absolute(failure_base.path_join(PlayerProfile.SECRET_FILE)),
		"The deliberately blocked key path is not deleted")

	_remove_tree(base)
	_finish()


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return
	file.store_string(text)
	file.close()


func _archives(extension: String) -> PackedStringArray:
	return _archives_in(base, extension)


func _archives_in(root: String, extension: String) -> PackedStringArray:
	var names := PackedStringArray()
	var dir := DirAccess.open(root)
	if dir == null:
		return names
	for name: String in dir.get_files():
		if name.begins_with(PlayerProfile.RESET_ARCHIVE_PREFIX) and name.ends_with("." + extension):
			names.append(name)
	names.sort()
	return names


func _contains(names: PackedStringArray, expected: String) -> bool:
	for name: String in names:
		if FileAccess.get_file_as_string(base.path_join(name)) == expected:
			return true
	return false


func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null: return
	for name: String in dir.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name: String in dir.get_directories():
		_remove_tree(path.path_join(name))
	DirAccess.remove_absolute(path)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("PLAYER_PROFILE_RESET_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
