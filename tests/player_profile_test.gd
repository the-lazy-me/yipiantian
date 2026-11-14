extends SceneTree
## The local player profile: one stable id per installation, a name that can
## change, and a broken file that is preserved instead of silently replaced.

const PlayerProfile = preload("res://social/player_profile.gd")

var checks: int = 0
var failures: Array[String] = []
var base: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	base = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/player-profile").simplify_path()
	_remove_tree(base)
	DirAccess.make_dir_recursive_absolute(base)

	# First run mints an id and writes it immediately, so the next launch is the
	# same neighbour even if the player never sets a name.
	var first := PlayerProfile.new(base)
	var created: Dictionary = first.load_profile()
	_expect(bool(created.get("ok", false)), "A missing profile is created")
	_expect(str(created.get("kind", "")) == "created", "The first load reports itself as created")
	_expect(PlayerProfile.valid_id(str(created.get("player_id", ""))),
		"The new id has the player_<32 hex> shape")
	_expect(str(created.get("name", "")) == "", "A new profile has no name yet")
	_expect(FileAccess.file_exists(base.path_join(PlayerProfile.FILE_NAME)),
		"The profile is written on first run, not only on rename")

	var again := PlayerProfile.new(base)
	var loaded: Dictionary = again.load_profile()
	_expect(str(loaded.get("kind", "")) == "loaded", "A second launch reads the stored profile")
	_expect(str(loaded.get("player_id", "")) == str(first.player_id),
		"The player keeps the same id across launches")

	# Renaming keeps the id: contacts made under the old name still point here.
	var renamed: Dictionary = again.save_profile("  阿青  ")
	_expect(bool(renamed.get("ok", false)), "A name can be stored")
	_expect(str(again.display_name) == "阿青", "The stored name is trimmed")
	var third := PlayerProfile.new(base)
	var with_name: Dictionary = third.load_profile()
	_expect(str(with_name.get("name", "")) == "阿青", "The name survives a restart")
	_expect(str(with_name.get("player_id", "")) == str(first.player_id),
		"Renaming does not change the id")

	# Names that would break a neighbour list are refused, and nothing is written.
	for bad: String in ["一二三四五六七八九十一二三四五六七八九十一二三四五",
			"阿青\n小满", "阿青%s小满" % char(7)]:
		var refused: Dictionary = third.save_profile(bad)
		_expect(not bool(refused.get("ok", false)), "The name %s is refused" % JSON.stringify(bad))
	var unchanged := PlayerProfile.new(base)
	unchanged.load_profile()
	_expect(str(unchanged.display_name) == "阿青", "A refused rename leaves the old name in place")

	# A blank name is anonymous, not a new player.
	var anonymous: Dictionary = third.save_profile("")
	_expect(bool(anonymous.get("ok", false)) and str(third.display_name) == "",
		"Clearing the name keeps the id and makes the player anonymous")
	_expect(third.save_profile("阿青").ok, "A name can be set again")

	# A broken file is preserved; the player becomes a new neighbour, but the old
	# id is still on disk for a human to recover.
	var broken: String = base.path_join(PlayerProfile.FILE_NAME)
	var broken_file := FileAccess.open(broken, FileAccess.WRITE)
	broken_file.store_string("{ not json")
	broken_file.close()
	var recovered := PlayerProfile.new(base)
	var healed: Dictionary = recovered.load_profile()
	_expect(str(healed.get("kind", "")) == "recovered", "A corrupt profile is reported as recovered")
	_expect(PlayerProfile.valid_id(str(healed.get("player_id", ""))),
		"A recovered profile still gets a usable id")
	_expect(str(healed.get("player_id", "")) != str(first.player_id),
		"A corrupt file cannot be trusted to name the same player")
	_expect(FileAccess.file_exists(base.path_join(PlayerProfile.HOLD_NAME)),
		"The unreadable file is kept next to the new one")
	_expect(FileAccess.get_file_as_string(base.path_join(PlayerProfile.HOLD_NAME)).begins_with("{ not json"),
		"The preserved copy is the original, byte for byte")

	# An unknown version is not migrated and not overwritten: this build does not
	# know what a future profile means.
	var future := PlayerProfile.new(base)
	var future_file := FileAccess.open(future._path(), FileAccess.WRITE)
	future_file.store_string(JSON.stringify({"version": 99, "player_id":
		"player_00000000000000000000000000000001", "name": "未来"}))
	future_file.close()
	var refused_future: Dictionary = future.load_profile()
	_expect(not bool(refused_future.get("ok", false)), "A newer profile version is not adopted")
	_expect(str(refused_future.get("reason", "")) == "unsupported", "The reason is named")
	_expect(FileAccess.get_file_as_string(future._path()).contains("\"version\":99"),
		"The newer file is left untouched")

	# Saving without loading must not invent an identity for an unrelated caller.
	var unloaded := PlayerProfile.new(base)
	_expect(not bool(unloaded.save_profile("阿青").ok), "Saving before loading is refused")

	_remove_tree(base)
	_finish()


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
	print("PLAYER_PROFILE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
