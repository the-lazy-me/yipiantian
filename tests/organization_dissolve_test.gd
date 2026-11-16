extends SceneTree
## M11-02 组织解散与资产清算纯规则测试：不读 FarmState、存档、场景或系统时钟。
## 只验证 `Organization.dissolve()` 的授权、关闭状态、历史保留、清算意图、
## 命令重放与严格文档校验。最后一行是验证证据。

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
	_test_leader_dissolves()
	_test_permission_refusals()
	_test_preconditions()
	_test_clearing_order_and_conservation()
	_test_replay()
	_test_closed_organization_operations()
	_test_pending_dissolve_intent()
	_test_document_validity()
	_test_determinism()
	for failure: String in failures:
		push_error(failure)
	print("ORGANIZATION_DISSOLVE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_leader_dissolves() -> void:
	var state: Dictionary = _member_state()
	var original: Dictionary = state.duplicate(true)
	var dissolved: Dictionary = Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		_options("close-1", 100, 0, {PLAYER_A: 2, PLAYER_B: 1}))
	_expect(dissolved.ok and str(dissolved.reason).is_empty(),
		"The current leader dissolves the organization")
	_expect(dissolved.duplicate == false, "A first dissolve is not a duplicate")
	_expect(state == original, "dissolve returns a candidate and leaves its input unchanged")
	var closed: Dictionary = dissolved.state
	_expect(Organization.valid(closed), "A dissolved document is still valid")
	var org: Dictionary = closed.organizations["coop"]
	_expect(org.status == Organization.STATUS_CLOSED, "The organization status becomes closed")
	_expect(float(org.closed_utc) == START + 100.0 and org.closed_by == PLAYER_A,
		"The closing time and actor are recorded")
	_expect(org.members.size() == 3
		and org.members[PLAYER_A] == Organization.ROLE_LEADER
		and org.members[PLAYER_B] == Organization.ROLE_OFFICER
		and org.members[PLAYER_C] == Organization.ROLE_MEMBER,
		"Dissolving keeps every member row and its position")
	_expect(Organization.role_of(closed, "coop", PLAYER_B).is_empty(),
		"A closed organization grants no operative role")
	_expect(Organization.historic_role_of(closed, "coop", PLAYER_B) \
		== Organization.ROLE_OFFICER,
		"The historic role is still readable through historic_role_of")
	_expect(org.account_id == "org_coop", "Dissolving does not change the asset identity")
	var history: Array = org.history
	_expect(history.size() == 5, "Creation, two joins, one appointment and closure are recorded")
	_expect(history[0].kind == Organization.HISTORY_CREATED
		and history[0].actor == PLAYER_A and float(history[0].at_utc) == START,
		"The first history row is still the creation")
	_expect(history[4].kind == Organization.HISTORY_DISSOLVED
		and history[4].actor == PLAYER_A and str(history[4].target).is_empty()
		and float(history[4].at_utc) == START + 100.0,
		"The last history row records who dissolved it and when")
	_expect(closed.command_results.has("close-1"),
		"The successful dissolve is recorded under its command id")
	var recorded: Dictionary = closed.command_results["close-1"].result
	_expect(recorded.organization_id == "coop" and recorded.clearing.balance == 100,
		"The recorded result carries the organization and balance")
	_expect(dissolved.organization_id == "coop"
		and str(dissolved.clearing.account_id) == "org_coop",
		"The dissolve reply carries the same clearing intent")
	_expect(dissolved.clearing.refunds == recorded.clearing.refunds,
		"The reply and the recorded result describe the same refunds")


