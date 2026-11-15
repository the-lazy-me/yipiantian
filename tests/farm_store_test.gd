extends SceneTree

const Store = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const Farm = preload("res://farm/farm_state.gd")
var checks: int = 0
var failures: Array[String] = []
var test_root: String

class AlteredReadback:
	extends "res://farm/farm_store.gd"
	var change_file: String=""
	var replacement: String=""
	func _read_text(filename: String) -> Dictionary:
		# Change a real newly written file just before verification. The preflight
		# sees a missing stage, so this exercises write verification, not admission.
		if filename==change_file and FileAccess.file_exists(_path(filename)):
			var file:=FileAccess.open(_path(filename),FileAccess.WRITE)
			assert(file!=null);file.store_string(replacement);file.close();change_file=""
		return super._read_text(filename)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join("../.local/verification/farm-store-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	var folder: String = test_root.path_join("roundtrip")
	var store := Store.new(folder)
	_expect(store.load_state().kind == "missing", "New isolated directory is truly missing")
	var farm := Farm.new(10000.0)
	_expect(store.save(farm.snapshot(), Decorations.new().snapshot()).ok, "First farm is saved")
	_expect(FileAccess.file_exists(folder.path_join(Store.MAIN)), "Main file exists")
	farm.sow("field_01", "cell_06", "greens", 10000.0)
	farm.water("field_01", "cell_06", 10000.0)
	_expect(store.save_state(farm, Decorations.new()).ok, "Owner transaction saves sow and water through the same durable path")
	var reopened := Store.new(folder)
	var loaded: Dictionary = reopened.load_state()
	_expect(loaded.ok and loaded.farm == farm.snapshot(), "Roundtrip retains exact authoritative state")
	# A live owner can hold a candidate its own loader would reject. save_state
	# must re-admit the exact document instead of committing what it cannot reload.
	var guarded: String = test_root.path_join("guarded")
	var guard_store := Store.new(guarded)
	_expect(guard_store.load_state().kind == "missing", "The guarded store starts empty")
	var poisoned := Farm.new(10000.0)
	_expect(guard_store.save(poisoned.snapshot(), Decorations.new().snapshot()).ok,
		"The guarded store has a committed baseline")
	var guarded_bytes: String = FileAccess.get_file_as_string(guarded.path_join(Store.MAIN))
	poisoned._data.economy.market.merchant.opened_utc = -1.0
	var refused: Dictionary = guard_store.save_state(poisoned, Decorations.new())
	_expect(not refused.ok and refused.kind == "invalid_state",
		"An owner snapshot that fails document validation is refused")
	_expect(FileAccess.get_file_as_string(guarded.path_join(Store.MAIN)) == guarded_bytes,
		"A refused candidate leaves the committed document unchanged")
	var second := Farm.new()
	second.restore_snapshot(loaded.farm)
	second.settle(11440.0)
	_expect(second.get_cell("field_01", "cell_06").stage == "mature", "Offline elapsed time matures the existing round")
	second.harvest("field_01", "cell_06", 11440.0)
	_expect(reopened.save(second.snapshot(), Decorations.new().snapshot()).ok, "Harvest is durably saved")
	var again := Store.new(folder)
	var restored: Dictionary = again.load_state()
	_expect(restored.farm.harvested.greens == 1 and restored.farm.fields.field_01.cells.cell_06.crop_id == "", "Reopen never reissues the collected basket")
	_expect(again.load_state().farm == restored.farm, "Repeated loading does not initialize or reward again")
	var before_stale: String = FileAccess.get_file_as_string(folder.path_join(Store.MAIN))
	_expect(not store.save_state(farm, Decorations.new()).ok, "A stale owner transaction refuses to overwrite newer on-disk state")
	_expect(FileAccess.get_file_as_string(folder.path_join(Store.MAIN)) == before_stale, "Stale write preserves main")
	# A legal all-empty farm is not a missing save.
	var empty := Farm.new(12000.0)
	empty.settle(20000.0)
	for id: String in Farm.FIELD_IDS:
		empty.harvest(id, "cell_06", 20000.0)
	_expect(again.save(empty.snapshot(), Decorations.new().snapshot()).ok, "Legal empty farm saves")
	_expect(Store.new(folder).load_state().farm == empty.snapshot(), "Legal empty farm restores without initial crops")
	# Real Windows failures: a directory occupies the temporary-file path.
	var pending_dir: String = folder.path_join(Store.PENDING)
	DirAccess.make_dir_absolute(pending_dir)
	var old_main: String = FileAccess.get_file_as_string(folder.path_join(Store.MAIN))
	var old_backup: String = FileAccess.get_file_as_string(folder.path_join(Store.BACKUP))
	empty.sow("field_02", "cell_06", "greens", 20000.0)
	var failed: Dictionary = again.save(empty.snapshot(), Decorations.new().snapshot())
	_expect(not failed.ok and failed.kind.begins_with("write_"), "Real filesystem prevents temporary write")
	_expect(FileAccess.get_file_as_string(folder.path_join(Store.MAIN)) == old_main and FileAccess.get_file_as_string(folder.path_join(Store.BACKUP)) == old_backup, "Temporary failure leaves main and backup unchanged")
	DirAccess.remove_absolute(pending_dir)
	_expect(again.save(empty.snapshot(), Decorations.new().snapshot()).ok, "Retry saves current snapshot without replaying the action")
	# Read-only replacement failure on Windows, using actual file attributes.
	var protected_main: String = folder.path_join(Store.MAIN)
	old_main = FileAccess.get_file_as_string(protected_main)
	_expect(FileAccess.set_read_only_attribute(protected_main, true) == OK, "Set real Windows read-only attribute")
	empty.water("field_02", "cell_06", 20000.0)
	failed = again.save(empty.snapshot(), Decorations.new().snapshot())
	_expect(not failed.ok, "Read-only main rejects replacement")
	_expect(FileAccess.get_file_as_string(protected_main) == old_main, "Replacement failure preserves previous main bytes")
	_expect(Store.new(folder).load_state().farm.fields.field_02.cells.cell_06.watered == false, "Restart after failed replace reads committed previous state")
	FileAccess.set_read_only_attribute(protected_main, false)
	_expect(again.save(empty.snapshot(), Decorations.new().snapshot()).ok, "Removing attribute allows safe retry")
	# Candidate files left by an interrupted replace must not beat a valid main.
	var candidate := Farm.new(90000.0)
	_write(folder.path_join(Store.PENDING), JSON.stringify({"version": Store.VERSION, "farm": candidate.snapshot(), "decorations": Decorations.new().snapshot()}))
	_expect(Store.new(folder).load_state().farm == empty.snapshot(), "Uncommitted temp never supersedes valid main")
	# A truncated main offers explicit recovery; it is not overwritten on load.
	_write(protected_main, "{truncated")
	var damaged_store := Store.new(folder)
	var damaged: Dictionary = damaged_store.load_state()
	_expect(damaged.kind == "recovery_available", "Valid backup offers recovery after main damage")
	_expect(FileAccess.get_file_as_string(protected_main) == "{truncated", "Load preserves damaged main")
	_expect(not damaged_store.save(candidate.snapshot(), Decorations.new().snapshot()).ok, "Unapproved recovery cannot write new gameplay")
	var recovered: Dictionary = damaged_store.recover()
	_expect(recovered.ok and recovered.kind == "recovered", "Explicit recovery restores validated backup")
	var preserved: bool = false
	for name: String in DirAccess.get_files_at(folder):
		if name.begins_with("farm.unreadable."):
			preserved = FileAccess.get_file_as_string(folder.path_join(name)) == "{truncated"
	_expect(preserved, "Original damaged bytes retained during recovery")
	# Unsupported versions block recovery even when an old compatible backup exists.
	var future: String = JSON.stringify({"version": 99, "farm": candidate.snapshot(), "future": true})
	_write(protected_main, future)
	var future_store := Store.new(folder)
	_expect(future_store.load_state().kind == "unsupported", "Future version is distinguished from damage")
	_expect(not future_store.recover().ok and not future_store.save(candidate.snapshot(), Decorations.new().snapshot()).ok, "Future version cannot recover older state or save over it")
	_expect(FileAccess.get_file_as_string(protected_main) == future, "Unknown version preserved byte-for-byte")
	var corrupt_dir: String = test_root.path_join("all-corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	_write(corrupt_dir.path_join(Store.MAIN), "")
	_write(corrupt_dir.path_join(Store.BACKUP), "not-json")
	var corrupt_store := Store.new(corrupt_dir)
	_expect(corrupt_store.load_state().kind == "corrupt", "Empty main and invalid backup are not first launch")
	_expect(not corrupt_store.recover().ok and not corrupt_store.save(candidate.snapshot(), Decorations.new().snapshot()).ok, "No valid recovery retains broken files and locks saves")
	var interrupted_dir: String = test_root.path_join("interrupted-first")
	DirAccess.make_dir_recursive_absolute(interrupted_dir)
	_write(interrupted_dir.path_join(Store.PENDING), JSON.stringify({"version": Store.VERSION, "farm": candidate.snapshot(), "decorations": Decorations.new().snapshot()}))
	var interrupted := Store.new(interrupted_dir)
	_expect(interrupted.load_state().kind == "recovery_available", "Interrupted first creation is not silently reinitialized")
	_expect(interrupted.recover().farm == candidate.snapshot(), "Valid first pending file can be explicitly recovered")
	var bad_path: String = test_root.path_join("not-a-directory")
	_write(bad_path, "occupied")
	var bad_store := Store.new(bad_path)
	_expect(not bad_store.load_state().ok and not bad_store.save(candidate.snapshot(), Decorations.new().snapshot()).ok, "A file cannot masquerade as the save directory")
	var first_dir: String = test_root.path_join("first-save-failure")
	var first_store := Store.new(first_dir)
	_expect(first_store.load_state().kind == "missing", "First-save fixture is admitted only after missing load")
	DirAccess.make_dir_recursive_absolute(first_dir.path_join(Store.PENDING))
	_expect(not first_store.save(candidate.snapshot(), Decorations.new().snapshot()).ok and not FileAccess.file_exists(first_dir.path_join(Store.MAIN)), "Interrupted first write creates no fake committed main")
	DirAccess.remove_absolute(first_dir.path_join(Store.PENDING))
	_expect(first_store.save(candidate.snapshot(), Decorations.new().snapshot()).ok and Store.new(first_dir).load_state().farm == candidate.snapshot(), "First-save retry preserves the same initial in-memory state")
	var staged_dir: String = test_root.path_join("staged-backup")
	DirAccess.make_dir_recursive_absolute(staged_dir)
	_write(staged_dir.path_join(Store.BACKUP_PENDING), JSON.stringify({"version": Store.VERSION, "farm": candidate.snapshot(), "decorations": Decorations.new().snapshot()}))
	var staged_store := Store.new(staged_dir)
	_expect(staged_store.load_state().kind == "recovery_available", "A lone validated backup stage cannot be mistaken for first launch")
	_expect(staged_store.recover().farm == candidate.snapshot(), "Recovery handles a previously committed staged backup")
	# A crash while writing the very first candidate leaves only a truncated or
	# empty pending file. With no committed document that is still a first
	# launch, including after a real process restart.
	for content: String in ["", "{truncated"]:
		var restart_dir: String = test_root.path_join("corrupt-pending-first-%d" % content.length())
		DirAccess.make_dir_recursive_absolute(restart_dir)
		_write(restart_dir.path_join(Store.PENDING), content)
		var restarted := Store.new(restart_dir)
		var restarted_state: Dictionary = restarted.load_state()
		_expect(restarted_state.ok and restarted_state.kind == "missing",
			"A corrupt pending without any committed main is a first launch: " + str(content.length()))
		_expect(restarted.save(candidate.snapshot(), Decorations.new().snapshot()).ok
			and Store.new(restart_dir).load_state().farm == candidate.snapshot(),
			"A first launch can commit after the interrupted candidate is discarded")
	var unsupported_pending_dir: String = test_root.path_join("unsupported-pending-first")
	DirAccess.make_dir_recursive_absolute(unsupported_pending_dir)
	_write(unsupported_pending_dir.path_join(Store.PENDING),
		JSON.stringify({"version": Store.VERSION + 1, "farm": candidate.snapshot(),
			"decorations": Decorations.new().snapshot()}))
	var unsupported_pending := Store.new(unsupported_pending_dir)
	_expect(unsupported_pending.load_state().kind == "unsupported",
		"An unsupported pending without a committed main is still refused as a first launch")
	_expect(not unsupported_pending.save(candidate.snapshot(), Decorations.new().snapshot()).ok,
		"An unsupported pending keeps the first launch locked")
	# An interrupted commit can leave both a backup and a staged backup valid.
	# The staged generation is the one just committed and must win; choosing the
	# older backup first would roll the world back and delete the newer stage.
	var priority_dir: String = test_root.path_join("staged-vs-backup")
	DirAccess.make_dir_recursive_absolute(priority_dir)
	var older := Farm.new(30000.0)
	var newer := Farm.new(40000.0)
	var older_text: String = JSON.stringify({"version": Store.VERSION, "farm": older.snapshot(),
		"decorations": Decorations.new().snapshot()})
	_write(priority_dir.path_join(Store.BACKUP), older_text)
	_write(priority_dir.path_join(Store.BACKUP_PENDING),
		JSON.stringify({"version": Store.VERSION, "farm": newer.snapshot(),
			"decorations": Decorations.new().snapshot()}))
	var priority_store := Store.new(priority_dir)
	var offered: Dictionary = priority_store.load_state()
	_expect(offered.kind == "recovery_available" and offered.source == Store.BACKUP_PENDING,
		"Two valid recovery generations offer the newer staged backup")
	var priority_recovered: Dictionary = priority_store.recover()
	_expect(priority_recovered.ok and priority_recovered.farm == newer.snapshot(),
		"Recovery restores the newer staged generation")
	var stale_stage_dir: String = test_root.path_join("staged-damaged-backup-valid")
	DirAccess.make_dir_recursive_absolute(stale_stage_dir)
	_write(stale_stage_dir.path_join(Store.BACKUP), older_text)
	_write(stale_stage_dir.path_join(Store.BACKUP_PENDING), "{truncated")
	var stale_stage := Store.new(stale_stage_dir)
	var fallback: Dictionary = stale_stage.load_state()
	_expect(fallback.kind == "recovery_available" and fallback.source == Store.BACKUP,
		"A damaged staged backup still falls back to the valid backup")
	_expect(stale_stage.recover().farm == older.snapshot(),
		"Fallback recovery restores the older valid backup")
	_write(first_dir.path_join(Store.BACKUP), future)
	var before_future_backup: String = FileAccess.get_file_as_string(first_dir.path_join(Store.MAIN))
	_expect(not first_store.save(candidate.snapshot(), Decorations.new().snapshot()).ok, "Future backup is not overwritten by older software")
	_expect(FileAccess.get_file_as_string(first_dir.path_join(Store.BACKUP)) == future and FileAccess.get_file_as_string(first_dir.path_join(Store.MAIN)) == before_future_backup, "Rejecting future backup preserves both files")
	_test_current_boundaries()
	_test_readback_integrity()
	_test_admitted_main_changes()
	_test_sidecar_version_gate()
	for failure: String in failures:
		push_error(failure)
	print("FARM_STORE_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)

func _test_sidecar_version_gate() -> void:
	var farm: Dictionary=Farm.new(10000).snapshot()
	var decorations: Dictionary=Decorations.new().snapshot()
	for filename: String in [Store.BACKUP,Store.BACKUP_PENDING,Store.PENDING]:
		var folder: String=test_root.path_join("version-gate-"+filename)
		DirAccess.make_dir_recursive_absolute(folder)
		var corrupt: String=JSON.stringify({"version":Store.VERSION,"farm":{},"decorations":{}})
		_write(folder.path_join(filename),corrupt)
		var broken := Store.new(folder).load_state()
		if filename==Store.PENDING:
			# An uncommitted candidate is not a recovery source. With no committed
			# main anywhere it is a first launch; the version alone still admits
			# nothing.
			_expect(broken.ok and broken.kind=="missing","A broken candidate without a committed main is a first launch: "+filename)
		else:
			_expect(broken.kind=="corrupt","Version alone cannot admit a broken recovery candidate: "+filename)
		# Admission comes from a valid main, never the unvalidated sidecar.
		_write(folder.path_join(Store.MAIN),JSON.stringify({"version":Store.VERSION,"farm":farm,"decorations":decorations}))
		var store:=Store.new(folder)
		_expect(store.load_state().ok and store.save(farm,decorations).ok,"A damaged current-version sidecar does not block saving valid current state: "+filename)
		var main_before: String=FileAccess.get_file_as_string(folder.path_join(Store.MAIN))
		var future: String=JSON.stringify({"version":Store.VERSION+1,"farm":null})
		_write(folder.path_join(filename),future)
		_expect(store.save(farm,decorations).kind=="unsupported","Unknown sidecar version blocks replacement even without a valid farm payload: "+filename)
		_expect(FileAccess.get_file_as_string(folder.path_join(filename))==future and FileAccess.get_file_as_string(folder.path_join(Store.MAIN))==main_before,"Rejected sidecar replacement preserves main and sidecar bytes: "+filename)

func _test_readback_integrity() -> void:
	var decorations: Dictionary=Decorations.new().snapshot()
	for stage: String in [Store.PENDING,Store.BACKUP_PENDING]:
		for corruption: String in ["truncated","different_valid"]:
			var folder: String=test_root.path_join(stage+"-"+corruption)
			var store:=AlteredReadback.new();store.directory=folder
			var farm:=Farm.new(20000)
			_expect(store.load_state().kind=="missing" and store.save(farm.snapshot(),decorations).ok,"Readback fixture has a valid first main")
			farm.sow("field_01","cell_01","greens",20000)
			_expect(store.save(farm.snapshot(),decorations).ok,"Readback fixture has a committed backup")
			var main_text: String=FileAccess.get_file_as_string(folder.path_join(Store.MAIN))
			var backup_text: String=FileAccess.get_file_as_string(folder.path_join(Store.BACKUP))
			farm.water("field_01","cell_01",20001)
			store.change_file=stage
			store.replacement="{truncated" if corruption=="truncated" else JSON.stringify({"version":Store.VERSION,"farm":Farm.new(90000).snapshot(),"decorations":decorations})
			var result: Dictionary=store.save(farm.snapshot(),decorations)
			_expect(not result.ok and result.kind=="verify_"+stage,"Readback rejects "+corruption+" content in "+stage)
			_expect(FileAccess.get_file_as_string(folder.path_join(Store.MAIN))==main_text and FileAccess.get_file_as_string(folder.path_join(Store.BACKUP))==backup_text,"Readback failure preserves committed main and backup")
			_expect(store.save(farm.snapshot(),decorations).ok and Store.new(folder).load_state().farm==farm.snapshot(),"Readback failure can retry the exact current state")

func _test_admitted_main_changes() -> void:
	var folder: String=test_root.path_join("admitted-changes")
	var store:=Store.new(folder);store.load_state()
	var farm:=Farm.new(20000);var decorations: Dictionary=Decorations.new().snapshot()
	_expect(store.save(farm.snapshot(),decorations).ok,"Admission fixture is committed")
	var original: String=FileAccess.get_file_as_string(folder.path_join(Store.MAIN))
	for changed: String in ["{truncated",original+" "]:
		_write(folder.path_join(Store.MAIN),changed)
		var result: Dictionary=store.save(farm.snapshot(),decorations)
		_expect(not result.ok and result.kind=="changed_on_disk" and FileAccess.get_file_as_string(folder.path_join(Store.MAIN))==changed,"Even invalid or equivalent JSON changes invalidate the admitted main")
	_write(folder.path_join(Store.MAIN),original)
	var invalid: Dictionary=farm.snapshot();invalid.fields.field_01.cells.cell_01.growth_seconds=-1
	var result: Dictionary=store.save(invalid,decorations)
	_expect(not result.ok and result.kind=="invalid_state" and FileAccess.get_file_as_string(folder.path_join(Store.MAIN))==original,"New candidates still receive full validation before any write")
	_expect(store.save(farm.snapshot(),decorations).ok,"Restoring the exact admitted main permits retry")


func _test_current_boundaries() -> void:
	var plan := Farm.Plan.new()
	for i: int in plan.fields.size():
		plan.fields[i] = Farm.Plan.resized_field(plan.fields[i],8,8,Vector2(5.0,3.81))
	var farm := Farm.new(10000.0,plan.snapshot())
	var data: Dictionary = farm.snapshot()
	for field_id: String in farm.field_ids():
		for cell_id: String in farm.cell_ids(field_id):
			data.fields[field_id].cells[cell_id] = {"crop_id": "radish", "growth_seconds": 4321.123456789, "last_settled_utc_seconds": Farm.MAX_TIME_SECONDS, "watered": true, "ground":"ready"}
	for crop_id: String in Farm.Crops.crop_ids():
		data.harvested[crop_id] = Farm.MAX_HARVEST_COUNT
	var decorations := Decorations.new()
	decorations.unlock(data.harvested)
	decorations.place("pot", "ground_04", 3)
	decorations.place("flowerpot", "ground_03", 2)
	decorations.place("lantern", "hanging_04", 0)
	var payload: Dictionary = {"version": Store.VERSION, "farm": data, "decorations": decorations.snapshot()}
	var text: String = JSON.stringify(payload, "\t")
	var bytes: int = text.to_utf8_buffer().size()
	_expect(bytes < Store.MAX_BYTES, "Full 384-cell state with layout and long numeric values fits bounded read limit")
	print("FARM_CURRENT_SIZE full_384_cells_bytes=%d max_bytes=%d" % [bytes, Store.MAX_BYTES])
	var full_dir: String = test_root.path_join("full-384")
	var full_store := Store.new(full_dir)
	full_store.load_state()
	_expect(full_store.save(data, decorations.snapshot()).ok, "384-cell schema saves under current limit")
	_expect(Store.new(full_dir).load_state().ok, "384-cell bounded payload roundtrips")
	for flaw: String in ["missing_cell", "unknown_cell", "invalid_growth", "invalid_decoration"]:
		var candidate: Dictionary = payload.duplicate(true)
		match flaw:
			"missing_cell": candidate.farm.fields.field_06.cells.erase("cell_16")
			"unknown_cell":
				candidate.farm.fields.field_06.cells.cell_99 = candidate.farm.fields.field_06.cells.cell_16
				candidate.farm.fields.field_06.cells.erase("cell_16")
			"invalid_growth": candidate.farm.fields.field_02.cells.cell_01.growth_seconds = -1.0
			"invalid_decoration": candidate.decorations.pot.slot_id = "ground_99"
		var folder: String = test_root.path_join(flaw)
		DirAccess.make_dir_recursive_absolute(folder)
		var original: String = JSON.stringify(candidate)
		_write(folder.path_join(Store.MAIN), original)
		var store := Store.new(folder)
		_expect(store.load_state().kind == "corrupt" and not store.save(data, decorations.snapshot()).ok, "Malformed or mislabeled schema locks writes: " + flaw)
		_expect(FileAccess.get_file_as_string(folder.path_join(Store.MAIN)) == original, "Rejected payload preserved: " + flaw)
	# Current mixed-cell data and decoration state persist together, including cell16.
	var mixed := Farm.new(20000.0)
	mixed.sow("field_01", "cell_01", "celery", 20000.0)
	mixed.sow("field_01", "cell_16", "garlic", 20000.0)
	mixed.water("field_01", "cell_16", 20001.0)
	var mixed_dir: String = test_root.path_join("mixed-roundtrip")
	var mixed_store := Store.new(mixed_dir)
	mixed_store.load_state()
	_expect(mixed_store.save(mixed.snapshot(), decorations.snapshot()).ok, "Mixed field saves")
	var loaded: Dictionary = Store.new(mixed_dir).load_state()
	_expect(loaded.farm == mixed.snapshot() and loaded.decorations == decorations.snapshot(), "Mixed crops, independent water and decorations restore exactly")
	var construction: Dictionary=mixed.snapshot().layout
	construction.construction={"east_land":[],"land":[[0,6,3,2.5]],"trellis":[4.9,.8,2.4,-5.8,1.05,0],"buildings":{"house":[],"kitchen":[]},"bridge":[5.40000009536743,-.10000038146973,11,.10000038146973,1.2,1],"flocks":{"duck":{"count":7,"area":[-12,4,4,6]},"goose":{"count":4,"area":[]},"hen":{"count":5,"area":[]}}}
	_expect(mixed.apply_layout(construction,20001.0).ok,"Construction parameters join the farm state")
	_expect(mixed_store.save(mixed.snapshot(),decorations.snapshot()).ok,"Construction parameters save")
	var built: Dictionary=Store.new(mixed_dir).load_state()
	_expect(built.ok and built.farm==mixed.snapshot(),"Construction numeric types and all flock identities roundtrip exactly")
	construction=mixed.snapshot().layout
	construction.construction.bridge[5]=0
	_expect(mixed.apply_layout(construction,20001.0).ok and mixed_store.save(mixed.snapshot(),decorations.snapshot()).ok,"Flat bridge style saves")
	built=Store.new(mixed_dir).load_state()
	_expect(built.ok and built.farm==mixed.snapshot(),"Bridge style is restored with all structure parameters")
	for style: Variant in [-1,2,.5,"flat",INF]:
		var invalid: Dictionary=mixed.snapshot().layout
		invalid.construction.bridge[5]=style
		_expect(Farm.Plan.from_snapshot(invalid)==null,"Unknown bridge style is rejected: "+str(style))
	construction=mixed.snapshot().layout
	construction.construction.buildings={"house":[.8,8.85,15],"kitchen":[-7,8,-15]}
	_expect(mixed.apply_layout(construction,20002.0).ok,"Independent building poses join the farm state")
	_expect(mixed_store.save(mixed.snapshot(),decorations.snapshot()).ok,"Building poses save")
	built=Store.new(mixed_dir).load_state()
	_expect(built.ok and built.farm==mixed.snapshot(),"Building poses and crops roundtrip without float noise")
	for values: Array in [[INF,0,0],[0,0,180],[25,0,0],[0,0]]:
		var invalid: Dictionary=mixed.snapshot().layout
		invalid.construction.buildings.house=values
		_expect(Farm.Plan.from_snapshot(invalid)==null,"Malformed building pose rejected: "+str(values))


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null, "Fixture must be writable")
	file.store_string(text)
	file.close()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
