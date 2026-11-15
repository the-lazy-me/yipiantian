extends SceneTree
## Shared-world housing view: deterministic slot layout, a clearly unfinished
## construction state, demolition, and blueprint-driven dimensions.
##
## The house builder is a stub, and the scenery keep-out data below is measured
## from the shipped east-bank dressing once, so this fixture runs without LFS
## art. The real house_kit geometry is covered by component_house_test.gd where
## art exists.

const Catalog = preload("res://farm/building_catalog.gd")
const Layout = preload("res://scenes/environment/housing_layout.gd")
const View = preload("res://scenes/environment/housing_view.gd")
const CourtyardPlan = preload("res://layout/courtyard_plan.gd")

var checks: int = 0
var failures: Array[String] = []
var stub_plans: Array[Dictionary] = []

## Low-canopy envelopes of the deterministic east-bank dressing, in world XZ
## relative to the plan anchor each group is placed at. They are the convex
## hulls of every mesh vertex below 1.09 m world height, which is below the
## actual roof ridge (~1.20 m world at the 0.20 reference scale), so anything
## inside a hull would be visible through a wall or a roof. Canopy above that
## line is deliberately absent: the willow's high branches may pass over roofs.
var WILLOW_LOW: Array = [
	PackedVector2Array([Vector2(1.017, -0.022), Vector2(1.038, -0.019), Vector2(1.265, 0.258), Vector2(1.445, 0.503), Vector2(1.452, 0.517), Vector2(1.661, 1.351), Vector2(1.648, 1.359), Vector2(1.514, 1.225), Vector2(1.441, 1.145), Vector2(1.428, 1.131), Vector2(1.289, 0.860), Vector2(1.027, 0.023)]),
	PackedVector2Array([Vector2(-0.373, -0.213), Vector2(-0.324, -0.278), Vector2(-0.203, -0.374), Vector2(-0.177, -0.393), Vector2(0.309, -0.329), Vector2(0.339, -0.324), Vector2(0.351, -0.321), Vector2(0.369, -0.317), Vector2(0.401, -0.299), Vector2(0.423, -0.280), Vector2(0.432, -0.269), Vector2(0.437, -0.260), Vector2(0.444, -0.231), Vector2(0.375, 0.412), Vector2(0.368, 0.426), Vector2(0.358, 0.437), Vector2(-0.220, 0.719), Vector2(-0.239, 0.726), Vector2(-0.250, 0.717), Vector2(-0.255, 0.701), Vector2(-0.264, 0.631), Vector2(-0.307, 0.311)]),
	PackedVector2Array([Vector2(-1.038, 0.046), Vector2(-1.026, 0.027), Vector2(-0.807, -0.282), Vector2(-0.786, -0.281), Vector2(-0.637, -0.265), Vector2(-0.572, -0.258), Vector2(-0.516, -0.251), Vector2(-0.444, -0.242), Vector2(-0.383, -0.231), Vector2(-0.341, 0.060), Vector2(-0.310, 0.292), Vector2(-0.257, 0.720), Vector2(-0.805, 0.577), Vector2(-0.819, 0.559), Vector2(-0.974, 0.360), Vector2(-0.979, 0.336), Vector2(-1.035, 0.075)]),
	PackedVector2Array([Vector2(-1.462, -1.144), Vector2(-1.449, -1.148), Vector2(-1.089, -1.117), Vector2(-1.040, -1.105), Vector2(-0.988, -1.090), Vector2(0.082, -0.733), Vector2(0.105, -0.723), Vector2(0.117, -0.699), Vector2(0.107, -0.678), Vector2(-0.176, -0.396), Vector2(-0.240, -0.346), Vector2(-0.294, -0.306), Vector2(-0.392, -0.244), Vector2(-0.403, -0.244), Vector2(-0.561, -0.259), Vector2(-0.758, -0.280), Vector2(-0.778, -0.283), Vector2(-0.801, -0.287), Vector2(-0.824, -0.302), Vector2(-0.870, -0.351), Vector2(-1.461, -1.133)]),
]
var BAMBOO_LOW: Array = [
	PackedVector2Array([Vector2(-0.691, 0.649), Vector2(-0.637, 0.342), Vector2(-0.634, 0.331), Vector2(-0.435, -0.102), Vector2(-0.256, -0.471), Vector2(0.272, -0.710), Vector2(0.413, -0.757), Vector2(0.626, -0.785), Vector2(0.814, -0.713), Vector2(0.433, 0.204), Vector2(0.377, 0.339), Vector2(-0.176, 0.761), Vector2(-0.384, 0.869)]),
]
var REEDS_9_LOW: Array = [
	PackedVector2Array([Vector2(-0.224, -0.180), Vector2(-0.207, -0.249), Vector2(-0.183, -0.307), Vector2(-0.136, -0.360), Vector2(-0.042, -0.317), Vector2(-0.001, -0.272), Vector2(0.161, -0.083), Vector2(0.232, 0.125), Vector2(0.244, 0.188), Vector2(0.242, 0.236), Vector2(0.212, 0.321), Vector2(0.166, 0.326), Vector2(0.059, 0.312), Vector2(-0.004, 0.272), Vector2(-0.050, 0.240), Vector2(-0.070, 0.222), Vector2(-0.083, 0.201), Vector2(-0.189, 0.027)]),
]
var REEDS_10_LOW: Array = [
	PackedVector2Array([Vector2(-0.438, -0.128), Vector2(-0.330, -0.186), Vector2(-0.258, -0.193), Vector2(0.036, -0.211), Vector2(0.284, -0.130), Vector2(0.351, -0.097), Vector2(0.396, -0.061), Vector2(0.455, 0.029), Vector2(0.426, 0.076), Vector2(0.337, 0.166), Vector2(0.255, 0.198), Vector2(0.191, 0.218), Vector2(0.160, 0.224), Vector2(0.131, 0.222), Vector2(-0.109, 0.198), Vector2(-0.330, 0.083), Vector2(-0.383, 0.018), Vector2(-0.421, -0.045)]),
]
var GRASS_12_LOW: Array = [
	PackedVector2Array([Vector2(-0.585, -0.017), Vector2(-0.501, -0.345), Vector2(-0.187, -0.507), Vector2(0.323, -0.248), Vector2(0.611, -0.059), Vector2(0.373, 0.275), Vector2(0.133, 0.418), Vector2(-0.508, 0.276)]),
]
var GRASS_13_LOW: Array = [
	PackedVector2Array([Vector2(-0.456, -0.110), Vector2(-0.424, -0.344), Vector2(-0.089, -0.609), Vector2(0.433, -0.320), Vector2(0.424, 0.381), Vector2(-0.121, 0.470), Vector2(-0.280, 0.464), Vector2(-0.319, 0.384), Vector2(-0.445, 0.004)]),
]
var FLOWERS_12_A_LOW: Array = [
	PackedVector2Array([Vector2(-0.324, 0.006), Vector2(-0.317, -0.052), Vector2(-0.223, -0.283), Vector2(-0.214, -0.291), Vector2(-0.167, -0.320), Vector2(-0.156, -0.324), Vector2(-0.146, -0.324), Vector2(-0.115, -0.311), Vector2(-0.106, -0.306), Vector2(-0.059, -0.271), Vector2(-0.016, -0.217), Vector2(-0.008, -0.175), Vector2(-0.008, -0.005), Vector2(-0.012, 0.007), Vector2(-0.039, 0.087), Vector2(-0.047, 0.098), Vector2(-0.057, 0.106), Vector2(-0.154, 0.154), Vector2(-0.165, 0.155)]),
]
var FLOWERS_12_B_LOW: Array = [
	PackedVector2Array([Vector2(-0.320, -0.284), Vector2(-0.318, -0.299), Vector2(-0.312, -0.310), Vector2(-0.279, -0.337), Vector2(-0.268, -0.345), Vector2(-0.199, -0.376), Vector2(-0.112, -0.392), Vector2(-0.060, -0.376), Vector2(0.135, -0.273), Vector2(0.146, -0.262), Vector2(0.220, -0.182), Vector2(0.227, -0.168), Vector2(0.231, -0.151), Vector2(0.226, -0.011), Vector2(0.223, 0.000), Vector2(-0.041, 0.094), Vector2(-0.106, 0.050), Vector2(-0.312, -0.198), Vector2(-0.316, -0.212)]),
]
var FLOWERS_13_A_LOW: Array = [
	PackedVector2Array([Vector2(-0.383, -0.213), Vector2(-0.380, -0.228), Vector2(-0.354, -0.293), Vector2(-0.347, -0.305), Vector2(-0.336, -0.313), Vector2(-0.296, -0.323), Vector2(-0.283, -0.325), Vector2(-0.209, -0.324), Vector2(-0.126, -0.303), Vector2(-0.086, -0.267), Vector2(0.044, -0.096), Vector2(0.049, -0.081), Vector2(0.082, 0.020), Vector2(0.082, 0.036), Vector2(0.079, 0.052), Vector2(0.017, 0.174), Vector2(0.009, 0.183), Vector2(-0.263, 0.156), Vector2(-0.303, 0.091)]),
]
var FLOWERS_13_B_LOW: Array = [
	PackedVector2Array([Vector2(-0.334, -0.136), Vector2(-0.325, -0.168), Vector2(-0.322, -0.179), Vector2(-0.291, -0.236), Vector2(-0.240, -0.291), Vector2(-0.196, -0.307), Vector2(-0.011, -0.337), Vector2(0.002, -0.335), Vector2(0.094, -0.319), Vector2(0.106, -0.313), Vector2(0.117, -0.303), Vector2(0.185, -0.206), Vector2(0.189, -0.196), Vector2(0.057, 0.003), Vector2(-0.009, 0.007), Vector2(-0.277, -0.056), Vector2(-0.287, -0.065), Vector2(-0.326, -0.111), Vector2(-0.332, -0.122)]),
]

