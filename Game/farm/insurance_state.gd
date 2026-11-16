extends RefCounted
## M8-03 insurance rules over the authoritative transport-loss evidence. Pure
## rules: no clock, disk, scene or network access.
##
## The policy table and the claim table are a separate bounded document owned by
## the caller. They are not part of the economy document: adding `insurance` to
## `Economy.STATE_KEYS` would break every strict economy shape at once, so this
## slice keeps the rows here and only moves cash through the existing balances.
##
## Cash authority stays on the existing balances (ADR-014/ADR-022). A premium is
## a transfer, not a burn, and a payout is a transfer, not an issuance:
##
##   premium  debit  account:<owner>  credit account:@world
##   payout   debit  account:<owner>  credit account:@world
##
## Both use `Economy.pay`, the existing balanced payment entry, so `issued` is
## unchanged and `total_cash == issued` still holds. The payout source is the
## `@world` cash that premiums accumulated; when it cannot cover a claim the
## claim waits as `pending` instead of inventing money (ADR-022).
##
## Underwriting is limited to future risk. A policy starts no earlier than the
## underwriting instant, and a claim is accepted only when the authoritative
## loss window sits strictly inside the policy window. A loss that already
## exists can therefore never be covered retroactively.
##
## A claim id is derived from the loss sequence (`claim_<loss.n>`), and a policy
## keeps one `claim_id`, so one loss can be paid at most once and one policy can
## pay at most one loss. Replays resolve from the durable claim row, not from the
## bounded command window.

