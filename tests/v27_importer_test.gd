extends SceneTree

const Farm = preload("res://farm/farm_state.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const World = preload("res://farm/world_package.gd")
const Importer = preload("res://farm/v27_importer.gd")
const START: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []
var test_root: String
var source_dir: String
var source_farm: Dictionary
var source_decorations: Dictionary
var expected_exported_at: int


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join("../.local/verification/v27-import-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	source_dir = test_root.path_join("source")
	if not _build_source():
		_report()
		return
	var source_path: String = source_dir.path_join(FarmStore.MAIN)
	var source_sha: String = FileAccess.get_sha256(source_path)
	var source_text: String = FileAccess.get_file_as_string(source_path)
	var output_root: String = test_root.path_join("output")
	var first: Dictionary = Importer.import_v27(source_dir, output_root)
	_expect(first.ok and first.kind == "imported" and first.changed, "First import succeeds and writes output")
	_expect(FileAccess.get_file_as_string(source_path) == source_text and FileAccess.get_sha256(source_path) == source_sha, "First import leaves the v27 source bytes and SHA-256 unchanged")
	var source_files: PackedStringArray = DirAccess.get_files_at(source_dir)
	_expect(source_files.size() == 1 and source_files[0] == FarmStore.MAIN, "Import writes nothing into the v27 source directory")
	if first.ok:
		_test_package(first, source_sha)
		_test_report(first, source_sha)
		_test_second_import(first, source_path, source_sha)
	_test_rejections()
	_test_unknown_fields()
	_test_nested_unknown_rejected()
	_report()


func _build_source() -> bool:
	DirAccess.make_dir_recursive_absolute(source_dir)
	var store := FarmStore.new(source_dir)
	if store.load_state().kind != "missing":
		_expect(false, "Fixture source directory is admitted as missing")
		return false
	var farm := Farm.new(START)
	farm.mature_all_crops(START)
	var ok: bool = true
	ok = farm.harvest("field_03", "cell_06", START).ok and ok
	ok = farm.harvest("field_04", "cell_06", START).ok and ok
	ok = farm.harvest("field_05", "cell_06", START).ok and ok
	var decorations := Decorations.new()
	ok = farm.kitchen_action("start", {"recipe": "leaf_stir", "crop": "greens"}, 0, START, decorations.snapshot()).ok and ok
	ok = farm.share_basket("willow", 0, {"greens": 1}).ok and ok
	ok = farm.claim_gift("willow", 0, "radish").ok and ok
	farm.settle(START + 3600.0)
	decorations.unlock(farm.snapshot().harvested)
	ok = decorations.place("pot", "ground_04", 3).ok and ok
	ok = store.save(farm.snapshot(), decorations.snapshot()).ok and ok
	_expect(ok, "Fixture performs farming, kitchen, neighbour, decoration and time actions")
	source_farm = farm.snapshot()
	source_decorations = decorations.snapshot()
	expected_exported_at = int(START + 3600.0)
	return ok


func _test_package(first: Dictionary, source_sha: String) -> void:
	var package: Dictionary = first.package
	var parsed: Dictionary = World.parse(FileAccess.get_file_as_string(first.package_path))
	_expect(parsed.ok, "Imported package validates through the v1 parser")
	_expect(parsed.package == package, "Parsed package equals the returned package")
	_expect(package.format_version == 1 and package.rules_version == FarmStore.VERSION, "Imported package uses format v1 and rules v27")
	_expect(package.exported_at_utc_seconds == expected_exported_at, "Package time is the latest logical snapshot second")
	_expect(package.committed_sequence == 0, "Missing v27 sequence is initialized to zero")
	_expect(package.money == {"currency": "COIN", "minor_units": 0}, "Missing v27 money is initialized to zero")
	_expect(package.snapshot.fields == source_farm.fields, "Fields match the v27 snapshot")
	_expect(package.snapshot.inventory == source_farm.inventory, "Inventory matches the v27 snapshot")
	_expect(package.snapshot.harvested == source_farm.harvested, "Harvested counts match the v27 snapshot")
	_expect(package.snapshot.neighbors == source_farm.neighbors, "Neighbours match the v27 snapshot")
	_expect(package.snapshot.layout == source_farm.layout, "Layout matches the v27 snapshot")
	_expect(package.snapshot.kitchen == source_farm.kitchen, "Kitchen state and job times match the v27 snapshot")
	_expect(package.snapshot.animals == source_farm.animals, "Animal state matches the v27 snapshot")
	_expect(package.snapshot.memories == source_farm.memories, "Memory state matches the v27 snapshot")
	_expect(package.snapshot.season == source_farm.season, "Season matches the v27 snapshot")
	_expect(package.decorations == source_decorations, "Decorations match the v27 snapshot")
	_expect(package.snapshot.inventory.greens == 0 and package.snapshot.inventory.radish == 2, "Specific inventory counts survive conversion")
	_expect(package.snapshot.harvested.greens == 2 and package.snapshot.harvested.radish == 1, "Specific harvested counts survive conversion")
	_expect(package.snapshot.neighbors.willow.round == 1 and package.snapshot.neighbors.willow.last_gift == "radish", "Neighbour round and gift survive conversion")
	_expect(package.decorations.pot.slot_id == "ground_04" and package.decorations.pot.quarter_turn == 3, "Placed decoration survives conversion")
	_expect(is_equal_approx(package.snapshot.fields.field_01.cells.cell_01.last_settled_utc_seconds, START + 3600.0), "Cell settlement time survives conversion")
	_expect(is_equal_approx(package.snapshot.kitchen.jobs.stove.start_utc, START) and is_equal_approx(package.snapshot.kitchen.jobs.stove.finish_utc, START + 20.0), "Kitchen job times survive conversion")
	_expect(package.world_id.length() == 64 and package.farm_id.length() == 64, "Content-derived identifiers are full SHA-256 hex")
	_expect(package.world_id != package.farm_id, "World and farm identifiers are domain-separated")
	var content_text: String = World.canonical_text({"farm": source_farm, "decorations": source_decorations})
	_expect(package.world_id == _sha256("world\n" + content_text), "World ID derives from normalized snapshot content")
	_expect(package.farm_id == _sha256("farm\n" + content_text), "Farm ID derives from normalized snapshot content")
	var identity: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(test_root.path_join("output").path_join("identity.json")))
	_expect(identity.player_id == package.player_id and identity.device_id == package.device_id, "Package uses the persisted import identity")
	_expect(World.valid_identifier(identity.player_id) and World.valid_identifier(identity.device_id), "Persisted identity values are valid identifiers")
	_expect(identity.player_id != identity.device_id, "Player and device identities remain distinct")
	_expect(identity.player_id.begins_with("player_") and identity.device_id.begins_with("device_"), "Identity values are generated tokens, not paths")
	_expect(first.source_sha256 == source_sha, "Result reports the original source SHA-256")


func _test_report(first: Dictionary, source_sha: String) -> void:
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(first.report_path))
	_expect(report.format == "yipiantian.import_report" and report.report_version == 1, "Conversion report has a fixed format")
	_expect(report.source.sha256 == source_sha and report.source.version == FarmStore.VERSION, "Report records the source digest and version")
	_expect(report.world_id == first.world_id and report.farm_id == first.farm_id, "Report records the derived identities")
	_expect(report.unknown_fields.is_empty(), "Clean v27 source has no unknown fields")
	_expect(report.initialized.money.currency == "COIN" and int(report.initialized.money.minor_units) == 0, "Report explains the initialized money")
	_expect(report.initialized.committed_sequence == 0, "Report explains the initialized sequence")
	_expect(report.exported_at_utc_seconds == expected_exported_at, "Report records the derived package time")
	_expect(report.content_sha256.length() == 64, "Report includes the canonical content digest")


