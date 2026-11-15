extends SceneTree
## M11-03 规则决议接入世界权威：真实 `HeadlessWorld` + 目录驱动
## `resolutions.json`，不经过网络。覆盖缺失文档为空且不写盘、提案→投票→生效→
## 撤销全链、视图隐私分级、同命令重放不追加日志、日志上限淘汰、重启后版本与
## 文档保持、损坏/异世界/不支持版本拒绝启动、保存失败不改内存，以及
## `WorldHost` 接缝上的只读、访客、匿名与未知动作拒绝。
##
## 所有写入通过权威时钟；测试只从返回结果和落盘文档取证据。

const World = preload("res://world/headless_world.gd")
const WorldHost = preload("res://world/world_host.gd")
const Resolution = preload("res://world/resolution_state.gd")
const ResolutionsStore = preload("res://world/resolutions_store.gd")
const WorldInvite = preload("res://world/world_invite.gd")

const START: float = 2000000000.0
const HOUR: float = 3600.0
const VOTE_START: float = START + 60.0
const VOTE_END: float = VOTE_START + HOUR
const EFFECTIVE_UTC: float = VOTE_END + HOUR
const WORLD: String = "world-resolution-authority"

const PROPOSER: String = "player_00000000000000000000000000000001"
const VOTER_B: String = "player_00000000000000000000000000000002"
const VOTER_C: String = "player_00000000000000000000000000000003"
const OUTSIDER: String = "player_00000000000000000000000000000004"
const RESOLUTION_ID: String = "res_bridge"

const PEER_MEMBER: int = 31
const PEER_VISITOR: int = 32
const PEER_ANONYMOUS: int = 33
const PEER_OUTSIDER: int = 34

