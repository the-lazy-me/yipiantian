extends SceneTree
## M10-04 居民邀约持久化与裁决的权威测试。无头、隔离：临时目录写在
## `.local/verification` 下，使用真实 `HeadlessWorld`、真实 `residents.json`
## sidecar 与既有 `NpcInvitation` / `NpcSocialMemory` 规则。
##
## 覆盖：
##   - 默认关闭时不创建 sidecar，也不产生邀约；
##   - 社交阶段选中 invite 时创建 pending，且不立即写关系或资产；
##   - 被邀请方在下一次结算按关系/人格确定性接受或拒绝，双方记忆各写当事人；
##   - 到期只转 expired，不写记忆、不授予资产；
##   - 同一 act id / 邀约重放不产生第二条邀约或第二次裁决；
##   - 重启后 pending、冷却与 command id 仍在；
##   - 信封容量 64 条、旧四键文档兼容、world_id 不符与损坏形状拒绝启动；
##   - 视图新增 pending_invitations 与 last_invitation，且不含 command_id。

const World = preload("res://world/headless_world.gd")
const ResidentsStore = preload("res://world/residents_store.gd")
const NatureStore = preload("res://farm/nature_store.gd")
const EconomyCatalog = preload("res://farm/economy_catalog.gd")
const NpcRoster = preload("res://npc/npc_roster.gd")
const NpcPersonality = preload("res://npc/npc_personality.gd")
const NpcInvitation = preload("res://npc/npc_invitation.gd")
const NpcSocial = preload("res://npc/npc_social.gd")
const NpcSocialMemory = preload("res://npc/npc_social_memory.gd")
const NpcMemory = preload("res://npc/npc_memory.gd")
const Market = preload("res://farm/market_state.gd")

const START: float = 1800060000.0
const AT: float = START + 10.0
const DECIDED_AT: float = AT + 400.0
const SEED: int = 42017
const RULES_VERSION: int = 2
const WORLD_ID: String = "resident-invitation-authority"
const HOST: String = "resident_invitation_host"
const VIEWER: String = "player_00000000000000000000000000000301"
const INVITER: String = NpcRoster.NPC_XU_BO
const RECIPIENT: String = NpcRoster.NPC_A_ZHOU
const BYSTANDER: String = NpcRoster.NPC_LIN_SHEN
const ACTION_CAP: int = 4
const INVITATION_KIND: String = NpcInvitation.KIND_VISIT
const PENDING_KEYS: Array[String] = [
	"id", "from", "to", "kind", "created_utc", "expires_utc", "status",
	"command_id",
]
const DECIDED_KEYS: Array[String] = [
	"id", "from", "to", "kind", "created_utc", "expires_utc", "status",
	"decided_utc", "reason", "command_id",
]
const VIEW_KEYS: Array[String] = ["from", "to", "status", "created_utc"]

