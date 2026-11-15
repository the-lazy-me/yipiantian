extends SceneTree
## M11-01 cadastre connectivity slice.
##
## Covers the routing view derived from a cadastre (edge adjacency, no corner
## adjacency, `can_pass` semantics, optional actor and external passable ids),
## deterministic shortest paths with the destination-homestead exemption, and
## the acceptance check that blocking one parcel still leaves every built
## homestead reachable from the public entrance.
##
## The fixture grids are hand-built so each expected path and each cut vertex is
## visible in the test itself. No files are written.

const TerritoryPaths = preload("res://world/territory_paths.gd")
const TerritoryState = preload("res://world/territory_state.gd")

const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_view_adjacency()
	_test_view_passability()
	_test_paths()
	_test_blocking()
	_test_view_validation()
	_test_path_validation()
	_test_blocking_validation()
	_test_bounds()
	_test_read_only_and_determinism()
	for failure: String in failures:
		push_error(failure)
	print("TERRITORY_PATHS_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_view_adjacency() -> void:
	var state: Dictionary = _grid_state()
	var view: Dictionary = TerritoryPaths.build_view(state, {
		"entrance": "p00", "homesteads": ["p02", "p22"],
	})
	_expect(bool(view.ok), "The 3x3 grid builds a view")
	_expect(view.entrance == "p00", "The view keeps the named entrance")
	_expect(view.homesteads == ["p02", "p22"], "Homesteads stay sorted")
	_expect(_clean(view.nodes.p00.neighbors) == ["p01", "p10"],
		"p00 neighbours share an edge on two sides")
	_expect(_clean(view.nodes.p11.neighbors) == ["p01", "p10", "p12", "p21"],
		"An interior parcel has four edge neighbours")
	_expect(_clean(view.nodes.p22.neighbors) == ["p12", "p21"],
		"A corner parcel has two edge neighbours")

	var diagonal: Dictionary = TerritoryPaths.build_view(_corner_state(), {
		"entrance": "e0", "homesteads": ["e1"], "actor": PLAYER_A,
	})
	_expect(bool(diagonal.ok), "A corner-touching pair still builds a view")
	_expect(_clean(diagonal.nodes.e0.neighbors).is_empty(),
		"Rectangles touching only at a corner are not adjacent")
	var diagonal_path: Dictionary = TerritoryPaths.path(diagonal, "e0", "e1")
	_expect(bool(diagonal_path.ok) and not bool(diagonal_path.reachable)
		and diagonal_path.distance == -1,
		"A corner-only neighbour is unreachable")

	# Duplicate homestead names collapse and the list stays sorted.
	var deduped: Dictionary = TerritoryPaths.build_view(state, {
		"entrance": "p00", "homesteads": ["p22", "p02", "p22"],
	})
	_expect(bool(deduped.ok) and deduped.homesteads == ["p02", "p22"],
		"Duplicate homestead ids are deduplicated")


func _test_view_passability() -> void:
	var state: Dictionary = _grid_state()
	var anonymous: Dictionary = TerritoryPaths.build_view(state, {
		"entrance": "p00", "homesteads": ["p02", "p22"],
	})
	_expect(bool(anonymous.nodes.p00.passable), "Public ground is passable")
	_expect(bool(anonymous.nodes.p10.passable), "Unclaimed ground is passable")
	_expect(not bool(anonymous.nodes.p11.passable),
		"Another player's claimed parcel blocks the anonymous walker")
	_expect(not bool(anonymous.nodes.p02.passable),
		"A claimed homestead is not transit-passable")

	var owner_view: Dictionary = TerritoryPaths.build_view(state, {
		"entrance": "p00", "homesteads": ["p02", "p22"], "actor": PLAYER_A,
	})
	_expect(bool(owner_view.nodes.p11.passable),
		"The owner may cross their own claimed parcel")
	_expect(not bool(owner_view.nodes.p12.passable),
		"The owner may not cross another player's parcel")

	var other_view: Dictionary = TerritoryPaths.build_view(state, {
		"entrance": "p00", "homesteads": ["p02", "p22"], "actor": PLAYER_B,
	})
	_expect(not bool(other_view.nodes.p11.passable),
		"Another player cannot cross a claimed parcel they do not own")
	_expect(bool(other_view.nodes.p02.passable),
		"The claimant may cross their own homestead")

	var opened: Dictionary = TerritoryPaths.build_view(state, {
		"entrance": "p00", "homesteads": ["p02", "p22"],
		"passable": ["p11"],
	})
	_expect(bool(opened.nodes.p11.passable),
		"An external passable id opens the parcel to everyone")
	_expect(not bool(opened.nodes.p12.passable),
		"Parcels outside the external list stay private")

	var no_homesteads: Dictionary = TerritoryPaths.build_view(state, {
		"entrance": "p00",
	})
	_expect(bool(no_homesteads.ok) and no_homesteads.homesteads.is_empty(),
		"A view without homesteads is legal")


func _test_paths() -> void:
	var view: Dictionary = TerritoryPaths.build_view(_grid_state(), {
		"entrance": "p00", "homesteads": ["p02", "p22"],
	})
	var to_goal: Dictionary = TerritoryPaths.path(view, "p00", "p02")
	_expect(bool(to_goal.ok) and bool(to_goal.reachable) and to_goal.distance == 2,
		"The entrance reaches a claimed homestead in two steps")
	_expect(to_goal.path == ["p00", "p01", "p02"],
		"The reported path ends at the homestead door")
	var around: Dictionary = TerritoryPaths.path(view, "p00", "p22")
	_expect(bool(around.reachable) and around.distance == 4,
		"The route around the claimed interior is four steps")
	_expect(around.path == ["p00", "p10", "p20", "p21", "p22"],
		"The shortest route is deterministic")
	_expect(TerritoryPaths.path(view, "p00", "p22") == around,
		"Two identical queries return the same result")

	var opened: Dictionary = TerritoryPaths.build_view(_grid_state(), {
		"entrance": "p00", "homesteads": ["p02", "p22"], "passable": ["p11"],
	})
	var through: Dictionary = TerritoryPaths.path(opened, "p00", "p11")
	_expect(bool(through.reachable) and through.path == ["p00", "p01", "p11"],
		"An externally opened parcel becomes routable")

	var same: Dictionary = TerritoryPaths.path(view, "p21", "p21")
	_expect(bool(same.reachable) and same.distance == 0 and same.path == ["p21"],
		"A parcel reaches itself with a zero-length path")

	var claimed_start: Dictionary = TerritoryPaths.path(view, "p02", "p22")
	_expect(bool(claimed_start.ok) and not bool(claimed_start.reachable)
		and claimed_start.distance == -1,
		"Impassable claimed land cannot be a start")

	var blocked_route: Dictionary = TerritoryPaths.path(view, "p00", "p22", ["p10"])
	_expect(bool(blocked_route.ok) and not bool(blocked_route.reachable)
		and blocked_route.path.is_empty(),
		"A caller-supplied blocked parcel can cut the route")
	var blocked_start: Dictionary = TerritoryPaths.path(view, "p00", "p22", ["p00"])
	_expect(bool(blocked_start.ok) and not bool(blocked_start.reachable),
		"A blocked start parcel is unreachable instead of an error")
	var blocked_goal: Dictionary = TerritoryPaths.path(view, "p00", "p22", ["p22"])
	_expect(bool(blocked_goal.ok) and not bool(blocked_goal.reachable),
		"A blocked goal parcel is unreachable instead of an error")


func _test_blocking() -> void:
	# Corridor: c1 -> c2 -> c3. c2 is the only cut vertex in front of c3.
	var corridor: Dictionary = TerritoryPaths.build_view(_corridor_state(), {
		"entrance": "c1", "homesteads": ["c3"],
	})
	var cut: Dictionary = TerritoryPaths.check_blocking(corridor, "c2")
	_expect(bool(cut.ok) and cut.blocked == ["c3"],
		"Blocking the only corridor cuts the homestead off")
	_expect(cut.newly_blocked == ["c3"],
		"The corridor block is reported as newly blocking")
	_expect(bool(cut.entrance_reachable),
		"The entrance itself stays reachable")
	var claimed: Dictionary = TerritoryPaths.check_blocking(corridor, "c3")
	_expect(bool(claimed.ok) and claimed.blocked.is_empty()
		and claimed.newly_blocked.is_empty(),
		"Blocking a homestead still leaves its door reachable")
	_expect(bool(claimed.entrance_reachable), "The entrance is unchanged")
	var entrance_blocked: Dictionary = TerritoryPaths.check_blocking(corridor, "c1")
	_expect(not bool(entrance_blocked.entrance_reachable)
		and entrance_blocked.blocked == ["c3"]
		and entrance_blocked.newly_blocked == ["c3"],
		"Blocking the entrance reports every homestead as cut off")

	# Diamond: d0 has two one-step approaches, so neither d1 nor d2 is a cut.
	var diamond: Dictionary = TerritoryPaths.build_view(_diamond_state(), {
		"entrance": "d0", "homesteads": ["d3"],
	})
	for cut_candidate: String in ["d1", "d2"]:
		var alternate: Dictionary = TerritoryPaths.check_blocking(diamond, cut_candidate)
		_expect(bool(alternate.ok) and alternate.newly_blocked.is_empty(),
			"Blocking %s leaves the alternate approach open" % cut_candidate)
	_expect(bool(TerritoryPaths.check_blocking(diamond, "d3").newly_blocked.is_empty()),
		"Blocking the homestead in the diamond changes no access")

	# Grid: p01 is the only walkable door of the claimed p02.
	var grid: Dictionary = TerritoryPaths.build_view(_grid_state(), {
		"entrance": "p00", "homesteads": ["p02", "p22"],
	})
	var grid_cut: Dictionary = TerritoryPaths.check_blocking(grid, "p01")
	_expect(bool(grid_cut.ok) and grid_cut.blocked == ["p02"]
		and grid_cut.newly_blocked == ["p02"],
		"The only door parcel is reported as blocking")
	_expect(bool(grid_cut.entrance_reachable),
		"The grid entrance stays reachable")
	var already_private: Dictionary = TerritoryPaths.check_blocking(grid, "p11")
	_expect(bool(already_private.ok) and already_private.blocked.is_empty()
		and already_private.newly_blocked.is_empty(),
		"A parcel that was already private newly blocks nothing")
	var grid_no_homesteads: Dictionary = TerritoryPaths.build_view(_grid_state(), {
		"entrance": "p00",
	})
	_expect(TerritoryPaths.check_blocking(grid_no_homesteads, "p01").blocked.is_empty(),
		"A view without homesteads reports no blocked homes")


func _test_view_validation() -> void:
	_expect(TerritoryPaths.build_view({}, {"entrance": "p00"}).reason == "invalid_state",
		"No parcels dictionary is invalid_state")
	_expect(TerritoryPaths.build_view({"parcels": []}, {"entrance": "p00"}).reason
		== "invalid_state", "An array parcels value is invalid_state")
	_expect(TerritoryPaths.build_view(_grid_state(),
		{"entrance": "p00", "unknown": 1}).reason == "invalid_options",
		"An unknown option key is refused")
	_expect(TerritoryPaths.build_view(_grid_state(), {}).reason == "missing_entrance",
		"A view requires an entrance")
	_expect(TerritoryPaths.build_view(_grid_state(),
		{"entrance": "bad id"}).reason == "invalid_entrance",
		"A malformed entrance id is refused")
	_expect(TerritoryPaths.build_view(_grid_state(),
		{"entrance": "p99"}).reason == "unknown_entrance",
		"An entrance not in the cadastre is refused")
	_expect(TerritoryPaths.build_view(_grid_state(),
		{"entrance": "p00", "homesteads": "p02"}).reason == "invalid_homestead",
		"Homesteads must be a list")
	_expect(TerritoryPaths.build_view(_grid_state(),
		{"entrance": "p00", "homesteads": ["bad id"]}).reason == "invalid_homestead",
		"A malformed homestead id is refused")
	_expect(TerritoryPaths.build_view(_grid_state(),
		{"entrance": "p00", "homesteads": ["p99"]}).reason == "unknown_homestead",
		"A homestead not in the cadastre is refused")
	_expect(TerritoryPaths.build_view(_grid_state(),
		{"entrance": "p00", "passable": "p11"}).reason == "invalid_passable",
		"Passable ids must be a list")
	_expect(TerritoryPaths.build_view(_grid_state(),
		{"entrance": "p00", "passable": ["bad id"]}).reason == "invalid_passable",
		"A malformed passable id is refused")
	_expect(TerritoryPaths.build_view(_grid_state(),
		{"entrance": "p00", "passable": ["p99"]}).reason == "unknown_passable",
		"A passable id not in the cadastre is refused")

	for actor: String in ["", "public", "@world", "bad id"]:
		_expect(TerritoryPaths.build_view(_grid_state(),
			{"entrance": "p00", "actor": actor}).reason == "invalid_actor",
			"An illegal actor (%s) is refused" % actor)

	# A hand-built cadastre may use StringName keys; a parsed one uses String.
	var named: Dictionary = {"parcels": {}}
	named.parcels[StringName("n0")] = _parcel("n0", 0, 0, 0, 0, "public",
		TerritoryState.STATUS_PUBLIC)
	named.parcels[StringName("n1")] = _parcel("n1", 1, 0, 1, 0, PLAYER_B,
		TerritoryState.STATUS_CLAIMED)
	var named_view: Dictionary = TerritoryPaths.build_view(named, {
		"entrance": "n0", "homesteads": ["n1"],
	})
	_expect(bool(named_view.ok) and bool(named_view.nodes.n1.passable) == false,
		"A StringName-keyed cadastre builds a normal view")
	_expect(TerritoryPaths.check_blocking(named_view, "n1").blocked.is_empty(),
		"The StringName-keyed view answers the blocking check")

	var duplicate_keys: Dictionary = {"parcels": {}}
	duplicate_keys.parcels["p00"] = _parcel("p00", 0, 0, 0, 0, "public",
		TerritoryState.STATUS_PUBLIC)
	duplicate_keys.parcels[StringName("p00")] = _parcel("p00", 0, 0, 0, 0, "",
		TerritoryState.STATUS_UNCLAIMED)
	_expect(duplicate_keys.parcels.size() == 1,
		"String and StringName spellings of one id are one dictionary key")

	var bad_status: Dictionary = _grid_state()
	bad_status.parcels["p00"].status = "leased"
	_expect(TerritoryPaths.build_view(bad_status,
		{"entrance": "p00"}).reason == "invalid_parcel",
		"An unknown parcel status is refused")
	var bad_rect: Dictionary = _grid_state()
	bad_rect.parcels["p00"].rect = {"min_x": 1, "min_z": 0, "max_x": 0, "max_z": 0}
	_expect(TerritoryPaths.build_view(bad_rect,
		{"entrance": "p00"}).reason == "invalid_parcel",
		"An inverted rectangle is refused")
	var bad_id: Dictionary = _grid_state()
	bad_id.parcels["bad id"] = _parcel("bad id", 5, 5, 5, 5, "", TerritoryState.STATUS_UNCLAIMED)
	_expect(TerritoryPaths.build_view(bad_id,
		{"entrance": "p00"}).reason == "invalid_parcel",
		"A malformed parcel key is refused")
	var mismatched: Dictionary = _grid_state()
	mismatched.parcels["p00"].id = "p01"
	_expect(TerritoryPaths.build_view(mismatched,
		{"entrance": "p00"}).reason == "invalid_parcel",
		"A row id that disagrees with its key is refused")
	var rowless: Dictionary = _grid_state()
	rowless.parcels["p00"] = {}
	_expect(TerritoryPaths.build_view(rowless,
		{"entrance": "p00"}).reason == "invalid_parcel",
		"A non-dictionary parcel row is refused")


func _test_path_validation() -> void:
	var view: Dictionary = TerritoryPaths.build_view(_grid_state(), {
		"entrance": "p00", "homesteads": ["p02", "p22"],
	})
	_expect(TerritoryPaths.path({}, "p00", "p22").reason == "invalid_view",
		"An empty view is invalid_view")
	_expect(TerritoryPaths.path(view, "bad id", "p22").reason == "invalid_start",
		"A malformed start is refused")
	_expect(TerritoryPaths.path(view, "p00", "bad id").reason == "invalid_goal",
		"A malformed goal is refused")
	_expect(TerritoryPaths.path(view, "p99", "p22").reason == "unknown_start",
		"A start outside the view is refused")
	_expect(TerritoryPaths.path(view, "p00", "p99").reason == "unknown_goal",
		"A goal outside the view is refused")
	_expect(TerritoryPaths.path(view, "p00", "p22", ["bad id"]).reason == "invalid_blocked",
		"A malformed blocked id is refused")
	_expect(TerritoryPaths.path(view, "p00", "p22", ["p99"]).reason == "unknown_blocked",
		"A blocked id outside the view is refused")
	var error: Dictionary = TerritoryPaths.path(view, "p99", "p22")
	_expect(not bool(error.ok) and error.path.is_empty() and error.distance == -1,
		"A path error carries the empty shape")


func _test_blocking_validation() -> void:
	var view: Dictionary = TerritoryPaths.build_view(_corridor_state(), {
		"entrance": "c1", "homesteads": ["c3"],
	})
	_expect(TerritoryPaths.check_blocking({}, "c2").reason == "invalid_view",
		"An empty view is invalid_view")
	_expect(TerritoryPaths.check_blocking(view, "bad id").reason == "invalid_parcel",
		"A malformed parcel is refused")
	_expect(TerritoryPaths.check_blocking(view, "c9").reason == "unknown_parcel",
		"A parcel outside the view is refused")
	var error: Dictionary = TerritoryPaths.check_blocking(view, "c9")
	_expect(not bool(error.ok) and error.blocked.is_empty()
		and error.newly_blocked.is_empty() and not bool(error.entrance_reachable),
		"A blocking error carries the empty shape")


func _test_bounds() -> void:
	var parcels: Dictionary = {}
	for index: int in TerritoryPaths.MAX_PARCELS + 1:
		var parcel_id: String = "p_%d" % index
		parcels[parcel_id] = _parcel(parcel_id, 0, 0, 0, 0, "",
			TerritoryState.STATUS_UNCLAIMED)
	_expect(TerritoryPaths.build_view({"parcels": parcels},
		{"entrance": "p_0"}).reason == "too_many_parcels",
		"A view over the parcel bound is refused by name")

	var wide: Dictionary = {}
	for index: int in 5:
		var parcel_id: String = "w_%d" % index
		wide[parcel_id] = _parcel(parcel_id, 0, 0, 4096, 4096, "",
			TerritoryState.STATUS_UNCLAIMED)
	_expect(TerritoryPaths.build_view({"parcels": wide},
		{"entrance": "w_0"}).reason == "too_many_cells",
		"A view over the boundary-cell bound is refused by name")


func _test_read_only_and_determinism() -> void:
	var state: Dictionary = _grid_state()
	var snapshot: Dictionary = state.duplicate(true)
	var options: Dictionary = {
		"entrance": "p00", "homesteads": ["p02", "p22"],
	}
	var first: Dictionary = TerritoryPaths.build_view(state, options)
	var second: Dictionary = TerritoryPaths.build_view(state, options)
	_expect(first == second, "Two builds of the same cadastre are identical")
	TerritoryPaths.path(first, "p00", "p22")
	TerritoryPaths.check_blocking(first, "p01")
	TerritoryPaths.check_blocking(first, "p11")
	_expect(state == snapshot,
		"Routing never writes to the cadastre it was given")
	_expect(str(state.parcels["p11"].owner) == PLAYER_A
		and str(state.parcels["p11"].status) == TerritoryState.STATUS_CLAIMED,
		"The claimed parcel keeps its owner and status")


## 3x3 grid of unit parcels, laid out row by row:
##   p00 p01 p02
##   p10 p11 p12
##   p20 p21 p22
## p11 is A's private parcel, p12 is C's; p02 is B's homestead. p01 is the only
## walkable door into p02, so blocking it is the grid's cut vertex.
func _grid_state() -> Dictionary:
	var state: Dictionary = {"parcels": {}}
	state.parcels["p00"] = _parcel("p00", 0, 0, 0, 0, "public", TerritoryState.STATUS_PUBLIC)
	state.parcels["p01"] = _parcel("p01", 1, 0, 1, 0, "", TerritoryState.STATUS_UNCLAIMED)
	state.parcels["p02"] = _parcel("p02", 2, 0, 2, 0, PLAYER_B, TerritoryState.STATUS_CLAIMED)
	state.parcels["p10"] = _parcel("p10", 0, 1, 0, 1, "", TerritoryState.STATUS_UNCLAIMED)
	state.parcels["p11"] = _parcel("p11", 1, 1, 1, 1, PLAYER_A, TerritoryState.STATUS_CLAIMED)
	state.parcels["p12"] = _parcel("p12", 2, 1, 2, 1, PLAYER_C, TerritoryState.STATUS_CLAIMED)
	state.parcels["p20"] = _parcel("p20", 0, 2, 0, 2, "", TerritoryState.STATUS_UNCLAIMED)
	state.parcels["p21"] = _parcel("p21", 1, 2, 1, 2, "public", TerritoryState.STATUS_PUBLIC)
	state.parcels["p22"] = _parcel("p22", 2, 2, 2, 2, PLAYER_C, TerritoryState.STATUS_CLAIMED)
	return state


## c1 -> c2 -> c3, a single line of unit parcels. c3 is B's claimed homestead.
func _corridor_state() -> Dictionary:
	var state: Dictionary = {"parcels": {}}
	state.parcels["c1"] = _parcel("c1", 0, 0, 0, 0, "public", TerritoryState.STATUS_PUBLIC)
	state.parcels["c2"] = _parcel("c2", 1, 0, 1, 0, "", TerritoryState.STATUS_UNCLAIMED)
	state.parcels["c3"] = _parcel("c3", 2, 0, 2, 0, PLAYER_B, TerritoryState.STATUS_CLAIMED)
	return state


## d0 has two one-step approaches to d3, so neither d1 nor d2 blocks it:
##   d0 d2
##   d1 d3
func _diamond_state() -> Dictionary:
	var state: Dictionary = {"parcels": {}}
	state.parcels["d0"] = _parcel("d0", 0, 0, 0, 0, "public", TerritoryState.STATUS_PUBLIC)
	state.parcels["d1"] = _parcel("d1", 0, 1, 0, 1, "", TerritoryState.STATUS_UNCLAIMED)
	state.parcels["d2"] = _parcel("d2", 1, 0, 1, 0, "", TerritoryState.STATUS_UNCLAIMED)
	state.parcels["d3"] = _parcel("d3", 1, 1, 1, 1, PLAYER_B, TerritoryState.STATUS_CLAIMED)
	return state


## Two parcels that touch only at the (1,1) corner.
func _corner_state() -> Dictionary:
	var state: Dictionary = {"parcels": {}}
	state.parcels["e0"] = _parcel("e0", 0, 0, 0, 0, "public", TerritoryState.STATUS_PUBLIC)
	state.parcels["e1"] = _parcel("e1", 1, 1, 1, 1, PLAYER_B, TerritoryState.STATUS_CLAIMED)
	return state


func _parcel(parcel_id: String, min_x: int, min_z: int, max_x: int, max_z: int,
		owner: String, status: String) -> Dictionary:
	return {
		"id": parcel_id,
		"rect": {"min_x": min_x, "min_z": min_z, "max_x": max_x, "max_z": max_z},
		"owner": owner,
		"status": status,
	}


func _clean(values: Array) -> Array:
	var result: Array = []
	for value: Variant in values:
		result.append(str(value))
	return result


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + message)
	print(("PASS " if condition else "FAIL ") + message)