var dir: String = ""
var world_dir: String = ""
var world
var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(
		".local/verification/resolution-authority-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	var opened: Dictionary = _open(world_dir, START)
	if not bool(opened.get("ok", false)):
		_expect(false, "The authoritative world opens: %s" % str(opened.get("reason", "")))
		_finish()
		return
	_test_initialization()
	_test_chain_and_view()
	_test_replay()
	_test_restart()
	_test_journal_cap()
	_test_store_guards()
	_test_save_failure()
	_test_host_permissions()
	_finish()


func _open(directory: String, now: float) -> Dictionary:
	var opened_world = World.new()
	var opened: Dictionary = opened_world.open(directory, now, WORLD, PROPOSER)
	if bool(opened.get("ok", false)):
		world = opened_world
	return opened


## Test seam: `authority_now_utc()` is the monotonic session clock. Moving the
## baseline forward simulates the next strategic tick without waiting in real
## time or touching the system clock.
func _advance(at_utc: float) -> void:
	world._session_start_utc = at_utc
	world._session_started_ms = Time.get_ticks_msec()


func _execute(action: String, actor: String, args: Dictionary,
		command_id: String) -> Dictionary:
	return world.execute_resolution(action, actor, args, command_id)


func _proposal(vote_start: float) -> Dictionary:
	return {
		"kind": Resolution.KIND_PUBLIC_WORKS,
		"title": "修桥",
		"vote_start_utc": vote_start,
		"vote_end_utc": vote_start + HOUR,
		"effective_utc": vote_start + 2.0 * HOUR,
	}


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


func _row(view: Dictionary, resolution_id: String) -> Dictionary:
	var rows: Variant = view.get("resolutions")
	if rows is Array:
		for row_value: Variant in rows:
			if row_value is Dictionary \
					and str((row_value as Dictionary).get("resolution_id", "")) \
						== resolution_id:
				return row_value
	return {}


# ------------------------------------------------------------- initialization

func _test_initialization() -> void:
	var view: Dictionary = world.resolutions_view("", false)
	_expect(bool(view.get("available", false)),
		"A fresh world has an available empty resolution view")
	_expect(int(view.get("rules_version", -1)) == 0,
		"A fresh world is at rules version 0")
	_expect((view.get("resolutions", []) as Array).is_empty()
			and (view.get("versions", []) as Array).is_empty(),
		"A fresh world has no resolutions and no version history")
	_expect(Resolution.valid(world.resolutions),
		"The in-memory resolution document passes the strict validator")
	_expect(not FileAccess.file_exists(_resolutions_path()),
		"A fresh world has no resolutions.json before the first write")
	_expect(view.get("effects") is Dictionary
			and int(view.effects.get("applied_version", -1)) == 0,
		"A fresh world reports an empty effects block")
	_expect(not FileAccess.file_exists(world_dir.path_join("resolution_effects.json")),
		"A fresh world has no resolution_effects.json before the first effect")


# -------------------------------------------------------- propose/vote/revoke

func _test_chain_and_view() -> void:
	_advance(START)
	var proposed: Dictionary = _execute("propose", PROPOSER, {
		"resolution_id": RESOLUTION_ID, "proposal": _proposal(VOTE_START),
	}, "chain-propose")
	_expect(bool(proposed.get("ok", false))
			and str(proposed.get("status", "")) == Resolution.STATUS_PROPOSED,
		"The proposer files a resolution (reason=%s)" % str(proposed.get("reason", "")))
	_expect(FileAccess.file_exists(_resolutions_path()),
		"The first accepted resolution writes resolutions.json")

	_advance(VOTE_START + 10.0)
	var vote_b: Dictionary = _execute("vote", VOTER_B, {
		"resolution_id": RESOLUTION_ID, "approve": true,
	}, "chain-vote-b")
	var vote_c: Dictionary = _execute("vote", VOTER_C, {
		"resolution_id": RESOLUTION_ID, "approve": true,
	}, "chain-vote-c")
	_expect(bool(vote_b.get("ok", false)) and bool(vote_c.get("ok", false)),
		"Two members approve the proposal")
	var self_vote: Dictionary = _execute("vote", PROPOSER, {
		"resolution_id": RESOLUTION_ID, "approve": true,
	}, "chain-self-vote")
	_expect(str(self_vote.get("reason", "")) == "self_vote",
		"The proposer cannot vote on their own proposal")
	var bad_vote: Dictionary = _execute("vote", OUTSIDER, {
		"resolution_id": RESOLUTION_ID, "approve": "yes",
	}, "chain-bad-vote")
	_expect(str(bad_vote.get("reason", "")) == "invalid_request",
		"A non-boolean approve flag is refused before the rule sees it")

	_advance(VOTE_END)
	var closed: Dictionary = _execute("close", PROPOSER, {
		"resolution_id": RESOLUTION_ID,
	}, "chain-close")
	_expect(bool(closed.get("ok", false))
			and str(closed.get("status", "")) == Resolution.STATUS_PASSED,
		"The proposal passes when the window ends")

	_advance(EFFECTIVE_UTC)
	var activated: Dictionary = _execute("activate", PROPOSER, {
		"resolution_id": RESOLUTION_ID,
	}, "chain-activate")
	_expect(bool(activated.get("ok", false))
			and str(activated.get("status", "")) == Resolution.STATUS_EFFECTIVE,
		"The passed resolution becomes effective at its scheduled time")
	_expect(int(world.resolutions.rules_version) == 1,
		"The first effective resolution advances the world to rules version 1")

	# 隐私分级：匿名读取没有计票人数；已加入成员有计数但无身份；相关成员有身份。
	var anonymous_view: Dictionary = world.resolutions_view("", false)
	var anonymous_row: Dictionary = _row(anonymous_view, RESOLUTION_ID)
	_expect(not anonymous_row.has("approvals") and not anonymous_row.has("rejections")
			and not anonymous_row.has("approvers"),
		"An anonymous viewer gets neither counts nor voter identities")
	var outsider_view: Dictionary = world.resolutions_view(OUTSIDER, true)
	var outsider_row: Dictionary = _row(outsider_view, RESOLUTION_ID)
	_expect(int(outsider_row.get("approvals", -1)) == 2
			and not outsider_row.has("approvers"),
		"A joined non-voter sees vote counts but no voter identities")
	var voter_view: Dictionary = world.resolutions_view(VOTER_B, true)
	var voter_row: Dictionary = _row(voter_view, RESOLUTION_ID)
	_expect((voter_row.get("approvers", []) as Array) == [VOTER_B, VOTER_C],
		"A voter sees the voter identities on a related resolution")
	_expect(str((_row(world.resolutions_view(PROPOSER, true), RESOLUTION_ID)
			.get("proposed_by", ""))) == PROPOSER,
		"The proposer is a public fact in every view")

	_advance(EFFECTIVE_UTC + 10.0)
	var revoked: Dictionary = _execute("revoke", VOTER_B, {
		"resolution_id": RESOLUTION_ID,
	}, "chain-revoke")
	_expect(bool(revoked.get("ok", false))
			and str(revoked.get("status", "")) == Resolution.STATUS_REVOKED,
		"An approver revokes the effective resolution")
	_expect(int(world.resolutions.rules_version) == 2,
		"Revocation advances the world to rules version 2")
	var view: Dictionary = world.resolutions_view(OUTSIDER, true)
	var row: Dictionary = _row(view, RESOLUTION_ID)
	_expect(int(row.get("effective_version", 0)) == 1
			and int(row.get("revoked_version", 0)) == 2,
		"The row keeps its effective version and records the revoke version")
	_expect(float(row.get("ends_utc", 0.0)) == EFFECTIVE_UTC + 10.0,
		"A revoked resolution reports its end time")
	_expect(str(row.get("revoked_by", "")) == VOTER_B,
		"The revoking member is recorded")
	var versions: Array = view.get("versions", [])
	_expect(versions.size() == 2
			and int((versions[0] as Dictionary).get("version", 0)) == 1
			and str((versions[0] as Dictionary).get("change", "")) == "effective"
			and int((versions[1] as Dictionary).get("version", 0)) == 2
			and str((versions[1] as Dictionary).get("change", "")) == "revoked",
		"The version summary lists effective then revoked in version order")
	_expect(Resolution.valid(world.resolutions),
		"The live document is still strictly valid after the full chain")
	_expect(int(_document(_resolutions_path()).get("version", 0)) == 1
			and str(_document(_resolutions_path()).get("world_id", "")) == WORLD,
		"resolutions.json carries version 1 and the world identity")


# -------------------------------------------------------------------- replay

func _test_replay() -> void:
	var before: PackedByteArray = _bytes(_resolutions_path())
	var effects_path: String = world_dir.path_join("resolution_effects.json")
	var effects_before: PackedByteArray = _bytes(effects_path)
	var replay: Dictionary = _execute("activate", PROPOSER, {
		"resolution_id": RESOLUTION_ID,
	}, "chain-activate")
	# activate already ran; its stored result replays even though the rule would
	# now answer not_passed. The journal, not the rule, owns the replay window.
	_expect(bool(replay.get("duplicate", false)),
		"Replaying a committed command id returns the first result")
	_expect(_bytes(_resolutions_path()) == before,
		"A replay leaves resolutions.json byte-identical")
	_expect(_bytes(effects_path) == effects_before,
		"A replay leaves resolution_effects.json byte-identical")
	var stored: Dictionary = _document(_resolutions_path())
	_expect((stored.get("commands", []) as Array).size() == 6,
		"Six accepted commands are journaled")
	var conflict: Dictionary = _execute("activate", PROPOSER, {
		"resolution_id": "res_other",
	}, "chain-activate")
	_expect(str(conflict.get("reason", "")) == "command_conflict",
		"A different payload under the same command id conflicts")
	_expect(_bytes(_resolutions_path()) == before,
		"A command conflict leaves resolutions.json byte-identical")
	var state: Dictionary = _execute("state", OUTSIDER, {}, "")
	_expect(bool(state.get("ok", false))
			and int((state.get("state", {}) as Dictionary)
				.get("rules_version", -1)) == 2,
		"The read-only state branch reports the live rules version")


# ------------------------------------------------------------------- restart

func _test_restart() -> void:
	var before: PackedByteArray = _bytes(_resolutions_path())
	var effects_path: String = world_dir.path_join("resolution_effects.json")
	var effects_before: PackedByteArray = _bytes(effects_path)
	var reopened: Dictionary = _open(world_dir, EFFECTIVE_UTC + HOUR)
	_expect(bool(reopened.get("ok", false)),
		"The world reopens from the existing resolutions.json: %s"
			% str(reopened.get("reason", "")))
	if not bool(reopened.get("ok", false)):
		return
	_expect(_bytes(_resolutions_path()) == before,
		"Reopening the world does not rewrite resolutions.json")
	_expect(_bytes(effects_path) == effects_before,
		"Reopening the world does not rewrite resolution_effects.json")
	_expect(int(world.resolutions.rules_version) == 2,
		"The rules version survives the restart")
	_expect(bool(Resolution.valid(world.resolutions)),
		"The restored document is strictly valid")
	var row: Dictionary = _row(world.resolutions_view(OUTSIDER, true), RESOLUTION_ID)
	_expect(str(row.get("status", "")) == Resolution.STATUS_REVOKED
			and float(row.get("ends_utc", 0.0)) == EFFECTIVE_UTC + 10.0,
		"The revoked row and its end time survive the restart")
	var replay: Dictionary = _execute("revoke", VOTER_B, {
		"resolution_id": RESOLUTION_ID,
	}, "chain-revoke")
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"The revoke command still replays after the restart")
	_expect(_bytes(_resolutions_path()) == before,
		"A post-restart replay leaves resolutions.json byte-identical")


