extends SceneTree
## M8-04a public works authority wiring: the pure project rules are loaded,
## persisted and executed through the authoritative world.
##
## Covers: the project sidecar round trip and strict key set, missing/corrupt/
## unsupported documents, open/pledge/release rule refusals and write-time copy,
## in-memory idempotency and command conflicts, build gating (underfunded, keeper,
## organization role, fund balance), a successful build moving real cash from the
## organization account into `@world`, fixed-cost use independent of any client
## amount, fund history and ledger markers, project persistence, duplicate/conflict
## replays, restart recovery that fills only the project document without paying
## twice, a read-only view with a field whitelist, and visitor/anonymous/read-only
## refusals through the WorldHost permission path.
##
## No UI, network transport, projection or Windows path is exercised.

const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const PublicFund = preload("res://world/public_fund.gd")
const FundStore = preload("res://world/fund_store.gd")
const PublicWorks = preload("res://world/public_works.gd")
const PublicWorksStore = preload("res://world/public_works_store.gd")
const Economy = preload("res://farm/economy_state.gd")

const START: float = 1800000000.0
const WORLD: String = "world-public-works-authority"
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const PEER_A: int = 41
const PEER_B: int = 42
const PEER_C: int = 43
const PEER_VISITOR: int = 44
const PEER_ANONYMOUS: int = 45
const ORG: String = "guild_works"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var root_dir: String = _repo().path_join(
		".local/verification/public-works-authority-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)
	_test_store_roundtrip_and_rejection(root_dir)
	_test_open_pledge_release(root_dir)
	_test_build_rejections(root_dir)
	_test_build_success(root_dir)
	_test_build_replay_and_conflict(root_dir)
	_test_restart_and_recovery(root_dir)
	_test_view_and_permissions(root_dir)
	for failure: String in failures:
		push_error(failure)
	print("PUBLIC_WORKS_AUTHORITY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_store_roundtrip_and_rejection(root_dir: String) -> void:
	var store := PublicWorksStore.new(root_dir.path_join("store"))
	_expect(PublicWorksStore.MAX_BYTES == 65536,
		"The public works sidecar budget is 64 KiB")
	var missing: Dictionary = store.load_state()
	_expect(missing.ok and missing.kind == "missing",
		"A world without a project document gets an empty table")
	_expect(PublicWorks.valid(missing.state),
		"The missing-document project table is valid")
	_expect((missing.state.get("projects", {}) as Dictionary).is_empty(),
		"The default project table has no projects")

	var empty_saved: Dictionary = store.save_state(missing.state)
	_expect(empty_saved.ok and empty_saved.kind == "saved",
		"A valid empty project table is written atomically")
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok and loaded.kind == "loaded",
		"The written project table reloads")
	_expect(loaded.state.projects == missing.state.projects,
		"An empty project table round trips")

	var unknown_key: Dictionary = missing.state.duplicate(true)
	unknown_key["extra"] = true
	_expect(not store.save_state(unknown_key).ok,
		"An unknown top-level key is refused before it reaches the file")
	_expect(not store.save_state({"projects": []}).ok,
		"A malformed project table is refused")

	var corrupt_dir: String = root_dir.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	var corrupt_path: String = corrupt_dir.path_join(PublicWorksStore.MAIN)
	_write(corrupt_path, JSON.stringify({"version": PublicWorksStore.VERSION, "state": {}}))
	var corrupt_before: String = FileAccess.get_file_as_string(corrupt_path)
	var corrupt_host := WorldHost.new()
	root.add_child(corrupt_host)
	var corrupt_open: Dictionary = corrupt_host.configure(corrupt_dir, START, WORLD)
	_expect(not corrupt_open.ok
			and str(corrupt_open.get("reason", "")) == "load_public_works_corrupt",
		"A corrupt project document stops the authority")
	_expect(FileAccess.get_file_as_string(corrupt_path) == corrupt_before,
		"A corrupt project document is not overwritten")

	var unsupported_dir: String = root_dir.path_join("unsupported")
	DirAccess.make_dir_recursive_absolute(unsupported_dir)
	_write(unsupported_dir.path_join(PublicWorksStore.MAIN),
		JSON.stringify({"version": PublicWorksStore.VERSION + 1,
			"state": PublicWorks.empty()}))
	var unsupported_host := WorldHost.new()
	root.add_child(unsupported_host)
	_expect(str(unsupported_host.configure(unsupported_dir, START, WORLD).get("reason", ""))
			== "load_public_works_unsupported",
		"An unsupported project document version is refused")

	var direct := HeadlessWorld.new()
	var direct_opened: Dictionary = direct.open(root_dir.path_join("direct"), START)
	_expect(bool(direct_opened.get("ok", false)) and PublicWorks.valid(direct.public_works),
		"A direct headless world starts with an empty, valid project table")
	_expect((direct.public_works_view().get("projects", []) as Array).is_empty(),
		"A world that never opened a project has an empty project view")


func _test_open_pledge_release(root_dir: String) -> void:
	var host: WorldHost = _open_host(root_dir.path_join("rules"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)

	var opened: Dictionary = host.public_works_for_member(PEER_B, "open", {
		"project_id": "square_01", "kind": PublicWorks.KIND_VILLAGE_SQUARE,
		"parcel_id": "parcel_09", "command_id": "pw-open-square",
	})
	_expect(opened.ok and str(opened.action) == "open",
		"Any named member can open a public project")
	_expect(not opened.duplicate, "The first open is not a replay")
	var row: Dictionary = _project(opened.state, "square_01")
	_expect(not row.is_empty()
			and str(row.get("kind", "")) == PublicWorks.KIND_VILLAGE_SQUARE
			and str(row.get("parcel_id", "")) == "parcel_09",
		"The project records its kind and parcel")
	_expect(int(row.get("funded", -1)) == 0
			and int(row.get("pledged", -1)) == 0
			and str(row.get("status", "")) == PublicWorks.STATUS_UNBUILT
			and float(row.get("built_utc", -1.0)) == 0.0,
		"A new project starts unbuilt and unfunded")

	_expect(host.public_works_for_member(PEER_B, "open", {
		"project_id": "square_01", "kind": PublicWorks.KIND_PUBLIC_WELL,
		"command_id": "pw-open-square-again",
	}).reason == "already_exists", "A duplicate project id is refused")
	_expect(host.public_works_for_member(PEER_B, "open", {
		"project_id": "bad_01", "kind": "tower", "command_id": "pw-open-bad-kind",
	}).reason == "invalid_kind", "An unknown project kind is refused")
	_expect(host.public_works_for_member(PEER_B, "open", {
		"project_id": "", "kind": PublicWorks.KIND_PUBLIC_WELL,
		"command_id": "pw-open-bad-id",
	}).reason == "invalid_project", "An empty project id is refused")
	_expect(host.public_works_for_member(PEER_B, "open", {
		"project_id": "bad_02", "kind": PublicWorks.KIND_PUBLIC_WELL,
		"parcel_id": "p".repeat(PublicWorks.MAX_PARCEL_ID_LENGTH + 1),
		"command_id": "pw-open-bad-parcel",
	}).reason == "invalid_parcel", "An oversized parcel id is refused")
	expect_ok(host.public_works_for_member(PEER_B, "open", {
		"project_id": "road_01", "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"command_id": "pw-open-road",
	}), "A project may omit its parcel")

	_expect(host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "missing", "amount": 10, "command_id": "pw-pledge-missing",
	}).reason == "unknown_project", "Pledging to an unknown project is refused")
	for amount: Variant in [0, -1, 1.5, "10", null]:
		_expect(host.public_works_for_member(PEER_A, "pledge", {
			"project_id": "square_01", "amount": amount,
			"command_id": "pw-pledge-bad-%s" % str(amount),
		}).reason == "invalid_amount", "A non-positive or fractional pledge is refused")
	_expect(host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "square_01", "amount": PublicWorks.MAX_PLEDGE + 1,
		"command_id": "pw-pledge-limit",
	}).reason == "amount_limit", "A pledge above the single-pledge bound is refused")

	var pledged: Dictionary = host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "square_01", "amount": 100, "command_id": "pw-pledge-100",
	})
	_expect(pledged.ok, "A positive pledge is accepted")
	row = _project(pledged.state, "square_01")
	_expect(int(row.get("pledged", -1)) == 100 and int(row.get("funded", -1)) == 100
			and str(row.get("status", "")) == PublicWorks.STATUS_UNBUILT,
		"A partial pledge stays unbuilt")
	_expect(host.world.farm.economy_total_cash() == host.world.farm.economy_issued(),
		"A pledge moves no cash")

	_expect(host.public_works_for_member(PEER_A, "release", {
		"project_id": "square_01", "amount": 101, "command_id": "pw-release-too-much",
	}).reason == "insufficient_pledged", "Releasing more than pledged is refused")
	var released: Dictionary = host.public_works_for_member(PEER_A, "release", {
		"project_id": "square_01", "amount": 40, "command_id": "pw-release-40",
	})
	_expect(released.ok, "A valid release is accepted")
	row = _project(released.state, "square_01")
	_expect(int(row.get("pledged", -1)) == 60 and int(row.get("funded", -1)) == 60
			and str(row.get("status", "")) == PublicWorks.STATUS_UNBUILT,
		"A release lowers the pledge and stays unbuilt")

	# Write-time copy: a refused rule never mutates the live document or the file.
	var works_before: String = JSON.stringify(host.world.public_works)
	var stored_before: String = JSON.stringify(_stored_works(host).state)
	_expect(host.public_works_for_member(PEER_A, "release", {
		"project_id": "square_01", "amount": 999, "command_id": "pw-copy-release",
	}).reason == "insufficient_pledged", "An excessive release is refused")
	_expect(JSON.stringify(host.world.public_works) == works_before,
		"A refused release does not mutate the live project document")
	_expect(JSON.stringify(_stored_works(host).state) == stored_before,
		"A refused release leaves the stored project document untouched")

	# In-memory idempotency and conflicts.
	var idem: Dictionary = host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "square_01", "amount": 10, "command_id": "pw-idem-pledge",
	})
	_expect(idem.ok and not idem.duplicate, "The first idempotency pledge commits")
	var works_after_idem: String = JSON.stringify(host.world.public_works)
	var replay: Dictionary = host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "square_01", "amount": 10, "command_id": "pw-idem-pledge",
	})
	_expect(replay.ok and replay.duplicate, "The same command id and payload replays")
	_expect(JSON.stringify(host.world.public_works) == works_after_idem,
		"A replay does not change the project document")
	var conflict: Dictionary = host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "square_01", "amount": 11, "command_id": "pw-idem-pledge",
	})
	_expect(conflict.reason == "command_conflict",
		"Reusing a command id with another payload conflicts")
	_expect(JSON.stringify(host.world.public_works) == works_after_idem,
		"A conflict does not change the project document")
	_expect(host.public_works_for_member(PEER_A, "open", {
		"project_id": "road_02", "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"command_id": "",
	}).reason == "invalid_command", "An empty command id is refused")

	var stored: Dictionary = _stored_works(host)
	_expect(stored.ok and PublicWorks.valid(stored.state),
		"The project table is written to the sidecar")
	_expect(stored.state.projects.has("square_01")
			and stored.state.projects.has("road_01"),
		"The stored document holds every opened project")