func _test_second_import(first: Dictionary, source_path: String, source_sha: String) -> void:
	var package_sha: String = FileAccess.get_sha256(first.package_path)
	var report_sha: String = FileAccess.get_sha256(first.report_path)
	var identity_path: String = test_root.path_join("output").path_join("identity.json")
	var identity_sha: String = FileAccess.get_sha256(identity_path)
	var second: Dictionary = Importer.import_v27(source_dir, test_root.path_join("output"))
	_expect(second.ok and second.kind == "imported" and not second.changed, "Second import is idempotent and writes nothing")
	_expect(second.world_id == first.world_id and second.farm_id == first.farm_id, "Second import derives the same identifiers")
	_expect(second.package == first.package, "Second import produces the same package data")
	_expect(second.report == first.report, "Second import produces the same report data")
	_expect(FileAccess.get_sha256(first.package_path) == package_sha, "Second import leaves package bytes identical")
	_expect(FileAccess.get_sha256(first.report_path) == report_sha, "Second import leaves report bytes identical")
	_expect(FileAccess.get_sha256(identity_path) == identity_sha, "Second import reuses the identity file")
	_expect(FileAccess.get_sha256(source_path) == source_sha, "Second import leaves the v27 source unchanged")
	var worlds: PackedStringArray = DirAccess.get_directories_at(test_root.path_join("output").path_join("worlds"))
	_expect(worlds.size() == 1 and worlds[0] == first.world_id, "Repeated import does not create a second world directory")
	var reloaded: Dictionary = World.parse(FileAccess.get_file_as_string(first.package_path))
	_expect(reloaded.ok and reloaded.package.snapshot.inventory.radish == 2, "Repeated import does not stack inventory")


