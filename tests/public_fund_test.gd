extends SceneTree
## M8-04a/M8-04 公共项目与公共基金纯规则测试：不读 FarmState、存档、场景、
## 系统时钟或真实经济账户。最后一行是验证证据。

const Works = preload("res://world/public_works.gd")
const Fund = preload("res://world/public_fund.gd")

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
	_test_works_basics()
	_test_works_funding()
	_test_works_rejections()
	_test_works_validity()
	_test_fund_basics()
	_test_fund_contribute()
	_test_fund_spend()
	_test_fund_rotation()
	_test_fund_history_limit()
	_test_fund_validity()
	_test_determinism()
	for failure: String in failures:
		push_error(failure)
	print("PUBLIC_FUND_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_works_basics() -> void:
	var empty: Dictionary = Works.empty()
	_expect(Works.valid(empty), "The empty public works document is valid")
	_expect(Works.valid(JSON.parse_string(JSON.stringify(empty))),
		"The empty public works document survives a JSON round trip")
	var original: Dictionary = empty.duplicate(true)
	var opened: Dictionary = Works.open_project(empty, "square_01",
		Works.KIND_VILLAGE_SQUARE, "parcel_09")
	_expect(opened.ok and str(opened.reason).is_empty(),
		"A legal public project is registered")
	_expect(empty == original, "open_project returns a candidate and leaves its input unchanged")
	var state: Dictionary = opened.state
	_expect(Works.valid(state), "A document with an open project is valid")
	var row: Dictionary = state["projects"]["square_01"]
	_expect(row["kind"] == Works.KIND_VILLAGE_SQUARE and row["parcel_id"] == "parcel_09",
		"The project records its kind and parcel")
	_expect(int(row["pledged"]) == 0 and int(row["funded"]) == 0
		and row["status"] == Works.STATUS_UNBUILT and float(row["built_utc"]) == 0.0,
		"A new project starts unpledged, unfunded and unbuilt")
	_expect(Works.cost_of(Works.KIND_VILLAGE_SQUARE) == 300
		and Works.cost_of(Works.KIND_PUBLIC_WELL) == 180
		and Works.cost_of(Works.KIND_ROAD_SEGMENT) == 120,
		"The fixed catalog exposes the three costs")
	_expect(Works.cost_of("tower") == 0, "An unknown kind has no catalog cost")
	_expect(not Works.open_project(state, "square_01", Works.KIND_VILLAGE_SQUARE,
		"parcel_09").ok, "A duplicate project id is refused")
	_expect(Works.open_project(state, "square_01", Works.KIND_VILLAGE_SQUARE,
		"parcel_09").reason == "already_exists", "A duplicate project names its refusal")
	_expect(Works.open_project(state, "road_01", Works.KIND_ROAD_SEGMENT, "").ok,
		"A project may be registered without a parcel")
	_expect(Works.open_project({"projects": []}, "square_02",
		Works.KIND_VILLAGE_SQUARE, "").reason == "invalid_state",
		"A malformed document cannot register a project")
	_expect(not Works.open_project(state, "square_01", Works.KIND_VILLAGE_SQUARE,
		"parcel_09").has("state"), "A refused registration returns no candidate state")


func _test_works_funding() -> void:
	var opened: Dictionary = Works.open_project(Works.empty(), "square_01",
		Works.KIND_VILLAGE_SQUARE, "parcel_09")
	var state: Dictionary = opened.state
	var original: Dictionary = state.duplicate(true)
	var first: Dictionary = Works.pledge(state, "square_01", 100)
	_expect(first.ok and first.state["projects"]["square_01"]["pledged"] == 100,
		"A pledge below cost is recorded")
	_expect(state == original, "pledge returns a candidate and leaves its input unchanged")
	state = first.state
	var row: Dictionary = state["projects"]["square_01"]
	_expect(int(row["pledged"]) == 100 and int(row["funded"]) == 100
		and row["status"] == Works.STATUS_UNBUILT,
		"A project below the catalog cost stays unbuilt and partially funded")

	var second: Dictionary = Works.pledge(state, "square_01", 200)
	_expect(second.ok, "A second pledge can reach the catalog cost")
	state = second.state
	row = state["projects"]["square_01"]
	_expect(int(row["pledged"]) == 300 and int(row["funded"]) == 300
		and row["status"] == Works.STATUS_FUNDED,
		"Reaching the catalog cost marks the project funded")
	_expect(Works.valid(state), "A funded project document is valid")

	var extra: Dictionary = Works.pledge(state, "square_01", 50)
	_expect(extra.ok and int(extra.state["projects"]["square_01"]["pledged"]) == 350
		and int(extra.state["projects"]["square_01"]["funded"]) == 300,
		"Over-pledging is recorded but funded stays capped at the cost")
	state = extra.state

	var released: Dictionary = Works.release_pledge(state, "square_01", 51)
	_expect(released.ok and int(released.state["projects"]["square_01"]["pledged"]) == 299
		and int(released.state["projects"]["square_01"]["funded"]) == 299
		and released.state["projects"]["square_01"]["status"] == Works.STATUS_UNBUILT,
		"Releasing below cost returns the project to unbuilt")
	state = released.state
	_expect(Works.release_pledge(state, "square_01", 300).reason == "insufficient_pledged",
		"A release larger than the pledge is refused")

	var underfunded: Dictionary = Works.mark_built(state, "square_01", START)
	_expect(underfunded.reason == "underfunded",
		"An underfunded project cannot be marked built")
	_expect(not underfunded.has("state"), "An underfunded refusal returns no state")

	state = Works.pledge(state, "square_01", 1).state
	_expect(state["projects"]["square_01"]["status"] == Works.STATUS_FUNDED,
		"One more coin reaches the cost and funds the project")
	var built: Dictionary = Works.mark_built(state, "square_01", START + 60.0)
	_expect(built.ok and built.state["projects"]["square_01"]["status"] == Works.STATUS_BUILT
		and float(built.state["projects"]["square_01"]["built_utc"]) == START + 60.0,
		"A fully funded project can be marked built with its time")
	_expect(state["projects"]["square_01"]["status"] == Works.STATUS_FUNDED,
		"mark_built leaves its input unchanged")
	state = built.state
	_expect(Works.valid(state), "A built project document is valid")
	_expect(Works.mark_built(state, "square_01", START + 70.0).reason == "already_built",
		"Marking a built project again is refused")
	_expect(Works.pledge(state, "square_01", 10).reason == "already_built",
		"A built project cannot be pledged again")
	_expect(Works.release_pledge(state, "square_01", 10).reason == "already_built",
		"A built project cannot release its budget")


func _test_works_rejections() -> void:
	var opened: Dictionary = Works.open_project(Works.empty(), "square_01",
		Works.KIND_VILLAGE_SQUARE, "parcel_09")
	var state: Dictionary = opened.state
	for bad_id: Variant in ["", "bad id", "bad/id", 42, null]:
		_expect(Works.open_project(state, bad_id, Works.KIND_VILLAGE_SQUARE,
			"parcel_09").reason == "invalid_project", "An illegal project id is refused")
	for bad_kind: Variant in ["", "tower", 42, null]:
		_expect(Works.open_project(state, "other_01", bad_kind, "").reason
			== "invalid_kind", "An unknown project kind is refused")
	for bad_parcel: Variant in ["bad parcel", "bad/parcel", 42, null]:
		_expect(Works.open_project(state, "other_01", Works.KIND_PUBLIC_WELL,
			bad_parcel).reason == "invalid_parcel", "An illegal parcel id is refused")
	for bad_amount: Variant in [0, -1, 1.5, 0.0, -0.5, INF, NAN, "10", null]:
		_expect(Works.pledge(state, "square_01", bad_amount).reason == "invalid_amount",
			"A non-positive or non-integer pledge is refused")
		_expect(Works.release_pledge(state, "square_01", bad_amount).reason
			== "invalid_amount", "A non-positive or non-integer release is refused")
	_expect(Works.pledge(state, "square_01", Works.MAX_PLEDGE + 1).reason
		== "amount_limit", "A pledge above the single-pledge bound is refused")
	_expect(Works.pledge(state, "missing", 10).reason == "unknown_project",
		"Pledging an unknown project is refused")
	_expect(Works.release_pledge(state, "missing", 10).reason == "unknown_project",
		"Releasing an unknown project is refused")
	_expect(Works.mark_built(state, "missing", START).reason == "unknown_project",
		"Building an unknown project is refused")
	_expect(Works.mark_built(state, "square_01", -1.0).reason == "invalid_time",
		"Building with a negative time is refused")
	_expect(Works.mark_built(state, "square_01", NAN).reason == "invalid_time",
		"Building with a non-finite time is refused")

	var full: Dictionary = Works.empty()
	var accepted: bool = true
	for index: int in Works.MAX_PROJECTS:
		var result: Dictionary = Works.open_project(full, "p_%02d" % index,
			Works.KIND_NAMES[index % Works.KIND_NAMES.size()], "parcel_%02d" % index)
		accepted = accepted and result.ok
		if result.ok:
			full = result.state
	var full_projects: Dictionary = full["projects"]
	_expect(accepted and Works.valid(full) and full_projects.size() == Works.MAX_PROJECTS,
		"The document accepts exactly the project bound")
	_expect(Works.open_project(full, "overflow", Works.KIND_PUBLIC_WELL, "").reason
		== "too_many", "One project beyond the bound is refused")


func _test_works_validity() -> void:
	var state: Dictionary = _works_state()
	_expect(Works.valid(JSON.parse_string(JSON.stringify(state))),
		"The public works document remains valid after a JSON round trip")
	_expect(not Works.valid(null) and not Works.valid([]) and not Works.valid({}),
		"A non-dictionary or structurally empty works document is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void: doc["extra"] = true),
		"An unknown top-level key is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void: doc.erase("projects")),
		"A missing projects key is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["square_01"]["extra"] = true),
		"An unknown project key is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["square_01"].erase("pledged")),
		"A missing project key is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["square_01"]["status"] = "done"),
		"An unknown project status is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["square_01"]["funded"] = 299),
		"A funded value that disagrees with the cost is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["square_01"]["status"] = Works.STATUS_UNBUILT),
		"A fully funded project marked unbuilt is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["square_01"]["pledged"] = -1),
		"A negative pledge is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["square_01"]["pledged"] = 1.5),
		"A fractional pledge is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["square_01"]["built_utc"] = 1.0),
		"A non-built project with a build time is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["well_01"]["built_utc"] = -1.0),
		"A negative build time is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["well_01"]["built_utc"] = INF),
		"A non-finite build time is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["road_01"]["status"] = Works.STATUS_BUILT),
		"An underfunded project marked built is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["square_01"]["kind"] = "tower"),
		"An unknown project kind in the document is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["square_01"]["parcel_id"] = "bad parcel"),
		"An illegal parcel id in the document is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["square_01"] = []),
		"A non-dictionary project row is rejected")
	_expect(_rejects_works(state, func(doc: Dictionary) -> void:
		doc["projects"]["a".repeat(65)] = _works_row(Works.KIND_ROAD_SEGMENT, "", 0, 0,
			Works.STATUS_UNBUILT, 0.0)),
		"An over-long project id key is rejected")
	var many: Dictionary = state.duplicate(true)
	for index: int in Works.MAX_PROJECTS:
		many["projects"]["extra_%02d" % index] = _works_row(Works.KIND_ROAD_SEGMENT,
			"", 0, 0, Works.STATUS_UNBUILT, 0.0)
	_expect(not Works.valid(many), "More projects than the bound are rejected")


func _test_fund_basics() -> void:
	var empty: Dictionary = Fund.empty()
	_expect(Fund.valid(empty), "The empty public fund document is valid")
	_expect(Fund.valid(JSON.parse_string(JSON.stringify(empty))),
		"The empty public fund document survives a JSON round trip")
	_expect(Fund.fund_for("coop") == "fund_coop" and Fund.account_for("coop") == "org_coop",
		"The fund id and account reference are derived from the organization id")
	var original: Dictionary = empty.duplicate(true)
	var opened: Dictionary = Fund.open_fund(empty, "coop", PLAYER_A)
	_expect(opened.ok and str(opened.reason).is_empty(), "A legal organization fund opens")
	_expect(empty == original, "open_fund returns a candidate and leaves its input unchanged")
	var state: Dictionary = opened.state
	_expect(Fund.valid(state), "A document with one open fund is valid")
	_expect(state["funds"].has("fund_coop"), "The fund is keyed by the derived fund id")
	var row: Dictionary = state["funds"]["fund_coop"]
	_expect(row["org_id"] == "coop" and row["keeper"] == PLAYER_A,
		"The fund records its organization and first keeper")
	_expect(int(row["balance"]) == 0 and int(row["spent"]) == 0
		and (row["history"] as Array).is_empty(),
		"A new fund starts with zero balance, spend and history")
	_expect(row["contributors"].has(PLAYER_A) and int(row["contributors"][PLAYER_A]) == 0,
		"The first keeper is a contributor with zero contributed")
	_expect(Fund.open_fund(state, "coop", PLAYER_B).reason == "already_exists",
		"An organization cannot open a second fund")
	for bad_org: Variant in ["", "@world", "bad org", 42, null]:
		_expect(Fund.open_fund(empty, bad_org, PLAYER_A).reason == "invalid_org",
			"An illegal organization id is refused")
	for bad_keeper: Variant in ["", "@world", "bad keeper", 42, null]:
		_expect(Fund.open_fund(empty, "coop", bad_keeper).reason == "invalid_player",
			"An illegal first keeper is refused")

	var full: Dictionary = Fund.empty()
	var accepted: bool = true
	for index: int in Fund.MAX_FUNDS:
		var result: Dictionary = Fund.open_fund(full, "org_%02d" % index, PLAYER_A)
		accepted = accepted and result.ok
		if result.ok:
			full = result.state
	var full_funds: Dictionary = full["funds"]
	_expect(accepted and Fund.valid(full) and full_funds.size() == Fund.MAX_FUNDS,
		"The document accepts exactly the fund bound")
	_expect(Fund.open_fund(full, "org_overflow", PLAYER_A).reason == "too_many",
		"One fund beyond the bound is refused")


func _test_fund_contribute() -> void:
	var state: Dictionary = _fund_state()
	var original: Dictionary = state.duplicate(true)
	var contributed: Dictionary = Fund.contribute(state, "fund_coop", PLAYER_C, 50)
	_expect(contributed.ok, "A legal player contributes to the fund")
	_expect(state == original, "contribute returns a candidate and leaves its input unchanged")
	state = contributed.state
	var row: Dictionary = state["funds"]["fund_coop"]
	_expect(int(row["balance"]) == 350 and int(row["contributors"][PLAYER_C]) == 50,
		"A contribution increases the balance and the contributor total")
	_expect((row["history"] as Array).is_empty(),
		"Contributions do not write spend history")
	_expect(Fund.valid(state), "The fund document is valid after a contribution")

	for bad_player: Variant in ["", "@world", "bad player", 42, null]:
		_expect(Fund.contribute(state, "fund_coop", bad_player, 10).reason
			== "invalid_player", "An illegal contributor is refused")
	for bad_amount: Variant in [0, -1, 1.5, 0.0, -0.5, INF, NAN, "10", null]:
		_expect(Fund.contribute(state, "fund_coop", PLAYER_C, bad_amount).reason
			== "invalid_amount", "A non-positive or non-integer contribution is refused")
	_expect(Fund.contribute(state, "fund_coop", PLAYER_C,
		Fund.MAX_CONTRIBUTION + 1).reason == "amount_limit",
		"A contribution above the single-contribution bound is refused")
	_expect(Fund.contribute(state, "missing", PLAYER_C, 10).reason == "unknown_fund",
		"Contributing to an unknown fund is refused")
	_expect(Fund.contribute({"funds": []}, "fund_coop", PLAYER_C, 10).reason
		== "invalid_state", "A malformed document cannot accept a contribution")

	var total_state: Dictionary = state
	var at_total: Dictionary = {}
	for index: int in 10:
		at_total = Fund.contribute(total_state, "fund_coop", PLAYER_B, 9_990)
		total_state = at_total.state
	_expect(at_total.ok and int(at_total.state["funds"]["fund_coop"]["contributors"][PLAYER_B])
		== Fund.MAX_TOTAL_CONTRIBUTION, "A contributor may reach the total bound")
	_expect(Fund.contribute(at_total.state, "fund_coop", PLAYER_B, 1).reason
		== "contribution_limit", "One coin above the contributor bound is refused")

	var crowded: Dictionary = Fund.open_fund(Fund.empty(), "coop", PLAYER_A).state
	var joined: bool = true
	for index: int in Fund.MAX_CONTRIBUTORS - 1:
		var result: Dictionary = Fund.contribute(crowded, "fund_coop", "m_%03d" % index, 1)
		joined = joined and result.ok
		if result.ok:
			crowded = result.state
	var crowded_row: Dictionary = crowded["funds"]["fund_coop"]
	_expect(joined and (crowded_row["contributors"] as Dictionary).size()
		== Fund.MAX_CONTRIBUTORS, "The fund accepts exactly the contributor bound")
	_expect(Fund.contribute(crowded, "fund_coop", "overflow_member", 1).reason
		== "fund_full", "One contributor beyond the bound is refused")

	var rich: Dictionary = Fund.open_fund(Fund.empty(), "coop", PLAYER_A).state
	var funded: bool = true
	for player_index: int in 10:
		for contribution: int in 10:
			var result: Dictionary = Fund.contribute(rich, "fund_coop",
				"rich_%02d" % player_index, 10_000)
			funded = funded and result.ok
			if result.ok:
				rich = result.state
	var rich_row: Dictionary = rich["funds"]["fund_coop"]
	_expect(funded and int(rich_row["balance"]) == Fund.MAX_BALANCE,
		"The fund balance may reach its bound")
	_expect(Fund.contribute(rich, "fund_coop", PLAYER_C, 1).reason == "balance_limit",
		"One coin above the balance bound is refused")


func _test_fund_spend() -> void:
	var state: Dictionary = _fund_state()
	var original: Dictionary = state.duplicate(true)
	var spent: Dictionary = Fund.authorize_spend(state, "fund_coop", PLAYER_A,
		"square_01", 120, START)
	_expect(spent.ok, "The current keeper may spend from the fund")
	_expect(state == original, "authorize_spend returns a candidate and leaves its input unchanged")
	var next: Dictionary = spent.state
	var row: Dictionary = next["funds"]["fund_coop"]
	_expect(int(row["balance"]) == 180 and int(row["spent"]) == 120,
		"A spend reduces the balance and increases cumulative spend")
	var history: Array = row["history"]
	_expect(history.size() == 1, "A spend writes one history row")
	var entry: Dictionary = history[0]
	_expect(entry["kind"] == Fund.HISTORY_KIND_SPEND and int(entry["amount"]) == 120
		and entry["actor"] == PLAYER_A and entry["project"] == "square_01"
		and float(entry["at_utc"]) == START,
		"The history row records kind, amount, actor, project and time")
	_expect(Fund.valid(next), "The fund document is valid after a spend")
	_expect(Fund.authorize_spend(next, "fund_coop", PLAYER_B, "square_01", 10,
		START).reason == "not_keeper", "A contributor who is not keeper cannot spend")
	_expect(Fund.authorize_spend(next, "fund_coop", PLAYER_A, "square_01", 181,
		START).reason == "insufficient_funds", "A spend above the balance is refused")
	_expect(Fund.authorize_spend(next, "fund_coop", PLAYER_A, "square_01", 0,
		START).reason == "invalid_amount", "A zero spend is refused")
	_expect(Fund.authorize_spend(next, "fund_coop", PLAYER_A, "square_01", 1.5,
		START).reason == "invalid_amount", "A fractional spend is refused")
	for bad_project: Variant in ["", "bad project", "bad/project", 42, null]:
		_expect(Fund.authorize_spend(next, "fund_coop", PLAYER_A, bad_project, 10,
			START).reason == "invalid_project", "An illegal project id is refused")
	_expect(Fund.authorize_spend(next, "fund_coop", PLAYER_A, "square_01", 10,
		-1.0).reason == "invalid_time", "A negative spend time is refused")
	_expect(Fund.authorize_spend(next, "missing", PLAYER_A, "square_01", 10,
		START).reason == "unknown_fund", "Spending from an unknown fund is refused")
	for bad_actor: Variant in ["", "@world", "bad actor", 42, null]:
		_expect(Fund.authorize_spend(next, "fund_coop", bad_actor, "square_01", 10,
			START).reason == "invalid_player", "An illegal spender is refused")
	_expect(not Fund.authorize_spend(next, "fund_coop", PLAYER_B, "square_01", 10,
		START).has("state"), "A refused spend returns no candidate state")


func _test_fund_rotation() -> void:
	var state: Dictionary = _fund_state()
	var original: Dictionary = state.duplicate(true)
	var rotated: Dictionary = Fund.rotate_keeper(state, "fund_coop", PLAYER_A, PLAYER_B)
	_expect(rotated.ok, "The current keeper may rotate the keeper role")
	_expect(state == original, "rotate_keeper returns a candidate and leaves its input unchanged")
	var moved: Dictionary = rotated.state
	var row: Dictionary = moved["funds"]["fund_coop"]
	_expect(row["keeper"] == PLAYER_B, "The new keeper is recorded")
	_expect(row["org_id"] == "coop" and moved["funds"].has("fund_coop")
		and Fund.fund_for("coop") == "fund_coop",
		"Rotation changes neither the organization nor the fund id")
	_expect(int(row["balance"]) == 300 and int(row["spent"]) == 0
		and int(row["contributors"][PLAYER_A]) == 200
		and int(row["contributors"][PLAYER_B]) == 100,
		"Rotation preserves the balance, spend and contributor totals")
	_expect(Fund.valid(moved), "The fund document is valid after a rotation")
	_expect(Fund.rotate_keeper(moved, "fund_coop", PLAYER_A, PLAYER_B).reason
		== "not_keeper", "The former keeper can no longer rotate")
	_expect(Fund.authorize_spend(moved, "fund_coop", PLAYER_A, "square_01", 10,
		START).reason == "not_keeper", "The former keeper loses the spend permission")
	_expect(Fund.authorize_spend(moved, "fund_coop", PLAYER_B, "square_01", 10,
		START).ok, "The new keeper gains the spend permission")
	_expect(Fund.rotate_keeper(moved, "fund_coop", PLAYER_B, PLAYER_C).reason
		== "not_member", "A non-contributor cannot become keeper")
	_expect(Fund.rotate_keeper(moved, "fund_coop", PLAYER_B, PLAYER_B).reason
		== "same_keeper", "Rotating to the current keeper is refused")
	_expect(Fund.rotate_keeper(moved, "fund_coop", PLAYER_B, PLAYER_A).ok,
		"An existing contributor may become keeper")
	for bad_keeper: Variant in ["", "@world", "bad keeper", 42, null]:
		_expect(Fund.rotate_keeper(moved, "fund_coop", PLAYER_B, bad_keeper).reason
			== "invalid_player", "An illegal new keeper is refused")
	_expect(Fund.rotate_keeper(moved, "missing", PLAYER_B, PLAYER_A).reason
		== "unknown_fund", "Rotating an unknown fund is refused")


func _test_fund_history_limit() -> void:
	var opened: Dictionary = Fund.open_fund(Fund.empty(), "coop", PLAYER_A)
	var state: Dictionary = Fund.contribute(opened.state, "fund_coop", PLAYER_A, 260).state
	var all_spent: bool = true
	for index: int in Fund.MAX_HISTORY:
		var result: Dictionary = Fund.authorize_spend(state, "fund_coop", PLAYER_A,
			"road_segment", 1, START + float(index))
		all_spent = all_spent and result.ok
		if result.ok:
			state = result.state
	var row: Dictionary = state["funds"]["fund_coop"]
	var history: Array = row["history"]
	var history_total: int = 0
	for entry: Dictionary in history:
		history_total += int(entry["amount"])
	_expect(all_spent and history.size() == Fund.MAX_HISTORY,
		"The fund accepts exactly the history bound")
	_expect(int(row["spent"]) == history_total and int(row["balance"]) + int(row["spent"]) == 260,
		"History total, cumulative spend and balance stay consistent")
	_expect(Fund.valid(state), "The fund document is valid at the history bound")
	_expect(Fund.authorize_spend(state, "fund_coop", PLAYER_A, "road_segment", 1,
		START + 300.0).reason == "history_full",
		"A spend beyond the history bound is refused")
	_expect(Fund.authorize_spend(state, "fund_coop", PLAYER_A, "road_segment", 1,
		START + 300.0).reason == "history_full", "The history refusal is deterministic")


func _test_fund_validity() -> void:
	var state: Dictionary = _fund_state()
	var spent: Dictionary = Fund.authorize_spend(state, "fund_coop", PLAYER_A,
		"square_01", 40, START)
	state = spent.state
	_expect(Fund.valid(JSON.parse_string(JSON.stringify(state))),
		"The public fund document remains valid after a JSON round trip")
	_expect(not Fund.valid(null) and not Fund.valid([]) and not Fund.valid({}),
		"A non-dictionary or structurally empty fund document is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void: doc["extra"] = true),
		"An unknown top-level key is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void: doc.erase("funds")),
		"A missing funds key is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void: doc["funds"] = []),
		"A non-dictionary funds table is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"] = []),
		"A non-dictionary fund row is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["extra"] = true),
		"An unknown fund key is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"].erase("history")),
		"A missing fund key is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		var row: Dictionary = doc["funds"]["fund_coop"]
		doc["funds"].erase("fund_coop")
		doc["funds"]["fund_other"] = row),
		"A renamed fund id that no longer matches org_id is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		var row: Dictionary = doc["funds"]["fund_coop"]
		doc["funds"].erase("fund_coop")
		doc["funds"]["fund_coop_extra"] = row),
		"A fund row moved under another derived key is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["org_id"] = "other"),
		"Changing org_id without changing the fund id is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["org_id"] = "bad org"),
		"An illegal org_id is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["keeper"] = "bad keeper"),
		"An illegal keeper id is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["keeper"] = PLAYER_D),
		"A keeper who is not a contributor is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["contributors"] = {}),
		"An empty contributor table is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["contributors"]["bad player"] = 1),
		"An illegal contributor id is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["contributors"][PLAYER_B] = -1),
		"A negative contributor total is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["contributors"][PLAYER_B] = 1.5),
		"A fractional contributor total is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["contributors"][PLAYER_B] = Fund.MAX_TOTAL_CONTRIBUTION + 1),
		"A contributor total above the bound is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["balance"] = 0),
		"A balance that breaks conservation is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["balance"] = -1),
		"A negative balance is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["spent"] = 0),
		"A spent total that disagrees with history is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["history"][0]["extra"] = true),
		"An unknown history key is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["history"][0]["kind"] = "refund"),
		"An unknown history kind is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["history"][0]["amount"] = 0),
		"A zero history amount is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["history"][0]["amount"] = 1.5),
		"A fractional history amount is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["history"][0]["actor"] = "bad actor"),
		"An illegal history actor is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["history"][0]["project"] = "bad project"),
		"An illegal history project is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["history"][0]["at_utc"] = -1.0),
		"A negative history time is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["fund_coop"]["history"] = [1]),
		"A non-dictionary history row is rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		var row: Dictionary = doc["funds"]["fund_coop"]
		var history: Array = []
		for index: int in Fund.MAX_HISTORY + 1:
			history.append({"kind": Fund.HISTORY_KIND_SPEND, "amount": 1,
				"actor": PLAYER_A, "project": "square_01", "at_utc": START})
		row["history"] = history
		row["spent"] = Fund.MAX_HISTORY + 1
		row["balance"] = 300 - Fund.MAX_HISTORY - 1),
		"More history rows than the bound are rejected")
	var many: Dictionary = Fund.empty()
	for index: int in Fund.MAX_FUNDS:
		many = Fund.open_fund(many, "org_%02d" % index, PLAYER_A).state
	many["funds"]["fund_overflow"] = _fund_row("overflow", PLAYER_A, 0, 0, [])
	_expect(not Fund.valid(many), "More funds than the bound are rejected")
	_expect(_rejects_fund(state, func(doc: Dictionary) -> void:
		doc["funds"]["bad id"] = _fund_row("bad id", PLAYER_A, 0, 0, [])),
		"An illegal fund id key is rejected")


