extends RefCounted
## M11-01 cadastre connectivity slice: deterministic parcel reachability and
## "does this parcel seal the only public path" checks.
##
## Pure rules: no clock, RNG, disk, scene, network or farm document access. The
## module only reads a cadastre-shaped document and returns plain dictionaries;
## it never writes to the document passed in.
##
## Input is a bounded routing view built from a cadastre-shaped document:
##
##   {
##     "parcels": {
##       "parcel_id": {
##         "id": "parcel_id",
##         "rect": {"min_x": 0, "min_z": 0, "max_x": 7, "max_z": 7},
##         "owner": "" | "<player_id>" | "public",
##         "status": "unclaimed" | "claimed" | "public",
##       }
##     }
##   }
##
## `build_view()` derives edge-contact adjacency from the inclusive cell
## rectangles and records whether each parcel is passable. Rectangles that only
## touch at a corner are not adjacent: a walker cannot pass through a point.
## Passability follows `TerritoryState.can_pass()`: unclaimed and public ground
## is open, a claimed parcel is owner-only, and ids in the external `passable`
## list (for example parcels bound to built public works) are open to everyone.
## With no actor the view models an anonymous public walker, which is exactly
## `can_pass()` for a legal player that owns no parcel.
##
## A destination homestead may be entered as the final node even when it is not
## transit-passable: the question is whether the public path reaches its door,
## not whether a visitor may cross the parcel. This exemption applies to the
## goal only; private parcels still block every step before it. A blocked parcel
## can never be entered, including as start or destination.
##
## The graph is bounded: at most MAX_PARCELS nodes and MAX_BOUNDARY_SEGMENTS unit
## boundary cells, so a breadth-first search is bounded by those limits. An
## over-limit view is rejected by name (`too_many_parcels`, `too_many_cells`)
## instead of starting an unbounded search. Rectangles are assumed to be valid
## and non-overlapping, as `TerritoryState.valid()` guarantees for a real
## cadastre; this module does not re-validate the whole document. The caller
## names the built homestead parcels, so the rules never read `FarmState`.

const TerritoryState = preload("res://world/territory_state.gd")
const OwnerIds = preload("res://farm/owner_id.gd")

## Upper bounds for one routing view. The current cadastre stores at most 256
## parcels, but the view is also useful for map-scale or test layouts, so it has
## its own bound well above that document limit.
const MAX_PARCELS: int = 4096
## Total unit boundary cells across every rectangle. A 64x64 grid of unit
## parcels needs 16384; the cap leaves room for mixed shapes without letting one
## pathological layout allocate an unbounded edge table.
const MAX_BOUNDARY_SEGMENTS: int = 65536
const MAX_COORD: int = 4096
## Edge keys span boundary lines from 0 through MAX_COORD + 1.
const EDGE_STRIDE: int = MAX_COORD + 2

const OPTION_KEYS: Array[String] = ["entrance", "homesteads", "passable", "actor"]