## Shoreline rocks (plan.east_stones) and the seven landing stones along the
## bridge's east path, as measured enclosing circles in world XZ. The
## GardenPaths stones are the circulated walkway's east end; its route is
## derived from the same plan, so it is recorded here rather than recomputed.
var SHORE_STONE_RADIUS: float = 0.46
var LANDING_STONE_RADIUS: float = 0.40
var GARDEN_PATH_CIRCLES: Array = [
	Vector2(11.92, -0.72), Vector2(12.05, -1.07), Vector2(12.19, -1.41),
	Vector2(12.32, -1.76), Vector2(12.45, -2.11), Vector2(12.59, -2.45),
]
var GARDEN_PATH_RADIUS: float = 0.30
## Measured horizontal half extents of the authored stone bridge.
var BRIDGE_HALF: Vector2 = Vector2(2.425, 1.0)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_layout()
	_test_scenery_clearance()
	_test_view()
	_finish()


func _test_layout() -> void:
	for blueprint_id: String in Catalog.blueprint_ids():
		_expect(Layout.has_blueprint(blueprint_id),
			"Every catalog blueprint has a presentation mapping (%s)" % blueprint_id)

	var seed_a: String = Layout.seed_for("world-1", "yard_a", "cottage")
	_expect(seed_a == Layout.seed_for("world-1", "yard_a", "cottage"),
		"The seed reproduces from world, slot and blueprint")
	_expect(seed_a != Layout.seed_for("world-1", "yard_b", "cottage"),
		"A different slot changes the seed")
	_expect(seed_a != Layout.seed_for("world-1", "yard_a", "workshop"),
		"A different blueprint changes the seed")
	_expect(seed_a != Layout.seed_for("world-2", "yard_a", "cottage"),
		"A different world changes the seed")

	var first: Dictionary = Layout.plan_for("world-1", "yard_a", "cottage")
	_expect(first == Layout.plan_for("world-1", "yard_a", "cottage"),
		"The house plan is reproducible from the same inputs")
	_expect(first.seed == seed_a, "The house plan carries the derived seed")

	var sizes: Dictionary = {}
	for blueprint_id: String in ["cottage", "workshop", "pavilion"]:
		sizes[blueprint_id] = Layout.dimensions(
			Layout.plan_for("world-1", "yard_a", blueprint_id))
	_expect(sizes.cottage != sizes.workshop and sizes.cottage != sizes.pavilion
		and sizes.workshop != sizes.pavilion,
		"Different blueprints produce different building dimensions")

	# Worst case: every slot uses the widest/deepest blueprint. Positions still
	# must not overlap and must stay on the opposite-bank plateau.
	var plateau: PackedVector2Array = CourtyardPlan.new().plateau(1)
	var half: Vector2 = Layout.footprint_half_extents()
	var boxes: Array[Rect2] = []
	for slot_id: String in Catalog.SLOTS:
		var pose: Dictionary = Layout.slot_pose(slot_id)
		_expect(not pose.is_empty(), "Every catalog slot has a fixed pose")
		var box := Rect2(pose.position - half, half * 2.0)
		for other: Rect2 in boxes:
			_expect(not box.intersects(other), "%s does not overlap another yard slot" % slot_id)
		boxes.append(box)
		for corner: Vector2 in [box.position, box.position + Vector2(box.size.x, 0.0),
				box.position + Vector2(0.0, box.size.y), box.end]:
			_expect(Geometry2D.is_point_in_polygon(corner, plateau),
				"%s stays on the opposite-bank plateau" % slot_id)
	_expect(Layout.slot_pose("yard_f").position == Layout.slot_pose("yard_f").position,
		"The layout order is stable across calls")
	_expect(Layout.slot_pose("not_a_slot").is_empty(), "An unknown slot has no pose")


