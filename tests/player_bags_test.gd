extends SceneTree
## ADR-005 player bags and gifting, authority side.
##
## A named harvest lands in that player's bag; anonymous play still uses the
## shared inventory. Gifts move baskets atomically through the existing command
## ledger, survive a disk round trip, and never reach an anonymous member.

const Farm = preload("res://farm/farm_state.gd")
const Crops = preload("res://farm/crop_catalog.gd")
const Command = preload("res://farm/farm_command.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")

const START: float = 1800000000.0
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join("../.local/verification/player-bags-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_harvest_attribution()
	_test_bags_are_independent()
	_test_gift_transfers()
	_test_gift_rejections_are_atomic()
	_test_bag_limits()
	_test_command_idempotency()
	_test_persistence()
	_test_summary_and_snapshot()
	_test_world_host_permissions()
	for failure: String in failures:
		push_error(failure)
	print("PLAYER_BAGS_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_harvest_attribution() -> void:
	var farm := Farm.new(START)
	var common_before: int = int(farm.snapshot().inventory.greens)
	var result: Dictionary = farm.harvest("field_03", "cell_06", START, PLAYER_A)
	_expect(result.ok and result.reward_crop_id == "greens" and result.reward_amount == 1,
		"A named harvest still reports one basket")
	_expect(int(farm.bag(PLAYER_A).greens) == 1, "The named actor receives the basket in their bag")
	_expect(farm.bag(PLAYER_A).size() == Crops.crop_ids().size(), "A bag lists every crop with a zero default")
	_expect(int(farm.snapshot().inventory.greens) == common_before and common_before == 0,
		"A named harvest leaves the shared inventory untouched")
	_expect(int(farm.snapshot().harvested.greens) == 1, "The world harvest count still advances")
	_expect(farm.snapshot().bags.has(PLAYER_A), "The snapshot carries the bag table")

	var anonymous := Farm.new(START)
	var plain: Dictionary = anonymous.harvest("field_03", "cell_06", START)
	_expect(plain.ok and int(anonymous.snapshot().inventory.greens) == 1,
		"An anonymous harvest keeps using the shared inventory")
	_expect(int(anonymous.bag(PLAYER_A).greens) == 0 and anonymous.snapshot().bags.is_empty(),
		"An anonymous harvest creates no bag")
	_expect(int(anonymous.snapshot().harvested.greens) == 1,
		"Anonymous harvesting keeps the existing rules")


func _test_bags_are_independent() -> void:
	var farm := Farm.new(START)
	farm.mature_all_crops(START)
	_expect(farm.harvest("field_03", "cell_06", START, PLAYER_A).ok, "Player A harvests greens")
	_expect(farm.harvest("field_04", "cell_06", START, PLAYER_B).ok, "Player B harvests greens")
	_expect(farm.harvest("field_05", "cell_06", START, PLAYER_A).ok, "Player A harvests a radish")
	_expect(int(farm.bag(PLAYER_A).greens) == 1 and int(farm.bag(PLAYER_A).radish) == 1,
		"Player A holds only their own baskets")
	_expect(int(farm.bag(PLAYER_B).greens) == 1 and int(farm.bag(PLAYER_B).radish) == 0,
		"Player B's bag is independent")
	_expect(int(farm.snapshot().inventory.greens) == 0 and int(farm.snapshot().inventory.radish) == 0,
		"Neither player's harvest leaks into the shared inventory")


func _test_gift_transfers() -> void:
	var farm := Farm.new(START)
	farm.mature_all_crops(START)
	farm.harvest("field_03", "cell_06", START, PLAYER_A)
	farm.harvest("field_04", "cell_06", START, PLAYER_A)
	_expect(int(farm.bag(PLAYER_A).greens) == 2, "Gift fixture gives the sender two baskets")
	var harvested_before: int = int(farm.snapshot().harvested.greens)
	var result: Dictionary = farm.gift(PLAYER_A, PLAYER_B, "greens", 1)
	_expect(result.ok and str(result.get("reason", "")) == "", "A funded gift succeeds")
	_expect(int(farm.bag(PLAYER_A).greens) == 1, "The sender pays exactly the gifted amount")
	_expect(int(farm.bag(PLAYER_B).greens) == 1, "The recipient receives exactly the gifted amount")
	_expect(int(farm.bag(PLAYER_A).greens) + int(farm.bag(PLAYER_B).greens) == 2,
		"A gift conserves the total number of baskets")
	_expect(int(farm.snapshot().harvested.greens) == harvested_before,
		"A gift does not change the world harvest count")
	_expect(int(farm.snapshot().inventory.greens) == 0, "A gift does not touch the shared inventory")


func _test_gift_rejections_are_atomic() -> void:
	var farm := Farm.new(START)
	farm.mature_all_crops(START)
	farm.harvest("field_03", "cell_06", START, PLAYER_A)
	var before: Dictionary = farm.snapshot()
	var cases: Array[Dictionary] = [
		{"to": PLAYER_A, "crop": "greens", "amount": 1, "reason": "invalid_player", "label": "self gift"},
		{"to": "", "crop": "greens", "amount": 1, "reason": "invalid_player", "label": "empty recipient"},
		{"to": "bad id", "crop": "greens", "amount": 1, "reason": "invalid_player", "label": "malformed recipient"},
		{"to": PLAYER_B, "crop": "unknown_crop", "amount": 1, "reason": "invalid_crop", "label": "unknown crop"},
		{"to": PLAYER_B, "crop": "greens", "amount": 0, "reason": "invalid_amount", "label": "zero amount"},
		{"to": PLAYER_B, "crop": "greens", "amount": -1, "reason": "invalid_amount", "label": "negative amount"},
		{"to": PLAYER_B, "crop": "greens", "amount": Farm.MAX_GIFT + 1, "reason": "invalid_amount", "label": "amount above the cap"},
		{"to": PLAYER_B, "crop": "greens", "amount": 1.5, "reason": "invalid_amount", "label": "fractional amount"},
		{"to": PLAYER_B, "crop": "greens", "amount": "1", "reason": "invalid_amount", "label": "amount as text"},
		{"to": PLAYER_B, "crop": "greens", "amount": 2, "reason": "insufficient", "label": "balance too low"},
	]
	for entry: Dictionary in cases:
		var rejected: Dictionary = farm.gift(PLAYER_A, str(entry.to), str(entry.crop), entry.amount)
		_expect(not rejected.ok and str(rejected.reason) == str(entry.reason),
			"Gift refuses " + str(entry.label) + " with " + str(entry.reason))
		_expect(farm.snapshot() == before, "Refused gift leaves state unchanged: " + str(entry.label))
	var bad_sender: Dictionary = farm.gift("bad id", PLAYER_B, "greens", 1)
	_expect(not bad_sender.ok and bad_sender.reason == "invalid_player" and farm.snapshot() == before,
		"An invalid sender is refused atomically")
	var empty_sender: Dictionary = farm.gift("", PLAYER_B, "greens", 1)
	_expect(not empty_sender.ok and empty_sender.reason == "invalid_player" and farm.snapshot() == before,
		"An empty sender is refused atomically")


func _test_bag_limits() -> void:
	var farm := Farm.new(START)
	var data: Dictionary = farm.snapshot()
	data.bags = {PLAYER_A: {"greens": Farm.MAX_HARVEST_COUNT}}
	_expect(farm.restore_snapshot(data), "A bag at the exact count bound is valid")
	var before: Dictionary = farm.snapshot()
	var overflow: Dictionary = farm.harvest("field_03", "cell_06", START, PLAYER_A)
	_expect(not overflow.ok and overflow.reason == "harvest_limit",
		"A full bag refuses the harvest instead of truncating the reward")
	_expect(farm.snapshot() == before, "A refused bag harvest leaves the mature crop in place")

	var receiver_full := Farm.new(START)
	var receiver_data: Dictionary = receiver_full.snapshot()
	receiver_data.bags = {
		PLAYER_A: {"greens": 1},
		PLAYER_B: {"greens": Farm.MAX_HARVEST_COUNT},
	}
	_expect(receiver_full.restore_snapshot(receiver_data), "A full recipient bag restores")
	var gift_before: Dictionary = receiver_full.snapshot()
	var blocked: Dictionary = receiver_full.gift(PLAYER_A, PLAYER_B, "greens", 1)
	_expect(not blocked.ok and blocked.reason == "inventory_limit",
		"A gift into a full bag is refused")
	_expect(receiver_full.snapshot() == gift_before,
		"A refused overflow gift does not debit the sender")


func _test_command_idempotency() -> void:
	var farm := Farm.new(START)
	farm.mature_all_crops(START)
	farm.harvest("field_03", "cell_06", START, PLAYER_A)
	var commands := Command.new()
	var gift: Dictionary = Command.make_gift("gift-1", PLAYER_B, "greens", 1, START)
	_expect(Command.valid(gift), "A gift command has the accepted shape")
	var first: Dictionary = commands.execute(farm, gift, PLAYER_A)
	_expect(first.ok and not first.duplicate, "A gift command executes once")
	farm.accept(first.candidate)
	_expect(int(farm.bag(PLAYER_A).greens) == 0 and int(farm.bag(PLAYER_B).greens) == 1,
		"The command path transfers exactly once")
	var accepted: Dictionary = farm.snapshot()
	var replay: Dictionary = commands.execute(farm, gift, PLAYER_A)
	_expect(replay.ok and replay.duplicate and not replay.has("candidate"),
		"A replayed gift id is a duplicate with no candidate")
	_expect(farm.snapshot() == accepted, "A replayed gift does not transfer again")
	_expect(commands.execute(farm, gift, PLAYER_B).reason == "command_conflict",
		"Another sender cannot replay the same command id as their own")
	var conflicting: Dictionary = Command.make_gift("gift-1", PLAYER_B, "greens", 2, START)
	var conflict: Dictionary = commands.execute(farm, conflicting, PLAYER_A)
	_expect(not conflict.ok and conflict.reason == "command_conflict" and conflict.duplicate,
		"Reusing a gift id for a different payload is a command conflict")
	_expect(farm.snapshot() == accepted, "The conflicting payload changes nothing")

	var restored := Farm.new()
	_expect(restored.restore_snapshot(farm.snapshot()), "The committed gift ledger restores")
	var after_restore: Dictionary = restored.snapshot()
	var replayed_after_restart: Dictionary = commands.execute(restored, gift, PLAYER_A)
	_expect(replayed_after_restart.duplicate and replayed_after_restart.ok,
		"A restarted world replays the gift id from the ledger")
	_expect(restored.snapshot() == after_restore, "The replayed gift after restart transfers nothing")

	var with_from: Dictionary = Command.make_gift("gift-from", PLAYER_B, "greens", 1, START)
	with_from["from"] = PLAYER_A
	_expect(not Command.valid(with_from), "A gift command may not carry its own sender")
	var with_field: Dictionary = Command.make_gift("gift-field", PLAYER_B, "greens", 1, START)
	with_field["field_id"] = "field_01"
	_expect(not Command.valid(with_field), "A gift command rejects field keys")
	_expect(not Command.valid(Command.make_gift("", PLAYER_B, "greens", 1, START)),
		"An empty gift id is invalid")
	_expect(not Command.valid(Command.make_gift("gift-x", "", "greens", 1, START)),
		"An empty recipient is invalid")
	_expect(not Command.valid(Command.make_gift("gift-x", PLAYER_B, "", 1, START)),
		"An empty crop is invalid")
	_expect(Command.valid(Command.make_gift("gift-max", PLAYER_B, "greens", Farm.MAX_GIFT, START)),
		"The maximum gift amount is accepted")
	_expect(not Command.valid({"id": "h1", "kind": "harvest", "field_id": "field_01",
		"cell_id": "cell_01", "at_utc": START, "extra": true}),
		"Existing command shapes keep their exact key count")


func _test_persistence() -> void:
	var farm := Farm.new(START)
	farm.mature_all_crops(START)
	farm.harvest("field_03", "cell_06", START, PLAYER_A)
	farm.harvest("field_04", "cell_06", START, PLAYER_B)
	var store := FarmStore.new(test_root.path_join("store"))
	_expect(store.load_state().kind == "missing", "A fresh save directory is admitted")
	_expect(store.save(farm.snapshot(), Decorations.new().snapshot()).ok, "A farm with bags saves")
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok, "The saved farm loads")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(loaded.farm), "The loaded farm restores")
	_expect(int(restored.bag(PLAYER_A).greens) == 1 and int(restored.bag(PLAYER_B).greens) == 1,
		"Bags survive the disk round trip")
	_expect(restored.snapshot().bags[PLAYER_A].greens is int,
		"JSON numbers are normalized back to integers on restore")

	var via_json: Variant = JSON.parse_string(JSON.stringify(farm.snapshot()))
	_expect(via_json is Dictionary and restored.restore_snapshot(via_json), "A JSON snapshot restores")
	_expect(int(restored.bag(PLAYER_A).greens) == 1, "JSON round trip keeps bag counts exact")

	var old: Dictionary = farm.snapshot()
	old.erase("bags")
	var migrated := Farm.new()
	_expect(migrated.restore_snapshot(old), "A snapshot without bags still restores")
	_expect(migrated.snapshot().bags == {}, "A missing bag table restores as empty")
	_expect(int(migrated.bag(PLAYER_A).greens) == 0, "An old snapshot gives every player zero")

	var valid: Dictionary = farm.snapshot()
	var corruptions: Array = [
		[],
		{"bad id": {}},
		{"": {}},
		{PLAYER_A: []},
		{PLAYER_A: {"unknown_crop": 1}},
		{PLAYER_A: {"greens": -1}},
		{PLAYER_A: {"greens": 1.5}},
		{PLAYER_A: {"greens": "1"}},
		{PLAYER_A: {"greens": Farm.MAX_HARVEST_COUNT + 1}},
	]
	for broken: Variant in corruptions:
		var candidate: Dictionary = valid.duplicate(true)
		candidate.bags = broken
		_expect(not farm.restore_snapshot(candidate), "Malformed bags are rejected: " + str(broken))
		_expect(farm.snapshot() == valid, "A rejected bag table preserves the live state")
	var empty_bags: Dictionary = valid.duplicate(true)
	empty_bags.bags = {}
	_expect(farm.restore_snapshot(empty_bags), "An explicit empty bag table is valid")