func _test_build_rejections(root_dir: String) -> void:
	# Underfunded: the rule refuses before any fund lookup or cash movement.
	var under_host: WorldHost = _open_host(root_dir.path_join("underfunded"), START)
	_join(under_host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	expect_ok(under_host.public_works_for_member(PEER_A, "open", {
		"project_id": "well_01", "kind": PublicWorks.KIND_PUBLIC_WELL,
		"command_id": "pw-under-open",
	}), "The underfunded project is opened")
	expect_ok(under_host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "well_01", "amount": 100, "command_id": "pw-under-pledge",
	}), "The project is pledged below cost")
	var total_before: int = under_host.world.farm.economy_total_cash()
	var under: Dictionary = under_host.public_works_for_member(PEER_A, "build", {
		"project_id": "well_01", "fund_id": "fund_missing",
		"command_id": "pw-under-build",
	})
	_expect(under.reason == "underfunded", "An underfunded project cannot be built")
	_expect(under_host.world.farm.economy_total_cash() == total_before,
		"An underfunded build moves no cash")
	_expect(str(_project(under.state, "well_01").get("status", ""))
			== PublicWorks.STATUS_UNBUILT, "An underfunded build leaves the project unbuilt")

	# Not keeper: a plain member cannot spend another keeper's fund.
	var keeper_dir: String = root_dir.path_join("not-keeper")
	var keeper_host: WorldHost = _open_host(keeper_dir, START)
	_join(keeper_host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(keeper_host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_create_org(keeper_host, PEER_A, ORG, "河岸工程", "not-keeper")
	expect_ok(keeper_host.organization_for_member(PEER_B, "join", {
		"org_id": ORG, "command_id": "org-join-b-not-keeper",
	}), "B joins the organization")
	_seed_actor(keeper_host, PLAYER_A)
	expect_ok(_open_fund(keeper_host, PEER_A, ORG, "fund-open-not-keeper"),
		"A opens the organization fund")
	expect_ok(keeper_host.fund_for_member(PEER_A, "contribute", {
		"fund_id": PublicFund.fund_for(ORG), "amount": 120,
		"command_id": "fund-contrib-not-keeper",
	}), "The leader funds the public account")
	expect_ok(keeper_host.public_works_for_member(PEER_A, "open", {
		"project_id": "road_01", "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"command_id": "pw-nk-open",
	}), "The road is opened")
	expect_ok(keeper_host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "road_01", "amount": 120, "command_id": "pw-nk-pledge",
	}), "The road reaches its fixed cost")
	var cash_before: int = keeper_host.world.farm.economy_cash(PublicFund.account_for(ORG))
	var world_before: int = keeper_host.world.farm.economy_cash(Economy.WORLD_OWNER)
	var not_keeper: Dictionary = keeper_host.public_works_for_member(PEER_B, "build", {
		"project_id": "road_01", "fund_id": PublicFund.fund_for(ORG),
		"command_id": "pw-nk-build",
	})
	_expect(not_keeper.reason == "not_keeper", "A non-keeper cannot build")
	_expect(keeper_host.world.farm.economy_cash(PublicFund.account_for(ORG)) == cash_before
			and keeper_host.world.farm.economy_cash(Economy.WORLD_OWNER) == world_before,
		"A non-keeper build moves no cash")
	_expect(str(_project(not_keeper.state, "road_01").get("status", ""))
			== PublicWorks.STATUS_FUNDED, "A non-keeper build leaves the project funded")

	# Role forbidden: the keeper lost the current organization spend permission.
	var role_dir: String = root_dir.path_join("role")
	var role_host: WorldHost = _open_host(role_dir, START)
	_join(role_host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(role_host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_create_org(role_host, PEER_A, ORG, "河岸工程", "role")
	expect_ok(role_host.organization_for_member(PEER_B, "join", {
		"org_id": ORG, "command_id": "org-join-b-role",
	}), "B joins the organization")
	expect_ok(role_host.organization_for_member(PEER_A, "appoint", {
		"org_id": ORG, "player_id": PLAYER_B, "role": "officer",
		"command_id": "org-officer-b-role",
	}), "B becomes an officer")
	expect_ok(_open_fund(role_host, PEER_B, ORG, "fund-open-role"),
		"The officer opens the fund and becomes keeper")
	_seed_actor(role_host, PLAYER_A)
	expect_ok(role_host.fund_for_member(PEER_A, "contribute", {
		"fund_id": PublicFund.fund_for(ORG), "amount": 120,
		"command_id": "fund-contrib-role",
	}), "The leader funds the public account")
	expect_ok(role_host.public_works_for_member(PEER_A, "open", {
		"project_id": "road_01", "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"command_id": "pw-role-open",
	}), "The role-check road is opened")
	expect_ok(role_host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "road_01", "amount": 120, "command_id": "pw-role-pledge",
	}), "The role-check road reaches its fixed cost")
	expect_ok(role_host.organization_for_member(PEER_A, "appoint", {
		"org_id": ORG, "player_id": PLAYER_B, "role": "member",
		"command_id": "org-demote-b-role",
	}), "The leader demotes the keeper")
	cash_before = role_host.world.farm.economy_cash(PublicFund.account_for(ORG))
	world_before = role_host.world.farm.economy_cash(Economy.WORLD_OWNER)
	var forbidden: Dictionary = role_host.public_works_for_member(PEER_B, "build", {
		"project_id": "road_01", "org_id": ORG, "command_id": "pw-role-build",
	})
	_expect(forbidden.reason == "role_forbidden",
		"A keeper whose current role cannot spend is refused")
	_expect(role_host.world.farm.economy_cash(PublicFund.account_for(ORG)) == cash_before
			and role_host.world.farm.economy_cash(Economy.WORLD_OWNER) == world_before,
		"A role-forbidden build moves no cash")

	# Insufficient funds: the project is funded by pledges but the fund is empty.
	var poor_dir: String = root_dir.path_join("insufficient")
	var poor_host: WorldHost = _open_host(poor_dir, START)
	_join(poor_host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_create_org(poor_host, PEER_A, ORG, "河岸工程", "insufficient")
	expect_ok(_open_fund(poor_host, PEER_A, ORG, "fund-open-insufficient"),
		"The empty fund is opened")
	expect_ok(poor_host.public_works_for_member(PEER_A, "open", {
		"project_id": "road_01", "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"command_id": "pw-poor-open",
	}), "The insufficient-funds road is opened")
	expect_ok(poor_host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "road_01", "amount": 120, "command_id": "pw-poor-pledge",
	}), "Pledges alone mark the project funded")
	var poor: Dictionary = poor_host.public_works_for_member(PEER_A, "build", {
		"project_id": "road_01", "fund_id": PublicFund.fund_for(ORG),
		"command_id": "pw-poor-build",
	})
	_expect(poor.reason == "insufficient_funds",
		"An empty fund cannot pay the fixed cost")
	_expect(poor_host.world.farm.economy_cash(Economy.WORLD_OWNER) == 0,
		"An insufficient build moves no cash")
	_expect(str(_project(poor.state, "road_01").get("status", ""))
			== PublicWorks.STATUS_FUNDED, "An insufficient build leaves the project funded")