func _test_rejections() -> void:
	var newer_dir: String = test_root.path_join("source-newer")
	DirAccess.make_dir_recursive_absolute(newer_dir)
	var newer_path: String = newer_dir.path_join(FarmStore.MAIN)
	_write(newer_path, JSON.stringify({"version": FarmStore.VERSION + 1, "farm": source_farm, "decorations": source_decorations}))
	var newer_sha: String = FileAccess.get_sha256(newer_path)
	var newer: Dictionary = Importer.import_v27(newer_dir, test_root.path_join("output-newer"))
	_expect(not newer.ok and newer.kind == "newer_version", "Newer v27 version is rejected")
	_expect(FileAccess.get_sha256(newer_path) == newer_sha, "Rejected newer source is unchanged")
	_expect(not DirAccess.dir_exists_absolute(test_root.path_join("output-newer").path_join("worlds")), "Rejected newer source writes no world")
	var older_dir: String = test_root.path_join("source-older")
	DirAccess.make_dir_recursive_absolute(older_dir)
	_write(older_dir.path_join(FarmStore.MAIN), JSON.stringify({"version": FarmStore.VERSION - 1, "farm": source_farm, "decorations": source_decorations}))
	_expect(Importer.import_v27(older_dir, test_root.path_join("output-older")).kind == "unsupported_version", "Older v27 version has no migration")
	var corrupt_dir: String = test_root.path_join("source-corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	var corrupt_path: String = corrupt_dir.path_join(FarmStore.MAIN)
	_write(corrupt_path, "{truncated")
	var corrupt_sha: String = FileAccess.get_sha256(corrupt_path)
	var corrupt: Dictionary = Importer.import_v27(corrupt_dir, test_root.path_join("output-corrupt"))
	_expect(not corrupt.ok and corrupt.kind == "corrupt", "Truncated v27 source is rejected")
	_expect(FileAccess.get_sha256(corrupt_path) == corrupt_sha, "Rejected corrupt source is unchanged")
	var missing: Dictionary = Importer.import_v27(test_root.path_join("no-such-source"), test_root.path_join("output-missing"))
	_expect(not missing.ok and missing.kind == "missing", "Missing v27 source is rejected without creating output")
	var invalid_dir: String = test_root.path_join("source-invalid-farm")
	DirAccess.make_dir_recursive_absolute(invalid_dir)
	var invalid_farm: Dictionary = source_farm.duplicate(true)
	invalid_farm.fields.erase("field_01")
	_write(invalid_dir.path_join(FarmStore.MAIN), JSON.stringify({"version": FarmStore.VERSION, "farm": invalid_farm, "decorations": source_decorations}))
	_expect(Importer.import_v27(invalid_dir, test_root.path_join("output-invalid-farm")).kind == "invalid_farm", "Invalid farm schema is rejected")


func _test_unknown_fields() -> void:
	var unknown_dir: String = test_root.path_join("source-unknown")
	DirAccess.make_dir_recursive_absolute(unknown_dir)
	var raw: Dictionary = {
		"version": FarmStore.VERSION,
		"farm": source_farm.duplicate(true),
		"decorations": source_decorations.duplicate(true),
		"legacy_note": {"kept": "in report"},
	}
	raw.farm["legacy_flag"] = true
	raw.decorations["legacy_deco"] = {"kept": "in report"}
	_write(unknown_dir.path_join(FarmStore.MAIN), JSON.stringify(raw))
	var result: Dictionary = Importer.import_v27(unknown_dir, test_root.path_join("output-unknown"))
	_expect(result.ok and result.changed, "Unknown keys are reported while known state still imports")
	var paths: Array[String] = []
	for entry: Dictionary in result.report.unknown_fields:
		paths.append(entry.path)
	_expect("legacy_note" in paths and "farm.legacy_flag" in paths and "decorations.legacy_deco" in paths, "Report lists top-level, farm-level and decoration-level unknown keys")
	_expect(not result.package.has("legacy_note") and not result.package.snapshot.has("legacy_flag") and not result.package.decorations.has("legacy_deco"), "Unknown keys are not copied into the world package")
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(result.report_path))
	_expect(report.unknown_fields.size() == 3, "Written report preserves all unknown field entries")
	var flag_preserved: bool = false
	for entry: Dictionary in report.unknown_fields:
		if entry.path == "farm.legacy_flag" and entry.value == true:
			flag_preserved = true
	_expect(flag_preserved, "Unknown field values are preserved in the report")


func _test_nested_unknown_rejected() -> void:
	var nested_dir: String = test_root.path_join("source-nested")
	DirAccess.make_dir_recursive_absolute(nested_dir)
	var nested: Dictionary = {
		"version": FarmStore.VERSION,
		"farm": source_farm.duplicate(true),
		"decorations": source_decorations.duplicate(true),
	}
	nested.farm.fields.field_01.cells.cell_01["legacy_cell"] = 1
	var path: String = nested_dir.path_join(FarmStore.MAIN)
	_write(path, JSON.stringify(nested))
	var sha: String = FileAccess.get_sha256(path)
	var result: Dictionary = Importer.import_v27(nested_dir, test_root.path_join("output-nested"))
	_expect(not result.ok and result.kind == "invalid_farm", "Nested unknown keys are rejected instead of guessed")
	_expect(FileAccess.get_sha256(path) == sha, "Rejected nested-unknown source is unchanged")


func _sha256(text: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(text.to_utf8_buffer())
	return context.finish().hex_encode()


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null, "Fixture must be writable")
	file.store_string(text)
	file.close()


func _report() -> void:
	for failure: String in failures:
		push_error(failure)
	print("V27_IMPORTER_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