func _test_permission_refusals() -> void:
	var state: Dictionary = _member_state()
	var accepted: Dictionary = state.duplicate(true)
	_expect(Organization.dissolve(state, "coop", PLAYER_B, START + 100.0,
		_options("officer", 0, 0, {})).reason == "not_leader",
		"An officer cannot dissolve the organization")
	_expect(Organization.dissolve(state, "coop", PLAYER_C, START + 100.0,
		_options("member", 0, 0, {})).reason == "not_leader",
		"A plain member cannot dissolve the organization")
	_expect(Organization.dissolve(state, "coop", PLAYER_D, START + 100.0,
		_options("stranger", 0, 0, {})).reason == "not_member",
		"A connected stranger cannot dissolve the organization")
	_expect(state == accepted, "Refused dissolves leave the document unchanged")
	_expect(Organization.dissolve(state, "missing", PLAYER_A, START + 100.0,
		_options("missing", 0, 0, {})).reason == "unknown_org",
		"Dissolving an unknown organization is refused")
	for bad_actor: Variant in ["", "@world", "bad actor", 42, null]:
		_expect(Organization.dissolve(state, "coop", bad_actor, START + 100.0,
			_options("bad-actor", 0, 0, {})).reason == "invalid_player",
			"Dissolving with an illegal actor id is refused")
	for bad_time: float in [-1.0, INF, NAN]:
		_expect(Organization.dissolve(state, "coop", PLAYER_A, bad_time,
			_options("bad-time", 0, 0, {})).reason == "invalid_time",
			"Dissolving with an illegal time is refused")
	_expect(Organization.dissolve(state, "coop", PLAYER_A, START - 5.0,
		_options("before-creation", 0, 0, {})).reason == "time_regression",
		"Dissolving before the organization existed is refused")
	_expect(Organization.dissolve(state, "coop", PLAYER_A, START + 1.0,
		_options("before-last-history", 0, 0, {})).reason == "time_regression",
		"Dissolving before the last recorded history row is refused")
	_expect(Organization.join(state, "coop", PLAYER_D, START + 0.5).reason \
		== "time_regression", "Joining before the last history row is refused")
	_expect(Organization.leave(state, "coop", PLAYER_C, START + 0.5).reason \
		== "time_regression", "Leaving before the last history row is refused")
	_expect(Organization.appoint(state, "coop", PLAYER_A, PLAYER_C,
		Organization.ROLE_MEMBER, START + 0.5).reason == "time_regression",
		"Appointing before the last history row is refused")
	_expect(Organization.transfer_leadership(state, "coop", PLAYER_A, PLAYER_B,
		START + 0.5).reason == "time_regression",
		"Handing over before the last history row is refused")

	var closed: Dictionary = Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		_options("close-once", 0, 0, {})).state
	_expect(Organization.dissolve(closed, "coop", PLAYER_A, START + 200.0,
		_options("close-twice", 0, 0, {})).reason == "already_closed",
		"An already closed organization cannot be dissolved again")


func _test_preconditions() -> void:
	var state: Dictionary = _member_state()
	var accepted: Dictionary = state.duplicate(true)
	_expect(Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		_options("pending", 50, 1, {PLAYER_A: 50})).reason == "pending_spend",
		"An unsettled spend authorization blocks dissolution")
	_expect(state == accepted, "A refused precondition leaves the document unchanged")
	_expect(Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		_options("unowned", 100, 0, {})).reason == "unowned_balance",
		"A positive balance with no contributors has no defined recipient")
	_expect(Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		_options("unowned-zero", 100, 0, {PLAYER_A: 0})).reason == "unowned_balance",
		"A positive balance with only zero contributions has no defined recipient")
	for bad_options: Variant in [null, [], {}, "close"]:
		_expect(Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
			bad_options).reason == "invalid_options",
			"A non-dictionary or wrong-sized options value is refused")
	_expect(Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		{"command_id": "short", "balance": 0, "pending_spend": 0}).reason \
		== "invalid_options", "Options with a missing key are refused")
	var extra: Dictionary = _options("extra", 0, 0, {})
	extra["account_id"] = "org_other"
	_expect(Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		extra).reason == "invalid_options", "Options with an unknown key are refused")
	_expect(Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		_options("", 0, 0, {})).reason == "invalid_command_id",
		"An empty command id is refused")
	_expect(Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		_options("x".repeat(Organization.MAX_COMMAND_ID_LENGTH + 1), 0, 0, {})).reason \
		== "invalid_command_id", "An over-long command id is refused")
	for bad_balance: Variant in [-1, 1.5, INF, NAN, "100", null]:
		_expect(Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
			{"command_id": "bad-balance", "balance": bad_balance, "pending_spend": 0,
			"contributors": {}}).reason == "invalid_balance",
			"An illegal balance is refused")
	for bad_pending: Variant in [-1, 1.5, INF, NAN, "1", null]:
		_expect(Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
			{"command_id": "bad-pending", "balance": 0, "pending_spend": bad_pending,
			"contributors": {}}).reason == "invalid_pending_spend",
			"An illegal pending spend count is refused")
	for bad_contributors: Variant in [null, [], {"bad player": 1}, {PLAYER_A: -1},
			{PLAYER_A: 1.5}, {42: 1}]:
		_expect(Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
			{"command_id": "bad-contributors", "balance": 0, "pending_spend": 0,
			"contributors": bad_contributors}).reason == "invalid_contributors",
			"An illegal contributor table is refused")
	_expect(Organization.dissolve({"organizations": {}}, "coop", PLAYER_A, START,
		_options("malformed", 0, 0, {})).reason == "invalid_state",
		"A malformed input document cannot dissolve an organization")
	_expect(Organization.dissolve(state, "bad org", PLAYER_A, START,
		_options("bad-org", 0, 0, {})).reason == "invalid_org",
		"An illegal organization id is refused before lookup")