func _test_build_success(root_dir: String) -> void:
	var directory: String = root_dir.path_join("success")
	var host: WorldHost = _open_host(directory, START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_create_org(host, PEER_A, ORG, "河岸工程", "success")
	_seed_actor(host, PLAYER_A)
	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	expect_ok(_open_fund(host, PEER_A, ORG, "fund-open-success"),
		"The fund is opened for the build")
	expect_ok(host.fund_for_member(PEER_A, "contribute", {
		"fund_id": fund_id, "amount": PublicWorks.CATALOG[PublicWorks.KIND_ROAD_SEGMENT],
		"command_id": "fund-contrib-success",
	}), "The leader contributes the fixed cost")
	expect_ok(host.public_works_for_member(PEER_A, "open", {
		"project_id": "road_01", "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"command_id": "pw-success-open",
	}), "The road is opened")
	expect_ok(host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "road_01", "amount": 120, "command_id": "pw-success-pledge",
	}), "The road is pledged to its fixed cost")

	var cost: int = PublicWorks.cost_of(PublicWorks.KIND_ROAD_SEGMENT)
	var org_before: int = host.world.farm.economy_cash(org_account)
	var world_before: int = host.world.farm.economy_cash(Economy.WORLD_OWNER)
	var total_before: int = host.world.farm.economy_total_cash()
	var issued_before: int = host.world.farm.economy_issued()
	var built: Dictionary = host.public_works_for_member(PEER_A, "build", {
		"project_id": "road_01", "org_id": ORG, "amount": 1,
		"command_id": "pw-success-build",
	})
	_expect(built.ok and str(built.action) == "build" and not built.duplicate,
		"The keeper builds the funded project through the derived fund")
	_expect(host.world.farm.economy_cash(org_account) == org_before - cost,
		"The organization account pays exactly the catalog cost")
	_expect(host.world.farm.economy_cash(Economy.WORLD_OWNER) == world_before + cost,
		"The fixed cost lands in the public treasury")
	_expect(host.world.farm.economy_total_cash() == total_before,
		"A build preserves total cash")
	_expect(host.world.farm.economy_issued() == issued_before,
		"A build issues no new cash")
	_expect(host.world.farm.economy_total_cash() == host.world.farm.economy_issued(),
		"After the build total cash still equals issued cash")

	var fund_row: Dictionary = _fund(host.world.funds_view(), fund_id)
	_expect(int(fund_row.get("balance", -1)) == 0
			and int(fund_row.get("spent", -1)) == cost,
		"The fund view shows the fixed cost spent")
	var stored_funds: Dictionary = _stored_funds(host)
	var history: Array = stored_funds.state.funds[fund_id].history
	_expect(history.size() == 1 and int(history[0].amount) == cost
			and str(history[0].project) == "road_01",
		"Exactly one fund history row records the project and cost")

	var row: Dictionary = _project(built.state, "road_01")
	_expect(str(row.get("status", "")) == PublicWorks.STATUS_BUILT,
		"The project view reports it built")
	_expect(int(row.get("funded", -1)) == cost and int(row.get("pledged", -1)) == 120,
		"The built project keeps its funded and pledged totals")
	_expect(float(row.get("built_utc", 0.0)) > 0.0,
		"The built project records its authority time")
	var stored_works: Dictionary = _stored_works(host)
	_expect(stored_works.ok and PublicWorks.valid(stored_works.state),
		"The project document is written and valid")
	_expect(str(stored_works.state.projects["road_01"].status) == PublicWorks.STATUS_BUILT
			and float(stored_works.state.projects["road_01"].built_utc)
				== float(row.get("built_utc", -1.0)),
		"The stored project matches the authoritative view")
	_expect(int(host.world.farm.economy_cash(org_account)) == int(
			_fund(host.world.funds_view(), fund_id).get("balance", -2)),
		"After the build the fund balance still equals the account cash")


