extends SceneTree
## M11-02 组织规则最小切片的无头纯规则测试：不读 FarmState、存档、场景或
## 系统时钟。最后一行是验证证据。

const Organization = preload("res://world/organization_state.gd")

const START: float = 1800000000.0
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const PLAYER_D: String = "player_00000000000000000000000000000004"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_create()
	_test_join_and_leave()
	_test_appoint()
	_test_spend()
	_test_transfer()
	_test_document_validity()
	_test_determinism()
	for failure: String in failures:
		push_error(failure)
	print("ORGANIZATION_STATE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_create() -> void:
	var empty: Dictionary = Organization.empty()
	_expect(Organization.valid(empty), "The empty document is valid")
	var original: Dictionary = empty.duplicate(true)
	var created: Dictionary = Organization.create(empty, "coop", "河岸合作社", PLAYER_A, START)
	_expect(created.ok and str(created.reason).is_empty(),
		"A legal player creates an organization")
	_expect(empty == original, "create returns a candidate and leaves its input unchanged")
	var state: Dictionary = created.state
	_expect(Organization.valid(state), "A created organization document is valid")
	var org: Dictionary = state.organizations["coop"]
	_expect(org["name"] == "河岸合作社" and float(org["created_utc"]) == START,
		"The organization records its name and creation time")
	_expect(org["account_id"] == "org_coop" and Organization.account_for("coop") == "org_coop",
		"The account id is derived from the organization id")
	_expect(org["members"].size() == 1 and org["members"][PLAYER_A] == Organization.ROLE_LEADER,
		"The creator is the sole leader")
	_expect(Organization.role_of(state, "coop", PLAYER_A) == Organization.ROLE_LEADER,
		"role_of reports the creator role")
	_expect(Organization.role_of(state, "coop", PLAYER_B).is_empty(),
		"role_of returns empty for a non-member")
	_expect(org["roles"].size() == 3
		and bool(org["roles"][Organization.ROLE_LEADER]["can_spend"])
		and bool(org["roles"][Organization.ROLE_LEADER]["can_manage"])
		and bool(org["roles"][Organization.ROLE_OFFICER]["can_spend"])
		and not bool(org["roles"][Organization.ROLE_OFFICER]["can_manage"])
		and not bool(org["roles"][Organization.ROLE_MEMBER]["can_spend"])
		and not bool(org["roles"][Organization.ROLE_MEMBER]["can_manage"]),
		"The canonical role permission table is stored")

	var accepted: Dictionary = state.duplicate(true)
	var duplicate: Dictionary = Organization.create(state, "coop", "另一个合作社", PLAYER_B,
		START + 1.0)
	_expect(not duplicate.ok and duplicate.reason == "already_exists",
		"A duplicate organization id is refused")
	_expect(state == accepted, "A refused duplicate changes nothing")

	for bad_id: Variant in ["", "bad org", "bad/id", 42, null]:
		var refused: Dictionary = Organization.create(state, bad_id, "Name", PLAYER_A, START)
		_expect(not refused.ok and refused.reason == "invalid_org",
			"An illegal organization id is refused")
	for bad_name: Variant in ["", "   ", "bad\nname", "x".repeat(65), 42, null]:
		var refused: Dictionary = Organization.create(state, "guild", bad_name, PLAYER_A, START)
		_expect(not refused.ok and refused.reason == "invalid_name",
			"An illegal organization name is refused")
	for bad_creator: Variant in ["", "@world", "bad player", 42, null]:
		var refused: Dictionary = Organization.create(state, "guild", "Guild", bad_creator, START)
		_expect(not refused.ok and refused.reason == "invalid_player",
			"An illegal creator id is refused")
	for bad_time: float in [-1.0, INF, NAN]:
		var refused: Dictionary = Organization.create(state, "guild", "Guild", PLAYER_A, bad_time)
		_expect(not refused.ok and refused.reason == "invalid_time",
			"An illegal creation time is refused")
	_expect(not Organization.create({"organizations": []}, "guild", "Guild", PLAYER_A, START).ok,
		"A malformed input document cannot create an organization")

	var full: Dictionary = Organization.empty()
	var all_accepted: bool = true
	for index: int in Organization.MAX_ORGANIZATIONS:
		var result: Dictionary = Organization.create(full, "bulk_%02d" % index,
			"Bulk %d" % index, PLAYER_A, START)
		all_accepted = all_accepted and result.ok
		full = result.state
	_expect(all_accepted and Organization.valid(full),
		"The document accepts exactly the organization bound")
	var overflow: Dictionary = Organization.create(full, "overflow", "Overflow", PLAYER_A, START)
	_expect(not overflow.ok and overflow.reason == "too_many",
		"One organization beyond the bound is refused")


func _test_join_and_leave() -> void:
	var state: Dictionary = _single_state()
	var original: Dictionary = state.duplicate(true)
	var joined: Dictionary = Organization.join(state, "coop", PLAYER_B, START + 10.0)
	_expect(joined.ok and joined.state.organizations["coop"]["members"][PLAYER_B]
		== Organization.ROLE_MEMBER, "A legal player joins as a plain member")
	_expect(state == original, "join returns a candidate and leaves its input unchanged")
	state = joined.state
	_expect(Organization.valid(state), "The document is valid after a join")

	var accepted: Dictionary = state.duplicate(true)
	var again: Dictionary = Organization.join(state, "coop", PLAYER_B, START + 11.0)
	_expect(not again.ok and again.reason == "already_member",
		"An existing member cannot join twice")
	_expect(state == accepted, "A refused join changes nothing")
	_expect(Organization.join(state, "missing", PLAYER_C, START).reason == "unknown_org",
		"Joining an unknown organization is refused")
	for bad_player: Variant in ["", "@world", "bad player", 42, null]:
		_expect(Organization.join(state, "coop", bad_player, START).reason == "invalid_player",
			"Joining with an illegal player id is refused")
	_expect(Organization.join(state, "coop", PLAYER_C, -1.0).reason == "invalid_time",
		"Joining with a negative time is refused")

	var left: Dictionary = Organization.leave(state, "coop", PLAYER_B, START + 12.0)
	_expect(left.ok and not left.state.organizations["coop"]["members"].has(PLAYER_B),
		"A member leaves and is removed from the member table")
	_expect(state == accepted, "leave returns a candidate and leaves its input unchanged")
	state = left.state
	_expect(Organization.valid(state), "The document is valid after a leave")
	_expect(Organization.leave(state, "coop", PLAYER_B, START + 13.0).reason == "not_member",
		"A non-member cannot leave")
	_expect(Organization.leave(state, "coop", PLAYER_A, START + 13.0).reason == "last_member",
		"The last member cannot leave")
	_expect(Organization.leave(state, "missing", PLAYER_A, START).reason == "unknown_org",
		"Leaving an unknown organization is refused")

	var with_member: Dictionary = Organization.join(state, "coop", PLAYER_B, START + 14.0).state
	_expect(Organization.leave(with_member, "coop", PLAYER_A, START + 15.0).reason
		== "leader_must_transfer", "The leader cannot leave before transferring leadership")
	_expect(Organization.leave(with_member, "coop", PLAYER_B, START + 15.0).ok,
		"A non-leader member may leave while the leader remains")

	var full: Dictionary = _single_state()
	var joined_all: bool = true
	for index: int in Organization.MAX_MEMBERS - 1:
		var result: Dictionary = Organization.join(full, "coop", "m_%03d" % index,
			START + 20.0 + index)
		joined_all = joined_all and result.ok
		full = result.state
	_expect(joined_all and Organization.valid(full)
		and full.organizations["coop"]["members"].size() == Organization.MAX_MEMBERS,
		"An organization accepts exactly the member bound")
	_expect(Organization.join(full, "coop", "overflow_member", START + 300.0).reason
		== "org_full", "One member beyond the bound is refused")


func _test_appoint() -> void:
	var state: Dictionary = _two_member_state()
	var original: Dictionary = state.duplicate(true)
	var appointed: Dictionary = Organization.appoint(state, "coop", PLAYER_A, PLAYER_B,
		Organization.ROLE_OFFICER, START + 20.0)
	_expect(appointed.ok and appointed.state.organizations["coop"]["members"][PLAYER_B]
		== Organization.ROLE_OFFICER, "The leader appoints a member as officer")
	_expect(state == original, "appoint returns a candidate and leaves its input unchanged")
	state = appointed.state
	_expect(Organization.valid(state), "The document is valid after an appointment")
	_expect(Organization.appoint(state, "coop", PLAYER_B, PLAYER_A,
		Organization.ROLE_MEMBER, START + 21.0).reason == "role_forbidden",
		"An officer cannot appoint because can_manage is false")
	_expect(Organization.appoint(state, "coop", PLAYER_C, PLAYER_B,
		Organization.ROLE_MEMBER, START + 21.0).reason == "not_member",
		"A non-member cannot appoint")
	_expect(Organization.appoint(state, "coop", PLAYER_A, PLAYER_C,
		Organization.ROLE_OFFICER, START + 21.0).reason == "target_not_member",
		"An appointment target must already be a member")
	_expect(Organization.appoint(state, "coop", PLAYER_A, PLAYER_B,
		Organization.ROLE_LEADER, START + 21.0).reason == "leader_requires_transfer",
		"The leader role cannot be assigned through appoint")
	_expect(Organization.appoint(state, "coop", PLAYER_A, PLAYER_B,
		"owner", START + 21.0).reason == "invalid_role",
		"An unknown role name is refused")
	_expect(Organization.appoint(state, "coop", PLAYER_A, PLAYER_A,
		Organization.ROLE_MEMBER, START + 21.0).reason == "leader_requires_transfer",
		"The leader cannot demote themselves through appoint")
	_expect(Organization.appoint(state, "missing", PLAYER_A, PLAYER_B,
		Organization.ROLE_MEMBER, START).reason == "unknown_org",
		"Appointing in an unknown organization is refused")
	_expect(Organization.appoint(state, "coop", PLAYER_A, PLAYER_B,
		Organization.ROLE_MEMBER, -1.0).reason == "invalid_time",
		"Appointing with a negative time is refused")

	var member_state: Dictionary = Organization.appoint(state, "coop", PLAYER_A, PLAYER_B,
		Organization.ROLE_MEMBER, START + 22.0).state
	_expect(Organization.appoint(member_state, "coop", PLAYER_A, PLAYER_B,
		Organization.ROLE_OFFICER, START + 23.0).ok,
		"The leader may promote a plain member again")
	_expect(not Organization.appoint(state, "coop", PLAYER_A, PLAYER_B,
		Organization.ROLE_OFFICER, START + 23.0).state is Array,
		"A refused appointment returns no candidate state")


func _test_spend() -> void:
	var state: Dictionary = _member_state()
	var accepted: Dictionary = state.duplicate(true)
	var leader: Dictionary = Organization.authorize_spend(state, "coop", PLAYER_A, "org_coop",
		50, START + 30.0)
	_expect(leader.ok and leader.amount == 50 and leader.account_id == "org_coop",
		"The leader may spend from the declared organization account")
	_expect(state == accepted, "authorize_spend does not modify the document")
	var officer: Dictionary = Organization.authorize_spend(state, "coop", PLAYER_B, "org_coop",
		25.0, START + 30.0)
	_expect(officer.ok and officer.amount == 25,
		"An officer may spend and an integral JSON float is accepted")
	_expect(Organization.authorize_spend(state, "coop", PLAYER_C, "org_coop",
		10, START + 30.0).reason == "role_forbidden",
		"A plain member may not spend")
	_expect(Organization.authorize_spend(state, "coop", PLAYER_D, "org_coop",
		10, START + 30.0).reason == "not_member",
		"A non-member may not spend")
	_expect(Organization.authorize_spend(state, "coop", PLAYER_A, "org_other",
		10, START + 30.0).reason == "wrong_account",
		"A spend cannot name another account")
	_expect(Organization.authorize_spend(state, "coop", PLAYER_A, "",
		10, START + 30.0).reason == "wrong_account",
		"An empty account id is refused")
	_expect(Organization.authorize_spend(state, "missing", PLAYER_A, "org_coop",
		10, START + 30.0).reason == "unknown_org",
		"Spending from an unknown organization is refused")
	for bad_amount: Variant in [0, -5, 1.5, 0.0, -0.5, INF, NAN, "10", null]:
		var refused: Dictionary = Organization.authorize_spend(state, "coop", PLAYER_A,
			"org_coop", bad_amount, START + 30.0)
		_expect(not refused.ok and refused.reason == "invalid_amount",
			"A non-positive or non-integer amount is refused")
	for bad_actor: Variant in ["", "@world", "bad actor", 42, null]:
		_expect(Organization.authorize_spend(state, "coop", bad_actor, "org_coop",
			10, START).reason == "invalid_player",
			"Spending with an illegal actor id is refused")
	_expect(Organization.authorize_spend(state, "coop", PLAYER_A, "org_coop",
		10, -1.0).reason == "invalid_time",
		"Spending with a negative time is refused")
	_expect(Organization.authorize_spend({"organizations": []}, "coop", PLAYER_A,
		"org_coop", 10, START).reason == "invalid_state",
		"A malformed document cannot authorize a spend")


func _test_transfer() -> void:
	var state: Dictionary = _member_state()
	var original: Dictionary = state.duplicate(true)
	_expect(Organization.transfer_leadership(state, "coop", PLAYER_B, PLAYER_C,
		START + 40.0).reason == "not_leader",
		"An officer cannot transfer leadership")
	_expect(Organization.transfer_leadership(state, "coop", PLAYER_A, PLAYER_D,
		START + 40.0).reason == "target_not_member",
		"Leadership can only be transferred to an existing member")
	_expect(Organization.transfer_leadership(state, "coop", PLAYER_A, PLAYER_A,
		START + 40.0).reason == "same_leader",
		"Leadership cannot be transferred to the current leader")
	_expect(Organization.transfer_leadership(state, "missing", PLAYER_A, PLAYER_C,
		START + 40.0).reason == "unknown_org",
		"Transferring leadership in an unknown organization is refused")

	var transferred: Dictionary = Organization.transfer_leadership(state, "coop", PLAYER_A,
		PLAYER_C, START + 41.0)
	_expect(transferred.ok, "The leader transfers leadership to another member")
	_expect(state == original, "transfer_leadership leaves its input unchanged")
	var moved: Dictionary = transferred.state
	var org: Dictionary = moved.organizations["coop"]
	_expect(org["members"][PLAYER_C] == Organization.ROLE_LEADER
		and org["members"][PLAYER_A] == Organization.ROLE_MEMBER,
		"The new leader is promoted and the old leader becomes a plain member")
	_expect(org["account_id"] == "org_coop" and moved.organizations.has("coop"),
		"Handover changes neither the account id nor the organization id")
	_expect(Organization.valid(moved), "The document is valid after a handover")
	_expect(Organization.authorize_spend(moved, "coop", PLAYER_A, "org_coop",
		10, START + 42.0).reason == "role_forbidden",
		"The former leader loses the spend permission")
	_expect(Organization.authorize_spend(moved, "coop", PLAYER_C, "org_coop",
		10, START + 42.0).ok, "The new leader gains the spend permission")
	_expect(Organization.appoint(moved, "coop", PLAYER_A, PLAYER_B,
		Organization.ROLE_OFFICER, START + 42.0).reason == "role_forbidden",
		"The former leader loses the manage permission")
	_expect(Organization.appoint(moved, "coop", PLAYER_C, PLAYER_A,
		Organization.ROLE_OFFICER, START + 42.0).ok,
		"The new leader can appoint members")
	_expect(Organization.role_of(moved, "coop", PLAYER_A) == Organization.ROLE_MEMBER,
		"role_of reports the demoted former leader")
	_expect(Organization.transfer_leadership(moved, "coop", PLAYER_C, PLAYER_A,
		START + 43.0).ok, "Leadership can be transferred again without touching assets")


func _test_document_validity() -> void:
	var state: Dictionary = _two_member_state()
	_expect(Organization.valid(JSON.parse_string(JSON.stringify(state))),
		"The document remains valid after a JSON round trip")
	_expect(not Organization.valid(null) and not Organization.valid([])
		and not Organization.valid({}),
		"A non-dictionary or structurally empty document is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void: doc["extra"] = true),
		"An unknown top-level key is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void: doc.erase("organizations")),
		"A missing organizations key is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["extra"] = true),
		"An unknown organization key is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["name"] = ""),
		"An empty organization name is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["name"] = " padded "),
		"An organization name with edge whitespace is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["name"] = "bad\nname"),
		"An organization name with a control character is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["created_utc"] = -1.0),
		"A negative creation time is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["created_utc"] = INF),
		"A non-finite creation time is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["account_id"] = "org_other"),
		"An account id that does not match the organization id is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["members"][PLAYER_A] = "owner"),
		"An unknown member role is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["members"]["bad player"] = "member"),
		"An illegal member id is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["members"] = {}),
		"An organization with no members is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["members"].erase(PLAYER_A)),
		"An organization with no leader is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["members"][PLAYER_C] = "leader"),
		"An organization with two leaders is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["members"][PLAYER_A] = "officer"),
		"Demoting the only leader in the document is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["bad org"] = doc["organizations"]["coop"]
		doc["organizations"].erase("coop")),
		"An illegal organization id key is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"] = []),
		"A non-dictionary organization row is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["roles"].erase("member")),
		"A missing role row is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["roles"]["guest"] = {"can_spend": false, "can_manage": false}),
		"An unknown role row is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["roles"]["member"]["can_spend"] = true),
		"A tampered permission that grants more power is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["roles"]["leader"]["can_manage"] = 1),
		"A non-boolean permission is rejected")
	_expect(_rejects(state, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["roles"]["leader"]["extra"] = true),
		"An unknown role permission key is rejected")

	var too_many_orgs: Dictionary = state.duplicate(true)
	for index: int in Organization.MAX_ORGANIZATIONS:
		var row: Dictionary = state.organizations["coop"].duplicate(true)
		row["account_id"] = Organization.account_for("bulk_%02d" % index)
		too_many_orgs["organizations"]["bulk_%02d" % index] = row
	_expect(not Organization.valid(too_many_orgs),
		"More organizations than the bound are rejected")

	var many_members: Dictionary = {PLAYER_A: Organization.ROLE_LEADER}
	for index: int in Organization.MAX_MEMBERS:
		many_members["m_%03d" % index] = Organization.ROLE_MEMBER
	var too_many_members: Dictionary = {
		"organizations": {"coop": _org_row("coop", many_members)},
	}
	_expect(not Organization.valid(too_many_members),
		"More members than the bound are rejected")