var checks: int = 0
var failures: Array[String] = []
var base_root: String = ""


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	base_root = project_root.get_base_dir().path_join(
		".local/verification/resident-invitation-authority-%d-%d"
		% [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(base_root)
	_run()
	for failure: String in failures:
		push_error(failure)
	print("RESIDENT_INVITATION_AUTHORITY_TEST checks=%d failures=%d"
		% [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _run() -> void:
	_test_disabled_writes_nothing()
	_test_create_pending_view_and_no_assets()
	_test_accept_decision_and_memory()
	_test_decline_decision_and_memory()
	_test_expiry_writes_no_memory()
	_test_replay_same_command_and_decision()
	_test_restart_keeps_pending_and_cooldown()
	_test_capacity_and_legacy_document()
	_test_world_mismatch_and_corrupt_refused()


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

func _test_disabled_writes_nothing() -> void:
	var directory: String = base_root.path_join("disabled")
	var closed := World.new()
	var opened: Dictionary = closed.open(directory, START, WORLD_ID, HOST)
	_expect(bool(opened.ok), "disabled: the world opens: "
		+ str(opened.get("reason", "")))
	_expect(not closed.residents_enabled, "disabled: residents start disabled")
	var view: Dictionary = closed.residents_view(VIEWER)
	_expect(str(view.get("reason", "")) == "disabled",
		"disabled: the view reports disabled")
	_expect((view.get("residents", []) as Array).is_empty(),
		"disabled: no resident rows are exposed")
	var settled: Dictionary = closed.settle_residents(AT)
	_expect(str(settled.get("reason", "")) == "disabled",
		"disabled: the sweep reports disabled")
	_expect((closed.resident_invitations as Dictionary).is_empty(),
		"disabled: the in-memory invitation table stays empty")
	_expect(not FileAccess.file_exists(directory.path_join("residents.json")),
		"disabled: no sidecar is written")
	closed.settle_economy_now(AT)
	_expect(not FileAccess.file_exists(directory.path_join("residents.json")),
		"disabled: the economy sweep writes no sidecar either")


func _test_create_pending_view_and_no_assets() -> void:
	var directory: String = base_root.path_join("create")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	# 先让经济账户开户与既有社交稳定，再强制邀约，才能单独断言“创建邀约不移动
	# 资产”。
	var warm: Dictionary = world.settle_residents(AT - 500.0)
	_expect(bool(warm.ok), "create: the warm-up sweep succeeds: "
		+ str(warm.get("reason", "")))
	_force_invite(world, INVITER, RECIPIENT, AT)
	var relation_before: String = _relation_snapshot(world, INVITER)
	var memory_before: int = _memory_entries(world, INVITER).size()
	var assets_before: Dictionary = _assets(world)
	var settled: Dictionary = world.settle_residents(AT)
	_expect(bool(settled.ok), "create: the sweep succeeds: "
		+ str(settled.get("reason", "")))
	_expect(bool(settled.get("changed", false)), "create: the sweep reports a change")
	var rows: Dictionary = world.resident_invitations
	_expect(rows.size() == 1, "create: exactly one invitation is created")
	if rows.size() != 1:
		return
	var invitation_id: String = str(rows.keys()[0])
	var row: Dictionary = rows[invitation_id]
	_expect(_pending_shape_ok(row), "create: the pending row has the strict shape")
	_expect(str(row.from) == INVITER and str(row.to) == RECIPIENT,
		"create: the invitation carries the planner's from/to")
	_expect(str(row.kind) == INVITATION_KIND,
		"create: the invitation kind is the fixed visit kind")
	_expect(is_equal_approx(float(row.created_utc), AT),
		"create: the invitation is stamped at the settlement instant")
	_expect(is_equal_approx(float(row.expires_utc),
			AT + float(NpcInvitation.TTL_SECONDS[INVITATION_KIND])),
		"create: the invitation uses the rule TTL")
	_expect(str(row.status) == NpcInvitation.STATUS_PENDING,
		"create: the invitation starts pending")
	var expected: Dictionary = NpcInvitation.propose(
		NpcInvitation.empty_document(), {
			"from": INVITER, "to": RECIPIENT, "kind": INVITATION_KIND,
		}, AT)
	_expect(bool(expected.ok), "create: the expected id derives from the rules")
	if bool(expected.ok):
		_expect(invitation_id == str(expected.invitation.id),
			"create: the persisted id is the deterministic rule id")
	_expect(invitation_id == str(expected.invitation.id),
		"create: the persisted id is the deterministic rule id")
	_expect(not str(row.command_id).is_empty(),
		"create: the creating act id is persisted")
	_expect(ResidentsStore.valid_invitations(rows),
		"create: the persisted invitation table is strictly valid")
	_expect(_relation_snapshot(world, INVITER) == relation_before,
		"create: creating an invitation does not write the relation document")
	_expect(_memory_entries(world, INVITER).size() == memory_before,
		"create: a pending invitation writes no memory")
	_expect(JSON.stringify(_assets(world)) == JSON.stringify(assets_before),
		"create: creating an invitation moves no asset")
	_expect(_invitation_memory_ids(world, invitation_id).is_empty(),
		"create: no party has a decision memory for a pending invitation")
	_expect(bool(world.farm.economy_reconcile().ok),
		"create: the ledger still reconciles")

	var view: Dictionary = world.residents_view(VIEWER)
	var inviter_view: Dictionary = _view_row(view, INVITER)
	var recipient_view: Dictionary = _view_row(view, RECIPIENT)
	var bystander_view: Dictionary = _view_row(view, BYSTANDER)
	_expect(int(inviter_view.get("pending_invitations", -1)) == 1,
		"view: the inviter counts one pending invitation")
	_expect(int(recipient_view.get("pending_invitations", -1)) == 1,
		"view: the recipient counts one pending invitation")
	_expect(int(bystander_view.get("pending_invitations", -1)) == 0,
		"view: an uninvolved resident counts none")
	var expected_view: Dictionary = {
		"from": INVITER, "to": RECIPIENT,
		"status": NpcInvitation.STATUS_PENDING, "created_utc": AT,
	}
	_expect(JSON.stringify(inviter_view.get("last_invitation", {}))
			== JSON.stringify(expected_view),
		"view: the inviter sees the latest invitation without free text")
	_expect(JSON.stringify(recipient_view.get("last_invitation", {}))
			== JSON.stringify(expected_view),
		"view: the recipient sees the same latest invitation")
	_expect((bystander_view.get("last_invitation", {}) as Dictionary).is_empty(),
		"view: the bystander sees no invitation")
	_expect(not JSON.stringify(view).contains("command_id"),
		"view: command ids are not exposed")


func _test_accept_decision_and_memory() -> void:
	var directory: String = base_root.path_join("accept")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	_force_invite(world, INVITER, RECIPIENT, AT)
	var created: Dictionary = world.settle_residents(AT)
	_expect(bool(created.ok), "accept: the creation sweep succeeds")
	var invitation_id: String = _only_invitation(world)
	_expect(not invitation_id.is_empty(), "accept: an invitation was created")
	if invitation_id.is_empty():
		return
	# 被邀请方对发起人的 affinity 极高，确定性规则必须接受。
	world.resident_social.relations[RECIPIENT][INVITER].affinity = 100
	_cool_down(world.resident_social, INVITER, AT)
	_cool_down(world.resident_social, RECIPIENT, AT)
	var assets_before: Dictionary = _assets(world)
	var settled: Dictionary = world.settle_residents(DECIDED_AT)
	_expect(bool(settled.ok), "accept: the decision sweep succeeds: "
		+ str(settled.get("reason", "")))
	var row: Dictionary = world.resident_invitations[invitation_id]
	_expect(_decided_shape_ok(row), "accept: the decided row has the strict shape")
	_expect(str(row.status) == NpcInvitation.STATUS_ACCEPTED,
		"accept: the recipient accepts under the deterministic rule")
	_expect(is_equal_approx(float(row.decided_utc), DECIDED_AT),
		"accept: decided_utc is the decision settlement instant")
	_expect(str(row.reason) == NpcInvitation.STATUS_ACCEPTED,
		"accept: reason is fixed to the status")
	_expect(JSON.stringify(_assets(world)) == JSON.stringify(assets_before),
		"accept: accepting an invitation moves no asset")
	_expect(bool(world.farm.economy_reconcile().ok),
		"accept: the ledger still reconciles")

	var memory_id: String = NpcSocialMemory.memory_id(
		"invitation", invitation_id, RECIPIENT)
	var recipient_entries: Dictionary = _memory_entries(world, RECIPIENT)
	_expect(recipient_entries.has(memory_id),
		"accept: the recipient remembers accepting")
	if recipient_entries.has(memory_id):
		_expect(str(recipient_entries[memory_id].summary).contains("接受了"),
			"accept: the recipient memory names the accepted invitation")
	_expect(not _memory_entries(world, INVITER).has(memory_id),
		"accept: the initiator does not receive the recipient's memory row")
	_expect(NpcMemory.valid_document(world.resident_memories, DECIDED_AT),
		"accept: the memory document is still valid")
	_expect(ResidentsStore.valid_invitations(world.resident_invitations),
		"accept: the invitation table is still valid")

	var view: Dictionary = world.residents_view(VIEWER)
	var inviter_view: Dictionary = _view_row(view, INVITER)
	var recipient_view: Dictionary = _view_row(view, RECIPIENT)
	_expect(int(inviter_view.get("pending_invitations", -1)) == 0,
		"accept: the inviter no longer counts a pending invitation")
	_expect(int(recipient_view.get("pending_invitations", -1)) == 0,
		"accept: the recipient no longer counts a pending invitation")
	_expect(str((inviter_view.get("last_invitation", {}) as Dictionary).get(
			"status", "")) == NpcInvitation.STATUS_ACCEPTED,
		"accept: the view shows the accepted status to the inviter")
	_expect(_view_invitation_keys_ok(inviter_view),
		"accept: the view invitation keeps only the four public fields")


func _test_decline_decision_and_memory() -> void:
	var directory: String = base_root.path_join("decline")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	_force_invite(world, INVITER, RECIPIENT, AT)
	var created: Dictionary = world.settle_residents(AT)
	_expect(bool(created.ok), "decline: the creation sweep succeeds")
	var invitation_id: String = _only_invitation(world)
	_expect(not invitation_id.is_empty(), "decline: an invitation was created")
	if invitation_id.is_empty():
		return
	world.resident_social.relations[RECIPIENT][INVITER].affinity = -100
	_cool_down(world.resident_social, INVITER, AT)
	_cool_down(world.resident_social, RECIPIENT, AT)
	var assets_before: Dictionary = _assets(world)
	var settled: Dictionary = world.settle_residents(DECIDED_AT)
	_expect(bool(settled.ok), "decline: the decision sweep succeeds: "
		+ str(settled.get("reason", "")))
	var row: Dictionary = world.resident_invitations[invitation_id]
	_expect(str(row.status) == NpcInvitation.STATUS_DECLINED,
		"decline: a hostile recipient declines under the deterministic rule")
	_expect(str(row.reason) == NpcInvitation.STATUS_DECLINED,
		"decline: reason is fixed to the declined status")
	_expect(JSON.stringify(_assets(world)) == JSON.stringify(assets_before),
		"decline: declining an invitation moves no asset")
	var memory_id: String = NpcSocialMemory.memory_id(
		"invitation", invitation_id, INVITER)
	var initiator_entries: Dictionary = _memory_entries(world, INVITER)
	_expect(initiator_entries.has(memory_id),
		"decline: the initiator remembers being declined")
	if initiator_entries.has(memory_id):
		_expect(str(initiator_entries[memory_id].summary).contains("拒绝"),
			"decline: the initiator memory names the rejection")
	_expect(not _memory_entries(world, RECIPIENT).has(memory_id),
		"decline: the recipient does not receive the initiator's memory row")
	_expect(NpcMemory.valid_document(world.resident_memories, DECIDED_AT),
		"decline: the memory document is still valid")


func _test_expiry_writes_no_memory() -> void:
	var directory: String = base_root.path_join("expire")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	_force_invite(world, INVITER, RECIPIENT, AT)
	var created: Dictionary = world.settle_residents(AT)
	_expect(bool(created.ok), "expire: the creation sweep succeeds")
	var invitation_id: String = _only_invitation(world)
	_expect(not invitation_id.is_empty(), "expire: an invitation was created")
	if invitation_id.is_empty():
		return
	_cool_down(world.resident_social, INVITER, AT)
	_cool_down(world.resident_social, RECIPIENT, AT)
	var assets_before: Dictionary = _assets(world)
	var expires_utc: float = float(
		world.resident_invitations[invitation_id].expires_utc)
	var settled: Dictionary = world.settle_residents(expires_utc)
	_expect(bool(settled.ok), "expire: the expiry sweep succeeds: "
		+ str(settled.get("reason", "")))
	var row: Dictionary = world.resident_invitations[invitation_id]
	_expect(str(row.status) == NpcInvitation.STATUS_EXPIRED,
		"expire: reaching the TTL turns the invitation expired")
	_expect(is_equal_approx(float(row.decided_utc), expires_utc),
		"expire: expired decisions are stamped at the expiry instant")
	_expect(str(row.reason) == NpcInvitation.STATUS_EXPIRED,
		"expire: the reason is the expired status")
	_expect(_invitation_memory_ids(world, invitation_id).is_empty(),
		"expire: expired invitations write no decision memory")
	_expect(JSON.stringify(_assets(world)) == JSON.stringify(assets_before),
		"expire: an expired invitation grants no asset or ownership")
	_expect(bool(world.farm.economy_reconcile().ok),
		"expire: the ledger still reconciles")


func _test_replay_same_command_and_decision() -> void:
	var directory: String = base_root.path_join("replay")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	_force_invite(world, INVITER, RECIPIENT, AT)
	var created: Dictionary = world.settle_residents(AT)
	_expect(bool(created.ok), "replay: the creation sweep succeeds")
	var invitation_id: String = _only_invitation(world)
	_expect(not invitation_id.is_empty(), "replay: an invitation was created")
	if invitation_id.is_empty():
		return
	# 同一时刻再次结算：新建的 pending 留到下一次结算，同一 act id 被
	# command_id 拦住，权威不应发生任何变化。
	var invitations_before: String = JSON.stringify(world.resident_invitations)
	var memories_before: String = JSON.stringify(world.resident_memories)
	var social_before: String = JSON.stringify(world.resident_social)
	var assets_before: Dictionary = _assets(world)
	var second: Dictionary = world.settle_residents(AT)
	_expect(bool(second.ok), "replay: the same-instant sweep succeeds")
	_expect(not bool(second.get("changed", true)),
		"replay: the same-instant replay reports no change")
	_expect(world.resident_invitations.size() == 1,
		"replay: the same act id creates no second invitation")
	_expect(str(world.resident_invitations[invitation_id].status)
			== NpcInvitation.STATUS_PENDING,
		"replay: a just-created invitation is not decided in the same instant")
	_expect(JSON.stringify(world.resident_invitations) == invitations_before
			and JSON.stringify(world.resident_memories) == memories_before
			and JSON.stringify(world.resident_social) == social_before,
		"replay: the same-instant replay changes no document")
	_expect(JSON.stringify(_assets(world)) == JSON.stringify(assets_before),
		"replay: the same-instant replay moves no asset")
	# 冷却本轮社交后，下一次结算裁决一次；再次同刻结算不重复。
	_cool_down(world.resident_social, INVITER, AT)
	_cool_down(world.resident_social, RECIPIENT, AT)
	var decided: Dictionary = world.settle_residents(AT + 1.0)
	_expect(bool(decided.ok), "replay: the next settlement succeeds")
	_expect(world.resident_invitations.size() == 1,
		"replay: the next settlement creates no extra invitation")
	var status: String = str(world.resident_invitations[invitation_id].status)
	_expect(status == NpcInvitation.STATUS_ACCEPTED
			or status == NpcInvitation.STATUS_DECLINED,
		"replay: the pending invitation is decided exactly once")
	_expect(_invitation_memory_ids(world, invitation_id).size() == 1,
		"replay: exactly one party receives the decision memory")
	var decided_invitations: String = JSON.stringify(world.resident_invitations)
	var decided_memories: String = JSON.stringify(world.resident_memories)
	var third: Dictionary = world.settle_residents(AT + 1.0)
	_expect(bool(third.ok), "replay: the repeated decision instant succeeds")
	_expect(not bool(third.get("changed", true)),
		"replay: the repeated decision instant reports no change")
	_expect(JSON.stringify(world.resident_invitations) == decided_invitations,
		"replay: the decided invitation is not decided again")
	_expect(JSON.stringify(world.resident_memories) == decided_memories,
		"replay: replay writes no second memory row")
	var commands: Dictionary = {}
	for row_value: Variant in world.resident_invitations.values():
		if row_value is Dictionary:
			commands[str((row_value as Dictionary).command_id)] = true
	_expect(commands.size() == world.resident_invitations.size(),
		"replay: command ids stay unique")


func _test_restart_keeps_pending_and_cooldown() -> void:
	var directory: String = base_root.path_join("restart")
	var world: RefCounted = _open_enabled(directory, START)
	if world == null:
		return
	_force_invite(world, INVITER, RECIPIENT, AT)
	# 让被邀请方对发起人的高 affinity 随创建结算一起落盘，以便重启后裁决；
	# 同时冷却其动作，避免它在本轮也发出反向邀约。
	world.resident_social.relations[RECIPIENT][INVITER].affinity = 100
	_cool_down(world.resident_social, RECIPIENT, AT)
	var created: Dictionary = world.settle_residents(AT)
	_expect(bool(created.ok), "restart: the creation sweep succeeds")
	var invitation_id: String = _only_invitation(world)
	_expect(not invitation_id.is_empty(), "restart: an invitation was created")
	if invitation_id.is_empty():
		return
	var invitations_snapshot: String = JSON.stringify(world.resident_invitations)
	var social_snapshot: String = JSON.stringify(world.resident_social)
	var memories_snapshot: String = JSON.stringify(world.resident_memories)

	var reopened := World.new()
	var opened: Dictionary = reopened.open(directory, AT, WORLD_ID, HOST)
	_expect(bool(opened.ok), "restart: the world reopens: "
		+ str(opened.get("reason", "")))
	_expect(str(opened.get("kind", "")) == "loaded",
		"restart: the sidecar is loaded from disk")
	_expect(JSON.stringify(reopened.resident_invitations) == invitations_snapshot,
		"restart: pending invitations survive byte-for-byte")
	_expect(JSON.stringify(reopened.resident_social) == social_snapshot,
		"restart: social relations and cooldowns survive")
	_expect(JSON.stringify(reopened.resident_memories) == memories_snapshot,
		"restart: memories survive")
	_expect(str(reopened.resident_invitations[invitation_id].status)
			== NpcInvitation.STATUS_PENDING,
		"restart: the invitation is still pending before the next settlement")
	reopened.enable_residents()
	# 同一时刻重放：刚创建的 pending 不在本轮裁决，同一 command id 也不再创建。
	var replay: Dictionary = reopened.settle_residents(AT)
	_expect(bool(replay.ok), "restart: the same-instant replay succeeds")
	_expect(not bool(replay.get("changed", true)),
		"restart: the same-instant replay changes nothing")
	_expect(reopened.resident_invitations.size() == 1,
		"restart: the replayed command id creates no second invitation")
	_expect(str(reopened.resident_invitations[invitation_id].status)
			== NpcInvitation.STATUS_PENDING,
		"restart: the replayed invitation stays pending")
	# 冷却本轮社交后，在下一次结算裁决。
	_cool_down(reopened.resident_social, INVITER, AT)
	var settled: Dictionary = reopened.settle_residents(AT + 1.0)
	_expect(bool(settled.ok), "restart: the next settlement succeeds")
	_expect(reopened.resident_invitations.size() == 1,
		"restart: the decision settlement creates no extra invitation")
	_expect(str(reopened.resident_invitations[invitation_id].status)
			== NpcInvitation.STATUS_ACCEPTED,
		"restart: the persisted pending invitation is decided after restart")
	_expect(_invitation_memory_ids(reopened, invitation_id).size() == 1,
		"restart: the decision writes exactly one party's memory")
	var invitations_after: String = JSON.stringify(reopened.resident_invitations)
	var memories_after: String = JSON.stringify(reopened.resident_memories)
	var again: Dictionary = reopened.settle_residents(AT + 1.0)
	_expect(bool(again.ok) and not bool(again.get("changed", true)),
		"restart: a further same-instant sweep is a no-op")
	_expect(JSON.stringify(reopened.resident_invitations) == invitations_after
			and JSON.stringify(reopened.resident_memories) == memories_after,
		"restart: no second decision or invitation is written")
	_expect(ResidentsStore.valid_invitations(reopened.resident_invitations),
		"restart: the reloaded invitation table is still valid")


func _test_capacity_and_legacy_document() -> void:
	var table64: Dictionary = _invitation_table(ResidentsStore.MAX_INVITATIONS)
	var table65: Dictionary = _invitation_table(ResidentsStore.MAX_INVITATIONS + 1)
	_expect(ResidentsStore.valid_invitations(table64),
		"capacity: 64 invitation rows are valid")
	_expect(not ResidentsStore.valid_invitations(table65),
		"capacity: 65 invitation rows are refused")

	var capacity_dir: String = base_root.path_join("capacity")
	DirAccess.make_dir_recursive_absolute(capacity_dir)
	var fresh: Dictionary = ResidentsStore.empty_state(WORLD_ID)
	_write_text(capacity_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": WORLD_ID, "social": fresh.social,
		"memories": fresh.memories, "invitations": table64,
	}))
	var loaded := World.new()
	var opened: Dictionary = loaded.open(capacity_dir, START, WORLD_ID, HOST)
	_expect(bool(opened.ok), "capacity: a 64-row sidecar opens: "
		+ str(opened.get("reason", "")))
	_expect(loaded.resident_invitations.size() == ResidentsStore.MAX_INVITATIONS,
		"capacity: all 64 invitations load")

	var over_dir: String = base_root.path_join("over-capacity")
	DirAccess.make_dir_recursive_absolute(over_dir)
	_write_text(over_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": WORLD_ID, "social": fresh.social,
		"memories": fresh.memories, "invitations": table65,
	}))
	var over := World.new()
	var refused: Dictionary = over.open(over_dir, START, WORLD_ID, HOST)
	_expect(not bool(refused.ok), "capacity: 65 rows refuse the open")
	_expect(str(refused.get("reason", "")) == "load_resident_state_corrupt",
		"capacity: the refusal is named load_resident_state_corrupt")

	# 已有 64 条已决策行时，新邀约不再创建；容量由权威在 propose 前拦住。
	var full_dir: String = base_root.path_join("full-capacity")
	DirAccess.make_dir_recursive_absolute(full_dir)
	var decided_table: Dictionary = _decided_table(ResidentsStore.MAX_INVITATIONS)
	_write_text(full_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": WORLD_ID, "social": fresh.social,
		"memories": fresh.memories, "invitations": decided_table,
	}))
	var full: RefCounted = _open_enabled(full_dir, START)
	if full != null:
		_force_invite(full, INVITER, RECIPIENT, AT)
		var full_before: String = JSON.stringify(full.resident_invitations)
		var full_settled: Dictionary = full.settle_residents(AT)
		_expect(bool(full_settled.ok), "capacity: the full table still settles")
		_expect(full.resident_invitations.size()
				== ResidentsStore.MAX_INVITATIONS,
			"capacity: a full table creates no 65th invitation")
		_expect(JSON.stringify(full.resident_invitations) == full_before,
			"capacity: the full invitation table is unchanged")
		_expect((full_settled.get("invitations", []) as Array).is_empty(),
			"capacity: the full sweep reports no created invitation")

	# 满表的已决行在保留窗口外必须被回收，否则居民永久停止发起邀约。窗口内的
	# 已决行不受影响。
	var stale_dir: String = base_root.path_join("stale-capacity")
	DirAccess.make_dir_recursive_absolute(stale_dir)
	var stale_table: Dictionary = _decided_table(ResidentsStore.MAX_INVITATIONS)
	_write_text(stale_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": WORLD_ID, "social": fresh.social,
		"memories": fresh.memories, "invitations": stale_table,
	}))
	var stale: RefCounted = _open_enabled(stale_dir, START)
	if stale != null:
		_expect(stale.resident_invitations.size() == ResidentsStore.MAX_INVITATIONS,
			"capacity: the stale full table loads")
		_force_invite(stale, INVITER, RECIPIENT, AT)
		var after_window: float = AT \
			+ float(NpcInvitation.DEFAULT_RETAIN_SECONDS) + 1.0
		var swept: Dictionary = stale.settle_residents(after_window)
		_expect(bool(swept.ok), "capacity: the sweep past the window succeeds: "
			+ str(swept.get("reason", "")))
		_expect(stale.resident_invitations.size() < ResidentsStore.MAX_INVITATIONS,
			"capacity: decided rows past the window are reclaimed")
		_expect(ResidentsStore.valid_invitations(stale.resident_invitations),
			"capacity: the reclaimed table is still valid")

	var in_window_dir: String = base_root.path_join("in-window")
	DirAccess.make_dir_recursive_absolute(in_window_dir)
	var recent_table: Dictionary = _decided_table(ResidentsStore.MAX_INVITATIONS)
	for id_value: Variant in recent_table:
		var row: Dictionary = recent_table[id_value]
		row["decided_utc"] = AT
		row["created_utc"] = AT - float(NpcInvitation.TTL_SECONDS[INVITATION_KIND])
	_write_text(in_window_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": WORLD_ID, "social": fresh.social,
		"memories": fresh.memories, "invitations": recent_table,
	}))
	var windowed: RefCounted = _open_enabled(in_window_dir, START)
	if windowed != null:
		var recent_before: String = JSON.stringify(windowed.resident_invitations)
		windowed.settle_residents(AT + 60.0)
		_expect(JSON.stringify(windowed.resident_invitations) == recent_before,
			"capacity: decided rows inside the window are kept untouched")

	# 旧四键文档（没有 invitations）按空表加载；下一次保存写成五键。
	var legacy_dir: String = base_root.path_join("legacy")
	DirAccess.make_dir_recursive_absolute(legacy_dir)
	_write_text(legacy_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": WORLD_ID, "social": fresh.social,
		"memories": fresh.memories,
	}))
	var legacy := World.new()
	var legacy_text: String = FileAccess.get_file_as_string(
		legacy_dir.path_join("residents.json"))
	var legacy_opened: Dictionary = legacy.open(legacy_dir, START, WORLD_ID, HOST)
	_expect(bool(legacy_opened.ok), "legacy: a four-key document still opens: "
		+ str(legacy_opened.get("reason", "")))
	_expect(FileAccess.get_file_as_string(legacy_dir.path_join("residents.json"))
			== legacy_text,
		"legacy: opening the old document never rewrites it")
	_expect((legacy.resident_invitations as Dictionary).is_empty(),
		"legacy: a missing invitation key reads as an empty table")