## Builds a read-only routing view. `options`:
##   entrance: required parcel id of the public entrance;
##   homesteads: optional list of built homestead parcel ids (default: empty);
##   passable: optional list of parcel ids open to everyone (default: empty);
##   actor: optional legal player id whose `can_pass` rights are used. Omitted
##          or null means the anonymous public walker.
##
## Returns {ok, reason, entrance, homesteads, nodes}. A node row is
## {neighbors: sorted ids, passable: bool}. Reasons are stable strings.
static func build_view(state: Dictionary, options: Dictionary = {}) -> Dictionary:
	if not state.get("parcels") is Dictionary:
		return _view_error("invalid_state")
	if not options is Dictionary:
		return _view_error("invalid_options")
	for key: Variant in options:
		if not OPTION_KEYS.has(str(key)):
			return _view_error("invalid_options")
	var parcels: Dictionary = state.parcels

	if not options.has("entrance"):
		return _view_error("missing_entrance")
	var entrance_value: Variant = options.get("entrance")
	if not _valid_parcel_id(entrance_value):
		return _view_error("invalid_entrance")
	var entrance: String = str(entrance_value)

	var homesteads: Array = []
	if options.has("homesteads"):
		var raw_homesteads: Variant = options.get("homesteads")
		if not raw_homesteads is Array:
			return _view_error("invalid_homestead")
		var seen_homesteads: Dictionary = {}
		for value: Variant in raw_homesteads:
			if not _valid_parcel_id(value):
				return _view_error("invalid_homestead")
			var homestead_id: String = str(value)
			if not seen_homesteads.has(homestead_id):
				seen_homesteads[homestead_id] = true
				homesteads.append(homestead_id)
		homesteads.sort()

	var passable_ids: Array = []
	var passable_set: Dictionary = {}
	if options.has("passable"):
		var raw_passable: Variant = options.get("passable")
		if not raw_passable is Array:
			return _view_error("invalid_passable")
		for value: Variant in raw_passable:
			if not _valid_parcel_id(value):
				return _view_error("invalid_passable")
			var passable_id: String = str(value)
			if not passable_set.has(passable_id):
				passable_set[passable_id] = true
				passable_ids.append(passable_id)
		passable_ids.sort()

	var actor: Variant = null
	var actor_value: Variant = options.get("actor")
	if actor_value != null:
		if not _valid_player(actor_value):
			return _view_error("invalid_actor")
		actor = str(actor_value)

	if parcels.size() > MAX_PARCELS:
		return _view_error("too_many_parcels")

	# Normalize both String and StringName keys to one string id. A parsed
	# cadastre always uses String keys, but a hand-built one may use either
	# spelling; Godot treats the two spellings as the same key.
	var rows: Dictionary = {}
	var ids: Array = []
	var boundary_total: int = 0
	for parcel_value: Variant in parcels:
		if not _valid_parcel_id(parcel_value):
			return _view_error("invalid_parcel")
		var parcel_id: String = str(parcel_value)
		var row: Variant = parcels[parcel_value]
		if not row is Dictionary:
			return _view_error("invalid_parcel")
		var parcel: Dictionary = row
		if parcel.has("id") and str(parcel.get("id")) != parcel_id:
			return _view_error("invalid_parcel")
		var rect: Variant = parcel.get("rect")
		if not _valid_rect(rect):
			return _view_error("invalid_parcel")
		if not TerritoryState.STATUSES.has(str(parcel.get("status", ""))):
			return _view_error("invalid_parcel")
		if not parcel.get("owner", "") is String:
			return _view_error("invalid_parcel")
		var width: int = int(rect.max_x) - int(rect.min_x) + 1
		var height: int = int(rect.max_z) - int(rect.min_z) + 1
		boundary_total += 2 * (width + height)
		if boundary_total > MAX_BOUNDARY_SEGMENTS:
			return _view_error("too_many_cells")
		rows[parcel_id] = parcel
		ids.append(parcel_id)
	ids.sort()

	if not rows.has(entrance):
		return _view_error("unknown_entrance")
	for homestead_id: String in homesteads:
		if not rows.has(homestead_id):
			return _view_error("unknown_homestead")
	for passable_id: String in passable_ids:
		if not rows.has(passable_id):
			return _view_error("unknown_passable")

	# A unit boundary key names the line between two grid cells. Two rectangles
	# that register the same key share that edge segment and are adjacent.
	var occupancy: Dictionary = {}
	var neighbor_sets: Dictionary = {}
	for parcel_id: String in ids:
		neighbor_sets[parcel_id] = {}
	for parcel_id: String in ids:
		var rect: Dictionary = rows[parcel_id].rect
		var min_x: int = int(rect.min_x)
		var max_x: int = int(rect.max_x)
		var min_z: int = int(rect.min_z)
		var max_z: int = int(rect.max_z)
		for z: int in range(min_z, max_z + 1):
			_link_edge(occupancy, neighbor_sets, _edge_key(min_x, z, 0), parcel_id)
			_link_edge(occupancy, neighbor_sets, _edge_key(max_x + 1, z, 0), parcel_id)
		for x: int in range(min_x, max_x + 1):
			_link_edge(occupancy, neighbor_sets, _edge_key(x, min_z, 1), parcel_id)
			_link_edge(occupancy, neighbor_sets, _edge_key(x, max_z + 1, 1), parcel_id)

	var nodes: Dictionary = {}
	for parcel_id: String in ids:
		var neighbors: Array = (neighbor_sets[parcel_id] as Dictionary).keys()
		neighbors.sort()
		nodes[parcel_id] = {
			"neighbors": neighbors,
			"passable": _is_passable(state, parcel_id,
				str(rows[parcel_id].get("status", "")), actor, passable_set),
		}
	return {
		"ok": true, "reason": "", "entrance": entrance,
		"homesteads": homesteads, "nodes": nodes,
	}


