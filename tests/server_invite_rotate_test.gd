extends SceneTree
## The resident authority's operator rotation entry point (`--rotate-invite`).
##
## The in-game room can replace its join code; this is the same action for a
## self-hosted directory, without a UI. The real `world_server.gd` runs as a
## subprocess: it must replace the invitation, archive the old one, print the
## new codes once (the next start prints nothing), and exit before binding a
## port. A refused rotation must leave the directory on its old code, and a
## relative `--data-dir` must be refused before any write.
##
## Fixtures live under `.local/verification/server-invite-rotate-*`.

const WorldJoinCode = preload("res://world/world_join_code.gd")
const WorldInvite = preload("res://world/world_invite.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const WORLD: String = "world-rotate"
const INVITE: String = "invite.bin"
const PREVIOUS: String = "invite.previous.bin"
const PENDING: String = "invite.pending.bin"
const VISITOR_CODE: String = "visitor-join-code.txt"
const STATUS: String = "server-status.json"
const FARM: String = "farm.json"

var checks: int = 0
var failures: Array[String] = []
var dir: String = ""
var _join_url_value: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(".local/verification/server-invite-rotate-%d"
		% Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)

	_test_relative_directory()
	_test_missing_invitation()
	var world: String = dir.path_join("world")
	if not _materialize(world):
		_finish()
		return
	var first_code: String = _test_rotation_once(world)
	_test_second_rotation(world, first_code)
	_test_invalid_invitation(world)
	_test_missing_after_removal(world)
	_test_live_lock(world)
	_test_bad_join_url(world)
	_test_without_join_url(world)
	_test_external_invite_file()
	_finish()

# ------------------------------------------------------------ refused inputs

## A relative path must be refused before the directory exists: rotating the
## wrong directory would invalidate a code someone else is using.
func _test_relative_directory() -> void:
	var relative: String = dir.trim_prefix(_repo() + "/").path_join("relative-leak")
	var leaked: String = _repo().path_join(relative)
	var run: Dictionary = _run_once(["--data-dir=" + relative, "--rotate-invite"])
	_expect(int(run.exit_code) != 0, "A relative data directory is refused")
	_expect(str(run.output).contains("relative_data_dir"),
		"The refusal names the relative data directory")
	_expect(not DirAccess.dir_exists_absolute(leaked),
		"A refused relative rotation creates no directory")
	if DirAccess.dir_exists_absolute(leaked):
		DirAccess.remove_absolute(leaked)


## A directory that never held an invitation has nothing to rotate. This is the
## deterministic failure path: it is refused by name without inventing a file.
func _test_missing_invitation() -> void:
	var absent: String = dir.path_join("absent")
	var absent_run: Dictionary = _run_once(["--data-dir=" + absent, "--rotate-invite"])
	_expect(int(absent_run.exit_code) == 3, "A rotation in a missing directory exits 3")
	_expect(str(absent_run.output).contains("invite_rotate_data_dir_missing"),
		"The refusal names the missing data directory")
	_expect(not DirAccess.dir_exists_absolute(absent),
		"Rotation does not create a missing data directory")
	var empty: String = dir.path_join("empty")
	DirAccess.make_dir_recursive_absolute(empty)
	var run: Dictionary = _run_once(["--data-dir=" + empty, "--rotate-invite"])
	_expect(int(run.exit_code) == 3, "A rotation without an invitation exits 3")
	_expect(str(run.output).contains("invite_rotate_invite_missing"),
		"The refusal names the missing invitation")
	_expect(not FileAccess.file_exists(empty.path_join(INVITE)),
		"A refused rotation does not invent an invitation")
	_expect(not FileAccess.file_exists(empty.path_join(PENDING)),
		"A refused rotation leaves no pending file")
	_expect(not FileAccess.file_exists(empty.path_join(STATUS)),
		"Rotation never writes the server status file")


# -------------------------------------------------------------- happy paths

## Creates a real directory through a bounded start, which writes key, cert and
## invitation exactly as a deployment would.
func _materialize(world: String) -> bool:
	DirAccess.make_dir_recursive_absolute(world)
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--port=%d" % _free_port(), "--run-seconds=1",
		"--world=" + WORLD, "--join-url=" + _join_url(),
	])
	_expect(int(run.exit_code) == 0, "A bounded first start creates the directory")
	return FileAccess.file_exists(world.path_join(INVITE))