## Every slot's worst-case footprint must stay outside the deterministic
## east-bank dressing: the low willow branches, the bamboo clump, reeds,
## chrysanthemums and bank grass, the shoreline rocks, the bridge landing
## stones and the circulated walkway. Hulls and circles are supersets of the
## real meshes, so a positive gap here proves no visible overlap.
func _test_scenery_clearance() -> void:
	var plan := CourtyardPlan.new()
	var polygons: Array = []
	var circles: Array = []  # [centre: Vector2, radius: float]
	_add_hulls(polygons, _xz(plan.trees[2].at), WILLOW_LOW)
	_add_hulls(polygons, _xz(plan.bamboo_positions[4]), BAMBOO_LOW)
	_add_hulls(polygons, _xz(plan.reeds[9]), REEDS_9_LOW)
	_add_hulls(polygons, _xz(plan.reeds[10]), REEDS_10_LOW)
	_add_hulls(polygons, _xz(plan.flower_centres[12]), GRASS_12_LOW)
	_add_hulls(polygons, _xz(plan.flower_centres[12]), FLOWERS_12_A_LOW)
	_add_hulls(polygons, _xz(plan.flower_centres[12]), FLOWERS_12_B_LOW)
	_add_hulls(polygons, _xz(plan.flower_centres[13]), GRASS_13_LOW)
	_add_hulls(polygons, _xz(plan.flower_centres[13]), FLOWERS_13_A_LOW)
	_add_hulls(polygons, _xz(plan.flower_centres[13]), FLOWERS_13_B_LOW)
	for stone: Vector3 in plan.east_stones:
		circles.append([Vector2(stone.x, stone.z), SHORE_STONE_RADIUS])
	var path_start := Vector2(plan.east_path[0].x, plan.east_path[0].z)
	var path_end := Vector2(plan.east_path[1].x, plan.east_path[1].z)
	for i in 7:
		circles.append([path_start.lerp(path_end, i / 6.0), LANDING_STONE_RADIUS])
	for centre: Vector2 in GARDEN_PATH_CIRCLES:
		circles.append([centre, GARDEN_PATH_RADIUS])
	polygons.append(_bridge_polygon(plan))

	var half: Vector2 = Layout.footprint_half_extents()
	var worst := 999.0
	for slot_id: String in Catalog.SLOTS:
		var pose: Dictionary = Layout.slot_pose(slot_id)
		var box := Rect2(pose.position - half, half * 2.0)
		var gap: float = _clearance(box, polygons, circles)
		worst = minf(worst, gap)
		_expect(gap > 0.0,
			"%s clears the east-bank planting, rocks and stone paths (%.3f m)" % [slot_id, gap])
	_expect(worst > 0.10, "Every slot keeps a visible margin from the dressing (%.3f m)" % worst)


