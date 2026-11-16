extends SceneTree
## M11-02 organization authority wiring: the pure membership/role rules are
## loaded, persisted and executed through the authoritative world.
##
## Covers: the organization sidecar round trip and strict key set, creation that
## survives a restart, idempotent replay by command id, connection identity (the
## actor is the joined player, never a payload field), non-member and role
## refusals, leadership handoff, leaving an organization, visitor/anonymous/
## read-only refusals, and corrupt/unsupported/unknown-key documents that stop
## the authority instead of being overwritten.
##
## No money, farm asset, land or building operation is exercised here: this
## slice owns members and positions only.
##
## Dissolution is covered through the authority: leader-only close, proportional
## refunds that move real cash out of the organization account, fund removal,
## idempotent retries, and both partial-write recovery windows.

const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const Organization = preload("res://world/organization_state.gd")
const OrganizationStore = preload("res://world/organization_store.gd")
const PublicFund = preload("res://world/public_fund.gd")
const FundStore = preload("res://world/fund_store.gd")

const START: float = 1800000000.0
const WORLD: String = "world-organization"
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const PLAYER_D: String = "player_00000000000000000000000000000004"
const PEER_A: int = 21
const PEER_B: int = 22
const PEER_C: int = 23
const PEER_D: int = 24
const PEER_VISITOR: int = 25
const PEER_ANONYMOUS: int = 26

