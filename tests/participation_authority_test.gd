extends SceneTree
## M12-02 participation authority wiring: the pure participation rules are loaded,
## persisted and executed through the authoritative headless world.
##
## Covers: the hostless room refusing every write instead of inventing a host,
## the implicit peace declaration of a hosted world that is not written until the
## first accepted command, a higher-risk declaration with its real scope/caps,
## idempotent replay by command id and command-conflict on a changed payload,
## participant consent and withdrawal with its fixed delay, named rule refusals,
## restart recovery, foreign-host/foreign-world load refusals that never
## overwrite the stored document, atomic sidecar round trips for corrupt and
## unsupported documents, write-time copy on refused declarations, and a stable
## read-only view shape and ordering.
##
## No UI, transport, engagement settlement or Windows path is exercised here.

const HeadlessWorld = preload("res://world/headless_world.gd")
const Participation = preload("res://conflict/participation_state.gd")
const ParticipationStore = preload("res://world/participation_store.gd")

const START: float = 1800000000.0
const DAY: float = 86400.0
const WORLD: String = "world-participation-authority"
const OTHER_WORLD: String = "world-participation-other"
const HOST: String = "player_00000000000000000000000000000001"
const HOST_2: String = "player_00000000000000000000000000000009"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"

var checks: int = 0
var failures: Array[String] = []
var root_dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = _repo().path_join(
		".local/verification/participation-authority-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)
	_test_hostless_open()
	_test_missing_document_is_peace()
	_test_regime_declaration_and_view()
	_test_regime_replay_and_conflict()
	_test_participant_consent()
	_test_withdrawal()
	_test_command_validation_and_peace()
	_test_restart()
	_test_load_mismatch()
	_test_corrupt_unsupported_and_store()
	_test_write_time_copy()
	for failure: String in failures:
		push_error(failure)
	print("PARTICIPATION_AUTHORITY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_hostless_open() -> void:
	var directory: String = _dir("hostless")
	var world := HeadlessWorld.new()
	var opened: Dictionary = world.open(directory, START, WORLD, "")
	_expect(bool(opened.get("ok", false)), "A room without a host player still opens")
	_expect(world.participation.is_empty(),
		"A hostless room has no participation document in memory")
	var view: Dictionary = world.participation_view()
	_expect(not bool(view.available), "A hostless room reports an unavailable view")
	_expect((view.areas as Array).is_empty() and (view.windows as Array).is_empty() \
		and (view.participants as Array).is_empty() and (view.losses as Array).is_empty(),
		"The hostless view carries no rows")
	var result: Dictionary = world.execute_participation("regime", HOST, {
		"declaration": _limited_declaration("decl-hostless", START, [AREA_A],
			[WINDOW_A]),
	}, "cmd-hostless-regime")
	_expect(not bool(result.ok) and result.reason == "no_host",
		"A hostless room refuses a regime declaration with no_host")
	_expect(not FileAccess.file_exists(_participation_file(directory)),
		"A hostless room never writes participation.json")


func _test_missing_document_is_peace() -> void:
	var directory: String = _dir("peace-default")
	var world := _open("peace-default", HOST)
	var view: Dictionary = world.participation_view()
	_expect(bool(view.available), "A hosted room exposes a participation view")
	_expect(str(view.host) == HOST, "The view names the room host")
	_expect(int(view.sequence) == 0, "A fresh participation document starts at sequence 0")
	_expect(str((view.regime as Dictionary).get("tier", "")) == Participation.TIER_PEACE,
		"A missing document is the implicit peace declaration")
	_expect(int((view.regime as Dictionary).get("revision", -1)) == 0,
		"The implicit peace declaration is revision 0")
	_expect(str((view.regime as Dictionary).get("declared_by", "")) == "",
		"The implicit peace declaration has no declarer")
	_expect(Participation.valid(world.participation),
		"The implicit peace document is a valid participation document")
	_expect(not FileAccess.file_exists(_participation_file(directory)),
		"Opening a hosted room does not write the implicit peace document")
	var store := ParticipationStore.new(directory)
	var missing: Dictionary = store.load_state(WORLD, HOST)
	_expect(bool(missing.ok) and missing.kind == "missing",
		"The missing document is reported as missing, not as loaded")
	_expect(str(missing.state.host) == HOST and str(missing.state.world_id) == WORLD,
		"The missing-document state names the requested world and host")


func _test_regime_declaration_and_view() -> void:
	var directory: String = _dir("regime")
	var world := _open("regime", HOST)
	_freeze(world)
	var now: float = world.authority_now_utc()
	var declaration: Dictionary = _limited_declaration("decl-1", now,
		[AREA_B, AREA_A], [WINDOW_B, WINDOW_A], 500, 100)
	var result: Dictionary = world.execute_participation("regime", HOST, {
		"declaration": declaration,
	}, "cmd-regime-1")
	_expect(bool(result.ok) and not bool(result.duplicate),
		"The host publishes a limited higher-risk declaration")
	_expect(result.reason == "", "The accepted declaration has no reason")
	_expect(FileAccess.file_exists(_participation_file(directory)),
		"An accepted declaration writes participation.json")

	var view: Dictionary = world.participation_view()
	var regime: Dictionary = view.regime
	_expect(bool(view.available), "The declared world stays available")
	_expect(str(regime.tier) == Participation.TIER_LIMITED, "The tier is limited")
	_expect(int(regime.revision) == 1, "The declaration increases the revision to 1")
	_expect(str(regime.declaration_id) == "decl-1", "The view carries the declaration id")
	_expect(str(regime.declared_by) == HOST, "declared_by is the host identity")
	_expect(float(regime.declared_utc) == now, "The declaration is stamped with the authority time")
	_expect(float(regime.effective_utc) == now, "The declaration takes effect at its effective time")
	_expect(bool(regime.higher_risk), "The limited regime is marked higher risk")
	_expect(int(regime.loss_cap) == 500, "The view carries the online loss cap")
	_expect(int(regime.offline_loss_cap) == 100, "The view carries the offline loss cap")
	_expect(regime.area_ids == ["area_a", "area_b"], "The live area ids are sorted")
	_expect(regime.window_ids == ["window_a", "window_b"], "The live window ids are sorted")
	_expect((view.areas as Array).size() == 2, "The view exposes both areas")
	_expect(str((view.areas as Array)[0].id) == "area_a"
		and str((view.areas as Array)[1].id) == "area_b",
		"The view sorts areas by id ascending")
	_expect((view.windows as Array).size() == 2, "The view exposes both windows")
	_expect(str((view.windows as Array)[0].id) == "window_a"
		and str((view.windows as Array)[1].id) == "window_b",
		"The view sorts windows by id ascending")
	_expect((view.participants as Array).is_empty(), "The declaration adds no participants")
	_expect((view.losses as Array).is_empty(), "A fresh declaration has no losses")
	_expect(not view.has("command_results") and not view.has("engagements"),
		"The view never exposes command replay rows or engagements")

	var loaded: Dictionary = ParticipationStore.new(directory).load_state(WORLD, HOST)
	_expect(bool(loaded.ok) and loaded.kind == "loaded",
		"The accepted declaration reloads from the sidecar")
	_expect(int(loaded.state.regime.revision) == 1,
		"The stored document keeps the new revision")


func _test_regime_replay_and_conflict() -> void:
	var directory: String = _dir("replay")
	var world := _open("replay", HOST)
	_freeze(world)
	var now: float = world.authority_now_utc()
	var declaration: Dictionary = _limited_declaration("decl-replay", now, [AREA_A],
		[WINDOW_A])
	var first: Dictionary = world.execute_participation("regime", HOST, {
		"declaration": declaration,
	}, "cmd-replay-regime")
	_expect(bool(first.ok) and not bool(first.duplicate),
		"The first regime command commits")
	var bytes_before: String = _file_text(_participation_file(directory))
	var sequence_before: int = int(world.participation_view().sequence)

	var replay: Dictionary = world.execute_participation("regime", HOST, {
		"declaration": declaration,
	}, "cmd-replay-regime")
	_expect(bool(replay.ok) and bool(replay.duplicate),
		"Replaying the same command id and declaration is a duplicate")
	_expect(_file_text(_participation_file(directory)) == bytes_before,
		"A duplicate replay leaves the stored document byte-identical")
	_expect(int(world.participation_view().sequence) == sequence_before,
		"A duplicate replay does not advance the sequence")

	var changed: Dictionary = _limited_declaration("decl-replay-2", now, [AREA_A],
		[WINDOW_A])
	var conflict: Dictionary = world.execute_participation("regime", HOST, {
		"declaration": changed,
	}, "cmd-replay-regime")
	_expect(not bool(conflict.ok) and conflict.reason == "command_conflict",
		"Reusing a command id with another declaration is a command_conflict")
	_expect(_file_text(_participation_file(directory)) == bytes_before,
		"A command conflict leaves the stored document byte-identical")


func _test_participant_consent() -> void:
	var directory: String = _dir("consent")
	var world := _open("consent", HOST)
	_freeze(world)
	var now: float = world.authority_now_utc()
	_expect_ok(world.execute_participation("regime", HOST, {
		"declaration": _limited_declaration("decl-consent", now, [AREA_A], [WINDOW_A]),
	}, "cmd-regime-consent"), "The host declares a limited regime for consent")
	# C consents first so the view has to sort B before C.
	_expect_ok(world.execute_participation("declare", PLAYER_C, {
		"role": "defender",
	}, "cmd-consent-c"), "C consents as defender")
	var consent_b: Dictionary = world.execute_participation("declare", PLAYER_B, {
		"role": "attacker",
	}, "cmd-consent-b")
	_expect(bool(consent_b.ok) and not bool(consent_b.duplicate),
		"B consents as attacker")

	var view: Dictionary = world.participation_view()
	var rows: Array = view.participants
	_expect(rows.size() == 2, "Both consenting players appear in the view")
	_expect(str(rows[0].participant) == PLAYER_B and str(rows[1].participant) == PLAYER_C,
		"The view sorts participants by player id ascending")
	var b: Dictionary = rows[0]
	_expect(bool(b.attacker) and not bool(b.defender),
		"B is shown as an attacker only")
	_expect(int(b.consent_revision) == 1, "B consent is tied to revision 1")
	_expect(float(b.consent_utc) == now, "B consent is stamped with the authority time")
	var c: Dictionary = rows[1]
	_expect(bool(c.defender) and not bool(c.attacker),
		"C is shown as a defender only")
	_expect((view.losses as Array).is_empty(), "Consent alone produces no losses")

	var replay: Dictionary = world.execute_participation("declare", PLAYER_B, {
		"role": "attacker",
	}, "cmd-consent-b")
	_expect(bool(replay.ok) and bool(replay.duplicate),
		"Replaying B's consent command is a duplicate")
	var role_conflict: Dictionary = world.execute_participation("declare", PLAYER_B, {
		"role": "defender",
	}, "cmd-consent-b")
	_expect(not bool(role_conflict.ok) and role_conflict.reason == "command_conflict",
		"Reusing B's command id with another role is a command_conflict")


func _test_withdrawal() -> void:
	var world := _open("withdraw", HOST)
	_freeze(world)
	var now: float = world.authority_now_utc()
	_expect_ok(world.execute_participation("regime", HOST, {
		"declaration": _limited_declaration("decl-withdraw", now, [AREA_A], [WINDOW_A]),
	}, "cmd-regime-withdraw"), "The host declares a limited regime for withdrawal")
	_expect_ok(world.execute_participation("declare", PLAYER_B, {
		"role": "attacker",
	}, "cmd-withdraw-consent"), "B consents before withdrawing")

	var result: Dictionary = world.execute_participation("withdraw", PLAYER_B, {},
		"cmd-withdraw-b")
	_expect(bool(result.ok) and not bool(result.duplicate), "B withdraws")
	var row: Dictionary = _participant(world.participation_view(), PLAYER_B)
	_expect(float(row.withdraw_utc) == now, "The withdrawal records its authority time")
	_expect(float(row.withdraw_effective_utc) == now \
		+ Participation.WITHDRAWAL_DELAY_SECONDS,
		"The withdrawal becomes effective after the fixed delay")
	_expect(bool(row.attacker), "A pending withdrawal keeps the existing role flags")

	var rejoin: Dictionary = world.execute_participation("declare", PLAYER_B, {
		"role": "attacker",
	}, "cmd-withdraw-rejoin")
	_expect(not bool(rejoin.ok) and rejoin.reason == "withdrawal_pending",
		"Consent is refused while a withdrawal is pending")
	var replay: Dictionary = world.execute_participation("withdraw", PLAYER_B, {},
		"cmd-withdraw-b")
	_expect(bool(replay.ok) and bool(replay.duplicate),
		"Replaying the same withdrawal command is a duplicate")
	var second: Dictionary = world.execute_participation("withdraw", PLAYER_B, {},
		"cmd-withdraw-b-2")
	_expect(not bool(second.ok) and second.reason == "withdrawal_pending",
		"A different withdrawal command is still refused while one is pending")


func _test_command_validation_and_peace() -> void:
	var directory: String = _dir("validation")
	var world := _open("validation", HOST)
	_freeze(world)
	var now: float = world.authority_now_utc()
	var declaration: Dictionary = _limited_declaration("decl-validation", now,
		[AREA_A], [WINDOW_A])
	var unknown: Dictionary = world.execute_participation("engage", HOST, {
		"declaration": declaration,
	}, "cmd-unknown")
	_expect(not bool(unknown.ok) and unknown.reason == "unknown_action",
		"An unknown action is refused")
	var no_id: Dictionary = world.execute_participation("regime", HOST, {
		"declaration": declaration,
	}, "")
	_expect(not bool(no_id.ok) and no_id.reason == "invalid_command",
		"An empty command id is refused")
	var no_declaration: Dictionary = world.execute_participation("regime", HOST, {},
		"cmd-empty-declaration")
	_expect(not bool(no_declaration.ok) and no_declaration.reason == "invalid_declaration",
		"An empty declaration is refused")
	var peace: Dictionary = world.execute_participation("declare", PLAYER_B, {
		"role": "attacker",
	}, "cmd-peace-consent")
	_expect(not bool(peace.ok) and peace.reason == "peace",
		"Consent is refused while the regime is peace")
	var view: Dictionary = world.participation_view()
	_expect(int((view.regime as Dictionary).revision) == 0,
		"Refused commands leave the peace regime at revision 0")
	_expect((view.participants as Array).is_empty(),
		"Refused commands create no participant")
	_expect(not FileAccess.file_exists(_participation_file(directory)),
		"Refused commands do not write participation.json")


func _test_restart() -> void:
	var directory: String = _dir("restart")
	var world := _open("restart", HOST)
	_freeze(world)
	var now: float = world.authority_now_utc()
	var declaration: Dictionary = _limited_declaration("decl-restart", now,
		[AREA_A], [WINDOW_A])
	_expect_ok(world.execute_participation("regime", HOST, {
		"declaration": declaration,
	}, "cmd-regime-restart"), "The host declares a regime before restart")
	_expect_ok(world.execute_participation("declare", PLAYER_B, {
		"role": "attacker",
	}, "cmd-consent-restart"), "B consents before restart")

	var reopened := HeadlessWorld.new()
	var opened: Dictionary = reopened.open(directory, START, WORLD, HOST)
	_expect(bool(opened.get("ok", false)), "The authority reopens the same world")
	_freeze(reopened)
	var view: Dictionary = reopened.participation_view()
	_expect(bool(view.available), "The reopened view is available")
	_expect(str((view.regime as Dictionary).tier) == Participation.TIER_LIMITED
		and int((view.regime as Dictionary).revision) == 1,
		"The reopened view keeps the declared regime")
	_expect(str((view.regime as Dictionary).declaration_id) == "decl-restart",
		"The reopened view keeps the declaration id")
	var b: Dictionary = _participant(view, PLAYER_B)
	_expect(not b.is_empty() and bool(b.attacker) and int(b.consent_revision) == 1,
		"The reopened view keeps B's consent")

	var replay: Dictionary = reopened.execute_participation("regime", HOST, {
		"declaration": declaration,
	}, "cmd-regime-restart")
	_expect(bool(replay.ok) and bool(replay.duplicate),
		"A declaration command replays as a duplicate after restart")


func _test_load_mismatch() -> void:
	var directory: String = _dir("mismatch")
	var world := _open("mismatch", HOST)
	_freeze(world)
	var now: float = world.authority_now_utc()
	_expect_ok(world.execute_participation("regime", HOST, {
		"declaration": _limited_declaration("decl-mismatch", now, [AREA_A], [WINDOW_A]),
	}, "cmd-regime-mismatch"), "The host declares a regime for mismatch checks")
	var bytes_before: String = _file_text(_participation_file(directory))

	var foreign_host := HeadlessWorld.new()
	var host_opened: Dictionary = foreign_host.open(directory, START, WORLD, HOST_2)
	_expect(not bool(host_opened.get("ok", false)) \
		and str(host_opened.get("reason", "")) == "load_participation_host_mismatch",
		"A different host player cannot reopen the stored document")
	_expect(_file_text(_participation_file(directory)) == bytes_before,
		"A host mismatch does not overwrite the stored document")

	var foreign_world := HeadlessWorld.new()
	var world_opened: Dictionary = foreign_world.open(directory, START, OTHER_WORLD, HOST)
	_expect(not bool(world_opened.get("ok", false)) \
		and str(world_opened.get("reason", "")) == "load_participation_world_mismatch",
		"A different world identity cannot adopt the stored document")
	_expect(_file_text(_participation_file(directory)) == bytes_before,
		"A world mismatch does not overwrite the stored document")


func _test_corrupt_unsupported_and_store() -> void:
	var corrupt_dir: String = _dir("corrupt")
	_write(_participation_file(corrupt_dir), "{not json")
	var corrupt_world := HeadlessWorld.new()
	var corrupt_opened: Dictionary = corrupt_world.open(corrupt_dir, START, WORLD, HOST)
	_expect(not bool(corrupt_opened.get("ok", false)) \
		and str(corrupt_opened.get("reason", "")) == "load_participation_corrupt",
		"A corrupt participation document stops the authority")
	_expect(_file_text(_participation_file(corrupt_dir)) == "{not json",
		"A corrupt document is not replaced at startup")

	var unsupported_dir: String = _dir("unsupported")
	var unsupported_text: String = JSON.stringify({"version": 2, "state": {}})
	_write(_participation_file(unsupported_dir), unsupported_text)
	var unsupported_world := HeadlessWorld.new()
	var unsupported_opened: Dictionary = unsupported_world.open(
		unsupported_dir, START, WORLD, HOST)
	_expect(not bool(unsupported_opened.get("ok", false)) \
		and str(unsupported_opened.get("reason", "")) == "load_participation_unsupported",
		"An unsupported participation version stops the authority")
	_expect(_file_text(_participation_file(unsupported_dir)) == unsupported_text,
		"An unsupported document is not replaced at startup")

	var store := ParticipationStore.new(_dir("store"))
	var state: Dictionary = Participation.initial_state(WORLD, HOST)
	_expect(Participation.valid(state), "The direct store fixture is a valid document")
	_expect(ParticipationStore.MAX_BYTES == 65536,
		"The participation sidecar budget is 64 KiB")
	var saved: Dictionary = store.save_state(state)
	_expect(bool(saved.ok) and saved.kind == "saved",
		"A valid participation document is written atomically")
	var loaded: Dictionary = store.load_state(WORLD, HOST)
	_expect(bool(loaded.ok) and loaded.kind == "loaded",
		"The written participation document reloads")
	_expect(Participation.valid(loaded.state) and str(loaded.state.world_id) == WORLD \
		and str(loaded.state.host) == HOST \
		and str(loaded.state.regime.tier) == Participation.TIER_PEACE \
		and int(loaded.state.regime.revision) == 0,
		"The reloaded document keeps the world, host and peace regime")
	var refused: Dictionary = store.save_state({})
	_expect(not bool(refused.ok) and refused.kind == "invalid_state",
		"An empty document is refused as invalid_state")


func _test_write_time_copy() -> void:
	var directory: String = _dir("copy")
	var world := _open("copy", HOST)
	_freeze(world)
	var now: float = world.authority_now_utc()
	_expect_ok(world.execute_participation("regime", HOST, {
		"declaration": _limited_declaration("decl-copy", now, [AREA_A], [WINDOW_A]),
	}, "cmd-regime-copy"), "The host declares a regime before refused writes")
	var live_before: String = JSON.stringify(world.participation)
	var stored_before: String = _file_text(_participation_file(directory))
	var sequence_before: int = int(world.participation_view().sequence)

	var outsider: Dictionary = world.execute_participation("regime", PLAYER_B, {
		"declaration": _limited_declaration("decl-copy-outsider", now, [AREA_B],
			[WINDOW_B]),
	}, "cmd-copy-outsider")
	_expect(not bool(outsider.ok) and outsider.reason == "not_host",
		"A non-host cannot declare a regime")
	_expect(JSON.stringify(world.participation) == live_before,
		"A not_host refusal does not mutate the live participation document")
	_expect(_file_text(_participation_file(directory)) == stored_before,
		"A not_host refusal does not change the stored bytes")
	_expect(int(world.participation_view().sequence) == sequence_before,
		"A not_host refusal does not advance the sequence")

	var invalid: Dictionary = world.execute_participation("regime", HOST, {
		"declaration": {"tier": Participation.TIER_LIMITED},
	}, "cmd-copy-invalid")
	_expect(not bool(invalid.ok) and invalid.reason == "invalid_declaration",
		"An invalid declaration is refused")
	_expect(JSON.stringify(world.participation) == live_before,
		"An invalid declaration does not mutate the live participation document")
	_expect(_file_text(_participation_file(directory)) == stored_before,
		"An invalid declaration does not change the stored bytes")


func _open(name: String, host: String, world_id: String = WORLD) -> HeadlessWorld:
	var world := HeadlessWorld.new()
	var opened: Dictionary = world.open(_dir(name), START, world_id, host)
	_expect(bool(opened.get("ok", false)),
		"The authority opens %s (%s)" % [name, str(opened.get("reason", ""))])
	return world


## The authority clock is monotonic. Freezing it keeps a replayed command's
## payload identical without sleeping or reading the system clock.
func _freeze(world: HeadlessWorld) -> void:
	world._session_started_ms = 0


func _limited_declaration(declaration_id: String, effective_utc: float,
		areas: Array, windows: Array, loss_cap: int = 500,
		offline_loss_cap: int = 100) -> Dictionary:
	return {
		"tier": Participation.TIER_LIMITED,
		"declaration_id": declaration_id,
		"effective_utc": effective_utc,
		"higher_risk": true,
		"areas": areas,
		"windows": windows,
		"loss_cap": loss_cap,
		"offline_loss_cap": offline_loss_cap,
	}


func _participant(view: Dictionary, player_id: String) -> Dictionary:
	var rows: Variant = view.get("participants")
	if not rows is Array:
		return {}
	for value: Variant in rows:
		if value is Dictionary and str((value as Dictionary).get("participant", "")) == player_id:
			return value
	return {}


func _dir(name: String) -> String:
	return root_dir.path_join(name)


func _participation_file(directory: String) -> String:
	return directory.path_join("participation.json")


func _file_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + message)
	print(("PASS " if condition else "FAIL ") + message)


func _expect_ok(result: Dictionary, message: String) -> void:
	_expect(bool(result.get("ok", false)), message)


const AREA_A: Dictionary = {"id": "area_a", "min_x": 0, "min_z": 0, "max_x": 5, "max_z": 5}
const AREA_B: Dictionary = {"id": "area_b", "min_x": 10, "min_z": 10, "max_x": 15, "max_z": 15}
const WINDOW_A: Dictionary = {"id": "window_a", "start_utc": START - 60.0,
	"end_utc": START + 3600.0}
const WINDOW_B: Dictionary = {"id": "window_b", "start_utc": START + 7200.0,
	"end_utc": START + DAY}
