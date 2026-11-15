extends RefCounted
## M7-01 economy ledger and cash accounts. Pure rules: no clock, disk or scene.
##
## The farm snapshot owns this table. Goods stay in the existing player bags and
## public inventory (ADR-005); this module owns cash, the one-time demo
## conversion audit and the idempotent ledger for its own commands.
##
## Every command carries a durable id. A replay returns the recorded result and
## changes nothing. The ledger is a bounded window like the farm command ledger,
## so the two operations that must never repeat even after eviction also keep a
## durable marker: `accounts[owner].granted` and the single `conversion` record.

const Catalog = preload("res://farm/economy_catalog.gd")
const OwnerIds = preload("res://farm/owner_id.gd")
const Market = preload("res://farm/market_state.gd")
const Ledger = preload("res://farm/ledger_state.gd")
const Loans = preload("res://farm/loan_state.gd")

const WORLD_OWNER: String = "@world"
const CURRENCY: String = Catalog.CURRENCY
## Experiment value: enough to join a few trades, not enough to skip a harvest.
const OPENING_GRANT: int = 120
## One-time rule-bank capital. It is issued once, like an opening grant, so the
## bank can fund several small loans without inventing cash per loan.
const BANK_CAPITAL: int = 2000
const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_COMMAND_ID_LENGTH: int = 128
const MAX_PAYLOAD_LENGTH: int = 512
const MAX_COMMAND_RESULTS: int = 64
const STATE_KEYS: Array[String] = [
	"currency", "sequence", "issued", "accounts", "conversion", "command_results", "market",
	"ledger", "bank", "loans", "losses",
]
const BANK_KEYS: Array[String] = ["opened", "opened_by", "opened_utc", "cash", "capital"]
## ADR-027 projected economy. The shape is deliberately smaller than the
## authority document: no ledger, conversion, trade log, loss evidence or
## command window, and only the viewer's own account and contracts.
const VIEW_STATE_KEYS: Array[String] = ["currency", "accounts", "market", "bank", "loans"]
const VIEW_MARKET_KEYS: Array[String] = ["merchant", "orders", "shipments", "deliveries"]
const VIEW_MERCHANT_KEYS: Array[String] = ["opened", "opened_utc", "cash", "goods"]
const VIEW_BANK_KEYS: Array[String] = ["opened", "cash", "capital", "outstanding", "fees"]
const VIEW_ORDER_KEYS: Array[String] = [
	"id", "side", "good", "price", "quantity", "remaining", "filled",
	"reserved", "sequence", "status", "owner_scope",
]
const VIEW_SHIPMENT_KEYS: Array[String] = [
	"id", "sequence", "good", "quantity", "origin", "destination",
	"depart_utc", "arrive_utc", "status", "owner_scope",
]
const VIEW_DELIVERY_KEYS: Array[String] = [
	"id", "sequence", "good", "quantity", "origin", "destination",
	"at_utc", "owner_scope",
]
const VIEW_LOAN_KEYS: Array[String] = [
	"id", "principal", "fee", "due_utc", "status", "owner_scope",
]
const VIEW_OWNER_SCOPES: Array[String] = ["me", "merchant", "other"]


static func initial_state() -> Dictionary:
	return {
		"currency": CURRENCY,
		"sequence": 0,
		"issued": 0,
		"accounts": {},
		"conversion": {},
		"command_results": {},
		"market": Market.initial_state(),
		"ledger": Ledger.initial_state(),
		"bank": initial_bank(),
		"loans": Loans.initial_state(),
		"losses": Market.initial_losses(),
	}


static func initial_bank() -> Dictionary:
	return {"opened": false, "opened_by": "", "opened_utc": 0.0, "cash": 0, "capital": 0}


static func valid_owner(value: Variant) -> bool:
	# `@world` is the public inventory's owner and is not a legal player id, so
	# no member can occupy the same account key.
	return value is String and (value == WORLD_OWNER or OwnerIds.valid(value))


