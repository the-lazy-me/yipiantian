extends SceneTree
## v4 world-transfer sidecars: a real save directory exports every world-level
## document, imports into a fresh directory, and a failure part-way through the
## sidecar writes restores the original world byte for byte.
##
## Every fixture lives under .local/verification/. No network, no scene.

const Farm = preload("res://farm/farm_state.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const WorldPackage = preload("res://farm/world_package.gd")
const Transfer = preload("res://farm/world_transfer.gd")
const SocialState = preload("res://social/social_state.gd")
const SocialStore = preload("res://social/social_store.gd")
const NatureState = preload("res://farm/nature_state.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const TerritoryState = preload("res://world/territory_state.gd")
const TerritoryStore = preload("res://world/territory_store.gd")
const OrganizationState = preload("res://world/organization_state.gd")
const OrganizationStore = preload("res://world/organization_store.gd")
const PublicFund = preload("res://world/public_fund.gd")
const FundStore = preload("res://world/fund_store.gd")
const PublicWorks = preload("res://world/public_works.gd")
const PublicWorksStore = preload("res://world/public_works_store.gd")
const UnitState = preload("res://conflict/unit_state.gd")
const UnitStore = preload("res://world/unit_store.gd")
const ParticipationState = preload("res://conflict/participation_state.gd")
const ParticipationStore = preload("res://world/participation_store.gd")
const ConflictSettlement = preload("res://world/conflict_settlement.gd")
const ConflictStore = preload("res://world/conflict_store.gd")
const DisputeState = preload("res://world/dispute_state.gd")
const DisputesStore = preload("res://world/disputes_store.gd")
const ResidentsStore = preload("res://world/residents_store.gd")
const IntentState = preload("res://npc/npc_intent_state.gd")
const NpcIntentStore = preload("res://npc/npc_intent_store.gd")
const ResolutionState = preload("res://world/resolution_state.gd")
const ResolutionsStore = preload("res://world/resolutions_store.gd")
const ResolutionEffects = preload("res://world/resolution_effects.gd")
const ResolutionEffectsStore = preload("res://world/resolution_effects_store.gd")

const START: float = 1800000000.0
const WORLD: String = "world_sidecar_live"
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/world-transfer-sidecars-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	var save_a: String = test_root.path_join("save-a")
	var fixture: Dictionary = _make_live_world(save_a)
	_expect(fixture.ok, "Live fixture world is committed with every sidecar")
	if not fixture.ok:
		_report()
		return
	var package: String = test_root.path_join("package")
	var exported: Dictionary = Transfer.export_world(save_a, package)
	_expect(exported.ok and exported.kind == "exported", "A world with sidecars exports")
	if not exported.ok:
		_report()
		return
	_expect(exported.package.format_version == 4, "Export writes package format 4")
	_expect(exported.package.world_id == WORLD, "Export keeps the live world identity")
	_expect(exported.package.sidecars.keys().size() == WorldPackage.SIDECAR_FILES.size(),
		"Export carries every live sidecar")
	_test_export_package(save_a, exported)
	_test_roundtrip_bytes(save_a, package)
	_test_export_rejections()
	_test_missing_stays_missing()
	_test_partial_failure_restores(save_a)
	_test_pin_mismatch(package, save_a)
	_report()


func _test_export_package(save: String, exported: Dictionary) -> void:
	for name: String in WorldPackage.SIDECAR_FILES:
		var parsed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
			save.path_join(name)))
		_expect(exported.package.sidecars[name] == parsed,
			"Exported sidecar is the live document: " + name)
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		exported.package_path.get_base_dir().path_join("import-report.json")))
	_expect(report.sidecars.size() == WorldPackage.SIDECAR_FILES.size(),
		"The import report names every carried sidecar")
	_expect(report.world_id == WORLD, "The import report records the stable world identity")