func _test_determinism() -> void:
	var first: Dictionary = _fund_sequence()
	var second: Dictionary = _fund_sequence()
	_expect(not first.is_empty() and first == second,
		"The same fund command sequence produces the same document")
	var works_first: Dictionary = _works_sequence()
	var works_second: Dictionary = _works_sequence()
	_expect(not works_first.is_empty() and works_first == works_second,
		"The same works command sequence produces the same document")
	var seed: Dictionary = _fund_state()
	var untouched: Dictionary = seed.duplicate(true)
	Fund.contribute(seed, "fund_coop", PLAYER_C, 10)
	Fund.authorize_spend(seed, "fund_coop", PLAYER_A, "square_01", 10, START)
	Fund.rotate_keeper(seed, "fund_coop", PLAYER_A, PLAYER_B)
	_expect(seed == untouched, "Library commands never mutate the caller's fund document")
	var works_seed: Dictionary = _works_state()
	var works_untouched: Dictionary = works_seed.duplicate(true)
	Works.pledge(works_seed, "square_01", 10)
	Works.release_pledge(works_seed, "square_01", 10)
	Works.mark_built(works_seed, "well_01", START + 200.0)
	_expect(works_seed == works_untouched,
		"Library commands never mutate the caller's works document")


func _fund_sequence() -> Dictionary:
	var opened: Dictionary = Fund.open_fund(Fund.empty(), "coop", PLAYER_A)
	var state: Dictionary = opened.state
	var contributed: Dictionary = Fund.contribute(state, "fund_coop", PLAYER_B, 100)
	if not contributed.ok:
		return {}
	state = contributed.state
	var rotated: Dictionary = Fund.rotate_keeper(state, "fund_coop", PLAYER_A, PLAYER_B)
	if not rotated.ok:
		return {}
	state = rotated.state
	var spent: Dictionary = Fund.authorize_spend(state, "fund_coop", PLAYER_B,
		"square_01", 60, START)
	if not spent.ok:
		return {}
	return spent.state