static func valid(state: Variant) -> bool:
	if not state is Dictionary:
		return false
	# An M7-01 economy document has no `market`, an M7 economy has no `ledger`
	# and the M8-02 bank/loans keys came later. Each restores as the empty shape
	# it would have had instead of requiring a migration. Every other key stays
	# mandatory.
	var legacy_market: bool = not state.has("market")
	var legacy_ledger: bool = not state.has("ledger")
	var legacy_bank: bool = not state.has("bank")
	var legacy_loans: bool = not state.has("loans")
	# M8-03a loss evidence came last. A missing `losses` table restores as the
	# empty shape, exactly like the other late subdocuments; a present table is
	# strict and must agree with every `lost` shipment.
	var legacy_losses: bool = not state.has("losses")
	# A missing journal is only genuine for a pre-M8 document. A bank or a
	# contract without its journal is a claim the journal cannot explain, and it
	# would also turn "missing ledger" into a switch that skips reconciliation.
	if legacy_ledger and (not legacy_bank or not legacy_loans):
		return false
	var expected_size: int = STATE_KEYS.size() - (1 if legacy_market else 0) \
		- (1 if legacy_ledger else 0) - (1 if legacy_bank else 0) \
		- (1 if legacy_loans else 0) - (1 if legacy_losses else 0)
	if state.size() != expected_size:
		return false
	for key: String in STATE_KEYS:
		if key == "market" and legacy_market:
			continue
		if key == "ledger" and legacy_ledger:
			continue
		if key == "bank" and legacy_bank:
			continue
		if key == "loans" and legacy_loans:
			continue
		if key == "losses" and legacy_losses:
			continue
		if not state.has(key):
			return false
	if state.currency != CURRENCY:
		return false
	if not _is_count(state.sequence) or int(state.sequence) >= MAX_SAFE_INTEGER \
			or not _is_count(state.issued):
		return false
	if not state.accounts is Dictionary or not state.conversion is Dictionary \
			or not state.command_results is Dictionary:
		return false
	if not Market.valid(state):
		return false
	if not Market.valid_losses(state):
		return false
	if not legacy_ledger and not Ledger.valid(state.ledger):
		return false
	if not legacy_bank and not _valid_bank(state.bank):
		return false
	if legacy_bank:
		# A pre-bank document cannot already carry contracts; that would be a
		# claim without the cash authority backing it.
		if not legacy_loans and not (state.loans is Dictionary and state.loans.is_empty()):
			return false
	elif not legacy_loans and not Loans.valid(state.loans):
		return false
	if not _bank_consistent(state, legacy_bank, legacy_loans):
		return false
	var cash_total: int = Market.merchant_cash(state) + Market.escrowed_cash(state) \
		+ bank_cash(state)
	for owner: Variant in state.accounts:
		if not valid_owner(owner):
			return false
		var account: Variant = state.accounts[owner]
		if not account is Dictionary or (account.size() != 2 and account.size() != 3):
			return false
		if account.size() == 3 and not account.has("pay_seq"):
			# A third key is allowed only for the payment sequence; this keeps
			# the account shape exact instead of letting any extra field in.
			return false
		if not _is_count(account.get("cash")) or not account.get("granted") is bool:
			return false
		# `pay_seq` is the durable replay guard for payments. A document written
		# before it existed omits the key and reads as zero; every other key is
		# still rejected, so the account shape cannot grow arbitrarily.
		if account.has("pay_seq") and not _is_count(account.get("pay_seq")):
			return false
		cash_total += int(account.cash)
		if not _is_count(cash_total):
			return false
	# ADR-012 decision 5: `issued` is the net issuance, so accounts, merchant
	# cash, buy escrow and bank cash must equal it exactly. The check sits outside
	# the loop so an empty accounts table cannot skip it.
	if cash_total != int(state.issued):
		return false
	# A present journal must reproduce every authoritative balance. A legacy
	# document without the key is admitted above and gets an opening checkpoint
	# on restore instead of a migration file.
	if not legacy_ledger and not reconcile(state).ok:
		return false
	if not _valid_conversion(state.conversion):
		return false
	return _valid_results(state.command_results)


## Validates the projected economy a member receives (ADR-027 §2.4). It checks
## table shape, value ranges and owner_scope, but deliberately skips the ledger
## and the cash-conservation identity: the projection carries neither the
## complete accounts table nor the journal, so `valid()` would reject every
## member view. This is a read-only view; it must never be written back as the
## authority document.
static func valid_view(state: Variant, viewer: String) -> bool:
	if not state is Dictionary:
		return false
	var data: Dictionary = state
	if data.size() != VIEW_STATE_KEYS.size():
		return false
	for key: String in VIEW_STATE_KEYS:
		if not data.has(key):
			return false
	if str(data.get("currency", "")) != CURRENCY:
		return false
	if not data.get("accounts") is Dictionary or not data.get("loans") is Dictionary:
		return false
	if not _valid_view_accounts(data.accounts, viewer):
		return false
	if not _valid_view_market(data.get("market")):
		return false
	if not _valid_view_bank(data.get("bank")):
		return false
	return _valid_view_loans(data.loans, viewer)


static func _valid_view_accounts(accounts: Dictionary, viewer: String) -> bool:
	if viewer.is_empty():
		return accounts.is_empty()
	if accounts.size() > 1:
		return false
	for owner: Variant in accounts:
		if str(owner) != viewer or not valid_owner(owner):
			return false
		var account: Variant = accounts[owner]
		if not account is Dictionary or (account.size() != 2 and account.size() != 3):
			return false
		if account.size() == 3 and not account.has("pay_seq"):
			return false
		if not _is_count((account as Dictionary).get("cash")):
			return false
		if not (account as Dictionary).get("granted") is bool:
			return false
		if account.has("pay_seq") and not _is_count(account.get("pay_seq")):
			return false
	return true


static func _valid_view_market(market: Variant) -> bool:
	if not market is Dictionary or market.size() != VIEW_MARKET_KEYS.size():
		return false
	for key: String in VIEW_MARKET_KEYS:
		if not market.has(key):
			return false
	if not _valid_view_merchant(market.merchant):
		return false
	if not market.orders is Dictionary or market.orders.size() > Market.MAX_ORDERS:
		return false
	for order_id: Variant in market.orders:
		if not _valid_view_order(order_id, market.orders[order_id]):
			return false
	if not market.shipments is Dictionary or market.shipments.size() > Market.MAX_SHIPMENTS:
		return false
	for shipment_id: Variant in market.shipments:
		if not _valid_view_shipment(shipment_id, market.shipments[shipment_id]):
			return false
	if not market.deliveries is Dictionary or market.deliveries.size() > Market.MAX_DELIVERIES:
		return false
	for delivery_id: Variant in market.deliveries:
		if not _valid_view_delivery(delivery_id, market.deliveries[delivery_id]):
			return false
	return true


static func _valid_view_merchant(merchant: Variant) -> bool:
	if not merchant is Dictionary or merchant.size() != VIEW_MERCHANT_KEYS.size():
		return false
	for key: String in VIEW_MERCHANT_KEYS:
		if not merchant.has(key):
			return false
	if not (merchant as Dictionary).get("opened") is bool:
		return false
	if not _is_time((merchant as Dictionary).get("opened_utc")):
		return false
	if not _is_count((merchant as Dictionary).get("cash")):
		return false
	if not (merchant as Dictionary).get("goods") is Dictionary:
		return false
	for good_id: Variant in (merchant as Dictionary).goods:
		if not Catalog.goods_ids().has(str(good_id)):
			return false
		if not _is_count((merchant as Dictionary).goods[good_id]):
			return false
	return true


