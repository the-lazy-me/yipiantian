extends SceneTree
## M11-03 resolution sidecar store: envelope, world identity, bounded command
## journal, strict state validation and atomic replacement. Pure filesystem test,
## no scene, network or system clock. Everything lives under
## .local/verification/resolutions-store-<ticks>/.

const Store = preload("res://world/resolutions_store.gd")
const Resolution = preload("res://world/resolution_state.gd")

const WORLD: String = "world-resolutions-store"
const OTHER_WORLD: String = "world-resolutions-other"
const START: float = 1800000000.0
const HOUR: float = 3600.0
const VOTE_START: float = START + 60.0
const VOTE_END: float = VOTE_START + HOUR
const EFFECTIVE_UTC: float = VOTE_END + HOUR

const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"

var root_dir: String = ""
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir() \
		.path_join(".local/verification/resolutions-store-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)

	_test_shape_constants()
	_test_missing_is_empty_and_writes_nothing()
	_test_roundtrip()
	_test_world_identity()
	_test_command_journal()
	_test_corrupt_unsupported_and_too_large()
	_test_atomicity()
	_test_save_guards()

	for failure: String in failures:
		push_error(failure)
	print("RESOLUTIONS_STORE_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), root_dir])
	quit(0 if failures.is_empty() else 1)


func _test_shape_constants() -> void:
	_expect(Store.VERSION == 1, "The sidecar envelope stays at version 1")
	_expect(Store.MAX_COMMANDS == 64, "The replay journal is bounded at 64 commands")
	_expect(Store.MAIN == "resolutions.json" and Store.PENDING == "resolutions.pending.json",
		"The sidecar keeps its main and pending names")


func _test_missing_is_empty_and_writes_nothing() -> void:
	var directory: String = _directory("missing")
	var store := Store.new(directory)
	var loaded: Dictionary = store.load_state(WORLD)
	_expect(bool(loaded.get("ok", false)) and str(loaded.get("kind", "")) == "missing",
		"A missing document loads as a fresh empty table")
	_expect(Resolution.valid(loaded.get("state")) and int(loaded.state.rules_version) == 0
			and (loaded.state.resolutions as Dictionary).is_empty(),
		"The fresh table is the empty rules document")
	_expect((loaded.get("commands", null) as Array).is_empty(),
		"A fresh table has no replay journal")
	_expect(not FileAccess.file_exists(directory.path_join(Store.MAIN)),
		"Loading a missing document writes no resolutions.json")
	_expect(store.world_id == WORLD, "The successful load fixes the world identity")
	_expect(not bool(Store.new(directory).load_state("").get("ok", true)),
		"An empty world identity is refused")

	var saved: Dictionary = store.save_state(Resolution.empty())
	_expect(bool(saved.get("ok", false)), "A store that loaded its world can save it")
	_expect(FileAccess.file_exists(directory.path_join(Store.MAIN)),
		"The first save creates the sidecar")
	_expect(not FileAccess.file_exists(directory.path_join(Store.PENDING)),
		"A successful save leaves no pending file behind")


func _test_roundtrip() -> void:
	var directory: String = _directory("roundtrip")
	var store := Store.new(directory)
	_expect(bool(store.load_state(WORLD).get("ok", false)), "The roundtrip world opens")
	var state: Dictionary = _revoked_state()
	var commands: Array = [
		_command("cmd-1", "propose", {"ok": true, "reason": ""}),
		_command("cmd-2", "vote", {"ok": true, "reason": "", "approvals": [PLAYER_B]}),
	]
	var saved: Dictionary = store.save_state(state, commands)
	_expect(bool(saved.get("ok", false)), "A valid state and journal save")
	var before: String = FileAccess.get_file_as_string(directory.path_join(Store.MAIN))
	var reloaded: Dictionary = Store.new(directory).load_state(WORLD)
	_expect(bool(reloaded.get("ok", false)) and str(reloaded.get("kind", "")) == "loaded",
		"Reopening the store loads the saved sidecar")
	_expect(reloaded.get("state") == state, "The loaded state equals the saved state")
	_expect(reloaded.get("commands") == commands, "The bounded journal round-trips exactly")
	_expect(FileAccess.get_file_as_string(directory.path_join(Store.MAIN)) == before,
		"Loading does not rewrite the sidecar")

	var envelope: Dictionary = _read_json(directory.path_join(Store.MAIN))
	_expect(int(envelope.get("version", -1)) == Store.VERSION,
		"The envelope records version 1")
	_expect(str(envelope.get("world_id", "")) == WORLD,
		"The envelope records the world identity")
	_expect(envelope.get("state") is Dictionary and Resolution.valid(envelope.get("state")),
		"The stored state is a strict rules document")
	_expect(envelope.has("commands") and envelope.get("commands") is Array,
		"The envelope carries the journal as an array")
	for key: String in Store.ENVELOPE_KEYS:
		_expect(envelope.has(key), "The envelope carries %s" % key)
	_expect(envelope.size() == Store.ENVELOPE_KEYS.size(),
		"The envelope has exactly the four documented keys")

	var loaded_state: Dictionary = reloaded.state
	_expect(loaded_state.get("rules_version") is int
			and loaded_state.resolutions["res_1"].get("revision") is int
			and loaded_state.resolutions["res_1"].get("effective_version") is int
			and loaded_state.resolutions["res_1"].get("revoked_version") is int,
		"Counts read back as integers, not integral floats")
	_expect(Resolution.valid(loaded_state), "The normalized state is still strictly valid")

	var empty_dir: String = _directory("roundtrip-empty")
	var empty_store := Store.new(empty_dir)
	empty_store.load_state(WORLD)
	_expect(bool(empty_store.save_state(Resolution.empty()).get("ok", false)),
		"An empty document round-trips")
	_expect(Resolution.valid(Store.new(empty_dir).load_state(WORLD).get("state")),
		"The empty document loads as a valid rules document")


func _test_world_identity() -> void:
	var directory: String = _directory("world")
	var store := Store.new(directory)
	store.load_state(WORLD)
	_expect(bool(store.save_state(_effective_state()).get("ok", false)),
		"The world document saves")
	var bytes_before: String = FileAccess.get_file_as_string(directory.path_join(Store.MAIN))
	var foreign: Dictionary = Store.new(directory).load_state(OTHER_WORLD)
	_expect(not bool(foreign.get("ok", true)) and str(foreign.get("kind", "")) \
		== "world_mismatch", "A document from another world is refused")
	_expect(FileAccess.get_file_as_string(directory.path_join(Store.MAIN)) == bytes_before,
		"A refused foreign load does not rewrite the sidecar")
	var saved_after: Dictionary = Store.new(directory).load_state(OTHER_WORLD)
	_expect(not bool(saved_after.get("ok", true)), "The foreign store cannot adopt the document")
	# A foreign store still refuses to save: it never performed a successful load.
	_expect(not bool(Store.new(directory).save_state(Resolution.empty()).get("ok", true)),
		"A store without a loaded world refuses to save")
	var fresh_foreign: Store = Store.new(_directory("world-fresh"))
	_expect(bool(fresh_foreign.load_state(OTHER_WORLD).get("ok", false)),
		"A world with no document starts empty under its own identity")
	_expect(bool(fresh_foreign.save_state(Resolution.empty()).get("ok", false)),
		"The other world can then save its own document")
	_expect(str(_read_json(fresh_foreign.directory.path_join(Store.MAIN)).get("world_id", "")) \
		== OTHER_WORLD, "The saved document names the loading world")


func _test_command_journal() -> void:
	var directory: String = _directory("journal")
	var store := Store.new(directory)
	store.load_state(WORLD)
	var full: Array = []
	for index: int in Store.MAX_COMMANDS:
		full.append(_command("cmd-%02d" % index, "propose", {"ok": true, "reason": ""}))
	_expect(bool(store.save_state(Resolution.empty(), full).get("ok", false)),
		"A journal of exactly the upper bound saves")
	var loaded: Dictionary = Store.new(directory).load_state(WORLD)
	_expect(bool(loaded.get("ok", false))
			and (loaded.get("commands", []) as Array).size() == Store.MAX_COMMANDS,
		"The full journal round-trips at the upper bound")
	var overflow: Array = full.duplicate(true)
	overflow.append(_command("cmd-overflow", "propose", {"ok": true, "reason": ""}))
	_expect(str(store.save_state(Resolution.empty(), overflow).get("kind", "")) \
		== "invalid_commands", "A journal over the upper bound is refused")
	var duplicate_id: Dictionary = store.save_state(Resolution.empty(), [
		_command("cmd-1", "a", {}), _command("cmd-1", "b", {}),
	])
	_expect(str(duplicate_id.get("kind", "")) == "invalid_commands",
		"Duplicate command ids are refused")
	var empty_id: Dictionary = store.save_state(Resolution.empty(), [
		{"command_id": "", "payload": "", "result": {}},
	])
	_expect(str(empty_id.get("kind", "")) == "invalid_commands",
		"An empty command id is refused")
	var unknown_key: Dictionary = store.save_state(Resolution.empty(), [
		{"command_id": "cmd", "payload": "", "result": {}, "extra": 1},
	])
	_expect(str(unknown_key.get("kind", "")) == "invalid_commands",
		"An unknown journal key is refused")
	var bad_payload: Dictionary = store.save_state(Resolution.empty(), [
		{"command_id": "cmd", "payload": 1, "result": {}},
	])
	_expect(str(bad_payload.get("kind", "")) == "invalid_commands",
		"A non-string payload is refused")
	var bad_result: Dictionary = store.save_state(Resolution.empty(), [
		{"command_id": "cmd", "payload": "", "result": []},
	])
	_expect(str(bad_result.get("kind", "")) == "invalid_commands",
		"A non-dictionary result is refused")


func _test_corrupt_unsupported_and_too_large() -> void:
	var corrupt_dir: String = _directory("corrupt")
	var corrupt_path: String = corrupt_dir.path_join(Store.MAIN)
	_write(corrupt_path, "{not json")
	var corrupt: Dictionary = Store.new(corrupt_dir).load_state(WORLD)
	_expect(not bool(corrupt.get("ok", true)) and str(corrupt.get("kind", "")) == "corrupt",
		"A sidecar that is not JSON is refused")
	_expect(FileAccess.get_file_as_string(corrupt_path) == "{not json",
		"A corrupt sidecar is not overwritten by an empty table")

	var shape_dir: String = _directory("corrupt-shape")
	_write(shape_dir.path_join(Store.MAIN), JSON.stringify({"version": Store.VERSION,
		"world_id": WORLD, "state": Resolution.empty()}))
	_expect(str(Store.new(shape_dir).load_state(WORLD).get("kind", "")) == "corrupt",
		"An envelope missing the journal key is refused")
	_write(shape_dir.path_join(Store.MAIN), JSON.stringify({"version": Store.VERSION,
		"world_id": WORLD, "state": Resolution.empty(), "commands": [], "extra": 1}))
	_expect(str(Store.new(shape_dir).load_state(WORLD).get("kind", "")) == "corrupt",
		"An envelope with an unknown key is refused")
	_write(shape_dir.path_join(Store.MAIN), JSON.stringify({"version": Store.VERSION,
		"world_id": WORLD, "state": {"rules_version": 0, "resolutions": {}, "extra": 1},
		"commands": []}))
	_expect(str(Store.new(shape_dir).load_state(WORLD).get("kind", "")) == "corrupt",
		"A state that fails ResolutionState.valid() is refused")

	var bad_journal_dir: String = _directory("corrupt-journal")
	var bad_rows: Array = []
	for index: int in Store.MAX_COMMANDS + 1:
		bad_rows.append(_command("cmd-%02d" % index, "p", {}))
	_write(bad_journal_dir.path_join(Store.MAIN), JSON.stringify({"version": Store.VERSION,
		"world_id": WORLD, "state": Resolution.empty(), "commands": bad_rows}))
	_expect(str(Store.new(bad_journal_dir).load_state(WORLD).get("kind", "")) == "corrupt",
		"An over-capacity stored journal is refused")

	var version_dir: String = _directory("unsupported")
	_write(version_dir.path_join(Store.MAIN), JSON.stringify({"version": Store.VERSION + 1,
		"world_id": WORLD, "state": Resolution.empty(), "commands": []}))
	_expect(str(Store.new(version_dir).load_state(WORLD).get("kind", "")) == "unsupported",
		"An unsupported envelope version is refused")

	var huge_dir: String = _directory("too-large")
	var huge_path: String = huge_dir.path_join(Store.MAIN)
	_write(huge_path, JSON.stringify({"version": Store.VERSION, "world_id": WORLD,
		"state": Resolution.empty(), "commands": [],
		"padding": "x".repeat(Store.MAX_BYTES + 1)}))
	_expect(str(Store.new(huge_dir).load_state(WORLD).get("kind", "")) == "too_large",
		"A sidecar over the byte budget is refused")
	_expect(FileAccess.get_file_as_string(huge_path).length() > Store.MAX_BYTES,
		"The oversized sidecar is left untouched")

	var oversize: String = "x".repeat(Store.MAX_BYTES + 1)
	var large_state: Dictionary = _effective_state()
	var large_store: Store = Store.new(_directory("save-too-large"))
	large_store.load_state(WORLD)
	_expect(str(large_store.save_state(large_state,
		[_command("huge", oversize, {"ok": true})]).get("kind", "")) == "too_large",
		"A save that would exceed the byte budget is refused")
	_expect(not FileAccess.file_exists(large_store.directory.path_join(Store.MAIN)),
		"A refused oversized save writes no main document")


func _test_atomicity() -> void:
	# A directory at the pending path makes the staged write fail for real.
	var directory: String = _directory("atomic")
	var store := Store.new(directory)
	store.load_state(WORLD)
	_expect(bool(store.save_state(_proposed_state()).get("ok", false)),
		"The atomicity baseline saves")
	var committed: String = FileAccess.get_file_as_string(directory.path_join(Store.MAIN))
	DirAccess.make_dir_absolute(directory.path_join(Store.PENDING))
	var failed: Dictionary = store.save_state(_revoked_state())
	_expect(not bool(failed.get("ok", true)), "A staged write failure is reported")
	_expect(not str(failed.get("kind", "")).is_empty(),
		"The write failure carries a named kind")
	_expect(FileAccess.get_file_as_string(directory.path_join(Store.MAIN)) == committed,
		"A failed save leaves the committed document byte-identical")
	_expect(DirAccess.dir_exists_absolute(directory.path_join(Store.PENDING)),
		"The failed save produced no half document, only the obstruction")
	DirAccess.remove_absolute(directory.path_join(Store.PENDING))
	_expect(bool(store.save_state(_revoked_state()).get("ok", false)),
		"The same save succeeds after the obstruction is removed")
	_expect(Resolution.valid(Store.new(directory).load_state(WORLD).get("state")),
		"The retried document loads as a valid state")

	# A failed first save must not leave a main document behind at all.
	var fresh_dir: String = _directory("atomic-fresh")
	var fresh := Store.new(fresh_dir)
	fresh.load_state(WORLD)
	DirAccess.make_dir_absolute(fresh_dir.path_join(Store.PENDING))
	_expect(not bool(fresh.save_state(_revoked_state()).get("ok", true)),
		"A first save can fail at the staging step")
	_expect(not FileAccess.file_exists(fresh_dir.path_join(Store.MAIN)),
		"A failed first save creates no main document")
	DirAccess.remove_absolute(fresh_dir.path_join(Store.PENDING))


func _test_save_guards() -> void:
	var directory: String = _directory("guards")
	var unopened := Store.new(directory)
	_expect(not bool(unopened.save_state(Resolution.empty()).get("ok", true)),
		"Saving before a successful load is refused")
	_expect(not FileAccess.file_exists(directory.path_join(Store.MAIN)),
		"A refused save before load writes nothing")

	var store := Store.new(directory)
	store.load_state(WORLD)
	_expect(str(store.save_state({"rules_version": 0}).get("kind", "")) == "invalid_state",
		"An invalid state is refused on save")
	_expect(not bool(store.save_state({"rules_version": 0}).get("ok", true)),
		"Refused saves report failure")
	_expect(not FileAccess.file_exists(directory.path_join(Store.MAIN)),
		"Refused saves create no document")

	var unsafe := Store.new("relative-path")
	_expect(str(unsafe.load_state(WORLD).get("kind", "")) == "unsafe_path",
		"A relative directory is refused")


# ------------------------------------------------------------------ fixtures

func _proposal() -> Dictionary:
	return {
		"kind": Resolution.KIND_PUBLIC_WORKS,
		"title": "修桥",
		"vote_start_utc": VOTE_START,
		"vote_end_utc": VOTE_END,
		"effective_utc": EFFECTIVE_UTC,
	}


func _proposed_state() -> Dictionary:
	return Resolution.propose(Resolution.empty(), "res_1", PLAYER_A, _proposal(),
		START).state


func _effective_state() -> Dictionary:
	var state: Dictionary = _proposed_state()
	state = Resolution.vote(state, "res_1", PLAYER_B, true, VOTE_START + 10.0).state
	state = Resolution.vote(state, "res_1", PLAYER_C, true, VOTE_START + 20.0).state
	state = Resolution.close(state, "res_1", VOTE_END).state
	return Resolution.activate(state, "res_1", EFFECTIVE_UTC).state


func _revoked_state() -> Dictionary:
	var state: Dictionary = _effective_state()
	return Resolution.revoke(state, "res_1", PLAYER_B, EFFECTIVE_UTC + 10.0).state


func _command(command_id: String, payload: String, result: Dictionary) -> Dictionary:
	return {"command_id": command_id, "payload": payload, "result": result}


# ------------------------------------------------------------------- helpers

func _directory(name: String) -> String:
	var path: String = root_dir.path_join(name)
	DirAccess.make_dir_recursive_absolute(path)
	return path


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
