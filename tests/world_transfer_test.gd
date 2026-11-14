extends SceneTree
## Runtime world transfer service. Fixtures stay below .local/verification.

const Farm = preload("res://farm/farm_state.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const WorldPackage = preload("res://farm/world_package.gd")
const Transfer = preload("res://farm/world_transfer.gd")
const SocialState = preload("res://social/social_state.gd")
const SocialStore = preload("res://social/social_store.gd")
const START: float = 1800000000.0
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join("../.local/verification/world-transfer-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	var save_a: String = test_root.path_join("save-a")
	var fixture_a: Dictionary = _make_save(save_a, 0)
	_expect(fixture_a.ok, "Fixture save A is committed")
	var save_a_tree: Dictionary = _tree(save_a)
	var package_a: String = test_root.path_join("package-a")
	var exported: Dictionary = Transfer.export_world(save_a, package_a)
	_expect(exported.ok and exported.kind == "exported", "Export converts the live v27 save")
	_expect(_without_identity(_tree(save_a)) == _without_identity(save_a_tree), "Export leaves the live world bytes unchanged")
	_expect(FileAccess.file_exists(save_a.path_join("identity.json")), "First export persists the live identity")
	if not exported.ok:
		_report()
		return
	_expect(exported.package.social.players.has(PLAYER_A),
		"Export carries the social document")
	_test_export_result(exported)
	_test_identity_continuity(save_a, exported)
	_test_export_rejections(save_a)
	var package_a_tree: Dictionary = _tree(package_a)
	_test_import_preview(package_a, package_a_tree)
	var save_b: String = test_root.path_join("save-b")
	var imported: Dictionary = _import_into(package_a, save_b)
	_expect(imported.ok and imported.kind == "imported", "A new save can be created from a package")
	if imported.ok:
		_expect(imported.backup_path.is_empty(), "First import has no previous world to back up")
		var loaded_b: Dictionary = FarmStore.new(save_b).load_state()
		_expect(loaded_b.ok and loaded_b.farm == exported.package.snapshot, "Imported farm matches the package snapshot")
		_expect(loaded_b.decorations == exported.package.decorations, "Imported decorations match the package")
		var identity_b: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(save_b.path_join("identity.json")))
		_expect(identity_b.player_id == exported.package.player_id and identity_b.device_id == exported.package.device_id, "Imported save keeps the package identity")
		var social_b: Dictionary = SocialStore.new(save_b).load_state()
		_expect(social_b.ok and social_b.state.players.has(PLAYER_A) and social_b.state.players.has(PLAYER_B),
			"Imported save restores both players")
		_expect(social_b.ok and social_b.state.players[PLAYER_A].contacts.has(PLAYER_B),
			"Imported save keeps the contact after migration")
	_test_modified_roundtrip(save_b, package_a)
	_test_backup_and_identity(save_a, package_a, exported.package)
	_test_rejections(package_a, package_a_tree, save_a)
	_test_cancel_is_read_only(package_a)
	_test_failure_preserves_original(package_a, package_a_tree)
	_test_repeated_import(package_a, package_a_tree)
	_test_ambiguous(package_a_tree)
	_report()


func _test_export_result(exported: Dictionary) -> void:
	var summary: Dictionary = exported.summary
	_expect(FileAccess.file_exists(summary.package_path), "Export writes world.json")
	_expect(summary.output_directory.get_file() == "package-a", "Export summary names the output directory")
	_expect(summary.world_id == exported.package.world_id and summary.farm_id == exported.package.farm_id, "Export summary names the derived world and farm")
	_expect(summary.player_id == exported.package.player_id and summary.device_id == exported.package.device_id, "Export summary carries identity")
	_expect(FileAccess.file_exists(summary.output_directory.path_join("identity.json")), "Export writes the identity file")
	var parsed: Dictionary = WorldPackage.parse(FileAccess.get_file_as_string(summary.package_path))
	_expect(parsed.ok, "Exported world.json validates through the current parser")
	_expect(parsed.package.snapshot.inventory == exported.package.snapshot.inventory, "Exported package keeps inventory")
	_expect(parsed.package.snapshot.layout == exported.package.snapshot.layout, "Exported package keeps the layout")


func _test_identity_continuity(save: String, first: Dictionary) -> void:
	var live: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(save.path_join("identity.json")))
	_expect(live.player_id == first.package.player_id and live.device_id == first.package.device_id, "Exported package carries the persisted live identity")
	var live_tree: Dictionary = _tree(save)
	var second: Dictionary = Transfer.export_world(save, test_root.path_join("package-again"))
	_expect(second.ok and second.kind == "exported", "The same live save exports a second time")
	if second.ok:
		_expect(second.package.player_id == first.package.player_id and second.package.device_id == first.package.device_id, "Repeated export keeps the same player and device")
	_expect(_tree(save) == live_tree, "Repeated export does not rewrite the live save")