static func _valid_view_order(order_id: Variant, value: Variant) -> bool:
	if not value is Dictionary or value.size() != VIEW_ORDER_KEYS.size():
		return false
	for key: String in VIEW_ORDER_KEYS:
		if not value.has(key):
			return false
	var order: Dictionary = value
	if str(order.get("id", "")) != str(order_id) or str(order.id).is_empty():
		return false
	if not Market.SIDES.has(str(order.get("side", ""))):
		return false
	if not Catalog.goods_ids().has(str(order.get("good", ""))):
		return false
	if not _is_count(order.get("price")) or int(order.price) > Market.MAX_PRICE:
		return false
	for key: String in ["quantity", "remaining", "filled", "reserved", "sequence"]:
		if not _is_count(order.get(key)):
			return false
	if int(order.quantity) > Market.MAX_QUANTITY:
		return false
	if not Market.STATUSES.has(str(order.get("status", ""))):
		return false
	return _valid_view_scope(order.get("owner_scope"))


static func _valid_view_shipment(shipment_id: Variant, value: Variant) -> bool:
	if not value is Dictionary or value.size() != VIEW_SHIPMENT_KEYS.size():
		return false
	for key: String in VIEW_SHIPMENT_KEYS:
		if not value.has(key):
			return false
	var shipment: Dictionary = value
	if str(shipment.get("id", "")) != str(shipment_id) or str(shipment.id).is_empty():
		return false
	if not _is_count(shipment.get("sequence")) or not _is_count(shipment.get("quantity")):
		return false
	if int(shipment.quantity) > Market.MAX_QUANTITY:
		return false
	if not Catalog.goods_ids().has(str(shipment.get("good", ""))):
		return false
	if not Market.LOCATIONS.has(str(shipment.get("origin", ""))) \
			or not Market.LOCATIONS.has(str(shipment.get("destination", ""))):
		return false
	if not _is_time(shipment.get("depart_utc")) or not _is_time(shipment.get("arrive_utc")):
		return false
	if not Market.SHIPMENT_STATUSES.has(str(shipment.get("status", ""))):
		return false
	return _valid_view_scope(shipment.get("owner_scope"))


static func _valid_view_delivery(delivery_id: Variant, value: Variant) -> bool:
	if not value is Dictionary or value.size() != VIEW_DELIVERY_KEYS.size():
		return false
	for key: String in VIEW_DELIVERY_KEYS:
		if not value.has(key):
			return false
	var delivery: Dictionary = value
	if str(delivery.get("id", "")) != str(delivery_id) or str(delivery.id).is_empty():
		return false
	if not _is_count(delivery.get("sequence")) or not _is_count(delivery.get("quantity")):
		return false
	if int(delivery.quantity) > Market.MAX_QUANTITY:
		return false
	if not Catalog.goods_ids().has(str(delivery.get("good", ""))):
		return false
	if not Market.LOCATIONS.has(str(delivery.get("origin", ""))) \
			or not Market.LOCATIONS.has(str(delivery.get("destination", ""))):
		return false
	if not _is_time(delivery.get("at_utc")):
		return false
	return _valid_view_scope(delivery.get("owner_scope"))


static func _valid_view_loans(loans: Dictionary, viewer: String) -> bool:
	if loans.size() > Loans.MAX_LOANS:
		return false
	if not loans.is_empty() and viewer.is_empty():
		return false
	for loan_id: Variant in loans:
		var contract: Variant = loans[loan_id]
		if not contract is Dictionary or contract.size() != VIEW_LOAN_KEYS.size():
			return false
		for key: String in VIEW_LOAN_KEYS:
			if not contract.has(key):
				return false
		if str(contract.get("id", "")) != str(loan_id) or str(contract.id).is_empty():
			return false
		if not _is_count(contract.get("principal")) or not _is_count(contract.get("fee")):
			return false
		if not _is_time(contract.get("due_utc")):
			return false
		if not Loans.STATUSES.has(str(contract.get("status", ""))):
			return false
		# Others' rows are never sent, so every visible contract is the viewer's.
		if str(contract.get("owner_scope", "")) != "me":
			return false
	return true


static func _valid_view_bank(bank: Variant) -> bool:
	if not bank is Dictionary or bank.size() != VIEW_BANK_KEYS.size():
		return false
	for key: String in VIEW_BANK_KEYS:
		if not bank.has(key):
			return false
	if not (bank as Dictionary).get("opened") is bool:
		return false
	for key: String in ["cash", "capital", "outstanding", "fees"]:
		if not _is_count((bank as Dictionary).get(key)):
			return false
	return true


static func _valid_view_scope(value: Variant) -> bool:
	return value is String and VIEW_OWNER_SCOPES.has(value)


static func _is_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


static func cash(state: Dictionary, owner: String) -> int:
	var account: Variant = state.accounts.get(owner)
	return int(account.cash) if account is Dictionary else 0


static func issued(state: Dictionary) -> int:
	return int(state.issued)


static func bank_snapshot(state: Dictionary) -> Dictionary:
	var bank: Variant = state.get("bank")
	return bank.duplicate(true) if bank is Dictionary else initial_bank()


static func bank_cash(state: Dictionary) -> int:
	var bank: Variant = state.get("bank")
	return int(bank.get("cash", 0)) if bank is Dictionary else 0


static func loans_snapshot(state: Dictionary) -> Dictionary:
	var loans: Variant = state.get("loans")
	return loans.duplicate(true) if loans is Dictionary else {}


static func loan(state: Dictionary, loan_id: String) -> Dictionary:
	var loans: Variant = state.get("loans")
	if not loans is Dictionary or not loans.get(loan_id) is Dictionary:
		return {}
	return loans[loan_id].duplicate(true)


static func loans(state: Dictionary) -> Array:
	return Loans.contracts(state)


