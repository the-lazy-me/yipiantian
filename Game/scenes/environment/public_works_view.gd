extends Node3D
## Shared-world public works presentation.
##
## The authority document owns which projects exist and which are built; this
## node only turns `built` rows into simple procedural markers on the yard slot
## that already displays the row's parcel. Parcels without a yard slot are
## skipped instead of guessed at, and a refresh replaces the whole set: a row
## that stops being built (or disappears) removes its marker.
##
## Positions come from the same contract as the housing view: `TerritoryState`
## maps a parcel to a named yard slot, and `HousingLayout` maps that slot to its
## world pose. No second coordinate table lives here, and no external art is
## loaded.

const TerritoryState = preload("res://world/territory_state.gd")
const HousingLayout = preload("res://scenes/environment/housing_layout.gd")
const UiTokens = preload("res://ui/ui_tokens.gd")

const KIND_VILLAGE_SQUARE: String = "village_square"
const KIND_PUBLIC_WELL: String = "public_well"
const KIND_ROAD_SEGMENT: String = "road_segment"
const KINDS: Array[String] = [
	KIND_VILLAGE_SQUARE, KIND_PUBLIC_WELL, KIND_ROAD_SEGMENT,
]
const STATUS_BUILT: String = "built"

## Ground height of the east bank, supplied by the scene before the first
## refresh. Markers stand on it; their meshes stay above their holder origin.
var ground_y: float = 0.0

## project_id -> {node, signature}; rebuilt only when the visible facts change.
var _marks: Dictionary = {}
var _stone_material: StandardMaterial3D
var _dark_material: StandardMaterial3D


## Accepts either the authority view `{projects: [...]}` or the rows directly.
## Non-built rows, unknown kinds, malformed rows and parcels without a yard slot
## are dropped; the rest are shown as a fresh set.
func refresh(source: Variant) -> void:
	var rows: Variant = source
	if source is Dictionary:
		rows = (source as Dictionary).get("projects", [])
	if not rows is Array:
		clear()
		return
	var next: Dictionary = {}
	for value: Variant in rows:
		if not value is Dictionary:
			continue
		var row: Dictionary = value
		if str(row.get("status", "")) != STATUS_BUILT:
			continue
		var kind: String = str(row.get("kind", ""))
		if kind not in KINDS:
			continue
		var project_id: String = str(row.get("project_id", ""))
		if project_id.is_empty():
			continue
		var parcel_id: String = str(row.get("parcel_id", ""))
		var place: Dictionary = placement_for(parcel_id)
		if place.is_empty():
			continue
		var signature: String = "%s|%s|%s" % [kind, parcel_id, str(place["slot_id"])]
		next[project_id] = {"row": row, "place": place, "signature": signature}
	for project_id: String in _marks.keys():
		if not next.has(project_id):
			_remove(project_id)
	var ids: Array = next.keys()
	ids.sort()
	for project_id: String in ids:
		var entry: Dictionary = next[project_id]
		var holder: Node3D = _marks.get(project_id, {}).get("node") as Node3D
		if holder != null and str(_marks[project_id].get("signature", "")) \
				== str(entry["signature"]):
			continue
		_remove(project_id)
		var row: Dictionary = entry["row"]
		_marks[project_id] = {
			"node": _build(project_id, row, entry["place"], str(entry["signature"])),
			"signature": str(entry["signature"]),
		}


## Removes every marker, e.g. when the world connection is gone.
func clear() -> void:
	for project_id: String in _marks.keys():
		_remove(project_id)


func is_showing(project_id: String) -> bool:
	return _marks.has(project_id)


## World placement for a cadastral parcel, using the housing slot contract.
## Returns `{slot_id, position: Vector2, yaw}` or `{}` when the parcel has no
## yard slot. A caller must not invent a position for the empty result.
static func placement_for(parcel_id: String) -> Dictionary:
	if parcel_id.is_empty():
		return {}
	var slot_id: String = TerritoryState.parcel_slot_id(parcel_id)
	if slot_id.is_empty():
		return {}
	var pose: Dictionary = HousingLayout.slot_pose(slot_id)
	if pose.is_empty():
		return {}
	return {
		"slot_id": slot_id,
		"position": pose.get("position", Vector2.ZERO),
		"yaw": float(pose.get("yaw", 0.0)),
	}


func _build(project_id: String, row: Dictionary, place: Dictionary,
		signature: String) -> Node3D:
	var holder := Node3D.new()
	holder.name = project_id
	var at: Vector2 = place["position"]
	holder.position = Vector3(at.x, ground_y, at.y)
	holder.rotation.y = float(place.get("yaw", 0.0))
	holder.set_meta("project_id", project_id)
	holder.set_meta("kind", str(row.get("kind", "")))
	holder.set_meta("parcel_id", str(row.get("parcel_id", "")))
	holder.set_meta("slot_id", str(place.get("slot_id", "")))
	holder.set_meta("signature", signature)
	match str(row.get("kind", "")):
		KIND_VILLAGE_SQUARE:
			# A low paving disc, distinct from the taller well and the long road.
			_add_cylinder(holder, "Square", 0.50, 0.10, 0.05, true, _stone())
		KIND_PUBLIC_WELL:
			# An open curb read as a well; the dark disc is the shaft mouth.
			_add_cylinder(holder, "Well", 0.18, 0.36, 0.18, false, _stone())
			_add_cylinder(holder, "Water", 0.13, 0.02, 0.34, true, _dark())
		KIND_ROAD_SEGMENT:
			_add_box(holder, "Road", Vector3(0.26, 0.06, 1.10),
				Vector3(0.0, 0.03, 0.0), _stone())
	add_child(holder)
	return holder


func _remove(project_id: String) -> void:
	var node: Node3D = _marks.get(project_id, {}).get("node") as Node3D
	_marks.erase(project_id)
	if node == null:
		return
	remove_child(node)
	node.queue_free()


func _add_cylinder(parent: Node3D, node_name: String, radius: float, height: float,
		centre_y: float, cap_top: bool, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 24
	mesh.rings = 1
	mesh.cap_top = cap_top
	mesh.cap_bottom = true
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.position = Vector3(0.0, centre_y, 0.0)
	node.material_override = material
	parent.add_child(node)
	return node


func _add_box(parent: Node3D, node_name: String, size: Vector3, at: Vector3,
		material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var node := MeshInstance3D.new()
	node.name = node_name
	node.mesh = mesh
	node.position = at
	node.material_override = material
	parent.add_child(node)
	return node


## One shared stone material keeps every public work in the same palette as the
## rest of the farm; the colours come from the UI tokens, not a new asset.
func _stone() -> StandardMaterial3D:
	if _stone_material == null:
		_stone_material = StandardMaterial3D.new()
		_stone_material.albedo_color = UiTokens.EDGE
		_stone_material.roughness = 1.0
	return _stone_material


func _dark() -> StandardMaterial3D:
	if _dark_material == null:
		_dark_material = StandardMaterial3D.new()
		_dark_material.albedo_color = UiTokens.INK
		_dark_material.roughness = 1.0
	return _dark_material