func _test_clearing_order_and_conservation() -> void:
	var state: Dictionary = _member_state()
	var even: Dictionary = Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		_options("even", 100, 0, {PLAYER_A: 1, PLAYER_B: 1, PLAYER_C: 1}))
	_expect(even.ok, "A three-contributor organization dissolves")
	var refunds: Array = even.clearing.refunds
	_expect(_ids(refunds) == [PLAYER_A, PLAYER_B, PLAYER_C],
		"Refund rows are ordered by ascending player id")
	_expect(_amounts(refunds) == [34, 33, 33],
		"The remainder unit goes to the first id in the deterministic order")
	_expect(_total(refunds) == 100, "The refunds conserve the whole balance")
	_expect(even.state.organizations.coop.history[4].kind == Organization.HISTORY_DISSOLVED,
		"The closed document still records the dissolve at the end")

	var uneven: Dictionary = Organization.dissolve(state, "coop", PLAYER_A, START + 101.0,
		_options("uneven", 100, 0, {PLAYER_C: 1, PLAYER_A: 2}))
	_expect(_ids(uneven.clearing.refunds) == [PLAYER_A, PLAYER_C],
		"Refund order does not depend on contributor insertion order")
	_expect(_amounts(uneven.clearing.refunds) == [67, 33],
		"Proportional shares round down and the remainder goes to the lowest id")
	_expect(_total(uneven.clearing.refunds) == 100,
		"An uneven split still conserves the balance")

	var empty: Dictionary = Organization.dissolve(state, "coop", PLAYER_A, START + 102.0,
		_options("empty", 0, 0, {PLAYER_A: 5}))
	_expect(empty.ok and (empty.clearing.refunds as Array).is_empty()
		and int(empty.clearing.balance) == 0,
		"A zero balance closes with no refunds")

	var zero_member: Dictionary = Organization.dissolve(state, "coop", PLAYER_A,
		START + 103.0, _options("zero-member", 10, 0, {PLAYER_A: 0, PLAYER_B: 10}))
	_expect(_ids(zero_member.clearing.refunds) == [PLAYER_B]
		and _amounts(zero_member.clearing.refunds) == [10],
		"A zero-contribution member receives no refund row")

	var large: Dictionary = Organization.dissolve(state, "coop", PLAYER_A, START + 104.0,
		_options("large", Organization.MAX_BALANCE, 0,
			{PLAYER_A: Organization.MAX_CONTRIBUTION, PLAYER_B: 1}))
	_expect(large.ok and _total(large.clearing.refunds) == Organization.MAX_BALANCE,
		"The largest accepted balance is conserved exactly")


func _test_replay() -> void:
	var state: Dictionary = _member_state()
	var first: Dictionary = Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		_options("replay", 90, 0, {PLAYER_A: 2, PLAYER_B: 1}))
	_expect(first.ok and first.duplicate == false, "The first dissolve succeeds")
	var closed: Dictionary = first.state
	var replay: Dictionary = Organization.dissolve(closed, "coop", PLAYER_A, START + 100.0,
		_options("replay", 90, 0, {PLAYER_A: 2, PLAYER_B: 1}))
	_expect(replay.ok and replay.duplicate == true,
		"Retrying the same command id replays the first result")
	_expect(replay.state == closed, "A replay returns the same document without a second close")
	_expect(replay.clearing == first.clearing,
		"A replay returns the identical clearing intent")
	_expect(Organization.dissolve(closed, "coop", PLAYER_A, START + 100.0,
		_options("replay", 91, 0, {PLAYER_A: 2, PLAYER_B: 1})).reason \
		== "command_conflict", "Reusing a command id with a different payload conflicts")
	_expect(Organization.dissolve(closed, "coop", PLAYER_A, START + 200.0,
		_options("replay", 90, 0, {PLAYER_A: 2, PLAYER_B: 1})).reason \
		== "command_conflict", "Reusing a command id with a different time conflicts")

	# A canonical payload means the same facts in another dictionary order replay.
	var reordered: Dictionary = Organization.dissolve(closed, "coop", PLAYER_A, START + 100.0,
		_options("replay", 90, 0, {PLAYER_B: 1, PLAYER_A: 2}))
	_expect(reordered.ok and reordered.duplicate == true,
		"The same contributors in another insertion order still replay")

	var other: Dictionary = _member_state()
	var second: Dictionary = Organization.dissolve(other, "coop", PLAYER_A, START + 100.0,
		_options("replay", 90, 0, {PLAYER_A: 2, PLAYER_B: 1}))
	_expect(second.ok, "A different document may reuse the command id")
	_expect(second.state.command_results.size() == 1,
		"The command window holds exactly one dissolve record")


