extends SceneTree
## Pure weather-routine rules. No art, scene or rendered frame is needed: a
## small AnimalSpace stands in for the real navigation region, and the default
## layout is inspected only through art-free layout numbers.

const AnimalWeather = preload("res://scenes/environment/animal_weather.gd")
const Space = preload("res://scenes/environment/animal_space.gd")
const Construction = preload("res://layout/island_construction.gd")
const Plan = preload("res://layout/courtyard_plan.gd")

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)


func _run() -> void:
	var open := _open_space()
	_test_species(open)
	_test_kinds(open)
	_test_order(open)
	_test_blocked()
	_test_constants()
	await process_frame
	for failure: String in failures:
		push_error(failure)
	print("ANIMAL_WEATHER_ROUTINE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _open_space() -> RefCounted:
	var space := Space.new()
	space.configure(Rect2(Vector2.ZERO, Vector2(6.0, 6.0)), 0.18)
	space.bake()
	return space


func _blocked_space() -> RefCounted:
	var space := Space.new()
	space.configure(Rect2(Vector2.ZERO, Vector2(6.0, 6.0)), 0.18)
	space.block(PackedVector2Array([
		Vector2(-1.0, -1.0), Vector2(7.0, -1.0), Vector2(7.0, 7.0), Vector2(-1.0, 7.0)]))
	space.bake()
	return space


func _targets() -> PackedVector2Array:
	return PackedVector2Array([Vector2(4.0, 4.0)])


func _test_species(space: RefCounted) -> void:
	for species: String in ["duck", "goose"]:
		var goal: Dictionary = AnimalWeather.weather_goal(
			"rain", species, Vector2(1.0, 1.0), space, _targets())
		check(not goal.is_empty(), species + " gets a rain goal")
		check(goal.get("space", "") == "water", species + " shelters in its water space")
		check(goal.get("point", Vector2.INF) == Vector2(4.0, 4.0),
			species + " uses the first reachable target")
		var route: PackedVector2Array = space.path(Vector2(1.0, 1.0), goal.get("point", Vector2.INF))
		check(not route.is_empty(), species + " goal routes through space.path()")
		if not route.is_empty():
			check(route[route.size() - 1].distance_to(goal.point) <= Space.CELL,
				species + " route ends at the chosen point")
	var hen: Dictionary = AnimalWeather.weather_goal(
		"rain", "hen", Vector2(1.0, 1.0), space, _targets())
	check(not hen.is_empty(), "hen gets a rain goal")
	check(hen.get("space", "") == "yard", "hen shelters in its yard space")
	var unknown: Dictionary = AnimalWeather.weather_goal(
		"rain", "cat", Vector2(1.0, 1.0), space, _targets())
	check(unknown.is_empty(), "Unknown species keeps its goal")


func _test_kinds(space: RefCounted) -> void:
	for kind: String in ["clear", "cloudy", "unknown", ""]:
		var goal: Dictionary = AnimalWeather.weather_goal(
			kind, "duck", Vector2(1.0, 1.0), space, _targets())
		check(goal.is_empty(), "'" + kind + "' leaves the routine unchanged")
	var rain_a: Dictionary = AnimalWeather.weather_goal(
		"rain", "duck", Vector2(1.0, 1.0), space, _targets())
	var rain_b: Dictionary = AnimalWeather.weather_goal(
		"rain", "duck", Vector2(1.0, 1.0), space, _targets())
	check(rain_a == rain_b, "Repeated rain calls return an identical goal")


func _test_order(space: RefCounted) -> void:
	var skipped: Dictionary = AnimalWeather.weather_goal(
		"rain", "duck", Vector2(1.0, 1.0), space,
		PackedVector2Array([Vector2(10.0, 10.0), Vector2(4.0, 4.0)]))
	check(skipped.get("point", Vector2.INF) == Vector2(4.0, 4.0),
		"An unreachable first target is skipped")
	var ordered: Dictionary = AnimalWeather.weather_goal(
		"rain", "duck", Vector2(1.0, 1.0), space,
		PackedVector2Array([Vector2(4.0, 4.0), Vector2(2.0, 5.0)]))
	check(ordered.get("point", Vector2.INF) == Vector2(4.0, 4.0),
		"Two reachable targets keep caller order")


func _test_blocked() -> void:
	var blocked: RefCounted = _blocked_space()
	var goal: Dictionary = AnimalWeather.weather_goal(
		"rain", "duck", Vector2(1.0, 1.0), blocked, _targets())
	check(goal.is_empty(), "A fully blocked space keeps the current goal")


func _test_constants() -> void:
	var plan := Plan.new()
	var space := Space.new()
	space.configure(Rect2(Vector2(-4.0, -4.0), Vector2(20.0, 16.0)), 0.18)
	space.bake()
	var water_targets: PackedVector2Array = AnimalWeather.water_shelter_targets(plan, space)
	var yard_targets: PackedVector2Array = AnimalWeather.yard_shelter_targets(plan, space)
	check(not water_targets.is_empty(), "Default water targets are constructed")
	check(not yard_targets.is_empty(), "Default yard targets are constructed")
	check(water_targets == AnimalWeather.water_shelter_targets(plan, space),
		"Water targets are deterministic across repeated construction")
	check(yard_targets == AnimalWeather.yard_shelter_targets(plan, space),
		"Yard targets are deterministic across repeated construction")

	var ends: Array[Vector3] = Construction.bridge_points(plan)
	var bridge_mid := (Vector2(ends[0].x, ends[0].z) + Vector2(ends[1].x, ends[1].z)) * 0.5
	var nearest_bridge: float = INF
	var boat := Vector2(plan.anchors.boat.x, plan.anchors.boat.z)
	var boat_lee := boat + AnimalWeather.BOAT_LEE_OFFSETS[0]
	var nearest_boat: float = INF
	for point: Vector2 in water_targets:
		nearest_bridge = minf(nearest_bridge, point.distance_to(bridge_mid))
		nearest_boat = minf(nearest_boat, point.distance_to(boat_lee))
	check(nearest_bridge <= 0.25, "Bridge-span target is in the water target list")
	check(nearest_boat <= 0.25, "Covered-boat lee target is in the water target list")

	var porch := Vector2(plan.anchors.veranda.x, plan.anchors.veranda.z)
	var nearest_porch: float = INF
	for point: Vector2 in yard_targets:
		nearest_porch = minf(nearest_porch, point.distance_to(porch))
	check(nearest_porch <= 0.25, "Porch-eaves target is in the yard target list")

	var goal: Dictionary = AnimalWeather.weather_goal(
		"rain", "duck", Vector2(1.0, 1.0), space, water_targets)
	check(not goal.is_empty(), "The default water target list yields a reachable goal")
	check(goal.get("space", "") == "water", "The default water goal uses the water space")
