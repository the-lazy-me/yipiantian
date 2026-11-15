extends SceneTree
## The resident authority's read-only reprint entry point (`--print-invite`).
##
## Rotation revokes the code everyone holds, so an operator who merely lost the
## printed copy needs a way to recover the same codes. The real `world_server.gd`
## runs as a subprocess: it must rebuild the member (and, with `--join-url`, the
## join and visitor) code from the existing invitation, leave every file byte for
## byte as it was, take no lock, open no world and bind no port. Refusals are
## named and exit 3, like rotation.
##
## Fixtures live under `.local/verification/server-invite-print-*`.

const WorldJoinCode = preload("res://world/world_join_code.gd")
const WorldInvite = preload("res://world/world_invite.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const WORLD: String = "world-print"
const INVITE: String = "invite.bin"
const VISITOR_CODE: String = "visitor-join-code.txt"
const STATUS: String = "server-status.json"
const FARM: String = "farm.json"
const WORLD_ID: String = "world-id.txt"

var checks: int = 0
var failures: Array[String] = []
var dir: String = ""
var _join_url_value: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(".local/verification/server-invite-print-%d"
		% Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)

	_test_missing_directory()
	var world: String = dir.path_join("world")
	if not _materialize(world):
		_finish()
		return
	_test_print_current(world)
	_test_print_without_join_url(world)
	_test_print_under_live_lock(world)
	_test_missing_invitation(world)
	_test_invalid_invitation(world)
	_test_world_mismatch(world)
	_test_bad_join_url(world)
	_test_conflicting_options(world)
	_finish()

# ------------------------------------------------------------ refused inputs

## A directory that was never deployed has no code to reprint; it must not be
## created, and the reason must say so rather than inventing an invitation.
func _test_missing_directory() -> void:
	var absent: String = dir.path_join("absent")
	var run: Dictionary = _run_once(["--data-dir=" + absent, "--print-invite"])
	_expect(int(run.exit_code) == 3, "Reprinting in a missing directory exits 3")
	_expect(str(run.output).contains("invite_print_data_dir_missing"),
		"The refusal names the missing data directory")
	_expect(not DirAccess.dir_exists_absolute(absent),
		"Reprinting does not create a missing data directory")


# -------------------------------------------------------------- happy paths

## Creates a real directory through a bounded start, exactly as a deployment
## would, so the reprint reads the same material the operator has.
func _materialize(world: String) -> bool:
	DirAccess.make_dir_recursive_absolute(world)
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--port=%d" % _free_port(), "--run-seconds=1",
		"--world=" + WORLD, "--join-url=" + _join_url(),
	])
	_expect(int(run.exit_code) == 0, "A bounded first start creates the directory")
	return FileAccess.file_exists(world.path_join(INVITE))


