extends SceneTree
## M11-01 cadastre connectivity, authority half (G10 first half): the pure
## `TerritoryPaths.check_blocking()` rule is reachable as a read-only world
## action.
##
## Covers: no built village square means a named `no_entrance`; an entrance with
## no completed homestead is a valid, empty answer; completed buildings map to
## cadastre parcels by the ADR-028 ordinal convention; a unique corridor is
## reported while a bypass is not; visitors and anonymous members can ask;
## named refusals; every document stays byte-identical across calls and
## `territory.sequence` does not move; and a reopened world answers the same.
##
## Covers the read-only answer above plus the write gate: a claim or first build
## that would seal the entrance-to-homestead public path is refused by name
## (`blocks_public_path`) without writing, while worlds with no judged entrance
## (bootstrap) and builds that leave a route open still commit. Fixtures stay
## below `.local/verification`.

const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const PublicWorks = preload("res://world/public_works.gd")
const PublicWorksStore = preload("res://world/public_works_store.gd")
const TerritoryState = preload("res://world/territory_state.gd")

const START: float = 1800000000.0
const WORLD: String = "world-territory-blocking"
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PEER_A: int = 21
const PEER_VISITOR: int = 22
const PEER_ANONYMOUS: int = 23
const PEER_ABSENT: int = 24