static func total_cash(state: Dictionary) -> int:
	# Merchant and bank cash are issued money too, so they belong in the
	# conservation view even though neither is a player account.
	var total: int = Market.merchant_cash(state) + Market.escrowed_cash(state) \
		+ bank_cash(state)
	for account: Variant in state.accounts.values():
		if account is Dictionary:
			total += int(account.get("cash", 0))
	return total


## Cash already committed to open buy orders for one owner. This is a derived
## view, not a stored balance: the order rows remain authoritative, and the
## owner's account cash is already the available amount.
static func frozen_cash(state: Dictionary, owner: String) -> int:
	return Market.escrowed_cash_for(state, owner)


## Available plus escrowed cash for one owner. The total is the amount the
## ledger checkpoint should show before an order is placed.
static func funds(state: Dictionary, owner: String) -> Dictionary:
	if not valid_owner(owner) and owner != Market.MERCHANT:
		return {}
	var available: int = Market.merchant_cash(state) if owner == Market.MERCHANT \
		else cash(state, owner)
	var frozen: int = frozen_cash(state, owner)
	return {
		"owner": owner, "available": available, "frozen": frozen,
		"total": available + frozen,
	}


## Compares the journal checkpoint with every authoritative cash holder. A
## successful result also proves the zero-sum identity and the ADR-012 net issue
## equation; a legacy economy without a ledger reports `legacy=true` and is not
## treated as a mismatch.
static func reconcile(state: Dictionary) -> Dictionary:
	if not state.get("ledger") is Dictionary:
		return {
			"ok": true, "reason": "", "legacy": true, "total_cash": total_cash(state),
			"issued": int(state.issued), "issuance": 0, "burned": 0,
			"accounts": 0, "merchant": 0, "escrow": 0, "bank": bank_cash(state),
			"entries": 0, "sequence": 0,
		}
	var ledger: Dictionary = state.ledger
	if not Ledger.valid(ledger):
		return _reconcile_error("invalid_ledger")
	var expected: Dictionary = {}
	var accounts_total: int = 0
	for owner: Variant in state.accounts:
		var account: Variant = state.accounts[owner]
		if account is Dictionary:
			var owner_cash: int = int(account.get("cash", 0))
			expected[Ledger.owner_code(str(owner))] = owner_cash
			accounts_total += owner_cash
	var merchant_cash: int = Market.merchant_cash(state)
	var escrow_cash: int = Market.escrowed_cash(state)
	var bank_balance: int = bank_cash(state)
	expected[Ledger.MERCHANT] = merchant_cash
	expected[Ledger.ESCROW] = escrow_cash
	expected[Ledger.BANK] = bank_balance
	var cash_total: int = accounts_total + merchant_cash + escrow_cash + bank_balance
	for code: Variant in expected:
		if Ledger.balance(ledger, str(code)) != int(expected[code]):
			return _reconcile_error("ledger_balance_mismatch")
	for code: Variant in ledger.balances:
		# A checkpoint for an account that no longer exists would hide cash.
		if Ledger.is_account_code(code) and not expected.has(code):
			return _reconcile_error("unknown_account")
	var issuance: int = -Ledger.balance(ledger, Ledger.ISSUANCE)
	var burned: int = Ledger.balance(ledger, Ledger.BURN)
	if issuance < 0 or burned < 0 or issuance - burned != int(state.issued) \
			or cash_total != int(state.issued):
		return _reconcile_error("ledger_not_conserved")
	return {
		"ok": true, "reason": "", "legacy": false, "total_cash": cash_total,
		"issued": int(state.issued), "issuance": issuance, "burned": burned,
		"accounts": accounts_total, "merchant": merchant_cash, "escrow": escrow_cash,
		"bank": bank_balance,
		"entries": ledger.entries.size(), "sequence": int(ledger.sequence),
	}


## Reserve report for the current slice. M8-02 has no deposits, so the claim
## side is still zero; the report adds the real loan asset (outstanding
## principal), the fees the bank has kept and the bank's cash. This reports
## existing authorities instead of inventing a second wallet.
static func reserve_statement(state: Dictionary) -> Dictionary:
	var report: Dictionary = reconcile(state)
	var accounts_total: int = 0
	for account: Variant in state.accounts.values():
		if account is Dictionary:
			accounts_total += int(account.get("cash", 0))
	var cash_total: int = total_cash(state)
	var claims: int = 0
	var loans_asset: int = Loans.outstanding_principal(state)
	var loan_rows: Array = Loans.contracts(state)
	var overdue: int = 0
	var repaid: int = 0
	for row: Dictionary in loan_rows:
		if str(row.status) == Loans.STATUS_OVERDUE:
			overdue += 1
		elif str(row.status) == Loans.STATUS_REPAID:
			repaid += 1
	var bank_row: Dictionary = bank_snapshot(state)
	return {
		"ok": bool(report.ok), "reason": str(report.get("reason", "")),
		"legacy": bool(report.get("legacy", false)),
		"total_cash": cash_total, "issued": issued(state),
		"accounts": accounts_total, "merchant": Market.merchant_cash(state),
		"escrow": Market.escrowed_cash(state), "bank": bank_cash(state),
		"bank_capital": int(bank_row.get("capital", 0)),
		"loans_asset": loans_asset, "loans": loan_rows.size(),
		"loans_overdue": overdue, "loans_repaid": repaid,
		"issuance": int(report.get("issuance", 0)), "burned": int(report.get("burned", 0)),
		"claims": claims, "reserve": cash_total, "covered": cash_total >= claims,
		"entries": int(report.get("entries", 0)), "sequence": int(report.get("sequence", 0)),
	}


