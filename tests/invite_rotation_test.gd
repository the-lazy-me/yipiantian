extends SceneTree
## A room's invitation can be replaced while the room keeps its world.
##
## This is the real chain: a headless authority is started by `WorldHosting`, a
## member joins with the first code and commits one command, the host rotates,
## and the restarted authority is joined with the new code. A rotation is only
## meaningful if the old member and visitor codes stop admitting anyone, the new
## ones work, and the world the first member changed is still there.
##
## Joins are sequential: SceneMultiplayer is one per SceneTree, and M4-06 records
## that limit. A rejected join only proves the code is refused; it never becomes
## a full session.

const WorldHosting = preload("res://world/world_hosting.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const WorldClient = preload("res://world/world_client.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const PLAYER_SECRET: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="

const WORLD: String = "world-rotation"
const MEMBER: String = "player_00000000000000000000000000000011"
const VISITOR: String = "player_00000000000000000000000000000012"

var checks: int = 0
var failures: Array[String] = []
var hosting: WorldHosting
var base: String = ""
var state: Dictionary = {}
var client: WorldClient
var _committed: bool = false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	base = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir() \
		.path_join(".local/verification/invite-rotation-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(base.get_base_dir())
	DirAccess.remove_absolute(base)
	hosting = WorldHosting.new()
	var started: Dictionary = hosting.start(base, WORLD, _free_port())
	_expect(bool(started.get("ok", false)), "A room starts before any rotation")
	var ready: Dictionary = await _await_ready(40.0)
	_expect(bool(ready.get("ok", false)), "The authority runs (reason=%s)"
		% str(ready.get("reason", "")))
	if not bool(ready.get("ok", false)):
		await _cleanup()
		_finish()
		return

	var old_member_code: String = str(ready.get("join_code", ""))
	var old_visitor_code: String = str(ready.get("visitor_join_code", ""))
	_expect(old_member_code.begins_with(WorldJoinCode.PREFIX),
		"The first room produces a member code")
	_expect(old_visitor_code.begins_with(WorldJoinCode.PREFIX),
		"The first room also produces a visitor code")
	if old_member_code.is_empty() or old_visitor_code.is_empty():
		await _cleanup()
		_finish()
		return
	var old_invite: PackedByteArray = FileAccess.get_file_as_bytes(
		base.path_join(WorldHosting.INVITE_FILE))
	_expect(old_invite.size() == 32, "The room's invitation is 32 bytes")

	# A member joins with the old code and leaves evidence in the world that a
	# restart must preserve: a committed command, not a local guess.
	var joined: bool = await _join(old_member_code, MEMBER, "阿青")
	_expect(joined, "The old member code admits a member before rotation")
	if not joined:
		await _cleanup()
		_finish()
		return
	_expect(client.submit(FarmCommand.make_set_theft("rotation-before", true,
		client.world_time())), "The joined member submits one command")
	var committed: bool = await _wait(func() -> bool: return _committed, 10000)
	_expect(committed, "The authority commits the command before rotation")
	# A commit reply carries no whole farm, so ask for one summary and require the
	# committed effect to be visible before the room is restarted.
	client.request_summary()
	var effect_seen: bool = await _wait(func() -> bool:
		return _theft(state.get("farm"), MEMBER), 8000)
	_expect(effect_seen, "The world state carries that command's effect")
	await _close_client()
	await create_timer(0.3).timeout

	# Rotate: this stops the authority, replaces the invitation and restarts it.
	var once: Dictionary = hosting.rotate_invites(8000)
	_expect(bool(once.get("ok", false)), "A rotation succeeds (reason=%s)"
		% str(once.get("reason", "")))
	if not bool(once.get("ok", false)):
		await _cleanup()
		_finish()
		return
	_expect(hosting.is_running(), "The rotated room is serving again")
	_expect(int(once.get("pid", 0)) == hosting.pid and hosting.pid > 0,
		"The rotation reports the restarted process")
	_expect(str(once.get("url", "")) == hosting.url(),
		"The rotation keeps the same room address and port")
	var new_member_code: String = str(once.get("join_code", ""))
	var new_visitor_code: String = str(once.get("visitor_join_code", ""))
	_expect(new_member_code.begins_with(WorldJoinCode.PREFIX),
		"The rotated room produces a member code")
	_expect(new_visitor_code.begins_with(WorldJoinCode.PREFIX),
		"The rotated room produces a visitor code")
	_expect(new_member_code != old_member_code,
		"The member code changed instead of being re-issued")
	_expect(new_visitor_code != old_visitor_code,
		"The visitor code changed with the invitation")
	_expect(str(once.get("previous", "")) == WorldHosting.INVITE_PREVIOUS,
		"The answer names the archived previous invitation")

	var new_invite: PackedByteArray = FileAccess.get_file_as_bytes(
		base.path_join(WorldHosting.INVITE_FILE))
	_expect(new_invite.size() == 32, "The current invitation is still 32 bytes")
	_expect(new_invite != old_invite, "invite.bin bytes changed")
	var archived: PackedByteArray = FileAccess.get_file_as_bytes(
		base.path_join(WorldHosting.INVITE_PREVIOUS))
	_expect(archived == old_invite, "The previous invitation is archived byte-for-byte")
	_expect(not FileAccess.file_exists(base.path_join(WorldHosting.INVITE_PENDING)),
		"A successful rotation leaves no pending file behind")
	var new_grant: Dictionary = WorldJoinCode.decode(new_member_code).get("grant", {}) as Dictionary
	_expect(new_grant.get("secret") == new_invite,
		"The new code carries the invitation file that is now current")
	var new_visitor_grant: Dictionary = WorldJoinCode.decode(new_visitor_code).get(
		"grant", {}) as Dictionary
	_expect(str(new_visitor_grant.get("role", "")) == WorldInvite.VISITOR,
		"The rotated visitor code still names the visitor role")

	# The old codes must be refused, the new ones must work.
	_expect(not await _join(old_member_code, MEMBER, "阿青"),
		"The old member code no longer reaches an authoritative state")
	var old_member_reason: String = str(state.get("refused", state.get("lost", "")))
	_expect(not old_member_reason.is_empty(),
		"The old member code is refused with a reason (got %s)" % old_member_reason)
	await _close_client()
	await create_timer(0.4).timeout
	_expect(not await _join(old_visitor_code, VISITOR, "小禾"),
		"The old visitor code no longer reaches an authoritative state")
	var old_visitor_reason: String = str(state.get("refused", state.get("lost", "")))
	_expect(not old_visitor_reason.is_empty(),
		"The old visitor code is refused with a reason (got %s)" % old_visitor_reason)
	await _close_client()
	await create_timer(0.4).timeout

	var rejoin: bool = await _join(new_member_code, MEMBER, "阿青")
	_expect(rejoin, "The new member code admits the former member")
	_expect(rejoin and _theft(state.get("farm"), MEMBER),
		"The rotated authority kept the world state written before the rotation")
	await _close_client()
	await create_timer(0.3).timeout
	var visitor_role: String = ""
	if await _join(new_visitor_code, VISITOR, "小禾"):
		visitor_role = str(client.member.role)
	_expect(visitor_role == WorldInvite.VISITOR,
		"The new visitor code admits a visitor (got %s)" % visitor_role)
	await _close_client()
	await create_timer(0.3).timeout

	# A second rotation must work from the already rotated state.
	var first_member_code: String = new_member_code
	var first_invite: PackedByteArray = new_invite
	var twice: Dictionary = hosting.rotate_invites(8000)
	_expect(bool(twice.get("ok", false)), "A second rotation succeeds (reason=%s)"
		% str(twice.get("reason", "")))
	if bool(twice.get("ok", false)):
		_expect(str(twice.get("join_code", "")) != first_member_code,
			"The second rotation issues yet another member code")
		_expect(FileAccess.get_file_as_bytes(base.path_join(WorldHosting.INVITE_PREVIOUS))
			== first_invite, "The second rotation archives the first rotated invitation")
		var second_role: String = ""
		if await _join(str(twice.get("join_code", "")), MEMBER, "阿青"):
			second_role = str(client.member.role)
		_expect(second_role == WorldInvite.MEMBER,
			"The newest member code admits a member")
		await _close_client()
		await create_timer(0.3).timeout

	# Failure path: a pending name that cannot be written. The current room and
	# its invitation must survive untouched, because the write is attempted
	# before the authority is stopped.
	var before_failure: PackedByteArray = FileAccess.get_file_as_bytes(
		base.path_join(WorldHosting.INVITE_FILE))
	var pending_path: String = base.path_join(WorldHosting.INVITE_PENDING)
	_expect(DirAccess.make_dir_absolute(pending_path) == OK,
		"The test can block the pending invitation path with a directory")
	var blocked: Dictionary = hosting.rotate_invites(8000)
	_expect(not bool(blocked.get("ok", false)),
		"A rotation whose new invitation cannot be written is refused")
	_expect(str(blocked.get("reason", "")) == "write_failed",
		"The refusal names the write failure (got %s)" % str(blocked.get("reason", "")))
	_expect(hosting.is_running(), "A refused rotation leaves the room running")
	_expect(FileAccess.get_file_as_bytes(base.path_join(WorldHosting.INVITE_FILE))
		== before_failure, "A refused rotation leaves the current invitation in place")
	DirAccess.remove_absolute(pending_path)
	var surviving_role: String = ""
	if await _join(str(twice.get("join_code", "")), MEMBER, "阿青"):
		surviving_role = str(client.member.role)
	_expect(surviving_role == WorldInvite.MEMBER,
		"The code in force before the failed rotation still admits a member")
	await _close_client()
	await create_timer(0.3).timeout

	# Rollback path: the archive name is a directory, so the old file can be
	# written and the room stopped, but it cannot be moved aside. The rotation
	# must put the untouched invitation back in force and restart on it.
	var archived_path: String = base.path_join(WorldHosting.INVITE_PREVIOUS)
	DirAccess.remove_absolute(archived_path)
	_expect(DirAccess.make_dir_absolute(archived_path) == OK,
		"The test can block the archive name with a directory")
	var archive_blocked: Dictionary = hosting.rotate_invites(8000)
	_expect(not bool(archive_blocked.get("ok", false))
		and str(archive_blocked.get("reason", "")) == "archive_failed",
		"An archive that cannot be replaced is refused as archive_failed (got %s)"
		% str(archive_blocked.get("reason", "")))
	_expect(hosting.is_running(), "The rollback restarts the room on the old invitation")
	_expect(FileAccess.get_file_as_bytes(base.path_join(WorldHosting.INVITE_FILE))
		== before_failure, "The rollback keeps the invitation that was in force")
	DirAccess.remove_absolute(archived_path)
	var rolled_back_role: String = ""
	if await _join(str(twice.get("join_code", "")), MEMBER, "阿青"):
		rolled_back_role = str(client.member.role)
	_expect(rolled_back_role == WorldInvite.MEMBER,
		"The old code still admits a member after the rolled-back rotation")
	await _close_client()
	await create_timer(0.3).timeout

	# A rotation after the room is stopped is refused without touching the files.
	var final_invite: PackedByteArray = FileAccess.get_file_as_bytes(
		base.path_join(WorldHosting.INVITE_FILE))
	var stopped_host: WorldHosting = hosting
	await _cleanup()
	var stopped: Dictionary = stopped_host.rotate_invites(1000)
	_expect(not bool(stopped.get("ok", false))
		and str(stopped.get("reason", "")) == "not_started",
		"A rotation with no room running is refused as not_started")
	_expect(FileAccess.get_file_as_bytes(base.path_join(WorldHosting.INVITE_FILE))
		== final_invite, "A refused rotation after stop does not rewrite invite.bin")
	_finish()


func _join(code: String, player_id: String, player_name: String) -> bool:
	state = {}
	_committed = false
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(farm: RefCounted, decorations: RefCounted,
			now_utc: float) -> void:
		state = {"farm": farm, "decorations": decorations, "now_utc": now_utc})
	client.refused.connect(func(reason: String) -> void: state = {"refused": reason})
	client.lost.connect(func(reason: String) -> void: state = {"lost": reason})
	client.committed.connect(func(_request_id: String, _reply: Dictionary) -> void:
		_committed = true)
	if not client.start(code, player_id, player_name,
		Marshalls.base64_to_raw(PLAYER_SECRET)):
		return false
	return await _wait(func() -> bool: return state.has("farm"), 25000)


func _theft(farm: Variant, player_id: String) -> bool:
	if not farm is RefCounted or not farm.has_method("theft_enabled"):
		return false
	return bool(farm.call("theft_enabled", player_id))


func _close_client() -> void:
	if client != null:
		client.close()
		client.queue_free()
		client = null
	await process_frame
	await process_frame


func _await_ready(seconds: float) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var answer: Dictionary = hosting.poll()
		if bool(answer.get("ok", false)):
			return answer
		var reason: String = str(answer.get("reason", ""))
		if not reason.is_empty() and reason != "pending":
			return answer
		await create_timer(0.2).timeout
	return hosting.poll()


func _wait(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _free_port() -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = Time.get_ticks_usec()
	for attempt: int in 8:
		var port: int = rng.randi_range(20000, 45000)
		var probe := TCPServer.new()
		if probe.listen(port, "127.0.0.1") == OK:
			probe.stop()
			return port
	return 20000 + rng.randi_range(0, 999)


func _cleanup() -> void:
	await _close_client()
	if hosting != null:
		hosting.stop()
		hosting = null
	await create_timer(0.2).timeout


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("INVITE_ROTATION_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