func _test_world_mismatch_and_corrupt_refused() -> void:
	var fresh: Dictionary = ResidentsStore.empty_state(WORLD_ID)
	var mismatch_dir: String = base_root.path_join("world-mismatch")
	DirAccess.make_dir_recursive_absolute(mismatch_dir)
	var other: Dictionary = ResidentsStore.empty_state("another-world")
	_write_text(mismatch_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": "another-world", "social": other.social,
		"memories": other.memories, "invitations": other.invitations,
	}))
	var before: String = FileAccess.get_file_as_string(
		mismatch_dir.path_join("residents.json"))
	var mismatch := World.new()
	var refused: Dictionary = mismatch.open(mismatch_dir, START, WORLD_ID, HOST)
	_expect(not bool(refused.ok), "mismatch: another world's sidecar refuses the open")
	_expect(str(refused.get("reason", "")) == "load_resident_state_world_mismatch",
		"mismatch: the refusal is named load_resident_state_world_mismatch")
	_expect(FileAccess.get_file_as_string(mismatch_dir.path_join("residents.json"))
			== before, "mismatch: the refused document is never overwritten")

	var corrupt_dir: String = base_root.path_join("corrupt-invitation")
	DirAccess.make_dir_recursive_absolute(corrupt_dir)
	_write_text(corrupt_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": WORLD_ID, "social": fresh.social,
		"memories": fresh.memories,
		"invitations": {"bogus": {"from": INVITER, "to": RECIPIENT}},
	}))
	var corrupt := World.new()
	var corrupt_refused: Dictionary = corrupt.open(
		corrupt_dir, START, WORLD_ID, HOST)
	_expect(not bool(corrupt_refused.ok),
		"corrupt: a malformed invitation row refuses the open")
	_expect(str(corrupt_refused.get("reason", "")) == "load_resident_state_corrupt",
		"corrupt: the refusal is named load_resident_state_corrupt")

	var duplicate_dir: String = base_root.path_join("duplicate-command")
	DirAccess.make_dir_recursive_absolute(duplicate_dir)
	var duplicate_table: Dictionary = _invitation_table(2)
	var duplicate_rows: Array = duplicate_table.values()
	(duplicate_rows[1] as Dictionary).command_id = \
		str((duplicate_rows[0] as Dictionary).command_id)
	_write_text(duplicate_dir.path_join("residents.json"), JSON.stringify({
		"version": 1, "world_id": WORLD_ID, "social": fresh.social,
		"memories": fresh.memories, "invitations": duplicate_table,
	}))
	var duplicate := World.new()
	var duplicate_refused: Dictionary = duplicate.open(
		duplicate_dir, START, WORLD_ID, HOST)
	_expect(not bool(duplicate_refused.ok),
		"corrupt: duplicate command ids refuse the open")
	_expect(str(duplicate_refused.get("reason", ""))
			== "load_resident_state_corrupt",
		"corrupt: duplicate command ids are named corrupt")