## Deterministic shortest path between two parcels. `blocked` is an optional list
## of parcel ids treated as impassable for this query. A valid query always has
## ok=true and reason=""; `reachable` carries the answer. `distance` is the path
## length in edges, or -1 when unreachable.
static func path(view: Dictionary, start: Variant, goal: Variant,
		blocked: Array = []) -> Dictionary:
	if not _view_ready(view):
		return _path_error("invalid_view")
	if not _valid_parcel_id(start):
		return _path_error("invalid_start")
	if not _valid_parcel_id(goal):
		return _path_error("invalid_goal")
	var start_id: String = str(start)
	var goal_id: String = str(goal)
	var nodes: Dictionary = view.nodes
	if not nodes.has(start_id):
		return _path_error("unknown_start")
	if not nodes.has(goal_id):
		return _path_error("unknown_goal")
	var blocked_result: Dictionary = _blocked_set(nodes, blocked)
	if not bool(blocked_result.get("ok", false)):
		return _path_error(str(blocked_result.get("reason", "")))
	var blocked_set: Dictionary = blocked_result.ids
	if blocked_set.has(start_id) or blocked_set.has(goal_id):
		return _path_result(true, false, [], -1)
	if not bool(nodes[start_id].get("passable", false)):
		return _path_result(true, false, [], -1)
	if start_id == goal_id:
		return _path_result(true, true, [start_id], 0)

	var search: Dictionary = _search(view, start_id, blocked_set)
	var parents: Dictionary = search.parents
	var distances: Dictionary = search.distances
	if parents.has(goal_id):
		var route: Array = _reconstruct(parents, start_id, goal_id)
		return _path_result(true, true, route, int(distances[goal_id]))

	# Destination exemption: an impassable goal is reachable when a passable
	# neighbour is reachable. The step into the goal is the visit itself, so it
	# may not be used to continue through the goal.
	if not bool(nodes[goal_id].get("passable", false)):
		var best: String = ""
		var best_distance: int = -1
		var goal_neighbors: Array = (nodes[goal_id].neighbors as Array).duplicate()
		goal_neighbors.sort()
		for neighbor_value: Variant in goal_neighbors:
			var neighbor: String = str(neighbor_value)
			if not parents.has(neighbor):
				continue
			var distance: int = int(distances[neighbor])
			if best.is_empty() or distance < best_distance \
					or (distance == best_distance and neighbor < best):
				best = neighbor
				best_distance = distance
		if not best.is_empty():
			var route: Array = _reconstruct(parents, start_id, best)
			route.append(goal_id)
			return _path_result(true, true, route, best_distance + 1)
	return _path_result(true, false, [], -1)


