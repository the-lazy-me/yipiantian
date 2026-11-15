extends SceneTree
## M11-02 cadastre authority wiring: the pure land rules are loaded, persisted
## and executed through the authoritative world.
##
## Covers: the sidecar store round trip, connection identity (the actor is the
## joined player, never a client-supplied owner), member claim/transfer/release,
## visitor read-only and anonymous read, stable refusal reasons, a claim that
## survives an authority restart and replays with the same claim id, and the
## non-overlap invariant after reopening. Also proves a corrupt or relabelled
## document stops the authority instead of being overwritten.

const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const TerritoryState = preload("res://world/territory_state.gd")
const TerritoryStore = preload("res://world/territory_store.gd")

const START: float = 1800000000.0
const WORLD: String = "world-territory"
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const PEER_A: int = 11
const PEER_B: int = 12
const PEER_C: int = 13
const PEER_VISITOR: int = 14
const PEER_ANONYMOUS: int = 15

var checks: int = 0
var failures: Array[String] = []
var root_dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = _repo().path_join(
		".local/verification/territory-authority-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)
	_test_store_roundtrip_and_default()
	_test_identity_and_stable_reasons()
	_test_restart_replay_and_non_overlap()
	_test_visitor_and_read_only()
	_test_corrupt_and_relabelled_documents()
	for failure: String in failures:
		push_error(failure)
	print("TERRITORY_AUTHORITY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_store_roundtrip_and_default() -> void:
	var store := TerritoryStore.new(root_dir.path_join("store"))
	var state: Dictionary = TerritoryState.default_state(WORLD)
	_expect(TerritoryState.valid(state), "The default cadastre is a valid document")
	_expect(state.parcels.size() == 6, "The default cadastre exposes six claimable parcels")
	_expect(_non_overlapping(state.parcels), "The default parcels do not overlap")

	var missing: Dictionary = store.load_state(WORLD)
	_expect(missing.ok and missing.kind == "missing",
		"A world without a cadastre gets the deterministic default")
	_expect(TerritoryState.valid(missing.state), "The missing-document default is valid")
	var saved: Dictionary = store.save_state(state)
	_expect(saved.ok and saved.kind == "saved", "A valid cadastre is written atomically")
	var loaded: Dictionary = store.load_state(WORLD)
	_expect(loaded.ok and loaded.kind == "loaded", "The written cadastre reloads")
	_expect(loaded.state == state, "A stored cadastre round trips to the same document")
	_expect(not store.save_state({"world_id": WORLD}).ok,
		"An invalid candidate is refused before it reaches the file")
	_expect(TerritoryState.recorded_time(state, "missing-command") == -1.0,
		"An unknown command has no recorded land time")


func _test_identity_and_stable_reasons() -> void:
	var host: WorldHost = _open_host(root_dir.path_join("world"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_join(host, PEER_C, PLAYER_C, WorldInvite.MEMBER)
	_join(host, PEER_VISITOR, PLAYER_C, WorldInvite.VISITOR)
	_join(host, PEER_ANONYMOUS, "", WorldInvite.MEMBER)
	_expect(TerritoryState.valid(host.world.territory),
		"The authority loads a valid cadastre from the fresh default")

	var read: Dictionary = host.territory_for_member(PEER_VISITOR, "state", {})
	var read_state: Dictionary = {}
	if read.get("state") is Dictionary:
		read_state = read.state
	_expect(read.ok and read_state.parcels.size() == 6,
		"A visitor can read every parcel")
	_expect(host.territory_for_member(99, "state", {}).reason == "not_a_member",
		"A connection outside the roster is refused")
	_expect(host.territory_for_member(PEER_A, "sell", {}).reason == "unknown_action",
		"An unknown land action is refused")

	_expect(host.territory_for_member(PEER_VISITOR, "claim",
		{"parcel_id": "parcel_01", "command_id": "visitor-claim"}).reason == "forbidden",
		"A visitor cannot claim land")
	_expect(host.territory_for_member(PEER_ANONYMOUS, "claim",
		{"parcel_id": "parcel_01", "command_id": "anonymous-claim"}).reason == "no_player",
		"A member without a player id cannot claim land")

	# The actor comes from the connection, not from the request payload.
	var claim: Dictionary = host.territory_for_member(PEER_A, "claim",
		{"parcel_id": "parcel_01", "command_id": "claim-a-1", "owner": PLAYER_C})
	_expect(claim.ok and claim.owner == PLAYER_A,
		"A member claims a parcel as their own joined player")
	_expect(str(host.world.territory.parcels.parcel_01.claim_id) == "claim-a-1",
		"The parcel records the command id")
	_expect(float(host.world.territory.parcels.parcel_01.claimed_utc) == START,
		"The authority stamps the land with its own clock")
	_expect(TerritoryState.recorded_time(host.world.territory, "claim-a-1") == START,
		"The accepted command records its land time")
	_expect(int(host.world.territory.sequence) == 1,
		"An accepted claim advances the cadastre sequence")
	_expect(_stored(host).get("kind", "") == "loaded",
		"The accepted claim is written to the sidecar immediately")

	var replay: Dictionary = host.territory_for_member(PEER_A, "claim",
		{"parcel_id": "parcel_01", "command_id": "claim-a-1"})
	_expect(replay.ok and replay.duplicate, "Retrying the claim replays its first result")
	_expect(int(host.world.territory.sequence) == 1,
		"A replay writes no new cadastre command")

	_expect(host.territory_for_member(PEER_B, "claim",
		{"parcel_id": "parcel_01", "command_id": "claim-a-1"}).reason == "command_conflict",
		"Reusing another player's claim id is a conflict")
	_expect(host.territory_for_member(PEER_B, "claim",
		{"parcel_id": "parcel_01", "command_id": "claim-b-x"}).reason == "already_claimed",
		"A claimed parcel cannot be claimed again")
	_expect(host.territory_for_member(PEER_A, "claim",
		{"parcel_id": "missing", "command_id": "claim-missing"}).reason == "unknown_parcel",
		"An unknown parcel is refused")
	_expect(host.territory_for_member(PEER_A, "claim",
		{"parcel_id": "parcel_02", "command_id": ""}).reason == "invalid_command",
		"An empty command id is refused")

	var claim_b: Dictionary = host.territory_for_member(PEER_B, "claim",
		{"parcel_id": "parcel_02", "command_id": "claim-b-1"})
	_expect(claim_b.ok and claim_b.owner == PLAYER_B, "A second member claims another parcel")

	var transfer: Dictionary = host.territory_for_member(PEER_A, "transfer",
		{"parcel_id": "parcel_01", "player_id": PLAYER_B, "command_id": "transfer-a-b"})
	_expect(transfer.ok and transfer.owner == PLAYER_B,
		"The owner transfers a parcel to another player")
	_expect(str(host.world.territory.parcels.parcel_01.claim_id) == "transfer-a-b",
		"The transfer replaces the parcel's claim id")
	_expect(host.territory_for_member(PEER_A, "transfer",
		{"parcel_id": "parcel_01", "player_id": PLAYER_C,
			"command_id": "transfer-a-c"}).reason == "not_owner",
		"The former owner cannot transfer the parcel again")
	_expect(host.territory_for_member(PEER_B, "transfer",
		{"parcel_id": "parcel_01", "player_id": PLAYER_B,
			"command_id": "transfer-self"}).reason == "same_owner",
		"Transferring to the current owner is refused")
	_expect(host.territory_for_member(PEER_B, "transfer",
		{"parcel_id": "parcel_01", "player_id": "bad id",
			"command_id": "transfer-bad"}).reason == "invalid_owner",
		"An illegal receiver is refused")
	_expect(host.territory_for_member(PEER_A, "release",
		{"parcel_id": "parcel_02", "command_id": "release-a-2"}).reason == "not_owner",
		"A non-owner cannot release a parcel")

	var release: Dictionary = host.territory_for_member(PEER_B, "release",
		{"parcel_id": "parcel_01", "command_id": "release-b-1"})
	_expect(release.ok and release.owner.is_empty()
		and release.status == TerritoryState.STATUS_UNCLAIMED,
		"The owner releases the parcel back to unclaimed")
	_expect(str(host.world.territory.parcels.parcel_01.claim_id).is_empty(),
		"Release clears the parcel's claim id")
	_expect(host.territory_for_member(PEER_B, "release",
		{"parcel_id": "parcel_01", "command_id": "release-b-2"}).reason == "not_owned",
		"An unclaimed parcel cannot be released again")
	_expect(host.territory_for_member(PEER_B, "transfer",
		{"parcel_id": "parcel_01", "player_id": PLAYER_A,
			"command_id": "transfer-unclaimed"}).reason == "not_owned",
		"An unclaimed parcel cannot be transferred")
	var release_replay: Dictionary = host.territory_for_member(PEER_B, "release",
		{"parcel_id": "parcel_01", "command_id": "release-b-1"})
	_expect(release_replay.ok and release_replay.duplicate,
		"A release replays inside the bounded command window")


func _test_restart_replay_and_non_overlap() -> void:
	# Reopen with a later authority clock. The parcel invariants and the command
	# records must come from disk, not memory.
	var host: WorldHost = _open_host(root_dir.path_join("world"), START + 100.0)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_join(host, PEER_C, PLAYER_C, WorldInvite.MEMBER)
	_expect(TerritoryState.valid(host.world.territory),
		"The reopened cadastre is valid")
	_expect(str(host.world.territory.parcels.parcel_02.owner) == PLAYER_B
		and str(host.world.territory.parcels.parcel_02.claim_id) == "claim-b-1",
		"The claimed parcel and its claim id survive the restart")
	_expect(str(host.world.territory.parcels.parcel_01.status) == TerritoryState.STATUS_UNCLAIMED,
		"The released parcel stays unclaimed after the restart")
	_expect(_non_overlapping(host.world.territory.parcels),
		"Parcels still do not overlap after the restart")

	var claim_replay: Dictionary = host.territory_for_member(PEER_B, "claim",
		{"parcel_id": "parcel_02", "command_id": "claim-b-1"})
	_expect(claim_replay.ok and claim_replay.duplicate,
		"The same claim id replays after a restart despite the newer clock")
	_expect(float(host.world.territory.parcels.parcel_02.claimed_utc) == START,
		"The replay reuses the originally recorded land time")
	var release_replay: Dictionary = host.territory_for_member(PEER_B, "release",
		{"parcel_id": "parcel_01", "command_id": "release-b-1"})
	_expect(release_replay.ok and release_replay.duplicate,
		"A release recorded before the restart still replays")

	var claim: Dictionary = host.territory_for_member(PEER_A, "claim",
		{"parcel_id": "parcel_03", "command_id": "claim-a-3"})
	_expect(claim.ok and claim.owner == PLAYER_A, "A new claim uses the newer authority clock")
	_expect(float(host.world.territory.parcels.parcel_03.claimed_utc) == START + 100.0,
		"The new claim is stamped at the reopened authority time")
	var release: Dictionary = host.territory_for_member(PEER_A, "release",
		{"parcel_id": "parcel_03", "command_id": "release-a-3"})
	_expect(release.ok, "The new claim can be released")

	var reopened: WorldHost = _open_host(root_dir.path_join("world"), START + 500.0)
	_join(reopened, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(reopened, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_expect(TerritoryState.valid(reopened.world.territory),
		"A cadastre with claims, transfers and releases stays valid across restarts")
	_expect(_non_overlapping(reopened.world.territory.parcels),
		"The non-overlap invariant still holds after the second restart")
	_expect(str(reopened.world.territory.parcels.parcel_02.claim_id) == "claim-b-1",
		"The durable claim id is not regenerated on restart")
	var durable_replay: Dictionary = reopened.territory_for_member(PEER_B, "claim",
		{"parcel_id": "parcel_02", "command_id": "claim-b-1"})
	_expect(durable_replay.ok and durable_replay.duplicate,
		"The claim still replays after a second restart")
	var durable_release: Dictionary = reopened.territory_for_member(PEER_A, "release",
		{"parcel_id": "parcel_03", "command_id": "release-a-3"})
	_expect(durable_release.ok and durable_release.duplicate,
		"The release still replays after a second restart")
	_expect(int(reopened.world.territory.sequence) == 6,
		"Every accepted land command is counted once, across restarts")


func _test_visitor_and_read_only() -> void:
	var host: WorldHost = _open_host(root_dir.path_join("world"), START + 600.0)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_VISITOR, PLAYER_C, WorldInvite.VISITOR)
	_join(host, PEER_ANONYMOUS, "", WorldInvite.VISITOR)

	_expect(host.territory_for_member(PEER_ANONYMOUS, "state", {}).ok,
		"A visitor without a player id can still read the cadastre")
	_expect(host.territory_for_member(PEER_VISITOR, "transfer",
		{"parcel_id": "parcel_02", "player_id": PLAYER_A,
			"command_id": "visitor-transfer"}).reason == "forbidden",
		"A visitor cannot transfer land")

	host.read_only = true
	_expect(host.territory_for_member(PEER_A, "claim",
		{"parcel_id": "parcel_04", "command_id": "claim-read-only"}).reason == "read_only",
		"A retiring authority refuses land writes")
	_expect(host.territory_for_member(PEER_VISITOR, "state", {}).ok,
		"A retiring authority still answers reads")
	host.read_only = false


func _test_corrupt_and_relabelled_documents() -> void:
	var corrupt_dir: String = root_dir.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	var corrupt_path: String = corrupt_dir.path_join(TerritoryStore.MAIN)
	_write(corrupt_path, JSON.stringify({"version": TerritoryStore.VERSION,
		"state": {"world_id": WORLD}}))
	var before: String = FileAccess.get_file_as_string(corrupt_path)
	var corrupt_host := WorldHost.new()
	root.add_child(corrupt_host)
	var opened: Dictionary = corrupt_host.configure(corrupt_dir, START, WORLD)
	_expect(not opened.ok and str(opened.reason) == "load_territory_corrupt",
		"A corrupt cadastre stops the authority")
	_expect(FileAccess.get_file_as_string(corrupt_path) == before,
		"A corrupt cadastre is not overwritten by a fresh layout")

	var old_dir: String = root_dir.path_join("unsupported")
	DirAccess.make_dir_recursive_absolute(old_dir)
	_write(old_dir.path_join(TerritoryStore.MAIN),
		JSON.stringify({"version": TerritoryStore.VERSION + 1, "state": {}}))
	var old_host := WorldHost.new()
	root.add_child(old_host)
	_expect(str(old_host.configure(old_dir, START, WORLD).get("reason", ""))
		== "load_territory_unsupported", "An unsupported cadastre version is refused")

	var foreign_dir: String = root_dir.path_join("foreign")
	DirAccess.make_dir_recursive_absolute(foreign_dir)
	_write(foreign_dir.path_join(TerritoryStore.MAIN),
		JSON.stringify({"version": TerritoryStore.VERSION,
			"state": TerritoryState.default_state("another-world")}))
	var foreign_host := WorldHost.new()
	root.add_child(foreign_host)
	_expect(str(foreign_host.configure(foreign_dir, START, WORLD).get("reason", ""))
		== "territory_world_mismatch",
		"A cadastre for another world is refused instead of relabelled")
	var adopting := HeadlessWorld.new()
	var adopted: Dictionary = adopting.open(foreign_dir, START + 1.0)
	_expect(adopted.ok and adopting.world_id == "another-world",
		"A direct headless reopen adopts the stored world id when none is named")


func _open_host(save_directory: String, now: float) -> WorldHost:
	var host := WorldHost.new()
	root.add_child(host)
	var opened: Dictionary = host.configure(save_directory, now, WORLD)
	_expect(bool(opened.get("ok", false)),
		"The authority opens %s" % save_directory.get_file())
	return host


func _join(host: WorldHost, peer: int, player_id: String, role: String) -> void:
	# join() is the production path; this test sets the same fields directly so
	# the authority surface is exercised without a transport.
	host._members[peer] = role
	if not player_id.is_empty():
		host._players[peer] = {"id": player_id, "name": player_id}


func _stored(host: WorldHost) -> Dictionary:
	return TerritoryStore.new(host.world.directory).load_state(WORLD)


func _non_overlapping(parcels: Dictionary) -> bool:
	var ids: Array = parcels.keys()
	for left: int in ids.size():
		var left_parcel: Dictionary = parcels[ids[left]]
		var a: Dictionary = left_parcel.rect
		for right: int in range(left + 1, ids.size()):
			var right_parcel: Dictionary = parcels[ids[right]]
			var b: Dictionary = right_parcel.rect
			if int(a.min_x) <= int(b.max_x) and int(b.min_x) <= int(a.max_x) \
					and int(a.min_z) <= int(b.max_z) and int(b.min_z) <= int(a.max_z):
				return false
	return true


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + message)
	print(("PASS " if condition else "FAIL ") + message)