var checks: int = 0
var failures: Array[String] = []
var root_dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = _repo().path_join(
		".local/verification/territory-blocking-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)
	_test_no_entrance(root_dir.path_join("no-entrance"))
	_test_entrance_without_homesteads(root_dir.path_join("entrance-only"))
	_test_paths(root_dir.path_join("paths"))
	_test_write_gate(root_dir.path_join("write-gate"))
	_test_named_refusals(root_dir.path_join("refusals"))
	_test_host_permissions(root_dir.path_join("host"))
	_test_read_only_and_restart(root_dir.path_join("restart"))
	for failure: String in failures:
		push_error(failure)
	print("TERRITORY_BLOCKING_AUTHORITY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_no_entrance(directory: String) -> void:
	var world := HeadlessWorld.new()
	_expect(bool(world.open(directory, START).get("ok", false)),
		"A world without projects opens")
	_expect(world.public_entrance_parcel().is_empty(),
		"A world without a built village square has no public entrance")
	_expect(world.built_homestead_parcels().is_empty(),
		"A world without buildings has no completed homestead")
	var answer: Dictionary = world.check_territory_blocking("parcel_01")
	_expect(not bool(answer.get("ok", false)) and str(answer.reason) == "no_entrance",
		"Without an entrance the authority refuses by name instead of guessing")
	_expect(str(answer.get("parcel_id", "")) == "parcel_01",
		"The refusal echoes the parcel that was asked about")
	var blocking: Dictionary = answer.get("blocking", {})
	_expect(blocking.get("ok") == false and str(blocking.get("reason", "")) == "no_entrance"
			and str(blocking.get("parcel", "")) == "parcel_01",
		"The refusal still carries the routing answer shape")


func _test_entrance_without_homesteads(directory: String) -> void:
	_seed_project(directory, "square_01", PublicWorks.KIND_VILLAGE_SQUARE,
		"parcel_01", PublicWorks.STATUS_BUILT)
	var world := HeadlessWorld.new()
	_expect(bool(world.open(directory, START).get("ok", false)),
		"A world with a built square opens")
	_expect(world.public_entrance_parcel() == "parcel_01",
		"A built village square bound to a parcel is the entrance")
	_expect(world.built_homestead_parcels().is_empty(),
		"No farm building means no homestead to protect")

	var answer: Dictionary = world.check_territory_blocking("parcel_02")
	_expect(bool(answer.get("ok", false)) and str(answer.reason).is_empty(),
		"With an entrance and no homestead the query is valid")
	var blocking: Dictionary = answer.get("blocking", {})
	_expect(str(blocking.get("entrance", "")) == "parcel_01",
		"The answer names the derived entrance")
	_expect(blocking.get("blocked") == [] and blocking.get("newly_blocked") == [],
		"With no homestead nothing can be blocked")
	_expect(bool(blocking.get("entrance_reachable", false)),
		"Blocking another parcel leaves the entrance reachable")

	var at_entrance: Dictionary = world.check_territory_blocking("parcel_01")
	_expect(bool(at_entrance.get("ok", false)),
		"Blocking the entrance itself is still a valid query")
	_expect(at_entrance.blocking.get("entrance_reachable") == false,
		"Blocking the entrance reports it unreachable")


func _test_paths(directory: String) -> void:
	_seed_project(directory, "square_01", PublicWorks.KIND_VILLAGE_SQUARE,
		"parcel_01", PublicWorks.STATUS_BUILT)
	var world := HeadlessWorld.new()
	_expect(bool(world.open(directory, START).get("ok", false)),
		"The routing world opens")
	_expect(bool(world.execute(FarmCommand.make_build(
		"build-yard-f", "yard_f", "cottage", START), PLAYER_A).get("ok", false)),
		"Building yard_f commits and claims parcel_06")
	_expect(world.built_homestead_parcels().is_empty(),
		"A construction site is not a homestead yet")
	_expect(bool(world.advance_to(START + 700.0).get("ok", false)),
		"Time advances past the first construction deadline")
	_expect(world.built_homestead_parcels() == ["parcel_06"],
		"A completed slot maps to its parcel by the ADR-028 ordinal convention")

	# Both the upper row (01→02→03) and the lower row (01→04→05) reach the
	# homestead door on parcel_06, so blocking one transit parcel strands nothing.
	var bypass: Dictionary = world.check_territory_blocking("parcel_05")
	_expect(bool(bypass.get("ok", false)), "The corridor parcel is a valid query")
	_expect(bypass.blocking.get("newly_blocked") == [],
		"With two routes open, blocking one corridor strands no homestead")
	_expect(bool(bypass.blocking.get("entrance_reachable", false)),
		"The entrance stays reachable around the blocked corridor")

	var build_b: Dictionary = world.execute(FarmCommand.make_build(
		"build-yard-b", "yard_b", "cottage", START + 700.0), PLAYER_A)
	_expect(bool(build_b.get("ok", false)), "A second homestead starts on yard_b")
	_expect(bool(world.advance_to(START + 1400.0).get("ok", false)),
		"Time advances past the second construction deadline")
	_expect(world.built_homestead_parcels() == ["parcel_02", "parcel_06"],
		"Two completed slots map to two homestead parcels")

	# A private parcel severs the upper row; the lower row becomes the only route.
	_expect(bool(world.claim_territory("parcel_03", PLAYER_B, "claim-03").get("ok", false)),
		"A member claims parcel_03 as private land")
	var unique: Dictionary = world.check_territory_blocking("parcel_05")
	_expect(bool(unique.get("ok", false)), "The unique corridor is a valid query")
	_expect(unique.blocking.get("newly_blocked") == ["parcel_06"],
		"Blocking the only remaining corridor strands the far homestead")
	_expect(unique.blocking.get("blocked") == ["parcel_06"],
		"The blocked list names the stranded homestead")

	var door: Dictionary = world.check_territory_blocking("parcel_02")
	_expect(bool(door.get("ok", false)), "A homestead parcel is a valid query")
	_expect(door.blocking.get("newly_blocked") == [],
		"Blocking a homestead still leaves its own door reachable")

	var private_parcel: Dictionary = world.check_territory_blocking("parcel_03")
	_expect(bool(private_parcel.get("ok", false)),
		"A private parcel remains a valid blocking query")
	_expect(private_parcel.blocking.get("newly_blocked") == [],
		"Blocking land the public path already avoids changes nothing")
	_expect(bool(private_parcel.blocking.get("entrance_reachable", false)),
		"Blocking an unrelated parcel leaves the entrance itself reachable")


func _test_named_refusals(directory: String) -> void:
	var unopened := HeadlessWorld.new()
	_expect(str(unopened.check_territory_blocking("parcel_01").reason) == "not_open",
		"A world that never opened refuses by name")

	var road_dir: String = directory.path_join("road")
	_seed_project(road_dir, "road_01", PublicWorks.KIND_ROAD_SEGMENT,
		"parcel_02", PublicWorks.STATUS_BUILT)
	var road_world := HeadlessWorld.new()
	_expect(bool(road_world.open(road_dir, START).get("ok", false)),
		"The road-only world opens")
	_expect(road_world.public_entrance_parcel().is_empty(),
		"A built road is not a public entrance")
	_expect(str(road_world.check_territory_blocking("parcel_02").reason) == "no_entrance",
		"A built road leaves the world without an entrance")

	var unbuilt_dir: String = directory.path_join("unbuilt")
	_seed_project(unbuilt_dir, "square_01", PublicWorks.KIND_VILLAGE_SQUARE,
		"parcel_01", PublicWorks.STATUS_FUNDED)
	var unbuilt_world := HeadlessWorld.new()
	_expect(bool(unbuilt_world.open(unbuilt_dir, START).get("ok", false)),
		"The funded-square world opens")
	_expect(unbuilt_world.public_entrance_parcel().is_empty(),
		"A funded but unbuilt square is not an entrance")

	var opened_dir: String = directory.path_join("opened")
	_seed_project(opened_dir, "square_01", PublicWorks.KIND_VILLAGE_SQUARE,
		"parcel_01", PublicWorks.STATUS_BUILT)
	var opened_world := HeadlessWorld.new()
	_expect(bool(opened_world.open(opened_dir, START).get("ok", false)),
		"The refusal world opens")
	var missing: Dictionary = opened_world.check_territory_blocking("parcel_99")
	_expect(not bool(missing.get("ok", false)) and str(missing.reason) == "unknown_parcel",
		"A parcel outside the cadastre is refused by name")
	_expect(str(missing.blocking.get("reason", "")) == "unknown_parcel"
			and str(missing.blocking.get("parcel", "")) == "parcel_99",
		"The routing failure is carried inside the answer")

	# A square bound to a parcel this cadastre does not contain is a configuration
	# error; reporting `unknown_entrance` keeps it visible instead of hiding it.
	var foreign_dir: String = directory.path_join("foreign-entrance")
	_seed_project(foreign_dir, "square_01", PublicWorks.KIND_VILLAGE_SQUARE,
		"parcel_99", PublicWorks.STATUS_BUILT)
	var foreign_world := HeadlessWorld.new()
	_expect(bool(foreign_world.open(foreign_dir, START).get("ok", false)),
		"The foreign-entrance world opens")
	_expect(foreign_world.public_entrance_parcel() == "parcel_99",
		"The entrance keeps the project's parcel even when the cadastre lacks it")
	_expect(str(foreign_world.check_territory_blocking("parcel_01").reason)
			== "unknown_entrance",
		"An entrance outside the cadastre is refused as unknown_entrance")
	_expect(foreign_world.public_entrance_parcel(true).is_empty(),
		"The write gate never uses an entrance the cadastre lacks")

	# 绑定到不存在地块的广场不能让写入门禁失效。只读视图仍报告配置错误，但
	# 门禁改用地籍里真实存在的入口，封路主张照常被拒绝。
	var gate_dir: String = directory.path_join("foreign-entrance-gate")
	_seed_projects(gate_dir, {
		"square_00": {"kind": PublicWorks.KIND_VILLAGE_SQUARE,
			"parcel_id": "parcel_00", "status": PublicWorks.STATUS_BUILT},
		"square_02": {"kind": PublicWorks.KIND_VILLAGE_SQUARE,
			"parcel_id": "parcel_02", "status": PublicWorks.STATUS_BUILT},
	})
	var gate_world := HeadlessWorld.new()
	_expect(bool(gate_world.open(gate_dir, START).get("ok", false)),
		"The mixed-entrance world opens")
	_expect(gate_world.public_entrance_parcel() == "parcel_00",
		"The raw routing view still names the misconfigured entrance")
	_expect(gate_world.public_entrance_parcel(true) == "parcel_02",
		"The gate uses the smallest entrance the cadastre contains")
	_expect(bool(gate_world.execute(FarmCommand.make_build(
		"fg-build-f", "yard_f", "cottage", START), PLAYER_A).get("ok", false)),
		"The gate world builds its homestead")
	_expect(bool(gate_world.advance_to(START + 700.0).get("ok", false)),
		"The gate world completes the homestead")
	_expect(bool(gate_world.claim_territory("parcel_03", PLAYER_B, "fg-claim-03")
		.get("ok", false)), "The upper row end is claimed while both rows connect")
	var gate_sealed: Dictionary = gate_world.claim_territory("parcel_05", PLAYER_B,
		"fg-claim-05")
	_expect(not bool(gate_sealed.get("ok", false))
			and str(gate_sealed.get("reason", "")) == "blocks_public_path",
		"A misconfigured entrance cannot disable the public-path gate")

	# Several built squares: the smallest parcel id is the single route origin.
	var many_dir: String = directory.path_join("many-squares")
	_seed_projects(many_dir, {
		"square_b": {"kind": PublicWorks.KIND_VILLAGE_SQUARE,
			"parcel_id": "parcel_04", "status": PublicWorks.STATUS_BUILT},
		"square_a": {"kind": PublicWorks.KIND_VILLAGE_SQUARE,
			"parcel_id": "parcel_02", "status": PublicWorks.STATUS_BUILT},
	})
	var many_world := HeadlessWorld.new()
	_expect(bool(many_world.open(many_dir, START).get("ok", false)),
		"The multi-square world opens")
	_expect(many_world.public_entrance_parcel() == "parcel_02",
		"Multiple built squares resolve to the smallest parcel id")

	# A built work bound outside the cadastre is dropped from the passable list
	# instead of failing the whole view with `unknown_passable`.
	var stray_dir: String = directory.path_join("stray-passable")
	_seed_projects(stray_dir, {
		"square_01": {"kind": PublicWorks.KIND_VILLAGE_SQUARE,
			"parcel_id": "parcel_01", "status": PublicWorks.STATUS_BUILT},
		"road_01": {"kind": PublicWorks.KIND_ROAD_SEGMENT,
			"parcel_id": "parcel_99", "status": PublicWorks.STATUS_BUILT},
	})
	var stray_world := HeadlessWorld.new()
	_expect(bool(stray_world.open(stray_dir, START).get("ok", false)),
		"The stray-passable world opens")
	_expect(stray_world.public_works_passable_parcels() == ["parcel_01", "parcel_99"],
		"The built works name their parcels, including the one outside the cadastre")
	var stray: Dictionary = stray_world.check_territory_blocking("parcel_02")
	_expect(bool(stray.get("ok", false)),
		"An out-of-cadastre passable parcel is filtered, not fatal")


func _test_host_permissions(directory: String) -> void:
	_seed_project(directory, "square_01", PublicWorks.KIND_VILLAGE_SQUARE,
		"parcel_01", PublicWorks.STATUS_BUILT)
	var setup := HeadlessWorld.new()
	_expect(bool(setup.open(directory, START, WORLD).get("ok", false)),
		"The host fixture world opens")
	_expect(bool(setup.execute(FarmCommand.make_build(
		"build-yard-f", "yard_f", "cottage", START), PLAYER_A).get("ok", false)),
		"The host fixture builds a homestead")
	# A private parcel severs the upper row, leaving the lower row as the only
	# route to the homestead door.
	_expect(bool(setup.claim_territory("parcel_03", PLAYER_B, "claim-03").get("ok", false)),
		"The host fixture closes the upper row")
	_expect(bool(setup.advance_to(START + 700.0).get("ok", false)),
		"The host fixture lets the homestead finish")

	var host := WorldHost.new()
	root.add_child(host)
	var opened: Dictionary = host.configure(directory, START + 700.0, WORLD)
	_expect(bool(opened.get("ok", false)), "The authority opens on the fixture")
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_VISITOR, PLAYER_B, WorldInvite.VISITOR)
	_join(host, PEER_ANONYMOUS, "", WorldInvite.VISITOR)

	var member: Dictionary = host.territory_for_member(PEER_A, "blocking",
		{"parcel_id": "parcel_05"})
	_expect(bool(member.get("ok", false)) and member.get("blocking") is Dictionary,
		"A member reads the connectivity answer")
	_expect(member.blocking.get("newly_blocked") == ["parcel_06"],
		"The host answer matches the direct authority answer")

	var visitor: Dictionary = host.territory_for_member(PEER_VISITOR, "blocking",
		{"parcel_id": "parcel_05"})
	_expect(bool(visitor.get("ok", false)) and visitor.blocking.get("newly_blocked") == ["parcel_06"],
		"A visitor reads the same connectivity answer")

	var anonymous: Dictionary = host.territory_for_member(PEER_ANONYMOUS, "blocking",
		{"parcel_id": "parcel_02"})
	_expect(bool(anonymous.get("ok", false))
			and anonymous.blocking.get("newly_blocked") == [],
		"An anonymous visitor can ask without a player identity")

	_expect(str(host.territory_for_member(PEER_ABSENT, "blocking",
		{"parcel_id": "parcel_05"}).reason) == "not_a_member",
		"A connection outside the roster is refused")

	var unknown: Dictionary = host.territory_for_member(PEER_VISITOR, "blocking",
		{"parcel_id": "parcel_99"})
	_expect(str(unknown.get("reason", "")) == "unknown_parcel"
			and str(unknown.get("reason_text", "")).length() > 0,
		"A named refusal reaches the connection with human text")

	var no_square: String = directory.path_join("no-square")
	var plain_host := WorldHost.new()
	root.add_child(plain_host)
	_expect(bool(plain_host.configure(no_square, START, WORLD).get("ok", false)),
		"A world without projects opens through the host")
	_join(plain_host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	var no_entrance: Dictionary = plain_host.territory_for_member(PEER_A, "blocking",
		{"parcel_id": "parcel_01"})
	_expect(str(no_entrance.get("reason", "")) == "no_entrance"
			and str(no_entrance.get("reason_text", "")).length() > 0,
		"The host surfaces the named no-entrance refusal")

	host.read_only = true
	_expect(bool(host.territory_for_member(PEER_A, "blocking",
		{"parcel_id": "parcel_05"}).get("ok", false)),
		"A retiring authority still answers the read-only query")
	host.read_only = false


func _test_read_only_and_restart(directory: String) -> void:
	_seed_project(directory, "square_01", PublicWorks.KIND_VILLAGE_SQUARE,
		"parcel_01", PublicWorks.STATUS_BUILT)
	var world := HeadlessWorld.new()
	_expect(bool(world.open(directory, START).get("ok", false)), "The restart world opens")
	_expect(bool(world.claim_territory("parcel_03", PLAYER_B, "claim-03").get("ok", false)),
		"The restart world has a private parcel")
	_expect(bool(world.execute(FarmCommand.make_build(
		"build-yard-f", "yard_f", "cottage", START), PLAYER_A).get("ok", false)),
		"The restart world builds a homestead")
	_expect(bool(world.advance_to(START + 700.0).get("ok", false)),
		"The restart homestead finishes")

	var sequence_before: int = int(world.territory.sequence)
	var farm_before: Dictionary = world.farm.snapshot()
	var files_before: Dictionary = _files(directory)
	var first: Dictionary = world.check_territory_blocking("parcel_05")
	# Ask everything the action exposes, twice, including failing paths.
	world.check_territory_blocking("parcel_01")
	world.check_territory_blocking("parcel_02")
	world.check_territory_blocking("parcel_99")
	world.public_entrance_parcel()
	world.built_homestead_parcels()
	var second: Dictionary = world.check_territory_blocking("parcel_05")
	_expect(second == first, "Repeated blocking questions return the same answer")
	_expect(int(world.territory.sequence) == sequence_before,
		"The read-only action never advances the cadastre sequence")
	_expect(world.farm.snapshot() == farm_before,
		"The read-only action never changes the farm document")
	_expect(_files(directory) == files_before,
		"Every stored document keeps the same bytes across the calls")

	var reopened := HeadlessWorld.new()
	_expect(bool(reopened.open(directory, START + 700.0).get("ok", false)),
		"The world reopens for a second authority session")
	_expect(reopened.public_entrance_parcel() == "parcel_01",
		"The entrance derives the same parcel after reopening")
	_expect(reopened.built_homestead_parcels() == ["parcel_06"],
		"The homestead list derives the same parcel after reopening")
	var after: Dictionary = reopened.check_territory_blocking("parcel_05")
	_expect(after == first, "A reopened world returns the same blocking answer")
	_expect(_files(directory) == files_before,
		"Reopening and answering writes no document")


func _test_write_gate(directory: String) -> void:
	# 没有建成公共广场时没有可判定的公共通路，主张与首次建造都必须放行，
	# 否则新世界会先被门禁锁死、建不出第一个入口。
	var bootstrap := HeadlessWorld.new()
	_expect(bool(bootstrap.open(directory.path_join("bootstrap"), START).get("ok", false)),
		"The bootstrap world opens")
	_expect(bool(bootstrap.claim_territory("parcel_05", PLAYER_A, "wg-boot").get("ok", false)),
		"A claim without a public entrance is still allowed")
	_expect(bool(bootstrap.execute(FarmCommand.make_build(
		"wg-build-boot", "yard_a", "cottage", START), PLAYER_A).get("ok", false)),
		"A first build without a public entrance is still allowed")

	var world_dir: String = directory.path_join("gated")
	_seed_project(world_dir, "square_01", PublicWorks.KIND_VILLAGE_SQUARE,
		"parcel_01", PublicWorks.STATUS_BUILT)
	var world := HeadlessWorld.new()
	_expect(bool(world.open(world_dir, START).get("ok", false)), "The gated world opens")
	_expect(bool(world.execute(FarmCommand.make_build(
		"wg-build-f", "yard_f", "cottage", START), PLAYER_A).get("ok", false)),
		"Building the far homestead claims its parcel without sealing a path")
	_expect(bool(world.advance_to(START + 700.0).get("ok", false)),
		"The far homestead completes")
	_expect(world.built_homestead_parcels() == ["parcel_06"],
		"parcel_06 is the protected homestead")
	_expect(bool(world.claim_territory("parcel_03", PLAYER_B, "wg-claim-03")
		.get("ok", false)),
		"Claiming the upper-row end is allowed while both rows connect")

	# 03 私有化后，06 只剩 01→04→05 这一条公共通路。
	var sequence_before: int = int(world.territory.get("sequence", 0))
	var files_before: Dictionary = _files(world_dir)
	var sealed: Dictionary = world.claim_territory("parcel_05", PLAYER_B, "wg-claim-05")
	_expect(not bool(sealed.get("ok", false))
		and str(sealed.get("reason", "")) == "blocks_public_path",
		"A claim that would seal the only public path is refused by name")
	_expect(str(world.territory.parcels.parcel_05.status) == TerritoryState.STATUS_UNCLAIMED,
		"A refused claim leaves the parcel unclaimed")
	_expect(int(world.territory.get("sequence", 0)) == sequence_before,
		"A refused claim does not advance the cadastre sequence")
	_expect(_files(world_dir) == files_before,
		"A refused claim writes no document")

	var blocked_build: Dictionary = world.execute(FarmCommand.make_build(
		"wg-build-e", "yard_e", "cottage", START + 700.0), PLAYER_A)
	_expect(not bool(blocked_build.get("ok", false))
		and str(blocked_build.get("reason", "")) == "blocks_public_path",
		"A first build that would seal the only public path is refused by name")
	_expect(str(world.territory.parcels.parcel_05.status) == TerritoryState.STATUS_UNCLAIMED,
		"A refused build does not claim the parcel")
	_expect(not world.farm.buildings_at(START + 700.0).has("yard_e"),
		"A refused build leaves no construction site")
	_expect(_files(world_dir) == files_before,
		"A refused build writes no document")

	# 同一批里仍允许不封路的建造：02 只是新宅基，不影响 06 的下排通路。
	_expect(bool(world.execute(FarmCommand.make_build(
		"wg-build-b", "yard_b", "cottage", START + 700.0), PLAYER_A).get("ok", false)),
		"A build that does not seal the public path still commits")
	_expect(str(world.territory.parcels.parcel_02.status) == TerritoryState.STATUS_CLAIMED,
		"The allowed build claims its own parcel")
	var replay: Dictionary = world.claim_territory("parcel_03", PLAYER_B, "wg-claim-03")
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"A committed claim still replays after the topology changed")
	_expect(str(WorldHost._territory_reason_text("blocks_public_path")).contains("公共通路"),
		"The blocking refusal has a public-path reason text")
	_expect(str(WorldHost._reason_text("blocks_public_path")).contains("公共通路"),
		"The farm-command refusal has a public-path reason text")

	# 已建成公共道路让地块对所有人开放：主张只换归属，不改变通行，因此即使它是
	# 唯一物理走廊也允许。
	var road_dir: String = directory.path_join("road")
	_seed_projects(road_dir, {
		"square_01": {
			"kind": PublicWorks.KIND_VILLAGE_SQUARE, "parcel_id": "parcel_01",
			"status": PublicWorks.STATUS_BUILT,
		},
		"road_05": {
			"kind": PublicWorks.KIND_ROAD_SEGMENT, "parcel_id": "parcel_05",
			"status": PublicWorks.STATUS_BUILT,
		},
	})
	var road_world := HeadlessWorld.new()
	_expect(bool(road_world.open(road_dir, START).get("ok", false)),
		"The world with a built road opens")
	_expect(bool(road_world.execute(FarmCommand.make_build(
		"wg-road-f", "yard_f", "cottage", START), PLAYER_A).get("ok", false)),
		"The road world builds the far homestead")
	_expect(bool(road_world.advance_to(START + 700.0).get("ok", false)),
		"The road world completes the homestead")
	_expect(bool(road_world.claim_territory("parcel_03", PLAYER_B, "wg-road-03")
		.get("ok", false)), "The road world claims the upper-row end")
	_expect(bool(road_world.claim_territory("parcel_05", PLAYER_B, "wg-road-05")
		.get("ok", false)),
		"A built public road keeps its parcel passable after a claim")
	_expect(str(road_world.territory.parcels.parcel_05.owner) == PLAYER_B,
		"The road parcel is claimed without sealing the public path")

	var host := WorldHost.new()
	root.add_child(host)
	_expect(bool(host.configure(world_dir, START + 700.0, "").get("ok", false)),
		"The gated world opens through the host")
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	var refused: Dictionary = host.territory_for_member(PEER_A, "claim",
		{"parcel_id": "parcel_05", "command_id": "wg-host-claim"})
	_expect(not bool(refused.get("ok", false))
		and str(refused.get("reason", "")) == "blocks_public_path",
		"The host forwards the public-path refusal")
	_expect(str(refused.get("reason_text", ""))
		== "这块地会挡住通往宅基的唯一公共通路。",
		"The refusal reaches the connection with the exact Chinese text")


func _seed_project(directory: String, project_id: String, kind: String,
		parcel_id: String, status: String) -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	var cost: int = PublicWorks.cost_of(kind)
	var row: Dictionary = {
		"kind": kind,
		"parcel_id": parcel_id,
		"funded": cost if status != PublicWorks.STATUS_UNBUILT else 0,
		"status": status,
		"pledged": cost if status != PublicWorks.STATUS_UNBUILT else 0,
		"built_utc": START if status == PublicWorks.STATUS_BUILT else 0.0,
	}
	var document: Dictionary = {"projects": {project_id: row}}
	_expect(PublicWorks.valid(document), "The seeded project document is valid")
	_expect(bool(PublicWorksStore.new(directory).save_state(document).get("ok", false)),
		"The seeded project document is written as a real sidecar")


func _seed_projects(directory: String, rows: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	var projects: Dictionary = {}
	for project_id: Variant in rows:
		var source: Dictionary = rows[project_id]
		var kind: String = str(source.kind)
		var status: String = str(source.status)
		var cost: int = PublicWorks.cost_of(kind)
		projects[str(project_id)] = {
			"kind": kind,
			"parcel_id": str(source.parcel_id),
			"funded": cost if status != PublicWorks.STATUS_UNBUILT else 0,
			"status": status,
			"pledged": cost if status != PublicWorks.STATUS_UNBUILT else 0,
			"built_utc": START if status == PublicWorks.STATUS_BUILT else 0.0,
		}
	var document: Dictionary = {"projects": projects}
	_expect(PublicWorks.valid(document), "The seeded project table is valid")
	_expect(bool(PublicWorksStore.new(directory).save_state(document).get("ok", false)),
		"The seeded project table is written as a real sidecar")


## 目录内容的逐文件快照：文件名映射到文件字节。只读检查不得改变其中任何一项。
func _files(directory: String) -> Dictionary:
	var result: Dictionary = {}
	var names: Array = []
	var dir := DirAccess.open(directory)
	if dir == null:
		return result
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and not entry.begins_with("."):
			names.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	names.sort()
	for name_value: Variant in names:
		var path: String = directory.path_join(str(name_value))
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			result[str(name_value)] = "<unreadable>"
			continue
		var length: int = file.get_length()
		result[str(name_value)] = file.get_buffer(length)
		file.close()
	return result


func _join(host: WorldHost, peer: int, player_id: String, role: String) -> void:
	# join() is the production path; this test sets the same fields directly so
	# the authority surface is exercised without a transport.
	host._members[peer] = role
	if not player_id.is_empty():
		host._players[peer] = {"id": player_id, "name": player_id}


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + message)
	print(("PASS " if condition else "FAIL ") + message)