## Issues the rule bank's one-time capital. The bank cash and the balanced
## issuance entry commit together; the `opened` marker is durable, so a replay
## after the command window is evicted still cannot issue a second capital.
static func open_bank(state: Dictionary, command_id: String, now_utc: float) -> Dictionary:
	if not _valid_command_id(command_id):
		return _result(false, "invalid_command", 0)
	if not _valid_time(now_utc):
		return _result(false, "invalid_time", 0)
	var payload: String = JSON.stringify(["open_bank", float(now_utc)])
	var replay: Dictionary = _replay(state, command_id, payload)
	if not replay.is_empty():
		return replay
	var bank: Variant = state.get("bank")
	if bank is Dictionary and bool(bank.get("opened", false)):
		var capital: int = int(bank.get("capital", BANK_CAPITAL))
		return {"ok": true, "reason": "", "amount": capital, "duplicate": true}
	if not bank is Dictionary and bank != null:
		return _result(false, "invalid_bank", 0)
	if bank is Dictionary and not _valid_bank(bank):
		return _result(false, "invalid_bank", 0)
	var ledger: Variant = state.get("ledger")
	if not ledger is Dictionary:
		return _result(false, "invalid_ledger", 0)
	if not _is_count(int(state.issued) + BANK_CAPITAL):
		return _result(false, "invalid_amount", 0)
	var posted: Dictionary = Ledger.post(ledger, Ledger.KIND_BANK_OPEN, command_id, now_utc, [
		Ledger.debit_line(Ledger.BANK, BANK_CAPITAL),
		Ledger.credit_line(Ledger.ISSUANCE, BANK_CAPITAL),
	])
	if not posted.ok:
		return _result(false, str(posted.reason), 0)
	state.bank = {
		"opened": true, "opened_by": command_id, "opened_utc": float(now_utc),
		"cash": BANK_CAPITAL, "capital": BANK_CAPITAL,
	}
	state.issued = int(state.issued) + BANK_CAPITAL
	var stored: Dictionary = {"ok": true, "reason": "", "amount": BANK_CAPITAL}
	_record(state, command_id, payload, stored)
	return {"ok": true, "reason": "", "amount": BANK_CAPITAL, "duplicate": false}


## Thin command entry points for the loan module. FarmState wrappers are added
## separately; keeping the rules here lets the same candidate semantics apply.
static func borrow_loan(state: Dictionary, borrower: String, principal: Variant,
		term: Variant, command_id: String, now_utc: float) -> Dictionary:
	return Loans.borrow(state, borrower, principal, term, command_id, now_utc)


static func repay_loan(state: Dictionary, borrower: String, loan_id: String,
		command_id: String, now_utc: float) -> Dictionary:
	return Loans.repay(state, borrower, loan_id, command_id, now_utc)


static func settle_loans(state: Dictionary, now_utc: float) -> Dictionary:
	return Loans.settle(state, now_utc)


static func ledger_snapshot(state: Dictionary) -> Dictionary:
	var ledger: Variant = state.get("ledger")
	return ledger.duplicate(true) if ledger is Dictionary else Ledger.initial_state()


static func ledger_entries(state: Dictionary) -> Array:
	var ledger: Variant = state.get("ledger")
	return Ledger.entries(ledger) if ledger is Dictionary else []


static func ledger_entry(state: Dictionary, entry_id: String) -> Dictionary:
	var ledger: Variant = state.get("ledger")
	return Ledger.entry(ledger, entry_id) if ledger is Dictionary else {}


static func ledger_balance(state: Dictionary, code: String) -> int:
	var ledger: Variant = state.get("ledger")
	return Ledger.balance(ledger, code) if ledger is Dictionary else 0


## Builds the opening checkpoint for a document written before the ledger
## existed. No journal entry is invented: the snapshot starts with an empty
## journal and a checkpoint equal to the cash authorities it already has, so
## the first new command can reconcile without a migration file.
static func adopt_ledger(state: Dictionary) -> void:
	if state.get("ledger") is Dictionary:
		return
	var balances: Dictionary = {}
	for owner: Variant in state.accounts:
		var account: Variant = state.accounts[owner]
		if account is Dictionary:
			var owner_cash: int = int(account.get("cash", 0))
			if owner_cash != 0:
				balances[Ledger.owner_code(str(owner))] = owner_cash
	var merchant_cash: int = Market.merchant_cash(state)
	if merchant_cash != 0:
		balances[Ledger.MERCHANT] = merchant_cash
	var escrow_cash: int = Market.escrowed_cash(state)
	if escrow_cash != 0:
		balances[Ledger.ESCROW] = escrow_cash
	var bank_balance: int = bank_cash(state)
	if bank_balance != 0:
		balances[Ledger.BANK] = bank_balance
	var net_issued: int = int(state.issued)
	if net_issued != 0:
		# Gross burn history is not recoverable from a pre-ledger document, so
		# the whole net issue starts on the issuance side.
		balances[Ledger.ISSUANCE] = -net_issued
	# With an empty live log, the opening net is the whole checkpoint.
	state.ledger = {"sequence": 0, "entries": {}, "balances": balances,
		"opening": balances.duplicate(true)}


## Restore-time normalization entry used by FarmState. Despite the historical
## name it also gives account `pay_seq`, the M8-02 bank, the loan subdocuments
## and the M8-03a loss table their canonical JSON number types; missing subdocuments become the empty shape
## they would have had, with no migration file and no invented cash or contract.
static func normalize_ledger(state: Dictionary) -> void:
	if not state.get("ledger") is Dictionary:
		adopt_ledger(state)
	Ledger.normalize(state.ledger)
	_normalize_bank(state)
	# `pay_seq` shipped after the first shared-world ledgers, so an earlier
	# document omits it. Zero is the correct default: no payment has been
	# accepted yet, and every positive sequence is newer. The key is only added
	# to account dictionaries, never to the top-level economy document.
	if state.get("accounts") is Dictionary:
		for owner: Variant in state.accounts:
			var account: Variant = state.accounts[owner]
			if account is Dictionary:
				account.pay_seq = int(account.get("pay_seq", 0))
	if not state.get("loans") is Dictionary:
		state.loans = Loans.initial_state()
	Loans.normalize(state.loans)
	# A document written before transport losses restores the empty loss table
	# instead of requiring a migration file. A present table only needs its JSON
	# numbers normalized; the evidence rows themselves are left untouched.
	Market.normalize_losses(state)