func _test_export_rejections(save: String) -> void:
	var occupied: String = test_root.path_join("occupied")
	DirAccess.make_dir_recursive_absolute(occupied)
	_write(occupied.path_join("note.txt"), "not a package")
	var blocked: Dictionary = Transfer.export_world(save, occupied)
	_expect(not blocked.ok and blocked.kind == "existing_output", "Export refuses a non-empty folder")
	_expect(DirAccess.get_files_at(occupied).size() == 1, "Refused export writes nothing into the folder")
	var inside: Dictionary = Transfer.export_world(save, save.path_join("export"))
	_expect(not inside.ok and inside.kind == "unsafe_output", "Export refuses a target inside the live save")
	var missing: Dictionary = Transfer.export_world(test_root.path_join("no-save"), test_root.path_join("empty-target"))
	_expect(not missing.ok and missing.kind == "missing", "Export reports a missing live save")


func _test_import_preview(package: String, package_tree: Dictionary) -> void:
	var save: String = test_root.path_join("preview-only")
	var prepared: Dictionary = Transfer.prepare_import(package, save)
	_expect(prepared.ok and prepared.kind == "ready", "Import preview validates without writing")
	_expect(prepared.summary.package_path == package.path_join("worlds").path_join(prepared.package.world_id).path_join("world.json"), "Preview finds the single world in a package root")
	_expect(prepared.summary.has_existing_save == false and prepared.summary.backup_path.is_empty(), "Preview reports that there is no existing world")
	_expect(not DirAccess.dir_exists_absolute(save), "Preview does not create the save directory")
	_expect(_tree(package) == package_tree, "Preview does not write the package")


func _test_modified_roundtrip(save_b: String, package_a_directory: String) -> void:
	# Simulate arriving on another machine, playing, and exporting again.
	var store_b := FarmStore.new(save_b)
	var loaded: Dictionary = store_b.load_state()
	var farm := Farm.new()
	_expect(farm.restore_snapshot(loaded.farm), "Reopened package farm can be played")
	var sow: Dictionary = farm.sow("field_02", "cell_01", "radish", START + 7200.0)
	_expect(sow.ok, "Second-machine farm accepts a new action")
	_expect(store_b.save(farm.snapshot(), loaded.decorations).ok, "Second-machine action is saved")
	var package_b: String = test_root.path_join("package-b")
	var exported: Dictionary = Transfer.export_world(save_b, package_b)
	_expect(exported.ok, "Second-machine save exports again")
	if not exported.ok:
		return
	var source_package: Dictionary = WorldPackage.parse(FileAccess.get_file_as_string(package_a_directory.path_join("worlds").path_join(_world_id(package_a_directory)).path_join("world.json"))).package
	_expect(exported.package.player_id == source_package.player_id and exported.package.device_id == source_package.device_id, "Roundtrip keeps the same player and device identity")
	var save_c: String = test_root.path_join("save-roundtrip")
	var imported: Dictionary = _import_into(package_b, save_c)
	_expect(imported.ok, "Roundtrip package imports into a fresh save")
	var restored: Dictionary = FarmStore.new(save_c).load_state()
	_expect(restored.ok and restored.farm == farm.snapshot(), "Roundtrip retains the second-machine farm state")
	_expect(restored.farm.inventory.radish == farm.snapshot().inventory.radish, "Roundtrip inventory is not duplicated or lost")
	var source_world: String = package_a_directory.path_join("worlds").path_join(_world_id(package_a_directory))
	_expect(FileAccess.file_exists(source_world.path_join("world.json")) and FileAccess.file_exists(source_world.path_join("import-report.json")), "Roundtrip leaves the original package readable")


func _test_backup_and_identity(save: String, package: String, package_data: Dictionary) -> void:
	var old_main: String = FileAccess.get_file_as_string(save.path_join(FarmStore.MAIN))
	var old_farm: Dictionary = FarmStore.new(save).load_state().farm
	var imported: Dictionary = _import_into(package, save)
	_expect(imported.ok, "Import replaces an existing save")
	if not imported.ok:
		return
	_expect(not imported.backup_path.is_empty() and DirAccess.dir_exists_absolute(imported.backup_path), "Existing world is copied to a backup directory")
	_expect(FileAccess.file_exists(imported.backup_path.path_join(FarmStore.MAIN)), "Backup contains farm.json")
	_expect(FileAccess.get_file_as_string(imported.backup_path.path_join(FarmStore.MAIN)) == old_main, "Backup keeps the previous main bytes")
	_expect(FileAccess.file_exists(imported.backup_path.path_join(FarmStore.BACKUP)), "Backup keeps the previous backup sidecar")
	var backup_state: Dictionary = FarmStore.new(imported.backup_path).load_state()
	_expect(backup_state.ok and backup_state.farm == old_farm, "Backup directory is itself a readable old world")
	var loaded: Dictionary = FarmStore.new(save).load_state()
	_expect(loaded.ok and loaded.farm == package_data.snapshot and loaded.decorations == package_data.decorations, "Live save now holds the imported world")
	var identity: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(save.path_join("identity.json")))
	_expect(identity.player_id == package_data.player_id and identity.device_id == package_data.device_id, "Import persists the package identity next to the live save")
	_expect(imported.summary.player_id == package_data.player_id, "Import result reports the preserved identity")


