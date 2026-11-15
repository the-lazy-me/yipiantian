extends SceneTree
## R20: one member must not be able to amplify authority work by repeating
## summary/catch-up requests or by flooding commands.
##
## This drives a real WorldHost node. The entrypoints read the remote sender, and
## there is no transport in this fixture, so peer 0 is the connected member; the
## per-peer checks below call the same admission gate with other ids. It proves:
##   - a request inside the burst reaches its normal path;
##   - an over-burst request is refused with the named reason `rate_limited` and
##     never executes;
##   - each request kind has its own bucket, and different peers are independent;
##   - disconnecting drops the bucket, so a reconnect starts with a full burst;
##   - a rate-limited summary is not a permanent lock: the bucket refills and the
##     next request is served.

const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const FarmCommand = preload("res://farm/farm_command.gd")

const START: float = 1800000000.0
const PEER: int = 70

var checks: int = 0
var failures: Array[String] = []
var dir: String = ""
var host: WorldHost


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir() \
		.path_join(".local/verification/world-rate-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	host = WorldHost.new()
	host.name = WorldHost.SESSION_NODE_NAME
	root.add_child(host)
	var opened: Dictionary = host.configure(dir.path_join("world"), START, "world-rate")
	_expect(bool(opened.get("ok", false)), "An authority opens a world")
	if not bool(opened.get("ok", false)):
		_finish()
		return
	# join() is the production path that fills _members; this fixture sets the
	# same field so the RPC entrypoints can be driven without a transport. The
	# sender id for local calls is 0.
	host._members[0] = WorldInvite.MEMBER
	_test_command_gate()
	_test_catch_up_gate()
	await _test_summary_gate()
	_test_peers_independent()
	_test_disconnect_resets()
	_finish()


## A command inside the burst still executes; once the command bucket is empty,
## submit() refuses before the rules run and counts the refusal.
func _test_command_gate() -> void:
	var before: int = _sequence()
	_submit_sow("rate-command-ok", "cell_01")
	_expect(_sequence() == before + 1, "A command inside the burst reaches the rules")
	_expect(host.rate_rejections == 0, "A normal command is not rate limited")

	var refusal: Dictionary = {}
	for _index: int in WorldHost.RATE_COMMAND_BURST * 2:
		refusal = host._admit(0, WorldHost.RATE_KIND_COMMAND, "rate-burst", false)
		if not refusal.is_empty():
			break
	_expect(not refusal.is_empty(), "A command over the burst is refused")
	_expect(str(refusal.get("error", "")) == "rate_limited"
		and str(refusal.get("reason", "")) == "rate_limited",
		"The command refusal names rate_limited")
	_expect(not str(refusal.get("reason_text", "")).is_empty(),
		"The command refusal carries display text")

	var sequence: int = _sequence()
	var counted: int = host.rate_rejections
	_submit_sow("rate-command-over", "cell_02")
	_expect(_sequence() == sequence, "A rate-limited command never reaches the rules")
	_expect(host.rate_rejections == counted + 1,
		"submit() counted its own rate refusal")


## catch_up has its own bucket: a summary refresh must not spend it and the
## other way round.
func _test_catch_up_gate() -> void:
	var before: int = host.rate_rejections
	for _index: int in WorldHost.RATE_CATCH_UP_BURST:
		host.catch_up(JSON.stringify({"since": 0}))
	_expect(host.rate_rejections == before, "A catch-up burst fits")
	host.catch_up(JSON.stringify({"since": 0}))
	_expect(host.rate_rejections == before + 1,
		"A catch-up over the burst is refused")


## Summary requests are the other whole-world amplification path. The bucket
## must refill rather than lock the member out for the rest of the session.
func _test_summary_gate() -> void:
	var before: int = host.rate_rejections
	for _index: int in WorldHost.RATE_SUMMARY_BURST:
		host.request_summary()
	_expect(host.rate_rejections == before, "A summary burst fits")
	host.request_summary()
	_expect(host.rate_rejections == before + 1,
		"A summary over the burst is refused")

	# Refill rate is 0.5/s. Headless SceneTree timers can run slightly ahead of
	# the wall clock, so wait past 2 s rather than exactly on the boundary.
	await create_timer(2.5).timeout
	var after: int = host.rate_rejections
	host.request_summary()
	_expect(host.rate_rejections == after,
		"A summary is served again after the bucket refills")


## Buckets are keyed by peer and kind. Exhausting one peer or one kind must not
## spend another peer's allowance.
func _test_peers_independent() -> void:
	var first: int = PEER + 1
	var second: int = PEER + 2
	var refusal: Dictionary = {}
	for _index: int in WorldHost.RATE_COMMAND_BURST * 2:
		refusal = host._admit(first, WorldHost.RATE_KIND_COMMAND, "first", false)
		if not refusal.is_empty():
			break
	_expect(not refusal.is_empty(), "One peer exhausts its own command bucket")
	_expect(host._admit(second, WorldHost.RATE_KIND_COMMAND, "second", false).is_empty(),
		"Another peer keeps its own command allowance")

	for _index: int in WorldHost.RATE_SUMMARY_BURST * 2:
		refusal = host._admit(first, WorldHost.RATE_KIND_SUMMARY, "summary", false)
		if not refusal.is_empty():
			break
	_expect(not refusal.is_empty(), "The first peer also exhausts its summary bucket")
	_expect(host._admit(second, WorldHost.RATE_KIND_SUMMARY, "summary", false).is_empty(),
		"The second peer keeps its own summary allowance")


## A reconnect is a new peer. The old bucket must not follow it, or a client that
## ever hit the limit would stay throttled across every later session.
func _test_disconnect_resets() -> void:
	var peer: int = PEER + 3
	host._members[peer] = WorldInvite.MEMBER
	var refusal: Dictionary = {}
	for _index: int in WorldHost.RATE_COMMAND_BURST * 2:
		refusal = host._admit(peer, WorldHost.RATE_KIND_COMMAND, "gone", false)
		if not refusal.is_empty():
			break
	_expect(not refusal.is_empty(), "A peer exhausts its command bucket")
	_expect(host._rate.has(peer), "The bucket is kept while the peer is connected")
	host._forget(peer)
	_expect(not host._rate.has(peer), "Disconnecting drops the peer's bucket")
	_expect(host._admit(peer, WorldHost.RATE_KIND_COMMAND, "back", false).is_empty(),
		"A reconnected peer starts with a full bucket")


func _submit_sow(request_id: String, cell_id: String) -> void:
	var command: Dictionary = FarmCommand.make_sow(
		request_id, "field_01", cell_id, "greens", START)
	host.submit(JSON.stringify({
		"request_id": request_id, "command": command,
		"based_on_sequence": _sequence(),
	}))


func _sequence() -> int:
	return host.world.farm.event_sequence() if host.world != null and host.world.farm != null else 0


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("WORLD_RATE_LIMIT_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
