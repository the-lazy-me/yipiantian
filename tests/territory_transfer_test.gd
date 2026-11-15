extends SceneTree
## M11-01 cadastre transfer and passage slice.
##
## Rule layer: a claimed parcel moves only between two members the caller names
## as the world's opened players; unclaimed land, a non-owner, a self transfer
## and a non-member are refused, and a repeated command id replays its first
## result. Passage answers the four documented cases (own, unclaimed, public,
## another player's private parcel) and treats a parcel bound to a built public
## work as passable without rewriting the cadastre.
##
## Authority layer: the real WorldHost resolves the actor from the connection,
## derives the member roster from durable granted accounts, persists the
## transfer to territory.json, keeps it across a restart, and lets the new owner
## build while the former owner is refused. The bounded command log and the
## public summary are checked too.

const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const TerritoryState = preload("res://world/territory_state.gd")
const TerritoryStore = preload("res://world/territory_store.gd")
const PublicWorks = preload("res://world/public_works.gd")
const PublicWorksStore = preload("res://world/public_works_store.gd")

const START: float = 1800000000.0
const WORLD: String = "world-territory-transfer"
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const PEER_A: int = 21
const PEER_B: int = 22
const PEER_C: int = 23
const PEER_VISITOR: int = 24
const PEER_ANONYMOUS: int = 25

