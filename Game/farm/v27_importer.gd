extends RefCounted
## One-time v27 -> world package v1 import. Reads only the v27 main envelope,
## validates it through the existing farm/decoration owners, and writes an
## isolated identity/package/report under a caller-provided directory.
## The v27 source directory and the live save path are never written here.

const Farm = preload("res://farm/farm_state.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const DecorationCatalog = preload("res://farm/decoration_catalog.gd")
const WorldPackage = preload("res://farm/world_package.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const SocialStore = preload("res://social/social_store.gd")

const IDENTITY_FILE: String = "identity.json"
const WORLDS_DIRECTORY: String = "worlds"
const PACKAGE_FILE: String = "world.json"
const REPORT_FILE: String = "import-report.json"
const TEMP_SUFFIX: String = ".pending"
const IDENTITY_FORMAT: String = "yipiantian.import_identity"
const IDENTITY_VERSION: int = 1
const REPORT_FORMAT: String = "yipiantian.import_report"
const REPORT_VERSION: int = 1
const MONEY_CURRENCY: String = "COIN"
const MAX_IDENTITY_BYTES: int = 4096
const OFFICIAL_SAVE_DIRECTORY: String = "user://farm-v27"
const KNOWN_ENVELOPE_KEYS: Array[String] = ["version", "farm", "decorations"]
const KNOWN_FARM_KEYS: Array[String] = [
	"fields", "harvested", "inventory", "neighbors", "layout",
	"kitchen", "animals", "memories", "season", "transaction",
]
const KNOWN_DECORATION_KEYS: Array[String] = DecorationCatalog.IDS


static func import_v27(source_directory: String, output_root: String, identity_override: Dictionary = {}) -> Dictionary:
	var source: String = ProjectSettings.globalize_path(source_directory).simplify_path()
	var output: String = ProjectSettings.globalize_path(output_root).simplify_path()
	var safety: Dictionary = _safe_paths(source, output)
	if not safety.ok:
		return safety
	var loaded: Dictionary = _read_source(source)
	if not loaded.ok:
		return loaded
	var converted: Dictionary = _convert(loaded.data, loaded.sha256, loaded.bytes)
	if not converted.ok:
		return converted
	var identity: Dictionary = _load_or_create_identity(output, identity_override)
	if not identity.ok:
		return identity
	# Contacts and messages travel with the world. An unreadable social document
	# stops the export instead of being replaced by an empty one.
	var social: Dictionary = SocialStore.new(source).load_state()
	if not social.ok:
		return {"ok": false, "kind": "social_" + str(social.kind)}
	return _write_import(output, identity.identity, converted, social.state)


static func _safe_paths(source: String, output: String) -> Dictionary:
	if not source.is_absolute_path() or not output.is_absolute_path():
		return _failure("unsafe_path")
	if output.get_base_dir() == output:
		return _failure("unsafe_output")
	if source == output or output.begins_with(source + "/"):
		return _failure("unsafe_output")
	var official: String = ProjectSettings.globalize_path(OFFICIAL_SAVE_DIRECTORY).simplify_path()
	if output == official or output.begins_with(official + "/") or FileAccess.file_exists(output.path_join(FarmStore.MAIN)):
		return _failure("unsafe_output")
	if DirAccess.dir_exists_absolute(output) and _is_link(output):
		return _failure("unsafe_output")
	return {"ok": true}


static func _is_link(path: String) -> bool:
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())


static func _read_source(source_directory: String) -> Dictionary:
	var path: String = source_directory.path_join(FarmStore.MAIN)
	if not FileAccess.file_exists(path):
		return _failure("missing")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("io")
	var length: int = file.get_length()
	if length <= 0:
		file.close()
		return _failure("corrupt")
	if length > FarmStore.MAX_BYTES:
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
	return {
		"ok": true,
		"kind": "read",
		"data": json.data,
		"sha256": FileAccess.get_sha256(path),
		"bytes": length,
	}


static func _convert(raw: Dictionary, source_sha256: String, source_bytes: int) -> Dictionary:
	var unknown_fields: Array[Dictionary] = _unknown_fields(raw, KNOWN_ENVELOPE_KEYS, "")
	var version_value: Variant = raw.get("version")
	if not _integral(version_value):
		return _reject("corrupt", source_sha256, source_bytes, -1, unknown_fields)
	var version: int = int(version_value)
	if version > FarmStore.VERSION:
		return _reject("newer_version", source_sha256, source_bytes, version, unknown_fields)
	if version < FarmStore.VERSION:
		return _reject("unsupported_version", source_sha256, source_bytes, version, unknown_fields)
	var farm_value: Variant = raw.get("farm")
	var decorations_value: Variant = raw.get("decorations")
	if not farm_value is Dictionary or not decorations_value is Dictionary:
		return _reject("corrupt", source_sha256, source_bytes, version, unknown_fields)
	var farm_raw: Dictionary = farm_value
	var decorations_raw: Dictionary = decorations_value
	var sanitized_farm: Dictionary = _strip_unknown(farm_raw, KNOWN_FARM_KEYS, "farm", unknown_fields)
	var sanitized_decorations: Dictionary = _strip_unknown(decorations_raw, KNOWN_DECORATION_KEYS, "decorations", unknown_fields)
	var farm := Farm.new()
	if not farm.restore_snapshot(sanitized_farm):
		return _reject("invalid_farm", source_sha256, source_bytes, version, unknown_fields)
	var decorations := Decorations.new()
	if not decorations.restore_snapshot(sanitized_decorations):
		return _reject("invalid_decorations", source_sha256, source_bytes, version, unknown_fields)
	var farm_snapshot: Dictionary = farm.snapshot()
	var decorations_snapshot: Dictionary = decorations.snapshot()
	if not Farm.Kitchen.placement_valid(farm_snapshot.kitchen, decorations_snapshot):
		return _reject("invalid_decorations", source_sha256, source_bytes, version, unknown_fields)
	var exported_at: int = _latest_time(farm_snapshot)
	if exported_at < 0:
		return _reject("invalid_time", source_sha256, source_bytes, version, unknown_fields)
	var payload: Dictionary = {"farm": farm_snapshot, "decorations": decorations_snapshot}
	var content_text: String = WorldPackage.canonical_text(payload)
	return {
		"ok": true,
		"kind": "converted",
		"source_sha256": source_sha256,
		"source_bytes": source_bytes,
		"source_version": version,
		"content_sha256": _sha256_hex(content_text),
		"world_id": _sha256_hex("world\n" + content_text),
		"farm_id": _sha256_hex("farm\n" + content_text),
		"exported_at_utc_seconds": exported_at,
		"snapshot": farm_snapshot,
		"decorations": decorations_snapshot,
		"unknown_fields": _sorted_unknown(unknown_fields),
	}


static func _strip_unknown(source: Dictionary, known: Array[String], prefix: String, unknown_fields: Array[Dictionary]) -> Dictionary:
	var result: Dictionary = source.duplicate(true)
	for key: Variant in source.keys():
		if key is String and key in known:
			continue
		unknown_fields.append({"path": prefix + "." + str(key), "value": source[key]})
		result.erase(key)
	return result


static func _unknown_fields(source: Dictionary, known: Array[String], prefix: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for key: Variant in source.keys():
		if key is String and key in known:
			continue
		result.append({"path": str(key) if prefix.is_empty() else prefix + "." + str(key), "value": source[key]})
	return result


static func _latest_time(farm: Dictionary) -> int:
	var latest: float = 0.0
	for field_value: Variant in farm.fields.values():
		var field: Dictionary = field_value
		for cell_value: Variant in field.cells.values():
			var cell: Dictionary = cell_value
			latest = maxf(latest, float(cell.last_settled_utc_seconds))
	for job_value: Variant in farm.kitchen.jobs.values():
		var job: Dictionary = job_value
		if job.is_empty():
			continue
		latest = maxf(latest, float(job.start_utc))
		latest = maxf(latest, float(job.finish_utc))
	for mark: Variant in farm.memories.marks.values():
		latest = maxf(latest, float(mark))
	for photo_value: Variant in farm.memories.photos:
		var photo: Dictionary = photo_value
		latest = maxf(latest, float(photo.utc))
	if not is_finite(latest) or latest < 0.0 or latest > float(WorldPackage.MAX_SAFE_INTEGER):
		return -1
	return int(floor(latest))


static func create_identity() -> Dictionary:
	return {
		"format": IDENTITY_FORMAT,
		"version": IDENTITY_VERSION,
		"player_id": "player_" + Crypto.new().generate_random_bytes(16).hex_encode(),
		"device_id": "device_" + Crypto.new().generate_random_bytes(16).hex_encode(),
	}


static func read_identity(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _failure("missing_identity")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("invalid_identity")
	var length: int = file.get_length()
	if length <= 0 or length > MAX_IDENTITY_BYTES:
		file.close()
		return _failure("invalid_identity")
	var text: String = file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return _failure("invalid_identity")
	return _validated_identity(json.data)


static func _load_or_create_identity(output_root: String, identity_override: Dictionary = {}) -> Dictionary:
	var path: String = output_root.path_join(IDENTITY_FILE)
	if FileAccess.file_exists(path):
		var existing: Dictionary = read_identity(path)
		if not existing.ok:
			return existing
		if not identity_override.is_empty():
			var checked_override: Dictionary = _validated_identity(identity_override)
			if not checked_override.ok:
				return checked_override
			if existing.identity.player_id != checked_override.identity.player_id or existing.identity.device_id != checked_override.identity.device_id:
				return _failure("identity_conflict")
		return existing
	if not identity_override.is_empty():
		var checked: Dictionary = _validated_identity(identity_override)
		if not checked.ok:
			return checked
		var written_override: Dictionary = _write_atomic(path, WorldPackage.canonical_text(checked.identity, true))
		if not written_override.ok:
			return written_override
		return {"ok": true, "identity": checked.identity}
	var identity: Dictionary = create_identity()
	var written: Dictionary = _write_atomic(path, WorldPackage.canonical_text(identity, true))
	if not written.ok:
		return written
	return {"ok": true, "identity": identity}


static func _validated_identity(data: Dictionary) -> Dictionary:
	if data.size() != 4 or data.get("format") != IDENTITY_FORMAT:
		return _failure("invalid_identity")
	var version: Variant = data.get("version")
	if not _integral(version) or int(version) != IDENTITY_VERSION:
		return _failure("invalid_identity")
	var player_id: Variant = data.get("player_id")
	var device_id: Variant = data.get("device_id")
	if not WorldPackage.valid_identifier(player_id) or not WorldPackage.valid_identifier(device_id) or player_id == device_id:
		return _failure("invalid_identity")
	return {
		"ok": true,
		"identity": {
			"format": IDENTITY_FORMAT,
			"version": IDENTITY_VERSION,
			"player_id": player_id,
			"device_id": device_id,
		},
	}


static func _write_import(output_root: String, identity: Dictionary, converted: Dictionary,
		social: Dictionary) -> Dictionary:
	var package: Dictionary = {
		"format": WorldPackage.FORMAT,
		"format_version": WorldPackage.FORMAT_VERSION,
		"rules_version": WorldPackage.RULES_VERSION,
		"world_id": converted.world_id,
		"farm_id": converted.farm_id,
		"player_id": identity.player_id,
		"device_id": identity.device_id,
		"exported_at_utc_seconds": converted.exported_at_utc_seconds,
		"committed_sequence": 0,
		"money": {"currency": MONEY_CURRENCY, "minor_units": 0},
		"snapshot": converted.snapshot,
		"decorations": converted.decorations,
		"social": social,
	}
	var serialized: Dictionary = WorldPackage.serialize(package)
	if not serialized.ok:
		return {"ok": false, "kind": "invalid_package", "detail": serialized.kind}
	var report: Dictionary = _report(converted, identity)
	var world_directory: String = output_root.path_join(WORLDS_DIRECTORY).path_join(converted.world_id)
	var package_path: String = world_directory.path_join(PACKAGE_FILE)
	var report_path: String = world_directory.path_join(REPORT_FILE)
	var package_result: Dictionary = _store_if_identical(package_path, serialized.text)
	if not package_result.ok:
		return package_result
	var report_result: Dictionary = _store_if_identical(report_path, WorldPackage.canonical_text(report, true))
	if not report_result.ok:
		return report_result
	return {
		"ok": true,
		"kind": "imported",
		"changed": package_result.written or report_result.written,
		"world_id": converted.world_id,
		"farm_id": converted.farm_id,
		"package_path": package_path,
		"report_path": report_path,
		"source_sha256": converted.source_sha256,
		"package": package,
		"report": report,
	}


static func _report(converted: Dictionary, identity: Dictionary) -> Dictionary:
	return {
		"format": REPORT_FORMAT,
		"report_version": REPORT_VERSION,
		"source": {
			"sha256": converted.source_sha256,
			"bytes": converted.source_bytes,
			"version": converted.source_version,
		},
		"content_sha256": converted.content_sha256,
		"world_id": converted.world_id,
		"farm_id": converted.farm_id,
		"player_id": identity.player_id,
		"device_id": identity.device_id,
		"package": PACKAGE_FILE,
		"converted": ["version", "farm", "decorations"],
		"initialized": {
			"committed_sequence": 0,
			"money": {"currency": MONEY_CURRENCY, "minor_units": 0},
		},
		"exported_at_utc_seconds": converted.exported_at_utc_seconds,
		"unknown_fields": converted.unknown_fields,
		"notes": [
			"v27 has no money or committed sequence; both are initialized deterministically",
			"exported_at_utc_seconds is the latest logical UTC second in the normalized snapshot",
			"player_id and device_id are reused from identity.json",
			"world_id and farm_id are content-derived import deduplication keys, not long-term mutable world identities",
		],
	}


static func _store_if_identical(path: String, text: String) -> Dictionary:
	if FileAccess.file_exists(path):
		if FileAccess.get_file_as_string(path) == text:
			return {"ok": true, "written": false}
		return _failure("conflict")
	var written: Dictionary = _write_atomic(path, text)
	if not written.ok:
		return written
	return {"ok": true, "written": true}


static func _write_atomic(path: String, text: String) -> Dictionary:
	if FileAccess.file_exists(path):
		return _failure("exists")
	var directory: String = path.get_base_dir()
	var mkdir_error: Error = OK if DirAccess.dir_exists_absolute(directory) else DirAccess.make_dir_recursive_absolute(directory)
	if mkdir_error != OK:
		return _failure("create_directory")
	var temp: String = path + TEMP_SUFFIX
	if FileAccess.file_exists(temp):
		DirAccess.remove_absolute(temp)
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return _failure("write")
	file.store_string(text)
	file.flush()
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK:
		return _failure("flush")
	if FileAccess.get_file_as_string(temp) != text:
		return _failure("verify")
	var rename_error: Error = DirAccess.rename_absolute(temp, path)
	if rename_error != OK:
		return _failure("replace")
	if FileAccess.get_file_as_string(path) != text:
		return _failure("verify_final")
	return {"ok": true}


static func _reject(kind: String, source_sha256: String, source_bytes: int, version: int, unknown_fields: Array[Dictionary]) -> Dictionary:
	return {
		"ok": false,
		"kind": kind,
		"report": {
			"format": REPORT_FORMAT,
			"report_version": REPORT_VERSION,
			"source": {
				"sha256": source_sha256,
				"bytes": source_bytes,
				"version": version,
			},
			"unknown_fields": _sorted_unknown(unknown_fields),
		},
	}


static func _sorted_unknown(unknown_fields: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = unknown_fields.duplicate(true)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.path) < str(b.path))
	return result


static func _integral(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number == floorf(number)


static func _sha256_hex(text: String) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(text.to_utf8_buffer())
	return context.finish().hex_encode()


static func _failure(kind: String) -> Dictionary:
	return {"ok": false, "kind": kind}