func _test_rotation_once(world: String) -> String:
	var old_invite: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(INVITE))
	var old_visitor: String = FileAccess.get_file_as_string(world.path_join(VISITOR_CODE))
	var farm_before: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(FARM))
	var status_before: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(STATUS))
	_expect(old_invite.size() == 32, "The directory starts with a 32-byte invitation")
	_expect(old_visitor.begins_with(WorldJoinCode.PREFIX),
		"The first run writes a visitor code")

	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--rotate-invite", "--world=" + WORLD,
		"--join-url=" + _join_url(),
	])
	_expect(int(run.exit_code) == 0,
		"A rotation succeeds (exit=%d %s)" % [int(run.exit_code), str(run.output).strip_edges()])
	var new_invite: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(INVITE))
	_expect(new_invite.size() == 32, "The rotated invitation is 32 bytes")
	_expect(new_invite != old_invite, "invite.bin bytes changed")
	_expect(FileAccess.get_file_as_bytes(world.path_join(PREVIOUS)) == old_invite,
		"The previous invitation is archived byte-for-byte")
	_expect(not FileAccess.file_exists(world.path_join(PENDING)),
		"A successful rotation leaves no pending file")
	_expect(FileAccess.get_file_as_bytes(world.path_join(FARM)) == farm_before,
		"Rotation never opens or rewrites the world document")
	_expect(FileAccess.get_file_as_bytes(world.path_join(STATUS)) == status_before,
		"Rotation leaves the stopped status file alone")

	var answer: Dictionary = _line_payload(run.output, "WORLD_SERVER_INVITE_ROTATED")
	_expect(bool(answer.get("ok", false)), "The rotation reports success on stdout")
	_expect(str(answer.get("previous", "")) == PREVIOUS,
		"The answer names the archived previous invitation")
	_expect(str(answer.get("world_id", "")) == WORLD,
		"The answer names the world the new code is valid for")
	var join_code: String = str(answer.get("join_code", ""))
	var decoded: Dictionary = WorldJoinCode.decode(join_code)
	_expect(bool(decoded.get("ok", false)), "The printed join code parses")
	var grant: Dictionary = decoded.get("grant", {}) as Dictionary
	_expect((grant.get("secret", PackedByteArray()) as PackedByteArray) == new_invite,
		"The printed code carries the invitation file that is now current")
	_expect(str(grant.get("role", "")) == WorldInvite.MEMBER,
		"The printed code confers membership")
	_expect(str(decoded.get("url", "")) == _join_url(),
		"The printed code carries the operator's endpoint")
	_expect(str(run.output).contains("INVITE_ROTATED previous=" + PREVIOUS),
		"The rotation prints the one-line archive marker")

	var visitor: String = FileAccess.get_file_as_string(world.path_join(VISITOR_CODE))
	_expect(visitor != old_visitor, "The visitor code changed with the invitation")
	_expect(str(answer.get("visitor_code", "")) == "written",
		"The answer reports the rewritten visitor code")
	var visitor_decoded: Dictionary = WorldJoinCode.decode(visitor)
	_expect(bool(visitor_decoded.get("ok", false)), "The rewritten visitor code parses")
	var visitor_grant: Dictionary = visitor_decoded.get("grant", {}) as Dictionary
	_expect(str(visitor_grant.get("role", "")) == WorldInvite.VISITOR,
		"The rewritten visitor code still names the visitor role")
	_expect((visitor_grant.get("secret", PackedByteArray()) as PackedByteArray) != new_invite,
		"The visitor secret is derived, not the member secret")
	return join_code

## Two rotations in a row: the archive keeps only the immediately previous
## invitation, never the first one.
func _test_second_rotation(world: String, first_code: String) -> void:
	var first_rotated: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(INVITE))
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--rotate-invite", "--world=" + WORLD,
		"--join-url=" + _join_url(),
	])
	_expect(int(run.exit_code) == 0, "A second rotation succeeds")
	var second_invite: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(INVITE))
	_expect(second_invite != first_rotated, "The second rotation changes the invitation again")
	_expect(FileAccess.get_file_as_bytes(world.path_join(PREVIOUS)) == first_rotated,
		"The archive holds the first rotated invitation")
	var second_answer: Dictionary = _line_payload(run.output, "WORLD_SERVER_INVITE_ROTATED")
	_expect(str(second_answer.get("join_code", "")) != first_code,
		"The second rotation issues a different join code")


# ----------------------------------------------------------- refusal paths