# ---------------------------------------------------------------- journal cap

func _test_journal_cap() -> void:
	# The chain already wrote six commands on this reopened world. Add enough
	# accepted proposals to cross the 64-row cap.
	var now: float = world.authority_now_utc()
	for index: int in 60:
		var vote_start: float = now + HOUR + float(index)
		var result: Dictionary = _execute("propose", PROPOSER, {
			"resolution_id": "bulk_%02d" % index,
			"proposal": _proposal(vote_start),
		}, "cap-propose-%02d" % index)
		_expect(bool(result.get("ok", false)),
			"The bounded-journal proposal %d is accepted" % index)
	var commands: Array = _document(_resolutions_path()).get("commands", [])
	_expect(commands.size() == ResolutionsStore.MAX_COMMANDS,
		"The journal stays at its 64-row upper bound")
	var ids: Dictionary = {}
	for row_value: Variant in commands:
		ids[str((row_value as Dictionary).get("command_id", ""))] = true
	_expect(not ids.has("chain-propose") and ids.has("cap-propose-59"),
		"The oldest journal row is evicted and the newest is retained")
	var evicted: Dictionary = _execute("propose", PROPOSER, {
		"resolution_id": RESOLUTION_ID, "proposal": _proposal(VOTE_START),
	}, "chain-propose")
	# The id aged out of the journal, so it is no longer a replay: the rule runs
	# again and refuses the now-past proposal window instead of returning the
	# first result.
	_expect(not bool(evicted.get("duplicate", false))
			and str(evicted.get("reason", "")) == "invalid_window",
		"An evicted command id no longer replays and runs the rule again")