var checks: int = 0
var failures: Array[String] = []
var root_dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root_dir = _repo().path_join(
		".local/verification/organization-authority-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(root_dir)
	_test_store_roundtrip()
	_test_create_restart_and_idempotent()
	_test_durable_command_replay()
	_test_document_budget_preflight()
	_test_permissions_and_handoff()
	_test_leave()
	_test_dissolve_and_refunds()
	_test_dissolve_recovery_windows()
	_test_dissolve_restart_recovery()
	_test_dissolve_refusals()
	_test_refusals_and_identity()
	_test_corrupt_unsupported_and_unknown()
	for failure: String in failures:
		push_error(failure)
	print("ORGANIZATION_AUTHORITY_TEST checks=%d failures=%d" % [
		checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_store_roundtrip() -> void:
	var store := OrganizationStore.new(root_dir.path_join("store"))
	_expect(OrganizationStore.MAX_BYTES == 65536, "The sidecar budget is 64 KiB")
	var missing: Dictionary = store.load_state()
	_expect(missing.ok and missing.kind == "missing",
		"A world without an organization document has an empty table")
	_expect(Organization.valid(missing.state), "The missing-document table is valid")

	var created: Dictionary = Organization.create(missing.state, "coop", "河岸合作社",
		PLAYER_A, START)
	_expect(created.ok, "A valid organization document can be produced for the store")
	var saved: Dictionary = store.save_state(created.state)
	_expect(saved.ok and saved.kind == "saved", "A valid organization table is written atomically")
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok and loaded.kind == "loaded", "The written organization table reloads")
	_expect(Organization.role_of(loaded.state, "coop", PLAYER_A) == Organization.ROLE_LEADER,
		"The stored leader survives the round trip")
	_expect(str(loaded.state.organizations.coop.name) == "河岸合作社",
		"The stored organization name survives the round trip")

	var unknown_key: Dictionary = created.state.duplicate(true)
	unknown_key["extra"] = true
	_expect(not store.save_state(unknown_key).ok,
		"An unknown top-level key is refused before it reaches the file")
	_expect(not store.save_state({"organizations": []}).ok,
		"A malformed organization table is refused")


func _test_create_restart_and_idempotent() -> void:
	var directory: String = root_dir.path_join("world")
	var host: WorldHost = _open_host(directory, START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)

	var create_args: Dictionary = {
		"org_id": "coop", "name": "河岸合作社", "command_id": "create-1",
		# Identity fields in the payload must never decide who acts.
		"actor": PLAYER_D, "owner": PLAYER_D,
	}
	var created: Dictionary = host.organization_for_member(PEER_A, "create", create_args)
	_expect(created.ok and created.action == "create",
		"A member creates an organization through the authority")
	var row: Dictionary = _row(created.state, "coop")
	_expect(not row.is_empty(), "The authoritative reply carries the new organization")
	_expect(str(row.get("name", "")) == "河岸合作社", "The reply carries the organization name")
	_expect(float(row.get("created_utc", -1.0)) >= START,
		"The authority stamps creation with its own clock")
	_expect(str((row.get("members", {}) as Dictionary).get(PLAYER_A, "")) \
		== Organization.ROLE_LEADER,
		"The joined creator becomes leader, not the payload's actor")
	_expect(not (row.get("members", {}) as Dictionary).has(PLAYER_D),
		"A payload actor/owner field does not become a member")
	_expect(str(host.world.organizations.organizations.coop.members[PLAYER_A]) \
		== Organization.ROLE_LEADER, "The live authority table holds the new leader")

	var replay: Dictionary = host.organization_for_member(PEER_A, "create", create_args)
	_expect(replay.ok and replay.duplicate,
		"Retrying the same command id replays the first result")
	_expect(_stored(host).kind == "loaded",
		"The accepted create is written to the sidecar immediately")
	_expect(host.organization_for_member(PEER_A, "create", {
		"org_id": "coop", "name": "另一个合作社", "command_id": "create-1",
	}).reason == "command_conflict",
		"Reusing a command id with a different payload is a conflict")
	_expect(host.organization_for_member(PEER_B, "create", {
		"org_id": "coop", "name": "另一个合作社", "command_id": "create-2",
	}).reason == "already_exists", "A new command id cannot create the same organization twice")

	var joined: Dictionary = host.organization_for_member(PEER_B, "join", {
		"org_id": "coop", "command_id": "join-b-1"})
	_expect(joined.ok and joined.action == "join", "A member joins the organization")
	_expect(str(host.world.organizations.organizations.coop.members[PLAYER_B]) \
		== Organization.ROLE_MEMBER, "A new member starts as an ordinary member")
	var join_replay: Dictionary = host.organization_for_member(PEER_B, "join", {
		"org_id": "coop", "command_id": "join-b-1"})
	_expect(join_replay.ok and join_replay.duplicate, "A join retry replays its first result")
	_expect(host.organization_for_member(PEER_B, "join", {
		"org_id": "coop", "command_id": "join-b-2"}).reason == "already_member",
		"A new command id cannot join twice")

	var reopened: WorldHost = _open_host(directory, START + 100.0)
	_join(reopened, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(reopened, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	var view: Dictionary = reopened.organization_for_member(PEER_A, "state", {})
	var reopened_row: Dictionary = _row(view.state, "coop")
	_expect(bool(view.get("ok", false)) and not reopened_row.is_empty(),
		"The organization exists after an authority restart")
	_expect(str((reopened_row.get("members", {}) as Dictionary).get(PLAYER_A, "")) \
		== Organization.ROLE_LEADER
		and str((reopened_row.get("members", {}) as Dictionary).get(PLAYER_B, "")) \
		== Organization.ROLE_MEMBER,
		"Members and positions survive the restart")
	_expect(float(reopened_row.get("created_utc", 0.0)) \
		== float(row.get("created_utc", -1.0)),
		"The creation time is not restamped on restart")
	var durable_create: Dictionary = reopened.organization_for_member(PEER_A, "create",
		create_args)
	_expect(durable_create.ok and durable_create.duplicate,
		"A create retry after restart replays through the durable command table")
	_expect(reopened.organization_for_member(PEER_A, "create", {
		"org_id": "coop", "name": "另一个合作社", "command_id": "create-1",
	}).reason == "command_conflict",
		"A durable command id with another payload conflicts after restart")
	var durable_join: Dictionary = reopened.organization_for_member(PEER_B, "join", {
		"org_id": "coop", "command_id": "join-b-1"})
	_expect(durable_join.ok and durable_join.duplicate,
		"A join retry after restart replays through the durable command table")


## 非解散命令跨重启重放：内存窗口已空，组织文档的 `commands` 表仍返回首次结果，
## 不会再次指派、交接或退出，也不会用旧指派覆盖之后的换届。
func _test_durable_command_replay() -> void:
	var directory: String = root_dir.path_join("durable-commands")
	var host: WorldHost = _open_host(directory, START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_join(host, PEER_C, PLAYER_C, WorldInvite.MEMBER)
	_create_org(host, PEER_A, "coop", "耐久组织", "durable")
	expect_ok(host.organization_for_member(PEER_B, "join", {
		"org_id": "coop", "command_id": "join-b"}), "The second member joins")
	expect_ok(host.organization_for_member(PEER_C, "join", {
		"org_id": "coop", "command_id": "join-c"}), "The third member joins")
	var appoint_args: Dictionary = {
		"org_id": "coop", "player_id": PLAYER_B, "role": Organization.ROLE_OFFICER,
		"command_id": "appoint-b",
	}
	expect_ok(host.organization_for_member(PEER_A, "appoint", appoint_args),
		"The durable appoint succeeds")
	var handoff_args: Dictionary = {
		"org_id": "coop", "player_id": PLAYER_B, "command_id": "handoff-b",
	}
	expect_ok(host.organization_for_member(PEER_A, "transfer_leadership",
		handoff_args), "The durable handoff succeeds")
	var leave_args: Dictionary = {"org_id": "coop", "command_id": "leave-c"}
	expect_ok(host.organization_for_member(PEER_C, "leave", leave_args),
		"The third member leaves")

	var reopened: WorldHost = _open_host(directory, START + 100.0)
	_join(reopened, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(reopened, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_join(reopened, PEER_C, PLAYER_C, WorldInvite.MEMBER)
	var before: String = JSON.stringify(reopened.world.organizations)
	var replay_appoint: Dictionary = reopened.organization_for_member(PEER_A, "appoint",
		appoint_args)
	_expect(replay_appoint.ok and replay_appoint.duplicate,
		"An appoint retry after restart replays the first result")
	_expect(str(reopened.world.organizations.organizations.coop.members[PLAYER_B]) \
		== Organization.ROLE_LEADER,
		"The appoint replay does not overwrite the later handoff")
	var replay_handoff: Dictionary = reopened.organization_for_member(PEER_A,
		"transfer_leadership", handoff_args)
	_expect(replay_handoff.ok and replay_handoff.duplicate,
		"A handoff retry after restart replays the first result")
	var replay_leave: Dictionary = reopened.organization_for_member(PEER_C, "leave",
		leave_args)
	_expect(replay_leave.ok and replay_leave.duplicate,
		"A leave retry after restart replays the first result")
	_expect(JSON.stringify(reopened.world.organizations) == before,
		"Replayed organization commands leave the document byte-identical")
	var conflict: Dictionary = reopened.organization_for_member(PEER_A, "appoint", {
		"org_id": "coop", "player_id": PLAYER_C,
		"role": Organization.ROLE_MEMBER, "command_id": "appoint-b",
	})
	_expect(conflict.reason == "command_conflict",
		"A durable command id with another payload conflicts after restart")
	_expect(JSON.stringify(reopened.world.organizations) == before,
		"A command conflict leaves the document byte-identical")

	# 解散记录占用的 id 不能被另一个组织的非解散命令复用。
	expect_ok(reopened.organization_for_member(PEER_B, "create", {
		"org_id": "coop2", "name": "第二组织", "command_id": "create-coop2"}),
		"The cross-table organization is created")
	expect_ok(reopened.organization_for_member(PEER_B, "dissolve", {
		"org_id": "coop2", "command_id": "diss-shared"}),
		"The cross-table organization is dissolved with its own id")
	expect_ok(reopened.organization_for_member(PEER_B, "create", {
		"org_id": "coop3", "name": "第三组织", "command_id": "create-coop3"}),
		"The third organization is created")
	var cross: Dictionary = reopened.organization_for_member(PEER_C, "join", {
		"org_id": "coop3", "command_id": "diss-shared"})
	_expect(cross.reason == "command_conflict",
		"A dissolve command id cannot be reused by an action command")
	_expect(not (reopened.world.organizations.organizations.coop3.members as Dictionary) \
		.has(PLAYER_C), "The cross-table conflict joins nobody")


func _test_permissions_and_handoff() -> void:
	var host: WorldHost = _open_host(root_dir.path_join("permissions"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_join(host, PEER_C, PLAYER_C, WorldInvite.MEMBER)
	_join(host, PEER_D, PLAYER_D, WorldInvite.MEMBER)
	_expect(host.organization_for_member(PEER_A, "create", {
		"org_id": "guild", "name": "河岸商会", "command_id": "g-create"}).ok,
		"The leader creates the organization")
	for member: Array in [[PEER_B, "g-join-b"], [PEER_C, "g-join-c"]]:
		_expect(host.organization_for_member(int(member[0]), "join", {
			"org_id": "guild", "command_id": str(member[1])}).ok,
			"A second and third player join the organization")

	_expect(host.organization_for_member(PEER_D, "appoint", {
		"org_id": "guild", "player_id": PLAYER_C, "role": Organization.ROLE_OFFICER,
		"command_id": "d-appoint"}).reason == "not_member",
		"A connected non-member cannot appoint anyone")
	_expect(host.organization_for_member(PEER_A, "appoint", {
		"org_id": "guild", "player_id": PLAYER_D, "role": Organization.ROLE_OFFICER,
		"command_id": "a-appoint-d"}).reason == "target_not_member",
		"An appointment requires an existing member target")
	_expect(host.organization_for_member(PEER_A, "appoint", {
		"org_id": "guild", "player_id": PLAYER_B, "role": "owner",
		"command_id": "a-appoint-bad-role"}).reason == "invalid_role",
		"An unknown role is refused")

	var appointed: Dictionary = host.organization_for_member(PEER_A, "appoint", {
		"org_id": "guild", "player_id": PLAYER_B, "role": Organization.ROLE_OFFICER,
		"command_id": "a-appoint-b"})
	_expect(appointed.ok, "The leader appoints an officer")
	_expect(appointed.duplicate == false, "A first appointment is not a duplicate")
	_expect(str(host.world.organizations.organizations.guild.members[PLAYER_B]) \
		== Organization.ROLE_OFFICER, "The appointed member holds the officer role")
	_expect(host.organization_for_member(PEER_B, "appoint", {
		"org_id": "guild", "player_id": PLAYER_C, "role": Organization.ROLE_OFFICER,
		"command_id": "b-appoint-c"}).reason == "role_forbidden",
		"An officer cannot manage positions")
	_expect(host.organization_for_member(PEER_A, "appoint", {
		"org_id": "guild", "player_id": PLAYER_B, "role": Organization.ROLE_LEADER,
		"command_id": "a-appoint-leader"}).reason == "leader_requires_transfer",
		"Leadership cannot be granted by appointment")

	var transfer: Dictionary = host.organization_for_member(PEER_A, "transfer_leadership", {
		"org_id": "guild", "player_id": PLAYER_B, "command_id": "a-transfer-b"})
	_expect(transfer.ok, "The leader hands leadership to a member")
	_expect(str(host.world.organizations.organizations.guild.members[PLAYER_A]) \
		== Organization.ROLE_MEMBER
		and str(host.world.organizations.organizations.guild.members[PLAYER_B]) \
		== Organization.ROLE_LEADER, "The handoff swaps the two positions")
	_expect(str(host.world.organizations.organizations.guild.account_id) == "org_guild",
		"The organization account identity does not change with the leader")
	_expect(host.organization_for_member(PEER_A, "appoint", {
		"org_id": "guild", "player_id": PLAYER_C, "role": Organization.ROLE_OFFICER,
		"command_id": "a-appoint-after"}).reason == "role_forbidden",
		"The former leader loses the right to appoint")
	var new_leader_appoints: Dictionary = host.organization_for_member(PEER_B, "appoint", {
		"org_id": "guild", "player_id": PLAYER_C, "role": Organization.ROLE_OFFICER,
		"command_id": "b-appoint-after"})
	_expect(new_leader_appoints.ok, "The new leader can appoint")
	_expect(host.organization_for_member(PEER_A, "transfer_leadership", {
		"org_id": "guild", "player_id": PLAYER_C, "command_id": "a-transfer-again"}).reason \
		== "not_leader", "The former leader cannot hand leadership off again")
	_expect(host.organization_for_member(PEER_B, "transfer_leadership", {
		"org_id": "guild", "player_id": PLAYER_B, "command_id": "b-transfer-self"}).reason \
		== "same_leader", "A leader cannot hand leadership to themselves")
	_expect(host.organization_for_member(PEER_B, "transfer_leadership", {
		"org_id": "guild", "player_id": PLAYER_D, "command_id": "b-transfer-d"}).reason \
		== "target_not_member", "A non-member cannot receive leadership")

	# A refused operation leaves the live document exactly as it was.
	var before: Dictionary = host.world.organizations.duplicate(true)
	_expect(host.organization_for_member(PEER_A, "appoint", {
		"org_id": "guild", "player_id": PLAYER_C, "role": Organization.ROLE_OFFICER,
		"command_id": "a-refused-copy"}).reason == "role_forbidden",
		"A role refusal is named")
	_expect(host.world.organizations == before,
		"A refused operation does not mutate the authority's live table")


func _test_leave() -> void:
	var host: WorldHost = _open_host(root_dir.path_join("leave"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	expect_ok(host.organization_for_member(PEER_A, "create", {
		"org_id": "coop", "name": "河岸合作社", "command_id": "l-create"}),
		"The organization exists for the leave checks")
	expect_ok(host.organization_for_member(PEER_B, "join", {
		"org_id": "coop", "command_id": "l-join-b"}), "The second member joins")

	var left: Dictionary = host.organization_for_member(PEER_B, "leave", {
		"org_id": "coop", "command_id": "l-leave-b"})
	_expect(left.ok, "A non-leader member may leave")
	_expect(not (host.world.organizations.organizations.coop.members as Dictionary)
		.has(PLAYER_B), "The departed member is removed")
	_expect(host.organization_for_member(PEER_B, "leave", {
		"org_id": "coop", "command_id": "l-leave-again"}).reason == "not_member",
		"A departed member cannot leave again")
	_expect(host.organization_for_member(PEER_B, "appoint", {
		"org_id": "coop", "player_id": PLAYER_A, "role": Organization.ROLE_OFFICER,
		"command_id": "l-appoint-after"}).reason == "not_member",
		"A departed member cannot operate on the organization")
	_expect(host.organization_for_member(PEER_A, "leave", {
		"org_id": "coop", "command_id": "l-leader-leave"}).reason == "last_member",
		"The last remaining member cannot leave the organization")

	expect_ok(host.organization_for_member(PEER_B, "join", {
		"org_id": "coop", "command_id": "l-rejoin-b"}), "The player may join again")
	_expect(host.organization_for_member(PEER_A, "leave", {
		"org_id": "coop", "command_id": "l-leader-leave-2"}).reason \
		== "leader_must_transfer", "A leader with other members must transfer first")
	_expect(host.organization_for_member(PEER_B, "leave", {
		"org_id": "coop", "command_id": "l-leave-b"}).ok,
		"A replayed leave id after a rejoin replays its first accepted result")
	var sole: Dictionary = host.organization_for_member(PEER_A, "create", {
		"org_id": "solo", "name": "单人组织", "command_id": "l-create-solo"})
	_expect(sole.ok, "A second organization has one member")
	_expect(host.organization_for_member(PEER_A, "leave", {
		"org_id": "solo", "command_id": "l-sole-leave"}).reason \
		in ["last_member", "leader_must_transfer"],
		"The sole member cannot leave an organization")


## Test doubles for the two partial-write windows a dissolve has to survive.
class FailingOrganizationStore extends OrganizationStore:
	func save_state(_state: Dictionary) -> Dictionary:
		return {"ok": false, "kind": "io"}


class FailingFundStore extends FundStore:
	func save_state(_state: Dictionary, _pending: Dictionary = {}) -> Dictionary:
		return {"ok": false, "kind": "io"}


## 第一次保存（解散意图）成功、第二次（关闭组织）失败：模拟退款已落盘而关闭
## 文档没写完的真实窗口。
class FailingSecondOrganizationStore extends OrganizationStore:
	var saves: int = 0

	func save_state(state: Dictionary) -> Dictionary:
		saves += 1
		if saves >= 2:
			return {"ok": false, "kind": "io"}
		return super.save_state(state)


## 解散意图已经落盘、退款农场保存失败：现金尚未移动，重启必须按意图退款一次。
class FailingFarmStore extends "res://farm/farm_store.gd":
	func save_state(_farm: RefCounted, _decorations: RefCounted) -> Dictionary:
		return {"ok": false, "kind": "io"}


func _test_dissolve_and_refunds() -> void:
	var directory: String = root_dir.path_join("dissolve")
	var host: WorldHost = _open_host(directory, START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_join(host, PEER_C, PLAYER_C, WorldInvite.MEMBER)
	_create_org(host, PEER_A, "guild", "河岸合作社", "dissolve")
	expect_ok(host.organization_for_member(PEER_B, "join", {
		"org_id": "guild", "command_id": "d-join-b"}),
		"B joins the dissolving organization")
	_seed_actor(host, PLAYER_A)
	_seed_actor(host, PLAYER_B)
	var fund_id: String = PublicFund.fund_for("guild")
	var account: String = PublicFund.account_for("guild")
	expect_ok(host.fund_for_member(PEER_A, "open", {
		"org_id": "guild", "command_id": "d-fund-open"}), "The leader opens the fund")
	expect_ok(host.fund_for_member(PEER_A, "contribute", {
		"fund_id": fund_id, "amount": 30, "command_id": "d-fund-a"}),
		"A contributes 30")
	expect_ok(host.fund_for_member(PEER_B, "contribute", {
		"fund_id": fund_id, "amount": 90, "command_id": "d-fund-b"}),
		"B contributes 90")
	expect_ok(host.fund_for_member(PEER_A, "spend", {
		"fund_id": fund_id, "amount": 40, "project_id": "shop",
		"command_id": "d-fund-spend"}), "The leader spends 40")
	_expect(host.world.farm.economy_cash(account) == 80,
		"The organization account holds the unspent balance")

	var cash_a: int = host.world.farm.economy_cash(PLAYER_A)
	var cash_b: int = host.world.farm.economy_cash(PLAYER_B)
	var refused: Dictionary = host.organization_for_member(PEER_B, "dissolve", {
		"org_id": "guild", "command_id": "d-dissolve-b"})
	_expect(refused.reason == "not_leader",
		"Only the leader may dissolve the organization")
	_expect(host.world.farm.economy_cash(account) == 80,
		"A refused dissolve moves no cash")

	var dissolved: Dictionary = host.organization_for_member(PEER_A, "dissolve", {
		"org_id": "guild", "command_id": "d-dissolve-a"})
	_expect(dissolved.ok and not dissolved.duplicate,
		"The leader dissolves the organization")
	var clearing: Dictionary = dissolved.get("clearing", {})
	_expect(int(clearing.get("balance", -1)) == 80,
		"The clearing intent names the refunded balance")
	var refunds: Array = clearing.get("refunds", [])
	_expect(refunds.size() == 2, "Both contributors appear in the refund table")
	if refunds.size() == 2:
		_expect(str(refunds[0].player_id) == PLAYER_A and int(refunds[0].amount) == 20,
			"A is refunded its proportional share")
		_expect(str(refunds[1].player_id) == PLAYER_B and int(refunds[1].amount) == 60,
			"B is refunded its proportional share")
	_expect(host.world.farm.economy_cash(PLAYER_A) == cash_a + 20,
		"The refund reaches A's real account")
	_expect(host.world.farm.economy_cash(PLAYER_B) == cash_b + 60,
		"The refund reaches B's real account")
	_expect(host.world.farm.economy_cash(account) == 0,
		"The organization account is emptied")
	_expect((host.world.funds_view().funds as Array).is_empty(),
		"The fund disappears from the authoritative view")
	_expect((_funds_stored(directory).get("funds", {}) as Dictionary).is_empty(),
		"The fund sidecar no longer holds the closed organization")
	var row: Dictionary = _row(dissolved.state, "guild")
	_expect(str(row.get("status", "")) == Organization.STATUS_CLOSED,
		"The organization view reports the closed status")
	_expect(float(row.get("closed_utc", 0.0)) >= START,
		"The close carries the authority clock")
	_expect(host.organization_for_member(PEER_C, "join", {
		"org_id": "guild", "command_id": "d-join-closed"}).reason == "org_closed",
		"A closed organization refuses new members")

	var replay: Dictionary = host.organization_for_member(PEER_A, "dissolve", {
		"org_id": "guild", "command_id": "d-dissolve-a"})
	_expect(replay.ok and replay.duplicate,
		"Retrying the dissolve command replays the first result")
	_expect(host.world.farm.economy_cash(PLAYER_A) == cash_a + 20,
		"The replay pays no second refund")
	_expect(host.organization_for_member(PEER_A, "dissolve", {
		"org_id": "guild", "command_id": "d-dissolve-again"}).reason == "already_closed",
		"A second dissolve command is refused")

	var reopened: WorldHost = _open_host(directory, START + 60.0)
	var reopened_row: Dictionary = _row(reopened.organization_for_member(
		PEER_A, "state", {}).state, "guild")
	_expect(str(reopened_row.get("status", "")) == Organization.STATUS_CLOSED,
		"The closed status survives a restart")
	_expect((reopened.world.funds_view().funds as Array).is_empty(),
		"The fund stays removed after a restart")
	_expect(reopened.world.farm.economy_cash(PLAYER_A) == cash_a + 20,
		"The refunds survive a restart")


func _test_dissolve_recovery_windows() -> void:
	# 组织文档第一次写失败（解散意图没落盘）：退款与关闭都还没开始，重试按普通
	# 解散路径完成，只退一次。
	var directory: String = root_dir.path_join("dissolve-org-save")
	var host: WorldHost = _open_host(directory, START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_create_org(host, PEER_A, "coop2", "河岸合作社", "rec-org")
	_seed_actor(host, PLAYER_A)
	expect_ok(host.fund_for_member(PEER_A, "open", {
		"org_id": "coop2", "command_id": "rec-open"}), "The recovery fund opens")
	expect_ok(host.fund_for_member(PEER_A, "contribute", {
		"fund_id": PublicFund.fund_for("coop2"), "amount": 50,
		"command_id": "rec-contribute"}), "The recovery fund holds 50")
	var args: Dictionary = {"org_id": "coop2", "command_id": "rec-dissolve"}
	var cash_before: int = host.world.farm.economy_cash(PLAYER_A)
	host.world.organizations_store = FailingOrganizationStore.new(directory)
	var failed: Dictionary = host.organization_for_member(PEER_A, "dissolve", args)
	_expect(not failed.ok and str(failed.reason).begins_with("save_organizations_"),
		"A failed organization write reports the sidecar")
	_expect(host.world.farm.economy_cash(PublicFund.account_for("coop2")) == 50,
		"A failed intent write moves no refund")
	_expect(host.world.farm.economy_cash(PLAYER_A) == cash_before,
		"A failed intent write leaves contributor cash unchanged")
	host.world.organizations_store = OrganizationStore.new(directory)
	var recovered: Dictionary = host.organization_for_member(PEER_A, "dissolve", args)
	_expect(recovered.ok, "Retrying completes the organization and fund documents")
	_expect(host.world.farm.economy_cash(PLAYER_A) == cash_before + 50,
		"The retry refunds exactly once")
	_expect((host.world.funds_view().funds as Array).is_empty(),
		"The retried dissolve removes the fund row")
	_expect(str(_stored(host).state.organizations.coop2.status)
		== Organization.STATUS_CLOSED, "The organization is closed on disk")

	# 基金文档写失败：组织已关闭、基金行仍在。重试只移除基金行，不再退款。
	var hole_dir: String = root_dir.path_join("dissolve-fund-save")
	var hole: WorldHost = _open_host(hole_dir, START)
	_join(hole, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_create_org(hole, PEER_A, "coop3", "河岸合作社", "hole")
	_seed_actor(hole, PLAYER_A)
	var hole_fund: String = PublicFund.fund_for("coop3")
	expect_ok(hole.fund_for_member(PEER_A, "open", {
		"org_id": "coop3", "command_id": "hole-open"}), "The failing fund opens")
	expect_ok(hole.fund_for_member(PEER_A, "contribute", {
		"fund_id": hole_fund, "amount": 40, "command_id": "hole-contribute"}),
		"The failing fund holds 40")
	hole.world.funds_store = FailingFundStore.new(hole_dir)
	var hole_args: Dictionary = {"org_id": "coop3", "command_id": "hole-dissolve"}
	var stuck: Dictionary = hole.organization_for_member(PEER_A, "dissolve", hole_args)
	_expect(not stuck.ok and str(stuck.reason).begins_with("save_funds_"),
		"A failed fund write reports the sidecar")
	_expect(not (hole.world.funds_view().funds as Array).is_empty(),
		"The stale fund row is still live after the failed write")
	var cash_after: int = hole.world.farm.economy_cash(PLAYER_A)
	hole.world.funds_store = FundStore.new(hole_dir)
	var closed: Dictionary = hole.organization_for_member(PEER_A, "dissolve", hole_args)
	_expect(closed.ok and closed.duplicate,
		"Retrying only finishes the fund removal")
	_expect((hole.world.funds_view().funds as Array).is_empty(),
		"The retried dissolve removes the fund row")
	_expect(hole.world.farm.economy_cash(PLAYER_A) == cash_after,
		"The retried dissolve pays no second refund")

	# 农场写失败：解散意图已落盘、退款还没发生。重启按意图退款一次并完成关闭。
	var farm_dir: String = root_dir.path_join("dissolve-farm-save")
	var farm_host: WorldHost = _open_host(farm_dir, START)
	_join(farm_host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_create_org(farm_host, PEER_A, "coop4", "河岸合作社", "farm-org")
	_seed_actor(farm_host, PLAYER_A)
	var farm_account: String = PublicFund.account_for("coop4")
	expect_ok(farm_host.fund_for_member(PEER_A, "open", {
		"org_id": "coop4", "command_id": "farm-open"}), "The farm-save fund opens")
	expect_ok(farm_host.fund_for_member(PEER_A, "contribute", {
		"fund_id": PublicFund.fund_for("coop4"), "amount": 30,
		"command_id": "farm-contribute"}), "The farm-save fund holds 30")
	var farm_cash: int = farm_host.world.farm.economy_cash(PLAYER_A)
	farm_host.world.store = FailingFarmStore.new(farm_dir)
	var farm_failed: Dictionary = farm_host.organization_for_member(PEER_A, "dissolve", {
		"org_id": "coop4", "command_id": "farm-dissolve"})
	_expect(not farm_failed.ok and str(farm_failed.reason) == "save_io",
		"A failed farm write reports the refund save")
	_expect(farm_host.world.farm.economy_cash(farm_account) == 30,
		"The failed farm write moved no refund cash")
	_expect(farm_host.world.organizations.pending_dissolves.has("coop4"),
		"The intent is already durable when the refund fails")
	var farm_reopened := HeadlessWorld.new()
	_expect(bool(farm_reopened.open(farm_dir, START + 60.0, WORLD, PLAYER_A)
		.get("ok", false)), "A world with an unpaid intent reopens")
	_expect(farm_reopened.farm.economy_cash(PLAYER_A) == farm_cash + 30,
		"Loading pays the intent refund exactly once")
	_expect(farm_reopened.farm.economy_cash(farm_account) == 0,
		"The intent refund empties the organization account")
	_expect(not _has_fund_row(farm_reopened.funds_view(), "coop4"),
		"Loading removes the fund row of the completed intent")
	var farm_again := HeadlessWorld.new()
	_expect(bool(farm_again.open(farm_dir, START + 120.0, WORLD, PLAYER_A)
		.get("ok", false)), "The intent-repaired world reopens cleanly")


## 退款已落盘、组织关闭文档没写完：解散意图与账户现金足以在进程内或重启后
## 完成，不依赖随时会被淘汰的账本分录；完成过程不二次付款。
func _test_dissolve_restart_recovery() -> void:
	# 同一进程内：意图写成功、关闭写失败，负责人换一个命令 id 重试补完。
	var live_dir: String = root_dir.path_join("dissolve-intent-live")
	var live: WorldHost = _open_host(live_dir, START)
	_join(live, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_create_org(live, PEER_A, "live_org", "河岸合作社", "li-org")
	_seed_actor(live, PLAYER_A)
	var live_account: String = PublicFund.account_for("live_org")
	expect_ok(live.fund_for_member(PEER_A, "open", {
		"org_id": "live_org", "command_id": "li-open"}),
		"The intent-live fund opens")
	expect_ok(live.fund_for_member(PEER_A, "contribute", {
		"fund_id": PublicFund.fund_for("live_org"), "amount": 50,
		"command_id": "li-contribute"}), "The intent-live fund holds 50")
	var live_cash: int = live.world.farm.economy_cash(PLAYER_A)
	live.world.organizations_store = FailingSecondOrganizationStore.new(live_dir)
	var interrupted: Dictionary = live.organization_for_member(PEER_A, "dissolve", {
		"org_id": "live_org", "command_id": "li-dissolve-1"})
	_expect(not interrupted.ok
			and str(interrupted.reason) == "save_organizations_io",
		"The closing organization write fails after the refund")
	_expect(live.world.farm.economy_cash(live_account) == 0,
		"The interrupted attempt refunded the fund before the closing write")
	_expect(live.world.farm.economy_cash(PLAYER_A) == live_cash + 50,
		"The interrupted attempt paid one refund")
	var stored_intent: Dictionary = _stored(live).state
	_expect(stored_intent.has(Organization.PENDING_DISSOLVES_KEY)
			and (stored_intent.pending_dissolves as Dictionary).has("live_org"),
		"The refunded attempt leaves a durable dissolve intent")
	_expect(_has_fund_row(live.world.funds_view(), "live_org"),
		"The fund row stays until the intent completes")
	var blocked: Dictionary = live.world.execute_fund("contribute", PLAYER_A, {
		"fund_id": PublicFund.fund_for("live_org"), "amount": 5}, "li-late")
	_expect(not blocked.ok and str(blocked.reason) == "pending_dissolve",
		"Fund operations are blocked while the intent is unfinished")
	live.world.organizations_store = OrganizationStore.new(live_dir)
	var finished: Dictionary = live.organization_for_member(PEER_A, "dissolve", {
		"org_id": "live_org", "command_id": "li-dissolve-2"})
	_expect(finished.ok and not finished.duplicate,
		"A new command id completes the interrupted dissolve")
	_expect(live.world.farm.economy_cash(PLAYER_A) == live_cash + 50,
		"The completing command pays no second refund")
	_expect(not _has_fund_row(live.world.funds_view(), "live_org"),
		"The completed intent removes the fund row")
	_expect(not _stored(live).state.has(Organization.PENDING_DISSOLVES_KEY),
		"The completed intent is cleared from the organization document")
	_expect(str((live.world.organizations_view().organizations as Array)[0].status)
		== Organization.STATUS_CLOSED, "The organization is closed after retry")

	# 重启且退款分录已淘汰：意图与账户现金 0 仍能完成退款语义，不重复转账。
	var org_dir: String = root_dir.path_join("dissolve-restart-org")
	var host: WorldHost = _open_host(org_dir, START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_create_org(host, PEER_A, "restart_org", "河岸合作社", "rr-org")
	_seed_actor(host, PLAYER_A)
	var org_account: String = PublicFund.account_for("restart_org")
	expect_ok(host.fund_for_member(PEER_A, "open", {
		"org_id": "restart_org", "command_id": "rr-open"}),
		"The restart-org fund opens")
	expect_ok(host.fund_for_member(PEER_A, "contribute", {
		"fund_id": PublicFund.fund_for("restart_org"), "amount": 60,
		"command_id": "rr-contribute"}), "The restart-org fund holds 60")
	var restart_cash: int = host.world.farm.economy_cash(PLAYER_A)
	host.world.organizations_store = FailingSecondOrganizationStore.new(org_dir)
	var failed: Dictionary = host.organization_for_member(PEER_A, "dissolve", {
		"org_id": "restart_org", "command_id": "rr-dissolve-1"})
	_expect(not failed.ok, "The interrupted organization write fails")
	_expect(host.world.farm.economy_cash(org_account) == 0,
		"The interrupted attempt already refunded the fund")

	# 只读快照：意图补完只在内存里发生，磁盘上的组织与基金文档原样保留。
	var copy_dir: String = root_dir.path_join("dissolve-intent-copy")
	_copy_dir(org_dir, copy_dir)
	var org_path: String = copy_dir.path_join("organizations.json")
	var funds_path: String = copy_dir.path_join("funds.json")
	var org_before: PackedByteArray = FileAccess.get_file_as_bytes(org_path)
	var funds_before: PackedByteArray = FileAccess.get_file_as_bytes(funds_path)
	var read_only := HeadlessWorld.new()
	_expect(bool(read_only.open(copy_dir, START + 60.0, WORLD, PLAYER_A, true)
		.get("ok", false)), "A read-only world with a pending intent opens")
	_expect(not _has_fund_row(read_only.funds_view(), "restart_org"),
		"The read-only world removes the fund row in memory")
	_expect(str((read_only.organizations_view().organizations as Array)[0].status)
		== Organization.STATUS_CLOSED,
		"The read-only world completes the closure in memory")
	_expect(FileAccess.get_file_as_bytes(org_path) == org_before
			and FileAccess.get_file_as_bytes(funds_path) == funds_before,
		"Read-only intent recovery writes no document")

	_evict_ledger_entries(org_dir)
	var reopened := HeadlessWorld.new()
	var opened: Dictionary = reopened.open(org_dir, START + 60.0, WORLD, PLAYER_A)
	_expect(bool(opened.get("ok", false)),
		"A world stopped after the refund opens instead of load_funds_mismatch")
	_expect(reopened.farm.economy_cash(PLAYER_A) == restart_cash + 60,
		"The reopened world keeps exactly one refund")
	_expect(not _has_fund_row(reopened.funds_view(), "restart_org"),
		"Loading the intent completes the fund removal")
	_expect(str((reopened.organizations_view().organizations as Array)[0].status)
		== Organization.STATUS_CLOSED, "Loading the intent closes the organization")
	var again: Dictionary = reopened.execute_organization("dissolve", PLAYER_A, {
		"org_id": "restart_org"}, "rr-dissolve-2")
	_expect(not again.ok and str(again.reason) == "already_closed",
		"A later dissolve command finds the organization already closed")
	var reopened_again := HeadlessWorld.new()
	_expect(bool(reopened_again.open(org_dir, START + 120.0, WORLD, PLAYER_A)
		.get("ok", false)), "The repaired world reopens cleanly")

	# 基金文档写失败：磁盘上是「农场已退款、组织已关闭、基金行仍在」。
	var fund_dir: String = root_dir.path_join("dissolve-restart-fund")
	var hole: WorldHost = _open_host(fund_dir, START)
	_join(hole, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_create_org(hole, PEER_A, "restart_fund", "河岸合作社", "rf-org")
	_seed_actor(hole, PLAYER_A)
	expect_ok(hole.fund_for_member(PEER_A, "open", {
		"org_id": "restart_fund", "command_id": "rf-open"}),
		"The restart-fund fund opens")
	expect_ok(hole.fund_for_member(PEER_A, "contribute", {
		"fund_id": PublicFund.fund_for("restart_fund"), "amount": 40,
		"command_id": "rf-contribute"}), "The restart-fund fund holds 40")
	hole.world.funds_store = FailingFundStore.new(fund_dir)
	var stuck: Dictionary = hole.organization_for_member(PEER_A, "dissolve", {
		"org_id": "restart_fund", "command_id": "rf-dissolve-1"})
	_expect(not stuck.ok, "The interrupted fund write fails")
	_expect(str(_stored(hole).state.organizations.restart_fund.status)
		== Organization.STATUS_CLOSED,
		"The organization document was already closed before the fund write")
	var late: Dictionary = hole.world.execute_fund("contribute", PLAYER_A, {
		"fund_id": PublicFund.fund_for("restart_fund"), "amount": 5}, "rf-late")
	_expect(not late.ok and str(late.reason) == "org_closed",
		"A closed organization refuses contributions before reload")

	# 退役/只读快照：补完在内存里完成，不动磁盘上的基金文档。
	var snapshot_dir: String = root_dir.path_join("dissolve-restart-copy")
	_copy_dir(fund_dir, snapshot_dir)
	var snapshot_funds_path: String = snapshot_dir.path_join("funds.json")
	var snapshot_funds: PackedByteArray = FileAccess.get_file_as_bytes(snapshot_funds_path)
	var read_only_world := HeadlessWorld.new()
	_expect(bool(read_only_world.open(snapshot_dir, START + 60.0, WORLD, PLAYER_A, true)
		.get("ok", false)), "A read-only world with a stale fund row opens")
	_expect((read_only_world.funds_view().funds as Array).is_empty(),
		"The read-only world removes the stale row in memory")
	_expect(FileAccess.get_file_as_bytes(snapshot_funds_path) == snapshot_funds,
		"Read-only recovery writes no document")

	# 有界账本淘汰退款分录后，已关闭组织的补完仍不依赖分录。
	_evict_ledger_entries(snapshot_dir)
	var evicted := HeadlessWorld.new()
	_expect(bool(evicted.open(snapshot_dir, START + 60.0, WORLD, PLAYER_A).get("ok", false)),
		"An evicted refund entry no longer blocks a closed-org recovery")
	_expect((evicted.funds_view().funds as Array).is_empty(),
		"The closed-org recovery removes the row without ledger evidence")
	_expect(evicted.farm.economy_cash(PLAYER_A) == 120,
		"The refunded cash is unchanged by the recovery")

	var fund_reopened := HeadlessWorld.new()
	var fund_opened: Dictionary = fund_reopened.open(
		fund_dir, START + 60.0, WORLD, PLAYER_A)
	_expect(bool(fund_opened.get("ok", false)),
		"A world with a stale fund row after closure reopens")
	_expect((fund_reopened.funds_view().funds as Array).is_empty(),
		"Loading finishes the closure by removing the stale fund row")
	var fund_finished: Dictionary = fund_reopened.execute_organization(
		"dissolve", PLAYER_A, {"org_id": "restart_fund"}, "rf-dissolve-2")
	_expect(not fund_finished.ok and str(fund_finished.reason) == "already_closed",
		"A later dissolve command finds the organization already closed")
	_expect(fund_reopened.farm.economy_cash(PLAYER_A) == 120,
		"Finishing the fund removal pays no second refund")
	var fund_reopened_again := HeadlessWorld.new()
	_expect(bool(fund_reopened_again.open(
		fund_dir, START + 120.0, WORLD, PLAYER_A).get("ok", false)),
		"The fund-repaired world reopens cleanly")

	# 零余额基金行在基金写失败后同样不锁死启动：加载直接移除。
	var zero_dir: String = root_dir.path_join("dissolve-restart-zero")
	var zero: WorldHost = _open_host(zero_dir, START)
	_join(zero, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_create_org(zero, PEER_A, "restart_zero", "河岸合作社", "rz-org")
	_seed_actor(zero, PLAYER_A)
	expect_ok(zero.fund_for_member(PEER_A, "open", {
		"org_id": "restart_zero", "command_id": "rz-open"}),
		"The empty restart fund opens")
	zero.world.funds_store = FailingFundStore.new(zero_dir)
	var zero_stuck: Dictionary = zero.organization_for_member(PEER_A, "dissolve", {
		"org_id": "restart_zero", "command_id": "rz-dissolve-1"})
	_expect(not zero_stuck.ok, "The zero-balance fund write fails")
	var zero_reopened := HeadlessWorld.new()
	_expect(bool(zero_reopened.open(zero_dir, START + 60.0, WORLD, PLAYER_A)
		.get("ok", false)), "The zero-balance world reopens")
	_expect((zero_reopened.funds_view().funds as Array).is_empty(),
		"The zero-balance stale row is removed on load")

	# 别人拿已成功的解散命令 id 重发：不获得清算摘要。
	var peer_dir: String = root_dir.path_join("dissolve-foreign-replay")
	var peer_host: WorldHost = WorldHost.new()
	root.add_child(peer_host)
	peer_host.configure(peer_dir, START, WORLD)
	_join(peer_host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(peer_host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_create_org(peer_host, PEER_A, "replay_org", "河岸合作社", "rp-org")
	expect_ok(peer_host.organization_for_member(PEER_B, "join", {
		"org_id": "replay_org", "command_id": "rp-join"}), "B joins the replay org")
	_seed_actor(peer_host, PLAYER_A)
	expect_ok(peer_host.fund_for_member(PEER_A, "open", {
		"org_id": "replay_org", "command_id": "rp-open"}), "The replay fund opens")
	var foreign: Dictionary = peer_host.organization_for_member(PEER_B, "dissolve", {
		"org_id": "replay_org", "command_id": "rp-dissolve"})
	_expect(not foreign.ok and str(foreign.reason) == "not_leader",
		"A non-leader cannot dissolve the organization")
	expect_ok(peer_host.organization_for_member(PEER_A, "dissolve", {
		"org_id": "replay_org", "command_id": "rp-dissolve"}),
		"The leader dissolves the replay org")
	# 重启清空内存重放窗口后，命令 id 又由已关闭组织的历史记录补完；非负责人
	# 不能借这个入口拿到清算摘要。
	var replay_world := HeadlessWorld.new()
	_expect(bool(replay_world.open(peer_dir, START + 60.0, WORLD, PLAYER_A)
		.get("ok", false)), "The replay world reopens")
	var replay: Dictionary = replay_world.execute_organization("dissolve", PLAYER_B, {
		"org_id": "replay_org"}, "rp-dissolve")
	_expect(not replay.ok and str(replay.reason) == "not_leader",
		"A non-leader cannot replay someone else's dissolve command")


## 关闭候选超过存储上限时必须在写意图与退款之前拒绝；否则退款已付、组织文档
## 永远写不下，组织与基金都会卡在半完成状态。
func _test_document_budget_preflight() -> void:
	var directory: String = root_dir.path_join("budget")
	var host: WorldHost = _open_host(directory, START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_B, PLAYER_B, WorldInvite.MEMBER)
	_create_org(host, PEER_A, "coop", "预算组织", "budget")
	var loaded: Dictionary = OrganizationStore.new(directory).load_state()
	_expect(loaded.ok, "The budget fixture organization loads")
	var state: Dictionary = loaded.state
	var history: Array = state.organizations.coop.history
	while history.size() < Organization.MAX_HISTORY - 1:
		history.append({"kind": Organization.HISTORY_JOINED, "actor": PLAYER_B,
			"target": "", "at_utc": START + float(history.size()) * 0.1})
	var result: Dictionary = {
		"ok": true, "reason": "", "action": "join", "org_id": "coop",
		"duplicate": false,
	}
	# 自校准：找到一份现在能落盘、但解散后的关闭候选超限的文档。命令 id 越
	# 长文档越大；从短到长递增，第一次出现“当前能装下、关闭后装不下”时选它，
	# 避免写死依赖当前 JSON 排版的具体字节数。
	var chosen: Dictionary = {}
	for length: int in range(Organization.MAX_COMMAND_ID_LENGTH - 3):
		var candidate: Dictionary = state.duplicate(true)
		var long_id: String = "🌾".repeat(length)
		for index: int in Organization.MAX_COMMANDS:
			candidate = Organization.remember_command(candidate,
				long_id + "%03d" % index, "payload-%d" % index, result)
		if not OrganizationStore.fits(candidate):
			break
		var preview: Dictionary = Organization.dissolve(candidate, "coop", PLAYER_A,
			START + 100.0, {
				"command_id": "budget-preview", "balance": 0, "pending_spend": 0,
				"contributors": {},
			})
		if bool(preview.get("ok", false)) \
				and not OrganizationStore.fits(preview.state):
			chosen = candidate
			break
	_expect(not chosen.is_empty(),
		"A document exists that fits before dissolution but not after it")
	_expect(Organization.valid(chosen),
		"The near-limit fixture is still a valid organization document")
	_write(directory.path_join(OrganizationStore.MAIN),
		JSON.stringify({"version": OrganizationStore.VERSION, "state": chosen}, "\t"))

	var reopened: WorldHost = _open_host(directory, START + 100.0)
	_join(reopened, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	var before: String = FileAccess.get_file_as_string(
		directory.path_join(OrganizationStore.MAIN))
	var refused: Dictionary = reopened.organization_for_member(PEER_A, "dissolve", {
		"org_id": "coop", "command_id": "budget-dissolve"})
	_expect(not refused.ok and refused.reason == "document_too_large",
		"An oversized close candidate is refused before the intent")
	_expect(FileAccess.get_file_as_string(directory.path_join(OrganizationStore.MAIN)) \
		== before, "The refused dissolve leaves the organization document untouched")
	_expect(str(reopened.world.organizations.organizations.coop.status) \
		== Organization.STATUS_ACTIVE,
		"The refused dissolve keeps the organization active")


func _test_dissolve_refusals() -> void:
	var directory: String = root_dir.path_join("dissolve-refusals")
	var host: WorldHost = _open_host(directory, START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_VISITOR, "", WorldInvite.VISITOR)
	_create_org(host, PEER_A, "mixed", "河岸合作社", "refusal")
	_seed_actor(host, PLAYER_A)
	var fund_id: String = PublicFund.fund_for("mixed")
	var account: String = PublicFund.account_for("mixed")
	expect_ok(host.fund_for_member(PEER_A, "open", {
		"org_id": "mixed", "command_id": "ref-open"}), "The refusal fund opens")
	expect_ok(host.fund_for_member(PEER_A, "contribute", {
		"fund_id": fund_id, "amount": 20, "command_id": "ref-contribute"}),
		"The refusal fund holds 20")

	# 账面余额高于真实现金：只能说明退款已经付过一小部分后又对不上，拒绝并保持
	# 现金不动，而不是按旧账再付一次。
	host.world.funds.funds[fund_id].balance = 21
	var mismatch: Dictionary = host.organization_for_member(PEER_A, "dissolve", {
		"org_id": "mixed", "command_id": "ref-mismatch"})
	_expect(mismatch.reason == "balance_mismatch",
		"A drifted fund balance refuses the dissolve")
	_expect(host.world.farm.economy_cash(account) == 20,
		"A drifted dissolve moves no cash")
	host.world.funds.funds[fund_id].balance = 20

	_expect(host.organization_for_member(PEER_VISITOR, "dissolve", {
		"org_id": "mixed", "command_id": "ref-visitor"}).reason == "forbidden",
		"A visitor cannot dissolve an organization")
	host.read_only = true
	_expect(host.organization_for_member(PEER_A, "dissolve", {
		"org_id": "mixed", "command_id": "ref-readonly"}).reason == "read_only",
		"A read-only authority refuses dissolve")
	host.read_only = false

	_create_org(host, PEER_A, "bare", "空组织", "ref-bare")
	var bare: Dictionary = host.organization_for_member(PEER_A, "dissolve", {
		"org_id": "bare", "command_id": "ref-bare-dissolve"})
	_expect(bare.ok, "An organization without a fund still dissolves")
	_expect(((bare.get("clearing", {}) as Dictionary).get("refunds", []) as Array) \
		.is_empty(), "It returns an empty refund table")


func _test_refusals_and_identity() -> void:
	var host: WorldHost = _open_host(root_dir.path_join("refusals"), START)
	_join(host, PEER_A, PLAYER_A, WorldInvite.MEMBER)
	_join(host, PEER_VISITOR, PLAYER_C, WorldInvite.VISITOR)
	_join(host, PEER_ANONYMOUS, "", WorldInvite.MEMBER)

	expect_ok(host.organization_for_member(PEER_A, "create", {
		"org_id": "coop", "name": "河岸合作社", "command_id": "r-create"}),
		"The named member creates the organization")
	_expect(host.organization_for_member(PEER_VISITOR, "create", {
		"org_id": "visitor", "name": "访客组织", "command_id": "r-visitor"}).reason \
		== "forbidden", "A visitor cannot create an organization")
	_expect(host.organization_for_member(PEER_VISITOR, "state", {}).ok,
		"A visitor may still read the organization view")
	_expect(host.organization_for_member(PEER_ANONYMOUS, "create", {
		"org_id": "anon", "name": "匿名组织", "command_id": "r-anon"}).reason \
		== "no_player", "An anonymous member has no player identity to act as")
	_expect(host.organization_for_member(99, "state", {}).reason == "not_a_member",
		"A connection outside the roster is refused")
	_expect(host.organization_for_member(PEER_A, "sell", {
		"org_id": "coop", "command_id": "r-unknown"}).reason == "unknown_action",
		"An unknown organization action is refused")
	_expect(host.organization_for_member(PEER_A, "create", {
		"org_id": "coop", "name": "河岸合作社", "command_id": ""}).reason \
		== "invalid_command", "An empty command id is refused")
	_expect(host.organization_for_member(PEER_A, "create", {
		"org_id": "ctl", "name": "控制字符", "command_id": "r-ctl\u0001"}).reason \
		== "invalid_command",
		"A command id with a control character is refused before execution")
	_expect(not host.world.organizations.organizations.has("ctl"),
		"The refused control-character command creates nothing")
	_expect(host.organization_for_member(PEER_A, "create", {
		"org_id": "bad org", "name": "无效组织", "command_id": "r-bad-org"}).reason \
		== "invalid_org", "An illegal organization id is refused")
	_expect(host.organization_for_member(PEER_A, "create", {
		"org_id": "other", "name": "  ", "command_id": "r-bad-name"}).reason \
		== "invalid_name", "An illegal organization name is refused")
	_expect(host.organization_for_member(PEER_A, "join", {
		"org_id": "missing", "command_id": "r-missing"}).reason == "unknown_org",
		"An unknown organization is refused")

	host.read_only = true
	_expect(host.organization_for_member(PEER_A, "create", {
		"org_id": "retired", "name": "只读组织", "command_id": "r-read-only"}).reason \
		== "read_only", "A retiring authority refuses organization writes")
	_expect(host.organization_for_member(PEER_A, "state", {}).ok,
		"A retiring authority still answers organization reads")
	host.read_only = false


func _test_corrupt_unsupported_and_unknown() -> void:
	var corrupt_dir: String = root_dir.path_join("corrupt")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	var corrupt_path: String = corrupt_dir.path_join(OrganizationStore.MAIN)
	_write(corrupt_path, JSON.stringify({"version": OrganizationStore.VERSION,
		"state": {"organizations": {"coop": {}}}}))
	var before: String = FileAccess.get_file_as_string(corrupt_path)
	var corrupt_host := WorldHost.new()
	root.add_child(corrupt_host)
	var opened: Dictionary = corrupt_host.configure(corrupt_dir, START, WORLD)
	_expect(not opened.ok and str(opened.reason) == "load_organizations_corrupt",
		"A corrupt organization document stops the authority")
	_expect(FileAccess.get_file_as_string(corrupt_path) == before,
		"A corrupt organization document is not overwritten by an empty table")

	var unsupported_dir: String = root_dir.path_join("unsupported")
	DirAccess.make_dir_recursive_absolute(unsupported_dir)
	_write(unsupported_dir.path_join(OrganizationStore.MAIN),
		JSON.stringify({"version": OrganizationStore.VERSION + 1, "state": {}}))
	var unsupported_host := WorldHost.new()
	root.add_child(unsupported_host)
	_expect(str(unsupported_host.configure(unsupported_dir, START, WORLD).get("reason", "")) \
		== "load_organizations_unsupported",
		"An unsupported organization document version is refused")

	var unknown_dir: String = root_dir.path_join("unknown-key")
	DirAccess.make_dir_recursive_absolute(unknown_dir)
	var unknown_path: String = unknown_dir.path_join(OrganizationStore.MAIN)
	_write(unknown_path, JSON.stringify({"version": OrganizationStore.VERSION,
		"state": {"organizations": {}, "extra": 1}}))
	var unknown_before: String = FileAccess.get_file_as_string(unknown_path)
	var unknown_host := WorldHost.new()
	root.add_child(unknown_host)
	_expect(str(unknown_host.configure(unknown_dir, START, WORLD).get("reason", "")) \
		== "load_organizations_corrupt",
		"An unknown top-level key is rejected as a corrupt organization document")
	_expect(FileAccess.get_file_as_string(unknown_path) == unknown_before,
		"A strict-validity failure is not overwritten")

	var direct := HeadlessWorld.new()
	var direct_missing: Dictionary = direct.open(root_dir.path_join("direct"), START)
	_expect(bool(direct_missing.get("ok", false)) and Organization.valid(direct.organizations),
		"A direct headless world starts with an empty, valid organization table")


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
	return OrganizationStore.new(host.world.directory).load_state()


func _funds_stored(directory: String) -> Dictionary:
	var loaded: Dictionary = FundStore.new(directory).load_state()
	var state: Variant = loaded.get("state", {})
	return state if state is Dictionary else {}


## Opens the actor's real economy account so contributions move actual cash.
func _seed_actor(host: WorldHost, player_id: String) -> void:
	expect_ok(host.world.farm.economy_open_account("seed-account-" + player_id,
		player_id, START), "%s has a real cash account" % player_id)


func _create_org(host: WorldHost, peer: int, org_id: String, name: String,
		suffix: String) -> void:
	expect_ok(host.organization_for_member(peer, "create", {
		"org_id": org_id, "name": name, "command_id": "org-create-" + suffix,
	}), "The organization %s is created" % org_id)


func _row(view: Variant, org_id: String) -> Dictionary:
	if not view is Dictionary:
		return {}
	var organizations: Variant = (view as Dictionary).get("organizations")
	if not organizations is Array:
		return {}
	for value: Variant in organizations:
		if value is Dictionary and str((value as Dictionary).get("id", "")) == org_id:
			return value
	return {}


func _has_fund_row(view: Dictionary, org_id: String) -> bool:
	var rows: Variant = view.get("funds")
	if not rows is Array:
		return false
	for value: Variant in rows:
		if value is Dictionary and str((value as Dictionary).get("org_id", "")) == org_id:
			return true
	return false


func _copy_dir(from_dir: String, to_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(to_dir)
	var dir := DirAccess.open(from_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			DirAccess.copy_absolute(from_dir.path_join(entry), to_dir.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()


## 把现有账本分录折进 opening 后清空 entries：余额不变、事件证据消失，等价于
## 512 条环形记录淘汰掉旧退款分录。只用于构造“证据已淘汰”的重启夹具。
func _evict_ledger_entries(directory: String) -> void:
	var path: String = directory.path_join("farm.json")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not data is Dictionary:
		return
	var farm_doc: Variant = (data as Dictionary).get("farm")
	if not farm_doc is Dictionary:
		return
	var economy: Variant = (farm_doc as Dictionary).get("economy")
	if not economy is Dictionary:
		return
	var ledger: Variant = (economy as Dictionary).get("ledger")
	if not ledger is Dictionary:
		return
	var opening: Variant = (ledger as Dictionary).get("opening")
	var entries: Variant = (ledger as Dictionary).get("entries")
	if not opening is Dictionary or not entries is Dictionary:
		return
	for entry_value: Variant in (entries as Dictionary).values():
		if not entry_value is Dictionary:
			continue
		var lines: Variant = (entry_value as Dictionary).get("lines", [])
		if not lines is Array:
			continue
		for line_value: Variant in lines:
			if not line_value is Dictionary:
				continue
			var code: String = str((line_value as Dictionary).get("account", ""))
			(opening as Dictionary)[code] = int((opening as Dictionary).get(code, 0)) \
				+ int((line_value as Dictionary).get("debit", 0)) \
				- int((line_value as Dictionary).get("credit", 0))
	(ledger as Dictionary)["entries"] = {}
	file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(data))
	file.close()


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