func _test_roundtrip_bytes(save_a: String, package: String) -> void:
	var save_b: String = test_root.path_join("save-b")
	var imported: Dictionary = _import_into(package, save_b)
	_expect(imported.ok and imported.kind == "imported", "The package imports into a fresh world")
	if not imported.ok:
		return
	_expect(imported.summary.sidecars.size() == WorldPackage.SIDECAR_FILES.size(),
		"The import summary names every written sidecar")
	for name: String in WorldPackage.SIDECAR_FILES:
		var source: String = save_a.path_join(name)
		var target: String = save_b.path_join(name)
		_expect(FileAccess.file_exists(target), "Imported sidecar exists: " + name)
		if not FileAccess.file_exists(target):
			continue
		# The package carries the parsed document, not the source bytes, so the
		# import writes the canonical form: same keys, same values, sorted
		# order. The comparison is on that canonical form for both sides.
		_expect(WorldPackage.canonical_text(
				JSON.parse_string(FileAccess.get_file_as_string(target)))
				== WorldPackage.canonical_text(
					JSON.parse_string(FileAccess.get_file_as_string(source))),
			"Imported sidecar has the same content: " + name)
		_expect(WorldPackage.validate_sidecars(
				{name: JSON.parse_string(FileAccess.get_file_as_string(target))},
				WORLD).ok,
			"Imported sidecar revalidates: " + name)
		_expect(not FileAccess.file_exists(save_b.path_join(_pending(name))),
			"No pending sidecar is left behind: " + name)
	# Each store's own load path is the proof the world's next start accepts the
	# imported documents.
	var loaded: Dictionary = _load_all(save_b)
	for name: String in WorldPackage.SIDECAR_FILES:
		_expect(bool(loaded[name].get("ok", false))
				and str(loaded[name].get("kind", "")) == "loaded",
			"Imported sidecar loads through its store: " + name)
	_expect(loaded["territory.json"].state.world_id == WORLD,
		"The imported cadastre names the imported world")
	_expect(not str(loaded["organizations.json"].state.organizations).is_empty(),
		"The imported organization table keeps its member")
	_expect(loaded["public_funds.json"].state.funds.has("fund_coop"),
		"The imported fund table keeps its balance")
	_expect(loaded["public_works.json"].state.projects.has("project_1"),
		"The imported project table keeps its project")
	_expect(loaded["units.json"].state.units.has("unit_1"),
		"The imported roster keeps its unit")
	_expect(loaded["conflicts.json"].state.sequence == 0,
		"The imported settlement context is readable")
	_expect(loaded["disputes.json"].state.cases.has("case_1"),
		"The imported case table keeps its case")
	_expect(loaded["residents.json"].state.social.relations.has("npc_lin_shen"),
		"The imported resident relations are readable")
	_expect(loaded["npc_intents.json"].state.intents.size() == 1,
		"The imported intent ledger keeps its intent")
	_expect(loaded["resolutions.json"].state.resolutions.is_empty(),
		"The imported resolution table is readable")
	_expect(loaded["resolution_effects.json"].state.applied_version == 0,
		"The imported effect document is readable")
	# A second export from the imported world must reproduce the package exactly:
	# nothing the import wrote loses information the first export carried.
	var package_b: String = test_root.path_join("package-b")
	var reexported: Dictionary = Transfer.export_world(save_b, package_b)
	_expect(reexported.ok, "The imported world exports again")
	if reexported.ok:
		_expect(reexported.package.sidecars.keys().size() == WorldPackage.SIDECAR_FILES.size(),
			"A re-export still carries every sidecar")
		for name: String in WorldPackage.SIDECAR_FILES:
			_expect(WorldPackage.canonical_text(reexported.package.sidecars[name])
					== WorldPackage.canonical_text(
						JSON.parse_string(_live_text(save_a, name))),
				"A re-export matches the original document: " + name)