func _test_build_replay_and_conflict(root_dir: String) -> void:
	var host: WorldHost = _open_host(root_dir.path_join("replay"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_create_org(host, PEER_A, ORG, "河岸工程", "replay")
	_seed_actor(host, PLAYER_A)
	var fund_id: String = PublicFund.fund_for(ORG)
	expect_ok(_open_fund(host, PEER_A, ORG, "fund-open-replay"),
		"The replay fund is opened")
	expect_ok(host.fund_for_member(PEER_A, "contribute", {
		"fund_id": fund_id, "amount": 120, "command_id": "fund-contrib-replay",
	}), "The replay fund holds the fixed cost")
	expect_ok(host.public_works_for_member(PEER_A, "open", {
		"project_id": "road_01", "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"command_id": "pw-replay-open",
	}), "The replay road is opened")
	expect_ok(host.public_works_for_member(PEER_A, "open", {
		"project_id": "square_01", "kind": PublicWorks.KIND_VILLAGE_SQUARE,
		"command_id": "pw-replay-open-square",
	}), "The conflict project is opened")
	expect_ok(host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "road_01", "amount": 120, "command_id": "pw-replay-pledge",
	}), "The replay road reaches its fixed cost")
	var args: Dictionary = {
		"project_id": "road_01", "fund_id": fund_id, "command_id": "pw-replay-build",
	}
	var built: Dictionary = host.public_works_for_member(PEER_A, "build", args)
	_expect(built.ok, "The replay baseline build commits")
	var works_after: String = JSON.stringify(host.world.public_works)
	var funds_after: String = JSON.stringify(host.world.funds)
	var org_after: int = host.world.farm.economy_cash(PublicFund.account_for(ORG))
	var world_after: int = host.world.farm.economy_cash(Economy.WORLD_OWNER)

	var replay: Dictionary = host.public_works_for_member(PEER_A, "build", args)
	_expect(replay.ok and replay.duplicate, "The same build command replays as duplicate")
	_expect(JSON.stringify(host.world.public_works) == works_after,
		"A build replay leaves the project document byte-identical")
	_expect(JSON.stringify(host.world.funds) == funds_after,
		"A build replay leaves the fund document byte-identical")
	_expect(host.world.farm.economy_cash(PublicFund.account_for(ORG)) == org_after
			and host.world.farm.economy_cash(Economy.WORLD_OWNER) == world_after,
		"A build replay moves no cash")

	var conflict: Dictionary = host.public_works_for_member(PEER_A, "build", {
		"project_id": "square_01", "fund_id": fund_id,
		"command_id": "pw-replay-build",
	})
	_expect(conflict.reason == "command_conflict",
		"Reusing a build command id for another project conflicts")
	_expect(host.world.farm.economy_cash(PublicFund.account_for(ORG)) == org_after
			and host.world.farm.economy_cash(Economy.WORLD_OWNER) == world_after,
		"A build command conflict moves no cash")
	var conflict_fund: Dictionary = host.public_works_for_member(PEER_A, "build", {
		"project_id": "road_01", "fund_id": "fund_other",
		"command_id": "pw-replay-build",
	})
	_expect(conflict_fund.reason == "command_conflict",
		"Reusing a build command id with another fund conflicts")

	var again: Dictionary = host.public_works_for_member(PEER_A, "build", {
		"project_id": "road_01", "fund_id": fund_id, "command_id": "pw-replay-again",
	})
	_expect(again.reason == "already_built",
		"A different command id on a built project is refused")
	_expect(host.world.farm.economy_cash(Economy.WORLD_OWNER) == world_after,
		"An already-built refusal moves no cash")


