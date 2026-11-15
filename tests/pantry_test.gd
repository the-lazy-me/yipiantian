extends SceneTree
## Pantry ownership: one player pocket feeds kitchen, animals, baskets and the
## local market. `pantry_owner` is view context only; snapshots and saved farm
## documents keep their existing shape.

const Farm = preload("res://farm/farm_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const DecorationState = preload("res://farm/decoration_state.gd")

const START: float = 1800000000.0
const PLAYER: String = "player_00000000000000000000000000000001"

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/pantry-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_harvest_attribution()
	_test_fallback()
	_test_kitchen()
	_test_animals()
	_test_basket_and_gift()
	_test_failures_are_atomic()
	_test_copy_and_accept()
	_test_json_round_trip()
	_test_store_round_trip()
	for failure: String in failures:
		push_error(failure)
	print("PANTRY_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


## A pocket-aware state whose shared inventory holds `shared_greens`. Calling
## `pantry()` once canonicalizes the bag's crop table, so later snapshot
## comparisons contain no lazy-write difference.
func _named(shared_greens: int = 0) -> Farm:
	var farm := Farm.new(START)
	var data: Dictionary = farm.snapshot()
	data.inventory.greens = shared_greens
	_expect(farm.restore_snapshot(data), "Fixture restores a valid farm")
	farm.pantry_owner = PLAYER
	farm.pantry()
	return farm


func _test_harvest_attribution() -> void:
	var shared := Farm.new(START)
	shared.pantry_owner = PLAYER
	var shared_before: int = int(shared.snapshot().inventory.greens)
	_expect(shared.harvest("field_03", "cell_06", START, PLAYER).ok,
		"A named harvest succeeds")
	_expect(int(shared.bag(PLAYER).greens) == 1, "The named harvest enters the actor's bag")
	_expect(int(shared.snapshot().inventory.greens) == shared_before,
		"A named harvest leaves the shared inventory untouched")

	var anonymous := Farm.new(START)
	anonymous.pantry_owner = ""
	var anonymous_before: int = int(anonymous.snapshot().inventory.greens)
	_expect(anonymous.harvest("field_03", "cell_06", START).ok,
		"An anonymous harvest succeeds")
	_expect(int(anonymous.snapshot().inventory.greens) == anonymous_before + 1,
		"An anonymous harvest keeps using the shared inventory")
	_expect(anonymous.snapshot().bags.is_empty(),
		"An anonymous harvest creates no player bag")


func _test_fallback() -> void:
	var farm := Farm.new(START)
	var shared: Dictionary = farm.snapshot().inventory
	_expect(farm.pantry() == shared, "An empty owner falls back to the shared inventory")
	farm.pantry_owner = "not a valid id!"
	_expect(farm.pantry() == shared, "An invalid owner falls back to the shared inventory")
	farm.pantry_owner = PLAYER
	_expect(farm.pantry() == farm.snapshot().bags[PLAYER],
		"A valid owner returns that player's bag")


func _test_kitchen() -> void:
	var farm := _named(7)
	farm.pantry().greens = 2
	var shared_before: int = int(farm.snapshot().inventory.greens)
	var started: Dictionary = farm.kitchen_action(
		"start", {"recipe": "leaf_stir", "crop": "greens"}, 0, START)
	_expect(started.ok, "Kitchen start reads the pantry")
	_expect(int(farm.snapshot().bags[PLAYER].greens) == 1,
		"Kitchen consumes exactly one basket from the pantry")
	_expect(int(farm.snapshot().inventory.greens) == shared_before,
		"Kitchen does not touch the shared inventory")
	_expect(farm.snapshot().kitchen.jobs.stove.recipe == "leaf_stir",
		"The kitchen job is recorded on the same state")


func _test_animals() -> void:
	var farm := _named(7)
	farm.pantry().greens = 1
	var shared_before: int = int(farm.snapshot().inventory.greens)
	var bird: String = Farm.Companions.IDS[0]
	var fed: Dictionary = farm.animal_action(bird, "feed", "greens", 0)
	_expect(fed.ok, "Animal feeding reads the pantry")
	_expect(int(farm.snapshot().bags[PLAYER].greens) == 0,
		"Feeding consumes the basket from the pantry")
	_expect(int(farm.snapshot().inventory.greens) == shared_before,
		"Feeding does not touch the shared inventory")
	_expect(int(farm.snapshot().animals[bird].shared) == 1,
		"The animal records the shared meal")


func _test_basket_and_gift() -> void:
	var farm := _named(4)
	farm.pantry().greens = 2
	var shared_greens: int = int(farm.snapshot().inventory.greens)
	var shared_radish: int = int(farm.snapshot().inventory.radish)
	_expect(farm.share_basket("willow", 0, {"greens": 1}).ok,
		"A basket can be packed from the pantry")
	_expect(int(farm.snapshot().bags[PLAYER].greens) == 1,
		"The basket deducts from the pantry")
	_expect(int(farm.snapshot().inventory.greens) == shared_greens,
		"The basket leaves the shared inventory untouched")
	_expect(bool(farm.snapshot().neighbors.willow.pending),
		"The visit waits for its return gift")
	_expect(farm.claim_gift("willow", 0, "radish").ok,
		"A return gift can be claimed")
	_expect(int(farm.snapshot().bags[PLAYER].radish) == 1,
		"The claim gift enters the pantry")
	_expect(int(farm.snapshot().inventory.radish) == shared_radish,
		"The claim gift leaves the shared inventory untouched")


func _test_failures_are_atomic() -> void:
	var farm := _named(5)
	farm.pantry().greens = 0
	var stable: Dictionary = farm.snapshot()
	var kitchen: Dictionary = farm.kitchen_action(
		"start", {"recipe": "leaf_stir", "crop": "greens"}, 0, START)
	_expect(not kitchen.ok and kitchen.reason == "insufficient_food",
		"Kitchen refuses an empty pantry")
	_expect(farm.snapshot() == stable, "A refused kitchen start changes nothing")

	var bird: String = Farm.Companions.IDS[0]
	var fed: Dictionary = farm.animal_action(bird, "feed", "greens", 0)
	_expect(not fed.ok and fed.reason == "insufficient_food",
		"Animal feeding refuses an empty pantry")
	_expect(farm.snapshot() == stable, "A refused feeding changes nothing")

	var basket: Dictionary = farm.share_basket("willow", 0, {"greens": 1})
	_expect(not basket.ok and basket.reason == "insufficient_food",
		"A basket cannot be packed from an empty pantry")
	_expect(farm.snapshot() == stable, "A refused basket changes nothing")


func _test_copy_and_accept() -> void:
	var farm := _named(0)
	farm.pantry().greens = 1
	var candidate: RefCounted = farm.copy()
	_expect(candidate.pantry_owner == PLAYER, "copy() keeps the pantry owner")
	_expect(int(candidate.pantry().greens) == 1, "copy() starts from the same pantry")
	candidate.pantry().greens = 5
	_expect(int(farm.pantry().greens) == 1, "A candidate pantry edit cannot leak into the source")
	candidate.pantry_owner = "another_player"
	farm.accept(candidate)
	_expect(farm.pantry_owner == PLAYER, "accept() keeps the live state's pantry owner")
	_expect(int(farm.pantry().greens) == 5, "accept() commits the candidate's pantry data")
	var snapshot: Dictionary = farm.snapshot()
	_expect(not snapshot.has("pantry_owner") and not snapshot.has("pantry"),
		"pantry metadata never enters the snapshot")
	_expect(not JSON.stringify(snapshot).contains("pantry_owner"),
		"pantry metadata never enters the JSON document")


func _test_json_round_trip() -> void:
	var farm := Farm.new(START)
	farm.pantry_owner = PLAYER
	_expect(farm.harvest("field_03", "cell_06", START, PLAYER).ok, "Round-trip fixture harvests")
	var parsed: Variant = JSON.parse_string(JSON.stringify(farm.snapshot()))
	_expect(parsed is Dictionary, "The snapshot serializes as JSON")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(parsed), "FarmState.restore_snapshot accepts the JSON form")
	_expect(restored.pantry_owner.is_empty(), "A restored state has no persisted pantry owner")
	restored.pantry_owner = PLAYER
	_expect(int(restored.pantry().greens) == 1, "The pantry keeps working after restoration")


func _test_store_round_trip() -> void:
	var directory: String = test_root.path_join("farm")
	var store := FarmStore.new(directory)
	_expect(store.load_state().ok, "An isolated farm store opens")
	var farm := _named(0)
	farm.pantry().greens = 2
	_expect(store.save_state(farm, DecorationState.new()).ok,
		"A pantry-backed farm saves through the normal document path")
	var saved: String = FileAccess.get_file_as_string(directory.path_join("farm.json"))
	_expect(not saved.contains("pantry_owner") and not saved.contains("\"pantry\""),
		"The saved farm document carries no pantry metadata")
	var reopened_store := FarmStore.new(directory)
	var loaded: Dictionary = reopened_store.load_state()
	_expect(loaded.ok and loaded.kind == "loaded", "The saved farm reloads")
	var reopened := Farm.new()
	_expect(reopened.restore_snapshot(loaded.farm), "The reloaded document restores")
	reopened.pantry_owner = PLAYER
	_expect(int(reopened.pantry().greens) == 2, "The reloaded pantry still feeds the player")


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