func _test_export_rejections() -> void:
	var names: Array[Dictionary] = [
		{"name": "territory.json", "kind": "sidecar_corrupt", "text": "{truncated"},
		{"name": "resolutions.json", "kind": "sidecar_unsupported",
			"text": JSON.stringify({"version": 2, "world_id": WORLD,
				"state": ResolutionState.empty(), "commands": []})},
		{"name": "units.json", "kind": "sidecar_world_mismatch",
			"text": JSON.stringify({"version": 1,
				"state": UnitState.initial_state("world_other")})},
	]
	for entry: Dictionary in names:
		var save: String = test_root.path_join("reject-" + str(entry.name).replace(".json", ""))
		_expect(_make_live_world(save).ok, "Rejection fixture is committed: " + str(entry.name))
		_write(save.path_join(str(entry.name)), str(entry.text))
		var tree: Dictionary = _tree(save)
		var target: String = test_root.path_join("reject-target-" + str(entry.name).replace(".json", ""))
		var result: Dictionary = Transfer.export_world(save, target)
		_expect(not result.ok and result.kind == entry.kind,
			"Export refuses %s by name (got %s)" % [str(entry.name), str(result.get("kind", ""))])
		_expect(result.get("sidecar", "") == entry.name,
			"Export names the offending sidecar: " + str(entry.name))
		_expect(_tree(save) == tree, "A refused export leaves the live world unchanged: " + str(entry.name))
		_expect(not DirAccess.dir_exists_absolute(target), "A refused export writes no package: " + str(entry.name))
	# A broken link is not a missing file: following it would export nothing and
	# silently drop the document.
	var link_save: String = test_root.path_join("reject-link")
	_expect(_make_live_world(link_save).ok, "Link fixture is committed")
	var access := DirAccess.open(link_save)
	var link_path: String = link_save.path_join("territory.json")
	DirAccess.remove_absolute(link_path)
	if access != null and access.create_link("no-such-target-xyz", "territory.json") == OK:
		var linked: Dictionary = Transfer.export_world(link_save, test_root.path_join("link-target"))
		_expect(not linked.ok and linked.kind == "unsafe_output",
			"A linked sidecar is refused instead of being skipped")
	else:
		print("SKIP sidecar link refusal on this platform")


func _test_missing_stays_missing() -> void:
	var save: String = test_root.path_join("save-missing")
	_expect(_make_farm_only(save).ok, "Farm-only fixture is committed")
	var package: String = test_root.path_join("package-missing")
	var exported: Dictionary = Transfer.export_world(save, package)
	_expect(exported.ok, "A world without sidecars still exports")
	if not exported.ok:
		return
	_expect(exported.package.sidecars.is_empty(),
		"A world without sidecars carries an empty dictionary, not empty documents")
	var target: String = test_root.path_join("save-missing-import")
	var imported: Dictionary = _import_into(package, target)
	_expect(imported.ok, "An empty sidecar dictionary imports")
	if not imported.ok:
		return
	for name: String in WorldPackage.SIDECAR_FILES:
		_expect(not FileAccess.file_exists(target.path_join(name)),
			"Import does not invent a missing sidecar: " + name)


func _test_partial_failure_restores(save_a: String) -> void:
	# A broken link at the last sidecar's pending name is a real write failure:
	# the import has already replaced the farm, identity, social, nature and the
	# earlier sidecars when it reaches this one, and the link target is outside
	# the save so following it would write there. A broken link is invisible to
	# `file_exists` on macOS, so the backup step passes it and the failure
	# happens mid import, which is exactly the path that must roll back.
	#
	# Windows reports the same link through `file_exists`, so the backup step
	# refuses with `io` before writing anything. Both outcomes are accepted, and
	# each one asserts its own promise: the platform that gets past the backup
	# must restore byte for byte, the one that refuses early must have changed
	# nothing. Neither may follow the link.
	var save: String = test_root.path_join("save-partial")
	var fixture: Dictionary = _make_live_world(save)
	_expect(fixture.ok, "Partial-failure fixture is committed")
	if not fixture.ok:
		return
	var before: Dictionary = _world_tree(save)
	var package: String = test_root.path_join("package-partial")
	var exported: Dictionary = Transfer.export_world(save_a, package)
	_expect(exported.ok, "Partial-failure package exports")
	var prepared: Dictionary = Transfer.prepare_import(package, save)
	_expect(prepared.ok, "Partial-failure import prepares")
	var access := DirAccess.open(save)
	if access == null or access.create_link("outside-target-xyz", "resolutions.pending.json") != OK:
		print("SKIP mid-import sidecar failure restore on this platform")
		return
	var failed: Dictionary = Transfer.apply_import(prepared, save)
	_expect(not bool(failed.ok), "A blocked sidecar write aborts the import")
	var link_path: String = save.path_join("resolutions.pending.json")
	if str(failed.get("kind", "")) == "io":
		_expect(not bool(failed.get("restored", false)),
			"A refused backup reports no restore because it wrote nothing")
		DirAccess.remove_absolute(link_path)
		_expect(_world_tree(save) == before,
			"A refused backup leaves the original world byte for byte")
	else:
		_expect(str(failed.get("kind", "")) == "sidecar_write",
			"A blocked sidecar write fails as sidecar_write (got %s)"
				% str(failed.get("kind", "")))
		_expect(bool(failed.get("restored", false)), "The failed import reports the restore")
		_expect(not access.is_link("resolutions.pending.json"),
			"The restore removes the pending placeholder")
		_expect(_world_tree(save) == before,
			"A failed sidecar write restores the original world byte for byte")
	# The link target was never created: a failed import must not write outside
	# the save directory either.
	_expect(not FileAccess.file_exists(save.get_base_dir().path_join("outside-target-xyz")),
		"A refused sidecar write never follows the link")


