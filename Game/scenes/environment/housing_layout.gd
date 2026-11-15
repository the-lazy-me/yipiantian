extends RefCounted
## Fixed shared-world yard layout for the named housing slots.
##
## The farm document stores only slot ids; positions and appearance are view
## decisions. Slots use an explicit fixed table on the opposite bank of the
## courtyard, in catalog order. The table is not a regular lattice: the east
## bank already holds a willow, bamboo, reeds, chrysanthemums, shoreline rocks
## and the bridge's stone path, so a lattice at a readable size cannot avoid
## them. Each position was placed to keep both the finished house and the
## construction frame clear of that scenery at PRESENTATION_SCALE, with the
## measured low-canopy envelope leaving at least 0.13 m. Only the willow canopy
## passes over the roofs, and it stays above them. No clock, RNG or scene state
## enters the seed or the pose.

const Catalog = preload("res://farm/building_catalog.gd")
const HouseKit = preload("res://scenes/procedural_lab/house_kit.gd")

## Every slot uses the same scale; the blueprint still owns the proportions.
## 0.19 keeps all six slots on the plateau with a measured margin instead of
## touching the planted east bank. A larger scale only fits after ceding plants
## or a rock/path, which this slice does not do.
const PRESENTATION_SCALE: float = 0.19
## Slot centre in world XZ, indexed by Catalog.SLOTS: the table is listed in
## catalog order and that order is part of the layout contract.
const SLOT_CENTRES: Array[Vector2] = [
	Vector2(15.58, -2.52), Vector2(11.08, -2.28), Vector2(15.58, -1.02),
	Vector2(11.04, -3.74), Vector2(13.72, -2.94), Vector2(11.08, -5.04),
]

const BLUEPRINT_OPTIONS: Dictionary = {
	"cottage": {"bays": 2, "depth": 3.6, "height": 2.4, "pitch": 24.0, "porch": 1, "openings": 0},
	"workshop": {"bays": 3, "depth": 5.2, "height": 3.2, "pitch": 34.0, "porch": 0, "openings": 2},
	"pavilion": {"bays": 2, "depth": 4.4, "height": 2.6, "pitch": 38.0, "porch": 1, "openings": 1},
}


static func has_blueprint(blueprint_id: String) -> bool:
	return BLUEPRINT_OPTIONS.has(blueprint_id)


static func slot_pose(slot_id: String) -> Dictionary:
	# Unknown slots return an empty pose; callers iterate the catalog.
	var index: int = Catalog.SLOTS.find(slot_id)
	if index < 0 or index >= SLOT_CENTRES.size():
		return {}
	return {"position": SLOT_CENTRES[index], "yaw": 0.0}


## World-XZ half extents a slot needs for the tallest/widest current blueprint.
## The scenery checks use this worst case so every blueprint fits every slot.
static func footprint_half_extents() -> Vector2:
	var width: float = 0.0
	var depth: float = 0.0
	for blueprint_id: String in BLUEPRINT_OPTIONS:
		var size: Vector3 = dimensions(plan_for("", "yard_a", blueprint_id))
		# The roof overhangs the walls by 0.35 m on each side.
		width = maxf(width, size.x + 0.70)
		depth = maxf(depth, size.y)
	return Vector2(width, depth) * 0.5 * PRESENTATION_SCALE


## Tallest point of a scaled house, used to prove scenery stays above the roof.
static func roof_height() -> float:
	var top: float = 0.0
	for blueprint_id: String in BLUEPRINT_OPTIONS:
		var plan: Dictionary = plan_for("", "yard_a", blueprint_id)
		top = maxf(top, HouseKit.roof_y(0.0, plan.settings))
	return top * PRESENTATION_SCALE


static func seed_for(world_id: String, slot_id: String, blueprint_id: String) -> String:
	# Same world, slot and blueprint always reproduce the same joinery and tile
	# tones after a reload, on either client, or when the scene is rebuilt.
	return "world:%s/slot:%s/blueprint:%s" % [world_id, slot_id, blueprint_id]


static func plan_for(world_id: String, slot_id: String, blueprint_id: String) -> Dictionary:
	if not has_blueprint(blueprint_id):
		return {}
	var options: Dictionary = (BLUEPRINT_OPTIONS[blueprint_id] as Dictionary).duplicate()
	return HouseKit.plan(seed_for(world_id, slot_id, blueprint_id), options)


static func dimensions(plan: Dictionary) -> Vector3:
	# Width, full front-to-back extent and ridge height, in house-kit metres.
	if plan.is_empty():
		return Vector3.ZERO
	return Vector3(float(plan.width), float(plan.front_extent) + float(plan.back_extent),
		HouseKit.roof_y(0.0, plan.settings))