const Catalog = preload("res://farm/economy_catalog.gd")
const Market = preload("res://farm/market_state.gd")
const Ledger = preload("res://farm/ledger_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const OwnerIds = preload("res://farm/owner_id.gd")

const WORLD_OWNER: String = "@world"
const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_COMMAND_ID_LENGTH: int = 128
const MAX_POLICIES: int = 128
## A claim is validated only when its policy links back to it, and a policy
## carries at most one claim id, so the claim table can never exceed the policy
## table. That relation is the bound; no separate eviction rule is needed.

## Experiment bounds. A single policy covers at most 64 baskets, and all
## overlapping policies on one route/good together cover at most 64, so the
## premium pool and the reserve report stay small enough to reason about.
const MAX_QUANTITY: int = 64
const ROUTE_GOOD_QUANTITY_LIMIT: int = 64
const MIN_TERM_SECONDS: float = 3600.0
const MAX_TERM_SECONDS: float = 2592000.0

## Fixed product terms. Coverage is 80% of the locked catalog value, the
## deductible is a flat 3 COIN and the premium 5% of coverage with a one COIN
## floor. `payout = min(coverage, value - deductible)`: a one-basket greens loss
## (value 6) is deductible-bound at 3, while a six-basket loss (value 36) is
## coverage-bound at 28, so both limits are real. Pricing semantics for optional
## insurance are still an open ADR-022 question; these fixed rates are an
## experiment, not a market price.
const COVERAGE_PERMILLE: int = 800
const FLAT_DEDUCTIBLE: int = 3
const PREMIUM_PERMILLE: int = 50
const RULE_VERSION: int = 1

const STATUS_ACTIVE: String = "active"
const STATUS_EXPIRED: String = "expired"
const STATUS_CLAIMED: String = "claimed"
const POLICY_STATUSES: Array[String] = [STATUS_ACTIVE, STATUS_EXPIRED, STATUS_CLAIMED]

const CLAIM_STATUS_PENDING: String = "pending"
const CLAIM_STATUS_PAID: String = "paid"
const CLAIM_STATUSES: Array[String] = [CLAIM_STATUS_PENDING, CLAIM_STATUS_PAID]

const STATE_KEYS: Array[String] = ["policies", "claims"]
const POLICY_KEYS: Array[String] = [
	"policy_id", "owner", "route", "good", "quantity_covered", "premium",
	"coverage", "deductible", "starts_utc", "ends_utc", "status", "claim_id",
]
const CLAIM_KEYS: Array[String] = [
	"id", "policy_id", "owner", "loss_id", "assessed_value", "coverage",
	"deductible", "payout", "created_utc", "paid_utc", "status",
]
const CLAIM_ID_PREFIX: String = "claim_"
const LOSS_ID_PREFIX: String = "loss_"
## Ids this module generates itself are reserved: a caller-chosen policy id in
## either namespace would later collide with a claim or loss event and block a
## payout that the loss evidence already justifies.
const RESERVED_ID_PREFIXES: Array[String] = [CLAIM_ID_PREFIX, LOSS_ID_PREFIX]


static func initial_state() -> Dictionary:
	return {"policies": {}, "claims": {}}


## Canonical route spelling. `Market.LOCATIONS` stays the route authority.
static func route_id(origin: String, destination: String) -> String:
	return origin + ">" + destination


static func valid_route_id(value: Variant) -> bool:
	if not value is String:
		return false
	var parts: PackedStringArray = str(value).split(">", true)
	return parts.size() == 2 and Market.valid_route(parts[0], parts[1])


static func route_parts(value: String) -> Array:
	if not valid_route_id(value):
		return []
	return str(value).split(">", true)


## Fixed terms derived from the catalog reference price and quantity. The same
## function is used by quote, underwriting and document validation, so a row
## cannot be loaded with a premium or coverage the product never quoted.
static func terms(good_id: String, quantity: Variant) -> Dictionary:
	if not Catalog.is_good(good_id) or not _is_positive_count(quantity):
		return {}
	var count: int = int(quantity)
	if count > MAX_QUANTITY:
		return {}
	var unit_value: int = Catalog.base_price(good_id)
	if unit_value <= 0:
		return {}
	var insured_value: int = unit_value * count
	if not _is_count(insured_value):
		return {}
	var coverage: int = insured_value * COVERAGE_PERMILLE / 1000
	var deductible: int = FLAT_DEDUCTIBLE
	var premium: int = maxi(1, coverage * PREMIUM_PERMILLE / 1000)
	return {
		"ok": true, "reason": "", "unit_value": unit_value,
		"insured_value": insured_value, "coverage": coverage,
		"deductible": deductible, "premium": premium,
	}


## Pure quote. `now_utc` only bounds the start instant; the fixed rates never
## depend on time, so the same request quotes the same premium later.
static func quote(route: String, good_id: String, quantity: Variant, starts_utc: Variant,
		ends_utc: Variant, now_utc: Variant = 0.0) -> Dictionary:
	if not valid_route_id(route):
		return _quote_error("invalid_route")
	if not Catalog.is_good(good_id) or Catalog.base_price(good_id) <= 0:
		return _quote_error("invalid_good")
	var priced: Dictionary = terms(good_id, quantity)
	if priced.is_empty():
		return _quote_error("invalid_quantity")
	if not _valid_time(now_utc) or not _valid_time(starts_utc) or not _valid_time(ends_utc):
		return _quote_error("invalid_time")
	if float(starts_utc) < float(now_utc):
		return _quote_error("invalid_start")
	if float(ends_utc) > float(MAX_SAFE_INTEGER):
		return _quote_error("invalid_end")
	var term: float = float(ends_utc) - float(starts_utc)
	if term < MIN_TERM_SECONDS or term > MAX_TERM_SECONDS \
			or not is_equal_approx(term, floorf(term)):
		return _quote_error("invalid_term")
	return {
		"ok": true, "reason": "", "route": route, "good": good_id,
		"quantity_covered": int(quantity), "unit_value": int(priced.unit_value),
		"insured_value": int(priced.insured_value),
		"coverage": int(priced.coverage), "deductible": int(priced.deductible),
		"premium": int(priced.premium), "starts_utc": float(starts_utc),
		"ends_utc": float(ends_utc), "rule_version": RULE_VERSION,
	}


## Writes one policy after charging its premium. The policy row is the durable
## replay guard: an identical retry returns the first result, a different retry
## with the same id is a conflict. All checks run before the premium moves, and
## the stale-policy transition plus the new row cannot fail, so a refusal leaves
## both the economy and the policy table untouched.
static func underwrite(economy: Dictionary, insurance: Dictionary, policy_id: String,
		owner: String, route: String, good_id: String, quantity: Variant,
		starts_utc: Variant, ends_utc: Variant, now_utc: float) -> Dictionary:
	if not _valid_command_id(policy_id):
		return _underwrite_error("invalid_policy")
	if not valid_player(owner):
		return _underwrite_error("invalid_owner")
	if not valid(insurance):
		return _underwrite_error("invalid_state")
	if not _valid_time(now_utc):
		return _underwrite_error("invalid_time")
	var policy_table: Dictionary = insurance.policies
	if policy_table.has(policy_id):
		return _replay_policy(policy_table[policy_id], owner, route, good_id, quantity,
			starts_utc, ends_utc)
	# The premium is paid through the economy command window, so the policy id is
	# also a payment command id there. An earlier accepted command with the same
	# id would make the payment replay instead of moving cash while the policy row
	# is still written, so a used id is refused rather than assumed to be paid.
	if _command_used(economy, policy_id):
		return _underwrite_error("id_in_use")
	var quoted: Dictionary = quote(route, good_id, quantity, starts_utc, ends_utc, now_utc)
	if not quoted.ok:
		return _underwrite_error(str(quoted.reason))
	if policy_table.size() >= MAX_POLICIES:
		return _underwrite_error("policy_limit")
	var accounts: Variant = economy.get("accounts")
	if not _valid_economy(economy):
		return _underwrite_error("invalid_economy")
	var account: Variant = accounts.get(owner)
	if not account is Dictionary:
		return _underwrite_error("unknown_account")
	if not bool(account.get("granted", false)):
		return _underwrite_error("account_not_open")
	if int(account.get("cash", 0)) < int(quoted.premium):
		return _underwrite_error("insufficient")
	if not _live_policy(insurance, owner, now_utc).is_empty():
		return _underwrite_error("policy_active")
	# Goods already in transit departed before this policy could start. Their loss
	# window would begin before the start bound, so selling coverage for them
	# would charge a premium for a claim that must be refused.
	for shipment: Dictionary in Market.shipments(economy):
		if str(shipment.owner) != owner or str(shipment.status) != Market.SHIPMENT_STATUS_TRANSIT \
				or str(shipment.risk) != Market.SHIPMENT_RISK_DECLARED:
			continue
		if route_id(str(shipment.origin), str(shipment.destination)) != route \
				or str(shipment.good) != good_id:
			continue
		if float(shipment.depart_utc) <= float(quoted.starts_utc):
			return _underwrite_error("risk_already_in_transit")
	# A recorded loss on the same good and route shows the risk already
	# materialised. A policy that starts at or before that loss end could cover
	# it, so it is refused even though the claim path would also reject it.
	# Starting strictly after the recorded loss is allowed; no claim can match it.
	for loss: Dictionary in Market.losses(economy):
		if str(loss.victim) != owner or str(loss.good) != good_id:
			continue
		if float(loss.cause_end_utc) < float(quoted.starts_utc):
			continue
		var loss_shipment: Dictionary = Market.shipment(economy, str(loss.shipment_id))
		if loss_shipment.is_empty() \
				or route_id(str(loss_shipment.origin), str(loss_shipment.destination)) == route:
			# An archived shipment row makes the route unverifiable; refusing is the
			# conservative reading.
			return _underwrite_error("loss_already_occurred")
	if _overlapping_quantity(policy_table, route, good_id,
			float(quoted.starts_utc), float(quoted.ends_utc)) \
			+ int(quoted.quantity_covered) > ROUTE_GOOD_QUANTITY_LIMIT:
		return _underwrite_error("route_limit")
	var created_world: bool = _valid_economy(economy) \
		and not economy.accounts.has(WORLD_OWNER)
	if not _ensure_world_account(economy):
		return _underwrite_error("invalid_economy")
	var paid: Dictionary = Economy.pay(economy, owner, WORLD_OWNER, int(quoted.premium),
		policy_id, now_utc)
	if not paid.ok:
		# A refused payment must not leave the helper's zero row behind.
		if created_world and _world_cash(economy) == 0:
			economy.accounts.erase(WORLD_OWNER)
		return _underwrite_error(str(paid.reason))
	# A policy whose window ended does not block a new one. The transition runs
	# after the accepted payment; validation then still sees at most one active
	# policy per owner.
	for row_id: Variant in policy_table:
		var existing: Variant = policy_table[row_id]
		if not existing is Dictionary:
			continue
		if str(existing.owner) == owner and str(existing.status) == STATUS_ACTIVE \
				and float(existing.ends_utc) <= float(now_utc):
			existing.status = STATUS_EXPIRED
	var policy_row: Dictionary = {
		"policy_id": policy_id, "owner": owner, "route": route, "good": good_id,
		"quantity_covered": int(quoted.quantity_covered),
		"premium": int(quoted.premium), "coverage": int(quoted.coverage),
		"deductible": int(quoted.deductible), "starts_utc": float(quoted.starts_utc),
		"ends_utc": float(quoted.ends_utc), "status": STATUS_ACTIVE, "claim_id": "",
	}
	policy_table[policy_id] = policy_row
	return _underwrite_success(policy_row, false)


## Pays one authoritative transport loss. The loss row is read-only here: the
## victim, shipment, good, quantity, window and value all come from
## `economy.losses`, never from the caller. A claim id is derived from the loss
## sequence so an already-claimed loss replays instead of paying twice.
static func claim(economy: Dictionary, insurance: Dictionary, claim_id: String,
		policy_id: String, loss_id: String, now_utc: float) -> Dictionary:
	if not valid(insurance):
		return _claim_error("invalid_state")
	if not _valid_time(now_utc):
		return _claim_error("invalid_time")
	# The claim id is generated by this module (`claim_<loss.n>`), so it is
	# validated by that namespace rather than as a caller-chosen command id.
	if not _valid_claim_id(claim_id):
		return _claim_error("invalid_claim")
	# The claim table is checked before the loss table: a loss event is bounded and
	# can be archived, but a recorded claim must still answer a retry as a
	# duplicate instead of degrading into `unknown_loss`.
	var claim_table: Dictionary = insurance.claims
	var recorded: Variant = claim_table.get(claim_id)
	if recorded is Dictionary:
		# The durable claim row is the replay guard even if the command window and
		# the loss evidence are gone. A different policy or loss cannot take over.
		if str(recorded.policy_id) != policy_id or str(recorded.loss_id) != loss_id:
			return _claim_error("command_conflict")
		return _claim_success(recorded, true)
	var loss: Dictionary = Market.loss(economy, loss_id)
	if loss.is_empty():
		return _claim_error("unknown_loss")
	var derived: String = CLAIM_ID_PREFIX + str(int(loss.sequence))
	if claim_id != derived:
		return _claim_error("invalid_claim_id")
	# The payout uses the claim id as a payment command id. A recorded command of
	# the same id that left no claim row would make the payout replay silently, so
	# it is refused before any policy state changes.
	if _command_used(economy, claim_id):
		return _claim_error("id_in_use")
	var policy_table: Dictionary = insurance.policies
	if not policy_table.get(policy_id) is Dictionary:
		return _claim_error("unknown_policy")
	var policy_row: Dictionary = policy_table[policy_id]
	var checked: Dictionary = _loss_claim_check(economy, policy_row, loss, now_utc)
	if not str(checked.reason).is_empty():
		return _claim_error(str(checked.reason))
	var assessed: int = int(checked.assessed_value)
	var coverage: int = int(policy_row.coverage)
	var deductible: int = int(policy_row.deductible)
	var payout: int = mini(coverage, maxi(0, assessed - deductible))
	var status: String = CLAIM_STATUS_PAID
	var paid_utc: float = float(now_utc)
	if payout > 0:
		if _world_cash(economy) < payout:
			# The pool is short (or does not exist yet): record the claim and
			# leave it pending. No cash is invented and no account is created.
			status = CLAIM_STATUS_PENDING
			paid_utc = 0.0
		else:
			var paid: Dictionary = Economy.pay(economy, WORLD_OWNER, str(policy_row.owner),
				payout, claim_id, now_utc)
			if not paid.ok:
				return _claim_error(str(paid.reason))
	var row: Dictionary = {
		"id": claim_id, "policy_id": policy_id, "owner": str(policy_row.owner),
		"loss_id": loss_id, "assessed_value": assessed, "coverage": coverage,
		"deductible": deductible, "payout": payout,
		"created_utc": float(now_utc), "paid_utc": paid_utc, "status": status,
	}
	claim_table[claim_id] = row
	policy_row.status = STATUS_CLAIMED
	policy_row.claim_id = claim_id
	return _claim_success(row, false)


## Finds the policy that `claim()` would accept for one authoritative loss,
## without touching any state. The caller no longer has to know `policy_id`.
##
## The matching predicate is not restated here: `claim()` and this query both
## call `_loss_claim_check`, so the read path and the write path cannot drift.
## Policies are tried in ascending `policy_id` order and the first one that
## passes is returned. That order is a stable spelling rule, independent of
## Dictionary insertion order or of the mutation order that produced the rows;
## "oldest window" would be a different rule that a caller-chosen id cannot
## encode, and picking by table order would make the answer depend on history.
##
## A recorded claim answers before the loss row is read, because a loss event can
## be archived while its claim row is durable. The claim row itself carries the
## loss id, so the lookup does not depend on the loss row surviving.
static func claimable_policy(economy: Dictionary, insurance: Dictionary,
		loss_id: String, now_utc: float) -> Dictionary:
	if not valid(insurance):
		return _claimable_error("invalid_state")
	if not _valid_time(now_utc):
		return _claimable_error("invalid_time")
	if not _valid_loss_id(loss_id):
		return _claimable_error("invalid_loss")
	for row_value: Variant in insurance.claims.values():
		var claim: Dictionary = row_value
		if str(claim.loss_id) != loss_id:
			continue
		# Already paid or pending: the loss is accounted for, so no policy is
		# claimable. A pending claim is reported the same way because paying it
		# again is exactly what `claim()` refuses.
		var claimed: Dictionary = _claimable_error("already_claimed")
		claimed.claim_id = str(claim.id)
		claimed.policy_id = str(claim.policy_id)
		return claimed
	var loss: Dictionary = Market.loss(economy, loss_id)
	if loss.is_empty():
		return _claimable_error("unknown_loss")
	# Same derivation as `claim()`: the sequence, not the id spelling, names the
	# claim. Under a valid document the two always agree; using the loss row keeps
	# the write path authoritative if a malformed document ever reaches this point.
	var claim_id: String = CLAIM_ID_PREFIX + str(int(loss.sequence))
	if _command_used(economy, claim_id):
		# `claim()` refuses a used payment command before it changes a policy, so a
		# query that ignored the same guard would name a policy that cannot pay.
		return _claimable_error("id_in_use")
	var ids: Array = []
	for row_id: Variant in insurance.policies:
		ids.append(str(row_id))
	ids.sort()
	var first_reason: String = ""
	for policy_id: String in ids:
		# `valid(insurance)` above guarantees every row is a dictionary, so the row
		# is read directly; only the claim predicate can refuse.
		var checked: Dictionary = _loss_claim_check(economy,
			insurance.policies[policy_id], loss, now_utc)
		if str(checked.reason).is_empty():
			var found: Dictionary = _claimable_error("")
			found.ok = true
			found.policy_id = policy_id
			found.claim_id = claim_id
			return found
		if first_reason.is_empty():
			# With one candidate this is exactly the `claim()` refusal reason. With
			# several, the lowest id's reason is reported so the answer stays stable.
			first_reason = str(checked.reason)
	return _claimable_error(first_reason if not first_reason.is_empty() else "no_policy")


## Pays pending claims in creation order while the `@world` pool can cover them.
## A larger claim that cannot be covered is skipped so a smaller later claim can
## still be paid; nothing is reordered and no claim is dropped.
static func settle_claims(economy: Dictionary, insurance: Dictionary,
		now_utc: float) -> Dictionary:
	if not valid(insurance):
		return {"ok": false, "reason": "invalid_state", "count": 0, "paid": []}
	if not _valid_time(now_utc):
		return {"ok": false, "reason": "invalid_time", "count": 0, "paid": []}
	var pending: Array = []
	for claim_id: Variant in insurance.claims:
		var row: Variant = insurance.claims[claim_id]
		if row is Dictionary and str(row.status) == CLAIM_STATUS_PENDING:
			pending.append(row)
	pending.sort_custom(_claim_before)
	var paid_ids: Array = []
	for row: Dictionary in pending:
		if float(row.created_utc) > float(now_utc):
			continue
		var payout: int = int(row.payout)
		if payout > 0:
			if _world_cash(economy) < payout:
				continue
			var paid: Dictionary = Economy.pay(economy, WORLD_OWNER, str(row.owner),
				payout, str(row.id), now_utc)
			if not paid.ok:
				return {"ok": false, "reason": str(paid.reason),
					"count": paid_ids.size(), "paid": paid_ids}
		row.status = CLAIM_STATUS_PAID
		row.paid_utc = float(now_utc)
		paid_ids.append(str(row.id))
	return {"ok": true, "reason": "", "count": paid_ids.size(), "paid": paid_ids}


## Marks every active policy whose window has ended as expired. This is status
## hygiene, not a payout: a claim inside the closed window remains valid because
## the timestamps, not the label, decide coverage.
static func expire(insurance: Dictionary, now_utc: float) -> Dictionary:
	if not valid(insurance):
		return {"ok": false, "reason": "invalid_state", "count": 0, "expired": []}
	if not _valid_time(now_utc):
		return {"ok": false, "reason": "invalid_time", "count": 0, "expired": []}
	var ids: Array = []
	for policy_id: Variant in insurance.policies:
		var row: Variant = insurance.policies[policy_id]
		if row is Dictionary and str(row.status) == STATUS_ACTIVE \
				and float(row.ends_utc) <= float(now_utc):
			row.status = STATUS_EXPIRED
			ids.append(str(policy_id))
	ids.sort()
	return {"ok": true, "reason": "", "count": ids.size(), "expired": ids}


static func policy(insurance: Dictionary, policy_id: String) -> Dictionary:
	var row: Variant = insurance.get("policies", {}).get(policy_id) \
		if insurance.get("policies") is Dictionary else null
	return row.duplicate(true) if row is Dictionary else {}


static func policies(insurance: Dictionary) -> Array:
	var table: Variant = insurance.get("policies")
	if not table is Dictionary:
		return []
	var result: Array = []
	for policy_id: Variant in table:
		result.append(str(policy_id))
	result.sort()
	var rows: Array = []
	for policy_id: String in result:
		rows.append(table[policy_id].duplicate(true))
	return rows


static func claim_row(insurance: Dictionary, claim_id: String) -> Dictionary:
	var row: Variant = insurance.get("claims", {}).get(claim_id) \
		if insurance.get("claims") is Dictionary else null
	return row.duplicate(true) if row is Dictionary else {}


static func claims(insurance: Dictionary) -> Array:
	var table: Variant = insurance.get("claims")
	if not table is Dictionary:
		return []
	var ids: Array = []
	for claim_id: Variant in table:
		ids.append(str(claim_id))
	ids.sort()
	var rows: Array = []
	for claim_id: String in ids:
		rows.append(table[claim_id].duplicate(true))
	return rows


## Strict document validation. Every row is re-derived from the catalog and the
## fixed product terms, cross-links are checked both ways, and the active-policy
## and route/good bounds are enforced. It never reads the economy document, so a
## policy table can be validated without a loss table.
static func valid(insurance: Variant) -> bool:
	if not insurance is Dictionary or insurance.size() != STATE_KEYS.size():
		return false
	for key: String in STATE_KEYS:
		if not insurance.has(key):
			return false
	var policy_table: Variant = insurance.policies
	var claim_table: Variant = insurance.claims
	if not policy_table is Dictionary or policy_table.size() > MAX_POLICIES:
		return false
	# Every claim must link back to a claimed policy, and a policy links to at
	# most one claim, so more claims than policies is already inconsistent.
	if not claim_table is Dictionary or claim_table.size() > policy_table.size():
		return false
	var active_owners: Dictionary = {}
	var ids: Dictionary = {}
	for policy_id: Variant in policy_table:
		var row: Variant = policy_table[policy_id]
		if not _valid_policy(policy_id, row):
			return false
		ids[str(policy_id)] = true
		if str(row.status) == STATUS_ACTIVE:
			if active_owners.has(str(row.owner)):
				return false
			active_owners[str(row.owner)] = true
	var claim_losses: Dictionary = {}
	for claim_id: Variant in claim_table:
		var row: Variant = claim_table[claim_id]
		if not _valid_claim(claim_id, row, policy_table):
			return false
		if ids.has(str(claim_id)):
			# Policy and claim ids share the ledger event namespace; colliding ids
			# would make one event id mean two business rows.
			return false
		ids[str(claim_id)] = true
		var loss_id: String = str(row.loss_id)
		if claim_losses.has(loss_id):
			return false
		claim_losses[loss_id] = true
	for policy_id: Variant in policy_table:
		var row: Dictionary = policy_table[policy_id]
		if str(row.status) == STATUS_CLAIMED:
			var linked: Variant = claim_table.get(str(row.claim_id))
			if not linked is Dictionary or str(linked.policy_id) != str(policy_id):
				return false
		elif not str(row.claim_id).is_empty():
			return false
	# Overlapping windows on one route/good share one coverage budget.
	var rows: Array = policy_table.values()
	for left_index: int in rows.size():
		var left: Dictionary = rows[left_index]
		for right_index: int in range(left_index + 1, rows.size()):
			var right: Dictionary = rows[right_index]
			if str(left.route) != str(right.route) or str(left.good) != str(right.good):
				continue
			if not _overlaps(left, right):
				continue
			if int(left.quantity_covered) + int(right.quantity_covered) > ROUTE_GOOD_QUANTITY_LIMIT:
				return false
	return true


## Converts JSON numbers back to GDScript integers and floats. Row identities,
## statuses and references stay untouched.
static func normalize(insurance: Dictionary) -> void:
	if not insurance.get("policies") is Dictionary:
		insurance.policies = {}
	if not insurance.get("claims") is Dictionary:
		insurance.claims = {}
	for policy_id: String in insurance.policies:
		var row: Dictionary = insurance.policies[policy_id]
		for key: String in ["quantity_covered", "premium", "coverage", "deductible"]:
			if row.has(key):
				row[key] = int(row[key])
		for key: String in ["starts_utc", "ends_utc"]:
			if row.has(key):
				row[key] = float(row[key])
	for claim_id: String in insurance.claims:
		var row: Dictionary = insurance.claims[claim_id]
		for key: String in ["assessed_value", "coverage", "deductible", "payout"]:
			if row.has(key):
				row[key] = int(row[key])
		for key: String in ["created_utc", "paid_utc"]:
			if row.has(key):
				row[key] = float(row[key])


static func valid_player(value: Variant) -> bool:
	return value is String and str(value) != WORLD_OWNER \
		and not OwnerIds.is_organization_account(value) and OwnerIds.valid(value)


static func _valid_policy(policy_id: Variant, value: Variant) -> bool:
	if not value is Dictionary or value.size() != POLICY_KEYS.size():
		return false
	for key: String in POLICY_KEYS:
		if not value.has(key):
			return false
	if not _valid_command_id(policy_id) or str(value.policy_id) != str(policy_id):
		return false
	if not valid_player(value.owner):
		return false
	if not valid_route_id(value.route):
		return false
	if not Catalog.is_good(value.good) or Catalog.base_price(str(value.good)) <= 0:
		return false
	var priced: Dictionary = terms(str(value.good), value.quantity_covered)
	if priced.is_empty():
		return false
	if int(value.premium) != int(priced.premium) \
			or int(value.coverage) != int(priced.coverage) \
			or int(value.deductible) != int(priced.deductible):
		return false
	if not _valid_time(value.starts_utc) or not _valid_time(value.ends_utc):
		return false
	var term: float = float(value.ends_utc) - float(value.starts_utc)
	if term < MIN_TERM_SECONDS or term > MAX_TERM_SECONDS \
			or not is_equal_approx(term, floorf(term)):
		return false
	if str(value.status) not in POLICY_STATUSES:
		return false
	if not value.claim_id is String:
		return false
	if not str(value.claim_id).is_empty() and not _valid_claim_id(str(value.claim_id)):
		return false
	return true


static func _valid_claim(claim_id: Variant, value: Variant, policies: Dictionary) -> bool:
	if not value is Dictionary or value.size() != CLAIM_KEYS.size():
		return false
	for key: String in CLAIM_KEYS:
		if not value.has(key):
			return false
	if not _valid_claim_id(claim_id) or str(value.id) != str(claim_id):
		return false
	if not _valid_loss_id(value.loss_id) \
			or str(value.id) != CLAIM_ID_PREFIX + str(value.loss_id).substr(LOSS_ID_PREFIX.length()):
		return false
	if not valid_player(value.owner):
		return false
	if not _is_positive_count(value.assessed_value):
		return false
	if not _is_count(value.coverage) or not _is_count(value.deductible) \
			or not _is_count(value.payout):
		return false
	var expected: int = mini(int(value.coverage),
		maxi(0, int(value.assessed_value) - int(value.deductible)))
	if int(value.payout) != expected:
		return false
	if str(value.status) not in CLAIM_STATUSES:
		return false
	if not _valid_time(value.created_utc) or not _valid_time(value.paid_utc):
		return false
	if str(value.status) == CLAIM_STATUS_PAID:
		if float(value.paid_utc) < float(value.created_utc):
			return false
	else:
		if float(value.paid_utc) != 0.0:
			return false
	var policy_value: Variant = policies.get(str(value.policy_id))
	if not policy_value is Dictionary:
		return false
	var linked: Dictionary = policy_value
	if str(linked.owner) != str(value.owner) or str(linked.status) != STATUS_CLAIMED \
			or str(linked.claim_id) != str(claim_id):
		return false
	if int(linked.coverage) != int(value.coverage) \
			or int(linked.deductible) != int(value.deductible):
		return false
	return true


## The single matching predicate shared by `claim()` and `claimable_policy()`.
## It reads only the policy row, the loss row and the economy, never a claim
## table, so a caller cannot bypass the claim-id replay guard through it.
## Returns `{reason, assessed_value}`; an empty reason means the policy would be
## accepted for this loss, and `assessed_value` is the catalog-derived value.
static func _loss_claim_check(economy: Dictionary, policy_row: Dictionary,
		loss: Dictionary, now_utc: float) -> Dictionary:
	if str(policy_row.owner) != str(loss.victim):
		return {"reason": "not_victim", "assessed_value": 0}
	if not str(policy_row.claim_id).is_empty() or str(policy_row.status) == STATUS_CLAIMED:
		return {"reason": "policy_claimed", "assessed_value": 0}
	if str(policy_row.status) not in [STATUS_ACTIVE, STATUS_EXPIRED]:
		return {"reason": "policy_inactive", "assessed_value": 0}
	if str(loss.kind) != Market.TRANSPORT_LOSS_KIND:
		return {"reason": "invalid_loss", "assessed_value": 0}
	if str(policy_row.good) != str(loss.good):
		return {"reason": "good_mismatch", "assessed_value": 0}
	if int(loss.quantity) > int(policy_row.quantity_covered):
		return {"reason": "quantity_exceeded", "assessed_value": 0}
	var shipment: Dictionary = Market.shipment(economy, str(loss.shipment_id))
	if shipment.is_empty():
		# A lost shipment row can be archived while its loss event remains. The
		# route is only in the shipment row, so an unverifiable route is refused
		# rather than assumed.
		return {"reason": "shipment_missing", "assessed_value": 0}
	if route_id(str(shipment.origin), str(shipment.destination)) != str(policy_row.route):
		return {"reason": "route_mismatch", "assessed_value": 0}
	if float(now_utc) < float(loss.cause_end_utc):
		return {"reason": "claim_before_loss", "assessed_value": 0}
	# ADR-022: the policy must already be effective strictly before the loss
	# starts and must still be in force at the loss end.
	if not float(policy_row.starts_utc) < float(loss.cause_start_utc) \
			or float(loss.cause_end_utc) > float(policy_row.ends_utc):
		return {"reason": "not_in_force", "assessed_value": 0}
	var unit_value: int = Catalog.base_price(str(loss.good))
	var assessed: int = unit_value * int(loss.quantity)
	if unit_value <= 0 or not _is_count(assessed) \
			or int(loss.unit_value) != unit_value or int(loss.value) != assessed:
		return {"reason": "invalid_loss", "assessed_value": 0}
	return {"reason": "", "assessed_value": assessed}


static func _replay_policy(row: Variant, owner: String, route: String, good_id: String,
		quantity: Variant, starts_utc: Variant, ends_utc: Variant) -> Dictionary:
	if not row is Dictionary:
		return _underwrite_error("command_conflict")
	var stored: Dictionary = row
	if str(stored.owner) != owner or str(stored.route) != route \
			or str(stored.good) != good_id \
			or int(stored.quantity_covered) != int(quantity) \
			or not is_equal_approx(float(stored.starts_utc), float(starts_utc)) \
			or not is_equal_approx(float(stored.ends_utc), float(ends_utc)):
		return _underwrite_error("command_conflict")
	return _underwrite_success(stored, true)


static func _live_policy(insurance: Dictionary, owner: String, now_utc: float) -> Dictionary:
	for row_value: Variant in insurance.policies.values():
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		if str(row.owner) == owner and str(row.status) == STATUS_ACTIVE \
				and float(row.ends_utc) > float(now_utc):
			return row
	return {}


static func _overlapping_quantity(policy_table: Dictionary, route: String, good_id: String,
		starts_utc: float, ends_utc: float) -> int:
	var total: int = 0
	for row_value: Variant in policy_table.values():
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		if str(row.route) != route or str(row.good) != good_id:
			continue
		if not _overlaps_pair(row, starts_utc, ends_utc):
			continue
		total += int(row.quantity_covered)
		if not _is_count(total):
			return MAX_SAFE_INTEGER
	return total


static func _overlaps(left: Dictionary, right: Dictionary) -> bool:
	return _overlaps_pair(left, float(right.starts_utc), float(right.ends_utc))


static func _overlaps_pair(row: Dictionary, starts_utc: float, ends_utc: float) -> bool:
	return float(row.starts_utc) < ends_utc and float(row.ends_utc) > starts_utc


static func _ensure_world_account(economy: Dictionary) -> bool:
	var accounts: Variant = economy.get("accounts")
	if not accounts is Dictionary:
		return false
	if not accounts.get(WORLD_OWNER) is Dictionary:
		# Premiums and payouts need a real cash holder. The empty row issues no
		# money and leaves the ledger checkpoint consistent at zero.
		accounts[WORLD_OWNER] = {"cash": 0, "granted": false}
	return true


## The cash and journal authorities must both exist before a premium is moved.
## `Economy.pay` re-checks them; this refuses early so an invalid document is
## reported as such instead of as a missing account.
static func _valid_economy(economy: Dictionary) -> bool:
	return economy.get("accounts") is Dictionary and economy.get("ledger") is Dictionary


## A command id is durable evidence in the bounded window; a reused one would
## make the premium or payout payment replay instead of moving cash.
static func _command_used(economy: Dictionary, command_id: String) -> bool:
	var results: Variant = economy.get("command_results")
	return results is Dictionary and results.has(command_id)


static func _world_cash(economy: Dictionary) -> int:
	var accounts: Variant = economy.get("accounts")
	if not accounts is Dictionary or not accounts.get(WORLD_OWNER) is Dictionary:
		return 0
	return int(accounts[WORLD_OWNER].get("cash", 0))


static func _valid_claim_id(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = str(value)
	if not text.begins_with(CLAIM_ID_PREFIX):
		return false
	return _is_positive_sequence(text.substr(CLAIM_ID_PREFIX.length()))


static func _valid_loss_id(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = str(value)
	if not text.begins_with(LOSS_ID_PREFIX):
		return false
	return _is_positive_sequence(text.substr(LOSS_ID_PREFIX.length()))


static func _is_positive_sequence(text: String) -> bool:
	if text.is_empty() or text.length() > 18:
		return false
	if text.length() > 1 and text.unicode_at(0) == 48:
		# Canonical spelling only: `loss_01` and `claim_01` would otherwise pass
		# as a second spelling of the same evidence id.
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		if code < 48 or code > 57:
			return false
	return int(text) > 0


static func _valid_command_id(value: Variant) -> bool:
	if not value is String or str(value).is_empty() \
			or str(value).length() > MAX_COMMAND_ID_LENGTH \
			or Ledger.reserved_event_id(str(value)) \
			or Ledger.internal_event_id(str(value)):
		return false
	for prefix: String in RESERVED_ID_PREFIXES:
		if str(value).begins_with(prefix):
			return false
	return true


static func _claim_before(a: Variant, b: Variant) -> bool:
	var left: Dictionary = a
	var right: Dictionary = b
	if float(left.created_utc) != float(right.created_utc):
		return float(left.created_utc) < float(right.created_utc)
	return str(left.id) < str(right.id)


static func _is_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)


static func _is_positive_count(value: Variant) -> bool:
	return _is_count(value) and float(value) > 0.0


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


static func _quote_error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


static func _underwrite_error(reason: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "duplicate": false, "policy_id": "",
		"premium": 0, "coverage": 0, "deductible": 0, "starts_utc": 0.0,
		"ends_utc": 0.0, "status": "",
	}


static func _underwrite_success(policy_row: Dictionary, duplicate: bool) -> Dictionary:
	return {
		"ok": true, "reason": "", "duplicate": duplicate,
		"policy_id": str(policy_row.policy_id), "premium": int(policy_row.premium),
		"coverage": int(policy_row.coverage), "deductible": int(policy_row.deductible),
		"starts_utc": float(policy_row.starts_utc), "ends_utc": float(policy_row.ends_utc),
		"status": str(policy_row.status),
	}


static func _claim_error(reason: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "duplicate": false, "claim_id": "",
		"payout": 0, "status": "", "paid_utc": 0.0,
	}


static func _claim_success(row: Dictionary, duplicate: bool) -> Dictionary:
	return {
		"ok": true, "reason": "", "duplicate": duplicate, "claim_id": str(row.id),
		"payout": int(row.payout), "status": str(row.status),
		"paid_utc": float(row.paid_utc),
	}


static func _claimable_error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "policy_id": "", "claim_id": ""}