# ---------------------------------------------------------------------------
# Fixtures and helpers
# ---------------------------------------------------------------------------

func _open_enabled(directory: String, at_utc: float) -> RefCounted:
	DirAccess.make_dir_recursive_absolute(directory)
	var seeded: Dictionary = NatureStore.new(directory).save_state(
		{"seed": SEED, "rules_version": RULES_VERSION})
	_expect(bool(seeded.get("ok", false)),
		"%s: the fixed seed is persisted" % directory.get_file())
	var world := World.new()
	var opened: Dictionary = world.open(directory, at_utc, WORLD_ID, HOST)
	_expect(bool(opened.ok), "%s: the world opens: %s"
		% [directory.get_file(), str(opened.get("reason", ""))])
	if not bool(opened.ok):
		return null
	world.enable_residents()
	return world


## 让 plan 必然选中 invite：所有对象 affinity 高到不道歉/不满足赠礼目标，其余
## 动作种类都在冷却中。
func _force_invite(world: RefCounted, from_id: String, to_id: String,
		at_utc: float) -> void:
	var social: Dictionary = world.resident_social
	var peers: Dictionary = social.relations[from_id]
	for peer_value: Variant in peers:
		var row: Dictionary = peers[peer_value]
		row.affinity = 90
		row.last_utc = maxf(float(row.last_utc), at_utc)
	social.actions[from_id] = {
		"greet": at_utc, "gift": at_utc, "apologize": at_utc,
	}
	var traits: Dictionary = NpcPersonality.traits(from_id, SEED).traits
	_expect(int(traits.warmth) >= NpcSocial.INVITE_MIN_WARMTH
			or int(traits.curiosity) >= NpcSocial.INVITE_MIN_CURIOSITY,
		"fixture: %s can plan an invitation" % from_id)
	_expect(str(to_id) != str(from_id), "fixture: the target is another resident")


