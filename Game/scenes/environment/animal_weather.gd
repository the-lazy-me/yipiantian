extends RefCounted
## Weather routine rules only: deterministic shelter goals inside a bird's
## existing navigation space. No scene node, art, RNG, clock or save access.
##
## The waterfowl target list starts under the authored bridge span, then falls
## back to the lee of the existing covered boat when the bridge water pocket is
## not reachable from that bird. Every target is a layout number; the caller
## proves reachability with the same Space.path() the birds already use.

const Space = preload("res://scenes/environment/animal_space.gd")
const Construction = preload("res://layout/island_construction.gd")

const KINDS: Array[String] = ["clear", "cloudy", "rain"]
const SWIMMERS: Array[String] = ["duck", "goose"]
# Along-span fractions under the bridge and lateral offsets inside its 1.2 m
# deck width. These are proportions of bridge_points(), not mesh samples.
const BRIDGE_LEE_T: Array[float] = [0.50, 0.62, 0.38, 0.74, 0.26, 0.86]
const BRIDGE_LEE_LATERAL: Array[float] = [0.0, -0.45, 0.45]
# Reachable covered-water fallback: a fixed ring around the existing covered
# boat anchor. The default layout makes the bridge span unreachable from the
# swimmer water component, so the first reachable boat-lee point is used.
const BOAT_LEE_OFFSETS: Array[Vector2] = [
	Vector2(-0.75, 0.95), Vector2(0.0, 1.2), Vector2(-1.2, 0.45),
	Vector2(1.2, 0.2), Vector2(-1.2, -0.45), Vector2(0.0, -1.2),
]
# Walkable points nearest the porch eaves. The porch/coop anchor is layout data.
const YARD_SHELTER_OFFSETS: Array[Vector2] = [
	Vector2.ZERO, Vector2(-1.0, 0.0), Vector2(1.0, 0.0),
	Vector2(0.0, 0.7), Vector2(0.0, -0.7), Vector2(-1.0, 0.7), Vector2(1.0, -0.7),
]


## Pure rule: rain only, and only for a known species. Targets are tried in
## caller order; the first one that the bird's own space can actually reach is
## returned. Empty means "keep the current goal".
static func weather_goal(kind: String, species: String, from: Vector2,
		space: RefCounted, targets: PackedVector2Array) -> Dictionary:
	if kind != "rain" or space == null or not from.is_finite():
		return {}
	var label: String = "water" if species in SWIMMERS else ("yard" if species == "hen" else "")
	if label.is_empty():
		return {}
	for target: Vector2 in targets:
		if not target.is_finite() or not space.contains(target):
			continue
		var route: PackedVector2Array = space.path(from, target)
		if route.is_empty():
			continue
		if route[route.size() - 1].distance_to(target) > Space.CELL:
			continue
		return {"space": label, "point": target}
	return {}


## Waterfowl shelter candidates in preference order: bridge span first, then
## the covered-boat lee. Points are snapped onto the supplied space and near
## duplicates are removed, so the helper's reachability check is the only gate.
static func water_shelter_targets(plan: RefCounted, space: RefCounted) -> PackedVector2Array:
	var result := PackedVector2Array()
	if plan == null or space == null:
		return result
	var ends: Array[Vector3] = Construction.bridge_points(plan)
	var a := Vector2(ends[0].x, ends[0].z)
	var b := Vector2(ends[1].x, ends[1].z)
	var direction := (b - a).normalized()
	var lateral := direction.orthogonal()
	for t: float in BRIDGE_LEE_T:
		for side: float in BRIDGE_LEE_LATERAL:
			_append(result, space, a.lerp(b, t) + lateral * side, Space.CELL * 1.5)
	var boat := Vector2(plan.anchors.boat.x, plan.anchors.boat.z)
	for offset: Vector2 in BOAT_LEE_OFFSETS:
		_append(result, space, boat + offset, Space.CELL * 1.5)
	return result


## Hen candidates in preference order: the walkable points closest to the
## porch eaves. The porch anchor sits inside the structure, so a wider snap is
## intentional; the helper still refuses anything the hen cannot reach.
static func yard_shelter_targets(plan: RefCounted, space: RefCounted) -> PackedVector2Array:
	var result := PackedVector2Array()
	if plan == null or space == null:
		return result
	var porch := Vector2(plan.anchors.veranda.x, plan.anchors.veranda.z)
	for offset: Vector2 in YARD_SHELTER_OFFSETS:
		_append(result, space, porch + offset, 2.0)
	return result


static func _append(result: PackedVector2Array, space: RefCounted, point: Vector2,
		max_snap: float) -> void:
	if not point.is_finite():
		return
	var snapped: Vector2 = space.nearest(point)
	if not snapped.is_finite() or snapped.distance_to(point) > max_snap:
		return
	if not space.contains(snapped):
		return
	for existing: Vector2 in result:
		if existing.distance_to(snapped) < .01:
			return
	result.append(snapped)