static func _normalize_bank(state: Dictionary) -> void:
	if not state.get("bank") is Dictionary:
		state.bank = initial_bank()
		return
	var bank: Dictionary = state.bank
	bank.opened_utc = float(bank.opened_utc)
	bank.cash = int(bank.cash)
	bank.capital = int(bank.capital)


static func _valid_bank(value: Variant) -> bool:
	if not value is Dictionary or value.size() != BANK_KEYS.size():
		return false
	for key: String in BANK_KEYS:
		if not value.has(key):
			return false
	if not value.get("opened") is bool:
		return false
	if not value.get("opened_by") is String:
		return false
	if not _valid_time(value.get("opened_utc")):
		return false
	if not _is_count(value.get("cash")) or not _is_count(value.get("capital")):
		return false
	if bool(value.opened):
		if not _valid_command_id(value.opened_by) or int(value.capital) != BANK_CAPITAL:
			return false
	else:
		if not str(value.opened_by).is_empty() or float(value.opened_utc) != 0.0 \
				or int(value.cash) != 0 or int(value.capital) != 0:
			return false
	return true


## With only the three M8-02 bank cash paths, this equation is exact:
##   bank.cash == capital - outstanding principal + fees already repaid
## A tampered bank cash row or contract table therefore fails validation even
## when total cash and the journal checkpoint were moved together.
static func _bank_consistent(state: Dictionary, legacy_bank: bool, legacy_loans: bool) -> bool:
	var loans: Variant = state.get("loans")
	var has_loans: bool = loans is Dictionary and not loans.is_empty()
	if legacy_bank:
		return not has_loans
	var bank: Variant = state.get("bank")
	if not bank is Dictionary or not bool(bank.get("opened", false)):
		return not has_loans
	if legacy_loans:
		return int(bank.cash) == int(bank.capital)
	var outstanding: int = Loans.outstanding_principal(state)
	var fees: int = Loans.collected_fees(state)
	return int(bank.cash) == int(bank.capital) - outstanding + fees


static func _reconcile_error(reason: String) -> Dictionary:
	return {
		"ok": false, "reason": reason, "legacy": false, "total_cash": 0,
		"issued": 0, "issuance": 0, "burned": 0, "accounts": 0, "merchant": 0,
		"escrow": 0, "bank": 0, "entries": 0, "sequence": 0,
	}


## Issues the one-time opening grant. The owner is supplied by the authority,
## never by the command payload; a second id for an existing owner is refused
## instead of paying twice.
static func open_account(state: Dictionary, owner: String, command_id: String, now_utc: float) -> Dictionary:
	if not _valid_command_id(command_id):
		return _result(false, "invalid_command", 0)
	if not _valid_time(now_utc):
		return _result(false, "invalid_time", 0)
	if not valid_owner(owner) or owner == WORLD_OWNER:
		return _result(false, "invalid_owner", 0)
	var payload: String = JSON.stringify(["open_account", owner, float(now_utc)])
	var replay: Dictionary = _replay(state, command_id, payload)
	if not replay.is_empty():
		return replay
	if state.accounts.has(owner):
		var existing: Variant = state.accounts[owner]
		if existing is Dictionary and bool(existing.get("granted", false)):
			return _result(false, "already_granted", 0)
		# A seller receives settlement proceeds without opening an account. That
		# proceeds-only account is granted=false, so the one-time opening grant is
		# still available exactly once. It is a grant, not a second issuance path.
		if not existing is Dictionary or not _is_count(int(existing.get("cash", 0)) + OPENING_GRANT):
			return _result(false, "invalid_amount", 0)
	if not _is_count(int(state.issued) + OPENING_GRANT):
		return _result(false, "invalid_amount", 0)
	# The entry and the balance move on the same candidate. Validation above
	# means the grant itself cannot fail after the journal accepts it.
	var posted: Dictionary = Ledger.post(state.ledger, Ledger.KIND_OPEN_ACCOUNT, command_id,
		now_utc, [
			Ledger.debit_line(Ledger.owner_code(owner), OPENING_GRANT),
			Ledger.credit_line(Ledger.ISSUANCE, OPENING_GRANT),
		])
	if not posted.ok:
		return _result(false, str(posted.reason), 0)
	if state.accounts.has(owner):
		var existing_account: Dictionary = state.accounts[owner]
		existing_account.cash = int(existing_account.cash) + OPENING_GRANT
		existing_account.granted = true
		existing_account.pay_seq = int(existing_account.get("pay_seq", 0))
	else:
		state.accounts[owner] = {"cash": OPENING_GRANT, "granted": true, "pay_seq": 0}
	state.issued = int(state.issued) + OPENING_GRANT
	var stored: Dictionary = {"ok": true, "reason": "", "amount": OPENING_GRANT}
	_record(state, command_id, payload, stored)
	return {"ok": true, "reason": "", "amount": OPENING_GRANT, "duplicate": false}


