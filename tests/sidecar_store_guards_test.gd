extends SceneTree
## Save guards shared by the world sidecar stores.
##
## Two failures are covered here:
##   1. A save must not write through a symbolic link. The pending file, the
##      main document and every ancestor directory are checked before the write,
##      so a planted link cannot redirect the document outside the save.
##   2. A store that could not read its document must not gain a world identity
##      it can then overwrite that document with. `residents.json` used to set
##      `world_id` before the document was validated, so a corrupt or foreign
##      document returned a failure but the next save replaced it.
##
## Pure filesystem test. Every fixture lives below .local/verification, and the
## outside target of each planted link is a sibling file that must stay intact.

const ConflictStore = preload("res://world/conflict_store.gd")
const Participation = preload("res://conflict/participation_state.gd")
const ParticipationStore = preload("res://world/participation_store.gd")
const TerritoryState = preload("res://world/territory_state.gd")
const TerritoryStore = preload("res://world/territory_store.gd")
const UnitState = preload("res://conflict/unit_state.gd")
const UnitStore = preload("res://world/unit_store.gd")
const PublicWorks = preload("res://world/public_works.gd")
const PublicWorksStore = preload("res://world/public_works_store.gd")
const PublicFund = preload("res://world/public_fund.gd")
const FundStore = preload("res://world/fund_store.gd")
const Organization = preload("res://world/organization_state.gd")
const OrganizationStore = preload("res://world/organization_store.gd")
const ResolutionState = preload("res://world/resolution_state.gd")
const ResolutionsStore = preload("res://world/resolutions_store.gd")
const ResidentsStore = preload("res://world/residents_store.gd")
const IntentState = preload("res://npc/npc_intent_state.gd")
const IntentStore = preload("res://npc/npc_intent_store.gd")
const PlayerBindingState = preload("res://world/player_binding_state.gd")
const PlayerBindingStore = preload("res://world/player_binding_store.gd")
const Disputes = preload("res://world/dispute_state.gd")
const DisputesStore = preload("res://world/disputes_store.gd")
const ResidentLedger = preload("res://npc/npc_resident_ledger.gd")
const ResidentLedgerStore = preload("res://npc/npc_resident_ledger_store.gd")

const WORLD: String = "world-sidecar-guards"
const OTHER_WORLD: String = "world-sidecar-guards-other"
const HOST: String = "player_sidecar_guard_00000000000001"
const START: float = 1800000000.0
const STORE_NAMES: Array[String] = [
	"conflict", "participation", "territory", "unit", "public_works", "fund",
	"organization", "resolutions", "residents", "intent", "player_binding",
	"disputes", "resident_ledger",
]

