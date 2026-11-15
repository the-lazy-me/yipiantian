extends SceneTree
## M8-03 insurance rules over the M8-03a transport-loss evidence. Headless and
## isolated; the economy, bags and market rows are driven directly, so no
## scene, network, system clock or player save is touched.

const Farm = preload("res://farm/farm_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const Market = preload("res://farm/market_state.gd")
const Ledger = preload("res://farm/ledger_state.gd")
const Insurance = preload("res://farm/insurance_state.gd")
const Catalog = preload("res://farm/economy_catalog.gd")

const START: float = 1800000000.0
const HOUR: float = 3600.0
const ARRIVE: float = START + Market.DELIVERY_SECONDS
const HORIZON: float = START + 3600.0
const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_C: String = "player_00000000000000000000000000000003"
const FARM_TO_HARBOR: String = Market.LOCATION_FARM + ">" + Market.LOCATION_HARBOR
const HARBOR_TO_FARM: String = Market.LOCATION_HARBOR + ">" + Market.LOCATION_FARM
const CELLS_16: Array[String] = [
	"cell_01", "cell_02", "cell_03", "cell_04", "cell_05", "cell_06",
	"cell_07", "cell_08", "cell_09", "cell_10", "cell_11", "cell_12",
	"cell_13", "cell_14", "cell_15", "cell_16",
]
const CELLS_8: Array[String] = [
	"cell_01", "cell_02", "cell_03", "cell_04", "cell_05", "cell_06",
	"cell_07", "cell_08",
]
const CELLS_4: Array[String] = ["cell_01", "cell_02", "cell_03", "cell_04"]

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_quote()
	_test_underwrite_charge()
	_test_underwrite_errors()
	_test_retroactive_rejected()
	_test_claim_once_and_replay()
	_test_deductible_and_coverage_bounds()
	_test_expired_status_still_pays()
	_test_claim_mismatches()
	_test_claim_limits()
	_test_route_bound_as_document()
	_test_pending_and_settle()
	_test_settle_skips_unaffordable()
	_test_document_validation()
	_test_bounds()
	_test_persistence()
	for failure: String in failures:
		push_error(failure)
	print("INSURANCE_STATE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_quote() -> void:
	var greens: Dictionary = Insurance.terms("greens", 2)
	_expect(greens.ok and greens.unit_value == 6 and greens.insured_value == 12 \
		and greens.coverage == 9 and greens.deductible == 3 and greens.premium == 1,
		"Two greens quote value 12, coverage 12, a 2 COIN deductible and a 1 COIN premium")
	var celery: Dictionary = Insurance.terms("celery", 2)
	_expect(celery.unit_value == 20 and celery.insured_value == 40 \
		and celery.coverage == 32 and celery.deductible == 3 and celery.premium == 1,
		"Fixed terms round down and keep a one COIN premium floor")
	var bulk: Dictionary = Insurance.terms("greens", Insurance.MAX_QUANTITY)
	_expect(bulk.insured_value == 384 and bulk.coverage == 307 \
		and bulk.deductible == 3 and bulk.premium == 15,
		"The largest allowed policy is bounded and priced by the same fixed rates")
	_expect(Insurance.terms("greens", 1).premium == 1,
		"A tiny policy still charges the one COIN premium floor")
	for bad_quantity: Variant in [0, -1, 65, 1.5, "2", true]:
		_expect(Insurance.terms("greens", bad_quantity).is_empty(),
			"An invalid covered quantity has no terms")
	_expect(Insurance.terms("luffa", 2).is_empty(),
		"A good without a catalog reference price cannot be insured")
	_expect(Insurance.terms("not_a_good", 2).is_empty(),
		"An unknown good cannot be insured")

	var route: Array = Insurance.route_parts(FARM_TO_HARBOR)
	_expect(route == [Market.LOCATION_FARM, Market.LOCATION_HARBOR],
		"A valid route id splits back into its two locations")
	_expect(Insurance.route_parts("farm_market>farm_market").is_empty(),
		"A non-distinct route id has no parts")
	_expect(Insurance.valid_route_id(FARM_TO_HARBOR) \
		and not Insurance.valid_route_id(HARBOR_TO_FARM + ">farm_market"),
		"Only the two fixed distinct routes are valid ids")

	var quoted: Dictionary = Insurance.quote(FARM_TO_HARBOR, "greens", 2, START,
		START + HOUR, START)
	_expect(quoted.ok and quoted.route == FARM_TO_HARBOR and quoted.good == "greens" \
		and quoted.quantity_covered == 2 and quoted.premium == 1 \
		and quoted.coverage == 9 and quoted.deductible == 3 \
		and quoted.starts_utc == START and quoted.ends_utc == START + HOUR \
		and quoted.rule_version == Insurance.RULE_VERSION,
		"A valid quote returns the route, good, quantity and fixed terms")
	var later: Dictionary = Insurance.quote(FARM_TO_HARBOR, "greens", 2, START + HOUR,
		START + HOUR * 2.0, START + HOUR)
	_expect(later.ok and later.premium == quoted.premium and later.coverage == quoted.coverage,
		"The fixed premium does not grow with the quote time")
	for bad_route: String in ["farm_market", "farm_market>farm_market",
			"harbor_market>farm_market2", "farm_market>harbor_market>farm_market", ""]:
		_expect(not Insurance.quote(bad_route, "greens", 2, START, START + HOUR, START).ok,
			"An unknown or non-distinct route is refused: " + bad_route)
	_expect(Insurance.quote(FARM_TO_HARBOR, "luffa", 2, START, START + HOUR, START).reason
		== "invalid_good", "An unpriced good is refused by name")
	_expect(Insurance.quote(FARM_TO_HARBOR, "not_a_good", 2, START, START + HOUR,
		START).reason == "invalid_good", "An unknown good is refused by name")
	_expect(Insurance.quote(FARM_TO_HARBOR, "greens", 0, START, START + HOUR,
		START).reason == "invalid_quantity", "A zero quantity is refused by name")
	_expect(Insurance.quote(FARM_TO_HARBOR, "greens", 65, START, START + HOUR,
		START).reason == "invalid_quantity", "A quantity over the policy bound is refused")
	_expect(Insurance.quote(FARM_TO_HARBOR, "greens", 2, START - 1.0, START + HOUR,
		START).reason == "invalid_start", "A policy starting before now is refused")
	_expect(Insurance.quote(FARM_TO_HARBOR, "greens", 2, START, START + 3599.0,
		START).reason == "invalid_term", "A term under one hour is refused")
	_expect(Insurance.quote(FARM_TO_HARBOR, "greens", 2, START, START + 2592001.0,
		START).reason == "invalid_term", "A term over thirty days is refused")
	_expect(Insurance.quote(FARM_TO_HARBOR, "greens", 2, START, START + HOUR + 0.5,
		START).reason == "invalid_term", "A fractional-second term is refused")
	_expect(Insurance.quote(FARM_TO_HARBOR, "greens", 2, -1.0, START + HOUR,
		START).reason == "invalid_time", "A negative start time is refused")
	_expect(Insurance.quote(FARM_TO_HARBOR, "greens", 2, START,
		float(Insurance.MAX_SAFE_INTEGER) + 1.0, START).reason == "invalid_end",
		"An end time past the exact-JSON bound is refused")


func _test_underwrite_charge() -> void:
	var fixture: Dictionary = _fixture()
	var data: Dictionary = fixture.data
	var insurance: Dictionary = fixture.insurance
	var issued_before: int = Economy.issued(data.economy)
	var total_before: int = Economy.total_cash(data.economy)
	var result: Dictionary = Insurance.underwrite(data.economy, insurance, "policy-a",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, START + HOUR, START)
	_expect(result.ok and not result.duplicate and result.policy_id == "policy-a" \
		and result.premium == 1 and result.coverage == 9 and result.deductible == 3 \
		and result.status == Insurance.STATUS_ACTIVE,
		"Underwriting returns the quoted terms and an active policy")
	_expect(result.starts_utc == START and result.ends_utc == START + HOUR,
		"The policy keeps the quoted window")
	_expect(Economy.cash(data.economy, PLAYER_A) == 119,
		"The premium is deducted from the owner's cash")
	_expect(Economy.cash(data.economy, Insurance.WORLD_OWNER) == 1,
		"The premium is held by the @world insurance pool")
	_expect(Economy.issued(data.economy) == issued_before \
		and Economy.total_cash(data.economy) == total_before,
		"A premium is a transfer: issued and total cash do not change")
	var policy: Dictionary = Insurance.policy(insurance, "policy-a")
	_expect(policy.policy_id == "policy-a" and policy.owner == PLAYER_A \
		and policy.route == FARM_TO_HARBOR and policy.good == "greens" \
		and policy.quantity_covered == 2 and policy.status == Insurance.STATUS_ACTIVE \
		and str(policy.claim_id).is_empty(),
		"The policy row carries the bounded shape and no claim")
	_expect(policy.size() == Insurance.POLICY_KEYS.size(),
		"The policy row has exactly the documented keys")
	var entry: Dictionary = _event_entry(data.economy, "policy-a")
	_expect(entry.kind == Ledger.KIND_PAY and _balanced(entry),
		"The premium posts one balanced payment entry")
	_expect(_signed(entry, Ledger.owner_code(PLAYER_A)) == -1 \
		and _signed(entry, Ledger.owner_code(Insurance.WORLD_OWNER)) == 1,
		"The owner is credited the premium and @world debited")
	_expect(Economy.valid(data.economy) and Economy.reconcile(data.economy).ok,
		"The economy validates and reconciles after a premium")
	_expect(Insurance.valid(insurance), "The policy document validates after underwriting")

	var accepted_economy: Dictionary = data.economy.duplicate(true)
	var accepted_insurance: Dictionary = insurance.duplicate(true)
	var replay: Dictionary = Insurance.underwrite(data.economy, insurance, "policy-a",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, START + HOUR, START)
	_expect(replay.ok and replay.duplicate and replay.premium == 1,
		"Replaying an accepted policy returns the first result")
	_expect(data.economy == accepted_economy and insurance == accepted_insurance,
		"A policy replay charges no second premium")
	var conflict: Dictionary = Insurance.underwrite(data.economy, insurance, "policy-a",
		PLAYER_A, FARM_TO_HARBOR, "greens", 3, START, START + HOUR, START)
	_expect(not conflict.ok and conflict.reason == "command_conflict",
		"Reusing a policy id with different terms is a conflict")
	_expect(data.economy == accepted_economy and insurance == accepted_insurance,
		"A conflicting policy replay changes nothing")
	var second: Dictionary = Insurance.underwrite(data.economy, insurance, "policy-a2",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START,
		START + HOUR, START)
	_expect(not second.ok and second.reason == "policy_active",
		"One owner cannot hold two active policies at once")
	_expect(data.economy == accepted_economy,
		"A refused second policy charges no premium")

	var expired: Dictionary = Insurance.expire(insurance, START + HOUR)
	_expect(expired.ok and expired.count == 1 and expired.expired == ["policy-a"],
		"An ended policy is marked expired, not deleted")
	_expect(Insurance.valid(insurance), "The expired policy document still validates")
	var renewed: Dictionary = Insurance.underwrite(data.economy, insurance, "policy-a3",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START + HOUR, START + HOUR * 2.0,
		START + HOUR)
	_expect(renewed.ok and not renewed.duplicate and renewed.premium == 1,
		"A new policy is accepted after the previous window ended")
	_expect(Insurance.policy(insurance, "policy-a").status == Insurance.STATUS_EXPIRED \
		and Insurance.policy(insurance, "policy-a3").status == Insurance.STATUS_ACTIVE,
		"The older policy stays expired and the new one is active")
	_expect(Economy.cash(data.economy, PLAYER_A) == 118,
		"The renewal charges a second premium")
	_expect(Insurance.valid(insurance) and Economy.valid(data.economy),
		"The renewed document and economy validate")
	# Underwriting long after a window closed does not need a separate expiry
	# sweep: the refused-active check ignores the ended row and the accepted
	# payment transitions it in the same call.
	var automatic: Dictionary = Insurance.underwrite(data.economy, insurance, "policy-a4",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START + HOUR * 3.0,
		START + HOUR * 4.0, START + HOUR * 3.0)
	_expect(automatic.ok, "A policy is accepted after the previous window ended, without a sweep")
	_expect(Insurance.policy(insurance, "policy-a3").status == Insurance.STATUS_EXPIRED \
		and Insurance.policy(insurance, "policy-a4").status == Insurance.STATUS_ACTIVE,
		"Underwriting marks the ended policy expired in the same candidate")
	_expect(Insurance.valid(insurance) and Economy.valid(data.economy),
		"The automatically expired document validates")


func _test_underwrite_errors() -> void:
	var fixture: Dictionary = _fixture()
	var data: Dictionary = fixture.data
	var insurance: Dictionary = fixture.insurance
	for bad_owner: String in [Insurance.WORLD_OWNER, "", "org_team", "bad owner!"]:
		_expect(Insurance.underwrite(data.economy, insurance, "policy-bad",
			bad_owner, FARM_TO_HARBOR, "greens", 2, START, START + HOUR,
			START).reason == "invalid_owner",
			"The @world, organization and malformed owners cannot underwrite")
	_expect(Insurance.underwrite(data.economy, insurance, "policy-c",
		PLAYER_C, FARM_TO_HARBOR, "greens", 2, START, START + HOUR,
		START).reason == "unknown_account", "An owner without an account is refused")
	# A proceeds-only account (cash received without the opening grant) exists but
	# cannot buy insurance until it is opened.
	data.economy.accounts[PLAYER_C] = {"cash": 100, "granted": false}
	data.economy.issued = int(data.economy.issued) + 100
	var ledger: Dictionary = data.economy.ledger
	Ledger.post(ledger, Ledger.KIND_OPEN_ACCOUNT, "open-c", START, [
		Ledger.debit_line(Ledger.owner_code(PLAYER_C), 100),
		Ledger.credit_line(Ledger.ISSUANCE, 100),
	])
	_expect(Insurance.underwrite(data.economy, insurance, "policy-c",
		PLAYER_C, FARM_TO_HARBOR, "greens", 2, START, START + HOUR,
		START).reason == "account_not_open",
		"An account that never received the opening grant is refused")
	_expect(Insurance.underwrite(data.economy, insurance, "claim_1",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, START + HOUR,
		START).reason == "invalid_policy",
		"A policy id in the claim namespace is reserved")
	_expect(Insurance.underwrite(data.economy, insurance, "loss_1",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, START + HOUR,
		START).reason == "invalid_policy",
		"A policy id in the loss namespace is reserved")
	_expect(Insurance.underwrite(data.economy, insurance, "",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, START + HOUR,
		START).reason == "invalid_policy", "An empty policy id is refused")
	var broken: Dictionary = {"policies": {}}
	_expect(Insurance.underwrite(data.economy, broken, "policy-d",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, START + HOUR,
		START).reason == "invalid_state", "A malformed policy document is refused")

	var drained: Dictionary = _fixture()
	var paid: Dictionary = Economy.pay(drained.data.economy, PLAYER_A, PLAYER_B, 120,
		"drain-a", START)
	_expect(paid.ok, "The fixture can drain the owner's cash")
	_expect(Insurance.underwrite(drained.data.economy, drained.insurance, "policy-e",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, START + HOUR,
		START).reason == "insufficient", "An owner who cannot afford the premium is refused")
	_expect(Insurance.underwrite(drained.data.economy, drained.insurance, "policy-f",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START - 1.0, START + HOUR,
		START).reason == "invalid_start", "A backdated policy is refused")
	_expect(drained.insurance.policies.is_empty(),
		"Every refused underwriting leaves the policy table empty")
	# The policy id is also the premium payment's command id. Reusing an accepted
	# command id would make the payment replay while the policy row still lands,
	# so the underwriting is refused instead.
	var reused: Dictionary = _fixture()
	_expect(Economy.pay(reused.data.economy, PLAYER_A, PLAYER_B, 1, "policy-reuse",
		START).ok, "The fixture uses a command id that a policy will reuse")
	_expect(Insurance.underwrite(reused.data.economy, reused.insurance, "policy-reuse",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, START + HOUR,
		START).reason == "id_in_use",
		"A policy id already recorded as an economy command is refused")
	_expect(reused.insurance.policies.is_empty()
		and Economy.cash(reused.data.economy, PLAYER_A) == 119,
		"A reused-id refusal writes no policy and charges no premium")


func _test_retroactive_rejected() -> void:
	var fixture: Dictionary = _fixture()
	var data: Dictionary = fixture.data
	var insurance: Dictionary = fixture.insurance
	var lost: Dictionary = _lose(data, "retro-ship", "greens", 2, START + 5.0)
	_expect(lost.ok and lost.lost == 1 and data.economy.losses.events.has("loss_1"),
		"The fixture produces one authoritative transport loss")
	var loss: Dictionary = Market.loss(data.economy, "loss_1")
	_expect(loss.cause_start_utc == START + 5.0 and loss.cause_end_utc == ARRIVE + 5.0,
		"The loss carries its real risk window, not the sweep instant")
	var cash_before: int = Economy.cash(data.economy, PLAYER_A)
	var after_loss: Dictionary = Insurance.underwrite(data.economy, insurance, "policy-late",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, ARRIVE + 5.0, ARRIVE + 5.0 + HOUR,
		ARRIVE + 5.0)
	_expect(not after_loss.ok and after_loss.reason == "loss_already_occurred",
		"A loss that already happened cannot be insured afterwards")
	_expect(Economy.cash(data.economy, PLAYER_A) == cash_before \
		and insurance.policies.is_empty(),
		"A refused retrospective policy charges nothing")
	var backdated: Dictionary = Insurance.underwrite(data.economy, insurance, "policy-back",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START + 4.0, START + 4.0 + HOUR,
		ARRIVE + 5.0)
	_expect(not backdated.ok and backdated.reason == "invalid_start",
		"A policy that starts before the underwriting instant is refused")

	var transit: Dictionary = _fixture()
	var shipped: Dictionary = Market.ship(transit.data, "transit-ship", PLAYER_A,
		Market.LOCATION_FARM, Market.LOCATION_HARBOR, "greens", 2, START + 5.0,
		Market.SHIPMENT_RISK_DECLARED)
	_expect(shipped.ok and shipped.status == Market.SHIPMENT_STATUS_TRANSIT,
		"The fixture ships declared risk before any policy")
	var transit_cash: int = Economy.cash(transit.data.economy, PLAYER_A)
	var same_instant: Dictionary = Insurance.underwrite(transit.data.economy,
		transit.insurance, "policy-transit", PLAYER_A, FARM_TO_HARBOR, "greens", 2,
		START + 5.0, START + 5.0 + HOUR, START + 5.0)
	_expect(not same_instant.ok and same_instant.reason == "risk_already_in_transit",
		"A shipment already under way at the policy start cannot be covered")
	var later_start: Dictionary = Insurance.underwrite(transit.data.economy,
		transit.insurance, "policy-transit-2", PLAYER_A, FARM_TO_HARBOR, "greens", 2,
		START + 6.0, START + 6.0 + HOUR, START + 6.0)
	_expect(not later_start.ok and later_start.reason == "risk_already_in_transit",
		"A later start still cannot cover that departure")
	_expect(Economy.cash(transit.data.economy, PLAYER_A) == transit_cash \
		and transit.insurance.policies.is_empty(),
		"Refused in-transit coverage charges nothing")

	# A policy bought after a loss but starting strictly after its window is
	# accepted as ordinary future risk; the old loss can still never be claimed.
	var after_window: Dictionary = Insurance.underwrite(data.economy, insurance,
		"policy-future", PLAYER_A, FARM_TO_HARBOR, "greens", 2,
		ARRIVE + 5.0 + HOUR, ARRIVE + 5.0 + HOUR * 2.0, ARRIVE + 5.0 + HOUR)
	_expect(after_window.ok,
		"Coverage bought after a loss is accepted once it starts after that loss")
	var rejected_claim: Dictionary = Insurance.claim(data.economy, insurance, "claim_1",
		"policy-future", "loss_1", ARRIVE + 5.0 + HOUR)
	_expect(not rejected_claim.ok and rejected_claim.reason == "not_in_force",
		"The pre-existing loss still cannot be claimed on the later policy")
	_expect(insurance.claims.is_empty() and insurance.policies.size() == 1,
		"A refused retrospective claim records no claim row")


func _test_claim_once_and_replay() -> void:
	var fixture: Dictionary = _fixture(100)
	var data: Dictionary = fixture.data
	var insurance: Dictionary = fixture.insurance
	var underwritten: Dictionary = Insurance.underwrite(data.economy, insurance, "policy-a",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, HORIZON, START)
	_expect(underwritten.ok, "The policy is active before the shipment departs")
	var lost: Dictionary = _lose(data, "claim-ship", "greens", 2, START + 5.0)
	_expect(lost.lost == 1, "The insured shipment is lost by the deterministic roll")
	var issued_before: int = Economy.issued(data.economy)
	var losses_before: Dictionary = data.economy.losses.duplicate(true)
	var cash_before: int = Economy.cash(data.economy, PLAYER_A)
	var world_before: int = Economy.cash(data.economy, Insurance.WORLD_OWNER)
	var total_before: int = Economy.total_cash(data.economy)
	var claimed: Dictionary = Insurance.claim(data.economy, insurance, "claim_1",
		"policy-a", "loss_1", ARRIVE + 5.0)
	_expect(claimed.ok and not claimed.duplicate and claimed.claim_id == "claim_1" \
		and claimed.status == Insurance.CLAIM_STATUS_PAID,
		"A loss inside the policy window is paid once")
	var row: Dictionary = Insurance.claim_row(insurance, "claim_1")
	_expect(row.assessed_value == 12 and row.coverage == 9 and row.deductible == 3 \
		and row.payout == 9 and row.loss_id == "loss_1" \
		and row.created_utc == ARRIVE + 5.0 and row.paid_utc == ARRIVE + 5.0,
		"The claim pays min(coverage, value - deductible) from the loss evidence")
	_expect(row.size() == Insurance.CLAIM_KEYS.size(),
		"The claim row has exactly the documented keys")
	_expect(Economy.cash(data.economy, PLAYER_A) == cash_before + 9 \
		and Economy.cash(data.economy, Insurance.WORLD_OWNER) == world_before - 9,
		"The payout moves cash from the pool to the victim")
	_expect(Economy.issued(data.economy) == issued_before \
		and Economy.total_cash(data.economy) == total_before,
		"A payout is a transfer: issued and total cash do not change")
	_expect(data.economy.losses == losses_before,
		"A claim never rewrites the authoritative loss evidence")
	_expect(Insurance.policy(insurance, "policy-a").status == Insurance.STATUS_CLAIMED \
		and Insurance.policy(insurance, "policy-a").claim_id == "claim_1",
		"The policy is claimed and points at its single claim")
	var pay_entry: Dictionary = _event_entry(data.economy, "claim_1")
	_expect(pay_entry.kind == Ledger.KIND_PAY and _balanced(pay_entry),
		"The payout posts one balanced payment entry")
	_expect(_signed(pay_entry, Ledger.owner_code(PLAYER_A)) == 9 \
		and _signed(pay_entry, Ledger.owner_code(Insurance.WORLD_OWNER)) == -9,
		"The victim is debited 9 and the pool credited 9")
	_expect(Economy.valid(data.economy) and Economy.reconcile(data.economy).ok,
		"The economy validates and reconciles after a payout")
	_expect(Insurance.valid(insurance), "The claimed policy document validates")

	var accepted_economy: Dictionary = data.economy.duplicate(true)
	var accepted_insurance: Dictionary = insurance.duplicate(true)
	var replay: Dictionary = Insurance.claim(data.economy, insurance, "claim_1",
		"policy-a", "loss_1", ARRIVE + 5.0)
	_expect(replay.ok and replay.duplicate and replay.payout == 9 \
		and replay.status == Insurance.CLAIM_STATUS_PAID,
		"Replaying the claim returns the paid result")
	_expect(data.economy == accepted_economy and insurance == accepted_insurance,
		"A claim replay pays nothing a second time")
	var takeover: Dictionary = Insurance.claim(data.economy, insurance, "claim_1",
		"policy-other", "loss_1", ARRIVE + 5.0)
	_expect(not takeover.ok and takeover.reason == "command_conflict",
		"Another policy cannot take over a recorded claim id")
	_expect(data.economy == accepted_economy,
		"A conflicting claim replay moves no cash")

	var second_loss: Dictionary = _fixture(100)
	Insurance.underwrite(second_loss.data.economy, second_loss.insurance, "policy-a",
		PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, HORIZON, START)
	var first: Dictionary = Market.ship(second_loss.data, "ship-one", PLAYER_A,
		Market.LOCATION_FARM, Market.LOCATION_HARBOR, "greens", 2, START + 5.0,
		Market.SHIPMENT_RISK_DECLARED)
	var second: Dictionary = Market.ship(second_loss.data, "ship-two", PLAYER_A,
		Market.LOCATION_FARM, Market.LOCATION_HARBOR, "greens", 2, START + 5.0,
		Market.SHIPMENT_RISK_DECLARED)
	_expect(first.ok and second.ok, "The fixture ships two declared-risk batches")
	var sweep: Dictionary = Market.deliver(second_loss.data, START + 5.0 + Market.DELIVERY_SECONDS)
	_expect(sweep.lost == 2 and second_loss.data.economy.losses.events.size() == 2,
		"Both declared shipments become losses")
	var paid_first: Dictionary = Insurance.claim(second_loss.data.economy,
		second_loss.insurance, "claim_1", "policy-a", "loss_1",
		START + 5.0 + Market.DELIVERY_SECONDS)
	_expect(paid_first.ok, "The first loss is paid by the policy")
	var cash_after: int = Economy.cash(second_loss.data.economy, PLAYER_A)
	var paid_second: Dictionary = Insurance.claim(second_loss.data.economy,
		second_loss.insurance, "claim_2", "policy-a", "loss_2",
		START + 5.0 + Market.DELIVERY_SECONDS)
	_expect(not paid_second.ok and paid_second.reason == "policy_claimed",
		"One policy pays one loss; a second loss is refused")
	_expect(Economy.cash(second_loss.data.economy, PLAYER_A) == cash_after \
		and not second_loss.insurance.claims.has("claim_2"),
		"A refused second claim moves no cash and records no row")
	_expect(Insurance.valid(second_loss.insurance),
		"The one-claim-per-policy document validates")


func _test_deductible_and_coverage_bounds() -> void:
	# Deductible-bound: one basket of greens (value 6) minus the 3 COIN deductible
	# pays 3, below the 4 COIN coverage.
	var small: Dictionary = _fixture()
	_expect(Insurance.underwrite(small.data.economy, small.insurance, "policy-small",
		PLAYER_A, FARM_TO_HARBOR, "greens", 1, START, HORIZON, START).ok,
		"A one-basket policy is written before the loss")
	_lose(small.data, "small-ship", "greens", 1, START + 3.0)
	var small_claim: Dictionary = Insurance.claim(small.data.economy, small.insurance,
		"claim_1", "policy-small", "loss_1", ARRIVE + 3.0)
	_expect(small_claim.ok and small_claim.payout == 3,
		"A loss on one basket pays value minus deductible, below its coverage")
	_expect(Insurance.claim_row(small.insurance, "claim_1").assessed_value == 6 \
		and Insurance.claim_row(small.insurance, "claim_1").coverage == 4 \
		and Insurance.claim_row(small.insurance, "claim_1").payout == 3,
		"The small claim is deductible-bound, not coverage-bound")

	# Coverage-bound: a six-basket greens loss (value 36) against a six-basket
	# policy (coverage 28) pays the coverage cap, not value minus deductible.
	var large: Dictionary = _fixture()
	_expect(Insurance.underwrite(large.data.economy, large.insurance, "policy-large",
		PLAYER_A, FARM_TO_HARBOR, "greens", 6, START, HORIZON, START).ok,
		"A six-basket policy is written before the loss")
	_lose(large.data, "large-ship", "greens", 6, START + 7.0)
	var large_claim: Dictionary = Insurance.claim(large.data.economy, large.insurance,
		"claim_1", "policy-large", "loss_1", ARRIVE + 7.0)
	_expect(large_claim.ok and large_claim.payout == 28,
		"A loss above the coverage cap pays exactly the coverage")
	_expect(Insurance.claim_row(large.insurance, "claim_1").assessed_value == 36 \
		and Insurance.claim_row(large.insurance, "claim_1").coverage == 28 \
		and Insurance.claim_row(large.insurance, "claim_1").payout == 28,
		"The large claim is coverage-bound")

	# A different good is priced from its own reference value, not greens'.
	var radish_fixture: Dictionary = _fixture()
	var data: Dictionary = radish_fixture.data
	var written: Dictionary = Insurance.underwrite(data.economy, radish_fixture.insurance,
		"policy-radish", PLAYER_A, FARM_TO_HARBOR, "radish", 1, START, HORIZON, START)
	_expect(written.ok and written.coverage == 14 and written.premium == 1,
		"A one-basket radish policy quotes its own 14 COIN coverage")
	_expect(Economy.cash(data.economy, PLAYER_A) == 119,
		"The radish premium is deducted once")


func _test_expired_status_still_pays() -> void:
	# Expiry is hygiene, not entitlement: a loss inside the closed window is still
	# paid even after the policy label flips to expired.
	var fixture: Dictionary = _fixture(100)
	var data: Dictionary = fixture.data
	var insurance: Dictionary = fixture.insurance
	Insurance.underwrite(data.economy, insurance, "policy-a", PLAYER_A,
		FARM_TO_HARBOR, "greens", 2, START, START + HOUR, START)
	_lose(data, "expired-ship", "greens", 2, START + 5.0)
	var swept: Dictionary = Insurance.expire(insurance, START + HOUR * 5.0)
	_expect(swept.ok and swept.expired == ["policy-a"],
		"The policy window has closed before the claim")
	_expect(Insurance.policy(insurance, "policy-a").status == Insurance.STATUS_EXPIRED,
		"The policy label is expired")
	var claimed: Dictionary = Insurance.claim(data.economy, insurance, "claim_1",
		"policy-a", "loss_1", START + HOUR * 5.0)
	_expect(claimed.ok and claimed.payout == 9,
		"A loss inside the closed window is still paid after expiry")
	_expect(Insurance.claim_row(insurance, "claim_1").paid_utc == START + HOUR * 5.0,
		"The payout is stamped at the claim instant, not the loss instant")
	_expect(Insurance.valid(insurance) and Economy.valid(data.economy),
		"The expiring-then-claimed document and economy validate")


func _test_claim_mismatches() -> void:
	var route_fixture: Dictionary = _fixture()
	_expect(Insurance.underwrite(route_fixture.data.economy, route_fixture.insurance,
		"policy-rev", PLAYER_A, HARBOR_TO_FARM, "greens", 2, START, HORIZON,
		START).ok, "A reverse-route policy is accepted")
	_lose(route_fixture.data, "route-ship", "greens", 2, START + 5.0)
	_expect(Insurance.claim(route_fixture.data.economy, route_fixture.insurance,
		"claim_1", "policy-rev", "loss_1", ARRIVE + 5.0).reason == "route_mismatch",
		"A loss on another route is refused by name")
	_expect(Insurance.policy(route_fixture.insurance, "policy-rev").status
		== Insurance.STATUS_ACTIVE and route_fixture.insurance.claims.is_empty(),
		"A refused route claim leaves the policy active and records nothing")

	var good_fixture: Dictionary = _fixture()
	_expect(Insurance.underwrite(good_fixture.data.economy, good_fixture.insurance,
		"policy-greens", PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, HORIZON,
		START).ok, "A greens policy is accepted")
	_lose(good_fixture.data, "spinach-ship", "spinach", 2, START + 1.0)
	_expect(Insurance.claim(good_fixture.data.economy, good_fixture.insurance,
		"claim_1", "policy-greens", "loss_1", ARRIVE + 1.0).reason == "good_mismatch",
		"A loss of another good is refused by name")

	var quantity_fixture: Dictionary = _fixture()
	_expect(Insurance.underwrite(quantity_fixture.data.economy,
		quantity_fixture.insurance, "policy-one", PLAYER_A, FARM_TO_HARBOR,
		"greens", 1, START, HORIZON, START).ok, "A one-basket policy is accepted")
	_lose(quantity_fixture.data, "two-ship", "greens", 2, START + 5.0)
	_expect(Insurance.claim(quantity_fixture.data.economy, quantity_fixture.insurance,
		"claim_1", "policy-one", "loss_1", ARRIVE + 5.0).reason == "quantity_exceeded",
		"A loss larger than the covered quantity is refused")

	var victim_fixture: Dictionary = _fixture()
	_expect(Insurance.underwrite(victim_fixture.data.economy, victim_fixture.insurance,
		"policy-a", PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, HORIZON,
		START).ok, "The victim fixture insures the wrong owner on purpose")
	var b_ship: Dictionary = Market.ship(victim_fixture.data, "b-ship", PLAYER_B,
		Market.LOCATION_FARM, Market.LOCATION_HARBOR, "greens", 2, START + 2.0,
		Market.SHIPMENT_RISK_DECLARED)
	_expect(b_ship.ok, "Another owner ships declared risk")
	_expect(Market.deliver(victim_fixture.data,
		START + 2.0 + Market.DELIVERY_SECONDS).lost == 1,
		"The other owner's shipment is lost")
	_expect(Insurance.claim(victim_fixture.data.economy, victim_fixture.insurance,
		"claim_1", "policy-a", "loss_1", ARRIVE + 2.0).reason == "not_victim",
		"A policy cannot claim another owner's loss")

	var window_fixture: Dictionary = _fixture()
	_expect(Insurance.underwrite(window_fixture.data.economy, window_fixture.insurance,
		"policy-late-start", PLAYER_A, FARM_TO_HARBOR, "greens", 2, START + 600.0,
		START + 600.0 + HOUR, START).ok, "A later-start policy is accepted before the risk")
	_lose(window_fixture.data, "window-ship", "greens", 2, START + 5.0)
	_expect(Insurance.claim(window_fixture.data.economy, window_fixture.insurance,
		"claim_1", "policy-late-start", "loss_1", ARRIVE + 5.0).reason
		== "not_in_force", "A loss that began before the policy start is refused")
	_expect(Insurance.claim(window_fixture.data.economy, window_fixture.insurance,
		"claim_1", "policy-late-start", "loss_1", ARRIVE + 4.0).reason
		== "claim_before_loss", "A claim before the loss window closed is refused")

	var missing_fixture: Dictionary = _fixture()
	Insurance.underwrite(missing_fixture.data.economy, missing_fixture.insurance,
		"policy-a", PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, HORIZON, START)
	_lose(missing_fixture.data, "archive-ship", "greens", 2, START + 5.0)
	missing_fixture.data.economy.market.shipments.erase("archive-ship")
	_expect(Insurance.claim(missing_fixture.data.economy, missing_fixture.insurance,
		"claim_1", "policy-a", "loss_1", ARRIVE + 5.0).reason == "shipment_missing",
		"A loss whose route evidence was archived is refused rather than assumed")

	var unknown_fixture: Dictionary = _fixture()
	Insurance.underwrite(unknown_fixture.data.economy, unknown_fixture.insurance,
		"policy-a", PLAYER_A, FARM_TO_HARBOR, "greens", 2, START, HORIZON, START)
	_lose(unknown_fixture.data, "unknown-ship", "greens", 2, START + 5.0)
	_expect(Insurance.claim(unknown_fixture.data.economy, unknown_fixture.insurance,
		"claim_1", "policy-absent", "loss_1", ARRIVE + 5.0).reason == "unknown_policy",
		"An unknown policy id is refused by name")
	_expect(Insurance.claim(unknown_fixture.data.economy, unknown_fixture.insurance,
		"claim_1", "policy-a", "loss_9", ARRIVE + 5.0).reason == "unknown_loss",
		"An unknown loss id is refused by name")
	_expect(Insurance.claim(unknown_fixture.data.economy, unknown_fixture.insurance,
		"claim_2", "policy-a", "loss_1", ARRIVE + 5.0).reason == "invalid_claim_id",
		"A claim id must derive from the loss sequence")
	_expect(Insurance.claim(unknown_fixture.data.economy, unknown_fixture.insurance,
		"claim_01", "policy-a", "loss_1", ARRIVE + 5.0).reason == "invalid_claim",
		"A non-canonical zero-padded claim id is refused")
	_expect(Insurance.claim(unknown_fixture.data.economy, unknown_fixture.insurance,
		"claim_1", "policy-a", "loss_01", ARRIVE + 5.0).reason == "unknown_loss",
		"A zero-padded loss id is not the recorded evidence id")
	_expect(Insurance.claim(unknown_fixture.data.economy, unknown_fixture.insurance,
		"make-claim", "policy-a", "loss_1", ARRIVE + 5.0).reason == "invalid_claim",
		"A claim id outside the generated namespace is refused")
	_expect(unknown_fixture.insurance.claims.is_empty(),
		"Every refused claim leaves the claim table empty")


func _test_claim_limits() -> void:
	var fixture: Dictionary = _fixture()
	var data: Dictionary = fixture.data
	var insurance: Dictionary = fixture.insurance
	var bulk: Dictionary = Insurance.underwrite(data.economy, insurance, "policy-bulk",
		PLAYER_A, FARM_TO_HARBOR, "greens", Insurance.MAX_QUANTITY, START,
		START + HOUR * 2.0, START)
	_expect(bulk.ok and bulk.premium == 15 and bulk.coverage == 307 \
		and bulk.deductible == 3,
		"The largest policy charges the fixed terms for 64 baskets")
	_expect(Economy.cash(data.economy, PLAYER_A) == 105,
		"The large premium is deducted exactly once")
	var overlap: Dictionary = Insurance.underwrite(data.economy, insurance, "policy-b",
		PLAYER_B, FARM_TO_HARBOR, "greens", 1, START + HOUR, START + HOUR * 2.0,
		START + HOUR)
	_expect(not overlap.ok and overlap.reason == "route_limit",
		"Overlapping policies on one route and good cannot exceed the covered bound")
	_expect(Economy.cash(data.economy, PLAYER_B) == 120,
		"A route-limit refusal charges no premium")
	var later: Dictionary = Insurance.underwrite(data.economy, insurance, "policy-b2",
		PLAYER_B, FARM_TO_HARBOR, "greens", 1, START + HOUR * 2.0,
		START + HOUR * 3.0, START + HOUR * 2.0)
	_expect(later.ok, "A non-overlapping window is still insurable")
	var swept: Dictionary = Insurance.expire(insurance, START + HOUR * 2.0)
	_expect(swept.ok and swept.count == 1 and swept.expired == ["policy-bulk"],
		"The expiry sweep marks the older closed window without touching the newer one")
	_expect(Insurance.policy(insurance, "policy-bulk").status == Insurance.STATUS_EXPIRED \
		and Insurance.policy(insurance, "policy-b2").status == Insurance.STATUS_ACTIVE,
		"Only the ended policy flips to expired")
	_expect(Insurance.valid(insurance), "The bounded overlapping document validates")
	_expect(Insurance.underwrite(data.economy, insurance, "policy-too-big",
		PLAYER_B, HARBOR_TO_FARM, "greens", Insurance.MAX_QUANTITY + 1,
		START + HOUR, START + HOUR * 2.0, START + HOUR).reason
		== "invalid_quantity", "A quantity over the policy bound is refused")


func _test_route_bound_as_document() -> void:
	# The route/good bound also has to hold in a stored document, not only in the
	# underwriting path. Two overlapping one-basket policies on the largest
	# allowed quantity would exceed the bound and must be rejected on load.
	var insurance: Dictionary = Insurance.initial_state()
	var wide: Dictionary = Insurance.terms("greens", Insurance.MAX_QUANTITY)
	insurance.policies["resume-a"] = {
		"policy_id": "resume-a", "owner": PLAYER_A, "route": FARM_TO_HARBOR,
		"good": "greens", "quantity_covered": Insurance.MAX_QUANTITY,
		"premium": int(wide.premium), "coverage": int(wide.coverage),
		"deductible": int(wide.deductible), "starts_utc": START,
		"ends_utc": START + HOUR, "status": Insurance.STATUS_EXPIRED, "claim_id": "",
	}
	var narrow: Dictionary = Insurance.terms("greens", 1)
	insurance.policies["resume-b"] = {
		"policy_id": "resume-b", "owner": PLAYER_B, "route": FARM_TO_HARBOR,
		"good": "greens", "quantity_covered": 1,
		"premium": int(narrow.premium), "coverage": int(narrow.coverage),
		"deductible": int(narrow.deductible), "starts_utc": START + HOUR,
		"ends_utc": START + HOUR * 2.0, "status": Insurance.STATUS_EXPIRED,
		"claim_id": "",
	}
	_expect(Insurance.valid(insurance),
		"A non-overlapping pair above the per-policy bound but within the route bound validates")
	insurance.policies["resume-c"] = {
		"policy_id": "resume-c", "owner": PLAYER_C, "route": FARM_TO_HARBOR,
		"good": "greens", "quantity_covered": 1,
		"premium": int(narrow.premium), "coverage": int(narrow.coverage),
		"deductible": int(narrow.deductible), "starts_utc": START + HOUR / 2.0,
		"ends_utc": START + HOUR * 1.5, "status": Insurance.STATUS_EXPIRED,
		"claim_id": "",
	}
	_expect(not Insurance.valid(insurance),
		"Three overlapping policies exceeding the route/good bound are rejected on load")


func _test_pending_and_settle() -> void:
	var fixture: Dictionary = _fixture()
	var data: Dictionary = fixture.data
	var insurance: Dictionary = fixture.insurance
	Insurance.underwrite(data.economy, insurance, "policy-a", PLAYER_A,
		FARM_TO_HARBOR, "greens", 2, START, HORIZON, START)
	_lose(data, "pending-ship", "greens", 2, START + 5.0)
	var world_before: int = Economy.cash(data.economy, Insurance.WORLD_OWNER)
	var victim_before: int = Economy.cash(data.economy, PLAYER_A)
	var claimed: Dictionary = Insurance.claim(data.economy, insurance, "claim_1",
		"policy-a", "loss_1", ARRIVE + 5.0)
	_expect(claimed.ok and claimed.status == Insurance.CLAIM_STATUS_PENDING \
		and claimed.payout == 9,
		"A claim larger than the pool is recorded as pending, not paid")
	_expect(Economy.cash(data.economy, Insurance.WORLD_OWNER) == world_before \
		and Economy.cash(data.economy, PLAYER_A) == victim_before,
		"A pending claim moves no cash and invents none")
	_expect(Insurance.claim_row(insurance, "claim_1").paid_utc == 0.0,
		"A pending claim has no paid instant")
	_expect(Insurance.valid(insurance) and Economy.valid(data.economy),
		"The pending claim document and economy validate")
	var early: Dictionary = Insurance.settle_claims(data.economy, insurance, ARRIVE + 6.0)
	_expect(early.ok and early.count == 0,
		"A short pool leaves the pending claim unpaid")
	var funded: Dictionary = Economy.pay(data.economy, PLAYER_B,
		Insurance.WORLD_OWNER, 100, "fund-pool", ARRIVE + 6.0)
	_expect(funded.ok, "The fixture can add reserve capital to the pool")
	var settled: Dictionary = Insurance.settle_claims(data.economy, insurance,
		ARRIVE + 7.0)
	_expect(settled.ok and settled.count == 1 and settled.paid == ["claim_1"],
		"A funded pool pays the pending claim exactly once")
	_expect(Insurance.claim_row(insurance, "claim_1").status
		== Insurance.CLAIM_STATUS_PAID \
		and Insurance.claim_row(insurance, "claim_1").paid_utc == ARRIVE + 7.0,
		"The settled claim records its paid instant")
	_expect(Economy.cash(data.economy, PLAYER_A) == victim_before + 9,
		"The victim receives the pending payout when the pool can cover it")
	_expect(Economy.issued(data.economy) == Economy.total_cash(data.economy),
		"Settling a pending claim issues no money")
	var replay: Dictionary = Insurance.claim(data.economy, insurance, "claim_1",
		"policy-a", "loss_1", ARRIVE + 7.0)
	_expect(replay.ok and replay.duplicate and replay.status == Insurance.CLAIM_STATUS_PAID,
		"A replay after settlement returns the paid row")
	var again: Dictionary = Insurance.settle_claims(data.economy, insurance, ARRIVE + 8.0)
	_expect(again.ok and again.count == 0,
		"A second settlement sweep pays nothing")
	_expect(Insurance.claims(insurance).size() == 1
		and Insurance.claims(insurance)[0].payout == 9,
		"The settled claim table holds exactly one paid row")


func _test_settle_skips_unaffordable() -> void:
	# Settlement walks pending claims in creation order. A large claim the pool
	# cannot cover is skipped and stays pending; a smaller later claim is still
	# paid, so one shortfall does not freeze the whole queue.
	var fixture: Dictionary = _fixture()
	var data: Dictionary = fixture.data
	var insurance: Dictionary = fixture.insurance
	Insurance.underwrite(data.economy, insurance, "policy-a", PLAYER_A,
		FARM_TO_HARBOR, "greens", 2, START, HORIZON, START)
	_lose(data, "queue-ship", "greens", 2, START + 5.0)
	var first: Dictionary = Insurance.claim(data.economy, insurance, "claim_1",
		"policy-a", "loss_1", ARRIVE + 5.0)
	_expect(first.ok and first.status == Insurance.CLAIM_STATUS_PENDING,
		"The large claim waits because the pool is short")
	# A second, smaller claim needs its own unclaimed policy and loss. Player B
	# ships at START + 5 so the deterministic roll for its sequence 2 is a loss.
	var second_policy: Dictionary = Insurance.underwrite(data.economy, insurance,
		"policy-b", PLAYER_B, FARM_TO_HARBOR, "greens", 1,
		START, HORIZON, START)
	_expect(second_policy.ok, "The second owner writes a small policy")
	var second_ship: Dictionary = Market.ship(data, "queue-ship-b", PLAYER_B,
		Market.LOCATION_FARM, Market.LOCATION_HARBOR, "greens", 1,
		START + 5.0, Market.SHIPMENT_RISK_DECLARED)
	_expect(second_ship.ok, "The second owner ships one declared-risk basket")
	var second_lost: Dictionary = Market.deliver(data, START + 5.0 + Market.DELIVERY_SECONDS)
	_expect(second_lost.lost == 1 and data.economy.losses.events.has("loss_2"),
		"The smaller shipment is lost as loss_2")
	var second_claim: Dictionary = Insurance.claim(data.economy, insurance, "claim_2",
		"policy-b", "loss_2", START + 5.0 + Market.DELIVERY_SECONDS)
	_expect(second_claim.ok and second_claim.status == Insurance.CLAIM_STATUS_PENDING,
		"The smaller claim is also pending before the pool is funded")
	# Fund the pool with less than the first claim but enough for the second.
	var needed: int = Insurance.claim_row(insurance, "claim_2").payout
	var funding: Dictionary = Economy.pay(data.economy, PLAYER_A,
		Insurance.WORLD_OWNER, needed, "fund-small", ARRIVE + 10.0)
	_expect(funding.ok and needed < Insurance.claim_row(insurance, "claim_1").payout,
		"The pool receives less than the large claim and enough for the small one")
	var swept: Dictionary = Insurance.settle_claims(data.economy, insurance,
		ARRIVE + 11.0)
	_expect(swept.ok and swept.count == 1 and swept.paid == ["claim_2"],
		"Settlement skips the unaffordable first claim and pays the smaller second")
	_expect(Insurance.claim_row(insurance, "claim_1").status
		== Insurance.CLAIM_STATUS_PENDING \
		and Insurance.claim_row(insurance, "claim_2").status
		== Insurance.CLAIM_STATUS_PAID,
		"The skipped claim stays pending and the paid one is terminal")
	_expect(Insurance.valid(insurance),
		"The partially settled claim document validates")


func _test_document_validation() -> void:
	var fixture: Dictionary = _fixture(100)
	var data: Dictionary = fixture.data
	var insurance: Dictionary = fixture.insurance
	Insurance.underwrite(data.economy, insurance, "policy-a", PLAYER_A,
		FARM_TO_HARBOR, "greens", 2, START, HORIZON, START)
	_lose(data, "valid-ship", "greens", 2, START + 5.0)
	Insurance.claim(data.economy, insurance, "claim_1", "policy-a", "loss_1",
		ARRIVE + 5.0)
	_expect(Insurance.valid(insurance), "A completed policy and claim validate")

	var round_trip: Variant = JSON.parse_string(JSON.stringify(insurance))
	_expect(round_trip is Dictionary, "The insurance document survives a JSON round trip")
	Insurance.normalize(round_trip)
	_expect(Insurance.valid(round_trip),
		"The normalized round trip still validates")
	_expect(Insurance.policy(round_trip, "policy-a").premium is int \
		and Insurance.claim_row(round_trip, "claim_1").payout is int \
		and Insurance.claim_row(round_trip, "claim_1").paid_utc is float,
		"Normalization restores integer and float number types")

	var inflated_premium: Dictionary = insurance.duplicate(true)
	inflated_premium.policies["policy-a"].premium = 2
	_expect(not Insurance.valid(inflated_premium),
		"A policy premium that the product never quoted is rejected")
	var inflated_coverage: Dictionary = insurance.duplicate(true)
	inflated_coverage.policies["policy-a"].coverage = 999
	_expect(not Insurance.valid(inflated_coverage),
		"A policy coverage that the product never quoted is rejected")
	var bad_payout: Dictionary = insurance.duplicate(true)
	bad_payout.claims["claim_1"].payout = 11
	_expect(not Insurance.valid(bad_payout),
		"A claim payout above the deductible formula is rejected")
	var orphan_claim: Dictionary = insurance.duplicate(true)
	orphan_claim.claims["claim_1"].loss_id = "loss_2"
	_expect(not Insurance.valid(orphan_claim),
		"A claim id that does not derive from its loss is rejected")
	var missing_link: Dictionary = insurance.duplicate(true)
	missing_link.claims.erase("claim_1")
	_expect(not Insurance.valid(missing_link),
		"A claimed policy without its claim row is rejected")
	var dangling_policy: Dictionary = insurance.duplicate(true)
	dangling_policy.policies["policy-a"].claim_id = ""
	dangling_policy.policies["policy-a"].status = Insurance.STATUS_ACTIVE
	_expect(not Insurance.valid(dangling_policy),
		"A pending claim cannot be left on an active policy")
	var duplicate_loss: Dictionary = insurance.duplicate(true)
	duplicate_loss.claims["claim_2"] = duplicate_loss.claims["claim_1"].duplicate(true)
	duplicate_loss.claims["claim_2"].id = "claim_2"
	_expect(not Insurance.valid(duplicate_loss),
		"Two claims cannot reference the same loss event")
	var double_active: Dictionary = insurance.duplicate(true)
	# Both rows are stripped back to an unclaimed active policy, which one owner
	# may not hold twice.
	double_active.claims = {}
	double_active.policies["policy-a"].status = Insurance.STATUS_ACTIVE
	double_active.policies["policy-a"].claim_id = ""
	var second: Dictionary = double_active.policies["policy-a"].duplicate(true)
	second.policy_id = "policy-b"
	second.route = HARBOR_TO_FARM
	double_active.policies["policy-b"] = second
	_expect(not Insurance.valid(double_active),
		"One owner cannot hold two active policies in a stored document")
	var extra_key: Dictionary = insurance.duplicate(true)
	extra_key["extra"] = true
	_expect(not Insurance.valid(extra_key),
		"An unknown top-level key is rejected")
	var bad_status: Dictionary = insurance.duplicate(true)
	bad_status.claims["claim_1"].status = "forgiven"
	_expect(not Insurance.valid(bad_status),
		"An unknown claim status is rejected")
	var bad_route: Dictionary = insurance.duplicate(true)
	bad_route.policies["policy-a"].route = "farm_market>farm_market"
	_expect(not Insurance.valid(bad_route),
		"A stored policy with a non-distinct route is rejected")
	var bad_owner: Dictionary = insurance.duplicate(true)
	bad_owner.policies["policy-a"].owner = Insurance.WORLD_OWNER
	_expect(not Insurance.valid(bad_owner),
		"The @world pool cannot hold a player policy")
	var empty: Dictionary = Insurance.initial_state()
	_expect(Insurance.valid(empty) and empty.policies.is_empty() and empty.claims.is_empty(),
		"The initial insurance document is valid and empty")


func _test_bounds() -> void:
	var fixture: Dictionary = _fixture()
	var data: Dictionary = fixture.data
	var insurance: Dictionary = fixture.insurance
	# The policy table is bounded; a full table refuses a new row instead of
	# evicting terminal evidence that a payout might still need. The fillers use
	# disjoint one-hour windows so the route/good bound is not the reason.
	for index: int in Insurance.MAX_POLICIES:
		var starts: float = START + float(index) * HOUR
		insurance.policies["filler-%03d" % index] = {
			"policy_id": "filler-%03d" % index, "owner": PLAYER_B,
			"route": FARM_TO_HARBOR, "good": "greens", "quantity_covered": 1,
			"premium": 1, "coverage": 4, "deductible": 3,
			"starts_utc": starts, "ends_utc": starts + HOUR,
			"status": Insurance.STATUS_EXPIRED, "claim_id": "",
		}
	_expect(Insurance.valid(insurance), "A table at exactly the policy bound validates")
	_expect(Insurance.underwrite(data.economy, insurance, "policy-over",
		PLAYER_A, FARM_TO_HARBOR, "greens", 1, START, START + HOUR,
		START).reason == "policy_limit",
		"A policy table at its bound refuses a new policy")
	_expect(insurance.policies.size() == Insurance.MAX_POLICIES \
		and Economy.cash(data.economy, PLAYER_A) == 120,
		"A policy-limit refusal writes no row and charges no premium")

	# A claim needs an unclaimed policy that links back to it, so the claim table
	# cannot outgrow the policy table. The document validator enforces that relation.
	var claims_fixture: Dictionary = _fixture()
	var claims_data: Dictionary = claims_fixture.data
	var claims_insurance: Dictionary = claims_fixture.insurance
	var written: Dictionary = Insurance.underwrite(claims_data.economy,
		claims_insurance, "policy-a", PLAYER_A, FARM_TO_HARBOR, "greens", 2,
		START, HORIZON, START)
	_expect(written.ok, "The claim-bound fixture writes a policy")
	_lose(claims_data, "bound-ship", "greens", 2, START + 5.0)
	_expect(Insurance.claim(claims_data.economy, claims_insurance, "claim_1",
		"policy-a", "loss_1", ARRIVE + 5.0).ok,
		"The only policy's one claim is accepted")
	var orphan: Dictionary = claims_insurance.duplicate(true)
	var extra: Dictionary = orphan.claims["claim_1"].duplicate(true)
	extra.id = "claim_2"
	extra.loss_id = "loss_2"
	orphan.claims["claim_2"] = extra
	_expect(not Insurance.valid(orphan),
		"A claim table larger than the policy table is rejected")
func _test_persistence() -> void:
	var fixture: Dictionary = _fixture(100)
	var data: Dictionary = fixture.data
	var insurance: Dictionary = fixture.insurance
	Insurance.underwrite(data.economy, insurance, "policy-a", PLAYER_A,
		FARM_TO_HARBOR, "greens", 2, START, HORIZON, START)
	_lose(data, "persist-ship", "greens", 2, START + 5.0)
	var claimed: Dictionary = Insurance.claim(data.economy, insurance, "claim_1",
		"policy-a", "loss_1", ARRIVE + 5.0)
	_expect(claimed.ok and claimed.status == Insurance.CLAIM_STATUS_PAID,
		"The persistence fixture pays one claim")
	var root: String = ProjectSettings.globalize_path("res://").path_join(
		"../.local/verification/insurance-%d" % OS.get_process_id()).simplify_path()
	DirAccess.make_dir_recursive_absolute(root)
	var path: String = root.path_join("insurance.json")
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	_expect(file != null, "The insurance document opens for writing")
	if file != null:
		file.store_string(JSON.stringify(insurance))
		file.close()
	var reopened: FileAccess = FileAccess.open(path, FileAccess.READ)
	_expect(reopened != null, "The written insurance document reopens")
	var parsed: Variant = JSON.parse_string(reopened.get_as_text()) if reopened != null else null
	if reopened != null:
		reopened.close()
	_expect(parsed is Dictionary, "The persisted insurance document parses")
	var restored: Dictionary = parsed if parsed is Dictionary else {}
	Insurance.normalize(restored)
	_expect(restored == insurance,
		"The reopened document normalizes back to the exact in-memory rows")
	_expect(Insurance.valid(restored),
		"The reopened document validates")
	_expect(Insurance.claim_row(restored, "claim_1").payout is int \
		and Insurance.claim_row(restored, "claim_1").paid_utc is float \
		and Insurance.policy(restored, "policy-a").premium is int \
		and Insurance.policy(restored, "policy-a").starts_utc is float,
		"The reopened rows carry canonical integer and float types")
	var economy_before: Dictionary = data.economy.duplicate(true)
	var replay: Dictionary = Insurance.claim(data.economy, restored, "claim_1",
		"policy-a", "loss_1", ARRIVE + 5.0)
	_expect(replay.ok and replay.duplicate and replay.payout == 9,
		"A reopened claim replays as a duplicate")
	_expect(data.economy == economy_before,
		"A reopened duplicate claim moves no cash")
	var new_policy: Dictionary = Insurance.underwrite(data.economy, restored,
		"policy-b", PLAYER_B, FARM_TO_HARBOR, "greens", 1,
		ARRIVE + HOUR, ARRIVE + HOUR * 2.0, ARRIVE + HOUR)
	_expect(new_policy.ok and Insurance.valid(restored),
		"A reopened document accepts a new policy and stays valid")


func _fixture(fund_world: int = 0) -> Dictionary:
	var farm := Farm.new(START)
	_grow(farm, "field_01", CELLS_16, "greens", PLAYER_A)
	_grow(farm, "field_02", CELLS_8, "spinach", PLAYER_A)
	_grow(farm, "field_03", CELLS_4, "greens", PLAYER_B)
	farm.economy_open_account("open-a", PLAYER_A, START)
	farm.economy_open_account("open-b", PLAYER_B, START)
	var snapshot: Dictionary = farm.snapshot()
	var data: Dictionary = {"economy": snapshot.economy, "bags": snapshot.bags}
	if fund_world > 0:
		data.economy.accounts[Insurance.WORLD_OWNER] = {"cash": 0, "granted": false}
		var funded: Dictionary = Economy.pay(data.economy, PLAYER_B,
			Insurance.WORLD_OWNER, fund_world, "fund-world", START)
		_expect(funded.ok, "The fixture funds the @world insurance pool")
	return {"data": data, "insurance": Insurance.initial_state()}


func _grow(farm: Farm, field_id: String, cells: Array[String], crop_id: String,
		actor: String) -> void:
	for cell_id: String in cells:
		_expect(farm.sow(field_id, cell_id, crop_id, START, actor).ok,
			"The fixture sows " + crop_id + " on " + field_id + " " + cell_id)
	farm.mature_all_crops(START)
	for cell_id: String in cells:
		_expect(farm.harvest(field_id, cell_id, START, actor).ok,
			"The fixture harvests " + field_id + " " + cell_id)


func _lose(data: Dictionary, ship_id: String, good_id: String, quantity: int,
		depart_utc: float) -> Dictionary:
	var shipped: Dictionary = Market.ship(data, ship_id, PLAYER_A, Market.LOCATION_FARM,
		Market.LOCATION_HARBOR, good_id, quantity, depart_utc,
		Market.SHIPMENT_RISK_DECLARED)
	_expect(shipped.ok, "The loss fixture ships declared risk " + ship_id)
	return Market.deliver(data, depart_utc + Market.DELIVERY_SECONDS)


func _event_entry(economy: Dictionary, event_id: String) -> Dictionary:
	for entry: Dictionary in Economy.ledger_entries(economy):
		if str(entry.event_id) == event_id:
			return entry
	return {}


func _balanced(entry: Dictionary) -> bool:
	var debit: int = 0
	var credit: int = 0
	for raw_line: Dictionary in entry.get("lines", []):
		debit += int(raw_line.debit)
		credit += int(raw_line.credit)
	return debit == credit and debit == int(entry.get("debit", -1)) \
		and credit == int(entry.get("credit", -1)) and debit > 0


## Signed line amount over one account: debit is positive, credit negative.
func _signed(entry: Dictionary, code: String) -> int:
	var total: int = 0
	for raw_line: Dictionary in entry.get("lines", []):
		if str(raw_line.account) == code:
			total += int(raw_line.debit) - int(raw_line.credit)
	return total


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