func _test_determinism() -> void:
	var first: Dictionary = _run_sequence()
	var second: Dictionary = _run_sequence()
	_expect(not first.is_empty() and first == second,
		"The same command sequence produces the same document")
	_expect(first.organizations["coop"]["account_id"] == "org_coop"
		and first.organizations["coop"]["members"][PLAYER_B] == Organization.ROLE_LEADER,
		"The deterministic sequence ends with the transferred leader and same account")

	var seed: Dictionary = _single_state()
	var untouched: Dictionary = seed.duplicate(true)
	Organization.join(seed, "coop", PLAYER_B, START + 1.0)
	Organization.create(seed, "guild", "Guild", PLAYER_C, START + 2.0)
	Organization.leave(seed, "coop", PLAYER_A, START + 3.0)
	_expect(seed == untouched, "Library commands never mutate the caller's document")

	var first_decision: Dictionary = Organization.authorize_spend(seed, "coop", PLAYER_A,
		"org_coop", 5, START + 4.0)
	var second_decision: Dictionary = Organization.authorize_spend(seed, "coop", PLAYER_A,
		"org_coop", 5, START + 4.0)
	_expect(first_decision == second_decision and first_decision.ok
		and first_decision.amount == 5, "An authorization result is deterministic")
	var first_refusal: Dictionary = Organization.join(seed, "coop", PLAYER_A, START + 5.0)
	var second_refusal: Dictionary = Organization.join(seed, "coop", PLAYER_A, START + 5.0)
	_expect(first_refusal.reason == second_refusal.reason
		and first_refusal.reason == "already_member", "A refusal is deterministic")


