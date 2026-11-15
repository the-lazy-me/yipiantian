extends SceneTree
## Authority economy clock. Order expiry, matching against resting orders,
## arrivals and loan due dates are deadlines of their own; a long-lived world
## must settle them even when nobody acts and no crop stage is due. The sweep
## runs on a candidate and only becomes live after the save succeeds.
##
## Headless and isolated: no scene, no network, one temporary world directory.

const World = preload("res://world/headless_world.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const Market = preload("res://farm/market_state.gd")
const WorldHost = preload("res://world/world_host.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const Catalog = preload("res://farm/economy_catalog.gd")

const START: float = 1800000000.0
const HOUR: float = 3600.0
const DAY: float = 86400.0
const PLAYER_A: String = "player_economy_clock_0001"
const PLAYER_B: String = "player_economy_clock_0002"

var checks: int = 0
var failures: Array[String] = []
var test_root: String = ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	test_root = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/world-economy-clock-%d" % OS.get_process_id()).simplify_path()
	DirAccess.make_dir_recursive_absolute(test_root)
	_test_sweep_without_growth_event()
	_test_sweep_is_idempotent()
	_test_sweep_survives_invalid_calls()
	await _test_authority_clock_advances_without_growth()
	await _test_limited_invite_expires_in_idle_world()
	for failure: String in failures:
		push_error(failure)
	print("WORLD_ECONOMY_CLOCK_TEST checks=%d failures=%d root=%s" % [
		checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


## The whole point: an expired order and an overdue loan settle on the clock,
## with no command, no growth and no weather event in between.
func _test_sweep_without_growth_event() -> void:
	var directory: String = test_root.path_join("clock")
	var world := World.new()
	var opened: Dictionary = world.open(directory, START)
	_expect(bool(opened.ok), "The isolated world opens")
	if not bool(opened.ok):
		return
	var farm: Variant = world.farm
	_expect(bool(farm.economy_open_account("clock-open-a", PLAYER_A, START).ok),
		"A opens an account")
	_expect(bool(farm.economy_open_bank("clock-bank", START).ok), "The bank opens once")
	var borrowed: Dictionary = farm.economy_borrow_loan("clock-borrow", PLAYER_A, 100,
		7 * int(DAY), START)
	_expect(bool(borrowed.ok), "A borrows 100 COIN for seven days: "
		+ str(borrowed.get("reason", "")))
	var buy: Dictionary = farm.market_place_order("clock-buy", PLAYER_A, Market.SIDE_BUY,
		"greens", 5, 2, START + 10.0, START)
	_expect(bool(buy.ok), "A places a buy order that expires in ten seconds")
	var order_id: String = ""
	for row: Variant in farm.market_orders():
		if row is Dictionary and str(row.get("id", "")) == "clock-buy":
			order_id = str(row.id)
	var before_fields: Dictionary = farm.snapshot().fields.duplicate(true)
	var before_sequence: int = int(farm.event_sequence())
	var before_order: Dictionary = farm.market_order(order_id)
	_expect(not before_order.is_empty() and str(before_order.status) == Market.STATUS_OPEN,
		"The order starts open")

	var settled: Dictionary = world.settle_economy_now(START + 11.0)
	_expect(bool(settled.ok), "The clock sweep succeeds: " + str(settled.get("reason", "")))
	_expect(int(settled.get("counts", {}).get("expired", 0)) == 1,
		"The sweep expires exactly one order")
	var expired: Dictionary = farm.market_order(order_id)
	_expect(str(expired.get("status", "")) == Market.STATUS_EXPIRED,
		"The order is expired without any command")
	_expect(int(expired.get("reserved", -1)) == 0, "The expired order released its escrow")

	var later: Dictionary = world.settle_economy_now(START + 8.0 * DAY)
	_expect(bool(later.ok), "The later sweep succeeds: " + str(later.get("reason", "")))
	_expect(int(later.get("counts", {}).get("loans", 0)) == 1,
		"The sweep marks exactly one overdue loan")
	var contract: Dictionary = farm.economy_loan("clock-borrow")
	_expect(str(contract.get("status", "")) == "overdue", "The loan is overdue on time")
	_expect(int(contract.get("fee", -1)) == 5, "Overdue did not grow the fixed fee")

	_expect(farm.snapshot().fields == before_fields,
		"The economy clock does not touch crop growth")
	_expect(int(farm.event_sequence()) == before_sequence,
		"The economy clock is not a farm command")
	_expect(bool(farm.economy_reconcile().ok), "The economy still reconciles")
	var issued: int = int(farm.economy_issued())
	_expect(issued == int(farm.economy_total_cash()),
		"Expiry and overdue change no issued cash")

	# The sweep was persisted: a fresh authority on the same directory sees it.
	var reopened := World.new()
	var again: Dictionary = reopened.open(directory, START + 8.0 * DAY)
	_expect(bool(again.ok), "The swept world reopens from disk")
	if bool(again.ok):
		_expect(str(reopened.farm.market_order(order_id).get("status", ""))
			== Market.STATUS_EXPIRED, "The persisted copy holds the expired order")
		_expect(str(reopened.farm.economy_loan("clock-borrow").get("status", "")) == "overdue",
			"The persisted copy holds the overdue contract")


## A second call at the same instant changes nothing and does not move stamps.
func _test_sweep_is_idempotent() -> void:
	var directory: String = test_root.path_join("idempotent")
	var world := World.new()
	_expect(bool(world.open(directory, START).ok), "The idempotence world opens")
	if world.farm == null:
		return
	var farm: Variant = world.farm
	_expect(bool(farm.economy_open_account("idem-open", PLAYER_B, START).ok),
		"B opens an account")
	_expect(bool(farm.market_place_order("idem-buy", PLAYER_B, Market.SIDE_BUY, "greens",
		5, 1, START + 10.0, START).ok), "B places a short order")
	var first: Dictionary = world.settle_economy_now(START + 20.0)
	_expect(int(first.get("counts", {}).get("expired", 0)) == 1, "The first sweep expires it")
	var stamp: Variant = farm.market_order("idem-buy").get("closed_utc")
	var second: Dictionary = world.settle_economy_now(START + 20.0)
	_expect(bool(second.ok) and not bool(second.get("changed", false)),
		"A second sweep at the same instant reports no change")
	_expect(farm.market_order("idem-buy").get("closed_utc") == stamp,
		"The closed stamp did not move")


## Invalid times are refused before any candidate is built.
func _test_sweep_survives_invalid_calls() -> void:
	var world := World.new()
	var refused: Dictionary = world.settle_economy_now(START)
	_expect(not bool(refused.ok) and str(refused.get("reason", "")) == "not_open",
		"A closed authority refuses the sweep")
	var directory: String = test_root.path_join("invalid")
	_expect(bool(world.open(directory, START).ok), "The invalid-call world opens")
	for value: float in [NAN, INF, -1.0]:
		var result: Dictionary = world.settle_economy_now(value)
		_expect(not bool(result.ok) and str(result.get("reason", "")) == "invalid_time",
			"An invalid clock is refused: " + str(value))


## An empty world has no crop event to advance `now_utc`, yet invitation and
## social expiry must still pass. The authority clock is the start instant plus
## monotonic elapsed time; the growth clock deliberately stays put.
func _test_authority_clock_advances_without_growth() -> void:
	var world := World.new()
	var directory: String = test_root.path_join("authority-clock")
	_expect(bool(world.open(directory, START).ok), "The empty authority world opens")
	var growth_before: float = world.now_utc
	var authority_before: float = world.authority_now_utc()
	var future_command: Dictionary = world.execute(FarmCommand.make_sow(
		"clock-future", "field_01", "cell_01", "greens", START + 10000000.0))
	_expect(not future_command.ok
		and str(future_command.get("reason", "")) == "time_forwards",
		"A far-future command is refused instead of settling early")
	_expect(is_equal_approx(world.now_utc, growth_before),
		"A refused future command leaves the growth clock unchanged")
	# SceneTree timers are ticked with the engine's process delta, which a loaded
	# runner may let run faster than the monotonic ticks the authority reads.
	# Compare the authority clock with the real time that actually passed
	# instead of assuming a 2.2-second timer waited 2.2 wall seconds.
	var before_ms: int = Time.get_ticks_msec()
	await create_timer(2.2).timeout
	var elapsed: float = float(Time.get_ticks_msec() - before_ms) / 1000.0
	var authority_after: float = world.authority_now_utc()
	_expect(elapsed > 0.5, "The wait let real time pass")
	_expect(authority_after - authority_before >= elapsed - 0.05,
		"The authority clock keeps moving with no growth advance")
	_expect(authority_after < START + 1000.0,
		"A client timestamp cannot advance the authority clock")
	_expect(is_equal_approx(world.now_utc, growth_before),
		"The growth clock is not advanced by the authority clock")


## A time-limited invitation expires on the authority clock even in an empty
## world whose growth clock never moves. The expiry is the same check `_spend`
## runs at join time; only the clock source changed.
func _test_limited_invite_expires_in_idle_world() -> void:
	var host := WorldHost.new()
	host.name = "WorldSession"
	root.add_child(host)
	var directory: String = test_root.path_join("idle-invite")
	var opened: Dictionary = host.configure(directory, START, "world-idle")
	_expect(bool(opened.ok), "The idle authority world opens")
	if not bool(opened.ok):
		return
	var grant: Dictionary = WorldInvite.make("idle-invite", Crypto.new().generate_random_bytes(32),
		WorldInvite.MEMBER, "world-idle", host.clock_now() + 1.0, true)
	_expect(bool(host.add_grant(grant).ok), "A one-second invitation is registered")
	_expect(bool(WorldInvite.check_usable(grant, host.clock_now(), 0).ok),
		"The invitation is usable at join time")
	var growth_before: float = host.world.now_utc
	await create_timer(1.6).timeout
	_expect(is_equal_approx(host.world.now_utc, growth_before),
		"The growth clock did not advance while the world sat idle")
	_expect(WorldInvite.check_usable(grant, host.clock_now(), 0).reason == "invite_expired",
		"The invitation expires on the authority clock without a growth advance")
	host.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if condition:
		return
	failures.append(message)