## Core acceptance check: pretend `parcel_id` becomes impassable, then test
## whether the public entrance can still reach every built homestead parcel.
## Returns {ok, reason, parcel, entrance, entrance_reachable, blocked,
## newly_blocked}. `blocked` lists homesteads unreachable after the hypothetical
## block (a homestead already unreachable before it also appears), while
## `newly_blocked` lists only those the block actually cuts off. Both are sorted.
static func check_blocking(view: Dictionary, parcel_id: Variant) -> Dictionary:
	if not _view_ready(view):
		return _blocking_error("invalid_view", str(parcel_id))
	if not _valid_parcel_id(parcel_id):
		return _blocking_error("invalid_parcel", str(parcel_id))
	var target: String = str(parcel_id)
	var nodes: Dictionary = view.nodes
	if not nodes.has(target):
		return _blocking_error("unknown_parcel", target)
	var entrance: String = str(view.entrance)

	var baseline_distances: Dictionary = {}
	if _start_ready(nodes, entrance, {}):
		baseline_distances = _search(view, entrance, {}).distances
	var blocked_after: Dictionary = {target: true}
	var after_distances: Dictionary = {}
	if _start_ready(nodes, entrance, blocked_after):
		after_distances = _search(view, entrance, blocked_after).distances

	var blocked_list: Array = []
	var newly_blocked: Array = []
	for homestead_value: Variant in view.homesteads:
		var homestead: String = str(homestead_value)
		var before: bool = _homestead_reached(nodes, homestead, baseline_distances, {})
		var after: bool = _homestead_reached(nodes, homestead, after_distances, blocked_after)
		if not after:
			blocked_list.append(homestead)
			if before:
				newly_blocked.append(homestead)
	return {
		"ok": true, "reason": "", "parcel": target, "entrance": entrance,
		"entrance_reachable": after_distances.has(entrance),
		"blocked": blocked_list, "newly_blocked": newly_blocked,
	}


## Sorted breadth-first traversal over passable, unblocked nodes. The caller
## checks that the start is passable; blocked starts produce an empty search.
static func _search(view: Dictionary, start: String, blocked: Dictionary) -> Dictionary:
	var nodes: Dictionary = view.nodes
	var parents: Dictionary = {start: ""}
	var distances: Dictionary = {start: 0}
	var queue: Array[String] = [start]
	var head: int = 0
	while head < queue.size():
		var current: String = queue[head]
		head += 1
		var neighbors: Array = (nodes[current].neighbors as Array).duplicate()
		neighbors.sort()
		for neighbor_value: Variant in neighbors:
			var neighbor: String = str(neighbor_value)
			if blocked.has(neighbor) or not bool(nodes[neighbor].passable):
				continue
			if parents.has(neighbor):
				continue
			parents[neighbor] = current
			distances[neighbor] = int(distances[current]) + 1
			queue.append(neighbor)
	return {"parents": parents, "distances": distances}


static func _reconstruct(parents: Dictionary, start: String, goal: String) -> Array:
	var route: Array = []
	var current: String = goal
	while current != start:
		route.append(current)
		current = str(parents[current])
	route.append(start)
	route.reverse()
	return route


static func _start_ready(nodes: Dictionary, entrance: String,
		blocked: Dictionary) -> bool:
	return nodes.has(entrance) and not blocked.has(entrance) \
		and bool(nodes[entrance].passable)


## A homestead is reached when its own parcel is reached, or when a reached
## passable neighbour is adjacent: the visitor stands at its door. `distances`
## only contains passable nodes, so a reached neighbour is always walkable.
## Blocking the homestead itself does not remove a still-walkable door on its
## neighbour; it only removes the option of crossing the homestead.
static func _homestead_reached(nodes: Dictionary, homestead: String,
		distances: Dictionary, blocked: Dictionary) -> bool:
	if distances.has(homestead):
		return true
	for neighbor_value: Variant in nodes[homestead].neighbors:
		var neighbor: String = str(neighbor_value)
		if blocked.has(neighbor):
			continue
		if distances.has(neighbor):
			return true
	return false