# --------------------------------------------------------------- store guards

func _test_store_guards() -> void:
	var corrupt_dir: String = dir.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	_write_text(corrupt_dir.path_join("resolutions.json"), "{")
	var corrupt_open: Dictionary = World.new().open(corrupt_dir, START, WORLD, PROPOSER)
	_expect(not bool(corrupt_open.get("ok", true))
			and str(corrupt_open.get("reason", "")) == "load_resolutions_corrupt",
		"A corrupt resolution document stops the authority")

	var version_dir: String = dir.path_join("unsupported")
	DirAccess.make_dir_recursive_absolute(version_dir)
	_write_text(version_dir.path_join("resolutions.json"), JSON.stringify({
		"version": 2, "world_id": WORLD, "state": Resolution.empty(), "commands": [],
	}))
	var version_open: Dictionary = World.new().open(version_dir, START, WORLD, PROPOSER)
	_expect(not bool(version_open.get("ok", true))
			and str(version_open.get("reason", "")) == "load_resolutions_unsupported",
		"An unsupported resolution document version stops the authority")

	var other_dir: String = dir.path_join("other-world")
	DirAccess.make_dir_recursive_absolute(other_dir)
	_write_text(other_dir.path_join("resolutions.json"), JSON.stringify({
		"version": 1, "world_id": "another-world", "state": Resolution.empty(),
		"commands": [],
	}))
	var other_open: Dictionary = World.new().open(other_dir, START, WORLD, PROPOSER)
	_expect(not bool(other_open.get("ok", true))
			and str(other_open.get("reason", "")) == "load_resolutions_world_mismatch",
		"A resolution document from another world stops the authority")

	# An existing document whose state fails the strict validator is corruption,
	# not an empty table to overwrite.
	var invalid_dir: String = dir.path_join("invalid-state")
	DirAccess.make_dir_recursive_absolute(invalid_dir)
	_write_text(invalid_dir.path_join("resolutions.json"), JSON.stringify({
		"version": 1, "world_id": WORLD,
		"state": {"rules_version": 3, "resolutions": {}}, "commands": [],
	}))
	var invalid_open: Dictionary = World.new().open(invalid_dir, START, WORLD, PROPOSER)
	_expect(not bool(invalid_open.get("ok", true))
			and str(invalid_open.get("reason", "")) == "load_resolutions_corrupt",
		"An inconsistent rules version stops the authority instead of resetting")


# --------------------------------------------------------------- save failure

func _test_save_failure() -> void:
	var failure_dir: String = dir.path_join("save-failure")
	DirAccess.make_dir_recursive_absolute(failure_dir)
	var failure_world = World.new()
	var opened: Dictionary = failure_world.open(failure_dir, START, WORLD, PROPOSER)
	_expect(bool(opened.get("ok", false)), "The save-failure world opens")
	if not bool(opened.get("ok", false)):
		return
	# A directory where the pending file should go makes the staged write fail
	# without relying on platform permission bits.
	DirAccess.make_dir_recursive_absolute(
		failure_dir.path_join("resolutions.pending.json"))
	var before: String = JSON.stringify(failure_world.resolutions)
	var failed: Dictionary = failure_world.execute_resolution("propose", PROPOSER, {
		"resolution_id": RESOLUTION_ID, "proposal": _proposal(START + 60.0),
	}, "save-failure-propose")
	_expect(not bool(failed.get("ok", true))
			and str(failed.get("reason", "")).begins_with("save_resolutions_"),
		"A failed save names the storage failure")
	_expect(JSON.stringify(failure_world.resolutions) == before,
		"A failed save leaves no half-applied resolution in memory")
	_expect(not FileAccess.file_exists(failure_dir.path_join("resolutions.json")),
		"A failed first save does not create the main document")
	var retried: Dictionary = failure_world.execute_resolution("state", PROPOSER, {},
		"")
	_expect(bool(retried.get("ok", false))
			and int(retried.state.rules_version) == 0,
		"The authority keeps serving reads after a failed write")


