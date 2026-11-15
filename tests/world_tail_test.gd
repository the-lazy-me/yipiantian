extends SceneTree
## M4-03: catching a reconnecting member up from the event tail.
##
## The host keeps a bounded tail of commits. A member that was away asks for the
## commits after the last sequence it applied; the host either returns exactly
## those, or says the tail aged out and a snapshot is required. A client must
## never apply an event it already has, and must never rewind on a stale sender.
##
## This drives the host's bookkeeping directly instead of over the wire: the
## transport gates (authentication, join, role) are covered by m4_auth_test,
## m4_join_test and m4_sync_test. What is new here is sequence bookkeeping.

const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const FarmCommand = preload("res://farm/farm_command.gd")

const START: float = 1800000000.0
const PEER: int = 7

var checks: int = 0
var failures: Array[String] = []
var dir: String = ""
var host: WorldHost


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = _repo().path_join(".local/verification/tail-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	host = WorldHost.new()
	root.add_child(host)
	var opened: Dictionary = host.configure(dir.path_join("world"), START, "world-tail")
	_expect(opened.ok, "An authority opens a world")
	if not opened.ok:
		_finish()
		return
	# Membership is decided by join(); this test sets the same field join() sets
	# so the tail can be exercised without a transport.
	host._members[PEER] = WorldInvite.MEMBER

	_expect(host.tail_since(0).ok, "An empty tail answers a catch-up request")
	_expect((host.tail_since(0).events as Array).is_empty(), "An empty tail has no events")
	_expect(host.tail_since(0).current == 0, "A fresh world has sequence zero")

	var first: Dictionary = host.execute_for_member(PEER,
		FarmCommand.make_sow("t1", "field_01", "cell_01", "greens", START))
	_expect(bool(first.get("ok", false)), "The authority commits a command")
	var after_first: Dictionary = host.tail_since(0)
	_expect(after_first.ok and (after_first.events as Array).size() == 1,
		"The tail holds the commit")
	if (after_first.events as Array).size() == 1:
		var event: Dictionary = after_first.events[0]
		_expect(int(event.sequence) == 1, "The tail entry carries its sequence")
		_expect(str((event.command as Dictionary).id) == "t1",
			"The tail entry carries the command so a member can apply it")
		_expect(str(event.stage) == "committed", "The tail entry carries the outcome")
	_expect((host.tail_since(1).events as Array).is_empty(),
		"A member already at the current sequence gets nothing to apply")
	_expect(host.tail_since(2).reason == "future_sequence",
		"A client claiming a future sequence is refused, not caught up")

	# A replay of a committed id is not a new event: it must not enter the tail,
	# or a reconnecting member would apply the same change twice.
	var replay: Dictionary = host.execute_for_member(PEER,
		FarmCommand.make_sow("t1", "field_01", "cell_01", "greens", START))
	_expect(bool(replay.get("duplicate", false)), "Replaying a committed id is reported as a duplicate")
	_expect((host.tail_since(1).events as Array).is_empty(),
		"A duplicate replay does not extend the tail")

	# Two more commits, then a member that saw sequence 1 asks for the rest.
	host.execute_for_member(PEER, FarmCommand.make_water("t2", "field_01", "cell_01", START + 1.0))
	host.execute_for_member(PEER,
		FarmCommand.make_sow("t3", "field_01", "cell_02", "greens", START + 2.0))
	var missed: Dictionary = host.tail_since(1)
	_expect(missed.ok, "A member inside the retained tail is caught up")
	_expect((missed.events as Array).size() == 2, "Only the events after the requested point are sent")
	if (missed.events as Array).size() == 2:
		_expect(int((missed.events[0] as Dictionary).sequence) == 2
			and int((missed.events[1] as Dictionary).sequence) == 3,
			"The catch-up is ordered oldest first")

	_test_member_dedupe()
	_test_tail_expiry()
	_finish()


## The member side applies a catch-up reply without double-counting.
func _test_member_dedupe() -> void:
	var member := WorldMember.new()
	member.last_sequence = 1
	var seen: Array[int] = []
	member.remote_change.connect(func(entry: Dictionary) -> void:
		seen.append(int(entry.get("sequence", 0))))
	member._apply_catch_up({"ok": true, "events": [
		{"sequence": 1, "command": {}, "stage": "committed"},
		{"sequence": 2, "command": {}, "stage": "committed"},
		{"sequence": 3, "command": {}, "stage": "committed"},
	]})
	_expect(seen == [2, 3], "A member applies only the events it did not have")
	_expect(member.last_sequence == 3, "The member advances to the newest applied event")
	# A duplicate delivery of the broadcast path must be ignored the same way.
	seen.clear()
	member._apply_broadcast({"sequence": 3, "command": {}})
	_expect(seen.is_empty(), "A re-delivered event is ignored")
	member._apply_broadcast({"sequence": 4, "command": {}})
	_expect(seen == [4], "A newer broadcast event is applied")
	member._apply_catch_up({"ok": false, "reason": "tail_expired"})
	_expect(member.last_sequence == 4, "A failed catch-up does not move the member's sequence")
	member.free()


## A tail that aged out must send the caller to a snapshot instead of a gap.
func _test_tail_expiry() -> void:
	var empty := WorldHost.new()
	root.add_child(empty)
	_expect(empty.configure(dir.path_join("expiry"), START, "world-tail").ok,
		"A second authority opens its own world")
	empty._members[PEER] = WorldInvite.MEMBER
	# Sow, water, harvest on one cell repeatedly: each cycle returns the cell to
	# empty, so any number of distinct commits can be produced. greens ripens in
	# 1800 s, so the harvest offset clears the full duration. The authority clock
	# is advanced by the authoritative sweep first: a command may not jump the
	# world clock forward on its own.
	var at: float = START
	for index: int in WorldHost.TAIL_LIMIT + 1:
		var harvest_at: float = at + 4000.0
		var commands: Array[Dictionary] = [
			FarmCommand.make_sow("e%d-sow" % index, "field_01", "cell_01", "greens", at),
			FarmCommand.make_water("e%d-water" % index, "field_01", "cell_01", at + 1.0),
		]
		for command: Dictionary in commands:
			var result: Dictionary = empty.execute_for_member(PEER, command)
			if not bool(result.get("ok", false)):
				_expect(false, "The tail-expiry fixture command %s commits (%s)"
					% [command.id, str(result.get("reason", ""))])
				return
		# The authoritative clock, not the command timestamp, moves time forward:
		# the harvest below is a normal command at the clock the world is now at.
		var advanced: Dictionary = empty.world.advance_to(harvest_at)
		if not bool(advanced.get("ok", false)):
			_expect(false, "The tail-expiry fixture cannot advance to %f" % harvest_at)
			return
		var harvest: Dictionary = empty.execute_for_member(PEER,
			FarmCommand.make("e%d-harvest" % index, "field_01", "cell_01", harvest_at))
		if not bool(harvest.get("ok", false)):
			_expect(false, "The tail-expiry fixture command e%d-harvest commits (%s)"
				% [index, str(harvest.get("reason", ""))])
			return
		at += 5000.0
	var current: int = int(empty.tail_since(0).current)
	_expect(current == (WorldHost.TAIL_LIMIT + 1) * 3,
		"Every distinct commit advances the sequence")
	_expect(empty.tail_since(0).reason == "tail_expired",
		"A member older than the retained tail is told to take a snapshot")
	# The retained window starts at exactly the oldest event still held. A
	# requester one event before it is still complete, because `since` names the
	# last event the client already applied.
	var window_start: int = current - WorldHost.TAIL_LIMIT + 1
	_expect(empty.tail_since(window_start - 1).ok,
		"A member one event before the retained window is still served")
	_expect(empty.tail_since(window_start - 2).reason == "tail_expired",
		"Two events before the retained window is refused")
	_expect((empty.tail_since(0).events as Array).is_empty(),
		"An expired tail never returns a partial gap as if it were complete")
	empty.queue_free()


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("WORLD_TAIL_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
