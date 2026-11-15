extends SceneTree
## M11-03 决议效果接入世界权威：真实 `HeadlessWorld` + 目录驱动
## `resolution_effects.json`，不经过网络。覆盖激活后效果落盘并生效、撤销后查询
## 归零且效果文档不变、重开不重写、决议已生效但效果缺失时幂等补齐一次、损坏/
## 不支持版本/异世界/与决议不一致四种拒绝启动，以及效果保存失败返回具名原因且
## 内存与磁盘不分裂。
##
## 所有写入通过权威时钟；测试只从返回结果和落盘文档取证据。

const World = preload("res://world/headless_world.gd")
const Resolution = preload("res://world/resolution_state.gd")
const Effects = preload("res://world/resolution_effects.gd")
const EffectsStore = preload("res://world/resolution_effects_store.gd")

const START: float = 2000000000.0
const HOUR: float = 3600.0
const VOTE_START: float = START + 60.0
const VOTE_END: float = VOTE_START + HOUR
const EFFECTIVE_UTC: float = VOTE_END + HOUR
const WORLD: String = "world-effects-authority"

const PROPOSER: String = "player_00000000000000000000000000000001"
const VOTER_B: String = "player_00000000000000000000000000000002"
const VOTER_C: String = "player_00000000000000000000000000000003"
const TAX_ID: String = "res_tax"
const WORKS_ID: String = "res_works"

var dir: String = ""
var world_dir: String = ""
var world
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/resolution-effects-authority-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	var opened: Dictionary = _open(world_dir, START)
	if not bool(opened.get("ok", false)):
		_expect(false, "The authoritative world opens: %s" % str(opened.get("reason", "")))
		_finish()
		return
	_test_initialization()
	_test_activate_applies_effects()
	_test_revoke_keeps_effects_bytes()
	_test_reopen_does_not_rewrite()
	_test_backfill_is_idempotent()
	_test_rejections()
	_test_save_failure()
	_finish()


func _open(directory: String, now: float) -> Dictionary:
	var opened_world = World.new()
	var opened: Dictionary = opened_world.open(directory, now, WORLD, PROPOSER)
	if bool(opened.get("ok", false)):
		world = opened_world
	return opened


func _advance(at_utc: float) -> void:
	world._session_start_utc = at_utc
	world._session_started_ms = Time.get_ticks_msec()


func _execute(action: String, actor: String, args: Dictionary,
		command_id: String) -> Dictionary:
	return world.execute_resolution(action, actor, args, command_id)


func _proposal(kind: String, vote_start: float) -> Dictionary:
	return {
		"kind": kind,
		"title": "规则",
		"vote_start_utc": vote_start,
		"vote_end_utc": vote_start + HOUR,
		"effective_utc": vote_start + 2.0 * HOUR,
	}


func _effects_path() -> String:
	return world_dir.path_join("resolution_effects.json")


func _resolutions_path() -> String:
	return world_dir.path_join("resolutions.json")


func _bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) \
		else PackedByteArray()