func _cool_down(social: Dictionary, npc_id: String, at_utc: float) -> void:
	for peer_value: Variant in social.relations[npc_id]:
		var row: Dictionary = social.relations[npc_id][peer_value]
		row.last_utc = maxf(float(row.last_utc), at_utc)
	social.actions[npc_id] = {
		"greet": at_utc, "gift": at_utc, "apologize": at_utc, "invite": at_utc,
	}


func _only_invitation(world: RefCounted) -> String:
	var rows: Dictionary = world.resident_invitations
	if rows.size() != 1:
		return ""
	return str(rows.keys()[0])


func _relation_snapshot(world: RefCounted, npc_id: String) -> String:
	return JSON.stringify(world.resident_social.relations.get(npc_id, {}))


func _view_row(view: Dictionary, npc_id: String) -> Dictionary:
	for row_value: Variant in view.get("residents", []):
		if row_value is Dictionary and str((row_value as Dictionary).id) == npc_id:
			return row_value
	return {}


func _view_invitation_keys_ok(row: Dictionary) -> bool:
	var invitation_value: Variant = row.get("last_invitation", null)
	if not invitation_value is Dictionary:
		return false
	var invitation: Dictionary = invitation_value
	if invitation.size() != VIEW_KEYS.size():
		return false
	for key: String in VIEW_KEYS:
		if not invitation.has(key):
			return false
	return true


