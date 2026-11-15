extends SceneTree
## M13-14 kitchen authority entry: a member's cooking actions travel as an
## authoritative command and land in the shared farm document.
##
## Covers: a member starting and collecting a dish through
## `WorldHost.execute_for_member` (the member's own pocket is debited and the
## dish appears in the kitchen document), an idempotent replay that neither
## charges a second basket nor mints a second dish, a stale revision refused as
## `stale_kitchen`, a visitor refused as `forbidden`, the `garden_rack` station
## refused as `station_unavailable` until the drying rack is unlocked and placed,
## malformed commands refused as `invalid_command` (unknown action, foreign
## request key, negative/fractional revision, and identity or decoration fields),
## and a restart that reloads the same dish and revision from farm.json.
##
## No UI, transport, projection or Windows path is exercised here.

const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const Decorations = preload("res://farm/decoration_state.gd")

const START: float = 1800000000.0
const WORLD: String = "world-kitchen-authority"
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_V: String = "player_00000000000000000000000000000002"
const PEER_A: int = 61
const PEER_V: int = 62

var checks: int = 0
var failures: Array[String] = []
var root_dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = _repo().path_join(
		".local/verification/kitchen-authority-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)
	_test_member_flow_and_replay()
	_test_restart_keeps_dish()
	_test_visitor_forbidden()
	_test_garden_rack()
	_test_invalid_commands()
	for failure: String in failures:
		push_error(failure)
	print("KITCHEN_AUTHORITY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


## A member with a bag of greens cooks one dish and collects it. The bag is the
## acting member's own pocket, not the shared world inventory.
func _test_member_flow_and_replay() -> void:
	var host: WorldHost = _open("member-flow")
	if host == null:
		return
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	var greens: int = _cookable_greens(host, "flow")
	_expect(greens == 2, "A member's harvest lands two greens in their own bag")
	var now: float = host.world.now_utc
	var revision: int = _kitchen_revision(host)
	_expect(revision == 0, "A fresh kitchen document starts at revision 0")

	var start: Dictionary = _kitchen("flow-start", "start",
		{"recipe": "leaf_stir", "crop": "greens", "station": "stove"}, revision, now)
	var started: Dictionary = host.execute_for_member(PEER_A, start)
	_expect(bool(started.get("ok", false)) and not bool(started.get("duplicate", true)),
		"A member starts a dish through the authority")
	_expect(_bag_greens(host) == 1, "Starting the dish spends one basket from the member's bag")
	var after_start: Dictionary = _kitchen_state(host)
	_expect(not (after_start.jobs.stove as Dictionary).is_empty(),
		"The job is written into the shared kitchen document")
	_expect(int(after_start.revision) == 1, "An accepted kitchen action advances the revision")

	# A replay of the committed id is a duplicate: no second basket, no job change.
	var replayed: Dictionary = host.execute_for_member(PEER_A, start)
	_expect(bool(replayed.get("duplicate", false)),
		"Replaying the committed kitchen id is reported as a duplicate")
	_expect(_bag_greens(host) == 1, "A replay does not charge a second basket")

	var at_collect: float = now + 20.0
	host.world.advance_to(at_collect)
	var collect: Dictionary = _kitchen("flow-collect", "collect",
		{"station": "stove"}, _kitchen_revision(host), at_collect)
	var collected: Dictionary = host.execute_for_member(PEER_A, collect)
	_expect(bool(collected.get("ok", false)), "The member collects the finished dish")
	var after_collect: Dictionary = _kitchen_state(host)
	_expect(int((after_collect.stock as Dictionary).leaf_stir) == 1,
		"The kitchen document holds one finished dish")
	_expect(int(((after_collect.records as Dictionary).leaf_stir as Dictionary).made) == 1,
		"The recipe record counts one dish made")
	_expect((after_collect.jobs.stove as Dictionary).is_empty(),
		"Collecting clears the station")
	var replay_collect: Dictionary = host.execute_for_member(PEER_A, collect)
	_expect(bool(replay_collect.get("duplicate", false)),
		"Replaying the collect id is a duplicate")
	_expect(int((_kitchen_state(host).stock as Dictionary).leaf_stir) == 1,
		"A collect replay does not mint a second dish")

	# The revision is durable state, not a hint: acting on an old one is refused.
	var stale: Dictionary = host.execute_for_member(PEER_A, _kitchen("flow-stale",
		"collect", {"station": "stove"}, revision, at_collect))
	_expect(not bool(stale.get("ok", false)) and str(stale.get("reason", "")) == "stale_kitchen",
		"A stale revision is refused as stale_kitchen")
	_expect(_bag_greens(host) == 1 and int((_kitchen_state(host).stock as Dictionary).leaf_stir) == 1,
		"A stale kitchen command changes nothing")

	# Sharing is the fourth action and switches the shared display off.
	var share: Dictionary = _kitchen("flow-share", "share",
		{"recipe": "leaf_stir", "neighbor": "willow"}, _kitchen_revision(host), at_collect)
	_expect(bool(host.execute_for_member(PEER_A, share).get("ok", false)),
		"The member shares the dish with a neighbour")
	var after_share: Dictionary = _kitchen_state(host)
	_expect(int((after_share.stock as Dictionary).leaf_stir) == 0,
		"Sharing removes the dish from the kitchen stock")
	_expect(int(((after_share.records as Dictionary).leaf_stir as Dictionary).shared) == 1,
		"The recipe record counts one dish shared")
	_expect(str(after_share.display) == "", "Sharing the displayed dish clears the display")
	_expect(bool(host.world.decorations.snapshot().drying_rack.unlocked),
		"The shared meal unlocks the drying rack in the authority's decorations")

	var saved: Dictionary = host.world.save()
	_expect(bool(saved.get("ok", false)), "The authority saves the world after cooking")


func _test_restart_keeps_dish() -> void:
	# The previous test saved its world under this directory; reopen it to prove
	# the kitchen document and its revision live in farm.json.
	var directory: String = _dir("member-flow")
	if not FileAccess.file_exists(directory.path_join("farm.json")):
		_expect(false, "The cooked world wrote farm.json")
		return
	var reopened := HeadlessWorld.new()
	var opened: Dictionary = reopened.open(directory, START + 9000.0, WORLD, "")
	_expect(bool(opened.get("ok", false)), "The authority reopens the cooked world")
	if not bool(opened.get("ok", false)):
		return
	var state: Dictionary = reopened.farm.snapshot().kitchen
	_expect(int((state.records as Dictionary).leaf_stir.made) == 1
		and int((state.records as Dictionary).leaf_stir.shared) == 1,
		"The reopened kitchen keeps the made and shared counts")
	_expect(int(state.revision) == 3,
		"The reopened kitchen keeps its revision")
	_expect(bool(reopened.decorations.snapshot().drying_rack.unlocked),
		"The unlocked drying rack survives the restart")
	_expect(FarmCommand.has_committed(reopened.farm, "flow-share"),
		"The committed kitchen id is still recognized after the restart")


func _test_visitor_forbidden() -> void:
	var host: WorldHost = _open("visitor")
	if host == null:
		return
	_join(host, PEER_V, PLAYER_V, WorldInvite.VISITOR)
	var command: Dictionary = _kitchen("visitor-start", "start",
		{"recipe": "leaf_stir", "crop": "greens", "station": "stove"}, 0, START)
	var refused: Dictionary = host.execute_for_member(PEER_V, command)
	_expect(not bool(refused.get("ok", false)) and str(refused.get("reason", "")) == "forbidden",
		"A visitor cannot cook in the shared kitchen")
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The visitor refusal carries a player-visible reason")
	_expect(int(_kitchen_state(host).revision) == 0,
		"A refused visitor action leaves the kitchen revision unchanged")


func _test_garden_rack() -> void:
	var host: WorldHost = _open("garden-rack")
	if host == null:
		return
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	# Cook and share once so the cooking rules earn the portable rack, but leave
	# it unplaced: the extra station must still be refused.
	_cookable_greens(host, "rack")
	var now: float = host.world.now_utc
	var start: Dictionary = _kitchen("rack-start", "start",
		{"recipe": "leaf_stir", "crop": "greens", "station": "stove"}, 0, now)
	_expect(bool(host.execute_for_member(PEER_A, start).get("ok", false)),
		"The rack fixture cooks one dish")
	host.world.advance_to(now + 20.0)
	var collect: Dictionary = _kitchen("rack-collect", "collect",
		{"station": "stove"}, _kitchen_revision(host), now + 20.0)
	_expect(bool(host.execute_for_member(PEER_A, collect).get("ok", false)),
		"The rack fixture collects the dish")
	var share: Dictionary = _kitchen("rack-share", "share",
		{"recipe": "leaf_stir", "neighbor": "willow"}, _kitchen_revision(host), now + 20.0)
	_expect(bool(host.execute_for_member(PEER_A, share).get("ok", false)),
		"The shared meal unlocks the drying rack")
	_expect(bool(host.world.decorations.snapshot().drying_rack.unlocked),
		"The authority's decoration document records the unlock")

	# A root dish on the extra rack. The radish is harvested into the same bag.
	var radish_at: float = now + 20.0
	_expect(bool(host.execute_for_member(PEER_A, FarmCommand.make_sow(
		"rack-sow", "field_01", "cell_02", "radish", radish_at)).get("ok", false)),
		"The rack fixture sows a radish")
	var ripe_at: float = radish_at + 5400.0 * 4.0
	host.world.advance_to(ripe_at)
	_expect(bool(host.execute_for_member(PEER_A, FarmCommand.make(
		"rack-harvest", "field_01", "cell_02", ripe_at)).get("ok", false)),
		"The rack fixture harvests the radish")

	var unplaced: Dictionary = host.execute_for_member(PEER_A, _kitchen("rack-unplaced",
		"start", {"recipe": "root_dry", "crop": "radish", "station": "garden_rack"},
		_kitchen_revision(host), ripe_at))
	_expect(not bool(unplaced.get("ok", false))
		and str(unplaced.get("reason", "")) == "station_unavailable",
		"The garden_rack station is refused while the drying rack is unplaced")
	_expect(int(_kitchen_state(host).revision) == 3,
		"A refused station does not advance the revision")

	# Placing the earned rack is the scene's construction flow; the rule reads
	# only the resulting document.
	var placed := Decorations.new()
	_expect(placed.restore_snapshot(host.world.decorations.snapshot()),
		"The fixture copies the authority's decoration document")
	_expect(bool(placed.place_at("drying_rack", Vector2(-3, 7), 0).ok),
		"The fixture places the drying rack")
	_expect(host.world.decorations.restore_snapshot(placed.snapshot()),
		"The authority adopts the placed rack")

	var cooking: Dictionary = host.execute_for_member(PEER_A, _kitchen("rack-placed",
		"start", {"recipe": "root_dry", "crop": "radish", "station": "garden_rack"},
		_kitchen_revision(host), ripe_at))
	_expect(bool(cooking.get("ok", false)),
		"The placed drying rack makes the garden_rack station available")
	_expect(not (_kitchen_state(host).jobs.garden_rack as Dictionary).is_empty(),
		"The extra station holds the drying job")


func _test_invalid_commands() -> void:
	var host: WorldHost = _open("invalid")
	if host == null:
		return
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	var revision: int = _kitchen_revision(host)
	var samples: Array[Dictionary] = [
		# An action the rule does not implement.
		_kitchen("bad-action", "boil", {"recipe": "leaf_stir"}, revision, START),
		# A request key the rule never reads.
		_kitchen("bad-key", "start", {"recipe": "leaf_stir", "crop": "greens",
			"station": "stove", "amount": "1"}, revision, START),
		# A negative revision.
		_kitchen("bad-revision", "collect", {"station": "stove"}, -1, START),
		# A fractional revision.
		_kitchen("fractional", "collect", {"station": "stove"}, 0, START),
	]
	(samples[3] as Dictionary)["revision"] = 0.5
	# Identity and world context must never travel in the payload.
	var identity: Array[String] = ["actor", "from", "from_id", "owner_id", "decorations"]
	for key: String in identity:
		var tampered: Dictionary = _kitchen("bad-" + key, "start",
			{"recipe": "leaf_stir", "crop": "greens", "station": "stove"}, revision, START)
		tampered[key] = "player_other"
		samples.append(tampered)
	for sample: Dictionary in samples:
		var refused: Dictionary = host.execute_for_member(PEER_A, sample)
		_expect(not bool(refused.get("ok", false))
			and str(refused.get("reason", "")) == "invalid_command",
			"Malformed kitchen command %s is refused as invalid_command"
				% str(sample.get("id", "")))
		_expect(not FarmCommand.valid(sample),
			"FarmCommand.valid rejects malformed kitchen command %s"
				% str(sample.get("id", "")))
	# The exact key set of a well-formed command is accepted.
	_expect(FarmCommand.valid(_kitchen("good", "start",
		{"recipe": "leaf_stir", "crop": "greens", "station": "stove"}, 0, START)),
		"A well-formed kitchen command passes validation")
	# A non-string operand is malformed even when the key is known.
	var numeric: Dictionary = _kitchen("numeric", "start",
		{"recipe": "leaf_stir", "crop": "greens", "station": "stove"}, 0, START)
	(numeric.request as Dictionary)["recipe"] = 3
	_expect(not FarmCommand.valid(numeric),
		"A non-string kitchen operand is refused")
	_expect(int(_kitchen_state(host).revision) == revision,
		"Malformed commands leave the kitchen document untouched")


# ---------------------------------------------------------------- helpers

## Sows, grows and harvests greens into the member's bag for one world. Returns
## the bag count so a caller can assert the fixture's own precondition.
func _cookable_greens(host: WorldHost, prefix: String) -> int:
	for cell: String in ["cell_01", "cell_02"]:
		var sow: Dictionary = host.execute_for_member(PEER_A, FarmCommand.make_sow(
			"%s-sow-%s" % [prefix, cell], "field_01", cell, "greens", START))
		if not bool(sow.get("ok", false)):
			return -1
	# Weather slows a crop; two full durations clears any factor the world applies.
	var harvest_at: float = START + 7200.0
	host.world.advance_to(harvest_at)
	for cell: String in ["cell_01", "cell_02"]:
		var harvest: Dictionary = host.execute_for_member(PEER_A, FarmCommand.make(
			"%s-harvest-%s" % [prefix, cell], "field_01", cell, harvest_at))
		if not bool(harvest.get("ok", false)):
			return -1
	return _bag_greens(host)


func _bag_greens(host: WorldHost) -> int:
	return int(host.world.farm.bag(PLAYER_A).get("greens", 0))


func _kitchen_state(host: WorldHost) -> Dictionary:
	return host.world.farm.snapshot().kitchen


func _kitchen_revision(host: WorldHost) -> int:
	return int(_kitchen_state(host).revision)


func _kitchen(id: String, action: String, request: Dictionary, revision: int,
		at_utc: float) -> Dictionary:
	return FarmCommand.make_kitchen(id, action, request, revision, at_utc)


func _open(name: String) -> WorldHost:
	var host := WorldHost.new()
	root.add_child(host)
	var opened: Dictionary = host.configure(_dir(name), START, WORLD)
	if not bool(opened.get("ok", false)):
		_expect(false, "The authority opens %s: %s" % [name, str(opened.get("reason", ""))])
		return null
	# No transport sits behind these emulated peers; a kitchen commit would ask
	# for a summary broadcast to peers that do not exist. The command path is
	# what this fixture exercises.
	var changed: Signal = host.world.shared_changed
	if changed.is_connected(host._broadcast_summary):
		changed.disconnect(host._broadcast_summary)
	return host


## Models the join side effects for one peer. Membership and the player id are
## the same fields `join()` writes; no identity document is needed by cooking.
func _join(host: WorldHost, peer: int, player_id: String, role: String) -> void:
	host._members[peer] = role
	host._players[peer] = {"id": player_id, "name": player_id}


func _dir(name: String) -> String:
	return root_dir.path_join(name)


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + message)
	print(("PASS " if condition else "FAIL ") + message)