func _test_restart_and_recovery(root_dir: String) -> void:
	var directory: String = root_dir.path_join("restart")
	var host: WorldHost = _open_host(directory, START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_create_org(host, PEER_A, ORG, "河岸工程", "restart")
	_seed_actor(host, PLAYER_A)
	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	expect_ok(_open_fund(host, PEER_A, ORG, "fund-open-restart"),
		"The restart fund is opened")
	expect_ok(host.fund_for_member(PEER_A, "contribute", {
		"fund_id": fund_id, "amount": 120, "command_id": "fund-contrib-restart",
	}), "The restart fund holds the fixed cost")
	expect_ok(host.public_works_for_member(PEER_A, "open", {
		"project_id": "road_01", "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"command_id": "pw-restart-open",
	}), "The restart road is opened")
	expect_ok(host.public_works_for_member(PEER_A, "open", {
		"project_id": "road_02", "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"command_id": "pw-restart-open-2",
	}), "A same-cost conflict road is opened")
	expect_ok(host.public_works_for_member(PEER_A, "open", {
		"project_id": "well_01", "kind": PublicWorks.KIND_PUBLIC_WELL,
		"command_id": "pw-restart-open-well",
	}), "A different-cost conflict project is opened")
	expect_ok(host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "road_01", "amount": 120, "command_id": "pw-restart-pledge",
	}), "The restart road reaches its fixed cost")
	expect_ok(host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "road_02", "amount": 120, "command_id": "pw-restart-pledge-2",
	}), "The second road reaches its fixed cost")
	expect_ok(host.public_works_for_member(PEER_A, "pledge", {
		"project_id": "well_01", "amount": 180, "command_id": "pw-restart-pledge-well",
	}), "The well reaches its fixed cost")
	var pre_build: Dictionary = host.world.public_works.duplicate(true)
	var args: Dictionary = {
		"project_id": "road_01", "fund_id": fund_id, "command_id": "pw-restart-build",
	}
	var built: Dictionary = host.public_works_for_member(PEER_A, "build", args)
	_expect(built.ok, "The restart baseline build commits")
	var world_after_build: int = host.world.farm.economy_cash(Economy.WORLD_OWNER)
	_expect(host.world.farm.economy_cash(org_account) == 0,
		"The organization account is empty after the build")

	var reopened: WorldHost = _open_host(directory, START + 100.0)
	_join(reopened, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	var restarted_view: Dictionary = reopened.public_works_for_member(PEER_A, "state", {})
	_expect(str(_project(restarted_view.state, "road_01").get("status", ""))
			== PublicWorks.STATUS_BUILT, "The built project survives the restart")
	var restarted_fund: Dictionary = _fund(reopened.fund_for_member(
		PEER_A, "state", {}).state, fund_id)
	_expect(int(restarted_fund.get("balance", -1)) == 0
			and int(restarted_fund.get("spent", -1)) == 120,
		"The spent fund survives the restart")
	var restarted_history: Array = _stored_funds(reopened).state.funds[fund_id].history
	_expect(restarted_history.size() == 1
			and str(restarted_history[0].project) == "road_01",
		"The fund history survives the restart")

	var replay: Dictionary = reopened.public_works_for_member(PEER_A, "build", args)
	_expect(replay.ok and replay.duplicate,
		"A build retry after restart replays through the durable marker")
	_expect(reopened.world.farm.economy_cash(Economy.WORLD_OWNER) == world_after_build
			and reopened.world.farm.economy_cash(org_account) == 0,
		"A build replay after restart moves no cash")
	_expect(_stored_funds(reopened).state.funds[fund_id].history.size() == 1,
		"A build replay after restart adds no second history row")

	var changed_cost: Dictionary = reopened.public_works_for_member(PEER_A, "build", {
		"project_id": "well_01", "fund_id": fund_id,
		"command_id": "pw-restart-build",
	})
	_expect(changed_cost.reason == "command_conflict",
		"A durable marker with another cost conflicts")
	var changed_project: Dictionary = reopened.public_works_for_member(PEER_A, "build", {
		"project_id": "road_02", "fund_id": fund_id,
		"command_id": "pw-restart-build",
	})
	_expect(changed_project.reason == "command_conflict",
		"A durable marker with another same-cost project conflicts")
	_expect(reopened.world.farm.economy_cash(Economy.WORLD_OWNER) == world_after_build,
		"Durable command conflicts move no cash")

	# Crash shape "cash spent, project document not written": restore the pre-build
	# project table on disk while the farm and fund documents keep the spend.
	expect_ok(PublicWorksStore.new(directory).save_state(pre_build),
		"The stale pre-build project table is written")
	var recovered: WorldHost = _open_host(directory, START + 200.0)
	_join(recovered, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	var before_retry: Dictionary = recovered.public_works_for_member(PEER_A, "state", {})
	_expect(str(_project(before_retry.state, "road_01").get("status", ""))
			== PublicWorks.STATUS_FUNDED,
		"After the simulated crash the project is still funded")
	_expect(int(_stored_funds(recovered).state.funds[fund_id].history.size()) == 1,
		"The fund side already holds the spend before the retry")
	var recovered_build: Dictionary = recovered.public_works_for_member(PEER_A, "build", args)
	_expect(recovered_build.ok, "The paid retry completes the project document")
	_expect(recovered.world.farm.economy_cash(Economy.WORLD_OWNER) == world_after_build
			and recovered.world.farm.economy_cash(org_account) == 0,
		"The paid retry does not move cash a second time")
	var recovered_history: Array = _stored_funds(recovered).state.funds[fund_id].history
	_expect(recovered_history.size() == 1 and int(recovered_history[0].amount) == 120,
		"The paid retry does not add a second history row")
	_expect(str(_project(recovered_build.state, "road_01").get("status", ""))
			== PublicWorks.STATUS_BUILT,
		"The paid retry marks the project built")
	_expect(str(_stored_works(recovered).state.projects["road_01"].status)
			== PublicWorks.STATUS_BUILT,
		"The recovered project reaches the sidecar")


func _test_view_and_permissions(root_dir: String) -> void:
	var host: WorldHost = _open_host(root_dir.path_join("permissions"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_VISITOR, PLAYER_C, WorldInvite.VISITOR)
	_join(host, PEER_ANONYMOUS, "", WorldInvite.MEMBER)
	expect_ok(host.public_works_for_member(PEER_A, "open", {
		"project_id": "square_01", "kind": PublicWorks.KIND_VILLAGE_SQUARE,
		"command_id": "pw-view-open-square",
	}), "The first view project is opened")
	expect_ok(host.public_works_for_member(PEER_A, "open", {
		"project_id": "road_01", "kind": PublicWorks.KIND_ROAD_SEGMENT,
		"command_id": "pw-view-open-road",
	}), "The second view project is opened")

	var view: Dictionary = host.public_works_for_member(PEER_VISITOR, "state", {})
	_expect(view.ok, "A visitor may read the project view")
	var rows: Array = view.state.get("projects", [])
	_expect(rows.size() == 2, "The view lists every project")
	_expect(str(rows[0].get("project_id", "")) == "road_01"
			and str(rows[1].get("project_id", "")) == "square_01",
		"The view is sorted by project id")
	var keys: Array = rows[0].keys()
	keys.sort()
	var expected_keys: Array = [
		"built_utc", "funded", "kind", "parcel_id", "pledged", "project_id", "status",
	]
	_expect(keys == expected_keys,
		"The view carries exactly the public project fields")
	_expect(not rows[0].has("command_id") and not rows[0].has("history"),
		"The view carries no command records")

	_expect(host.public_works_for_member(PEER_ANONYMOUS, "state", {}).ok,
		"An anonymous member may read the project view")
	_expect(host.public_works_for_member(PEER_VISITOR, "open", {
		"project_id": "well_01", "kind": PublicWorks.KIND_PUBLIC_WELL,
		"command_id": "pw-view-visitor",
	}).reason == "forbidden", "A visitor cannot write project state")
	_expect(host.public_works_for_member(PEER_ANONYMOUS, "open", {
		"project_id": "well_01", "kind": PublicWorks.KIND_PUBLIC_WELL,
		"command_id": "pw-view-anonymous",
	}).reason == "no_player", "An anonymous member has no player identity to act as")
	_expect(host.public_works_for_member(99, "state", {}).reason == "not_a_member",
		"A connection outside the roster is refused")
	_expect(host.public_works_for_member(PEER_A, "demolish", {}).reason
			== "unknown_action", "An unknown project action is refused")
	_expect(host.public_works_for_member(PEER_A, "open", {
		"project_id": "well_01", "kind": PublicWorks.KIND_PUBLIC_WELL,
		"command_id": "",
	}).reason == "invalid_command", "An empty command id is refused")
	host.read_only = true
	_expect(host.public_works_for_member(PEER_A, "open", {
		"project_id": "well_01", "kind": PublicWorks.KIND_PUBLIC_WELL,
		"command_id": "pw-view-read-only",
	}).reason == "read_only", "A retiring authority refuses project writes")
	_expect(host.public_works_for_member(PEER_A, "state", {}).ok,
		"A retiring authority still answers project reads")
	host.read_only = false


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


func _create_org(host: WorldHost, peer: int, org_id: String, name: String,
		suffix: String) -> void:
	expect_ok(host.organization_for_member(peer, "create", {
		"org_id": org_id, "name": name, "command_id": "org-create-" + suffix,
	}), "The organization %s is created" % org_id)


func _open_fund(host: WorldHost, peer: int, org_id: String,
		command_id: String) -> Dictionary:
	return host.fund_for_member(peer, "open", {
		"org_id": org_id, "command_id": command_id,
	})


## Opens the actor's real economy account (the one-time grant). This uses the same
## public FarmState surface the game uses; it adds no test-only storage path.
func _seed_actor(host: WorldHost, player_id: String) -> void:
	expect_ok(host.world.farm.economy_open_account("seed-account-" + player_id,
		player_id, START), "%s has a real cash account" % player_id)
	_expect(host.world.farm.economy_total_cash() == host.world.farm.economy_issued(),
		"Seeding keeps cash conservation")


func _stored_works(host: WorldHost) -> Dictionary:
	return PublicWorksStore.new(host.world.directory).load_state()


func _stored_funds(host: WorldHost) -> Dictionary:
	return FundStore.new(host.world.directory).load_state()


func _project(view: Variant, project_id: String) -> Dictionary:
	if not view is Dictionary:
		return {}
	var rows: Variant = (view as Dictionary).get("projects")
	if not rows is Array:
		return {}
	for value: Variant in rows:
		if value is Dictionary \
				and str((value as Dictionary).get("project_id", "")) == project_id:
			return value
	return {}


func _fund(view: Variant, fund_id: String) -> Dictionary:
	if not view is Dictionary:
		return {}
	var rows: Variant = (view as Dictionary).get("funds")
	if not rows is Array:
		return {}
	for value: Variant in rows:
		if value is Dictionary \
				and str((value as Dictionary).get("fund_id", "")) == fund_id:
			return value
	return {}


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


func expect_ok(result: Dictionary, message: String) -> void:
	_expect(bool(result.get("ok", false)), message)