var checks: int = 0
var failures: Array[String] = []
var root_dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = _repo().path_join(
		".local/verification/territory-transfer-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)
	_test_rule_transfer()
	_test_rule_passage()
	_test_authority_transfer()
	_test_build_gate_follows_transfer()
	_test_restart_and_replay()
	_test_public_works_passage()
	_test_command_log_and_summary()
	for failure: String in failures:
		push_error(failure)
	print("TERRITORY_TRANSFER_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_rule_transfer() -> void:
	var state: Dictionary = TerritoryState.default_state(WORLD)
	TerritoryState.claim(state, WORLD, "parcel_01", PLAYER_A, "claim-a", START)
	var members: Array = [PLAYER_A, PLAYER_B]

	var unknown: Dictionary = TerritoryState.transfer(state, "parcel_09", PLAYER_A,
		PLAYER_B, "transfer-unknown", START + 1.0, members)
	_expect(not unknown.ok and unknown.reason == "unknown_parcel",
		"An unknown parcel is refused before any ownership check")
	var unclaimed: Dictionary = TerritoryState.transfer(state, "parcel_02", PLAYER_A,
		PLAYER_B, "transfer-unclaimed", START + 1.0, members)
	_expect(not unclaimed.ok and unclaimed.reason == "not_owned",
		"An unclaimed parcel cannot be transferred")
	var not_owner: Dictionary = TerritoryState.transfer(state, "parcel_01", PLAYER_B,
		PLAYER_A, "transfer-not-owner", START + 1.0, members)
	_expect(not not_owner.ok and not_owner.reason == "not_owner",
		"Only the current owner may transfer")
	var to_self: Dictionary = TerritoryState.transfer(state, "parcel_01", PLAYER_A,
		PLAYER_A, "transfer-self", START + 1.0, members)
	_expect(not to_self.ok and to_self.reason == "same_owner",
		"A transfer to the current owner is refused")
	var outsider: Dictionary = TerritoryState.transfer(state, "parcel_01", PLAYER_A,
		PLAYER_C, "transfer-outsider", START + 1.0, members)
	_expect(not outsider.ok and outsider.reason == "unknown_member",
		"A receiver outside the opened-member list is refused")
	_expect(str(state.parcels.parcel_01.owner) == PLAYER_A,
		"No refused transfer changes the owner")

	var moved: Dictionary = TerritoryState.transfer(state, "parcel_01", PLAYER_A,
		PLAYER_B, "transfer-ok", START + 2.0, members)
	_expect(moved.ok and not moved.duplicate and moved.owner == PLAYER_B,
		"The owner transfers the parcel to another opened member")
	_expect(str(state.parcels.parcel_01.claim_id) == "transfer-ok"
		and float(state.parcels.parcel_01.claimed_utc) == START + 2.0,
		"The transfer records the new command id and land time")
	_expect(TerritoryState.valid(state), "The transferred document stays valid")
	var accepted: Dictionary = state.duplicate(true)
	var replay: Dictionary = TerritoryState.transfer(state, "parcel_01", PLAYER_A,
		PLAYER_B, "transfer-ok", START + 2.0, members)
	_expect(replay.ok and replay.duplicate and replay.owner == PLAYER_B,
		"A repeated command id replays the first transfer result")
	_expect(state == accepted, "A replayed transfer changes nothing")
	var conflict: Dictionary = TerritoryState.transfer(state, "parcel_01", PLAYER_A,
		PLAYER_B, "transfer-ok", START + 3.0, members)
	_expect(not conflict.ok and conflict.reason == "command_conflict",
		"Reusing the command id with another land time conflicts")

	# Without a roster the rule keeps the first-slice behaviour: two legal
	# player ids are enough. This is what other callers rely on.
	var loose: Dictionary = TerritoryState.default_state(WORLD)
	TerritoryState.claim(loose, WORLD, "parcel_01", PLAYER_A, "loose-claim", START)
	_expect(TerritoryState.transfer(loose, "parcel_01", PLAYER_A, PLAYER_C,
		"loose-transfer", START + 1.0).ok,
		"An omitted member roster keeps the rule usable without accounts")


func _test_rule_passage() -> void:
	var state: Dictionary = TerritoryState.default_state(WORLD)
	TerritoryState.claim(state, WORLD, "parcel_01", PLAYER_A, "passage-claim", START)
	state.parcels.parcel_03.owner = TerritoryState.PUBLIC_OWNER
	state.parcels.parcel_03.status = TerritoryState.STATUS_PUBLIC
	state.parcels.parcel_03.claimed_utc = 0.0
	state.parcels.parcel_03.claim_id = ""
	_expect(TerritoryState.valid(state), "A public parcel document is valid")

	_expect(TerritoryState.can_pass(state, "parcel_01", PLAYER_A),
		"The owner may cross their own parcel")
	_expect(not TerritoryState.can_pass(state, "parcel_01", PLAYER_B),
		"Another player may not cross a private parcel")
	_expect(TerritoryState.can_pass(state, "parcel_02", PLAYER_B),
		"Unclaimed ground is passable")
	_expect(TerritoryState.can_pass(state, "parcel_03", PLAYER_B),
		"Public ground is passable")
	_expect(TerritoryState.can_pass(state, "parcel_01", PLAYER_B, ["parcel_01"]),
		"A parcel bound to a built public work is passable")
	_expect(not TerritoryState.can_pass(state, "parcel_01", PLAYER_B, ["parcel_02"]),
		"A passable list for another parcel grants nothing")
	_expect(not TerritoryState.may_trespass(state, "parcel_01", PLAYER_B),
		"The ADR-023 alias keeps the no-external-list answer")
	_expect(not TerritoryState.can_pass(state, "parcel_09", PLAYER_A)
		and not TerritoryState.can_pass(state, "parcel_02", "bad id")
		and not TerritoryState.can_pass(state, "parcel_02", null),
		"An unknown parcel and an illegal actor are refused")


func _test_authority_transfer() -> void:
	var directory: String = root_dir.path_join("authority")
	var host: WorldHost = _open_host(directory, START)
	_seed_members(host, [PLAYER_A, PLAYER_B])
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_join(host, PEER_C, PLAYER_C, WorldInvite.MEMBER)
	_join(host, PEER_VISITOR, PLAYER_C, WorldInvite.VISITOR)
	_expect(host.world.territory_members() == [PLAYER_A, PLAYER_B],
		"The member roster is derived from durable granted accounts only")

	var claim: Dictionary = host.territory_for_member(PEER_A, "claim",
		{"parcel_id": "parcel_01", "command_id": "claim-a-1"})
	_expect(claim.ok and claim.owner == PLAYER_A, "A claims the parcel first")

	var refused_unclaimed: Dictionary = host.territory_for_member(PEER_A, "transfer",
		{"parcel_id": "parcel_02", "player_id": PLAYER_B, "command_id": "transfer-free"})
	_expect(not refused_unclaimed.ok and refused_unclaimed.reason == "not_owned",
		"An unclaimed parcel cannot be transferred")
	_expect(not str(refused_unclaimed.get("reason_text", "")).is_empty(),
		"A refusal carries readable text")
	var refused_self: Dictionary = host.territory_for_member(PEER_A, "transfer",
		{"parcel_id": "parcel_01", "player_id": PLAYER_A, "command_id": "transfer-self"})
	_expect(not refused_self.ok and refused_self.reason == "same_owner",
		"Transferring to the current owner is refused")
	var refused_outsider: Dictionary = host.territory_for_member(PEER_A, "transfer",
		{"parcel_id": "parcel_01", "player_id": PLAYER_C, "command_id": "transfer-c"})
	_expect(not refused_outsider.ok and refused_outsider.reason == "unknown_member",
		"A connected player without an opened account is refused")
	_expect(str(refused_outsider.get("reason_text", "")).find("成员") >= 0,
		"The unknown-member refusal explains itself")
	var refused_visitor: Dictionary = host.territory_for_member(PEER_VISITOR, "transfer",
		{"parcel_id": "parcel_01", "player_id": PLAYER_B, "command_id": "transfer-visitor"})
	_expect(not refused_visitor.ok and refused_visitor.reason == "forbidden",
		"A visitor cannot transfer land")

	var moved: Dictionary = host.territory_for_member(PEER_A, "transfer",
		{"parcel_id": "parcel_01", "player_id": PLAYER_B, "command_id": "transfer-a-b"})
	_expect(moved.ok and moved.owner == PLAYER_B and moved.action == "transfer",
		"The owner transfers the parcel to an opened member")
	_expect(str(host.world.territory.parcels.parcel_01.claim_id) == "transfer-a-b",
		"The authority records the transfer command id")
	_expect(_stored(directory).state.parcels.parcel_01.owner == PLAYER_B,
		"The transfer is written to territory.json immediately")
	_expect(int(_stored(directory).state.sequence) == 2,
		"Only accepted land commands advance the cadastre sequence")

	var replay: Dictionary = host.territory_for_member(PEER_A, "transfer",
		{"parcel_id": "parcel_01", "player_id": PLAYER_B, "command_id": "transfer-a-b"})
	_expect(replay.ok and replay.duplicate, "The transfer replays idempotently")
	_expect(int(host.world.territory.sequence) == 2,
		"A replay writes no new command")
	var former_owner: Dictionary = host.territory_for_member(PEER_A, "transfer",
		{"parcel_id": "parcel_01", "player_id": PLAYER_C, "command_id": "transfer-a-c"})
	_expect(not former_owner.ok and former_owner.reason == "not_owner",
		"The former owner can no longer transfer the parcel")

	# The build gate still reads only `owner`, so the new owner may build and the
	# former owner is refused on the same slot.
	var build_a: Dictionary = host.world.execute(
		FarmCommand.make_build("build-a-1", "yard_a", "cottage", START), PLAYER_A)
	_expect(not build_a.ok and str(build_a.reason) == "not_parcel_owner",
		"The former owner is refused after the transfer")
	var build_b: Dictionary = host.world.execute(
		FarmCommand.make_build("build-b-1", "yard_a", "cottage", START), PLAYER_B)
	_expect(build_b.ok and str(build_b.stage) == "committed",
		"The new owner may build on the transferred parcel")


func _test_build_gate_follows_transfer() -> void:
	# A fresh directory keeps the build result independent from the previous
	# method's farm: the gate must follow the receiver before any building exists.
	var directory: String = root_dir.path_join("gate")
	var host: WorldHost = _open_host(directory, START)
	_seed_members(host, [PLAYER_A, PLAYER_B])
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_expect(host.territory_for_member(PEER_A, "claim",
		{"parcel_id": "parcel_01", "command_id": "gate-claim"}).ok, "A claims the gate parcel")
	var denied_before: Dictionary = host.world.execute(
		FarmCommand.make_build("gate-build-b", "yard_a", "cottage", START), PLAYER_B)
	_expect(not denied_before.ok and str(denied_before.reason) == "not_parcel_owner",
		"B cannot build before the transfer")
	_expect(host.territory_for_member(PEER_A, "transfer",
		{"parcel_id": "parcel_01", "player_id": PLAYER_B, "command_id": "gate-transfer"}).ok,
		"A transfers the gate parcel to B")
	var allowed_b: Dictionary = host.world.execute(
		FarmCommand.make_build("gate-build-b", "yard_a", "cottage", START), PLAYER_B)
	_expect(allowed_b.ok, "The same build succeeds for B after the transfer")
	_expect(not bool(allowed_b.get("duplicate", true)), "The build is new work")
	_expect(not host.world.execute(
		FarmCommand.make_build("gate-build-a", "yard_a", "cottage", START), PLAYER_A).ok,
		"A is refused on the parcel they transferred away")


func _test_restart_and_replay() -> void:
	var directory: String = root_dir.path_join("authority")
	var reopened: WorldHost = _open_host(directory, START + 500.0)
	_join(reopened, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(reopened, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_expect(str(reopened.world.territory.parcels.parcel_01.owner) == PLAYER_B,
		"The transferred owner survives a restart")
	_expect(str(reopened.world.territory.parcels.parcel_01.claim_id) == "transfer-a-b",
		"The durable transfer command id survives a restart")
	var replay: Dictionary = reopened.territory_for_member(PEER_A, "transfer",
		{"parcel_id": "parcel_01", "player_id": PLAYER_B, "command_id": "transfer-a-b"})
	_expect(replay.ok and replay.duplicate,
		"The transfer replays after a restart despite the newer clock")
	_expect(float(reopened.world.territory.parcels.parcel_01.claimed_utc) == START,
		"The replay reuses the originally recorded land time")
	# The build in the previous method persisted the farm, so the accounts are
	# durable and the reverse transfer is judged against the same roster.
	_expect(reopened.world.territory_members() == [PLAYER_A, PLAYER_B],
		"The opened-member roster survives the restart")
	var back: Dictionary = reopened.territory_for_member(PEER_B, "transfer",
		{"parcel_id": "parcel_01", "player_id": PLAYER_A, "command_id": "transfer-b-a"})
	_expect(back.ok and back.owner == PLAYER_A,
		"The current owner transfers the parcel back after a restart")


func _test_public_works_passage() -> void:
	var directory: String = root_dir.path_join("public-passage")
	DirAccess.make_dir_recursive_absolute(directory)
	var project: Dictionary = {
		"projects": {
			"road_01": {
				"kind": PublicWorks.KIND_ROAD_SEGMENT,
				"parcel_id": "parcel_02",
				"funded": int(PublicWorks.CATALOG[PublicWorks.KIND_ROAD_SEGMENT]),
				"status": PublicWorks.STATUS_BUILT,
				"pledged": int(PublicWorks.CATALOG[PublicWorks.KIND_ROAD_SEGMENT]),
				"built_utc": START,
			},
		},
	}
	_expect(PublicWorks.valid(project), "The built project fixture is valid")
	_expect(PublicWorksStore.new(directory).save_state(project).ok,
		"The built project is written as a real sidecar")
	var host: WorldHost = _open_host(directory, START)
	_seed_members(host, [PLAYER_A, PLAYER_B])
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_expect(host.world.public_works_passable_parcels() == ["parcel_02"],
		"Only the built project's bound parcel becomes passable")
	_expect(host.territory_for_member(PEER_A, "claim",
		{"parcel_id": "parcel_02", "command_id": "pw-claim"}).ok, "A claims parcel_02")
	_expect(host.territory_for_member(PEER_A, "claim",
		{"parcel_id": "parcel_01", "command_id": "pw-claim-private"}).ok,
		"A also claims a private parcel without a public work")

	var self_pass: Dictionary = host.territory_for_member(PEER_A, "can_pass",
		{"parcel_id": "parcel_02"})
	_expect(self_pass.ok and self_pass.passable,
		"The owner may cross their own parcel")
	var other_pass: Dictionary = host.territory_for_member(PEER_B, "can_pass",
		{"parcel_id": "parcel_02"})
	_expect(other_pass.ok and other_pass.passable,
		"A built public work makes another player's parcel passable")
	_expect(not bool(host.territory_for_member(PEER_B, "can_pass",
		{"parcel_id": "parcel_01"}).get("passable", true)),
		"A private parcel without a public work stays closed")
	_expect(host.territory_for_member(PEER_B, "can_pass",
		{"parcel_id": "parcel_03"}).passable,
		"Unclaimed ground stays passable")
	# Passage does not extend to building.
	_expect(str(host.world.execute(
		FarmCommand.make_build("pw-build-b", "yard_b", "cottage", START), PLAYER_B)
		.get("reason", "")) == "not_parcel_owner",
		"Passage does not grant building rights")
	# The query is read-only, so a named visitor gets their own answer; a member
	# with no player id cannot be judged and is refused.
	_join(host, PEER_VISITOR, PLAYER_C, WorldInvite.VISITOR)
	_expect(host.territory_for_member(PEER_VISITOR, "can_pass",
		{"parcel_id": "parcel_03"}).passable,
		"A named visitor may ask about their own passage")
	_join(host, PEER_ANONYMOUS, "", WorldInvite.MEMBER)
	var anonymous: Dictionary = host.territory_for_member(PEER_ANONYMOUS, "can_pass",
		{"parcel_id": "parcel_02"})
	_expect(not anonymous.ok and anonymous.reason == "invalid_player",
		"A member without a player id cannot be judged")
	_expect(not str(anonymous.get("reason_text", "")).is_empty(),
		"The passage refusal carries readable text")
	var unknown: Dictionary = host.territory_for_member(PEER_B, "can_pass",
		{"parcel_id": "parcel_09"})
	_expect(not unknown.ok and unknown.reason == "unknown_parcel",
		"An unknown parcel cannot be queried")


func _test_command_log_and_summary() -> void:
	var directory: String = root_dir.path_join("bounded")
	var host: WorldHost = _open_host(directory, START)
	_seed_members(host, [PLAYER_A, PLAYER_B])
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	for index: int in 70:
		if index % 2 == 0:
			_expect(host.territory_for_member(PEER_A, "claim",
				{"parcel_id": "parcel_03", "command_id": "bounded-%d" % index}).ok,
				"Bounded fixture claim %d is accepted" % index)
		else:
			_expect(host.territory_for_member(PEER_A, "release",
				{"parcel_id": "parcel_03", "command_id": "bounded-%d" % index}).ok,
				"Bounded fixture release %d is accepted" % index)
	_expect(int(host.world.territory.sequence) == 70,
		"Every accepted land command is counted once")
	_expect(host.world.territory.command_results.size() == 64,
		"The command window stays bounded at 64 rows")

	_expect(host.territory_for_member(PEER_A, "claim",
		{"parcel_id": "parcel_04", "command_id": "summary-claim"}).ok,
		"A claims parcel_04 for the summary check")
	_expect(host.territory_for_member(PEER_A, "transfer",
		{"parcel_id": "parcel_04", "player_id": PLAYER_B, "command_id": "summary-transfer"}).ok,
		"A transfers parcel_04 to B")
	var display: Dictionary = host.world.territory_display()
	var row: Dictionary = {}
	for value: Variant in display.get("parcels", []):
		if str((value as Dictionary).get("id", "")) == "parcel_04":
			row = value
	_expect(str(row.get("owner", "")) == PLAYER_B and str(row.get("status", "")) == "claimed",
		"The public summary reports the new owner")
	_expect(not row.has("claim_id"),
		"The public summary never exposes the internal command id")


func _seed_members(host: WorldHost, players: Array) -> void:
	# Open through the real authority command so the grant is written to the farm
	# document before a restart, exactly as a joining member would produce it.
	for player: String in players:
		if host.world.farm.economy_granted(player):
			continue
		var opened: Dictionary = host.world.execute(
			FarmCommand.make_account_open("seed-account-" + player, START), player)
		_expect(bool(opened.get("ok", false)) or str(opened.get("reason", "")) == "already_granted",
			"%s has a durable opened account" % player)


func _open_host(save_directory: String, now: float) -> WorldHost:
	var host := WorldHost.new()
	root.add_child(host)
	var opened: Dictionary = host.configure(save_directory, now, WORLD)
	_expect(bool(opened.get("ok", false)),
		"The authority opens %s" % save_directory.get_file())
	return host


func _join(host: WorldHost, peer: int, player_id: String, role: String) -> void:
	# join() is the production path; setting the same fields directly keeps the
	# test on the authority surface without a transport.
	host._members[peer] = role
	if not player_id.is_empty():
		host._players[peer] = {"id": player_id, "name": player_id}


func _stored(directory: String) -> Dictionary:
	return TerritoryStore.new(directory).load_state(WORLD)


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + message)
	print(("PASS " if condition else "FAIL ") + message)