func _document(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _effects_view() -> Dictionary:
	var view: Dictionary = world.resolutions_view("", false)
	var effects: Variant = view.get("effects")
	return effects if effects is Dictionary else {}


## 把世界推向一条决议生效：提案、两票赞成、关闭、激活。返回 activate 结果。
func _activate(kind: String, resolution_id: String, vote_start: float,
		command_prefix: String) -> Dictionary:
	_advance(vote_start - 60.0)
	_execute("propose", PROPOSER, {
		"resolution_id": resolution_id, "proposal": _proposal(kind, vote_start),
	}, command_prefix + "-propose")
	_advance(vote_start + 10.0)
	_execute("vote", VOTER_B, {"resolution_id": resolution_id, "approve": true},
		command_prefix + "-vote-b")
	_execute("vote", VOTER_C, {"resolution_id": resolution_id, "approve": true},
		command_prefix + "-vote-c")
	_advance(vote_start + HOUR)
	_execute("close", PROPOSER, {"resolution_id": resolution_id},
		command_prefix + "-close")
	_advance(vote_start + 2.0 * HOUR)
	return _execute("activate", PROPOSER, {"resolution_id": resolution_id},
		command_prefix + "-activate")


# ------------------------------------------------------------- initialization

func _test_initialization() -> void:
	var view: Dictionary = world.resolutions_view("", false)
	_expect(view.get("effects") is Dictionary,
		"A fresh world view carries the effects block")
	var effects: Dictionary = _effects_view()
	var zero_coefficients: bool = true
	for value: Variant in (effects.get("coefficients", {}) as Dictionary).values():
		if int(value) != 0:
			zero_coefficients = false
	_expect(int(effects.get("applied_version", -1)) == 0
			and int(effects.get("tax_rate_permille", -1)) == 0
			and zero_coefficients,
		"A fresh world has no applied effects, no tax and zero coefficients")
	_expect(Effects.valid(world.resolution_effects),
		"The in-memory effect document passes the strict validator")
	_expect(not FileAccess.file_exists(_effects_path()),
		"A fresh world has no resolution_effects.json before the first effect")


# --------------------------------------------------------- activate -> effects

func _test_activate_applies_effects() -> void:
	var activated: Dictionary = _activate(Resolution.KIND_TAX, TAX_ID, VOTE_START, "tax")
	_expect(bool(activated.get("ok", false))
			and str(activated.get("status", "")) == Resolution.STATUS_EFFECTIVE,
		"The tax resolution activates (reason=%s)" % str(activated.get("reason", "")))
	_expect(FileAccess.file_exists(_effects_path()),
		"Activation writes resolution_effects.json")
	var document: Dictionary = _document(_effects_path())
	_expect(int(document.get("version", 0)) == 1
			and str(document.get("world_id", "")) == WORLD,
		"The effect sidecar carries version 1 and the world identity")
	var state: Dictionary = document.get("state", {})
	_expect(Effects.valid(state) and int(state.get("applied_version", 0)) == 1
			and (state.get("applied", []) as Array).size() == 1,
		"The applied watermark advanced and one record was written")
	_expect(Effects.consistent(state, world.resolutions),
		"The stored effect document agrees with the stored resolutions")
	var effects: Dictionary = _effects_view()
	_expect(int(effects.get("applied_version", 0)) == 1,
		"The view reports the applied watermark")
	_expect(int(effects.get("tax_rate_permille", 0)) == Effects.TAX_STEP_PERMILLE,
		"The activated tax produces its permille rate in the view")
	var coefficients: Dictionary = effects.get("coefficients", {})
	_expect(int(coefficients.get(Effects.EFFECT_PUBLIC_WORKS_EXPENSE, -1)) == 0
			and int(coefficients.get(Effects.EFFECT_DISASTER_LOSS, -1)) == 0,
		"A tax resolution grants no public-works coefficient")

	var works: Dictionary = _activate(Resolution.KIND_PUBLIC_WORKS, WORKS_ID,
		VOTE_START + HOUR, "works")
	_expect(bool(works.get("ok", false)),
		"The public-works resolution activates (reason=%s)" % str(works.get("reason", "")))
	effects = _effects_view()
	coefficients = effects.get("coefficients", {})
	_expect(int(coefficients.get(Effects.EFFECT_PUBLIC_WORKS_EXPENSE, 0))
			== int(Effects.COEFFICIENTS[Effects.EFFECT_PUBLIC_WORKS_EXPENSE])
			and int(coefficients.get(Effects.EFFECT_DISASTER_LOSS, 0))
			== int(Effects.COEFFICIENTS[Effects.EFFECT_DISASTER_LOSS]),
		"The activated public works grant both fixed coefficients in the view")
	_expect(int(effects.get("tax_rate_permille", 0)) == Effects.TAX_STEP_PERMILLE,
		"Public works do not change the tax rate")
	_expect(int(_document(_effects_path()).state.applied_version) == 2,
		"The second activation advances the applied watermark")


# --------------------------------------------------- revoke -> queries go zero

func _test_revoke_keeps_effects_bytes() -> void:
	var before: PackedByteArray = _bytes(_effects_path())
	var resolutions_before: PackedByteArray = _bytes(_resolutions_path())
	_advance(VOTE_START + 5.0 * HOUR)
	var revoked: Dictionary = _execute("revoke", VOTER_B, {
		"resolution_id": TAX_ID,
	}, "tax-revoke")
	_expect(bool(revoked.get("ok", false))
			and str(revoked.get("status", "")) == Resolution.STATUS_REVOKED,
		"An approver revokes the tax resolution")
	_expect(_bytes(_effects_path()) == before,
		"Revocation leaves resolution_effects.json byte-identical")
	_expect(_bytes(_resolutions_path()) != resolutions_before,
		"Revocation does write resolutions.json")
	var effects: Dictionary = _effects_view()
	_expect(int(effects.get("tax_rate_permille", -1)) == 0,
		"A revoked tax resolution stops contributing its rate, without rewriting the effects")
	_expect(int(effects.get("applied_version", 0)) == 2,
		"Revocation does not roll the applied watermark back")
	_expect(int(effects.get("coefficients", {}).get(
			Effects.EFFECT_PUBLIC_WORKS_EXPENSE, 0))
			== int(Effects.COEFFICIENTS[Effects.EFFECT_PUBLIC_WORKS_EXPENSE]),
		"The remaining public works still grant their coefficient")
	_expect(Effects.consistent(world.resolution_effects, world.resolutions),
		"The effect document stays consistent after the revoke")


# --------------------------------------------------------- reopen: no rewrite

func _test_reopen_does_not_rewrite() -> void:
	var effects_before: PackedByteArray = _bytes(_effects_path())
	var resolutions_before: PackedByteArray = _bytes(_resolutions_path())
	var reopened: Dictionary = _open(world_dir, VOTE_START + 6.0 * HOUR)
	_expect(bool(reopened.get("ok", false)),
		"The world reopens with its effect document: %s"
			% str(reopened.get("reason", "")))
	if not bool(reopened.get("ok", false)):
		return
	_expect(_bytes(_effects_path()) == effects_before,
		"Reopening does not rewrite resolution_effects.json")
	_expect(_bytes(_resolutions_path()) == resolutions_before,
		"Reopening does not rewrite resolutions.json")
	_expect(int(world.resolution_effects.applied_version) == 2,
		"The applied watermark survives the restart")
	_expect(int(_effects_view().get("tax_rate_permille", -1)) == 0,
		"The revoked tax stays revoked after the restart")
	_expect(Effects.consistent(world.resolution_effects, world.resolutions),
		"The restored effect document is consistent")


# --------------------------------------- missing effects on an effective world

func _test_backfill_is_idempotent() -> void:
	# 构造“决议文档里有已生效行，但效果文档不存在”的真实目录：直接删掉效果
	# 文档，再打开世界。权威应按生效版本补齐一次并写盘，第二次打开不再写。
	var backfill_dir: String = dir.path_join("backfill")
	DirAccess.make_dir_recursive_absolute(backfill_dir)
	var seed_world = World.new()
	var opened: Dictionary = seed_world.open(backfill_dir, START, WORLD, PROPOSER)
	_expect(bool(opened.get("ok", false)), "The backfill fixture world opens")
	if not bool(opened.get("ok", false)):
		return
	world = seed_world
	_activate(Resolution.KIND_TAX, TAX_ID, VOTE_START, "seed")
	_expect(FileAccess.file_exists(backfill_dir.path_join("resolution_effects.json")),
		"The backfill fixture first writes its effect document")
	DirAccess.remove_absolute(backfill_dir.path_join("resolution_effects.json"))
	_expect(not FileAccess.file_exists(backfill_dir.path_join("resolution_effects.json")),
		"The effect document is removed to simulate a missing one")

	var backfilled = World.new()
	var first_open: Dictionary = backfilled.open(backfill_dir, VOTE_START + 4.0 * HOUR,
		WORLD, PROPOSER)
	_expect(bool(first_open.get("ok", false)),
		"An effective resolution with a missing effect document backfills on open: %s"
			% str(first_open.get("reason", "")))
	if not bool(first_open.get("ok", false)):
		return
	_expect(FileAccess.file_exists(backfill_dir.path_join("resolution_effects.json")),
		"Backfill writes the missing effect document")
	_expect(int(backfilled.resolution_effects.applied_version) == 1
			and int(backfilled.resolutions_view("", false).effects.tax_rate_permille)
				== Effects.TAX_STEP_PERMILLE,
		"Backfill applies the effective resolution exactly once")
	var written: PackedByteArray = FileAccess.get_file_as_bytes(
		backfill_dir.path_join("resolution_effects.json"))

	var second_open = World.new()
	var reopened: Dictionary = second_open.open(backfill_dir, VOTE_START + 5.0 * HOUR,
		WORLD, PROPOSER)
	_expect(bool(reopened.get("ok", false)),
		"The backfilled world reopens")
	_expect(FileAccess.get_file_as_bytes(backfill_dir.path_join("resolution_effects.json"))
			== written,
		"A second open does not rewrite the backfilled document")
	_expect(int(second_open.resolution_effects.applied_version) == 1,
		"The backfilled watermark does not advance again")
	# 恢复主世界，后续拒绝分支各自使用独立目录。
	world = World.new()
	world.open(world_dir, VOTE_START + 6.0 * HOUR, WORLD, PROPOSER)


# --------------------------------------------------------------- rejections

func _test_rejections() -> void:
	var corrupt_dir: String = dir.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	_write_text(corrupt_dir.path_join("resolution_effects.json"), "{")
	_expect_open_reason(corrupt_dir, "load_resolution_effects_corrupt",
		"A corrupt effect document stops the authority")

	var version_dir: String = dir.path_join("unsupported")
	DirAccess.make_dir_recursive_absolute(version_dir)
	_write_text(version_dir.path_join("resolution_effects.json"), JSON.stringify({
		"version": 2, "world_id": WORLD, "state": Effects.empty(),
	}))
	_expect_open_reason(version_dir, "load_resolution_effects_unsupported",
		"An unsupported effect document version stops the authority")

	var other_dir: String = dir.path_join("other-world")
	DirAccess.make_dir_recursive_absolute(other_dir)
	_write_text(other_dir.path_join("resolution_effects.json"), JSON.stringify({
		"version": 1, "world_id": "another-world", "state": Effects.empty(),
	}))
	_expect_open_reason(other_dir, "load_resolution_effects_world_mismatch",
		"An effect document from another world stops the authority")

	# 效果文档合法，但记录了决议文档里不存在或版本不符的条目。
	var inconsistent_dir: String = dir.path_join("inconsistent")
	DirAccess.make_dir_recursive_absolute(inconsistent_dir)
	_write_text(inconsistent_dir.path_join("resolution_effects.json"), JSON.stringify({
		"version": 1, "world_id": WORLD,
		"state": {
			"applied_version": 1,
			"applied": [{
				"resolution_id": TAX_ID, "version": 1, "kind": Resolution.KIND_TAX,
				"at_utc": EFFECTIVE_UTC,
			}],
		},
	}))
	_expect_open_reason(inconsistent_dir, "load_resolution_effects_inconsistent",
		"An effect document that disagrees with the resolutions stops the authority")


func _expect_open_reason(directory: String, reason: String, label: String) -> void:
	var opened: Dictionary = World.new().open(directory, START, WORLD, PROPOSER)
	_expect(not bool(opened.get("ok", true)) and str(opened.get("reason", "")) == reason,
		label + " (got %s)" % str(opened.get("reason", "")))


# ------------------------------------------------------------- save failure

func _test_save_failure() -> void:
	var failure_dir: String = dir.path_join("save-failure")
	DirAccess.make_dir_recursive_absolute(failure_dir)
	var failure_world = World.new()
	var opened: Dictionary = failure_world.open(failure_dir, START, WORLD, PROPOSER)
	_expect(bool(opened.get("ok", false)), "The effect-save-failure world opens")
	if not bool(opened.get("ok", false)):
		return
	world = failure_world
	_advance(VOTE_START - 60.0)
	_execute("propose", PROPOSER, {
		"resolution_id": TAX_ID, "proposal": _proposal(Resolution.KIND_TAX, VOTE_START),
	}, "failure-propose")
	_advance(VOTE_START + 10.0)
	_execute("vote", VOTER_B, {"resolution_id": TAX_ID, "approve": true},
		"failure-vote-b")
	_execute("vote", VOTER_C, {"resolution_id": TAX_ID, "approve": true},
		"failure-vote-c")
	_advance(VOTE_END)
	_execute("close", PROPOSER, {"resolution_id": TAX_ID}, "failure-close")
	# A directory where the effect pending file should go makes the staged write
	# fail without relying on platform permission bits.
	DirAccess.make_dir_recursive_absolute(
		failure_dir.path_join("resolution_effects.pending.json"))
	_advance(EFFECTIVE_UTC)
	var effects_before: String = JSON.stringify(failure_world.resolution_effects)
	var activated: Dictionary = _execute("activate", PROPOSER, {
		"resolution_id": TAX_ID,
	}, "failure-activate")
	_expect(not bool(activated.get("ok", true))
			and str(activated.get("reason", "")).begins_with("save_resolution_effects_"),
		"A failed effect save names the storage failure (got %s)"
			% str(activated.get("reason", "")))
	_expect(JSON.stringify(failure_world.resolution_effects) == effects_before,
		"A failed effect save leaves the in-memory effect document unchanged")
	_expect(FileAccess.file_exists(failure_dir.path_join("resolutions.json")),
		"The resolution document was already saved before the effect failed")
	# The resolution really is effective on disk, so memory and disk agree: the
	# next open backfills the effect instead of serving a half-applied pair.
	_expect(str(failure_world._resolution_status(failure_world.resolutions, TAX_ID))
			== Resolution.STATUS_EFFECTIVE,
		"The activated resolution stays effective after the effect save failure")
	_expect(not FileAccess.file_exists(
			failure_dir.path_join("resolution_effects.json")),
		"A failed effect save does not create the main effect document")


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("RESOLUTION_EFFECTS_AUTHORITY_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