var root_dir: String = ""
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir() \
		.path_join(".local/verification/sidecar-store-guards-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)

	for name: String in STORE_NAMES:
		_test_clean_roundtrip(name)
		_test_pending_link(name)
		_test_broken_pending_link(name)
		_test_main_link(name)
		_test_linked_ancestor(name)
	_test_residents_failed_load_keeps_document()

	for failure: String in failures:
		push_error(failure)
	print("SIDECAR_STORE_GUARDS_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), root_dir])
	quit(0 if failures.is_empty() else 1)


## Builds a store plus its load/save entry points. `state` is the valid document
## each store may write, already built for the fixture world.
func _make(name: String, directory: String) -> Dictionary:
	match name:
		"conflict":
			var store := ConflictStore.new(directory)
			var state: Dictionary = ConflictStore.initial_state(WORLD)
			state["participation"] = Participation.initial_state(WORLD, HOST)
			return {
				"store": store, "main": store.MAIN, "pending": store.PENDING,
				"load": Callable(store, "load_state").bind(WORLD),
				"save": Callable(store, "save_state").bind(state, {}),
			}
		"participation":
			var store := ParticipationStore.new(directory)
			return {
				"store": store, "main": store.MAIN, "pending": store.PENDING,
				"load": Callable(store, "load_state").bind(WORLD, HOST),
				"save": Callable(store, "save_state").bind(
					Participation.initial_state(WORLD, HOST)),
			}
		"territory":
			var store := TerritoryStore.new(directory)
			return {
				"store": store, "main": store.MAIN, "pending": store.PENDING,
				"load": Callable(store, "load_state").bind(WORLD),
				"save": Callable(store, "save_state").bind(
					TerritoryState.default_state(WORLD)),
			}
		"unit":
			var store := UnitStore.new(directory)
			return {
				"store": store, "main": store.MAIN, "pending": store.PENDING,
				"load": Callable(store, "load_state").bind(WORLD),
				"save": Callable(store, "save_state").bind(UnitState.initial_state(WORLD)),
			}
		"public_works":
			var store := PublicWorksStore.new(directory)
			return {
				"store": store, "main": store.MAIN, "pending": store.PENDING,
				"load": Callable(store, "load_state"),
				"save": Callable(store, "save_state").bind(PublicWorks.empty()),
			}
		"fund":
			var store := FundStore.new(directory)
			return {
				"store": store, "main": store.MAIN, "pending": store.PENDING,
				"load": Callable(store, "load_state"),
				"save": Callable(store, "save_state").bind(PublicFund.empty()),
			}
		"organization":
			var store := OrganizationStore.new(directory)
			return {
				"store": store, "main": store.MAIN, "pending": store.PENDING,
				"load": Callable(store, "load_state"),
				"save": Callable(store, "save_state").bind(Organization.empty()),
			}
		"resolutions":
			var store := ResolutionsStore.new(directory)
			return {
				"store": store, "main": store.MAIN, "pending": store.PENDING,
				"load": Callable(store, "load_state").bind(WORLD),
				"save": Callable(store, "save_state").bind(ResolutionState.empty()),
			}
		"residents":
			var store := ResidentsStore.new(directory)
			return {
				"store": store, "main": store.MAIN, "pending": store.PENDING,
				"load": Callable(store, "load_state").bind(WORLD, START),
				"save": Callable(store, "save_state").bind(
					ResidentsStore.empty_state(WORLD), START),
			}
		"intent":
			var store := IntentStore.new(directory)
			return {
				"store": store, "main": store.MAIN, "pending": store.PENDING,
				"load": Callable(store, "load_state"),
				"save": Callable(store, "save_state").bind(IntentState.empty_state()),
			}
		"player_binding":
			var store := PlayerBindingStore.new(directory)
			return {
				"store": store, "main": store.MAIN, "pending": store.PENDING,
				"load": Callable(store, "load_state"),
				"save": Callable(store, "save_state").bind(
					PlayerBindingState.empty_state()),
			}
		"disputes":
			var store := DisputesStore.new(directory)
			return {
				"store": store, "main": store.MAIN, "pending": store.PENDING,
				"load": Callable(store, "load_state").bind(WORLD, HOST),
				"save": Callable(store, "save_state").bind(Disputes.empty([HOST], [])),
			}
		"resident_ledger":
			var store := ResidentLedgerStore.new(directory)
			return {
				"store": store, "main": store.MAIN, "pending": store.PENDING,
				"load": Callable(store, "load_state"),
				"save": Callable(store, "save_state").bind(ResidentLedger.empty()),
			}
	return {}


func _test_clean_roundtrip(name: String) -> void:
	var directory: String = _directory(name + "-clean")
	var fixture: Dictionary = _make(name, directory)
	var loaded: Dictionary = (fixture.load as Callable).call()
	_expect(bool(loaded.get("ok", false)),
		name + ": a clean document loads before any save")
	var saved: Dictionary = (fixture.save as Callable).call()
	_expect(bool(saved.get("ok", false)) and str(saved.get("kind", "")) == "saved",
		name + ": a clean directory still saves (got %s)" % str(saved.get("kind", "")))
	_expect(FileAccess.file_exists(directory.path_join(fixture.main)),
		name + ": the accepted save creates its main document")
	_expect(not FileAccess.file_exists(directory.path_join(fixture.pending)),
		name + ": the accepted save leaves no pending file")


## A pending path that is a link to an existing outside file must be refused
## before the write, and the outside file must keep its bytes.
func _test_pending_link(name: String) -> void:
	var directory: String = _directory(name + "-pending-link")
	var outside: String = directory.get_base_dir().path_join(name + "-outside.json")
	_write(outside, "outside-bytes")
	var fixture: Dictionary = _make(name, directory)
	var loaded: Dictionary = (fixture.load as Callable).call()
	_expect(bool(loaded.get("ok", false)),
		name + ": the fixture loads before the link is planted")
	if not _try_link(directory, outside, str(fixture.pending)):
		print("SKIP pending link guard for " + name)
		return
	var saved: Dictionary = (fixture.save as Callable).call()
	_expect(str(saved.get("kind", "")) == "unsafe_path",
		name + ": a linked pending file is refused (got %s)" % str(saved.get("kind", "")))
	_expect(FileAccess.get_file_as_string(outside) == "outside-bytes",
		name + ": a refused pending write leaves the outside file unchanged")
	_expect(not FileAccess.file_exists(directory.path_join(fixture.main)),
		name + ": a refused pending write creates no main document")


## A broken link is invisible to `file_exists`, so only a link check can stop a
## write from creating the target outside the save.
func _test_broken_pending_link(name: String) -> void:
	var directory: String = _directory(name + "-broken-link")
	var outside: String = directory.get_base_dir().path_join(name + "-broken.json")
	var fixture: Dictionary = _make(name, directory)
	var loaded: Dictionary = (fixture.load as Callable).call()
	_expect(bool(loaded.get("ok", false)),
		name + ": the fixture loads before the broken link is planted")
	if not _try_link(directory, outside, str(fixture.pending)):
		print("SKIP broken pending link guard for " + name)
		return
	_expect(not FileAccess.file_exists(directory.path_join(fixture.pending)),
		name + ": a broken link is invisible to file_exists")
	var saved: Dictionary = (fixture.save as Callable).call()
	_expect(str(saved.get("kind", "")) == "unsafe_path",
		name + ": a broken pending link is refused (got %s)" % str(saved.get("kind", "")))
	_expect(not FileAccess.file_exists(outside),
		name + ": a refused save does not create the link target outside the save")


## A main document that is a link must not be read through: the link target is
## outside the save and is not this world's document.
func _test_main_link(name: String) -> void:
	var directory: String = _directory(name + "-main-link")
	var outside: String = directory.get_base_dir().path_join(name + "-main-outside.json")
	_write(outside, JSON.stringify({"version": 1, "state": {}}))
	if not _try_link(directory, outside, str(_make(name, directory).main)):
		print("SKIP main link guard for " + name)
		return
	var fixture: Dictionary = _make(name, directory)
	var loaded: Dictionary = (fixture.load as Callable).call()
	_expect(str(loaded.get("kind", "")) == "unsafe_path",
		name + ": a linked main document is refused on load (got %s)"
		% str(loaded.get("kind", "")))
	_expect(FileAccess.get_file_as_string(outside)
		== JSON.stringify({"version": 1, "state": {}}),
		name + ": a refused linked load leaves the outside file unchanged")


## A save directory reached through a linked ancestor is refused as well.
func _test_linked_ancestor(name: String) -> void:
	var directory: String = _directory(name + "-ancestor")
	var real: String = directory.path_join("real-world")
	DirAccess.make_dir_recursive_absolute(real)
	if not _try_link(directory, real, "alias-world"):
		print("SKIP linked ancestor guard for " + name)
		return
	var alias: String = directory.path_join("alias-world")
	var fixture: Dictionary = _make(name, alias)
	var loaded: Dictionary = (fixture.load as Callable).call()
	_expect(str(loaded.get("kind", "")) == "unsafe_path",
		name + ": a linked ancestor is refused on load (got %s)"
		% str(loaded.get("kind", "")))
	var saved: Dictionary = (fixture.save as Callable).call()
	# A store that also requires a loaded world identity refuses this directory
	# with `invalid_world` first; either way the linked save writes nothing.
	var save_kind: String = str(saved.get("kind", ""))
	_expect(save_kind == "unsafe_path" or save_kind == "invalid_world",
		name + ": a linked ancestor is refused on save (got %s)" % save_kind)
	_expect(_files_in(real).is_empty(),
		name + ": a refused save writes nothing through the linked ancestor")


## A document that failed validation must not become writable. Before the fix,
## `load_state` fixed `world_id` first, so the next save silently replaced the
## corrupt or foreign document with a fresh roster.
func _test_residents_failed_load_keeps_document() -> void:
	var corrupt_dir: String = _directory("residents-corrupt")
	var corrupt_text: String = "{truncated"
	_write(corrupt_dir.path_join(ResidentsStore.MAIN), corrupt_text)
	var corrupt_store := ResidentsStore.new(corrupt_dir)
	var corrupt_loaded: Dictionary = corrupt_store.load_state(WORLD, START)
	_expect(str(corrupt_loaded.get("kind", "")) == "corrupt",
		"A truncated residents document is reported as corrupt")
	_expect(corrupt_store.world_id.is_empty(),
		"A failed residents load does not fix a world identity")
	var corrupt_saved: Dictionary = corrupt_store.save_state(
		ResidentsStore.empty_state(WORLD), START)
	_expect(str(corrupt_saved.get("kind", "")) == "invalid_world",
		"A store that could not load refuses to overwrite (got %s)"
		% str(corrupt_saved.get("kind", "")))
	_expect(FileAccess.get_file_as_string(
		corrupt_dir.path_join(ResidentsStore.MAIN)) == corrupt_text,
		"The corrupt residents document is left byte for byte")

	var foreign_dir: String = _directory("residents-foreign")
	var foreign_fresh: Dictionary = ResidentsStore.empty_state(OTHER_WORLD)
	var foreign_text: String = JSON.stringify({
		"version": ResidentsStore.VERSION, "world_id": OTHER_WORLD,
		"social": foreign_fresh.social, "memories": foreign_fresh.memories,
		"invitations": foreign_fresh.invitations, "dialogues": foreign_fresh.dialogues,
	}, "\t")
	_write(foreign_dir.path_join(ResidentsStore.MAIN), foreign_text)
	var foreign_store := ResidentsStore.new(foreign_dir)
	var foreign_loaded: Dictionary = foreign_store.load_state(WORLD, START)
	_expect(str(foreign_loaded.get("kind", "")) == "world_mismatch",
		"A residents document from another world is refused")
	_expect(foreign_store.world_id.is_empty(),
		"A world mismatch does not fix a world identity")
	var foreign_saved: Dictionary = foreign_store.save_state(
		ResidentsStore.empty_state(WORLD), START)
	_expect(str(foreign_saved.get("kind", "")) == "invalid_world",
		"A mismatched residents document is not replaced by a fresh roster")
	_expect(FileAccess.get_file_as_string(
		foreign_dir.path_join(ResidentsStore.MAIN)) == foreign_text,
		"The foreign residents document is left byte for byte")


func _directory(name: String) -> String:
	var path: String = root_dir.path_join(name)
	DirAccess.make_dir_recursive_absolute(path)
	return path


func _try_link(parent: String, source: String, name: String) -> bool:
	# Windows only permits symbolic links with developer mode or elevation, so a
	# fixture that cannot create one prints SKIP instead of failing the rule.
	var access := DirAccess.open(parent)
	return access != null and access.create_link(source, name) == OK


func _files_in(directory: String) -> Array[String]:
	var listed: Array[String] = []
	var access := DirAccess.open(directory)
	if access == null:
		return listed
	for name: String in access.get_files():
		listed.append(name)
	return listed


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null)
	file.store_string(text)
	file.close()


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