func _run_sequence() -> Dictionary:
	var state: Dictionary = Organization.empty()
	var result: Dictionary = Organization.create(state, "coop", "河岸合作社", PLAYER_A, START)
	state = result.state
	result = Organization.join(state, "coop", PLAYER_B, START + 1.0)
	state = result.state
	result = Organization.appoint(state, "coop", PLAYER_A, PLAYER_B,
		Organization.ROLE_OFFICER, START + 2.0)
	state = result.state
	result = Organization.transfer_leadership(state, "coop", PLAYER_A, PLAYER_B, START + 3.0)
	state = result.state
	var decision: Dictionary = Organization.authorize_spend(state, "coop", PLAYER_B,
		"org_coop", 12, START + 4.0)
	if not decision.ok:
		return {}
	return state


func _single_state() -> Dictionary:
	var created: Dictionary = Organization.create(Organization.empty(), "coop",
		"河岸合作社", PLAYER_A, START)
	var state: Dictionary = created.state
	return state


func _two_member_state() -> Dictionary:
	var state: Dictionary = _single_state()
	var joined: Dictionary = Organization.join(state, "coop", PLAYER_B, START + 1.0)
	return joined.state


func _member_state() -> Dictionary:
	var state: Dictionary = _two_member_state()
	var appointed: Dictionary = Organization.appoint(state, "coop", PLAYER_A, PLAYER_B,
		Organization.ROLE_OFFICER, START + 2.0)
	state = appointed.state
	var joined: Dictionary = Organization.join(state, "coop", PLAYER_C, START + 3.0)
	return joined.state


func _org_row(org_id: String, members: Dictionary) -> Dictionary:
	return {
		"name": "Test Organization",
		"created_utc": START,
		"members": members,
		"roles": {
			"leader": {"can_spend": true, "can_manage": true},
			"officer": {"can_spend": true, "can_manage": false},
			"member": {"can_spend": false, "can_manage": false},
		},
		"account_id": Organization.account_for(org_id),
		"status": Organization.STATUS_ACTIVE,
		"closed_utc": 0.0,
		"closed_by": "",
		"history": [{"kind": Organization.HISTORY_CREATED, "actor": PLAYER_A,
			"target": "", "at_utc": START}],
	}


func _rejects(state: Dictionary, mutate: Callable) -> bool:
	var copy: Dictionary = state.duplicate(true)
	mutate.call(copy)
	return not Organization.valid(copy)


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