func _test_rejections(package: String, package_tree: Dictionary, save: String) -> void:
	var before: Dictionary = _tree(save)
	var corrupt: String = test_root.path_join("corrupt-package")
	DirAccess.make_dir_recursive_absolute(corrupt)
	_write(corrupt.path_join("world.json"), "{truncated")
	_write(corrupt.path_join("identity.json"), "{\"format\":\"yipiantian.import_identity\"}")
	var rejected: Dictionary = Transfer.prepare_import(corrupt, save)
	_expect(not rejected.ok and rejected.kind == "corrupt", "Corrupt package is rejected")
	_expect(_tree(save) == before and _tree(package) == package_tree, "Rejected corrupt package leaves save and package unchanged")
	var newer: String = test_root.path_join("newer-package")
	DirAccess.make_dir_recursive_absolute(newer)
	var newer_package: Dictionary = WorldPackage.parse(FileAccess.get_file_as_string(package.path_join("worlds").path_join(_world_id(package)).path_join("world.json"))).package.duplicate(true)
	newer_package.rules_version = FarmStore.VERSION + 1
	_write(newer.path_join("world.json"), JSON.stringify(newer_package))
	var newer_result: Dictionary = Transfer.prepare_import(newer, save)
	_expect(not newer_result.ok and newer_result.kind == "newer_rules", "Newer rules version is rejected")
	_expect(_tree(save) == before, "Rejected newer package leaves the save unchanged")
	var unknown: String = test_root.path_join("unknown-package")
	DirAccess.make_dir_recursive_absolute(unknown)
	var unknown_package: Dictionary = newer_package.duplicate(true)
	unknown_package.rules_version = FarmStore.VERSION
	unknown_package.format = "another.format"
	_write(unknown.path_join("world.json"), JSON.stringify(unknown_package))
	_expect(Transfer.prepare_import(unknown, save).kind == "unknown_format", "Unknown package format is rejected")
	var missing: Dictionary = Transfer.prepare_import(test_root.path_join("no-such-package"), save)
	_expect(not missing.ok and missing.kind == "missing", "Missing package is rejected without writing")
	_expect(_tree(save) == before, "All rejected imports leave the live save byte-identical")


func _test_cancel_is_read_only(package: String) -> void:
	var save: String = test_root.path_join("save-cancel")
	_expect(_make_save(save, 1).ok, "Cancel fixture save is committed")
	var before: Dictionary = _tree(save)
	var prepared: Dictionary = Transfer.prepare_import(package, save)
	_expect(prepared.ok, "Cancel fixture prepares successfully")
	_expect(_tree(save) == before, "Preparing an import changes no save bytes")
	_expect(not DirAccess.dir_exists_absolute(save.path_join("import-backups")), "Cancelling before apply creates no backup directory")


func _test_failure_preserves_original(package: String, package_tree: Dictionary) -> void:
	var save: String = test_root.path_join("save-write-failure")
	_expect(_make_save(save, 1).ok, "Failure fixture save is committed")
	var main_path: String = save.path_join(FarmStore.MAIN)
	var before: String = FileAccess.get_file_as_string(main_path)
	var prepared: Dictionary = Transfer.prepare_import(package, save)
	_expect(prepared.ok, "Failure fixture prepares")
	_write(save.path_join("import-backups"), "blocks backup directory creation")
	var failed: Dictionary = Transfer.apply_import(prepared, save)
	_expect(not failed.ok, "A blocked backup aborts the import")
	_expect(FileAccess.get_file_as_string(main_path) == before, "Failed import preserves the original main bytes")
	_expect(_tree(package) == package_tree, "Failed import leaves the source package unchanged")
	DirAccess.remove_absolute(save.path_join("import-backups"))