func _test_pin_mismatch(package: String, save_a: String) -> void:
	var save: String = test_root.path_join("save-pin")
	DirAccess.make_dir_recursive_absolute(save)
	_write(save.path_join("world-id.txt"), "world_pinned_other")
	var before: Dictionary = _tree(save)
	var prepared: Dictionary = Transfer.prepare_import(package, save)
	_expect(not prepared.ok and prepared.kind == "sidecar_world_mismatch",
		"Import refuses a directory pinned to another world")
	_expect(_tree(save) == before, "A pin mismatch writes nothing")
	# Export follows the pin even when the sidecars were written under it.
	var pinned_save: String = test_root.path_join("save-pinned-live")
	_expect(_make_live_world(pinned_save).ok, "Pinned-live fixture is committed")
	_write(pinned_save.path_join("world-id.txt"), WORLD)
	var pinned_package: String = test_root.path_join("package-pinned")
	var exported: Dictionary = Transfer.export_world(pinned_save, pinned_package)
	_expect(exported.ok and exported.package.world_id == WORLD,
		"Export keeps the pinned live world identity")


func _make_live_world(folder: String) -> Dictionary:
	var created: Dictionary = _make_farm_only(folder)
	if not created.ok:
		return created
	var ok: bool = true
	# The cadastre names the live world; it is what the export follows.
	ok = TerritoryStore.new(folder).save_state(
		TerritoryState.default_state(WORLD)).ok and ok
	var organizations: Dictionary = OrganizationState.create(
		OrganizationState.empty(), "coop", "河岸合作社", PLAYER_A, START)
	ok = organizations.ok and OrganizationStore.new(folder).save_state(
		organizations.state).ok and ok
	var funds: Dictionary = PublicFund.open_fund(PublicFund.empty(), "coop", PLAYER_A)
	ok = funds.ok and FundStore.new(folder).save_state(funds.state).ok and ok
	var works: Dictionary = PublicWorks.open_project(
		PublicWorks.empty(), "project_1", PublicWorks.KIND_PUBLIC_WELL, "")
	ok = works.ok and PublicWorksStore.new(folder).save_state(works.state).ok and ok
	# The roster's unit is created through the rule layer so the derived record
	# and count fields are exactly what the validator expects.
	var units: Dictionary = UnitState.initial_state(WORLD)
	var recruited: Dictionary = UnitState.recruit(
		units, {"cash": 100, "supplies": 100},
		{"id": "unit_1", "owner": PLAYER_A, "kind": UnitState.KIND_MILITIA,
			"people": 1, "equipment": "none", "station": "home"}, START)
	ok = recruited.ok and UnitStore.new(folder).save_state(recruited.state).ok and ok
	var participation: Dictionary = ParticipationState.initial_state(WORLD, PLAYER_A)
	ok = ParticipationStore.new(folder).save_state(participation).ok and ok
	var conflicts: Dictionary = ConflictSettlement.initial_context(WORLD, participation)
	ok = ConflictStore.new(folder).save_state(conflicts, {}).ok and ok
	# A filed case is created through the rule layer so its audit trail matches.
	var disputes: Dictionary = DisputeState.empty([PLAYER_A], [])
	var filed: Dictionary = DisputeState.file(
		disputes, "case_1", PLAYER_A, PLAYER_B, ["event_1"], START)
	# The store writes the world it last loaded, so the load must bind this world
	# before the save (see the defect note in the record).
	var dispute_store := DisputesStore.new(folder)
	ok = dispute_store.load_state(WORLD, PLAYER_A).ok and filed.ok \
		and dispute_store.save_state(filed.state).ok and ok
	var residents := ResidentsStore.new(folder)
	var residents_loaded: Dictionary = residents.load_state(WORLD, START)
	ok = residents_loaded.ok and residents.save_state(residents_loaded.state, START).ok and ok
	var intents: Dictionary = IntentState.empty_state()
	intents.until_utc = START
	intents.intents["npc_lin_shen"] = START - 10.0
	ok = NpcIntentStore.new(folder).save_state(intents).ok and ok
	var resolutions := ResolutionsStore.new(folder)
	ok = resolutions.load_state(WORLD).ok and resolutions.save_state(
		ResolutionState.empty()).ok and ok
	var effects := ResolutionEffectsStore.new(folder)
	ok = effects.load_state(WORLD).ok and effects.save_state(
		ResolutionEffects.empty()).ok and ok
	return {"ok": ok}


