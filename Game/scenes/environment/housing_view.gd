extends Node3D
## Shared-world housing presentation.
##
## The mirrored farm document owns the buildings table; this node only derives
## one holder per named yard slot. It is created by the shared-world client and
## never by a local save, so a single-player farm grows no invented homesteads.
## A refresh is a full compare by slot/blueprint/state; unchanged slots keep
## their generated geometry, a demolition removes the holder immediately.

const Catalog = preload("res://farm/building_catalog.gd")
const Layout = preload("res://scenes/environment/housing_layout.gd")
const HouseKit = preload("res://scenes/procedural_lab/house_kit.gd")
const PIGMENT = preload("res://scenes/environment/pigment.gdshader")

## Replaceable so a scene-free test can verify the view without importing art.
var house_builder: Callable = HouseKit.build
## East bank ground, supplied by the scene before the first refresh.
var ground_y: float = 0.0

var _slots: Dictionary = {}
var _stone: ShaderMaterial
var _wood: ShaderMaterial


func refresh(buildings: Dictionary, world_id: String) -> void:
	for slot_id: String in Catalog.SLOTS:
		var entry: Variant = buildings.get(slot_id)
		if not entry is Dictionary or (entry as Dictionary).is_empty():
			_remove(slot_id)
			continue
		var blueprint_id: String = str((entry as Dictionary).get("blueprint", ""))
		if not Layout.has_blueprint(blueprint_id):
			_remove(slot_id)
			continue
		var state: String = "done" if str((entry as Dictionary).get("state", "done")) == "done" else "building"
		var plan: Dictionary = Layout.plan_for(world_id, slot_id, blueprint_id)
		var signature: String = "%s|%s|%s" % [blueprint_id, state, str(plan.get("seed", ""))]
		var holder: Node3D = _slots.get(slot_id) as Node3D
		if holder != null and str(holder.get_meta("signature", "")) == signature:
			continue
		_remove(slot_id)
		_slots[slot_id] = _build_slot(slot_id, plan, blueprint_id, state, signature)


func is_showing(slot_id: String) -> bool:
	return _slots.has(slot_id)


func _build_slot(slot_id: String, plan: Dictionary, blueprint_id: String, state: String,
		signature: String) -> Node3D:
	var holder := Node3D.new()
	holder.name = slot_id
	var pose: Dictionary = Layout.slot_pose(slot_id)
	var at: Vector2 = pose.position
	holder.position = Vector3(at.x, ground_y, at.y)
	holder.rotation.y = float(pose.yaw)
	holder.scale = Vector3.ONE * Layout.PRESENTATION_SCALE
	holder.set_meta("signature", signature)
	holder.set_meta("slot_id", slot_id)
	holder.set_meta("blueprint", blueprint_id)
	holder.set_meta("state", state)
	holder.set_meta("seed", str(plan.get("seed", "")))
	var size: Vector3 = Layout.dimensions(plan)
	holder.set_meta("width", size.x)
	holder.set_meta("depth", size.y)
	holder.set_meta("height", size.z)
	if state == "done":
		var model: Variant = house_builder.call(plan)
		if model is Node3D:
			# Centre the complete footprint (porch included) over the slot.
			(model as Node3D).name = "House"
			(model as Node3D).position.z = (float(plan.back_extent) - float(plan.front_extent)) * 0.5
			holder.add_child(model)
	else:
		holder.add_child(_scaffold(plan))
	add_child(holder)
	return holder


func _remove(slot_id: String) -> void:
	var holder: Node3D = _slots.get(slot_id) as Node3D
	if holder == null:
		return
	_slots.erase(slot_id)
	remove_child(holder)
	holder.queue_free()


func _scaffold(plan: Dictionary) -> Node3D:
	# Clearly unfinished: a stone pad and an open timber frame, no roof or walls.
	var root := Node3D.new()
	root.name = "Foundation"
	var width: float = float(plan.width)
	var depth: float = float(plan.settings.depth)
	var wall_height: float = float(plan.settings.height)
	_box(root, "Pad", Vector3(width + 0.24, 0.16, depth + 0.24), Vector3(0.0, 0.08, 0.0), _material(true))
	for x: float in [-width * 0.5, width * 0.5]:
		for z: float in [-depth * 0.5, depth * 0.5]:
			_box(root, "Post", Vector3(0.12, wall_height, 0.12),
				Vector3(x, 0.16 + wall_height * 0.5, z), _material(false))
	for z: float in [-depth * 0.5, depth * 0.5]:
		_box(root, "Beam", Vector3(width, 0.12, 0.12),
			Vector3(0.0, 0.16 + wall_height, z), _material(false))
	return root


func _box(parent: Node3D, node_name: String, size: Vector3, at: Vector3, material: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.position = at
	node.material_override = material
	parent.add_child(node)


func _material(stone: bool) -> ShaderMaterial:
	if stone:
		if _stone == null:
			_stone = _pigment(Color("8e8163"))
		return _stone
	if _wood == null:
		_wood = _pigment(Color("6b5a3e"))
	return _wood


func _pigment(color: Color) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = PIGMENT
	material.set_shader_parameter("base_color", color)
	return material
