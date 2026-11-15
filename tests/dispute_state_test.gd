extends SceneTree
## M12-04 纠纷登记纯规则测试。无场景、无时钟、无 RNG、无网络、无存档。
## 每条命令都显式传入 UTC 时间；所有变更入口写时复制，测试只通过返回的
## `state` 候选继续，末行是验证证据。

const Disputes = preload("res://world/dispute_state.gd")

const START: float = 1800000000.0

const FILER: String = "player_00000000000000000000000000000001"
const TARGET: String = "player_00000000000000000000000000000002"
const ADMIN: String = "player_00000000000000000000000000000003"
const ADMIN_2: String = "player_00000000000000000000000000000004"
const ARBITER: String = "player_00000000000000000000000000000005"
const OUTSIDER: String = "player_00000000000000000000000000000006"
const ADVISOR: String = "player_00000000000000000000000000000007"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_empty_and_bounds()
	_test_copy_on_write()
	_test_filing()
	_test_accept_permissions()
	_test_reject()
	_test_evidence_validation()
	_test_evidence_statuses()
	_test_rule_advisor()
	_test_appeal_and_correction()
	_test_correction_without_appeal()
	_test_invalid_documents()
	_test_capacity()
	for failure: String in failures:
		push_error(failure)
	print("DISPUTE_STATE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_empty_and_bounds() -> void:
	var state: Dictionary = Disputes.empty()
	_expect(Disputes.valid(state), "An empty dispute document is valid")
	_expect(state.cases.is_empty(), "An empty document has no cases")

	var with_roles: Dictionary = _state()
	_expect(Disputes.valid(with_roles), "A document with an authority roster is valid")
	_expect(Disputes.empty([ADMIN], [ADMIN]).authority_roles.admin.size() == 1,
		"empty() keeps the supplied roster as-is")
	_expect(not Disputes.valid(Disputes.empty([ADMIN], [ADMIN])),
		"A player may not be both admin and arbiter")
	_expect(not Disputes.valid(Disputes.empty(["bad id"], [])),
		"An invalid authority id is refused")
	_expect(not Disputes.valid(Disputes.empty([ADMIN, ADMIN], [])),
		"A duplicate authority id is refused")

	var extra: Dictionary = _state()
	extra.extra = 1
	_expect(not Disputes.valid(extra), "An unknown top-level key is refused")
	var wrong_cases: Dictionary = _state()
	wrong_cases.cases = []
	_expect(not Disputes.valid(wrong_cases), "A non-dictionary cases field is refused")


## 写时复制契约：成功返回候选但不改输入；连续变更基于前一个候选；失败不带
## state，也不修改输入。
func _test_copy_on_write() -> void:
	var base: Dictionary = _state()
	var base_json: String = JSON.stringify(base)
	var filed: Dictionary = Disputes.file(base, "case_1", FILER, TARGET, ["event_1"], START)
	_expect(filed.ok and filed.get("state") is Dictionary,
		"A successful mutation returns a candidate document")
	_expect(JSON.stringify(base) == base_json, "file() leaves the input byte-identical")
	_expect(base.cases.is_empty(), "The caller's base document still has no case")

	var accepted: Dictionary = Disputes.accept(filed.state, "case_1", ADMIN, START + 1.0)
	_expect(accepted.ok, "A second mutation builds on the first returned candidate")
	_expect(filed.state.cases.case_1.audit.is_empty(),
		"The first candidate is not mutated by the second operation")
	_expect(accepted.state.cases.case_1.audit.size() == 1,
		"Only the second candidate carries the acceptance audit")

	var accepted_json: String = JSON.stringify(accepted.state)
	var refused: Dictionary = Disputes.accept(accepted.state, "case_1", ARBITER, START + 2.0)
	_expect(not refused.ok and refused.reason == "invalid_status",
		"A refused mutation reports its reason")
	_expect(not refused.has("state"),
		"A refused mutation does not return a candidate document")
	_expect(JSON.stringify(accepted.state) == accepted_json,
		"A refused mutation leaves its input byte-identical")
	_expect(Disputes.valid(accepted.state),
		"The unchanged input is still a valid applied document")


func _test_filing() -> void:
	var state: Dictionary = _state()
	var before_json: String = JSON.stringify(state)
	var no_events: Dictionary = Disputes.file(state, "case_1", FILER, TARGET, [], START)
	_expect(no_events.reason == "no_events",
		"A case without an authoritative event id is refused")
	_expect(not no_events.has("state"), "A refused filing returns no candidate")
	_expect(JSON.stringify(state) == before_json, "A refused filing changes nothing")
	_expect(Disputes.file(state, "case_1", FILER, TARGET, "event_1", START).reason
		== "no_events", "A non-array event list is refused")
	_expect(Disputes.file(state, "case_1", FILER, TARGET, ["event_1", "event_1"], START)
		.reason == "invalid_events", "Duplicate authoritative event ids are refused")
	_expect(Disputes.file(state, "case_1", FILER, FILER, ["event_1"], START).reason
		== "same_player", "A player cannot file against themselves")
	_expect(Disputes.file(state, "bad id", FILER, TARGET, ["event_1"], START).reason
		== "invalid_case", "An invalid case id is refused")
	_expect(Disputes.file(state, "case_1", FILER, TARGET, ["event_1"], -1.0).reason
		== "invalid_time", "A negative filing time is refused")
	_expect(JSON.stringify(state) == before_json,
		"All refused filings leave the input byte-identical")
	_expect(state.cases.is_empty(), "All refused filings leave the document empty")

	var filed: Dictionary = Disputes.file(state, "case_1", FILER, TARGET,
		["event_1", "event_2"], START)
	_expect(filed.ok and filed.status == Disputes.STATUS_FILED,
		"A filing with an authority event is accepted")
	_expect(filed.get("state") is Dictionary,
		"A successful filing returns a candidate document")
	_expect(JSON.stringify(state) == before_json,
		"A successful filing leaves the input unchanged")
	var candidate: Dictionary = filed.state
	_expect(candidate.cases.has("case_1"), "The candidate stores the case by id")
	_expect(candidate.cases.case_1.event_ids.size() == 2
		and candidate.cases.case_1.event_ids[0] == "event_1",
		"The authoritative event ids are kept")
	_expect(candidate.cases.case_1.manager_only == true,
		"A case is always manager-only")
	_expect(candidate.cases.case_1.audit.is_empty(),
		"Filing itself is not a manager action and writes no audit row")
	_expect(Disputes.valid(candidate), "A filed candidate is valid")
	_expect(Disputes.valid(state), "The unchanged input remains valid")

	var candidate_json: String = JSON.stringify(candidate)
	var duplicate: Dictionary = Disputes.file(candidate, "case_1", FILER, TARGET,
		["event_3"], START)
	_expect(duplicate.reason == "duplicate_case", "A duplicate case id is refused")
	_expect(not duplicate.has("state"), "A duplicate filing returns no candidate")
	_expect(JSON.stringify(candidate) == candidate_json,
		"A duplicate filing leaves its input unchanged")


func _test_accept_permissions() -> void:
	var base: Dictionary = _state()
	var state: Dictionary = _apply(base,
		Disputes.file(base, "case_1", FILER, TARGET, ["event_1"], START), "file case_1")
	var filed_json: String = JSON.stringify(state)
	var outsider: Dictionary = Disputes.accept(state, "case_1", OUTSIDER, START)
	_expect(outsider.reason == "not_authority", "An outsider cannot accept a case")
	_expect(not outsider.has("state"), "An unauthorized acceptance returns no candidate")
	_expect(JSON.stringify(state) == filed_json,
		"A refused acceptance leaves the input unchanged")
	_expect(Disputes.accept(state, "case_1", ADMIN, START - 1.0).reason
		== "time_regression", "Acceptance before filing is refused")
	_expect(Disputes.accept(state, "missing", ADMIN, START).reason == "missing_case",
		"A missing case is refused by name")
	_expect(Disputes.accept(state, "case_1", "bad id", START).reason == "invalid_player",
		"An invalid actor id is refused")

	var accepted: Dictionary = Disputes.accept(state, "case_1", ADMIN, START + 1.0)
	_expect(accepted.ok and accepted.status == Disputes.STATUS_ACCEPTED,
		"A listed admin can accept a filed case")
	_expect(accepted.get("state") is Dictionary,
		"Acceptance returns a candidate document")
	_expect(JSON.stringify(state) == filed_json,
		"Acceptance leaves the input filed and byte-identical")
	_expect(state.cases.case_1.status == Disputes.STATUS_FILED,
		"The caller's input is still filed")
	var candidate: Dictionary = accepted.state
	_expect(candidate.cases.case_1.status == Disputes.STATUS_ACCEPTED,
		"The candidate carries the accepted status")
	_expect(candidate.cases.case_1.audit.size() == 1,
		"Acceptance appends exactly one audit row")
	_expect(candidate.cases.case_1.audit[0].action == Disputes.ACTION_ACCEPT
		and candidate.cases.case_1.audit[0].by == ADMIN
		and candidate.cases.case_1.audit[0].at_utc == START + 1.0,
		"The acceptance audit records actor and time")
	_expect(Disputes.valid(candidate), "An accepted candidate is valid")
	_expect(Disputes.accept(candidate, "case_1", ARBITER, START + 2.0).reason
		== "invalid_status", "A case cannot be accepted twice")
	_expect(Disputes.reject(candidate, "case_1", ADMIN, START + 2.0).reason
		== "invalid_status", "An accepted case cannot be rejected")
	_expect(candidate.cases.case_1.status == Disputes.STATUS_ACCEPTED,
		"Refused transitions keep the accepted status")

	var ruled: Dictionary = Disputes.rule(candidate, "case_1", ADMIN,
		_authority_decision(Disputes.OUTCOME_WARNING, "second step"), START + 2.0)
	_expect(ruled.ok, "A second mutation can build directly on the first candidate")
	_expect(ruled.state.cases.case_1.status == Disputes.STATUS_RULED,
		"The second candidate carries both transitions")
	_expect(candidate.cases.case_1.status == Disputes.STATUS_ACCEPTED,
		"The first candidate is not mutated by the second operation")
	_expect(state.cases.case_1.status == Disputes.STATUS_FILED,
		"The original input is still filed after two mutations")

	var second_state: Dictionary = _apply(_state(),
		Disputes.file(_state(), "case_2", FILER, TARGET, ["event_2"], START), "file case_2")
	_expect(Disputes.accept(second_state, "case_2", ARBITER, START).ok,
		"A listed arbiter can also accept a case")


func _test_reject() -> void:
	var base: Dictionary = _state()
	var state: Dictionary = _apply(base,
		Disputes.file(base, "case_1", FILER, TARGET, ["event_1"], START), "file case_1")
	var before_json: String = JSON.stringify(state)
	var rejected: Dictionary = Disputes.reject(state, "case_1", ARBITER, START + 1.0)
	_expect(rejected.ok and rejected.status == Disputes.STATUS_REJECTED,
		"An arbiter can reject a malicious report")
	_expect(JSON.stringify(state) == before_json,
		"Rejection leaves the input filed and unchanged")
	var candidate: Dictionary = rejected.state
	_expect(candidate.cases.case_1.audit.size() == 1
		and candidate.cases.case_1.audit[0].action == Disputes.ACTION_REJECT,
		"Rejection writes its own audit row")
	_expect(Disputes.valid(candidate), "A rejected candidate is valid")
	_expect(Disputes.accept(candidate, "case_1", ADMIN, START + 2.0).reason
		== "invalid_status", "A rejected case cannot be accepted")
	_expect(Disputes.rule(candidate, "case_1", ADMIN,
		_authority_decision(Disputes.OUTCOME_WARNING, "too late"), START + 2.0).reason
		== "invalid_status", "A rejected case cannot be ruled")
	_expect(Disputes.submit_evidence(candidate, "case_1",
		_evidence("ev_1", Disputes.EVIDENCE_LEDGER, "ledger:1", FILER, START + 2.0))
		.reason == "case_closed", "A rejected case accepts no more evidence")


func _test_evidence_validation() -> void:
	var base: Dictionary = _state()
	var state: Dictionary = _apply(base,
		Disputes.file(base, "case_1", FILER, TARGET, ["event_1"], START), "file case_1")
	var before_json: String = JSON.stringify(state)
	var submitted: Dictionary = Disputes.submit_evidence(state, "case_1",
		_evidence("ev_1", Disputes.EVIDENCE_LEDGER, "ledger:1", FILER, START + 1.0))
	_expect(submitted.ok and submitted.status == Disputes.STATUS_FILED,
		"Evidence inside the filing window is accepted")
	_expect(JSON.stringify(state) == before_json,
		"Evidence submission leaves the input unchanged")
	var candidate: Dictionary = submitted.state
	_expect(candidate.cases.case_1.evidence.size() == 1,
		"The candidate carries the submitted evidence")
	_expect(candidate.cases.case_1.status == Disputes.STATUS_FILED,
		"Submitting evidence does not change the case status")
	_expect(Disputes.valid(candidate), "A candidate with evidence is valid")
	_expect(Disputes.submit_evidence(candidate, "case_1",
		_evidence("ev_1", Disputes.EVIDENCE_LEDGER, "ledger:2", FILER, START + 2.0))
		.reason == "duplicate_evidence", "A duplicate evidence id is refused")
	_expect(Disputes.submit_evidence(candidate, "case_1",
		_evidence("ev_2", "rumor", "chat:1", FILER, START + 2.0)).reason
		== "invalid_evidence", "An unknown evidence kind is refused")
	_expect(Disputes.submit_evidence(candidate, "case_1",
		_evidence("ev_2", Disputes.EVIDENCE_CHAT, "chat:1", FILER, START - 1.0))
		.reason == "time_regression", "Evidence dated before filing is refused")
	_expect(Disputes.submit_evidence(candidate, "case_1",
		_evidence("ev_2", Disputes.EVIDENCE_CHAT, "chat:1", FILER,
		START + Disputes.EVIDENCE_WINDOW_SECONDS + 1.0)).reason == "evidence_expired",
		"Evidence submitted after the evidence window is refused")
	var boundary: Dictionary = Disputes.submit_evidence(candidate, "case_1",
		_evidence("ev_2", Disputes.EVIDENCE_CHAT, "chat:1", FILER,
		START + Disputes.EVIDENCE_WINDOW_SECONDS))
	_expect(boundary.ok, "Evidence exactly at the window boundary is accepted")
	_expect(boundary.state.cases.case_1.evidence.size() == 2,
		"The boundary candidate carries both evidence rows")
	_expect(candidate.cases.case_1.evidence.size() == 1,
		"The earlier candidate is not mutated by the boundary submission")
	_expect(Disputes.submit_evidence(boundary.state, "case_1",
		_evidence("ev_3", Disputes.EVIDENCE_WITNESS, "witness:1", FILER,
		START + Disputes.EVIDENCE_WINDOW_SECONDS + 1.0)).reason == "evidence_expired",
		"Evidence one second past the boundary is refused")
	_expect(Disputes.valid(boundary.state), "Boundary evidence keeps the candidate valid")


func _test_evidence_statuses() -> void:
	var state: Dictionary = _state()
	state = _apply(state, Disputes.file(state, "case_1", FILER, TARGET, ["event_1"], START),
		"file case_1")
	state = _apply(state, Disputes.accept(state, "case_1", ADMIN, START + 1.0),
		"accept case_1")
	state = _apply(state, Disputes.submit_evidence(state, "case_1",
		_evidence("ev_1", Disputes.EVIDENCE_WITNESS, "witness:1", FILER, START + 2.0)),
		"evidence while accepted")
	state = _apply(state, Disputes.rule(state, "case_1", ADMIN,
		_authority_decision(Disputes.OUTCOME_WARNING, "first ruling"), START + 3.0),
		"rule case_1")
	state = _apply(state, Disputes.submit_evidence(state, "case_1",
		_evidence("ev_2", Disputes.EVIDENCE_DOCUMENT, "doc:1", FILER, START + 4.0)),
		"evidence while ruled")
	state = _apply(state, Disputes.correct(state, "case_1", ADMIN,
		"fix the ruling", START + 5.0), "correct case_1")
	var refused: Dictionary = Disputes.submit_evidence(state, "case_1",
		_evidence("ev_3", Disputes.EVIDENCE_DOCUMENT, "doc:2", FILER, START + 6.0))
	_expect(refused.reason == "case_closed", "A corrected case accepts no more evidence")
	_expect(not refused.has("state"), "A closed evidence window returns no candidate")
	var corrected_json: String = JSON.stringify(state)
	state = _apply(state, Disputes.close(state, "case_1", ADMIN, START + 7.0),
		"close case_1")
	_expect(JSON.stringify(state) != corrected_json,
		"Closing produces a new candidate rather than the corrected input")
	_expect(Disputes.submit_evidence(state, "case_1",
		_evidence("ev_4", Disputes.EVIDENCE_DOCUMENT, "doc:3", FILER, START + 8.0))
		.reason == "case_closed", "A closed case accepts no more evidence")
	_expect(Disputes.valid(state), "The closed candidate is valid")


func _test_rule_advisor() -> void:
	var state: Dictionary = _state()
	state = _apply(state, Disputes.file(state, "case_1", FILER, TARGET, ["event_1"], START),
		"file case_1")
	state = _apply(state, Disputes.accept(state, "case_1", ADMIN, START + 1.0),
		"accept case_1")
	var accepted_json: String = JSON.stringify(state)
	var advice: Dictionary = {
		"advisor": true, "authority": false,
		"outcome": Disputes.OUTCOME_WARNING, "reason": "suggest a warning",
	}
	var advisory: Dictionary = Disputes.rule(state, "case_1", ADVISOR, advice, START + 2.0)
	_expect(advisory.reason == "advisory_only",
		"An AI suggestion is refused as advisory only")
	_expect(not advisory.has("state"),
		"An AI suggestion returns no candidate document")
	_expect(JSON.stringify(state) == accepted_json,
		"An AI suggestion leaves the input byte-identical")
	_expect(state.cases.case_1.status == Disputes.STATUS_ACCEPTED,
		"An AI suggestion cannot move a case to ruled")

	var both: Dictionary = advice.duplicate(true)
	both.authority = true
	_expect(Disputes.rule(state, "case_1", ADMIN, both, START + 2.0).reason
		== "invalid_decision", "A decision cannot be both advice and authority")
	var neither: Dictionary = advice.duplicate(true)
	neither.advisor = false
	_expect(Disputes.rule(state, "case_1", ADMIN, neither, START + 2.0).reason
		== "invalid_decision", "A decision with no mode is refused")
	_expect(JSON.stringify(state) == accepted_json,
		"Invalid decisions leave the input unchanged")
	_expect(Disputes.rule(state, "case_1", OUTSIDER,
		_authority_decision(Disputes.OUTCOME_WARNING, "outsider ruling"), START + 2.0)
		.reason == "not_authority", "An outsider cannot issue an authority ruling")
	_expect(state.cases.case_1.status == Disputes.STATUS_ACCEPTED,
		"An unauthorized ruling leaves the case accepted")
	_expect(Disputes.rule(state, "case_1", ADMIN,
		_authority_decision("bogus", "bad outcome"), START + 2.0).reason
		== "invalid_outcome", "An unknown ruling outcome is refused")
	_expect(Disputes.rule(state, "case_1", ADMIN,
		_authority_decision(Disputes.OUTCOME_WARNING, "   "), START + 2.0).reason
		== "invalid_reason", "A blank ruling reason is refused")
	_expect(Disputes.rule(state, "case_1", ADMIN,
		_authority_decision(Disputes.OUTCOME_WARNING, "first warning"), START).reason
		== "time_regression", "A ruling before acceptance is refused")
	_expect(JSON.stringify(state) == accepted_json,
		"All refused rulings leave the accepted input unchanged")

	var ruled: Dictionary = Disputes.rule(state, "case_1", ADMIN,
		_authority_decision(Disputes.OUTCOME_WARNING, "first warning"), START + 2.0)
	_expect(ruled.ok and ruled.status == Disputes.STATUS_RULED,
		"A listed admin can issue an authority ruling")
	_expect(JSON.stringify(state) == accepted_json,
		"A successful ruling leaves its input accepted and unchanged")
	var candidate: Dictionary = ruled.state
	_expect(candidate.cases.case_1.ruling.outcome == Disputes.OUTCOME_WARNING
		and candidate.cases.case_1.ruling.by == ADMIN
		and candidate.cases.case_1.ruling.at_utc == START + 2.0,
		"The ruling records outcome, actor and time")
	_expect(candidate.cases.case_1.audit.size() == 2
		and candidate.cases.case_1.audit[1].action == Disputes.ACTION_RULE,
		"A ruling appends an independent audit row")
	_expect(Disputes.valid(candidate), "A ruled candidate is valid")
	_expect(Disputes.rule(candidate, "case_1", ARBITER,
		_authority_decision(Disputes.OUTCOME_UPHELD, "second ruling"), START + 3.0)
		.reason == "invalid_status", "A case cannot be ruled twice")


func _test_appeal_and_correction() -> void:
	var state: Dictionary = _state()
	state = _apply(state, Disputes.file(state, "case_1", FILER, TARGET, ["event_1"], START),
		"file case_1")
	state = _apply(state, Disputes.accept(state, "case_1", ADMIN, START + 1.0),
		"accept case_1")
	state = _apply(state, Disputes.rule(state, "case_1", ADMIN,
		_authority_decision(Disputes.OUTCOME_COMPENSATION, "wrong compensation"),
		START + 2.0), "rule case_1")
	var original_ruling: Dictionary = state.cases.case_1.ruling.duplicate(true)
	var ruled_json: String = JSON.stringify(state)

	_expect(Disputes.appeal(state, "case_1", OUTSIDER, "not my case", START + 3.0).reason
		== "not_party", "Only a party can appeal")
	_expect(Disputes.appeal(state, "case_1", FILER, "", START + 3.0).reason
		== "invalid_reason", "An appeal without a reason is refused")
	_expect(Disputes.appeal(state, "case_1", FILER, "unfair", START + 1.0).reason
		== "time_regression", "An appeal before the ruling is refused")
	_expect(JSON.stringify(state) == ruled_json,
		"Refused appeals leave the ruled input unchanged")
	var appealed: Dictionary = Disputes.appeal(state, "case_1", FILER, "unfair", START + 3.0)
	_expect(appealed.ok and appealed.status == Disputes.STATUS_APPEALED,
		"A party can appeal a ruling")
	_expect(JSON.stringify(state) == ruled_json,
		"An appeal leaves its input ruled and unchanged")
	var appealed_state: Dictionary = appealed.state
	_expect(appealed_state.cases.case_1.appeals.size() == 1
		and appealed_state.cases.case_1.appeals[0].by == FILER,
		"The appeal history records the appellant")
	_expect(Disputes.valid(appealed_state), "An appealed candidate is valid")
	_expect(Disputes.appeal(appealed_state, "case_1", TARGET, "also unfair", START + 4.0)
		.reason == "already_appealed", "A case accepts only one appeal")

	var appealed_json: String = JSON.stringify(appealed_state)
	_expect(Disputes.correct(appealed_state, "case_1", OUTSIDER, "outsider fix",
		START + 4.0).reason == "not_authority", "An outsider cannot correct a ruling")
	_expect(Disputes.correct(appealed_state, "case_1", ADMIN, "   ", START + 4.0).reason
		== "invalid_reason", "A correction without a reason is refused")
	_expect(Disputes.correct(appealed_state, "case_1", ADMIN, "too early",
		START + 2.5).reason == "time_regression",
		"A correction before the appeal is refused")
	_expect(JSON.stringify(appealed_state) == appealed_json,
		"Refused corrections leave the appealed input unchanged")

	var corrected: Dictionary = Disputes.correct(appealed_state, "case_1", ADMIN,
		"recheck evidence", START + 4.0)
	_expect(corrected.ok and corrected.status == Disputes.STATUS_CORRECTED,
		"A listed admin can correct a ruling")
	_expect(JSON.stringify(appealed_state) == appealed_json,
		"A correction leaves its input appealed and unchanged")
	var corrected_state: Dictionary = corrected.state
	_expect(corrected_state.cases.case_1.ruling == original_ruling,
		"Correction preserves the original ruling")
	_expect(corrected_state.cases.case_1.appeals.size() == 1,
		"Correction preserves the appeal history")
	_expect(corrected_state.cases.case_1.corrections.size() == 1
		and corrected_state.cases.case_1.corrections[0].by == ADMIN,
		"Correction appends a durable correction row")
	_expect(corrected_state.cases.case_1.audit.size() == 3
		and corrected_state.cases.case_1.audit[2].action == Disputes.ACTION_CORRECT,
		"Correction appends an independent audit row")
	_expect(Disputes.valid(corrected_state), "A corrected candidate is valid")
	_expect(Disputes.correct(corrected_state, "case_1", ADMIN, "again", START + 5.0)
		.reason == "already_corrected", "A case cannot be corrected twice")

	var corrected_json: String = JSON.stringify(corrected_state)
	var closed: Dictionary = Disputes.close(corrected_state, "case_1", ADMIN, START + 5.0)
	_expect(closed.ok and closed.status == Disputes.STATUS_CLOSED,
		"A corrected case can be closed")
	_expect(JSON.stringify(corrected_state) == corrected_json,
		"Closing leaves its input corrected and unchanged")
	_expect(closed.state.cases.case_1.audit.size() == 4
		and closed.state.cases.case_1.audit[3].action == Disputes.ACTION_CLOSE,
		"Closing appends its own audit row")
	_expect(Disputes.valid(closed.state), "A closed candidate is valid")
	_expect(Disputes.close(closed.state, "case_1", ADMIN, START + 6.0).reason
		== "already_closed", "A case cannot be closed twice")
	_expect(Disputes.correct(closed.state, "case_1", ADMIN, "after close",
		START + 6.0).reason == "already_closed", "A closed case cannot be corrected")


func _test_correction_without_appeal() -> void:
	var state: Dictionary = _state()
	state = _apply(state, Disputes.file(state, "case_1", FILER, TARGET, ["event_1"], START),
		"file case_1")
	state = _apply(state, Disputes.accept(state, "case_1", ADMIN, START + 1.0),
		"accept case_1")
	state = _apply(state, Disputes.rule(state, "case_1", ADMIN,
		_authority_decision(Disputes.OUTCOME_WARNING, "warning"), START + 2.0),
		"rule case_1")
	var result: Dictionary = Disputes.correct(state, "case_1", ARBITER,
		"correct without appeal", START + 3.0)
	_expect(result.ok, "A ruling can be corrected without a prior appeal")
	_expect(result.state.cases.case_1.appeals.is_empty()
		and result.state.cases.case_1.corrections.size() == 1,
		"Direct correction keeps an empty appeal history")
	_expect(Disputes.valid(result.state), "A directly corrected candidate is valid")


func _test_invalid_documents() -> void:
	var state: Dictionary = _state()
	state = _apply(state, Disputes.file(state, "case_1", FILER, TARGET, ["event_1"], START),
		"file case_1")
	state = _apply(state, Disputes.submit_evidence(state, "case_1",
		_evidence("ev_1", Disputes.EVIDENCE_LEDGER, "ledger:1", FILER, START + 1.0)),
		"evidence case_1")
	state = _apply(state, Disputes.accept(state, "case_1", ADMIN, START + 2.0),
		"accept case_1")
	state = _apply(state, Disputes.rule(state, "case_1", ADMIN,
		_authority_decision(Disputes.OUTCOME_WARNING, "warning"), START + 3.0),
		"rule case_1")
	_expect(Disputes.valid(state), "The forged-document baseline is valid")

	var no_ruling: Dictionary = state.duplicate(true)
	no_ruling.cases.case_1.ruling = {}
	_expect(not Disputes.valid(no_ruling), "A ruled case without a ruling is refused")
	var not_manager: Dictionary = state.duplicate(true)
	not_manager.cases.case_1.manager_only = false
	_expect(not Disputes.valid(not_manager), "A non-manager-only case is refused")
	var bad_status: Dictionary = state.duplicate(true)
	bad_status.cases.case_1.status = "convicted"
	_expect(not Disputes.valid(bad_status), "An unknown status is refused")
	var bad_kind: Dictionary = state.duplicate(true)
	bad_kind.cases.case_1.evidence[0].kind = "rumor"
	_expect(not Disputes.valid(bad_kind), "An unknown evidence kind is refused")
	var forged_actor: Dictionary = state.duplicate(true)
	forged_actor.cases.case_1.audit[0].by = OUTSIDER
	_expect(not Disputes.valid(forged_actor),
		"An audit row by a non-authority is refused")
	var missing_accept: Dictionary = state.duplicate(true)
	missing_accept.cases.case_1.audit.pop_front()
	_expect(not Disputes.valid(missing_accept),
		"A document that hides the acceptance audit is refused")
	var forged_ruler: Dictionary = state.duplicate(true)
	forged_ruler.cases.case_1.ruling.by = OUTSIDER
	_expect(not Disputes.valid(forged_ruler), "A ruling by a non-authority is refused")
	var filed_with_appeal: Dictionary = _state()
	var filed_candidate: Dictionary = _apply(filed_with_appeal,
		Disputes.file(filed_with_appeal, "case_1", FILER, TARGET, ["event_1"], START),
		"file for forged appeal")
	filed_candidate.cases.case_1.appeals.append(
		{"by": FILER, "at_utc": START, "reason": "forged"})
	_expect(not Disputes.valid(filed_candidate),
		"A filed case with appeal history is refused")
	var extra_field: Dictionary = state.duplicate(true)
	extra_field.cases.case_1.conviction = "guilty"
	_expect(not Disputes.valid(extra_field), "An unknown case key is refused")
	var late_evidence: Dictionary = state.duplicate(true)
	late_evidence.cases.case_1.evidence.append({
		"id": "ev_2",
		"kind": Disputes.EVIDENCE_DOCUMENT,
		"source": "doc:1",
		"submitted_by": FILER,
		"at_utc": START + Disputes.EVIDENCE_WINDOW_SECONDS + 1.0,
	})
	_expect(not Disputes.valid(late_evidence),
		"Evidence outside the window makes the document invalid")


func _test_capacity() -> void:
	var state: Dictionary = _state()
	for index: int in Disputes.MAX_CASES:
		var result: Dictionary = Disputes.file(state, "case_%03d" % index, FILER, TARGET,
			["event_%03d" % index], START)
		if not result.ok:
			break
		state = result.state
	_expect(state.cases.size() == Disputes.MAX_CASES, "The case bound is reachable")
	_expect(Disputes.valid(state), "A full case document is valid")
	var overflow: Dictionary = Disputes.file(state, "case_overflow", FILER, TARGET,
		["event_overflow"], START)
	_expect(overflow.reason == "capacity", "Filing past the case bound is refused by name")
	_expect(not overflow.has("state"), "A capacity refusal returns no candidate")

	var many_events: Array = []
	for index: int in Disputes.MAX_EVENTS + 1:
		many_events.append("event_bound_%03d" % index)
	_expect(Disputes.file(_state(), "case_1", FILER, TARGET, many_events, START).reason
		== "invalid_events", "An event list past its bound is refused")

	var evidence_base: Dictionary = _state()
	var evidence_state: Dictionary = _apply(evidence_base,
		Disputes.file(evidence_base, "case_1", FILER, TARGET, ["event_1"], START),
		"file evidence case_1")
	for index: int in Disputes.MAX_EVIDENCE:
		var result: Dictionary = Disputes.submit_evidence(evidence_state, "case_1",
			_evidence("ev_%03d" % index, Disputes.EVIDENCE_LEDGER, "ledger:%d" % index,
			FILER, START + float(index + 1)))
		if not result.ok:
			break
		evidence_state = result.state
	_expect(evidence_state.cases.case_1.evidence.size() == Disputes.MAX_EVIDENCE,
		"The evidence bound is reachable")
	_expect(Disputes.valid(evidence_state), "A full evidence list is valid")
	var evidence_overflow: Dictionary = Disputes.submit_evidence(evidence_state, "case_1",
		_evidence("ev_overflow", Disputes.EVIDENCE_LEDGER, "ledger:overflow", FILER,
		START + float(Disputes.MAX_EVIDENCE + 1)))
	_expect(evidence_overflow.reason == "capacity",
		"Submitting evidence past the bound is refused by name")
	_expect(not evidence_overflow.has("state"),
		"An evidence capacity refusal returns no candidate")


func _state() -> Dictionary:
	return Disputes.empty([ADMIN, ADMIN_2], [ARBITER])


func _evidence(id: String, kind: String, source: String, submitted_by: String,
		at_utc: float) -> Dictionary:
	return {
		"id": id,
		"kind": kind,
		"source": source,
		"submitted_by": submitted_by,
		"at_utc": at_utc,
	}


func _authority_decision(outcome: String, reason: String) -> Dictionary:
	return {
		"advisor": false,
		"authority": true,
		"outcome": outcome,
		"reason": reason,
	}


## 把成功入口返回的候选串起来；若入口拒绝或没有候选，保留输入并记录失败。
func _apply(state: Dictionary, result: Dictionary, label: String) -> Dictionary:
	checks += 1
	if not result.ok:
		failures.append("check %d: %s should succeed (%s)"
			% [checks, label, str(result.get("reason", ""))])
		return state
	var candidate: Variant = result.get("state")
	if not candidate is Dictionary:
		failures.append("check %d: %s returned no candidate state" % [checks, label])
		return state
	return candidate


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("check %d: %s" % [checks, message])