func _pending_shape_ok(row: Dictionary) -> bool:
	if row.size() != PENDING_KEYS.size():
		return false
	for key: String in PENDING_KEYS:
		if not row.has(key):
			return false
	return true


func _decided_shape_ok(row: Dictionary) -> bool:
	if row.size() != DECIDED_KEYS.size():
		return false
	for key: String in DECIDED_KEYS:
		if not row.has(key):
			return false
	return true


func _invitation_memory_ids(world: RefCounted, invitation_id: String) -> Array:
	var found: Array = []
	for npc_id: String in [INVITER, RECIPIENT, BYSTANDER]:
		var memory_id: String = NpcSocialMemory.memory_id(
			"invitation", invitation_id, npc_id)
		if _memory_entries(world, npc_id).has(memory_id):
			found.append(npc_id)
	return found


func _memory_entries(world: RefCounted, npc_id: String) -> Dictionary:
	var npcs: Variant = world.resident_memories.get("npcs", {})
	if not npcs is Dictionary:
		return {}
	var row: Variant = (npcs as Dictionary).get(npc_id, {})
	if not row is Dictionary:
		return {}
	var entries: Variant = (row as Dictionary).get("entries", {})
	return entries if entries is Dictionary else {}


func _assets(world: RefCounted) -> Dictionary:
	var cash: Dictionary = {}
	var bags: Dictionary = {}
	for npc_id: String in NpcRoster.IDS:
		cash[npc_id] = world.farm.economy_cash(npc_id)
		bags[npc_id] = world.farm.economy_goods(npc_id)
	return {
		"cash": cash, "bags": bags,
		"goods_total": _goods_total(world.farm),
		"issued": world.farm.economy_issued(),
		"trades": world.farm.market_trades().size(),
	}


