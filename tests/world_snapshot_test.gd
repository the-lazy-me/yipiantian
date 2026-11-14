extends SceneTree
## The snapshot a member restores when its event tail aged out.
##
## The summary view only carried the field grid, so a member that lost the tail
## could not see the layout, kitchen, animals, memories, season or decorations.
## This proves the summary carries the whole restorable authority, that a member
## rebuilds it through the same validators a disk load uses, and that a damaged
## document is refused instead of half-applied.

const HeadlessWorld = preload("res://world/headless_world.gd")
const WorldMember = preload("res://world/world_member.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Plan = preload("res://layout/courtyard_plan.gd")

const START: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []
var dir: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	dir = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir() \
		.path_join(".local/verification/world-snapshot-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var world := HeadlessWorld.new()
	var opened: Dictionary = world.open(dir, START)
	_expect(opened.ok and world.farm != null, "A fresh authoritative world opens")
	if not opened.ok or world.farm == null:
		_finish()
		return

	# One commit so the snapshot carries event history, not just initial state.
	_expect(world.execute(FarmCommand.make("snap-harvest", "field_03", "cell_06", START)).ok,
		"A mature cell is harvested into the world")
	_expect(world.execute(FarmCommand.make_sow("snap-sow", "field_01", "cell_01", "greens", START)).ok,
		"A new crop is sown")
	# Every section the view used to omit gets a value worth carrying.
	_expect(world.farm.kitchen_action("start", {"recipe": "leaf_stir", "crop": "greens"}, 0,
		START + 5.0).ok, "A kitchen job starts")
	_expect(world.farm.animal_action("LakeDuck1", "name", "小豆", 0).ok, "An animal is renamed")
	_expect(world.farm.remember("dawn", START + 6.0), "A memory is recorded")
	_expect(world.farm.set_season("after_rain"), "The season changes")
	world.decorations.unlock({"greens": 3})
	_expect(world.decorations.place("pot", "ground_01", 0).ok, "A decoration is placed")
	var layout: Dictionary = world.farm.snapshot().layout
	var plan: RefCounted = Plan.from_snapshot(layout)
	var construction: Dictionary = plan.construction.duplicate(true)
	construction.flocks.duck.count = int(construction.flocks.duck.count) + 1
	_expect(plan.apply_construction(construction), "The fixture adds one duck to the flock")
	_expect(world.farm.apply_layout(plan.snapshot(), START + 7.0).ok, "The edited layout is accepted")
	var saved: Dictionary = world.save()
	_expect(saved.ok, "The world persists through the store")
	if not saved.ok:
		_finish()
		return

	# What the member receives after a restart, as if the tail had aged out.
	var reopened := HeadlessWorld.new()
	_expect(reopened.open(dir, START + 8.0).ok, "The world reopens from disk")
	var document: Dictionary = reopened.state_snapshot()
	_expect(document.size() == 4, "The snapshot document has a clock, a farm, decorations and nature")
	_expect((document.get("nature", {}) as Dictionary).get("seed", -1) == reopened.nature.get_seed(),
		"The snapshot carries the persisted nature seed")
	var farm_data: Dictionary = document.get("farm", {}) as Dictionary
	_expect(int(farm_data.get("transaction", {}).get("sequence", 0)) == 2,
		"The snapshot carries the committed sequence")
	_expect(str(farm_data.get("season", "")) == "after_rain", "The snapshot carries the season")
	_expect(str(farm_data.get("kitchen", {}).get("jobs", {}).get("stove", {}).get("recipe", "")) == "leaf_stir",
		"The snapshot carries the running kitchen job")
	_expect(str(farm_data.get("animals", {}).get("LakeDuck1", {}).get("name", "")) == "小豆",
		"The snapshot carries the animal name")
	_expect((farm_data.get("memories", {}).get("marks", {}) as Dictionary).has("dawn"),
		"The snapshot carries the recorded memory")
	_expect((farm_data.get("layout", {}).get("construction", {}).get("flocks", {}) \
		.get("duck", {}) as Dictionary).get("count", 0) == int(construction.flocks.duck.count),
		"The snapshot carries the edited layout")
	_expect(str((document.get("decorations", {}) as Dictionary).get("pot", {}) \
		.get("slot_id", "")) == "ground_01", "The snapshot carries the placed decoration")

	# The member rebuilds the whole world, not just a field view, and it must
	# match the authority exactly.
	var member := WorldMember.new()
	member.snapshot = document
	var restored: Dictionary = member.restore_state()
	_expect(bool(restored.get("ok", false)), "The member restores the snapshot")
	if restored.get("ok", false):
		var farm: RefCounted = restored.farm
		_expect(farm.snapshot() == reopened.farm.snapshot(),
			"The restored farm equals the authoritative one")
		_expect((restored.decorations as RefCounted).snapshot() == reopened.decorations.snapshot(),
			"The restored decorations equal the authoritative ones")
		_expect((restored.nature as RefCounted).snapshot() == reopened.nature.snapshot(),
			"The restored nature seed equals the authority's")
		_expect(is_equal_approx(float(restored.now_utc), reopened.now_utc),
			"The restored clock matches the authority")

	# A network payload is untrusted input: a damaged document must be refused.
	member.snapshot = {}
	_expect(str(member.restore_state().reason) == "no_snapshot",
		"An empty snapshot is refused")
	member.snapshot = {"now_utc": START, "farm": {}, "decorations": document.decorations}
	_expect(str(member.restore_state().reason) == "invalid_farm",
		"A farm document that fails validation is refused")
	var damaged: Dictionary = (document.decorations as Dictionary).duplicate(true)
	damaged.erase("pot")
	member.snapshot = {"now_utc": START, "farm": document.farm, "decorations": damaged}
	_expect(str(member.restore_state().reason) == "invalid_decorations",
		"A decorations document that fails validation is refused")
	member.snapshot = {"now_utc": -1.0, "farm": document.farm, "decorations": document.decorations}
	_expect(str(member.restore_state().reason) == "invalid_time",
		"A clock before the epoch is refused")
	member.snapshot = {"now_utc": START, "farm": document.farm,
		"decorations": document.decorations, "nature": {"seed": -1, "rules_version": 1}}
	_expect(str(member.restore_state().reason) == "invalid_nature",
		"A nature document that fails validation is refused")
	member.free()
	_finish()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("WORLD_SNAPSHOT_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