## A malformed current invitation is refused instead of replaced, so a wrong
## `--invite-file` cannot silently produce a credential nobody had.
func _test_invalid_invitation(world: String) -> void:
	var good: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(INVITE))
	var previous: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(PREVIOUS))
	var broken := FileAccess.open(world.path_join(INVITE), FileAccess.WRITE)
	broken.store_buffer(PackedByteArray([1, 2, 3, 4, 5]))
	broken.close()
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--rotate-invite", "--world=" + WORLD,
	])
	_expect(int(run.exit_code) == 3, "A malformed invitation is refused with exit 3")
	_expect(str(run.output).contains("invite_rotate_invite_invalid"),
		"The refusal names the malformed invitation")
	_expect(FileAccess.get_file_as_bytes(world.path_join(INVITE)) == PackedByteArray([1, 2, 3, 4, 5]),
		"A refused rotation does not rewrite the malformed file")
	_expect(FileAccess.get_file_as_bytes(world.path_join(PREVIOUS)) == previous,
		"A refused rotation leaves the archive alone")
	_expect(not FileAccess.file_exists(world.path_join(PENDING)),
		"A refused rotation leaves no pending file")
	# The directory is usable again once the real file is back; that is the
	# recovery the operator performs.
	_restore(world.path_join(INVITE), good)
	_expect(FileAccess.get_file_as_bytes(world.path_join(INVITE)) == good,
		"The test restores the usable invitation")


## The invitation disappearing between two rotations is the second guaranteed
## refusal: no generated file, no changed archive.
func _test_missing_after_removal(world: String) -> void:
	var good: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(INVITE))
	var previous: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(PREVIOUS))
	var saved: String = world.path_join("invite.saved")
	_expect(DirAccess.rename_absolute(world.path_join(INVITE), saved) == OK,
		"The test can move the live invitation aside")
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--rotate-invite", "--world=" + WORLD,
	])
	_expect(int(run.exit_code) == 3, "A rotation with no current invitation exits 3")
	_expect(str(run.output).contains("invite_rotate_invite_missing"),
		"The refusal names the missing invitation")
	_expect(not FileAccess.file_exists(world.path_join(PENDING)),
		"A missing-invitation refusal leaves no pending file")
	_expect(FileAccess.get_file_as_bytes(world.path_join(PREVIOUS)) == previous,
		"A missing-invitation refusal leaves the archive alone")
	DirAccess.rename_absolute(saved, world.path_join(INVITE))
	_expect(FileAccess.get_file_as_bytes(world.path_join(INVITE)) == good,
		"The restored invitation is the one the directory had")


## Rotating under a live authority cannot revoke the codes that process already
## serves, so the directory lock must refuse it instead.
func _test_live_lock(world: String) -> void:
	var good: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(INVITE))
	var lock: String = world.path_join("authority.lock")
	DirAccess.make_dir_absolute(lock)
	var owner := FileAccess.open(lock.path_join("owner"), FileAccess.WRITE)
	_expect(owner != null, "The test can create a fresh authority lock")
	if owner != null:
		owner.store_string(str(OS.get_process_id()))
		owner.close()
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--rotate-invite", "--world=" + WORLD,
	])
	_expect(int(run.exit_code) == 3, "A rotation under a live authority exits 3")
	_expect(str(run.output).contains("invite_rotate_data_dir_locked"),
		"The refusal names the directory lock")
	_expect(FileAccess.get_file_as_bytes(world.path_join(INVITE)) == good,
		"A locked-out rotation leaves the invitation alone")
	_expect(not FileAccess.file_exists(world.path_join(PENDING)),
		"A locked-out rotation leaves no pending file")
	DirAccess.remove_absolute(lock.path_join("owner"))
	DirAccess.remove_absolute(lock)


## A rotation that could not hand back a usable code must not revoke the old
## one: an unusable endpoint is refused before the invitation is written.
func _test_bad_join_url(world: String) -> void:
	var good: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(INVITE))
	var previous: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(PREVIOUS))
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--rotate-invite", "--world=" + WORLD,
		"--join-url=http://192.168.1.20:7777",
	])
	_expect(int(run.exit_code) == 3, "An unusable endpoint is refused with exit 3")
	_expect(str(run.output).contains("invite_rotate_certificate_or_join_url_invalid"),
		"The refusal names the endpoint or certificate")
	_expect(FileAccess.get_file_as_bytes(world.path_join(INVITE)) == good,
		"A refused endpoint leaves the invitation in force")
	_expect(FileAccess.get_file_as_bytes(world.path_join(PREVIOUS)) == previous,
		"A refused endpoint leaves the archive alone")
	_expect(not FileAccess.file_exists(world.path_join(PENDING)),
		"A refused endpoint leaves no pending file")