func _goods_total(farm: RefCounted) -> int:
	var total: int = 0
	var merchant: Dictionary = farm.market_merchant()
	var stock: Variant = merchant.get("goods")
	if stock is Dictionary:
		for good_id: String in EconomyCatalog.goods_ids():
			total += int((stock as Dictionary).get(good_id, 0))
	for npc_id: String in NpcRoster.IDS:
		var bag: Dictionary = farm.economy_goods(npc_id)
		for good_id: String in EconomyCatalog.goods_ids():
			total += int(bag.get(good_id, 0))
	for row: Variant in farm.market_orders():
		if row is Dictionary and str((row as Dictionary).get("side", "")) \
				== Market.SIDE_SELL \
				and str((row as Dictionary).get("status", "")) == Market.STATUS_OPEN:
			total += int((row as Dictionary).get("remaining", 0))
	return total


func _invitation_table(count: int) -> Dictionary:
	var table: Dictionary = {}
	for index: int in count:
		var proposed: Dictionary = NpcInvitation.propose(
			NpcInvitation.empty_document(), {
				"from": INVITER, "to": RECIPIENT, "kind": INVITATION_KIND,
			}, AT + float(index))
		if not bool(proposed.get("ok", false)):
			continue
		var row: Dictionary = (proposed.invitation as Dictionary).duplicate(true)
		row["command_id"] = "capacity_cmd_%03d" % index
		table[str(row.id)] = row
	return table


## 64 条已决策行：不构成同对象 pending，也不在结算时被裁决，只用于验证容量。
func _decided_table(count: int) -> Dictionary:
	var table: Dictionary = {}
	for index: int in count:
		var proposed: Dictionary = NpcInvitation.propose(
			NpcInvitation.empty_document(), {
				"from": INVITER, "to": RECIPIENT, "kind": INVITATION_KIND,
			}, AT + float(index))
		if not bool(proposed.get("ok", false)):
			continue
		var row: Dictionary = (proposed.invitation as Dictionary).duplicate(true)
		row["status"] = NpcInvitation.STATUS_ACCEPTED
		row["decided_utc"] = float(row.created_utc)
		row["reason"] = NpcInvitation.STATUS_ACCEPTED
		row["command_id"] = "capacity_cmd_%03d" % index
		table[str(row.id)] = row
	return table


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_expect(false, "fixture: cannot write " + path)
		return
	file.store_string(text)
	file.close()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