## Moves already-issued cash between two accounts. It is the payment primitive
## M7-02 will call after a quote is accepted; it never changes the issued total.
##
## `seq` is the payer's payment sequence. The authoritative command path always
## supplies one: it must be strictly greater than the payer's durable `pay_seq`,
## otherwise the payment is stale. The bounded command window is therefore not
## the replay guard any more: after it evicts the original result, an old `seq`
## still cannot move cash a second time. A `null` sequence is only for direct
## single-player/test callers whose results never cross the command boundary and
## keeps the pre-M9 payload shape so old ledgers still replay.
static func pay(state: Dictionary, from_owner: String, to_owner: String, amount: Variant,
		command_id: String, now_utc: float, seq: Variant = null) -> Dictionary:
	if not _valid_command_id(command_id):
		return _result(false, "invalid_command", 0)
	if not _valid_time(now_utc):
		return _result(false, "invalid_time", 0)
	if not valid_owner(from_owner) or not valid_owner(to_owner) or from_owner == to_owner:
		return _result(false, "invalid_owner", 0)
	if not _is_positive_count(amount):
		return _result(false, "invalid_amount", 0)
	var guarded: bool = seq != null
	if guarded and not _is_positive_count(seq):
		return _result(false, "invalid_sequence", 0)
	var count: int = int(amount)
	var payload_fields: Array = ["pay", from_owner, to_owner, count, float(now_utc)]
	if guarded:
		payload_fields.append(int(seq))
	var payload: String = JSON.stringify(payload_fields)
	# A retry with the same id and sequence must replay the accepted result even
	# though its sequence is no longer greater than `pay_seq`.
	var replay: Dictionary = _replay(state, command_id, payload)
	if not replay.is_empty():
		return replay
	var from_account: Variant = state.accounts.get(from_owner)
	var to_account: Variant = state.accounts.get(to_owner)
	if not from_account is Dictionary or not to_account is Dictionary:
		return _result(false, "unknown_account", 0)
	if guarded and int(seq) <= int(from_account.get("pay_seq", 0)):
		# The durable guard survives command-window eviction. It is checked
		# before the balance so an old retry cannot even be distinguished from a
		# legitimate one by whether it would have been affordable.
		return _result(false, "stale_sequence", 0)
	if int(from_account.cash) < count:
		return _result(false, "insufficient", 0)
	# A transfer is one balanced entry: the receiver is debited and the payer is
	# credited for the same amount, so issued cash does not change.
	var posted: Dictionary = Ledger.post(state.ledger, Ledger.KIND_PAY, command_id, now_utc, [
		Ledger.debit_line(Ledger.owner_code(to_owner), count),
		Ledger.credit_line(Ledger.owner_code(from_owner), count),
	])
	if not posted.ok:
		return _result(false, str(posted.reason), 0)
	from_account.cash = int(from_account.cash) - count
	to_account.cash = int(to_account.cash) + count
	if guarded:
		from_account.pay_seq = int(seq)
	var stored: Dictionary = {"ok": true, "reason": "", "amount": count}
	_record(state, command_id, payload, stored)
	return {"ok": true, "reason": "", "amount": count, "duplicate": false}


## Authority-only transfer used by dispute compensation. Unlike `pay`, the event
## id comes from the authority's reserved `dispute_compensate_` namespace and is
## not recorded in the bounded economy command window: the balanced ledger entry
## is the durable evidence and the dispute document keeps its own paid marker.
## The event id must already be reserved by `Ledger.RESERVED_EVENT_PREFIXES`, so a
## client command id can never collide with an authority compensation entry.
static func authority_pay(state: Dictionary, from_owner: String, to_owner: String,
		amount: Variant, event_id: String, now_utc: float) -> Dictionary:
	if not _valid_time(now_utc):
		return _result(false, "invalid_time", 0)
	if not valid_owner(from_owner) or not valid_owner(to_owner) or from_owner == to_owner:
		return _result(false, "invalid_owner", 0)
	if not _is_positive_count(amount):
		return _result(false, "invalid_amount", 0)
	if event_id.is_empty() or event_id.length() > Ledger.MAX_EVENT_ID_LENGTH:
		return _result(false, "invalid_event", 0)
	var from_account: Variant = state.accounts.get(from_owner)
	var to_account: Variant = state.accounts.get(to_owner)
	if not from_account is Dictionary or not to_account is Dictionary:
		return _result(false, "unknown_account", 0)
	var count: int = int(amount)
	if int(from_account.cash) < count:
		return _result(false, "insufficient", 0)
	# A transfer is one balanced entry: the receiver is debited and the payer is
	# credited for the same amount, so issued cash does not change.
	var posted: Dictionary = Ledger.post(state.ledger, Ledger.KIND_PAY, event_id, now_utc, [
		Ledger.debit_line(Ledger.owner_code(to_owner), count),
		Ledger.credit_line(Ledger.owner_code(from_owner), count),
	])
	if not posted.ok:
		return _result(false, str(posted.reason), 0)
	from_account.cash = int(from_account.cash) - count
	to_account.cash = int(to_account.cash) + count
	return {"ok": true, "reason": "", "amount": count, "duplicate": false}


## Records the opening stock of the existing bags and public inventory. Goods
## are not copied or moved: the existing tables remain the inventory authority.
## The command runs at most once per world, and a replay of the same id and
## source returns the original totals instead of stacking them.
static func convert_demo(state: Dictionary, source: Dictionary, command_id: String,
		now_utc: float) -> Dictionary:
	if not _valid_command_id(command_id):
		return _result(false, "invalid_command", 0)
	if not _valid_time(now_utc):
		return _result(false, "invalid_time", 0)
	var normalized: Dictionary = normalize_source(source)
	if not normalized.ok:
		return _result(false, str(normalized.reason), 0)
	var digest: String = str(normalized.digest)
	var existing: Dictionary = state.conversion
	if not existing.is_empty():
		if str(existing.id) != command_id:
			return _result(false, "already_converted", 0)
		if str(existing.digest) != digest:
			return _result(false, "command_conflict", 0)
		var replay: Dictionary = _replay(state, command_id, _conversion_payload(digest, now_utc))
		if not replay.is_empty():
			return replay
		return {"ok": true, "reason": "", "amount": int(existing.goods_total), "duplicate": true}
	var payload: String = _conversion_payload(digest, now_utc)
	var recorded: Dictionary = _replay(state, command_id, payload)
	if not recorded.is_empty():
		return recorded
	state.conversion = {
		"id": command_id, "digest": digest, "owners": normalized.source,
		"goods_total": int(normalized.total), "at_utc": now_utc,
	}
	var stored: Dictionary = {"ok": true, "reason": "", "amount": int(normalized.total)}
	_record(state, command_id, payload, stored)
	return {"ok": true, "reason": "", "amount": int(normalized.total), "duplicate": false}


