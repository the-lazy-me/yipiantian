extends SceneTree
## Public works view: built rows become one procedural marker each, placed on
## the same yard slot contract the housing view uses. Rows that are not built,
## unknown kinds and parcels without a yard slot are skipped rather than guessed,
## and a refresh replaces the whole set without stacking nodes.
##
## Scene-free: the view builds StandardMaterial3D meshes from UI token colours,
## so this fixture needs no themed font, texture or LFS art.

const View = preload("res://scenes/environment/public_works_view.gd")
const Layout = preload("res://scenes/environment/housing_layout.gd")
const TerritoryState = preload("res://world/territory_state.gd")

const SQUARE: String = "village_square"
const WELL: String = "public_well"
const ROAD: String = "road_segment"

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_placement()
	var view := View.new()
	view.name = "PublicWorksView"
	view.ground_y = 0.11
	root.add_child(view)
	_test_built_kinds(view)
	_test_skips(view)
	_test_replacement(view)
	view.queue_free()
	_finish()


func _test_placement() -> void:
	var first: Dictionary = View.placement_for("parcel_01")
	_expect(str(first.get("slot_id", "")) == "yard_a",
		"A parcel maps to the same yard slot the housing view uses")
	var pose: Dictionary = Layout.slot_pose("yard_a")
	_expect(first.get("position") == pose.get("position"),
		"The view reuses the housing slot position instead of copying coordinates")
	_expect(str(View.placement_for("parcel_06").get("slot_id", "")) == "yard_f",
		"The last default parcel maps to the last yard slot")
	for parcel_id: String in ["", "parcel_99", "yard_a", "parcel_1"]:
		_expect(View.placement_for(parcel_id).is_empty(),
			"An unknown or unbound parcel has no placement (%s)" % parcel_id)
	var reverse: String = TerritoryState.parcel_slot_id("parcel_03")
	_expect(reverse == "yard_c", "The parcel-to-slot contract is unchanged")


func _test_built_kinds(view: Node3D) -> void:
	view.refresh([
		_built("p_square", SQUARE, "parcel_01"),
		_built("p_well", WELL, "parcel_02"),
		_built("p_road", ROAD, "parcel_03"),
	])
	_expect(view.get_child_count() == 3, "Three built projects create three markers")
	var square: Node3D = view.get_node_or_null("p_square") as Node3D
	var well: Node3D = view.get_node_or_null("p_well") as Node3D
	var road: Node3D = view.get_node_or_null("p_road") as Node3D
	_expect(square != null and well != null and road != null,
		"Each marker is named by its project id")
	_expect(square != null and str(square.get_meta("kind", "")) == SQUARE
		and square.find_child("Square", true, false) is MeshInstance3D,
		"A village square gets a low paving disc")
	_expect(well != null and str(well.get_meta("kind", "")) == WELL
		and well.find_child("Well", true, false) is MeshInstance3D
		and well.find_child("Water", true, false) is MeshInstance3D,
		"A public well gets a curb with a dark mouth")
	_expect(road != null and str(road.get_meta("kind", "")) == ROAD
		and road.find_child("Road", true, false) is MeshInstance3D,
		"A road segment gets a narrow long slab")

	# Every marker stands on the supplied ground at its parcel's yard pose.
	var pose: Dictionary = Layout.slot_pose("yard_a")
	var at: Vector2 = pose["position"]
	_expect(square != null and square.position.is_equal_approx(
		Vector3(at.x, 0.11, at.y)), "The marker sits on the ground at the slot centre")
	_expect(square != null and str(square.get_meta("slot_id", "")) == "yard_a"
		and str(square.get_meta("parcel_id", "")) == "parcel_01",
		"The marker records the parcel and slot it was placed at")
	var square_mesh: MeshInstance3D = square.find_child("Square", true, false) \
		as MeshInstance3D
	_expect(square_mesh != null and square_mesh.mesh is CylinderMesh
		and (square_mesh.mesh as CylinderMesh).height < 0.2,
		"The square is a low slab, not a tall building")
	var road_mesh: MeshInstance3D = road.find_child("Road", true, false) \
		as MeshInstance3D
	_expect(road_mesh != null and road_mesh.mesh is BoxMesh,
		"The road uses a box slab")
	if road_mesh != null and road_mesh.mesh is BoxMesh:
		var size: Vector3 = (road_mesh.mesh as BoxMesh).size
		_expect(size.z > size.x and size.y < size.x,
			"The road slab is long, narrow and thin")

	# Two projects on one parcel still produce two markers; neither overwrites
	# the other, and the view never silently relocates either.
	view.refresh([
		_built("p_square", SQUARE, "parcel_01"),
		_built("p_square_b", SQUARE, "parcel_01"),
	])
	_expect(view.get_child_count() == 2
		and view.get_node_or_null("p_square") != null
		and view.get_node_or_null("p_square_b") != null,
		"Two projects on one parcel both keep a marker")


func _test_skips(view: Node3D) -> void:
	view.refresh([
		_built("p_unbuilt", SQUARE, "parcel_01").merged(
			{"status": "unbuilt"}, true),
		_built("p_funded", WELL, "parcel_02").merged(
			{"status": "funded"}, true),
		_built("p_empty_parcel", ROAD, ""),
		_built("p_unknown_parcel", SQUARE, "parcel_99"),
		_built("p_unknown_kind", "statue", "parcel_01"),
		_built("", SQUARE, "parcel_01"),
		{"status": "built", "kind": SQUARE, "parcel_id": "parcel_01"},
		"not a row",
	])
	_expect(view.get_child_count() == 0,
		"Non-built, unknown-kind, malformed and unbound rows are skipped")
	view.refresh({"projects": []})
	_expect(view.get_child_count() == 0, "An empty authority view leaves no markers")


func _test_replacement(view: Node3D) -> void:
	view.refresh([
		_built("p_square", SQUARE, "parcel_01"),
		_built("p_well", WELL, "parcel_02"),
	])
	var square: Node3D = view.get_node("p_square") as Node3D
	# A repeated refresh with the same facts keeps the same geometry.
	view.refresh([
		_built("p_square", SQUARE, "parcel_01"),
		_built("p_well", WELL, "parcel_02"),
	])
	_expect(view.get_child_count() == 2 and view.get_node("p_square") == square,
		"Repeating the same view does not stack or rebuild markers")
	# A full replacement removes a project the authority no longer reports and
	# keeps the remaining one.
	view.refresh([_built("p_well", WELL, "parcel_02")])
	_expect(view.get_child_count() == 1
		and view.get_node_or_null("p_square") == null
		and view.get_node_or_null("p_well") != null
		and not view.is_showing("p_square"),
		"A refresh replaces the whole set instead of merging rows")
	# A rebuilt project with a different kind or parcel is a new marker, not the
	# old geometry with new metadata.
	var before: Node3D = view.get_node("p_well") as Node3D
	view.refresh([_built("p_well", ROAD, "parcel_03")])
	var after: Node3D = view.get_node("p_well") as Node3D
	_expect(after != before and after.get_meta("kind") == ROAD
		and after.get_meta("slot_id") == "yard_c",
		"A changed kind or parcel rebuilds the marker")
	view.clear()
	_expect(view.get_child_count() == 0 and not view.is_showing("p_well"),
		"Clearing removes every marker")


func _built(project_id: String, kind: String, parcel_id: String) -> Dictionary:
	return {
		"project_id": project_id,
		"kind": kind,
		"parcel_id": parcel_id,
		"funded": 300,
		"pledged": 300,
		"status": "built",
		"built_utc": 1000.0,
	}


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		print("FAIL " + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("PUBLIC_WORKS_VIEW_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
