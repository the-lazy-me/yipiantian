extends SceneTree

const Farm = preload("res://farm/farm_state.gd")
const World = preload("res://farm/world_package.gd")
const START: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join("../.local/verification/world-package-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_valid_roundtrip()
	_test_version_negotiation()
	_test_corrupt_and_truncated()
	_test_invalid_identifiers()
	_test_invalid_time_and_sequence()
	_test_invalid_money()
	_test_repeated_import()
	_test_original_bytes_untouched()
	for failure: String in failures:
		push_error(failure)
	print("WORLD_PACKAGE_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_valid_roundtrip() -> void:
	var package: Dictionary = _package()
	var before: Dictionary = package.duplicate(true)
	var serialized: Dictionary = World.serialize(package)
	_expect(package == before, "Validation and serialization do not mutate the caller's package")
	_expect(serialized.ok and serialized.kind == "serialized", "A valid package serializes")
	var parsed: Dictionary = World.parse(serialized.text)
	_expect(parsed.ok and parsed.kind == "parsed", "Serialized text parses back")
	_expect(parsed.package.snapshot == package.snapshot, "Roundtrip retains the complete farm snapshot")
	for field: String in ["world_id", "farm_id", "player_id", "device_id"]:
		_expect(parsed.package[field] == package[field], "Roundtrip retains " + field)
	_expect(parsed.package.money == package.money and parsed.package.committed_sequence == package.committed_sequence, "Roundtrip retains money and committed sequence")
	var reserialized: Dictionary = World.serialize(parsed.package)
	_expect(reserialized.ok and reserialized.text == serialized.text, "Canonical serialization is stable across a roundtrip")
	var boundary: Dictionary = _package()
	boundary.exported_at_utc_seconds = World.MAX_SAFE_INTEGER
	boundary.committed_sequence = World.MAX_SAFE_INTEGER
	boundary.money.minor_units = World.MAX_SAFE_INTEGER
	_expect(World.serialize(boundary).ok, "Maximum exact integer bounds are accepted")


func _test_version_negotiation() -> void:
	var newer_format: Dictionary = _package()
	newer_format.format_version = World.FORMAT_VERSION + 1
	var result: Dictionary = World.serialize(newer_format)
	_expect(not result.ok and result.kind == "newer_format", "Newer envelope version is rejected")
	_expect(World.parse(JSON.stringify(newer_format)).kind == "newer_format", "Newer envelope version is rejected on import")
	var older_format: Dictionary = _package()
	older_format.format_version = World.FORMAT_VERSION - 1
	_expect(World.serialize(older_format).kind == "unsupported_format", "Older envelope version has no migration")
	var float_format: Dictionary = _package()
	float_format.format_version = 1.5
	_expect(World.serialize(float_format).kind == "invalid_format_version", "Non-integral envelope version is rejected")
	var unknown: Dictionary = _package()
	unknown.format = "another.format"
	_expect(World.serialize(unknown).kind == "unknown_format", "Unknown package format is rejected")
	var newer_rules: Dictionary = _package()
	newer_rules.rules_version = World.RULES_VERSION + 1
	_expect(World.serialize(newer_rules).kind == "newer_rules", "Newer rules version is rejected")
	_expect(World.parse(JSON.stringify(newer_rules)).kind == "newer_rules", "Newer rules version is rejected on import")
	var older_rules: Dictionary = _package()
	older_rules.rules_version = World.RULES_VERSION - 1
	_expect(World.serialize(older_rules).kind == "unsupported_rules", "Older rules version has no migration")
	var bad_rules: Dictionary = _package()
	bad_rules.rules_version = "27"
	_expect(World.serialize(bad_rules).kind == "invalid_rules_version", "Non-integer rules version is rejected")


func _test_corrupt_and_truncated() -> void:
	_expect(World.parse("").kind == "corrupt", "Empty input is corrupt")
	_expect(World.parse("{").kind == "corrupt", "Truncated JSON is corrupt")
	_expect(World.parse("[]").kind == "corrupt", "Non-object JSON is corrupt")
	var serialized: Dictionary = World.serialize(_package())
	_expect(World.parse(serialized.text.substr(0, 80)).kind == "corrupt", "Truncated package text is corrupt")
	_expect(World.parse("x".repeat(World.MAX_BYTES + 1)).kind == "too_large", "Oversized input is rejected before parsing")
	var missing: Dictionary = _package()
	missing.erase("money")
	_expect(World.serialize(missing).kind == "corrupt", "Missing envelope field is corrupt")
	var extra: Dictionary = _package()
	extra["future_field"] = true
	_expect(World.serialize(extra).kind == "corrupt", "Unknown envelope field is corrupt")
	var bad_snapshot_type: Dictionary = _package()
	bad_snapshot_type.snapshot = []
	_expect(World.serialize(bad_snapshot_type).kind == "invalid_snapshot", "Non-object snapshot is rejected")
	var bad_snapshot: Dictionary = _package()
	bad_snapshot.snapshot.fields.erase("field_01")
	_expect(World.serialize(bad_snapshot).kind == "invalid_snapshot", "Snapshot that fails farm rules is rejected")
	_expect(World.parse(JSON.stringify(bad_snapshot)).kind == "invalid_snapshot", "Rejected snapshot is not admitted on import")


func _test_invalid_identifiers() -> void:
	var bad_ids: Array = [
		"", "has space", "../farm", "world/farm", "世界", 7, null,
		"a".repeat(World.MAX_IDENTIFIER_LENGTH + 1),
	]
	for field: String in ["world_id", "farm_id", "player_id", "device_id"]:
		for bad: Variant in bad_ids:
			var candidate: Dictionary = _package()
			candidate[field] = bad
			var result: Dictionary = World.serialize(candidate)
			_expect(not result.ok and result.kind == "invalid_identifier", "%s rejects %s" % [field, str(bad)])
	for value: String in ["world:alpha", "farm-home", "player.lin", "device_mac_01"]:
		var candidate: Dictionary = _package()
		candidate.world_id = value
		_expect(World.serialize(candidate).ok, "Opaque ASCII identifier is accepted: " + value)


func _test_invalid_time_and_sequence() -> void:
	var bad_integers: Array = [
		-1, 1.5, "1800000000", World.MAX_SAFE_INTEGER + 1, null, true,
	]
	for value: Variant in bad_integers:
		var bad_time: Dictionary = _package()
		bad_time.exported_at_utc_seconds = value
		_expect(World.serialize(bad_time).kind == "invalid_time", "Invalid export time is rejected: " + str(value))
		var bad_sequence: Dictionary = _package()
		bad_sequence.committed_sequence = value
		_expect(World.serialize(bad_sequence).kind == "invalid_sequence", "Invalid committed sequence is rejected: " + str(value))


func _test_invalid_money() -> void:
	var bad_money: Array = [
		{"currency": "COIN", "minor_units": 1.5},
		{"currency": "COIN", "minor_units": -1},
		{"currency": "COIN", "minor_units": World.MAX_SAFE_INTEGER + 1},
		{"currency": "coin", "minor_units": 0},
		{"currency": "", "minor_units": 0},
		{"currency": "COIN", "minor_units": "0"},
		{"currency": "COIN"},
		{"currency": "COIN", "minor_units": 0, "extra": 0},
		{},
		[],
	]
	for value: Variant in bad_money:
		var candidate: Dictionary = _package()
		candidate.money = value
		var result: Dictionary = World.serialize(candidate)
		_expect(not result.ok and result.kind == "invalid_money", "Invalid money is rejected: " + str(value))
	for value: int in [0, 1, World.MAX_SAFE_INTEGER]:
		var candidate: Dictionary = _package()
		candidate.money.minor_units = value
		_expect(World.serialize(candidate).ok, "Nonnegative integer money is accepted: " + str(value))


func _test_repeated_import() -> void:
	var serialized: Dictionary = World.serialize(_package())
	_expect(serialized.ok, "Repeated-import fixture is serializable")
	var baseline: Dictionary = World.parse(serialized.text)
	for _iteration: int in range(3):
		var repeated: Dictionary = World.parse(serialized.text)
		_expect(repeated.ok and repeated.package == baseline.package, "Repeated import yields identical package data")
		_expect(World.serialize(repeated.package).text == serialized.text, "Repeated import yields identical serialized text")


func _test_original_bytes_untouched() -> void:
	var folder: String = test_root.path_join("bytes")
	DirAccess.make_dir_recursive_absolute(folder)
	var package: Dictionary = _package()
	var newer_rules: Dictionary = package.duplicate(true)
	newer_rules.rules_version = World.RULES_VERSION + 1
	var cases: Array[Dictionary] = [
		{"name": "newer", "text": JSON.stringify(newer_rules), "kind": "newer_rules"},
		{"name": "truncated", "text": JSON.stringify(package).substr(0, 100), "kind": "corrupt"},
	]
	for entry: Dictionary in cases:
		var path: String = folder.path_join(entry.name + ".json")
		_write(path, entry.text)
		var before_text: String = FileAccess.get_file_as_string(path)
		var before_hash: String = FileAccess.get_sha256(path)
		var result: Dictionary = World.parse(before_text)
		_expect(not result.ok and result.kind == entry.kind, "Isolated import rejects " + entry.name)
		_expect(FileAccess.get_file_as_string(path) == before_text and FileAccess.get_sha256(path) == before_hash, "Rejected " + entry.name + " input bytes remain untouched")


func _package() -> Dictionary:
	var farm := Farm.new(START)
	farm.harvest("field_03", "cell_06", START)
	return {
		"format": World.FORMAT,
		"format_version": World.FORMAT_VERSION,
		"rules_version": World.RULES_VERSION,
		"world_id": "world_alpha",
		"farm_id": "farm_home",
		"player_id": "player_lin",
		"device_id": "device_mac_01",
		"exported_at_utc_seconds": 1800000000,
		"committed_sequence": 0,
		"money": {"currency": "COIN", "minor_units": 0},
		"snapshot": farm.snapshot(),
	}


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null, "Fixture must be writable")
	file.store_string(text)
	file.close()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