func _works_sequence() -> Dictionary:
	var opened: Dictionary = Works.open_project(Works.empty(), "square_01",
		Works.KIND_VILLAGE_SQUARE, "parcel_09")
	if not opened.ok:
		return {}
	var state: Dictionary = opened.state
	var pledged: Dictionary = Works.pledge(state, "square_01", 300)
	if not pledged.ok:
		return {}
	state = pledged.state
	var built: Dictionary = Works.mark_built(state, "square_01", START)
	if not built.ok:
		return {}
	return built.state


func _works_state() -> Dictionary:
	var opened: Dictionary = Works.open_project(Works.empty(), "square_01",
		Works.KIND_VILLAGE_SQUARE, "parcel_09")
	var state: Dictionary = opened.state
	state = Works.pledge(state, "square_01", 300).state
	state = Works.open_project(state, "well_01", Works.KIND_PUBLIC_WELL, "parcel_10").state
	state = Works.pledge(state, "well_01", 180).state
	state = Works.mark_built(state, "well_01", START + 100.0).state
	state = Works.open_project(state, "road_01", Works.KIND_ROAD_SEGMENT, "").state
	return state


func _works_row(kind: String, parcel_id: String, pledged: int, funded: int,
		status: String, built_utc: float) -> Dictionary:
	return {
		"kind": kind,
		"parcel_id": parcel_id,
		"funded": funded,
		"status": status,
		"pledged": pledged,
		"built_utc": built_utc,
	}


func _fund_state() -> Dictionary:
	var opened: Dictionary = Fund.open_fund(Fund.empty(), "coop", PLAYER_A)
	var state: Dictionary = opened.state
	state = Fund.contribute(state, "fund_coop", PLAYER_A, 200).state
	state = Fund.contribute(state, "fund_coop", PLAYER_B, 100).state
	return state


func _fund_row(org_id: String, keeper: String, balance: int, spent: int,
		history: Array) -> Dictionary:
	var contributors: Dictionary = {keeper: balance + spent}
	return {
		"org_id": org_id,
		"keeper": keeper,
		"contributors": contributors,
		"balance": balance,
		"spent": spent,
		"history": history,
	}


func _rejects_works(state: Dictionary, mutate: Callable) -> bool:
	var copy: Dictionary = state.duplicate(true)
	mutate.call(copy)
	return not Works.valid(copy)


func _rejects_fund(state: Dictionary, mutate: Callable) -> bool:
	var copy: Dictionary = state.duplicate(true)
	mutate.call(copy)
	return not Fund.valid(copy)


func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
