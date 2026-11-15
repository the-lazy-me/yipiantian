extends SceneTree
## M7-01 economy initial conditions: commodity set, opening cash, demo stock
## conversion, ownership and the idempotent ledger. Headless, isolated paths.

const Farm = preload("res://farm/farm_state.gd")
const Crops = preload("res://farm/crop_catalog.gd")
const Catalog = preload("res://farm/economy_catalog.gd")
const Economy = preload("res://farm/economy_state.gd")
const Kitchen = preload("res://farm/kitchen.gd")
const Companions = preload("res://farm/animal_companions.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const V27Importer = preload("res://farm/v27_importer.gd")

const START: float = 1800000000.0
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/economy-initial-%d" % Time.get_ticks_usec()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_catalog()
	_test_initial_state()
	_test_opening_grant()
	_test_demo_conversion()
	_test_invalid_conversion_sources()
	_test_conservation_and_pay()
	_test_retry_and_restart()
	_test_authority_and_local_replay()
	_test_snapshot_validation()
	for failure: String in failures:
		push_error(failure)
	print("ECONOMY_INITIAL_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _test_catalog() -> void:
	_expect(Catalog.CURRENCY == "COIN", "The catalog names the existing COIN currency")
	_expect(Catalog.CURRENCY == Catalog.CURRENCY.to_upper(), "The currency token is uppercase like the package field")
	var ids: Array[String] = Catalog.goods_ids()
	_expect(ids.size() == 6, "The first market carries six goods, not a growing catalogue")
	_expect(Catalog.is_good("luffa") == false,
		"The sole trellis crop stays out of the first ground-bed price surface")
	for good_id: String in ids:
		var good: Dictionary = Catalog.definition(good_id)
		var crop: Dictionary = Crops.definition(good_id)
		_expect(not good.is_empty() and not crop.is_empty(), "Every good is a real crop: " + good_id)
		_expect(good.group in Crops.GROUPS and crop.group == good.group,
			"The good's group matches the crop catalog: " + good_id)
		_expect(good.source == Catalog.SOURCE_GROW and Crops.supports(good_id, false),
			"Every good has a current ground-bed planting source: " + good_id)
		_expect(Catalog.SINK_EAT in good.sinks and Catalog.SINK_SELL in good.sinks,
			"Every good declares eating and the M7-02 sale sink: " + good_id)
		var eat_route: bool = good_id in Companions.FOOD
		for recipe: String in Kitchen.RECIPES:
			if Kitchen.accepts(recipe, good_id):
				eat_route = true
		_expect(eat_route, "Every good has a current kitchen or animal eat route: " + good_id)
		_expect(Catalog.base_price(good_id) > 0 and Catalog.base_price(good_id) == int(good.base_price),
			"Every good has a positive integer reference price: " + good_id)
	_expect(Catalog.definition("not_a_good").is_empty(), "Unknown goods return no definition")
	var first: Dictionary = Catalog.definition("greens")
	first.name = "changed"
	_expect(Catalog.definition("greens").name == "青菜", "Catalog definitions are read-only views")
	_expect(not Catalog.is_good(""), "An empty id is not a good")
	_expect("economy" in V27Importer.KNOWN_FARM_KEYS,
		"The v27 importer knows the new optional farm key")


func _test_initial_state() -> void:
	var farm := Farm.new(START)
	var economy: Dictionary = farm.economy_snapshot()
	_expect(economy.currency == "COIN" and economy.sequence == 0 and economy.issued == 0,
		"A new farm starts with no issued cash and no economy commands")
	_expect(economy.accounts.is_empty() and economy.conversion.is_empty()
		and economy.command_results.is_empty(), "A new economy has no accounts, conversion or ledger entries")
	_expect(farm.economy_total_cash() == 0 and farm.economy_issued() == 0,
		"Empty accounts hold and have issued zero cash")
	_expect(farm.economy_goods(PLAYER_A).size() == Catalog.goods_ids().size()
		and farm.economy_goods(PLAYER_A).greens == 0, "Every player has a zero-default market view")
	var old: Dictionary = farm.snapshot()
	old.erase("economy")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(old), "A snapshot written before the economy still restores")
	_expect(restored.economy_snapshot() == Economy.initial_state(),
		"An old snapshot starts with the empty economy instead of free cash")
	_expect(restored.economy_total_cash() == 0, "Restoring an old snapshot issues nothing")


func _test_opening_grant() -> void:
	var farm := Farm.new(START)
	var opened: Dictionary = farm.economy_open_account("open-a", PLAYER_A, START)
	_expect(opened.ok and not opened.duplicate and opened.amount == Economy.OPENING_GRANT,
		"The authority issues one opening grant")
	_expect(farm.economy_cash(PLAYER_A) == Economy.OPENING_GRANT
		and farm.economy_issued() == Economy.OPENING_GRANT
		and farm.economy_total_cash() == Economy.OPENING_GRANT,
		"Cash, issued total and account total agree after the grant")
	_expect(farm.economy_snapshot().sequence == 1, "The grant advances the economy sequence once")
	var accepted: Dictionary = farm.snapshot()
	var replay: Dictionary = farm.economy_open_account("open-a", PLAYER_A, START)
	_expect(replay.ok and replay.duplicate and replay.amount == Economy.OPENING_GRANT,
		"A retry of the same grant id replays its result")
	_expect(farm.snapshot() == accepted, "A replayed grant changes no cash and no sequence")
	var second_id: Dictionary = farm.economy_open_account("open-a-2", PLAYER_A, START)
	_expect(not second_id.ok and second_id.reason == "already_granted"
		and farm.snapshot() == accepted, "A second id cannot grant the same owner twice")
	var conflict: Dictionary = farm.economy_open_account("open-a", PLAYER_B, START)
	_expect(not conflict.ok and conflict.reason == "command_conflict"
		and farm.snapshot() == accepted, "Reusing a grant id for another owner is a conflict")
	_expect(not farm.economy_open_account("open-world", Economy.WORLD_OWNER, START).ok,
		"The public inventory owner does not receive a player grant")
	_expect(not farm.economy_open_account("", PLAYER_A, START).ok, "An empty command id is refused")
	_expect(not farm.economy_open_account("x".repeat(Economy.MAX_COMMAND_ID_LENGTH + 1), PLAYER_B, START).ok,
		"A command id above the length bound is refused")
	_expect(not farm.economy_open_account("open-bad", "bad id", START).ok, "A malformed owner is refused")
	_expect(not farm.economy_open_account("open-neg", PLAYER_B, -1.0).ok, "A negative grant time is refused")
	_expect(farm.economy_open_account("open-b", PLAYER_B, START).ok
		and farm.economy_issued() == Economy.OPENING_GRANT * 2,
		"A second player gets the same one-time grant, not a smaller copy")
	_expect(farm.economy_total_cash() == farm.economy_issued(),
		"With no sink yet, issued cash equals the sum of accounts")


func _test_demo_conversion() -> void:
	var farm: Farm = _fixture_farm()
	var bag_a_before: Dictionary = farm.bag(PLAYER_A)
	var inventory_before: Dictionary = farm.snapshot().inventory
	var converted: Dictionary = farm.economy_convert_demo("convert-1", START)
	_expect(converted.ok and not converted.duplicate and converted.amount == 4,
		"Demo conversion records four catalog baskets")
	var record: Dictionary = farm.economy_snapshot().conversion
	_expect(record.id == "convert-1" and record.goods_total == 4 and record.digest.length() == 64,
		"The conversion record carries its id, total and a SHA-256 digest")
	_expect(record.owners.has(PLAYER_A) and record.owners[PLAYER_A] == {"greens": 2},
		"Player A's two greens are recorded under A's ownership")
	_expect(record.owners.has(PLAYER_B) and record.owners[PLAYER_B] == {"radish": 1},
		"Player B's radish is recorded under B's ownership")
	_expect(record.owners.has(Economy.WORLD_OWNER)
		and record.owners[Economy.WORLD_OWNER] == {"radish": 1},
		"The public inventory is recorded as the world owner's stock")
	_expect(farm.bag(PLAYER_A) == bag_a_before and farm.snapshot().inventory == inventory_before,
		"Conversion audits existing stock without moving or copying goods")
	_expect(farm.bag(PLAYER_A).lettuce == 1,
		"A non-priced crop stays in the ordinary bag and is not an economy good")
	_expect(farm.economy_goods(PLAYER_A) == {
		"greens": 2, "spinach": 0, "radish": 0, "carrot": 0, "celery": 0, "garlic": 0,
	}, "The market view exposes only catalog goods")
	var account: Dictionary = farm.economy_account(PLAYER_A)
	_expect(account.cash == 0 and account.goods.greens == 2,
		"The account view joins the owner's cash and owned goods")
	_expect(farm.economy_cash(PLAYER_A) == 0 and farm.economy_issued() == 0,
		"Conversion issues no cash")

	var accepted: Dictionary = farm.snapshot()
	var replay: Dictionary = farm.economy_convert_demo("convert-1", START)
	_expect(replay.ok and replay.duplicate and replay.amount == 4,
		"A retry of the same conversion id replays the same total")
	_expect(farm.snapshot() == accepted, "A replayed conversion does not stack stock or sequence")
	var new_id: Dictionary = farm.economy_convert_demo("convert-2", START)
	_expect(not new_id.ok and new_id.reason == "already_converted"
		and farm.snapshot() == accepted, "A second conversion id is refused without changing state")

	var changed: Farm = _fixture_farm()
	changed.economy_convert_demo("convert-1", START)
	changed.mature_all_crops(START)
	changed.sow("field_01", "cell_01", "greens", START)
	changed.mature_all_crops(START)
	_expect(changed.harvest("field_01", "cell_01", START, PLAYER_A).ok,
		"The fixture grows one more catalog basket after conversion")
	var conflicted: Dictionary = changed.economy_convert_demo("convert-1", START)
	_expect(not conflicted.ok and conflicted.reason == "command_conflict",
		"The same id with a changed source is a conflict, not a second award")
	_expect(changed.economy_snapshot().conversion.goods_total == 4,
		"A conflicting conversion leaves the original total in place")


func _test_invalid_conversion_sources() -> void:
	var state: Dictionary = Economy.initial_state()
	var cases: Array[Dictionary] = [
		{"source": {"bad id": {"greens": 1}}, "reason": "invalid_owner", "label": "malformed owner"},
		{"source": {Economy.WORLD_OWNER: {"luffa": 1}}, "reason": "invalid_good", "label": "non-priced crop"},
		{"source": {Economy.WORLD_OWNER: {"not_a_crop": 1}}, "reason": "invalid_good", "label": "unknown good"},
		{"source": {Economy.WORLD_OWNER: {"greens": -1}}, "reason": "invalid_amount", "label": "negative stock"},
		{"source": {Economy.WORLD_OWNER: {"greens": 1.5}}, "reason": "invalid_amount", "label": "fractional stock"},
		{"source": {Economy.WORLD_OWNER: {"greens": "1"}}, "reason": "invalid_amount", "label": "text stock"},
		{"source": {Economy.WORLD_OWNER: []}, "reason": "invalid_goods", "label": "non-table goods"},
	]
	for entry: Dictionary in cases:
		var result: Dictionary = Economy.convert_demo(state, entry.source, "bad", START)
		_expect(not result.ok and result.reason == entry.reason,
			"Conversion refuses " + str(entry.label) + " with " + str(entry.reason))
		_expect(state.conversion.is_empty() and state.sequence == 0,
			"Refused conversion leaves the ledger untouched: " + str(entry.label))
	var empty: Dictionary = Economy.convert_demo(state, {}, "empty", START)
	_expect(empty.ok and empty.amount == 0, "An empty world may record an empty opening stock")
	var after: Dictionary = Economy.convert_demo(state, {Economy.WORLD_OWNER: {"greens": 1}}, "empty-2", START)
	_expect(not after.ok and after.reason == "already_converted",
		"Once recorded, conversion cannot be reopened by a later command")


func _test_conservation_and_pay() -> void:
	var farm := Farm.new(START)
	farm.economy_open_account("open-a", PLAYER_A, START)
	farm.economy_open_account("open-b", PLAYER_B, START)
	var issued_before: int = farm.economy_issued()
	var total_before: int = farm.economy_total_cash()
	_expect(total_before == Economy.OPENING_GRANT * 2 and issued_before == total_before,
		"Two accounts start from exactly the issued opening grants")
	var paid: Dictionary = farm.economy_pay("pay-1", PLAYER_A, PLAYER_B, 50, START)
	_expect(paid.ok and not paid.duplicate and paid.amount == 50, "A funded payment moves cash once")
	_expect(farm.economy_cash(PLAYER_A) == 70 and farm.economy_cash(PLAYER_B) == 170,
		"Buyer pays and seller receives the same amount")
	_expect(farm.economy_issued() == issued_before and farm.economy_total_cash() == total_before,
		"A payment conserves issued cash and total cash")
	var accepted: Dictionary = farm.snapshot()
	var replay: Dictionary = farm.economy_pay("pay-1", PLAYER_A, PLAYER_B, 50, START)
	_expect(replay.ok and replay.duplicate and farm.snapshot() == accepted,
		"A replayed payment pays nothing twice")
	_expect(not farm.economy_pay("pay-1", PLAYER_A, PLAYER_B, 51, START).ok
		and farm.snapshot() == accepted, "The same payment id with another amount is refused")
	_expect(not farm.economy_pay("pay-over", PLAYER_A, PLAYER_B, 1000, START).ok
		and farm.snapshot() == accepted, "A payment above the payer's balance is refused")
	_expect(not farm.economy_pay("pay-neg", PLAYER_A, PLAYER_B, -1, START).ok
		and farm.snapshot() == accepted, "A negative payment is refused")
	_expect(not farm.economy_pay("pay-zero", PLAYER_A, PLAYER_B, 0, START).ok
		and farm.snapshot() == accepted, "A zero payment is refused")
	_expect(not farm.economy_pay("pay-frac", PLAYER_A, PLAYER_B, 1.5, START).ok
		and farm.snapshot() == accepted, "A fractional payment is refused")
	_expect(not farm.economy_pay("pay-self", PLAYER_A, PLAYER_A, 1, START).ok
		and farm.snapshot() == accepted, "A payment to the same account is refused")
	_expect(not farm.economy_pay("pay-unknown", PLAYER_A, "player_00000000000000000000000000000003", 1, START).ok
		and farm.snapshot() == accepted, "A payment to an unopened account is refused")
	_expect(not farm.economy_pay("pay-invalid-id", PLAYER_A, PLAYER_B, 1, -1.0).ok,
		"A payment with an invalid time is refused")


func _test_retry_and_restart() -> void:
	var farm: Farm = _fixture_farm()
	var base: Dictionary = farm.snapshot()
	var first := Farm.new()
	_expect(first.restore_snapshot(base), "The economy fixture restores")
	_expect(first.economy_open_account("restart-open", PLAYER_A, START).ok, "The first authority opens an account")
	_expect(first.economy_convert_demo("restart-convert", START).ok, "The first authority records the opening stock")
	_expect(first.economy_open_account("restart-open-b", PLAYER_B, START).ok, "The first authority opens a second account")
	_expect(first.economy_pay("restart-pay", PLAYER_A, PLAYER_B, 20, START).ok, "The first authority pays")
	var store := FarmStore.new(test_root.path_join("store"))
	_expect(store.load_state().kind == "missing", "The isolated save directory is admitted")
	_expect(store.save(first.snapshot(), Decorations.new().snapshot()).ok, "The farm with economy saves")
	var loaded: Dictionary = store.load_state()
	_expect(loaded.ok, "The saved farm loads")
	var restored := Farm.new()
	_expect(restored.restore_snapshot(loaded.farm), "The loaded farm restores")
	_expect(restored.snapshot() == first.snapshot(), "Cash, conversion and ledger survive the disk round trip")
	var accepted: Dictionary = restored.snapshot()
	_expect(restored.economy_open_account("restart-open", PLAYER_A, START).duplicate
		and restored.snapshot() == accepted, "A restarted world replays the opening grant id")
	_expect(restored.economy_convert_demo("restart-convert", START).duplicate
		and restored.snapshot() == accepted, "A restarted world replays the conversion id")
	_expect(restored.economy_pay("restart-pay", PLAYER_A, PLAYER_B, 20, START).duplicate
		and restored.snapshot() == accepted, "A restarted world replays the payment id")

	# The bounded ledger may evict old ids. The opening grant and conversion
	# carry their own durable markers, so eviction still cannot pay or convert twice.
	var evicted: Dictionary = restored.snapshot()
	evicted.economy.command_results = {}
	var evicted_farm := Farm.new()
	_expect(evicted_farm.restore_snapshot(evicted), "A snapshot with an evicted ledger still restores")
	var cash_before: int = evicted_farm.economy_cash(PLAYER_A)
	_expect(not evicted_farm.economy_open_account("restart-open", PLAYER_A, START).ok
		and evicted_farm.economy_cash(PLAYER_A) == cash_before,
		"An evicted grant ledger entry cannot issue the opening grant again")
	var converted: Dictionary = evicted_farm.economy_convert_demo("restart-convert", START)
	_expect(converted.ok and converted.duplicate and converted.amount == 4,
		"An evicted conversion ledger entry replays from its durable record")
	_expect(evicted_farm.economy_snapshot().conversion.goods_total == 4,
		"Eviction does not reopen conversion")


func _test_authority_and_local_replay() -> void:
	var authority: Farm = _fixture_farm()
	var base: Dictionary = authority.snapshot()
	_expect(authority.economy_convert_demo("replay-convert", START).ok, "Authority records the stock")
	_expect(authority.economy_open_account("replay-a", PLAYER_A, START).ok, "Authority opens A")
	_expect(authority.economy_open_account("replay-b", PLAYER_B, START).ok, "Authority opens B")
	_expect(authority.economy_pay("replay-pay", PLAYER_A, PLAYER_B, 35, START).ok, "Authority pays B")

	var local := Farm.new()
	_expect(local.restore_snapshot(base), "The local replay starts from the same pre-command snapshot")
	_expect(local.economy_convert_demo("replay-convert", START).ok, "Local replay records the stock")
	_expect(local.economy_open_account("replay-a", PLAYER_A, START).ok, "Local replay opens A")
	_expect(local.economy_open_account("replay-b", PLAYER_B, START).ok, "Local replay opens B")
	_expect(local.economy_pay("replay-pay", PLAYER_A, PLAYER_B, 35, START).ok, "Local replay pays B")
	_expect(local.snapshot() == authority.snapshot(),
		"The same economy commands produce the same snapshot on authority and local copies")

	var twin_a := Farm.new()
	var twin_b := Farm.new()
	twin_a.restore_snapshot(base)
	twin_b.restore_snapshot(base)
	_expect(twin_a.economy_open_account("race-a", PLAYER_A, START).ok
		and twin_b.economy_open_account("race-a", PLAYER_A, START).ok,
		"Two candidates from one snapshot apply the same grant deterministically")
	_expect(twin_a.snapshot() == twin_b.snapshot(),
		"Same starting snapshot and command produce identical candidates")
	_expect(twin_a.economy_open_account("race-a", PLAYER_A, START).duplicate
		and twin_a.economy_cash(PLAYER_A) == Economy.OPENING_GRANT,
		"A retry after the candidate commits is a duplicate, not a second grant")


func _test_snapshot_validation() -> void:
	var farm: Farm = _fixture_farm()
	farm.economy_open_account("valid-a", PLAYER_A, START)
	farm.economy_convert_demo("valid-convert", START)
	var original: Dictionary = farm.snapshot()
	var json_value: Dictionary = JSON.parse_string(JSON.stringify(original))
	var restored := Farm.new()
	_expect(restored.restore_snapshot(json_value), "A JSON economy snapshot restores")
	_expect(restored.economy_cash(PLAYER_A) is int and restored.economy_cash(PLAYER_A) == Economy.OPENING_GRANT,
		"JSON numbers normalize back to integer cash")
	var corruptions: Array[Dictionary] = []
	var candidate: Dictionary = original.duplicate(true)
	candidate.economy.currency = "coin"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.sequence = -1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.issued = 0
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.accounts[PLAYER_A].cash = -1
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.accounts[PLAYER_A].cash = 1.5
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.accounts[PLAYER_A].granted = "yes"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.accounts["bad id"] = {"cash": 0, "granted": true}
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.extra = true
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.conversion.owners[PLAYER_A] = {"luffa": 1}
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.conversion.goods_total = 99
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.conversion.digest = "not-a-digest"
	corruptions.append(candidate)
	candidate = original.duplicate(true)
	candidate.economy.command_results["valid-a"].result.amount = "120"
	corruptions.append(candidate)
	for broken: Dictionary in corruptions:
		_expect(not farm.restore_snapshot(broken) and farm.snapshot() == original,
			"Malformed economy state is rejected without changing the live farm")


func _fixture_farm() -> Farm:
	# A named harvest lands in bags; an anonymous harvest stays public; lettuce
	# is a real crop that the first market does not price.
	var farm := Farm.new(START)
	farm.mature_all_crops(START)
	farm.harvest("field_03", "cell_06", START, PLAYER_A)
	farm.harvest("field_04", "cell_06", START, PLAYER_A)
	farm.harvest("field_05", "cell_06", START, PLAYER_B)
	farm.harvest("field_06", "cell_06", START)
	farm.sow("field_01", "cell_01", "lettuce", START)
	farm.mature_all_crops(START)
	farm.harvest("field_01", "cell_01", START, PLAYER_A)
	return farm


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