func _test_closed_organization_operations() -> void:
	var closed: Dictionary = Organization.dissolve(_member_state(), "coop", PLAYER_A,
		START + 100.0, _options("ops", 10, 0, {PLAYER_A: 10})).state
	var accepted: Dictionary = closed.duplicate(true)
	_expect(Organization.join(closed, "coop", PLAYER_D, START + 101.0).reason == "org_closed",
		"A closed organization refuses new members")
	_expect(Organization.leave(closed, "coop", PLAYER_C, START + 101.0).reason == "org_closed",
		"A closed organization refuses departures")
	_expect(Organization.appoint(closed, "coop", PLAYER_A, PLAYER_C,
		Organization.ROLE_OFFICER, START + 101.0).reason == "org_closed",
		"A closed organization refuses appointments")
	_expect(Organization.transfer_leadership(closed, "coop", PLAYER_A, PLAYER_B,
		START + 101.0).reason == "org_closed",
		"A closed organization refuses leadership handovers")
	_expect(Organization.authorize_spend(closed, "coop", PLAYER_A, "org_coop", 10,
		START + 101.0).reason == "org_closed",
		"A closed organization refuses spend authorization")
	_expect(closed == accepted, "Closed-organization refusals change nothing")
	var reopened: Dictionary = Organization.create(closed, "guild", "新商会", PLAYER_D, START + 102.0)
	_expect(reopened.ok and reopened.state.organizations.has("coop")
		and reopened.state.organizations.coop.status == Organization.STATUS_CLOSED,
		"A new organization can be created without reviving the closed row")
	_expect(Organization.valid(reopened.state),
		"The document stays valid with one closed and one active organization")