## The deployed directory: the reprint must hand back the same codes the first
## run printed and change nothing on disk.
func _test_print_current(world: String) -> void:
	var invite: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(INVITE))
	var visitor_file: PackedByteArray = FileAccess.get_file_as_bytes(
		world.path_join(VISITOR_CODE))
	var farm_before: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(FARM))
	var status_before: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(STATUS))
	var world_id_before: PackedByteArray = FileAccess.get_file_as_bytes(
		world.path_join(WORLD_ID))
	_expect(invite.size() == 32, "The directory has a 32-byte invitation")
	_expect(visitor_file.size() > 0, "The first run wrote a visitor code")

	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--print-invite", "--world=" + WORLD,
		"--join-url=" + _join_url(),
	])
	_expect(int(run.exit_code) == 0,
		"A reprint succeeds (exit=%d %s)" % [int(run.exit_code), str(run.output).strip_edges()])
	var answer: Dictionary = _line_payload(run.output, "WORLD_SERVER_INVITE_PRINTED")
	_expect(bool(answer.get("ok", false)), "The reprint reports success on stdout")
	_expect(str(answer.get("state", "")) == "printed", "The answer names the printed state")
	_expect(str(answer.get("data_dir", "")) == world, "The answer names the data directory")
	_expect(str(answer.get("world_id", "")) == WORLD,
		"The answer names the world the code is valid for")

	var invite_code: String = str(answer.get("invite_code", ""))
	var decoded_invite: Dictionary = WorldInvite.decode(invite_code)
	_expect(bool(decoded_invite.get("ok", false)), "The printed invite code parses")
	var member_grant: Dictionary = decoded_invite.get("grant", {}) as Dictionary
	_expect((member_grant.get("secret", PackedByteArray()) as PackedByteArray) == invite,
		"The printed invite code carries the current invite.bin")
	_expect(str(member_grant.get("role", "")) == WorldInvite.MEMBER,
		"The printed invite code confers membership")
	_expect(str(member_grant.get("world_id", "")) == WORLD,
		"The printed invite code carries the world name")

	var join_code: String = str(answer.get("join_code", ""))
	var decoded_join: Dictionary = WorldJoinCode.decode(join_code)
	_expect(bool(decoded_join.get("ok", false)), "The printed join code parses")
	var join_grant: Dictionary = decoded_join.get("grant", {}) as Dictionary
	_expect((join_grant.get("secret", PackedByteArray()) as PackedByteArray) == invite,
		"The printed join code carries the current invite.bin")
	_expect(str(decoded_join.get("url", "")) == _join_url(),
		"The printed join code carries the operator's endpoint")

	var printed_visitor: String = str(answer.get("visitor_code", ""))
	var decoded_visitor: Dictionary = WorldJoinCode.decode(printed_visitor)
	_expect(bool(decoded_visitor.get("ok", false)), "The printed visitor code parses")
	var visitor_grant: Dictionary = decoded_visitor.get("grant", {}) as Dictionary
	_expect(str(visitor_grant.get("role", "")) == WorldInvite.VISITOR,
		"The printed visitor code names the visitor role")
	_expect((visitor_grant.get("secret", PackedByteArray()) as PackedByteArray) != invite,
		"The printed visitor secret is derived, not the member secret")

	# Read-only means read-only: every file the deployment owns must be untouched.
	_expect(FileAccess.get_file_as_bytes(world.path_join(INVITE)) == invite,
		"The reprint does not change invite.bin")
	_expect(FileAccess.get_file_as_bytes(world.path_join(VISITOR_CODE)) == visitor_file,
		"The reprint does not rewrite visitor-join-code.txt")
	_expect(FileAccess.get_file_as_bytes(world.path_join(FARM)) == farm_before,
		"The reprint never opens or rewrites the world document")
	_expect(FileAccess.get_file_as_bytes(world.path_join(STATUS)) == status_before,
		"The reprint leaves the stopped status file alone")
	_expect(FileAccess.get_file_as_bytes(world.path_join(WORLD_ID)) == world_id_before,
		"The reprint leaves world-id.txt alone")
	_expect(not DirAccess.dir_exists_absolute(world.path_join("authority.lock")),
		"The reprint takes no authority lock")
	_expect(not FileAccess.file_exists(world.path_join("invite.pending.bin")),
		"The reprint leaves no pending invitation")
	_expect(not FileAccess.file_exists(world.path_join("invite.previous.bin")),
		"The reprint creates no invitation archive")
	_expect(not str(run.output).contains("WORLD_SERVER_READY"),
		"The reprint never starts the server")


## Without an endpoint there is no join or visitor code, matching the first-run
## rule; the member invitation is still printed.
func _test_print_without_join_url(world: String) -> void:
	var visitor_before: PackedByteArray = FileAccess.get_file_as_bytes(
		world.path_join(VISITOR_CODE))
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--print-invite", "--world=" + WORLD,
	])
	_expect(int(run.exit_code) == 0, "A reprint without --join-url succeeds")
	var answer: Dictionary = _line_payload(run.output, "WORLD_SERVER_INVITE_PRINTED")
	_expect(bool(answer.get("ok", false)), "The endpoint-less reprint reports success")
	_expect(bool(WorldInvite.decode(str(answer.get("invite_code", ""))).get("ok", false)),
		"The endpoint-less reprint still prints an invitable member code")
	_expect(not answer.has("join_code"), "No join code is printed without an endpoint")
	_expect(not answer.has("visitor_code"),
		"No visitor code is printed without an endpoint")
	_expect(FileAccess.get_file_as_bytes(world.path_join(VISITOR_CODE)) == visitor_before,
		"The endpoint-less reprint does not rewrite the visitor code")