func _add_hulls(target: Array, anchor: Vector2, hulls: Array) -> void:
	for hull: PackedVector2Array in hulls:
		var world := PackedVector2Array()
		for point: Vector2 in hull:
			world.append(anchor + point)
		target.append(world)


func _bridge_polygon(plan: CourtyardPlan) -> PackedVector2Array:
	var space := Basis(Vector3.UP, deg_to_rad(float(plan.angles.bridge)))
	var anchor: Vector3 = plan.anchors.bridge
	var polygon := PackedVector2Array()
	for local: Vector2 in [Vector2(BRIDGE_HALF.x, BRIDGE_HALF.y), Vector2(-BRIDGE_HALF.x, BRIDGE_HALF.y),
			Vector2(-BRIDGE_HALF.x, -BRIDGE_HALF.y), Vector2(BRIDGE_HALF.x, -BRIDGE_HALF.y)]:
		var point: Vector3 = anchor + space * Vector3(local.x, 0.0, local.y)
		polygon.append(Vector2(point.x, point.z))
	return polygon


func _clearance(box: Rect2, polygons: Array, circles: Array) -> float:
	var best := 999.0
	for polygon: PackedVector2Array in polygons:
		best = minf(best, _rect_to_polygon(box, polygon))
	for circle in circles:
		best = minf(best, _rect_to_point(box, circle[0]) - float(circle[1]))
	return best