## 退款前写入的解散意图：纯规则层必须能严格校验、原样完成，并且不会把同一
## 授权重复写入或留到关闭之后。
func _test_pending_dissolve_intent() -> void:
	var state: Dictionary = _member_state()
	var original: Dictionary = state.duplicate(true)
	var contributors: Dictionary = {PLAYER_A: 1, PLAYER_B: 2}
	var marked: Dictionary = Organization.mark_pending_dissolve(state, "coop",
		"pend-1", PLAYER_A, START + 100.0, 90, contributors)
	_expect(marked.ok and Organization.valid(marked.state),
		"A pending dissolve intent is valid")
	_expect(state == original, "Marking an intent leaves its input unchanged")
	var pending: Dictionary = Organization.pending_dissolve(marked.state, "coop")
	_expect(str(pending.get("command_id", "")) == "pend-1"
			and int(pending.get("balance", 0)) == 90,
		"The intent keeps the command and balance it was authorized with")
	_expect(str(Organization.pending_dissolve(state, "coop")
			.get("command_id", "")).is_empty(),
		"The input document has no intent")
	_expect(Organization.mark_pending_dissolve(marked.state, "coop", "pend-2",
		PLAYER_A, START + 101.0, 90, contributors).reason == "pending_exists",
		"A second intent for the same organization is refused")
	_expect(Organization.mark_pending_dissolve(state, "coop", "pend-1",
		PLAYER_A, START + 100.0, 0, contributors).reason == "invalid_clearing",
		"A zero balance intent is refused")
	_expect(Organization.mark_pending_dissolve(state, "coop", "pend-3",
		PLAYER_A, START + 100.0, 90, {}).reason == "invalid_clearing",
		"An intent without contributors is refused")
	_expect(Organization.mark_pending_dissolve(state, "ghost", "pend-4",
		PLAYER_A, START + 100.0, 90, contributors).reason == "unknown_org",
		"An intent for an unknown organization is refused")

	var finished: Dictionary = Organization.finish_pending_dissolve(marked.state, "coop")
	_expect(finished.ok and Organization.valid(finished.state),
		"Finishing an intent produces a valid closed document")
	var row: Dictionary = finished.state.organizations["coop"]
	_expect(str(row.status) == Organization.STATUS_CLOSED
			and float(row.closed_utc) == START + 100.0
			and str(row.closed_by) == PLAYER_A,
		"Finishing closes the organization with the intent's time and actor")
	_expect(not finished.state.has(Organization.PENDING_DISSOLVES_KEY),
		"Finishing removes the intent from the document")
	var clearing: Dictionary = finished.get("clearing", {})
	_expect(int(clearing.get("balance", 0)) == 90
			and (clearing.get("refunds", []) as Array).size() == 2,
		"The completed intent returns the same clearing table")
	_expect(Organization.finish_pending_dissolve(finished.state, "coop").reason \
		== "no_pending", "Finishing twice is refused")
	var replay: Dictionary = Organization.dissolve(finished.state, "coop", PLAYER_A,
		START + 100.0, _options("pend-1", 90, 0, contributors))
	_expect(replay.ok and replay.duplicate,
		"The recorded intent command replays after completion")
	_expect(Organization.valid(marked.state.duplicate(true)),
		"A pending document stays valid after plain duplication")
	var rounded: Variant = JSON.parse_string(JSON.stringify(marked.state))
	_expect(Organization.valid(rounded)
			and str(Organization.pending_dissolve(rounded, "coop")
				.get("command_id", "")) == "pend-1",
		"A pending document survives a JSON round trip")

	var closed: Dictionary = Organization.dissolve(state, "coop", PLAYER_A,
		START + 100.0, _options("closed-1", 90, 0, contributors)).state
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc[Organization.PENDING_DISSOLVES_KEY] = {"coop": pending}),
		"A closed organization cannot carry a pending intent")
	_expect(_rejects(marked.state, func(doc: Dictionary) -> void:
		doc[Organization.PENDING_DISSOLVES_KEY]["coop"]["extra"] = true),
		"An unknown intent key is rejected")
	_expect(_rejects(marked.state, func(doc: Dictionary) -> void:
		var intent: Variant = doc[Organization.PENDING_DISSOLVES_KEY]["coop"]
		doc[Organization.PENDING_DISSOLVES_KEY]["ghost"] = intent),
		"An intent for an unknown organization is rejected")
	_expect(_rejects(marked.state, func(doc: Dictionary) -> void:
		doc[Organization.PENDING_DISSOLVES_KEY]["coop"]["command_id"] = ""),
		"An empty intent command id is rejected")
	_expect(_rejects(marked.state, func(doc: Dictionary) -> void:
		doc[Organization.PENDING_DISSOLVES_KEY]["coop"]["balance"] = 0),
		"A zero intent balance is rejected")
	_expect(_rejects(marked.state, func(doc: Dictionary) -> void:
		doc[Organization.PENDING_DISSOLVES_KEY]["coop"]["at_utc"] = START - 1.0),
		"An intent time before the organization history is rejected")
	_expect(_rejects(marked.state, func(doc: Dictionary) -> void:
		doc[Organization.PENDING_DISSOLVES_KEY]["coop"]["contributors"] = {}),
		"An intent without contributors is rejected")
	_expect(_rejects(marked.state, func(doc: Dictionary) -> void:
		doc[Organization.PENDING_DISSOLVES_KEY]["coop"]["actor"] = ""),
		"An intent without an authorizing actor is rejected")
	_expect(_rejects(marked.state, func(doc: Dictionary) -> void:
		doc["command_results"]["pend-1"] = {
			"payload": "dissolve:" + "0".repeat(64),
			"result": {"ok": true, "reason": "", "organization_id": "coop",
				"clearing": clearing},
		}),
		"An intent whose command id is already recorded is rejected")