## A reprint must not need the single-authority lock: the running process already
## serves exactly this invitation, so reading it changes nothing it relies on.
func _test_print_under_live_lock(world: String) -> void:
	var invite: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(INVITE))
	var lock: String = world.path_join("authority.lock")
	DirAccess.make_dir_absolute(lock)
	var owner := FileAccess.open(lock.path_join("owner"), FileAccess.WRITE)
	_expect(owner != null, "The test can create a fresh authority lock")
	if owner != null:
		owner.store_string(str(OS.get_process_id()))
		owner.close()
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--print-invite", "--world=" + WORLD,
	])
	_expect(int(run.exit_code) == 0, "A reprint under a live authority succeeds")
	_expect(str(run.output).contains("WORLD_SERVER_INVITE_PRINTED"),
		"The live-authority reprint prints the codes")
	_expect(FileAccess.file_exists(lock.path_join("owner")),
		"The reprint leaves the running authority's lock alone")
	_expect(FileAccess.get_file_as_bytes(world.path_join(INVITE)) == invite,
		"The live-authority reprint leaves the invitation alone")
	DirAccess.remove_absolute(lock.path_join("owner"))
	DirAccess.remove_absolute(lock)


# ----------------------------------------------------------- refusal paths

## The invitation disappearing is a refusal, not a new credential.
func _test_missing_invitation(world: String) -> void:
	var saved: String = world.path_join("invite.saved")
	_expect(DirAccess.rename_absolute(world.path_join(INVITE), saved) == OK,
		"The test can move the live invitation aside")
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--print-invite", "--world=" + WORLD,
	])
	_expect(int(run.exit_code) == 3, "A reprint without an invitation exits 3")
	_expect(str(run.output).contains("invite_print_invite_missing"),
		"The refusal names the missing invitation")
	_expect(not FileAccess.file_exists(world.path_join(INVITE)),
		"A refused reprint does not invent an invitation")
	DirAccess.rename_absolute(saved, world.path_join(INVITE))


## A file that is not the 32 bytes `_material` writes is refused by name, and the
## operator's file is left as it is for inspection.
func _test_invalid_invitation(world: String) -> void:
	var good: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(INVITE))
	_write_bytes(world.path_join(INVITE), PackedByteArray([1, 2, 3, 4, 5]))
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--print-invite", "--world=" + WORLD,
	])
	_expect(int(run.exit_code) == 3, "A malformed invitation is refused with exit 3")
	_expect(str(run.output).contains("invite_print_invite_invalid"),
		"The refusal names the malformed invitation")
	_expect(FileAccess.get_file_as_bytes(world.path_join(INVITE)) == PackedByteArray([1, 2, 3, 4, 5]),
		"A refused reprint does not rewrite the malformed file")
	_write_bytes(world.path_join(INVITE), good)


## A code printed for a world this directory will not serve would be dead on
## arrival.
func _test_world_mismatch(world: String) -> void:
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--print-invite", "--world=another-world",
	])
	_expect(int(run.exit_code) == 3, "A reprint for another world exits 3")
	_expect(str(run.output).contains("invite_print_world_mismatch"),
		"The refusal names the world mismatch")
	_expect(not str(run.output).contains("WORLD_SERVER_INVITE_PRINTED"),
		"A mismatched world prints no code")


## An unreadable certificate or unusable endpoint is refused before any code is
## assembled; the invitation is untouched either way.
func _test_bad_join_url(world: String) -> void:
	var invite: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(INVITE))
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--print-invite", "--world=" + WORLD,
		"--join-url=http://192.168.1.20:7777",
	])
	_expect(int(run.exit_code) == 3, "An unusable endpoint is refused with exit 3")
	_expect(str(run.output).contains("invite_print_certificate_or_join_url_invalid"),
		"The refusal names the endpoint or certificate")
	_expect(FileAccess.get_file_as_bytes(world.path_join(INVITE)) == invite,
		"A refused reprint leaves the invitation alone")
	_expect(not str(run.output).contains("WORLD_SERVER_INVITE_PRINTED"),
		"A refused endpoint prints no code")


## Asking to print and rotate at once is ambiguous; neither is guessed.
func _test_conflicting_options(world: String) -> void:
	var invite: PackedByteArray = FileAccess.get_file_as_bytes(world.path_join(INVITE))
	var run: Dictionary = _run_once([
		"--data-dir=" + world, "--print-invite", "--rotate-invite",
		"--world=" + WORLD, "--join-url=" + _join_url(),
	])
	_expect(int(run.exit_code) == 3, "Printing and rotating at once exits 3")
	_expect(str(run.output).contains("invite_print_conflicting_options"),
		"The refusal names the conflicting options")
	_expect(not FileAccess.file_exists(world.path_join("invite.pending.bin")),
		"A conflicting request leaves no pending invitation")
	_expect(FileAccess.get_file_as_bytes(world.path_join(INVITE)) == invite,
		"A conflicting request does not rotate the invitation")


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


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
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
	print("SERVER_INVITE_PRINT_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