func _test_summary_and_snapshot() -> void:
	var world := HeadlessWorld.new()
	_expect(world.open(test_root.path_join("world-summary"), START).ok, "A fresh headless world opens")
	_expect(world.execute(Command.make("sum-harvest", "field_03", "cell_06", START), PLAYER_A).ok,
		"A member harvest commits through the world")
	var summary: Dictionary = world.summary()
	_expect(summary.has("bags") and summary.bags.has(PLAYER_A) and int(summary.bags[PLAYER_A].greens) == 1,
		"The world summary carries the bag table")
	_expect(int(summary.inventory.greens) == 0, "The world summary inventory stays public-only")
	var document: Dictionary = world.state_snapshot()
	_expect(document.farm.has("bags") and int(document.farm.bags[PLAYER_A].greens) == 1,
		"The restorable snapshot carries the bags")

	var anonymous := HeadlessWorld.new()
	_expect(anonymous.open(test_root.path_join("world-anonymous"), START).ok,
		"A second headless world opens")
	_expect(anonymous.execute(Command.make("anon-harvest", "field_03", "cell_06", START)).ok,
		"An anonymous world command harvests into the shared inventory")
	_expect(int(anonymous.summary().inventory.greens) == 1 and anonymous.summary().bags.is_empty(),
		"An anonymous world command creates no bag")