func _test_document_validity() -> void:
	var closed: Dictionary = Organization.dissolve(_member_state(), "coop", PLAYER_A,
		START + 100.0, _options("doc", 100, 0, {PLAYER_A: 1, PLAYER_B: 1})).state
	_expect(Organization.valid(JSON.parse_string(JSON.stringify(closed))),
		"A dissolved document remains valid after a JSON round trip")
	_expect(not Organization.valid(null) and not Organization.valid([])
		and not Organization.valid({}),
		"A non-dictionary or structurally empty document is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void: doc["extra"] = true),
		"An unknown top-level key is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void: doc.erase("command_results")),
		"A missing command window is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["status"] = "archived"),
		"An unknown status value is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["extra"] = true),
		"An unknown organization key is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["history"][0]["extra"] = true),
		"An unknown history key is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["history"][0]["kind"] = "founded"),
		"An unknown history kind is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["history"][0]["at_utc"] = START + 1.0),
		"A creation history row that disagrees with created_utc is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["history"].insert(1,
			{"kind": "created", "actor": PLAYER_A, "target": "", "at_utc": START})),
		"A second creation history row is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["history"][1]["target"] = PLAYER_C),
		"A join history row with a target is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["history"][3]["target"] = PLAYER_B),
		"An appointment history row that names its own actor is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		var rows: Array = doc["organizations"]["coop"]["history"]
		rows.remove_at(rows.size() - 1)),
		"A closed organization whose last history row is not the dissolution is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["history"][4]["actor"] = PLAYER_B),
		"A dissolution row whose actor differs from closed_by is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["history"][4]["at_utc"] = START + 99.0),
		"A dissolution row whose time differs from closed_utc is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		var rows: Array = doc["organizations"]["coop"]["history"]
		var swapped: Variant = rows[1]
		rows[1] = rows[2]
		rows[2] = swapped),
		"History rows whose times move backwards are rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["closed_by"] = ""),
		"A closed organization without a closing actor is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["closed_utc"] = 0.0),
		"A closed organization with a zero closing time is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["closed_utc"] = START - 1.0),
		"A closing time before creation is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["status"] = Organization.STATUS_ACTIVE),
		"An active organization that still has a dissolution record is rejected")
	var restored: Dictionary = closed.duplicate(true)
	var restored_org: Dictionary = restored["organizations"]["coop"]
	restored_org["status"] = Organization.STATUS_ACTIVE
	restored_org["closed_by"] = ""
	restored_org["closed_utc"] = 0.0
	restored_org["history"].remove_at(restored_org["history"].size() - 1)
	restored["command_results"] = {}
	_expect(Organization.valid(restored),
		"An active organization with only the creation row stays valid")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["history"][4]["kind"] = Organization.HISTORY_LEFT),
		"A closed organization without a dissolution row is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["members"].erase(PLAYER_A)),
		"A closed organization still needs its historic leader")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"].erase("doc")),
		"A closed organization without a command record is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["extra"] = true),
		"An unknown command record key is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["payload"] = ""),
		"An empty command payload is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["payload"] = "dissolve:" + "z".repeat(64)),
		"A payload that is not a lowercase hex digest is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["payload"] = "dissolve:abc"),
		"A truncated payload digest is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["result"]["ok"] = false),
		"A recorded failed dissolve result is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["result"]["reason"] = "not_leader"),
		"A recorded dissolve result with a reason is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["result"]["organization_id"] = "other"),
		"A command record that points at another organization is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["result"]["clearing"]["account_id"] = "org_other"),
		"A clearing intent that names another account is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["result"]["clearing"]["balance"] = 99),
		"A clearing balance that disagrees with the refunds is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["result"]["clearing"]["refunds"].reverse()),
		"Refund rows out of ascending id order are rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["result"]["clearing"]["refunds"].append(
			{"player_id": PLAYER_A, "amount": 1})),
		"A duplicated refund recipient is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["result"]["clearing"]["refunds"][0]["extra"] = 1),
		"An unknown refund key is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["result"]["clearing"]["refunds"][0]["amount"] = 0),
		"A zero refund row is rejected")
	_expect(_rejects(closed, func(doc: Dictionary) -> void:
		doc["command_results"]["doc"]["result"]["clearing"]["refunds"][0]["player_id"] \
			= "bad player"),
		"An illegal refund recipient is rejected")

	var active: Dictionary = _member_state()
	_expect(_rejects(active, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["extra"] = true),
		"An unknown organization key is rejected on an active organization")
	_expect(_rejects(active, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["status"] = "paused"),
		"An unknown status is rejected on an active organization")
	_expect(_rejects(active, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["closed_by"] = PLAYER_A),
		"An active organization with a closing actor is rejected")
	_expect(_rejects(active, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["closed_utc"] = START + 1.0),
		"An active organization with a closing time is rejected")
	_expect(_rejects(active, func(doc: Dictionary) -> void:
		doc["organizations"]["coop"]["history"].append(
			{"kind": "dissolved", "actor": PLAYER_A, "target": "", "at_utc": START + 1.0})),
		"An active organization with a dissolution row is rejected")
	var copied: Dictionary = active.duplicate(true)
	copied["command_results"]["ghost"] = closed.command_results["doc"].duplicate(true)
	_expect(not Organization.valid(copied),
		"A command record for an active organization is rejected")

	var too_many: Dictionary = closed.duplicate(true)
	for index: int in Organization.MAX_COMMANDS + 1:
		var command_id: String = "bulk_%02d" % index
		too_many["command_results"][command_id] = {
			"payload": JSON.stringify(["dissolve", command_id]),
			"result": {
				"ok": true, "reason": "", "organization_id": "coop",
				"clearing": {"account_id": "org_coop", "balance": 0, "refunds": []},
			},
		}
	_expect(not Organization.valid(too_many),
		"More command records than the bound are rejected")