## Validates and canonicalizes one declared opening stock. Zero quantities are
## dropped so two equivalent declarations have the same digest; negatives and
## fractional values are refused rather than floored.
static func normalize_source(source: Dictionary) -> Dictionary:
	var normalized: Dictionary = {}
	var total: int = 0
	for owner: Variant in source:
		if not valid_owner(owner):
			return {"ok": false, "reason": "invalid_owner"}
		var goods: Variant = source[owner]
		if not goods is Dictionary:
			return {"ok": false, "reason": "invalid_goods"}
		var clean: Dictionary = {}
		for good_id: Variant in goods:
			if not Catalog.is_good(good_id):
				return {"ok": false, "reason": "invalid_good"}
			var amount: Variant = goods[good_id]
			if not _is_count(amount):
				return {"ok": false, "reason": "invalid_amount"}
			if int(amount) > MAX_SAFE_INTEGER - total:
				return {"ok": false, "reason": "invalid_amount"}
			if int(amount) > 0:
				clean[str(good_id)] = int(amount)
				total += int(amount)
		if not clean.is_empty():
			normalized[str(owner)] = clean
	var text: String = JSON.stringify(normalized, "", true, false)
	return {"ok": true, "source": normalized, "total": total, "digest": _sha256(text)}


## Public bridge for the market slice. Orders own their rules but reuse this
## bounded ledger, so the world keeps one command-id window instead of two.
static func replay(state: Dictionary, command_id: String, payload: String) -> Dictionary:
	return _replay(state, command_id, payload)


static func record(state: Dictionary, command_id: String, payload: String, result: Dictionary) -> void:
	_record(state, command_id, payload, result)


static func _valid_conversion(value: Dictionary) -> bool:
	if value.is_empty():
		return true
	if value.size() != 5:
		return false
	for key: String in ["id", "digest", "owners", "goods_total", "at_utc"]:
		if not value.has(key):
			return false
	if not _valid_command_id(value.id) or not _valid_digest(value.digest):
		return false
	if not _is_count(value.goods_total) or not _valid_time(value.at_utc):
		return false
	if not value.owners is Dictionary:
		return false
	var total: int = 0
	for owner: Variant in value.owners:
		if not valid_owner(owner):
			return false
		var goods: Variant = value.owners[owner]
		if not goods is Dictionary or goods.is_empty():
			return false
		for good_id: Variant in goods:
			if not Catalog.is_good(good_id):
				return false
			var amount: Variant = goods[good_id]
			if not _is_positive_count(amount):
				return false
			total += int(amount)
			if total > MAX_SAFE_INTEGER:
				return false
	return total == int(value.goods_total)


static func _valid_results(value: Dictionary) -> bool:
	if value.size() > MAX_COMMAND_RESULTS:
		return false
	for command_id: Variant in value:
		if not _valid_command_id(command_id):
			return false
		var entry: Variant = value[command_id]
		if not entry is Dictionary or entry.size() != 2:
			return false
		var payload: Variant = entry.get("payload")
		if not payload is String or payload.length() > MAX_PAYLOAD_LENGTH:
			return false
		var result: Variant = entry.get("result")
		if not result is Dictionary or result.size() != 3:
			return false
		if not result.get("ok") is bool or not result.get("reason") is String:
			return false
		if not _is_count(result.get("amount")):
			return false
	return true


static func _replay(state: Dictionary, command_id: String, payload: String) -> Dictionary:
	var results: Dictionary = state.command_results
	if not results.has(command_id):
		return {}
	var entry: Variant = results[command_id]
	if not entry is Dictionary or str(entry.get("payload", "")) != payload:
		return {"ok": false, "reason": "command_conflict", "amount": 0, "duplicate": true}
	var result: Dictionary = entry.result
	return {
		"ok": bool(result.get("ok", false)), "reason": str(result.get("reason", "")),
		"amount": int(result.get("amount", 0)), "duplicate": true,
	}


static func _record(state: Dictionary, command_id: String, payload: String, result: Dictionary) -> void:
	state.sequence = int(state.sequence) + 1
	state.command_results[command_id] = {"payload": payload, "result": result}
	while state.command_results.size() > MAX_COMMAND_RESULTS:
		state.command_results.erase(state.command_results.keys()[0])


static func _conversion_payload(digest: String, now_utc: float) -> String:
	return JSON.stringify(["convert_demo", digest, float(now_utc)])


static func _valid_command_id(value: Variant) -> bool:
	return value is String and not value.is_empty() \
		and value.length() <= MAX_COMMAND_ID_LENGTH \
		and not Ledger.reserved_event_id(value)


static func _valid_digest(value: Variant) -> bool:
	if not value is String or value.length() != 64:
		return false
	for index: int in value.length():
		var code: int = value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 97 and code <= 102)):
			return false
	return true


static func _is_count(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) and number == floorf(number)


static func _is_positive_count(value: Variant) -> bool:
	return _is_count(value) and float(value) > 0.0


static func _valid_time(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


static func _result(ok: bool, reason: String, amount: int) -> Dictionary:
	return {"ok": ok, "reason": reason, "amount": amount, "duplicate": false}


static func _sha256(text: String) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(text.to_utf8_buffer())
	return hashing.finish().hex_encode()
