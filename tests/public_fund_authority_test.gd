extends SceneTree
## M8-04 public fund authority wiring: the pure fund rules are loaded, persisted
## and executed through the authoritative world.
##
## Covers: the fund sidecar round trip and strict key set, organization-gated
## opening, real cash contributed from the contributor's account into the derived
## organization account, keeper spends moving cash into `@world`, keeper rotation
## restricted to current organization members, balance/account invariant checked
## on load and on every commit, idempotent replay, ledger-marker recovery when the
## farm committed but the fund document did not, visitor/anonymous/read-only
## refusals, a read-only view without history, and corrupt/unsupported/mismatched
## documents that stop the authority instead of being overwritten.
##
## No UI, project catalogue integration, projection or Windows path is exercised.

const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const PublicFund = preload("res://world/public_fund.gd")
const FundStore = preload("res://world/fund_store.gd")
const Economy = preload("res://farm/economy_state.gd")
const FarmCommand = preload("res://farm/farm_command.gd")

const START: float = 1800000000.0
const WORLD: String = "world-fund-authority"
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const PEER_A: int = 41
const PEER_B: int = 42
const PEER_C: int = 43
const PEER_VISITOR: int = 44
const PEER_ANONYMOUS: int = 45
const ORG: String = "guild_alpha"
const ORG_2: String = "guild_beta"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var root_dir: String = _repo().path_join(
		".local/verification/public-fund-authority-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)
	_test_store_roundtrip_and_default(root_dir)
	_test_open_requires_org_permission(root_dir)
	_test_direct_payment_to_org_account_is_refused(root_dir)
	_test_contribute_moves_real_cash(root_dir)
	_test_spend_and_org_permission(root_dir)
	_test_rotate_keeper(root_dir)
	_test_restart_and_replay(root_dir)
	_test_paid_retry_recovers_fund_document(root_dir)
	_test_load_mismatch_refuses_startup(root_dir)
	_test_corrupt_and_unsupported(root_dir)
	_test_permissions_and_view(root_dir)
	_test_write_time_copy(root_dir)
	for failure: String in failures:
		push_error(failure)
	print("PUBLIC_FUND_AUTHORITY_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_store_roundtrip_and_default(root_dir: String) -> void:
	var store := FundStore.new(root_dir.path_join("store"))
	_expect(FundStore.MAX_BYTES == 65536, "The fund sidecar budget is 64 KiB")
	var missing: Dictionary = store.load_state()
	_expect(missing.ok and missing.kind == "missing",
		"A world without a fund document gets an empty table")
	_expect(PublicFund.valid(missing.state), "The missing-document fund table is valid")
	_expect((missing.state.get("funds", {}) as Dictionary).is_empty(),
		"The default fund table has no funds")

	var empty_saved: Dictionary = store.save_state(missing.state)
	_expect(empty_saved.ok and empty_saved.kind == "saved",
		"A valid empty fund table is written atomically")
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok and loaded.kind == "loaded", "The written fund table reloads")
	_expect(loaded.state.funds == missing.state.funds,
		"An empty fund table round trips")

	var unknown_key: Dictionary = missing.state.duplicate(true)
	unknown_key["extra"] = true
	_expect(not store.save_state(unknown_key).ok,
		"An unknown top-level key is refused before it reaches the file")
	_expect(not store.save_state({"funds": []}).ok, "A malformed fund table is refused")


func _test_open_requires_org_permission(root_dir: String) -> void:
	var host: WorldHost = _open_host(root_dir.path_join("open"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_join(host, PEER_C, PLAYER_C, WorldInvite.MEMBER)
	_create_org(host, PEER_A, ORG, "河岸合作社", "open")
	expect_ok(host.organization_for_member(PEER_B, "join", {
		"org_id": ORG, "command_id": "org-join-b-open",
	}), "B joins the organization")

	var fund_id: String = PublicFund.fund_for(ORG)
	_expect(host.fund_for_member(PEER_A, "open", {
		"org_id": "missing_org", "command_id": "fund-open-missing",
	}).reason == "unknown_org", "Opening a fund for an unknown organization is refused")
	_expect(host.fund_for_member(PEER_C, "open", {
		"org_id": ORG, "command_id": "fund-open-c",
	}).reason == "not_member", "An outsider cannot open the organization fund")
	_expect(host.fund_for_member(PEER_B, "open", {
		"org_id": ORG, "command_id": "fund-open-b",
	}).reason == "role_forbidden", "A plain member cannot open the fund")

	var opened: Dictionary = host.fund_for_member(PEER_A, "open", {
		"org_id": ORG, "command_id": "fund-open-a",
	})
	_expect(opened.ok and str(opened.action) == "open", "The leader opens the fund")
	_expect(not opened.duplicate, "The first open is not a replay")
	_expect(str(opened.get("fund_id", "")) == fund_id, "The reply names the derived fund")
	var row: Dictionary = _fund(opened.state, fund_id)
	_expect(not row.is_empty(), "The authoritative reply carries the new fund")
	_expect(str(row.get("org_id", "")) == ORG, "The fund records its organization")
	_expect(str(row.get("keeper", "")) == PLAYER_A, "The opener becomes keeper")
	_expect(int(row.get("balance", -1)) == 0, "A new fund starts empty")
	_expect(int(row.get("spent", -1)) == 0, "A new fund has spent nothing")
	var contributors: Dictionary = row.get("contributors", {}) as Dictionary
	_expect(contributors.has(PLAYER_A) and int(contributors[PLAYER_A]) == 0,
		"The keeper enters the contributor table with a zero total")
	_expect(not row.has("history"), "The view carries no spend history")
	_expect(host.world.farm.economy_cash(PublicFund.account_for(ORG)) == 0,
		"Opening a fund moves no cash")
	_expect(PublicFund.account_for(ORG) == PublicFund.account_for(ORG)
		and PublicFund.account_for(ORG) == "org_" + ORG,
		"The fund account id matches the organization account convention")

	var replay: Dictionary = host.fund_for_member(PEER_A, "open", {
		"org_id": ORG, "command_id": "fund-open-a",
	})
	_expect(replay.ok and replay.duplicate, "Retrying the open command replays its result")
	var conflict: Dictionary = host.fund_for_member(PEER_A, "open", {
		"org_id": ORG_2, "command_id": "fund-open-a",
	})
	_expect(conflict.reason == "command_conflict",
		"Reusing a command id with another payload is a conflict")

	var stored: Dictionary = _stored(host)
	_expect(stored.ok and stored.kind == "loaded",
		"The accepted fund is written to the sidecar immediately")
	_expect(PublicFund.valid(stored.state), "The committed fund document is valid")
	_expect(stored.state.funds.has(fund_id), "The stored document holds the fund")


## A direct player payment to an organization account would move cash without a
## fund row: it could block opening the fund or silently desynchronize the
## balance invariant. The command boundary refuses it and leaves both documents
## untouched.
func _test_direct_payment_to_org_account_is_refused(root_dir: String) -> void:
	var host: WorldHost = _open_host(root_dir.path_join("reserved-pay"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_seed_actor(host, PLAYER_A)
	var cash_before: int = host.world.farm.economy_cash(PLAYER_A)
	var total_before: int = host.world.farm.economy_total_cash()
	var refused: Dictionary = host.execute_for_member(PEER_A,
		FarmCommand.make_pay("direct-org-pay", PublicFund.account_for(ORG), 1, 1, START))
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "reserved_account",
		"A player payment directly into an organization account is refused")
	_expect(host.world.farm.economy_cash(PLAYER_A) == cash_before,
		"The refused payment leaves the payer's cash unchanged")
	_expect(host.world.farm.economy_cash(PublicFund.account_for(ORG)) == 0,
		"The refused payment does not create or credit the organization account")
	_expect(host.world.farm.economy_total_cash() == total_before,
		"The refused payment moves no cash")

	# The account is still openable afterwards: the guard prevents the
	# pre-existing-cash state that would fail the balance invariant.
	_create_org(host, PEER_A, ORG, "河岸合作社", "reserved-pay")
	expect_ok(_open_fund(host, PEER_A, ORG, "fund-reserved-open"),
		"The organization can open its fund after a refused direct payment")
	_expect(_fund_balance_matches(host, PublicFund.fund_for(ORG)),
		"The fund balance still matches the empty organization account")


func _test_contribute_moves_real_cash(root_dir: String) -> void:
	var host: WorldHost = _open_host(root_dir.path_join("contribute"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_join(host, PEER_C, PLAYER_C, WorldInvite.MEMBER)
	_create_org(host, PEER_A, ORG, "河岸合作社", "contribute")
	_seed_actor(host, PLAYER_A)
	_seed_actor(host, PLAYER_B)
	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	expect_ok(_open_fund(host, PEER_A, ORG, "fund-contrib-open"),
		"The fund is opened for the contribution checks")

	var cash_a_before: int = host.world.farm.economy_cash(PLAYER_A)
	var cash_b_before: int = host.world.farm.economy_cash(PLAYER_B)
	var total_before: int = host.world.farm.economy_total_cash()
	var issued_before: int = host.world.farm.economy_issued()
	var contributed: Dictionary = host.fund_for_member(PEER_A, "contribute", {
		"fund_id": fund_id, "amount": 100, "command_id": "fund-contrib-1",
		"actor": PLAYER_B, "owner": PLAYER_B,
	})
	_expect(contributed.ok and str(contributed.action) == "contribute",
		"A member contributes real cash")
	_expect(host.world.farm.economy_cash(PLAYER_A) == cash_a_before - 100,
		"The connected player pays, not the payload actor")
	_expect(host.world.farm.economy_cash(PLAYER_B) == cash_b_before,
		"The payload actor claim never pays")
	_expect(host.world.farm.economy_cash(org_account) == 100,
		"The cash lands in the derived organization account")
	_expect(host.world.farm.economy_total_cash() == total_before,
		"Contributing preserves total cash")
	_expect(host.world.farm.economy_issued() == issued_before,
		"Contributing issues no new cash")
	var row: Dictionary = _fund(contributed.state, fund_id)
	_expect(int(row.get("balance", -1)) == 100, "The fund balance grows by the contribution")
	var contributors: Dictionary = row.get("contributors", {}) as Dictionary
	_expect(int(contributors.get(PLAYER_A, -1)) == 100,
		"The contributor's public total grows by the contribution")
	_expect(_fund_balance_matches(host, fund_id),
		"The fund balance equals the organization account cash")

	var stored: Dictionary = _stored(host)
	_expect(stored.ok and PublicFund.valid(stored.state),
		"The contribution is written to the fund sidecar")
	_expect(int(stored.state.funds[fund_id].balance) == 100,
		"The stored sidecar holds the new balance")

	var funds_after: String = JSON.stringify(host.world.funds)
	var cash_after: int = host.world.farm.economy_cash(PLAYER_A)
	var replay: Dictionary = host.fund_for_member(PEER_A, "contribute", {
		"fund_id": fund_id, "amount": 100, "command_id": "fund-contrib-1",
		"actor": PLAYER_B, "owner": PLAYER_B,
	})
	_expect(replay.ok and replay.duplicate, "Retrying the contribution replays its result")
	_expect(host.world.farm.economy_cash(PLAYER_A) == cash_after,
		"A contribution replay charges no cash twice")
	_expect(JSON.stringify(host.world.funds) == funds_after,
		"A contribution replay does not change the fund document")

	var conflict: Dictionary = host.fund_for_member(PEER_A, "contribute", {
		"fund_id": fund_id, "amount": 50, "command_id": "fund-contrib-1",
	})
	_expect(conflict.reason == "command_conflict",
		"Reusing a contribution command id with another amount conflicts")
	_expect(host.world.farm.economy_cash(PLAYER_A) == cash_after,
		"A conflict charges no cash")

	var poor: Dictionary = host.fund_for_member(PEER_C, "contribute", {
		"fund_id": fund_id, "amount": 10, "command_id": "fund-contrib-poor",
	})
	_expect(poor.reason == "insufficient_cash",
		"A member without an account cannot contribute")
	_expect(host.world.farm.economy_cash(org_account) == 100,
		"A refused contribution moves no cash")

	var unknown: Dictionary = host.fund_for_member(PEER_A, "contribute", {
		"fund_id": "fund_missing", "amount": 1, "command_id": "fund-contrib-unknown",
	})
	_expect(unknown.reason == "unknown_fund", "Contributing to an unknown fund is refused")

	# The fund may also be addressed by organization id; it derives the same row.
	var by_org: Dictionary = host.fund_for_member(PEER_B, "contribute", {
		"org_id": ORG, "amount": 5, "command_id": "fund-contrib-2",
	})
	_expect(by_org.ok and int(_fund(by_org.state, fund_id).get("balance", -1)) == 105,
		"An organization id addresses the same derived fund")
	_expect(host.world.farm.economy_cash(org_account) == 105,
		"The organization account receives the second contribution")


func _test_spend_and_org_permission(root_dir: String) -> void:
	var host: WorldHost = _open_host(root_dir.path_join("spend"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_create_org(host, PEER_A, ORG, "河岸运输", "spend")
	expect_ok(host.organization_for_member(PEER_B, "join", {
		"org_id": ORG, "command_id": "org-join-b-spend",
	}), "B joins the organization")
	expect_ok(host.organization_for_member(PEER_A, "appoint", {
		"org_id": ORG, "player_id": PLAYER_B, "role": "officer",
		"command_id": "org-officer-b-spend",
	}), "B becomes an officer")
	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	expect_ok(_open_fund(host, PEER_B, ORG, "fund-open-officer"),
		"An officer can open the organization fund")
	_seed_actor(host, PLAYER_A)
	expect_ok(host.fund_for_member(PEER_A, "contribute", {
		"fund_id": fund_id, "amount": 100, "command_id": "fund-spend-seed",
	}), "The leader funds the public account")

	var world_before: int = host.world.farm.economy_cash(Economy.WORLD_OWNER)
	var total_before: int = host.world.farm.economy_total_cash()
	var spent: Dictionary = host.fund_for_member(PEER_B, "spend", {
		"fund_id": fund_id, "project_id": "village_square", "amount": 40,
		"command_id": "fund-spend-1",
	})
	_expect(spent.ok and str(spent.action) == "spend", "The keeper spends fund cash")
	_expect(host.world.farm.economy_cash(org_account) == 60,
		"The organization account pays the spend")
	_expect(host.world.farm.economy_cash(Economy.WORLD_OWNER) == world_before + 40,
		"The spend lands in the public treasury")
	_expect(host.world.farm.economy_total_cash() == total_before,
		"A spend preserves total cash")
	var row: Dictionary = _fund(spent.state, fund_id)
	_expect(int(row.get("balance", -1)) == 60, "The view shows the reduced balance")
	_expect(int(row.get("spent", -1)) == 40, "The view shows accumulated spending")
	_expect(_fund_balance_matches(host, fund_id),
		"The fund balance still equals the organization account cash")
	var stored_row: Dictionary = _stored(host).state.funds[fund_id]
	_expect((stored_row.history as Array).size() == 1,
		"The spend appends one history row")
	_expect(int(stored_row.history[0].amount) == 40
		and str(stored_row.history[0].project) == "village_square",
		"The history row records amount and project")

	var cash_after: int = host.world.farm.economy_cash(org_account)
	var world_after: int = host.world.farm.economy_cash(Economy.WORLD_OWNER)
	var not_keeper: Dictionary = host.fund_for_member(PEER_A, "spend", {
		"fund_id": fund_id, "project_id": "public_well", "amount": 10,
		"command_id": "fund-spend-not-keeper",
	})
	_expect(not_keeper.reason == "not_keeper", "Only the keeper may spend")
	_expect(host.world.farm.economy_cash(org_account) == cash_after,
		"A non-keeper spend moves no cash")

	var poor: Dictionary = host.fund_for_member(PEER_B, "spend", {
		"fund_id": fund_id, "project_id": "public_well", "amount": 1000,
		"command_id": "fund-spend-too-much",
	})
	_expect(poor.reason == "insufficient_funds", "A spend above the balance is refused")
	_expect(host.world.farm.economy_cash(org_account) == cash_after,
		"An insufficient spend moves no cash")

	var replay: Dictionary = host.fund_for_member(PEER_B, "spend", {
		"fund_id": fund_id, "project_id": "village_square", "amount": 40,
		"command_id": "fund-spend-1",
	})
	_expect(replay.ok and replay.duplicate, "Retrying the spend replays its result")
	_expect(host.world.farm.economy_cash(org_account) == cash_after
		and host.world.farm.economy_cash(Economy.WORLD_OWNER) == world_after,
		"A spend replay moves no cash")
	var conflict: Dictionary = host.fund_for_member(PEER_B, "spend", {
		"fund_id": fund_id, "project_id": "village_square", "amount": 10,
		"command_id": "fund-spend-1",
	})
	_expect(conflict.reason == "command_conflict",
		"Reusing a spend command id with another amount conflicts")
	_expect(host.world.farm.economy_cash(org_account) == cash_after,
		"A spend conflict moves no cash")

	expect_ok(host.organization_for_member(PEER_A, "appoint", {
		"org_id": ORG, "player_id": PLAYER_B, "role": "member",
		"command_id": "org-demote-b-spend",
	}), "The leader demotes the officer")
	var demoted: Dictionary = host.fund_for_member(PEER_B, "spend", {
		"fund_id": fund_id, "project_id": "public_well", "amount": 5,
		"command_id": "fund-spend-demoted",
	})
	_expect(demoted.reason == "role_forbidden",
		"A keeper whose current role cannot spend is refused")
	_expect(host.world.farm.economy_cash(org_account) == cash_after,
		"A demoted keeper moves no cash")

	expect_ok(host.organization_for_member(PEER_B, "leave", {
		"org_id": ORG, "command_id": "org-leave-b-spend",
	}), "The demoted member leaves the organization")
	var left: Dictionary = host.fund_for_member(PEER_B, "spend", {
		"fund_id": fund_id, "project_id": "public_well", "amount": 5,
		"command_id": "fund-spend-left",
	})
	_expect(left.reason == "not_member",
		"A keeper who left the organization cannot spend")
	_expect(host.world.farm.economy_cash(org_account) == cash_after,
		"A former member moves no cash")


func _test_rotate_keeper(root_dir: String) -> void:
	var host: WorldHost = _open_host(root_dir.path_join("rotate"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_join(host, PEER_C, PLAYER_C, WorldInvite.MEMBER)
	_create_org(host, PEER_A, ORG, "河岸合作社", "rotate")
	expect_ok(host.organization_for_member(PEER_B, "join", {
		"org_id": ORG, "command_id": "org-join-b-rotate",
	}), "B joins the organization")
	_seed_actor(host, PLAYER_A)
	_seed_actor(host, PLAYER_B)
	_seed_actor(host, PLAYER_C)
	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	expect_ok(_open_fund(host, PEER_A, ORG, "fund-rotate-open"),
		"The leader opens the fund for the rotation checks")
	expect_ok(host.fund_for_member(PEER_B, "contribute", {
		"fund_id": fund_id, "amount": 10, "command_id": "fund-rotate-b-pay",
	}), "B contributes and becomes an eligible keeper")
	expect_ok(host.fund_for_member(PEER_C, "contribute", {
		"fund_id": fund_id, "amount": 5, "command_id": "fund-rotate-c-pay",
	}), "C contributes without joining the organization")

	var cash_before: int = host.world.farm.economy_cash(org_account)
	var total_before: int = host.world.farm.economy_total_cash()
	var outside: Dictionary = host.fund_for_member(PEER_A, "rotate", {
		"fund_id": fund_id, "new_keeper": PLAYER_C, "command_id": "fund-rotate-c",
	})
	_expect(outside.reason == "not_member",
		"A contributor outside the organization cannot become keeper")
	_expect(str(_fund(host.fund_for_member(PEER_A, "state", {}).state, fund_id).keeper)
		== PLAYER_A, "A refused rotation leaves the keeper unchanged")

	var rotated: Dictionary = host.fund_for_member(PEER_A, "rotate", {
		"fund_id": fund_id, "new_keeper": PLAYER_B, "command_id": "fund-rotate-b",
	})
	_expect(rotated.ok and str(rotated.action) == "rotate", "The keeper rotates")
	var row: Dictionary = _fund(rotated.state, fund_id)
	_expect(str(row.get("keeper", "")) == PLAYER_B, "The new keeper is recorded")
	_expect(int(row.get("balance", -1)) == 15, "Rotation does not change the balance")
	_expect(int(row.get("spent", -1)) == 0, "Rotation does not change spending")
	_expect(host.world.farm.economy_cash(org_account) == cash_before,
		"Rotation moves no cash")
	_expect(host.world.farm.economy_total_cash() == total_before,
		"Rotation preserves total cash")

	var replay: Dictionary = host.fund_for_member(PEER_A, "rotate", {
		"fund_id": fund_id, "new_keeper": PLAYER_B, "command_id": "fund-rotate-b",
	})
	_expect(replay.ok and replay.duplicate, "Retrying the rotation replays its result")
	var old_keeper: Dictionary = host.fund_for_member(PEER_A, "rotate", {
		"fund_id": fund_id, "new_keeper": PLAYER_B, "command_id": "fund-rotate-again",
	})
	_expect(old_keeper.reason == "not_keeper", "The former keeper cannot rotate again")
	var same: Dictionary = host.fund_for_member(PEER_B, "rotate", {
		"fund_id": fund_id, "new_keeper": PLAYER_B, "command_id": "fund-rotate-same",
	})
	_expect(same.reason == "same_keeper", "Rotating to the current keeper is refused")


func _test_restart_and_replay(root_dir: String) -> void:
	var directory: String = root_dir.path_join("restart")
	var host: WorldHost = _open_host(directory, START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_create_org(host, PEER_A, ORG, "河岸合作社", "restart")
	_seed_actor(host, PLAYER_A)
	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	expect_ok(_open_fund(host, PEER_A, ORG, "fund-restart-open"),
		"The fund is opened before the restart")
	var args: Dictionary = {
		"fund_id": fund_id, "amount": 50, "command_id": "fund-restart-1",
	}
	expect_ok(host.fund_for_member(PEER_A, "contribute", args),
		"The contribution is committed before the restart")
	var cash_paid: int = host.world.farm.economy_cash(PLAYER_A)

	var reopened: WorldHost = _open_host(directory, START + 100.0)
	_join(reopened, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	var view: Dictionary = reopened.fund_for_member(PEER_A, "state", {})
	var row: Dictionary = _fund(view.state, fund_id)
	_expect(view.ok and not row.is_empty(), "The fund exists after an authority restart")
	_expect(str(row.get("keeper", "")) == PLAYER_A
		and int(row.get("balance", -1)) == 50,
		"The keeper and balance survive the restart")
	var contributors: Dictionary = row.get("contributors", {}) as Dictionary
	_expect(int(contributors.get(PLAYER_A, -1)) == 50,
		"The contributor total survives the restart")
	_expect(reopened.world.farm.economy_cash(org_account) == 50,
		"The organization account cash survives the restart")
	_expect(_fund_balance_matches(reopened, fund_id),
		"Restart keeps the fund balance equal to the account cash")

	var replay: Dictionary = reopened.fund_for_member(PEER_A, "contribute", args)
	_expect(replay.ok and replay.duplicate,
		"A retry after restart replays through the ledger marker")
	_expect(reopened.world.farm.economy_cash(PLAYER_A) == cash_paid,
		"A restart retry charges no cash twice")
	_expect(reopened.world.farm.economy_cash(org_account) == 50,
		"A restart retry does not credit the organization twice")
	var conflict: Dictionary = reopened.fund_for_member(PEER_A, "contribute", {
		"fund_id": fund_id, "amount": 10, "command_id": "fund-restart-1",
	})
	_expect(conflict.reason == "command_conflict",
		"A restart retry with another amount conflicts")
	_expect(reopened.world.farm.economy_cash(org_account) == 50,
		"A restart conflict moves no cash")


func _test_paid_retry_recovers_fund_document(root_dir: String) -> void:
	var directory: String = root_dir.path_join("paid-retry")
	var host: WorldHost = _open_host(directory, START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_create_org(host, PEER_A, ORG, "河岸合作社", "paid-retry")
	_seed_actor(host, PLAYER_A)
	var fund_id: String = PublicFund.fund_for(ORG)
	var org_account: String = PublicFund.account_for(ORG)
	expect_ok(_open_fund(host, PEER_A, ORG, "fund-retry-open"),
		"The fund is opened for the recovery checks")
	var before_funds: Dictionary = host.world.funds.duplicate(true)
	var args: Dictionary = {
		"fund_id": fund_id, "amount": 40, "command_id": "fund-pay-retry",
	}
	expect_ok(host.fund_for_member(PEER_A, "contribute", args),
		"The contribution commits the farm side first")
	var cash_paid: int = host.world.farm.economy_cash(PLAYER_A)
	_expect(host.world.farm.economy_cash(org_account) == 40,
		"The farm side already holds the transfer")

	# Simulate "farm saved, fund document save failed" with a stale in-memory and
	# on-disk document, and with no in-memory replay window (an authority restart).
	host.world.funds = before_funds.duplicate(true)
	host.world._fund_results.clear()
	expect_ok(FundStore.new(directory).save_state(before_funds),
		"The simulated stale fund document is written")
	var recovered: Dictionary = host.fund_for_member(PEER_A, "contribute", args)
	_expect(recovered.ok and recovered.duplicate,
		"The paid retry completes the fund document")
	_expect(host.world.farm.economy_cash(PLAYER_A) == cash_paid,
		"The paid retry charges no cash twice")
	_expect(host.world.farm.economy_cash(org_account) == 40,
		"The paid retry does not credit the organization twice")
	_expect(int(_fund(recovered.state, fund_id).get("balance", -1)) == 40,
		"The recovered fund document carries the contribution")
	_expect(int(_stored(host).state.funds[fund_id].balance) == 40,
		"The recovered balance reaches the sidecar")

	host.world.funds = before_funds.duplicate(true)
	host.world._fund_results.clear()
	expect_ok(FundStore.new(directory).save_state(before_funds),
		"The stale document is restored for the conflict check")
	var conflict: Dictionary = host.fund_for_member(PEER_A, "contribute", {
		"fund_id": fund_id, "amount": 20, "command_id": "fund-pay-retry",
	})
	_expect(conflict.reason == "command_conflict",
		"The durable payment marker refuses a different amount")
	_expect(host.world.farm.economy_cash(org_account) == 40,
		"A marker conflict transfers nothing")

	# Restore the recovered fund document before exercising the spend recovery.
	var restored: Dictionary = host.fund_for_member(PEER_A, "contribute", args)
	_expect(restored.ok and restored.duplicate,
		"The contribution document is restored for the spend recovery")
	_expect(int(_fund(restored.state, fund_id).get("balance", -1)) == 40,
		"The restored fund holds the contribution before the spend")

	# Spend recovery: same idea, org account -> @world.
	var before_spend_funds: Dictionary = host.world.funds.duplicate(true)
	var world_before: int = host.world.farm.economy_cash(Economy.WORLD_OWNER)
	var spend_args: Dictionary = {
		"fund_id": fund_id, "project_id": "public_well", "amount": 15,
		"command_id": "fund-spend-retry",
	}
	expect_ok(host.fund_for_member(PEER_A, "spend", spend_args),
		"The spend commits the farm side first")
	_expect(host.world.farm.economy_cash(org_account) == 25,
		"The organization account already paid the spend")
	host.world.funds = before_spend_funds.duplicate(true)
	host.world._fund_results.clear()
	expect_ok(FundStore.new(directory).save_state(before_spend_funds),
		"The stale document is restored for the spend recovery")
	var recovered_spend: Dictionary = host.fund_for_member(PEER_A, "spend", spend_args)
	_expect(recovered_spend.ok and recovered_spend.duplicate,
		"The spend retry completes the fund document")
	_expect(host.world.farm.economy_cash(org_account) == 25
		and host.world.farm.economy_cash(Economy.WORLD_OWNER) == world_before + 15,
		"The spend retry moves no cash a second time")
	var spend_row: Dictionary = _fund(recovered_spend.state, fund_id)
	_expect(int(spend_row.get("balance", -1)) == 25
		and int(spend_row.get("spent", -1)) == 15,
		"The recovered spend row is consistent")
	var history: Array = _stored(host).state.funds[fund_id].history
	_expect(history.size() == 1 and int(history[0].amount) == 15,
		"The recovered spend records exactly one history row")


func _test_load_mismatch_refuses_startup(root_dir: String) -> void:
	var directory: String = root_dir.path_join("mismatch")
	var host: WorldHost = _open_host(directory, START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_create_org(host, PEER_A, ORG, "河岸合作社", "mismatch")
	_seed_actor(host, PLAYER_A)
	var fund_id: String = PublicFund.fund_for(ORG)
	expect_ok(_open_fund(host, PEER_A, ORG, "fund-mismatch-open"),
		"The fund is opened for the mismatch check")
	expect_ok(host.fund_for_member(PEER_A, "contribute", {
		"fund_id": fund_id, "amount": 25, "command_id": "fund-mismatch-1",
	}), "The contribution is committed before the mismatch")

	var tampered: Dictionary = host.world.funds.duplicate(true)
	tampered.funds[fund_id].balance = 30
	tampered.funds[fund_id].contributors[PLAYER_A] = 30
	_expect(PublicFund.valid(tampered), "The tampered fund document is still self-consistent")
	expect_ok(FundStore.new(directory).save_state(tampered),
		"The tampered fund document is written")
	var before: String = FileAccess.get_file_as_string(
		directory.path_join(FundStore.MAIN))
	var clean := WorldHost.new()
	root.add_child(clean)
	var opened: Dictionary = clean.configure(directory, START, WORLD)
	_expect(not opened.ok and str(opened.get("reason", "")) == "load_funds_mismatch",
		"A fund balance that disagrees with the organization account stops the authority")
	_expect(FileAccess.get_file_as_string(directory.path_join(FundStore.MAIN)) == before,
		"A mismatched fund document is not overwritten")


func _test_corrupt_and_unsupported(root_dir: String) -> void:
	var corrupt_dir: String = root_dir.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	var corrupt_path: String = corrupt_dir.path_join(FundStore.MAIN)
	_write(corrupt_path, JSON.stringify({"version": FundStore.VERSION, "state": {}}))
	var before: String = FileAccess.get_file_as_string(corrupt_path)
	var corrupt_host := WorldHost.new()
	root.add_child(corrupt_host)
	var corrupt_open: Dictionary = corrupt_host.configure(corrupt_dir, START, WORLD)
	_expect(not corrupt_open.ok and str(corrupt_open.get("reason", "")) == "load_funds_corrupt",
		"A corrupt fund document stops the authority")
	_expect(FileAccess.get_file_as_string(corrupt_path) == before,
		"A corrupt fund document is not overwritten")

	var unsupported_dir: String = root_dir.path_join("unsupported")
	DirAccess.make_dir_recursive_absolute(unsupported_dir)
	_write(unsupported_dir.path_join(FundStore.MAIN),
		JSON.stringify({"version": FundStore.VERSION + 1, "state": {"funds": {}}}))
	var unsupported_host := WorldHost.new()
	root.add_child(unsupported_host)
	_expect(str(unsupported_host.configure(unsupported_dir, START, WORLD).get("reason", ""))
		== "load_funds_unsupported",
		"An unsupported fund document version is refused")

	var direct := HeadlessWorld.new()
	var direct_missing: Dictionary = direct.open(root_dir.path_join("direct"), START)
	_expect(bool(direct_missing.get("ok", false)) and PublicFund.valid(direct.funds),
		"A direct headless world starts with an empty, valid fund table")
	_expect((direct.funds_view().get("funds", []) as Array).is_empty(),
		"A world that never opened a fund has an empty fund view")


func _test_permissions_and_view(root_dir: String) -> void:
	var host: WorldHost = _open_host(root_dir.path_join("permissions"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_VISITOR, PLAYER_C, WorldInvite.VISITOR)
	_join(host, PEER_ANONYMOUS, "", WorldInvite.MEMBER)
	_create_org(host, PEER_A, ORG, "河岸合作社", "permissions-a")
	_create_org(host, PEER_A, ORG_2, "河岸运输", "permissions-b")
	expect_ok(_open_fund(host, PEER_A, ORG, "fund-view-a"),
		"The first fund is opened for the view checks")
	expect_ok(_open_fund(host, PEER_A, ORG_2, "fund-view-b"),
		"The second fund is opened for the view checks")

	var view: Dictionary = host.fund_for_member(PEER_VISITOR, "state", {})
	_expect(view.ok, "A visitor may read the fund view")
	var rows: Array = view.state.get("funds", [])
	_expect(rows.size() == 2, "The view lists every fund")
	_expect(str(rows[0].get("fund_id", "")) == PublicFund.fund_for(ORG)
		and str(rows[1].get("fund_id", "")) == PublicFund.fund_for(ORG_2),
		"The view is sorted by fund id")
	_expect(not rows[0].has("history") and not rows[0].has("command_id"),
		"The view carries no history or command records")
	_expect(rows[0].has("contributors") and rows[0].has("balance")
		and rows[0].has("spent") and rows[0].has("keeper"),
		"The view carries the public cumulative fields")
	_expect(host.fund_for_member(PEER_ANONYMOUS, "state", {}).ok,
		"An anonymous member may read the fund view")
	_expect(host.fund_for_member(PEER_VISITOR, "open", {
		"org_id": ORG, "command_id": "fund-view-visitor",
	}).reason == "forbidden", "A visitor cannot write fund state")
	_expect(host.fund_for_member(PEER_ANONYMOUS, "open", {
		"org_id": ORG, "command_id": "fund-view-anonymous",
	}).reason == "no_player", "An anonymous member has no player identity to act as")
	_expect(host.fund_for_member(99, "state", {}).reason == "not_a_member",
		"A connection outside the roster is refused")
	_expect(host.fund_for_member(PEER_A, "march", {}).reason == "unknown_action",
		"An unknown fund action is refused")
	_expect(host.fund_for_member(PEER_A, "open", {
		"org_id": ORG, "command_id": "",
	}).reason == "invalid_command", "An empty command id is refused")

	host.read_only = true
	_expect(host.fund_for_member(PEER_A, "open", {
		"org_id": ORG_2, "command_id": "fund-view-read-only",
	}).reason == "read_only", "A retiring authority refuses fund writes")
	_expect(host.fund_for_member(PEER_A, "state", {}).ok,
		"A retiring authority still answers fund reads")
	host.read_only = false


func _test_write_time_copy(root_dir: String) -> void:
	var host: WorldHost = _open_host(root_dir.path_join("copy"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_C, PLAYER_C, WorldInvite.MEMBER)
	_create_org(host, PEER_A, ORG, "河岸合作社", "copy")
	var fund_id: String = PublicFund.fund_for(ORG)
	expect_ok(_open_fund(host, PEER_A, ORG, "fund-copy-open"),
		"The fund is opened for the write-time copy checks")
	var funds_before: String = JSON.stringify(host.world.funds)
	var farm_before: String = JSON.stringify(host.world.farm.snapshot())
	var stored_before: String = JSON.stringify(_stored(host).state)

	_expect(host.fund_for_member(PEER_A, "contribute", {
		"fund_id": "fund_missing", "amount": 10, "command_id": "fund-copy-unknown",
	}).reason == "unknown_fund", "An unknown fund is refused")
	_expect(JSON.stringify(host.world.funds) == funds_before,
		"An unknown-fund refusal does not mutate the live fund document")
	_expect(JSON.stringify(host.world.farm.snapshot()) == farm_before,
		"An unknown-fund refusal does not mutate the live farm")

	# C has no economy account, so this contribution cannot be paid.
	_expect(host.fund_for_member(PEER_C, "contribute", {
		"fund_id": fund_id, "amount": 10, "command_id": "fund-copy-poor",
	}).reason == "insufficient_cash", "A contribution without cash is refused")
	_expect(JSON.stringify(host.world.funds) == funds_before,
		"A failed contribution does not mutate the live fund document")
	_expect(JSON.stringify(host.world.farm.snapshot()) == farm_before,
		"A failed contribution does not mutate the live farm")

	_expect(host.fund_for_member(PEER_A, "rotate", {
		"fund_id": fund_id, "new_keeper": PLAYER_C, "command_id": "fund-copy-rotate",
	}).reason == "not_member", "A rotation to an outsider is refused")
	_expect(JSON.stringify(host.world.funds) == funds_before,
		"A failed rotation does not mutate the live fund document")
	_expect(JSON.stringify(_stored(host).state) == stored_before,
		"Refused writes leave the stored fund document untouched")


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


func _stored(host: WorldHost) -> Dictionary:
	return FundStore.new(host.world.directory).load_state()


## The invariant is checked on the authority's read-only view, so the test does
## not reach into the fund document or add a test-only world method.
func _fund_balance_matches(host: WorldHost, fund_id: String) -> bool:
	var row: Dictionary = _fund(host.world.funds_view(), fund_id)
	if row.is_empty():
		return false
	return int(row.get("balance", -1)) == host.world.farm.economy_cash(
		PublicFund.account_for(str(row.get("org_id", ""))))


func _fund(view: Variant, fund_id: String) -> Dictionary:
	if not view is Dictionary:
		return {}
	var rows: Variant = (view as Dictionary).get("funds")
	if not rows is Array:
		return {}
	for value: Variant in rows:
		if value is Dictionary and str((value as Dictionary).get("fund_id", "")) == fund_id:
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