func _rect_to_point(box: Rect2, point: Vector2) -> float:
	var nearest := Vector2(clampf(point.x, box.position.x, box.end.x),
		clampf(point.y, box.position.y, box.end.y))
	return nearest.distance_to(point)


func _rect_to_polygon(box: Rect2, polygon: PackedVector2Array) -> float:
	var corners: Array[Vector2] = [box.position, Vector2(box.end.x, box.position.y), box.end,
		Vector2(box.position.x, box.end.y)]
	for corner: Vector2 in corners:
		if Geometry2D.is_point_in_polygon(corner, polygon):
			return 0.0
	for point: Vector2 in polygon:
		if box.has_point(point):
			return 0.0
	for i in polygon.size():
		for k in 4:
			if Geometry2D.segment_intersects_segment(polygon[i],
					polygon[(i + 1) % polygon.size()], corners[k], corners[(k + 1) % 4]) != null:
				return 0.0
	var best := 999.0
	for i in polygon.size():
		var a: Vector2 = polygon[i]
		var b: Vector2 = polygon[(i + 1) % polygon.size()]
		for corner: Vector2 in corners:
			best = minf(best, corner.distance_to(
				Geometry2D.get_closest_point_to_segment(corner, a, b)))
		for point: Vector2 in [a, b]:
			best = minf(best, _rect_to_point(box, point))
	return best