func _test_world_host_permissions() -> void:
	var host := WorldHost.new()
	# The multiplayer singleton is only reachable from a node inside the tree.
	root.add_child(host)
	var opened: Dictionary = host.configure(test_root.path_join("world-host"), START, "world-bags")
	_expect(opened.ok, "A world host opens for the permission checks")
	if not opened.ok:
		host.free()
		return
	_expect(host.world.execute(Command.make("host-seed", "field_03", "cell_06", START), PLAYER_A).ok,
		"The fixture gives player A a basket")
	# A visitor role normally cannot harvest; gifting must still be allowed.
	host._members[10] = WorldInvite.VISITOR
	host._players[10] = {"id": PLAYER_A, "name": "阿青"}
	var gift: Dictionary = Command.make_gift("host-gift", PLAYER_B, "greens", 1, START)
	var reply: Dictionary = host.execute_for_member(10, gift)
	_expect(reply.ok, "A named visitor may gift despite the field permissions")
	_expect(reply.has("bags") and int(reply.bags.greens) == 0,
		"The gift reply carries the sender's own new balance")
	_expect(int(host.world.farm.bag(PLAYER_B).greens) == 1, "The authority credits the recipient")
	var forbidden: Dictionary = host.execute_for_member(10,
		Command.make("host-harvest", "field_04", "cell_06", START))
	_expect(not forbidden.ok and forbidden.reason == "forbidden",
		"A visitor is still refused land work")
	# An anonymous member owns no bag and cannot gift.
	host._members[11] = WorldInvite.VISITOR
	var anonymous: Dictionary = host.execute_for_member(11,
		Command.make_gift("host-anon", PLAYER_B, "greens", 1, START))
	_expect(not anonymous.ok and anonymous.reason == "no_player",
		"An anonymous member is refused with no_player")
	_expect(int(host.world.farm.bag(PLAYER_B).greens) == 1,
		"The anonymous refusal transfers nothing")
	host.free()


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