func _make_farm_only(folder: String) -> Dictionary:
	var store := FarmStore.new(folder)
	if store.load_state().kind != "missing":
		return {"ok": false}
	var farm := Farm.new(START)
	farm.harvest("field_03", "cell_06", START)
	farm.settle(START + 3600.0)
	var decorations := Decorations.new()
	decorations.unlock(farm.snapshot().harvested)
	var saved: Dictionary = store.save(farm.snapshot(), decorations.snapshot())
	if not saved.ok:
		return {"ok": false}
	var social: Dictionary = SocialState.initial_state()
	SocialState.ensure_player(social, PLAYER_A, "阿青", START)
	if not SocialStore.new(folder).save_state(social).ok:
		return {"ok": false}
	if not NatureStore.new(folder).save_state({
		"seed": 777888, "rules_version": NatureState.RULES_VERSION,
	}).ok:
		return {"ok": false}
	# A live shared world pins its name; the export follows that name.
	_write(folder.path_join("world-id.txt"), WORLD)
	return {"ok": true}


func _load_all(save: String) -> Dictionary:
	var residents := ResidentsStore.new(save)
	return {
		"territory.json": TerritoryStore.new(save).load_state(WORLD),
		"organizations.json": OrganizationStore.new(save).load_state(),
		"public_funds.json": FundStore.new(save).load_state(),
		"public_works.json": PublicWorksStore.new(save).load_state(),
		"units.json": UnitStore.new(save).load_state(WORLD),
		"participation.json": ParticipationStore.new(save).load_state(WORLD, PLAYER_A),
		"conflicts.json": ConflictStore.new(save).load_state(WORLD),
		"disputes.json": DisputesStore.new(save).load_state(WORLD, PLAYER_A),
		"residents.json": residents.load_state(WORLD, START),
		"npc_intents.json": NpcIntentStore.new(save).load_state(),
		"resolutions.json": ResolutionsStore.new(save).load_state(WORLD),
		"resolution_effects.json": ResolutionEffectsStore.new(save).load_state(WORLD),
	}


func _import_into(package: String, save: String) -> Dictionary:
	var prepared: Dictionary = Transfer.prepare_import(package, save)
	if not prepared.ok:
		return prepared
	return Transfer.apply_import(prepared, save)


func _live_text(directory: String, name: String) -> String:
	return FileAccess.get_file_as_string(directory.path_join(name))


func _pending(name: String) -> String:
	return name.get_basename() + ".pending.json"


func _tree(path: String) -> Dictionary:
	var result: Dictionary = {}
	if DirAccess.dir_exists_absolute(path):
		_walk(path, path, result)
	return result


## Every world document the import may replace, without the backup directory
## the import itself creates. Comparing this is the "original world bytes
## unchanged" claim; the backup directory is new state by design.
func _world_tree(path: String) -> Dictionary:
	var result: Dictionary = _tree(path)
	for key: Variant in result.keys():
		if str(key).begins_with("import-backups/"):
			result.erase(key)
	return result


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
	print("WORLD_TRANSFER_SIDECARS_TEST checks=%d failures=%d root=%s"
		% [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
