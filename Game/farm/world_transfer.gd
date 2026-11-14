extends RefCounted
## Runtime world transfer around the live v27 save.
##
## Export converts the live save through the existing v27 importer. Import
## validates a package without writing anything, then (only when the caller
## applies the prepared result) backs up the live save and replaces it through
## FarmStore's verified temporary-file rename. The package directory is never
## written during import.

const Importer = preload("res://farm/v27_importer.gd")
const WorldPackage = preload("res://farm/world_package.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const SocialStore = preload("res://social/social_store.gd")
const NatureStore = preload("res://farm/nature_store.gd")

const PACKAGE_FILE: String = Importer.PACKAGE_FILE
const WORLDS_DIRECTORY: String = Importer.WORLDS_DIRECTORY
const IDENTITY_FILE: String = Importer.IDENTITY_FILE
const BACKUP_DIRECTORY: String = "import-backups"
const IDENTITY_PENDING: String = "identity.import.pending.json"
const BACKUP_FILES: Array[String] = [
	FarmStore.MAIN, FarmStore.BACKUP, FarmStore.PENDING,
	FarmStore.BACKUP_PENDING, Importer.IDENTITY_FILE, SocialStore.MAIN,
	NatureStore.MAIN,
]


static func export_world(save_directory: String, target_directory: String) -> Dictionary:
	var save: String = _normalize(save_directory)
	var target: String = _normalize(target_directory)
	if not DirAccess.dir_exists_absolute(save):
		_log("export", "missing")
		return _failure("missing")
	var safety: Dictionary = _safe_export_paths(save, target)
	if not safety.ok:
		_log("export", safety.kind)
		return safety
	# Read the natural document before anything is written. A missing document
	# means the fixed default seed (never a fresh roll); a corrupt or newer one
	# stops the export instead of silently replacing the world's weather history.
	var nature: Dictionary = NatureStore.new(save).load_state()
	if not nature.ok:
		var nature_kind: String = "nature_" + str(nature.kind)
		_log("export", nature_kind)
		return _failure(nature_kind)
	var identity: Dictionary = _ensure_live_identity(save)
	if not identity.ok:
		_log("export", identity.kind)
		return identity
	var result: Dictionary = Importer.import_v27(save, target, identity.identity, nature.state)
	if not result.ok:
		_log("export", result.kind)
		return result
	var summary: Dictionary = {
		"world_id": result.world_id,
		"farm_id": result.farm_id,
		"player_id": result.package.player_id,
		"device_id": result.package.device_id,
		"exported_at_utc_seconds": int(result.package.exported_at_utc_seconds),
		"package_path": result.package_path,
		"output_directory": target,
		"changed": bool(result.changed),
	}
	_log("export", "ok")
	return {
		"ok": true,
		"kind": "exported",
		"changed": result.changed,
		"package": result.package,
		"package_path": result.package_path,
		"summary": summary,
	}


static func prepare_import(package_source: String, save_directory: String) -> Dictionary:
	var source: String = _normalize(package_source)
	var save: String = _normalize(save_directory)
	var safety: Dictionary = _safe_import_paths(source, save)
	if not safety.ok:
		_log("prepare", safety.kind)
		return safety
	var located: Dictionary = _locate_package(source)
	if not located.ok:
		_log("prepare", located.kind)
		return located
	var read: Dictionary = _read_package(located.path)
	if not read.ok:
		_log("prepare", read.kind)
		return read
	var package: Dictionary = read.package
	var identity_check: Dictionary = _check_package_identity(located.package_root, package)
	if not identity_check.ok:
		_log("prepare", identity_check.kind)
		return identity_check
	var has_existing: bool = FileAccess.file_exists(save.path_join(FarmStore.MAIN))
	var backup_path: String = "" if not has_existing else _next_backup_path(save, package.world_id)
	var summary: Dictionary = {
		"world_id": package.world_id,
		"farm_id": package.farm_id,
		"player_id": package.player_id,
		"device_id": package.device_id,
		"exported_at_utc_seconds": int(package.exported_at_utc_seconds),
		"package_path": located.path,
		"package_directory": located.package_root,
		"backup_path": backup_path,
		"has_existing_save": has_existing,
	}
	_log("prepare", "ready")
	return {
		"ok": true,
		"kind": "ready",
		"package_path": located.path,
		"package_directory": located.package_root,
		"source_directory": source,
		"save_directory": save,
		"sha256": FileAccess.get_sha256(located.path),
		"package": package,
		"summary": summary,
	}


static func apply_import(prepared: Dictionary, save_directory: String) -> Dictionary:
	if not prepared.get("ok", false) or prepared.get("kind", "") != "ready":
		return _failure("invalid_preparation")
	var save: String = _normalize(save_directory)
	if save.is_empty() or save != prepared.save_directory:
		return _failure("changed_path")
	var safety: Dictionary = _safe_import_paths(prepared.source_directory, save)
	if not safety.ok:
		_log("import", safety.kind)
		return safety
	var path: String = prepared.package_path
	if not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != prepared.sha256:
		_log("import", "package_changed")
		return _failure("package_changed")
	var read: Dictionary = _read_package(path)
	if not read.ok:
		_log("import", read.kind)
		return read
	var package: Dictionary = read.package
	var identity_check: Dictionary = _check_package_identity(prepared.package_directory, package)
	if not identity_check.ok:
		_log("import", identity_check.kind)
		return identity_check
	var store := FarmStore.new(save)
	var state: Dictionary = store.load_state()
	if not state.ok:
		_log("import", state.kind)
		return {"ok": false, "kind": state.kind, "backup_path": ""}
	var backup: Dictionary = _backup_current(save, prepared.summary.get("backup_path", ""))
	if not backup.ok:
		_log("import", backup.kind)
		return backup
	# FarmStore owns validation, admission and the verified temp-file rename.
	var written: Dictionary = store.save(package.snapshot, package.decorations)
	if not written.ok:
		_log("import", written.kind)
		return {"ok": false, "kind": written.kind, "backup_path": backup.path}
	var reloaded := FarmStore.new(save).load_state()
	if not reloaded.ok or reloaded.farm != package.snapshot or reloaded.decorations != package.decorations:
		var restored: bool = _restore_backup(save, backup.path)
		_log("import", "verify_import")
		return {"ok": false, "kind": "verify_import", "backup_path": backup.path, "restored": restored}
	var identity_saved: bool = _write_live_identity(save, package.player_id, package.device_id).ok
	# Social data is a second document, so it is written after the farm has been
	# verified. A failure restores the backup rather than leaving a world whose
	# contacts belong to a different farm.
	var social_saved: Dictionary = SocialStore.new(save).save_state(package.social)
	if not social_saved.ok:
		var rolled_back: bool = _restore_backup(save, backup.path)
		_log("import", "social_" + str(social_saved.kind))
		return {"ok": false, "kind": "social_" + str(social_saved.kind),
			"backup_path": backup.path, "restored": rolled_back}
	# The natural document is the third sidecar. Importing replaces the whole
	# world, so a differing existing seed follows the same backup-then-replace
	# rule as the farm and social documents, while an identical document is not
	# rewritten. A missing document is written explicitly, matching the export
	# semantics that read it as the fixed default seed.
	var nature_store := NatureStore.new(save)
	var existing_nature: Dictionary = nature_store.load_state()
	var nature_saved: bool = existing_nature.ok and existing_nature.kind == "loaded" \
		and existing_nature.state == package.nature
	var nature_written: bool = false
	if not nature_saved:
		var wrote_nature: Dictionary = nature_store.save_state(package.nature)
		if not wrote_nature.ok:
			var nature_rolled_back: bool = _restore_backup(save, backup.path)
			_log("import", "nature_" + str(wrote_nature.kind))
			return {"ok": false, "kind": "nature_" + str(wrote_nature.kind),
				"backup_path": backup.path, "restored": nature_rolled_back}
		var verified_nature: Dictionary = NatureStore.new(save).load_state()
		if not verified_nature.ok or verified_nature.state != package.nature:
			var verify_rolled_back: bool = _restore_backup(save, backup.path)
			_log("import", "verify_nature")
			return {"ok": false, "kind": "verify_nature", "backup_path": backup.path,
				"restored": verify_rolled_back}
		nature_saved = true
		nature_written = true
	var summary: Dictionary = prepared.summary.duplicate(true)
	summary["backup_path"] = backup.path
	summary["identity_saved"] = identity_saved
	summary["nature_saved"] = nature_saved
	summary["nature_written"] = nature_written
	_log("import", "ok")
	return {
		"ok": true,
		"kind": "imported",
		"summary": summary,
		"backup_path": backup.path,
		"identity_saved": identity_saved,
	}


static func _safe_export_paths(save: String, target: String) -> Dictionary:
	if save.is_empty() or target.is_empty():
		return _failure("unsafe_path")
	if not save.is_absolute_path() or not target.is_absolute_path():
		return _failure("unsafe_path")
	if target.get_base_dir() == target:
		return _failure("unsafe_output")
	if _same_or_inside(target, save) or _same_or_inside(save, target):
		return _failure("unsafe_output")
	if DirAccess.dir_exists_absolute(target):
		if _is_link(target):
			return _failure("unsafe_output")
		if not _directory_clear(target):
			return _failure("existing_output")
	elif FileAccess.file_exists(target):
		return _failure("unsafe_output")
	return {"ok": true}


static func _safe_import_paths(source: String, save: String) -> Dictionary:
	if source.is_empty() or save.is_empty():
		return _failure("unsafe_path")
	if not source.is_absolute_path() or not save.is_absolute_path():
		return _failure("unsafe_path")
	if _same_or_inside(source, save) or _same_or_inside(save, source):
		return _failure("unsafe_output")
	var source_is_file: bool = FileAccess.file_exists(source)
	var source_is_directory: bool = DirAccess.dir_exists_absolute(source)
	if not source_is_file and not source_is_directory:
		return _failure("missing")
	if source_is_directory and _is_link(source):
		return _failure("unsafe_path")
	if FileAccess.file_exists(save):
		return _failure("unsafe_output")
	if DirAccess.dir_exists_absolute(save) and _is_link(save):
		return _failure("unsafe_path")
	return {"ok": true}


static func _locate_package(source: String) -> Dictionary:
	if FileAccess.file_exists(source):
		if source.get_extension().to_lower() != "json":
			return _failure("missing")
		return {"ok": true, "path": source, "package_root": source.get_base_dir()}
	if not DirAccess.dir_exists_absolute(source):
		return _failure("missing")
	if FileAccess.file_exists(source.path_join(PACKAGE_FILE)):
		return {"ok": true, "path": source.path_join(PACKAGE_FILE), "package_root": source}
	var worlds: String = source.path_join(WORLDS_DIRECTORY)
	if not DirAccess.dir_exists_absolute(worlds):
		return _failure("missing")
	var found: Array[String] = []
	for name: String in DirAccess.get_directories_at(worlds):
		var candidate: String = worlds.path_join(name).path_join(PACKAGE_FILE)
		if FileAccess.file_exists(candidate):
			found.append(candidate)
	if found.size() == 1:
		var path: String = found[0]
		return {"ok": true, "path": path, "package_root": path.get_base_dir()}
	if found.size() > 1:
		return _failure("ambiguous")
	return _failure("missing")


static func _read_package(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("io")
	var length: int = file.get_length()
	if length <= 0:
		file.close()
		return _failure("corrupt")
	if length > WorldPackage.MAX_BYTES:
		file.close()
		return _failure("too_large")
	var text: String = file.get_as_text()
	var read_error: Error = file.get_error()
	file.close()
	if read_error != OK and read_error != ERR_FILE_EOF:
		return _failure("io")
	var parsed: Dictionary = WorldPackage.parse(text)
	if not parsed.ok:
		return parsed
	return {"ok": true, "package": parsed.package}


static func _check_package_identity(package_root: String, package: Dictionary) -> Dictionary:
	# identity.json mirrors the envelope identity for export/import continuity.
	# It is optional, but a present, invalid or mismatched file rejects the pack.
	var directory: String = package_root
	for _depth: int in 3:
		var candidate: String = directory.path_join(IDENTITY_FILE)
		if FileAccess.file_exists(candidate):
			var identity: Dictionary = Importer.read_identity(candidate)
			if not identity.ok:
				return _failure("invalid_identity")
			if identity.identity.player_id != package.player_id or identity.identity.device_id != package.device_id:
				return _failure("identity_mismatch")
			return {"ok": true}
		var parent: String = directory.get_base_dir()
		if parent == directory:
			break
		directory = parent
	return {"ok": true}


static func _ensure_live_identity(save: String) -> Dictionary:
	# The first export establishes the missing identity in the live save so that
	# later exports keep the same player and device instead of drawing new ones.
	var path: String = save.path_join(IDENTITY_FILE)
	if FileAccess.file_exists(path):
		var identity: Dictionary = Importer.read_identity(path)
		if not identity.ok:
			return _failure("invalid_identity")
		return identity
	var created: Dictionary = Importer.create_identity()
	var written: Dictionary = _write_live_identity(save, created.player_id, created.device_id)
	if not written.ok:
		return written
	return {"ok": true, "identity": created}


static func _next_backup_path(save: String, world_id: String) -> String:
	var root: String = save.path_join(BACKUP_DIRECTORY)
	var base: String = "world-" + world_id.substr(0, 12)
	var candidate: String = root.path_join(base)
	var index: int = 2
	while DirAccess.dir_exists_absolute(candidate):
		candidate = root.path_join(base + "-" + str(index))
		index += 1
	return candidate


static func _backup_current(save: String, preferred: String) -> Dictionary:
	var existing: Array[String] = []
	for name: String in BACKUP_FILES:
		var path: String = save.path_join(name)
		if DirAccess.dir_exists_absolute(path) or (FileAccess.file_exists(path) and _is_link(path)):
			return _failure("io")
		if FileAccess.file_exists(path):
			existing.append(name)
	if existing.is_empty():
		return {"ok": true, "path": ""}
	var root: String = save.path_join(BACKUP_DIRECTORY)
	if DirAccess.dir_exists_absolute(root) and _is_link(root):
		return _failure("unsafe_output")
	var mkdir_error: Error = OK if DirAccess.dir_exists_absolute(root) else DirAccess.make_dir_recursive_absolute(root)
	if mkdir_error != OK:
		return _failure("create_backup")
	var final_path: String = _unique_backup_path(root, preferred)
	var pending: String = root.path_join(".pending-" + final_path.get_file())
	if _is_link(pending):
		return _failure("unsafe_output")
	_remove_tree(pending)
	mkdir_error = DirAccess.make_dir_recursive_absolute(pending)
	if mkdir_error != OK:
		return _failure("create_backup")
	for name: String in existing:
		var from: String = save.path_join(name)
		var to: String = pending.path_join(name)
		var copy_error: Error = DirAccess.copy_absolute(from, to)
		if copy_error != OK or not FileAccess.file_exists(to) or FileAccess.get_sha256(from) != FileAccess.get_sha256(to):
			_remove_tree(pending)
			return _failure("backup_copy")
	var rename_error: Error = DirAccess.rename_absolute(pending, final_path)
	if rename_error != OK:
		_remove_tree(pending)
		return _failure("backup_replace")
	return {"ok": true, "path": final_path}


static func _unique_backup_path(root: String, preferred: String) -> String:
	if not preferred.is_empty() and _same_or_inside(preferred, root) and not DirAccess.dir_exists_absolute(preferred):
		return preferred
	var base: String = root.path_join("import")
	var candidate: String = base
	var index: int = 2
	while DirAccess.dir_exists_absolute(candidate):
		candidate = root.path_join("import-" + str(index))
		index += 1
	return candidate


static func _restore_backup(save: String, backup_path: String) -> bool:
	var ok: bool = true
	for name: String in BACKUP_FILES:
		var target: String = save.path_join(name)
		if FileAccess.file_exists(target) and _is_link(target):
			ok = false
			continue
		var source: String = backup_path.path_join(name) if not backup_path.is_empty() else ""
		if not source.is_empty() and FileAccess.file_exists(source):
			var copy_error: Error = DirAccess.copy_absolute(source, target)
			if copy_error != OK or FileAccess.get_sha256(source) != FileAccess.get_sha256(target):
				ok = false
		elif FileAccess.file_exists(target) and DirAccess.remove_absolute(target) != OK:
			ok = false
	return ok


static func _write_live_identity(save: String, player_id: String, device_id: String) -> Dictionary:
	var identity: Dictionary = {
		"format": Importer.IDENTITY_FORMAT,
		"version": Importer.IDENTITY_VERSION,
		"player_id": player_id,
		"device_id": device_id,
	}
	var text: String = WorldPackage.canonical_text(identity, true)
	var path: String = save.path_join(IDENTITY_FILE)
	if FileAccess.file_exists(path) and _is_link(path):
		return _failure("identity_write")
	if FileAccess.file_exists(path) and FileAccess.get_file_as_string(path) == text:
		return {"ok": true}
	var temp: String = save.path_join(IDENTITY_PENDING)
	if _is_link(temp):
		return _failure("identity_write")
	if FileAccess.file_exists(temp) and DirAccess.remove_absolute(temp) != OK:
		return _failure("identity_write")
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return _failure("identity_write")
	file.store_string(text)
	file.flush()
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK or FileAccess.get_file_as_string(temp) != text:
		DirAccess.remove_absolute(temp)
		return _failure("identity_write")
	var rename_error: Error = DirAccess.rename_absolute(temp, path)
	if rename_error != OK or FileAccess.get_file_as_string(path) != text:
		DirAccess.remove_absolute(temp)
		return _failure("identity_write")
	return {"ok": true}


static func _is_link(path: String) -> bool:
	var parent := DirAccess.open(path.get_base_dir())
	return parent != null and parent.is_link(path.get_file())


static func _directory_clear(path: String) -> bool:
	for name: String in DirAccess.get_files_at(path):
		if not name.begins_with("."):
			return false
	for name: String in DirAccess.get_directories_at(path):
		if not name.begins_with("."):
			return false
	return true


static func _remove_tree(path: String) -> void:
	if _is_link(path):
		DirAccess.remove_absolute(path)
		return
	if not DirAccess.dir_exists_absolute(path):
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	for name: String in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(name))
	for name: String in DirAccess.get_directories_at(path):
		var child: String = path.path_join(name)
		if _is_link(child):
			DirAccess.remove_absolute(child)
		else:
			_remove_tree(child)
	DirAccess.remove_absolute(path)


static func _normalize(path: String) -> String:
	if path.is_empty():
		return ""
	return ProjectSettings.globalize_path(path).simplify_path().replace("\\", "/")


static func _same_or_inside(child: String, parent: String) -> bool:
	if child.is_empty() or parent.is_empty():
		return false
	var child_key: String = child.to_lower() if OS.has_feature("windows") else child
	var parent_key: String = parent.to_lower() if OS.has_feature("windows") else parent
	return child_key == parent_key or child_key.begins_with(parent_key.trim_suffix("/") + "/")


static func _failure(kind: String) -> Dictionary:
	return {"ok": false, "kind": kind}


static func _log(stage: String, kind: String) -> void:
	print("WORLD_TRANSFER stage=%s result=%s" % [stage, kind])