# ---------------------------------------------------------- host permissions

func _test_host_permissions() -> void:
	var host_dir: String = dir.path_join("host")
	DirAccess.make_dir_recursive_absolute(host_dir)
	var host := WorldHost.new()
	root.add_child(host)
	var opened: Dictionary = host.configure(host_dir, START, WORLD, 1, PROPOSER)
	_expect(bool(opened.get("ok", false)), "The host authority opens")
	if not bool(opened.get("ok", false)):
		return
	host._members[PEER_MEMBER] = WorldInvite.MEMBER
	host._players[PEER_MEMBER] = {"id": PROPOSER, "name": "阿金"}
	host._members[PEER_VISITOR] = WorldInvite.VISITOR
	host._players[PEER_VISITOR] = {"id": OUTSIDER, "name": "访客"}
	host._members[PEER_ANONYMOUS] = WorldInvite.MEMBER
	host._members[PEER_OUTSIDER] = WorldInvite.MEMBER
	host._players[PEER_OUTSIDER] = {"id": VOTER_B, "name": "阿木"}

	var read: Dictionary = host.resolutions_for_member(PEER_VISITOR, "state", {})
	_expect(bool(read.get("ok", false)),
		"A visitor may read the resolution view")
	_expect(bool((read.get("state", {}) as Dictionary).get("is_member", false)),
		"An accepted join is reported as a member read")

	var visitor_write: Dictionary = host.resolutions_for_member(PEER_VISITOR, "propose", {
		"resolution_id": RESOLUTION_ID, "proposal": _proposal(START + 60.0),
		"command_id": "host-visitor",
	})
	_expect(str(visitor_write.get("reason", "")) == "forbidden",
		"A visitor's resolution write is refused as forbidden")
	_expect(not str(visitor_write.get("reason_text", "")).is_empty(),
		"The visitor refusal carries human-readable text")

	var anonymous_write: Dictionary = host.resolutions_for_member(PEER_ANONYMOUS,
		"propose", {
			"resolution_id": RESOLUTION_ID,
			"proposal": _proposal(START + 60.0), "command_id": "host-anonymous",
		})
	_expect(str(anonymous_write.get("reason", "")) == "no_player",
		"An anonymous member's resolution write is refused for lack of identity")

	var unknown: Dictionary = host.resolutions_for_member(PEER_MEMBER, "dissolve", {
		"resolution_id": RESOLUTION_ID, "command_id": "host-unknown",
	})
	_expect(str(unknown.get("reason", "")) == "unknown_action",
		"An unknown resolution action is refused")

	host.read_only = true
	var retired: Dictionary = host.resolutions_for_member(PEER_MEMBER, "propose", {
		"resolution_id": RESOLUTION_ID,
		"proposal": _proposal(START + 60.0), "command_id": "host-readonly",
	})
	_expect(str(retired.get("reason", "")) == "read_only",
		"A read-only authority refuses resolution writes")
	host.read_only = false

	var accepted: Dictionary = host.resolutions_for_member(PEER_MEMBER, "propose", {
		"resolution_id": RESOLUTION_ID,
		"proposal": _proposal(START + 60.0), "command_id": "host-propose",
		# Identity fields in the payload never decide who acts.
		"actor": VOTER_C, "proposer": VOTER_C,
	})
	_expect(bool(accepted.get("ok", false))
			and str(accepted.get("status", "")) == Resolution.STATUS_PROPOSED,
		"A named member proposes through the host seam")
	var proposed_row: Dictionary = _row(accepted.get("state", {}), RESOLUTION_ID)
	_expect(str(proposed_row.get("proposed_by", "")) == PROPOSER,
		"The connection identity, not a payload field, becomes the proposer")
	_expect(FileAccess.file_exists(host_dir.path_join("resolutions.json")),
		"The host write persists resolutions.json")

	host.queue_free()


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
	print("RESOLUTION_AUTHORITY_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