static func _is_passable(state: Dictionary, parcel_id: String, status: String,
		actor: Variant, passable_set: Dictionary) -> bool:
	if passable_set.has(parcel_id):
		return true
	if actor == null:
		# The anonymous public walker owns no parcel, so this is `can_pass()`
		# with an empty owner match: only public and unclaimed ground is open.
		return status == TerritoryState.STATUS_PUBLIC \
			or status == TerritoryState.STATUS_UNCLAIMED
	return TerritoryState.can_pass(state, parcel_id, actor)


static func _link_edge(occupancy: Dictionary, neighbor_sets: Dictionary,
		key: int, parcel_id: String) -> void:
	var other: Variant = occupancy.get(key)
	if other == null:
		occupancy[key] = parcel_id
		return
	var other_id: String = str(other)
	if other_id == parcel_id:
		return
	(neighbor_sets[parcel_id] as Dictionary)[other_id] = true
	(neighbor_sets[other_id] as Dictionary)[parcel_id] = true


## Packs a unit boundary line into one integer. Axis 0 is a vertical line
## between cells (x-1, z) and (x, z); axis 1 is horizontal between (x, z-1) and
## (x, z).
static func _edge_key(x: int, z: int, axis: int) -> int:
	return (x * EDGE_STRIDE + z) * 2 + axis


static func _blocked_set(nodes: Dictionary, blocked: Array) -> Dictionary:
	var result: Dictionary = {}
	for value: Variant in blocked:
		if not _valid_parcel_id(value):
			return {"ok": false, "reason": "invalid_blocked", "ids": {}}
		var parcel_id: String = str(value)
		if not nodes.has(parcel_id):
			return {"ok": false, "reason": "unknown_blocked", "ids": {}}
		result[parcel_id] = true
	return {"ok": true, "reason": "", "ids": result}


static func _view_ready(view: Dictionary) -> bool:
	if not view.get("nodes") is Dictionary:
		return false
	if not view.get("entrance") is String:
		return false
	if not view.get("homesteads") is Array:
		return false
	var nodes: Dictionary = view.nodes
	if nodes.size() > MAX_PARCELS or not nodes.has(str(view.entrance)):
		return false
	for homestead_value: Variant in view.homesteads:
		if not homestead_value is String or not nodes.has(str(homestead_value)):
			return false
	for parcel_value: Variant in nodes:
		if not _valid_parcel_id(parcel_value):
			return false
		var row: Variant = nodes[parcel_value]
		if not row is Dictionary or not row.get("neighbors") is Array \
				or not row.get("passable") is bool:
			return false
		for neighbor_value: Variant in row.neighbors:
			if not neighbor_value is String or not nodes.has(str(neighbor_value)):
				return false
	return true


static func _valid_rect(value: Variant) -> bool:
	if not value is Dictionary or value.size() != 4:
		return false
	for key: String in ["min_x", "min_z", "max_x", "max_z"]:
		if not value.has(key) or not _is_cell(value[key]):
			return false
	return int(value.min_x) <= int(value.max_x) \
		and int(value.min_z) <= int(value.max_z)


static func _is_cell(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_COORD) \
		and number == floorf(number)


static func _valid_parcel_id(value: Variant) -> bool:
	# A hand-built dictionary may key a parcel with a StringName (`row.p00 = ...`),
	# while a parsed cadastre always uses String keys. Both name the same parcel.
	return (value is String or value is StringName) and OwnerIds.valid(str(value))


static func _valid_player(value: Variant) -> bool:
	return value is String and str(value) != TerritoryState.PUBLIC_OWNER \
		and OwnerIds.valid(value)


static func _view_error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "entrance": "", "homesteads": [], "nodes": {}}


static func _path_result(ok: bool, path_reached: bool, route: Array,
		distance: int) -> Dictionary:
	return {
		"ok": ok, "reason": "", "reachable": path_reached,
		"path": route, "distance": distance,
	}


static func _path_error(reason: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "reachable": false,
		"path": [], "distance": -1,
	}


static func _blocking_error(reason: String, parcel_id: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "parcel": parcel_id, "entrance": "",
		"entrance_reachable": false, "blocked": [], "newly_blocked": [],
	}