## Without an endpoint there is no join code and no visitor code, matching the
## first-run rule; the file already on disk is not rewritten.
func _test_without_join_url(world: String) -> void:
	var visitor_before: String = FileAccess.get_file_as_string(world.path_join(VISITOR_CODE))
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--rotate-invite", "--world=" + WORLD,
	])
	_expect(int(run.exit_code) == 0, "A rotation without --join-url succeeds")
	var answer: Dictionary = _line_payload(run.output, "WORLD_SERVER_INVITE_ROTATED")
	_expect(bool(answer.get("ok", false)), "The rotation still reports success")
	_expect(not answer.has("join_code"), "No join code is printed without an endpoint")
	_expect(str(answer.get("visitor_code", "")) == "skipped_no_join_url",
		"The answer says the visitor code was skipped")
	_expect(FileAccess.get_file_as_string(world.path_join(VISITOR_CODE)) == visitor_before,
		"A rotation without an endpoint does not rewrite the visitor code")


## `--invite-file` points the rotation somewhere else; the archive and pending
## names follow that file, and the visitor code still belongs to the data dir.
func _test_external_invite_file() -> void:
	var data: String = dir.path_join("external-data")
	var external: String = dir.path_join("external")
	DirAccess.make_dir_recursive_absolute(external)
	var external_invite: String = external.path_join("custom.bin")
	var started: Dictionary = _run_once([
		"--data-dir=" + data, "--invite-file=" + external_invite,
		"--port=%d" % _free_port(), "--run-seconds=1", "--world=" + WORLD,
		"--join-url=" + _join_url(),
	])
	_expect(int(started.exit_code) == 0, "A start with --invite-file creates that file")
	if not FileAccess.file_exists(external_invite):
		_expect(false, "The external invitation exists")
		return
	var old_invite: PackedByteArray = FileAccess.get_file_as_bytes(external_invite)
	var run: Dictionary = _run_once([
		"--data-dir=" + data, "--invite-file=" + external_invite,
		"--rotate-invite", "--world=" + WORLD, "--join-url=" + _join_url(),
	])
	_expect(int(run.exit_code) == 0, "A rotation of an external invitation succeeds")
	var new_invite: PackedByteArray = FileAccess.get_file_as_bytes(external_invite)
	_expect(new_invite.size() == 32 and new_invite != old_invite,
		"The external invitation file was replaced")
	_expect(FileAccess.get_file_as_bytes(external.path_join(PREVIOUS)) == old_invite,
		"The archive lives beside the external invitation")
	_expect(not FileAccess.file_exists(external.path_join(PENDING)),
		"No pending file is left beside the external invitation")
	_expect(FileAccess.file_exists(data.path_join(VISITOR_CODE)),
		"The visitor code is still written into the data directory")
	var answer: Dictionary = _line_payload(run.output, "WORLD_SERVER_INVITE_ROTATED")
	_expect(bool(WorldJoinCode.decode(str(answer.get("join_code", ""))).get("ok", false)),
		"The external rotation prints a parseable join code")


# ------------------------------------------------------------ server driver


func _run_once(arguments: Array) -> Dictionary:
	var output: Array = []
	var code: int = OS.execute(_exe(), PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
	] + arguments), output, true)
	return {"exit_code": code, "output": "\n".join(output)}


func _line_payload(output: String, tag: String) -> Dictionary:
	for line: String in output.split("\n"):
		var trimmed: String = line.strip_edges()
		if not trimmed.begins_with(tag + " "):
			continue
		var parsed: Variant = JSON.parse_string(trimmed.trim_prefix(tag + " "))
		if parsed is Dictionary:
			return parsed
	return {}


func _restore(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_buffer(bytes)
	file.close()


func _join_url() -> String:
	# The endpoint only has to be a plausible address; a cached value keeps the
	# code printed by one run comparable to what the test expects from another.
	if _join_url_value.is_empty():
		_join_url_value = "wss://192.168.1.20:%d" % _free_port()
	return _join_url_value


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _exe() -> String:
	return OS.get_executable_path()


func _free_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0, "127.0.0.1") != OK:
		return 7777
	var chosen: int = probe.get_local_port()
	probe.stop()
	return chosen


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("SERVER_INVITE_ROTATE_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