func _test_repeated_import(package: String, package_tree: Dictionary) -> void:
	var save: String = test_root.path_join("save-repeat")
	var first: Dictionary = _import_into(package, save)
	_expect(first.ok, "Repeated-import fixture imports once")
	var main_path: String = save.path_join(FarmStore.MAIN)
	var identity_path: String = save.path_join("identity.json")
	var main_hash: String = FileAccess.get_sha256(main_path)
	var identity_hash: String = FileAccess.get_sha256(identity_path)
	var state: Dictionary = FarmStore.new(save).load_state()
	var prepared: Dictionary = Transfer.prepare_import(package, save)
	_expect(prepared.ok and prepared.summary.has_existing_save, "Repeat preview sees the imported save")
	var second: Dictionary = Transfer.apply_import(prepared, save)
	_expect(second.ok and second.kind == "imported", "Repeating the same import succeeds")
	_expect(FileAccess.get_sha256(main_path) == main_hash, "Repeated import produces byte-identical farm data")
	_expect(FileAccess.get_sha256(identity_path) == identity_hash, "Repeated import keeps the same identity bytes")
	var reloaded: Dictionary = FarmStore.new(save).load_state()
	_expect(reloaded.farm == state.farm and reloaded.decorations == state.decorations, "Repeated import does not stack inventory or rewards")
	_expect(_tree(package) == package_tree, "Repeated import leaves the source package unchanged")


func _test_ambiguous(package_tree: Dictionary) -> void:
	var root: String = test_root.path_join("ambiguous-package")
	var first_world: String = root.path_join("worlds").path_join("world_a")
	var second_world: String = root.path_join("worlds").path_join("world_b")
	DirAccess.make_dir_recursive_absolute(first_world)
	DirAccess.make_dir_recursive_absolute(second_world)
	var text: String = _first_package_text(package_tree)
	_write(first_world.path_join("world.json"), text)
	_write(second_world.path_join("world.json"), text)
	var prepared: Dictionary = Transfer.prepare_import(root, test_root.path_join("ambiguous-save"))
	_expect(not prepared.ok and prepared.kind == "ambiguous", "A package root with two worlds is ambiguous")


func _import_into(package: String, save: String) -> Dictionary:
	var prepared: Dictionary = Transfer.prepare_import(package, save)
	if not prepared.ok:
		return prepared
	return Transfer.apply_import(prepared, save)


func _first_package_text(tree: Dictionary) -> String:
	for path: Variant in tree:
		if str(path).ends_with("world.json"):
			return FileAccess.get_file_as_string(test_root.path_join("package-a").path_join(str(path)))
	return ""


func _world_id(package: String) -> String:
	var worlds: PackedStringArray = DirAccess.get_directories_at(package.path_join("worlds"))
	return worlds[0] if worlds.size() == 1 else ""


func _make_save(folder: String, variant: int) -> Dictionary:
	var store := FarmStore.new(folder)
	var loaded: Dictionary = store.load_state()
	if loaded.kind != "missing":
		_expect(false, "Fixture save directory is admitted as missing: " + folder)
		return {"ok": false}
	var farm := Farm.new(START)
	farm.mature_all_crops(START)
	if variant == 0:
		farm.harvest("field_03", "cell_06", START)
	else:
		farm.harvest("field_04", "cell_06", START)
		farm.harvest("field_05", "cell_06", START)
	farm.settle(START + 3600.0)
	var decorations := Decorations.new()
	decorations.unlock(farm.snapshot().harvested)
	decorations.place("pot", "ground_04", 3 if variant == 0 else 1)
	var saved: Dictionary = store.save(farm.snapshot(), decorations.snapshot())
	# A second identical save leaves a real backup sidecar for the transfer to preserve.
	if saved.ok:
		saved = store.save(farm.snapshot(), decorations.snapshot())
	# A migrated world must take its social record with it.
	var social: Dictionary = SocialState.initial_state()
	SocialState.ensure_player(social, PLAYER_A, "阿青", START)
	SocialState.ensure_player(social, PLAYER_B, "小满", START)
	SocialState.invite(social, PLAYER_A, PLAYER_B, "小满", START)
	SocialState.accept(social, PLAYER_B, PLAYER_A, START)
	if saved.ok:
		saved = SocialStore.new(folder).save_state(social)
	return {"ok": saved.ok, "farm": farm.snapshot(), "decorations": decorations.snapshot()}


func _tree(path: String) -> Dictionary:
	var result: Dictionary = {}
	if DirAccess.dir_exists_absolute(path):
		_walk(path, path, result)
	return result


func _without_identity(tree: Dictionary) -> Dictionary:
	var copy: Dictionary = tree.duplicate()
	copy.erase("identity.json")
	return copy


func _walk(root: String, directory: String, result: Dictionary) -> void:
	for name: String in DirAccess.get_files_at(directory):
		var file: String = directory.path_join(name)
		result[file.trim_prefix(root + "/")] = FileAccess.get_sha256(file)
	for name: String in DirAccess.get_directories_at(directory):
		_walk(root, directory.path_join(name), result)


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null, "Fixture must be writable")
	file.store_string(text)
	file.close()


func _report() -> void:
	for failure: String in failures:
		push_error(failure)
	print("WORLD_TRANSFER_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