func _test_view() -> void:
	var view := View.new()
	view.name = "YardHomes"
	view.ground_y = 0.11
	view.house_builder = _stub_house
	root.add_child(view)

	var entries: Dictionary = {
		"yard_a": {"blueprint": "cottage", "state": "done"},
		"yard_b": {"blueprint": "workshop", "state": "building"},
	}
	view.refresh(entries, "world-1")
	var done_slot: Node3D = view.get_node_or_null("yard_a") as Node3D
	var active_slot: Node3D = view.get_node_or_null("yard_b") as Node3D
	_expect(done_slot != null and active_slot != null, "Both recorded slots appear")
	_expect(done_slot.get_meta("state") == "done"
		and done_slot.find_child("House", true, false) != null,
		"A done slot shows the generated house")
	_expect(active_slot.find_child("Foundation", true, false) != null
		and active_slot.find_child("House", true, false) == null,
		"A building slot shows an unfinished foundation instead of a house")
	_expect(stub_plans.size() == 1, "Only the done slot asks for house geometry")
	_expect(str(done_slot.get_meta("seed")) == Layout.seed_for("world-1", "yard_a", "cottage"),
		"The visible slot carries its derived seed")

	# A repeated refresh with the same state must not rebuild the geometry.
	var unchanged: Node3D = view.get_node("yard_a") as Node3D
	view.refresh(entries, "world-1")
	_expect(view.get_node("yard_a") == unchanged and stub_plans.size() == 1,
		"An unchanged slot keeps its node and is not rebuilt")

	# Blueprint dimensions are part of the visible slot and differ per blueprint.
	var mixed: Dictionary = {
		"yard_c": {"blueprint": "workshop", "state": "done"},
		"yard_d": {"blueprint": "pavilion", "state": "done"},
	}
	view.refresh(mixed, "world-1")
	var workshop: Node3D = view.get_node("yard_c") as Node3D
	var pavilion: Node3D = view.get_node("yard_d") as Node3D
	_expect(workshop.get_meta("width") != pavilion.get_meta("width")
		or workshop.get_meta("depth") != pavilion.get_meta("depth")
		or workshop.get_meta("height") != pavilion.get_meta("height"),
		"Visible dimensions follow the chosen blueprint")

	# A building becomes a house when the authority's state flips to done.
	var before: Node3D = _refresh_single(view, "yard_e", "pavilion", "building")
	var after: Node3D = _refresh_single(view, "yard_e", "pavilion", "done")
	_expect(before.find_child("Foundation", true, false) != null,
		"The construction state is visible before completion")
	_expect(after != before and after.find_child("House", true, false) != null
		and after.find_child("Foundation", true, false) == null,
		"Completion replaces the foundation with the finished house")

	# Demolition removes the node; an empty table clears every yard.
	view.refresh({"yard_e": {"blueprint": "pavilion", "state": "done"}}, "world-1")
	_expect(view.get_node_or_null("yard_d") == null and not view.is_showing("yard_d"),
		"A demolished slot disappears immediately")
	_expect(view.get_node_or_null("yard_e") != null, "The remaining slot stays")
	view.refresh({}, "world-1")
	_expect(view.get_child_count() == 0 and not view.is_showing("yard_e"),
		"An empty buildings table leaves no invented homesteads")
	view.refresh({"yard_a": {"blueprint": "greenhouse", "state": "done"}}, "world-1")
	_expect(view.get_node_or_null("yard_a") == null,
		"An unknown blueprint is not rendered as some other building")
	view.queue_free()


func _refresh_single(view: Node3D, slot_id: String, blueprint: String, state: String) -> Node3D:
	view.refresh({slot_id: {"blueprint": blueprint, "state": state}}, "world-1")
	return view.get_node(slot_id) as Node3D


func _xz(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)


func _stub_house(plan: Dictionary) -> Node3D:
	stub_plans.append(plan)
	return Node3D.new()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		print("FAIL " + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("HOUSING_VIEW_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