func _test_determinism() -> void:
	var first: Dictionary = _run_sequence()
	var second: Dictionary = _run_sequence()
	_expect(not first.is_empty() and first == second,
		"The same dissolve sequence produces the same document")

	var state: Dictionary = _member_state()
	var untouched: Dictionary = state.duplicate(true)
	Organization.dissolve(state, "coop", PLAYER_B, START + 1.0, _options("x", 0, 0, {}))
	Organization.dissolve(state, "coop", PLAYER_A, START + 1.0, _options("y", 0, 0, {}))
	_expect(state == untouched, "Library commands never mutate the caller's document")

	var one: Dictionary = Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		_options("same", 55, 0, {PLAYER_A: 3, PLAYER_C: 1}))
	var two: Dictionary = Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		_options("same", 55, 0, {PLAYER_A: 3, PLAYER_C: 1}))
	_expect(one == two, "A dissolve result is deterministic")
	var refusal_one: Dictionary = Organization.dissolve(state, "coop", PLAYER_B,
		START + 100.0, _options("same", 0, 0, {}))
	var refusal_two: Dictionary = Organization.dissolve(state, "coop", PLAYER_B,
		START + 100.0, _options("same", 0, 0, {}))
	_expect(refusal_one.reason == refusal_two.reason
		and refusal_one.reason == "not_leader", "A dissolve refusal is deterministic")


func _run_sequence() -> Dictionary:
	var state: Dictionary = _member_state()
	var dissolved: Dictionary = Organization.dissolve(state, "coop", PLAYER_A, START + 100.0,
		_options("sequence", 100, 0, {PLAYER_A: 1, PLAYER_B: 1, PLAYER_C: 1}))
	if not dissolved.ok:
		return {}
	return dissolved.state


func _options(command_id: String, balance: int, pending_spend: int,
		contributors: Dictionary) -> Dictionary:
	return {
		"command_id": command_id,
		"balance": balance,
		"pending_spend": pending_spend,
		"contributors": contributors.duplicate(true),
	}


func _member_state() -> Dictionary:
	var state: Dictionary = Organization.create(Organization.empty(), "coop",
		"河岸合作社", PLAYER_A, START).state
	state = Organization.join(state, "coop", PLAYER_B, START + 1.0).state
	state = Organization.appoint(state, "coop", PLAYER_A, PLAYER_B,
		Organization.ROLE_OFFICER, START + 2.0).state
	state = Organization.join(state, "coop", PLAYER_C, START + 3.0).state
	return state


func _ids(refunds: Array) -> Array:
	var result: Array = []
	for entry: Variant in refunds:
		result.append(str((entry as Dictionary)["player_id"]))
	return result


func _amounts(refunds: Array) -> Array:
	var result: Array = []
	for entry: Variant in refunds:
		result.append(int((entry as Dictionary)["amount"]))
	return result


func _total(refunds: Array) -> int:
	var total: int = 0
	for entry: Variant in refunds:
		total += int((entry as Dictionary)["amount"])
	return total


func _rejects(state: Dictionary, mutate: Callable) -> bool:
	var copy: Dictionary = state.duplicate(true)
	mutate.call(copy)
	return not Organization.valid(copy)


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
