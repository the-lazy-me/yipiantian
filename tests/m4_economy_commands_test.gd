extends SceneTree
## M9 economy commands over the real authoritative world.
##
## Two named members open accounts, pay each other, trade, cancel, ship,
## deliver, open the bank, borrow and repay. The payer/borrower/owner is always
## the connection's player: a forged `from_id` is refused, and another member
## cannot repay someone else's loan. A visitor keeps only water/weed. The
## authority advances time to trigger expiry and the overdue sweep, a watcher
## proves it receives fresh summaries without asking, and a reopened world
## passes the same validators as the live one.
##
## Roles: --role=host, --role=member. The parent orchestrates.

const WorldHost = preload("res://world/world_host.gd")
const WorldMember = preload("res://world/world_member.gd")
const PLAYER_SECRET: String = "eWlwaWFudGlhbi10ZXN0LXBsYXllci1zZWNyZXQtMTI="
const WorldInvite = preload("res://world/world_invite.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const HeadlessWorld = preload("res://world/headless_world.gd")
const FarmState = preload("res://farm/farm_state.gd")
const Economy = preload("res://farm/economy_state.gd")
const Market = preload("res://farm/market_state.gd")
const Loans = preload("res://farm/loan_state.gd")

const WORLD: String = "world-economy"
const TIMEOUT: float = 25.0
const HOST_LIFETIME: float = 240.0
const START: float = 1800000000.0
const TERM: int = 604800

const PLAYER_A: String = "player_00000000000000000000000000000001"
const PLAYER_B: String = "player_00000000000000000000000000000002"
const PLAYER_V: String = "player_00000000000000000000000000000003"
const PLAYER_RAW: String = "player_00000000000000000000000000000004"
const NAME_A: String = "阿青"
const NAME_B: String = "阿白"
const NAME_V: String = "访客"

const GRANT_A: String = "econ-a"
const GRANT_B: String = "econ-b"
const GRANT_V: String = "econ-v"
const GRANT_W: String = "econ-watch"
const INVITES: Array[String] = ["invite-a.bin", "invite-b.bin", "invite-v.bin", "invite-watch.bin"]

## One valid command per economy kind, used to prove the visitor is refused
## before the rules see any of them.
const ECONOMY_KINDS: Array[String] = [
	"account_open", "pay", "market_open", "market_place", "market_cancel",
	"market_ship", "market_deliver", "bank_open", "loan_borrow", "loan_repay",
]

var role: String = "parent"
var dir: String = ""
var port: int = 0
var url: String = ""
var report_path: String = ""
var who: String = ""
var player_id: String = ""
var display_name: String = ""
var grant_id: String = ""
var invite_name: String = ""
var steps: Array = []
var at_utc: float = START
var deliver_at: float = START
var retry_at: float = START
var watch_stop: String = ""
var no_auth: bool = false

var crypto := Crypto.new()
var host: WorldHost
var member: WorldMember
var checks: int = 0
var failures: Array[String] = []
var join_reason: String = ""
var lost: String = ""
var replies: Dictionary = {}
var step_results: Array = []
var remote_changes: int = 0
var summaries: int = 0
var raw_reply: bool = false


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--dir="): dir = argument.trim_prefix("--dir=")
		elif argument.begins_with("--port="): port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--url="): url = argument.trim_prefix("--url=")
		elif argument.begins_with("--report="): report_path = argument.trim_prefix("--report=")
		elif argument.begins_with("--who="): who = argument.trim_prefix("--who=")
		elif argument.begins_with("--player="): player_id = argument.trim_prefix("--player=")
		elif argument.begins_with("--name="): display_name = argument.trim_prefix("--name=")
		elif argument.begins_with("--grant-id="): grant_id = argument.trim_prefix("--grant-id=")
		elif argument.begins_with("--invite="): invite_name = argument.trim_prefix("--invite=")
		elif argument.begins_with("--steps="):
			steps.assign(argument.trim_prefix("--steps=").split(",", false))
		elif argument.begins_with("--at="): at_utc = argument.trim_prefix("--at=").to_float()
		elif argument.begins_with("--deliver-at="): deliver_at = argument.trim_prefix("--deliver-at=").to_float()
		elif argument.begins_with("--retry-at="): retry_at = argument.trim_prefix("--retry-at=").to_float()
		elif argument.begins_with("--watch-stop="): watch_stop = argument.trim_prefix("--watch-stop=")
		elif argument == "--no-auth": no_auth = true
	_run.call_deferred()


func _run() -> void:
	match role:
		"host": await _run_host()
		"member": await _run_member()
		_: await _run_parent()


# ------------------------------------------------------------------ parent

func _run_parent() -> void:
	dir = _repo().path_join(".local/verification/m4-economy-commands-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var key: CryptoKey = crypto.generate_rsa(2048)
	var cert: X509Certificate = crypto.generate_self_signed_certificate(
		key, "CN=localhost,O=farm,C=CN")
	_expect(key != null and cert != null and key.save(dir.path_join("server.key")) == OK
		and cert.save(dir.path_join("server.crt")) == OK, "Server key and certificate are written")
	for index: int in INVITES.size():
		var file := FileAccess.open(dir.path_join(INVITES[index]), FileAccess.WRITE)
		_expect(file != null, "Invite %d is written" % index)
		if file != null:
			file.store_buffer(crypto.generate_random_bytes(32))
			file.close()
	port = _free_port()
	_expect(port > 0, "A free loopback port is available")
	if not failures.is_empty():
		_finish()
		return
	var host_pid: int = OS.create_process(_exe(), _args_for("host"), false)
	_expect(host_pid > 0, "Host process starts")
	if not await _wait_file(dir.path_join("host.ready"), 30000):
		_expect(false, "Host reports ready")
		_finish()
		return

	# A watcher joins and never submits. Every economy commit and authority
	# sweep must reach it as a fresh summary without a local request.
	var watcher = _launch("watch", _member_args("watch", "watch", "", START, false))
	_expect(watcher.pid > 0, "The watching member starts")
	_expect(await _wait_file(dir.path_join("watcher.ready"), 30000),
		"The watching member reports that it joined")

	# (1) Opening accounts and a payment. B opens first so A has a recipient.
	var b_open: Dictionary = await _run_member_job("b-open", "b", "open", START, false)
	_expect(_ok(b_open, "open"), "Member B opens an account")
	var a_pre: Dictionary = await _run_member_job("a-pre", "a", "harvest,open", START, false)
	_expect(_ok(a_pre, "harvest"), "Member A harvests a mature crop into their own bag")
	_expect(_ok(a_pre, "open"), "Member A opens an account")
	var dump0: Dictionary = await _dump()
	_expect(bool(dump0.get("economy_valid", false)), "The economy stays structurally valid")
	_expect(_cash(dump0, PLAYER_A) == Economy.OPENING_GRANT
		and _cash(dump0, PLAYER_B) == Economy.OPENING_GRANT,
		"Each account received exactly one opening grant")
	_expect(int(dump0.get("issued", -1)) == 2 * Economy.OPENING_GRANT
		and int(dump0.get("total_cash", -1)) == int(dump0.get("issued", -2)),
		"Accounts are conserved before any transfer")

	var a_pay: Dictionary = await _run_member_job("a-pay", "a", "pay,dup_pay", START, false)
	_expect(_ok(a_pay, "pay"), "Member A pays member B")
	_expect(bool((_step_reply(a_pay, "dup_pay")).get("duplicate", false)),
		"Retrying the same payment id and sequence replays instead of paying twice")
	var dump1: Dictionary = await _dump()
	_expect(_cash(dump1, PLAYER_A) == Economy.OPENING_GRANT - 10
		and _cash(dump1, PLAYER_B) == Economy.OPENING_GRANT + 10,
		"The payment debits the connection's player and credits the recipient")
	_expect(_conserved(dump1), "The payment keeps total_cash == issued")

	# A forged sender is a malformed command, not a second identity.
	var forged: Dictionary = await _run_member_job("a-forge", "a", "forge", START, false)
	var forged_reply: Dictionary = _step_reply(forged, "forge")
	_expect(_reply_reason(forged_reply, "pay") == "invalid_command"
		and _reply_reason(forged_reply, "borrow") == "invalid_command",
		"Commands that declare their own payer or borrower are refused")
	var dump_forged: Dictionary = await _dump()
	_expect(_same_economy(dump1, dump_forged), "A forged sender changes no economy state")

	# (2) World-level openings, then a two-member fill and a merchant fill.
	var merchant: Dictionary = await _run_member_job("a-merchant", "a", "merchant", START, false)
	_expect(_ok(merchant, "merchant"), "A member opens the rule merchant once")
	var sell: Dictionary = await _run_member_job("a-sell", "a", "sell", START, false)
	_expect(_ok(sell, "sell"), "Member A places a sell order from their own bag")
	var buys: Dictionary = await _run_member_job("b-buys", "b",
		"buy,dup_buy,merchant_buy", START, false)
	_expect(_ok(buys, "buy"), "Member B's buy order matches A's sell order")
	_expect(bool((_step_reply(buys, "dup_buy")).get("duplicate", false)),
		"Retrying the same buy id replays instead of trading twice")
	_expect(_ok(buys, "merchant_buy"), "Member B buys from the open merchant")
	var dump2: Dictionary = await _dump()
	_expect(_conserved(dump2), "Market fills and the fee burn keep total_cash == issued")
	_expect(_order_status(dump2, "a-sell") == Market.STATUS_FILLED,
		"A's sell order is filled exactly once")
	_expect(_trades_with(dump2, PLAYER_B, PLAYER_A) >= 1,
		"The fill records a trade between the two members")
	_expect(_trades_with(dump2, PLAYER_B, Market.MERCHANT) >= 1,
		"The merchant fill records a trade against the rule merchant")
	_expect(_bag(dump2, PLAYER_B, "greens") == 2,
		"B received one unit from each counterparty")
	_expect(int(dump2.get("trades", []).size()) == 2,
		"Exactly two trades exist after the duplicate retry")

	var dump_before_cancel: Dictionary = await _dump()
	var cancelled: Dictionary = await _run_member_job("a-cancel", "a",
		"cancel_place,cancel", START, false)
	_expect(_ok(cancelled, "cancel_place"), "A can escrow cash in a resting buy order")
	_expect(_ok(cancelled, "cancel"), "A cancels their own order")
	var dump3: Dictionary = await _dump()
	_expect(_order_status(dump3, "a-cancel-order") == Market.STATUS_CANCELLED,
		"The cancelled order closes")
	_expect(_cash(dump3, PLAYER_A) == _cash(dump_before_cancel, PLAYER_A),
		"Cancelling returns the escrow to the owner")
	_expect(_conserved(dump3), "Cancelling keeps total_cash == issued")

	var ship: Dictionary = await _run_member_job("b-ship", "b", "ship", START, false)
	_expect(_ok(ship, "ship"), "B ships goods to the other market")
	var dump_ship: Dictionary = await _dump()
	_expect(_shipment_status(dump_ship, "b-ship") == Market.SHIPMENT_STATUS_TRANSIT,
		"Shipped goods stay in transit before the arrival time")
	_expect(_conserved(dump_ship), "The shipping fee keeps total_cash == issued")
	var deliver: Dictionary = await _run_member_job("b-deliver", "b", "deliver",
		START + 700.0, false)
	_expect(_ok(deliver, "deliver"), "The authority deliver sweep runs")
	var dump4: Dictionary = await _dump()
	_expect(_shipment_status(dump4, "b-ship") == Market.SHIPMENT_STATUS_DELIVERED,
		"The shipment is marked delivered")
	_expect(int(dump4.get("deliveries", []).size()) == 1,
		"One delivery event is recorded")
	_expect(_bag(dump4, PLAYER_B, "greens") == 2,
		"Delivered goods returned to the owner's bag")
	_expect(_conserved(dump4), "Delivery keeps total_cash == issued")

	# (3) Bank and loans. A owns the bank opener and the first loan.
	var bank: Dictionary = await _run_member_job("a-bank", "a", "bank,borrow",
		START + 710.0, false)
	_expect(_ok(bank, "bank"), "A opens the rule bank once")
	_expect(_ok(bank, "borrow"), "A borrows against their own account")
	var dump5: Dictionary = await _dump()
	_expect(int(dump5.get("issued", -1)) == int(dump4.get("issued", 0)) + Economy.BANK_CAPITAL,
		"The bank capital is issued exactly once")
	_expect(_loan_status(dump5, "a-loan") == Loans.STATUS_OPEN,
		"The loan contract is open")
	_expect(_cash(dump5, PLAYER_A) == _cash(dump4, PLAYER_A) + 50,
		"The principal reached the borrower")
	_expect(_conserved(dump5), "Borrowing keeps total_cash == issued")

	var repay_other: Dictionary = await _run_member_job("b-repay-a", "b", "repay_other",
		START + 720.0, false)
	_expect(_reason(repay_other, "repay_other") == "not_borrower",
		"Another member cannot repay A's loan")
	var dump_repay_other: Dictionary = await _dump()
	_expect(_same_economy(dump5, dump_repay_other),
		"A refused repay changes no loan or balance")

	var repay: Dictionary = await _run_member_job("a-repay", "a", "repay",
		START + 730.0, false)
	var fee: int = Loans.fee_for(50)
	var cash_before_repay: int = _cash(dump_repay_other, PLAYER_A)
	_expect(_ok(repay, "repay"), "A repays their own loan")
	var dump6: Dictionary = await _dump()
	_expect(_loan_status(dump6, "a-loan") == Loans.STATUS_REPAID,
		"The repaid contract is closed")
	_expect(_cash(dump6, PLAYER_A) == cash_before_repay - 50 - fee,
		"Repayment charges principal and the fixed fee once")
	_expect(_conserved(dump6), "Repayment keeps total_cash == issued")

	var b_borrow: Dictionary = await _run_member_job("b-borrow", "b", "borrow,dup_borrow",
		START + 740.0, false)
	_expect(_ok(b_borrow, "borrow"), "B borrows after repaying nothing")
	_expect(bool((_step_reply(b_borrow, "dup_borrow")).get("duplicate", false)),
		"Retrying the same borrow id does not lend twice")
	var dump7: Dictionary = await _dump()
	_expect(int(dump7.get("loans", []).size()) == 2, "Two contracts exist, not three")
	_expect(_loan_status(dump7, "b-loan") == Loans.STATUS_OPEN,
		"B's contract is open before its due time")
	_expect(_loan_owner(dump7, "b-loan") == PLAYER_B,
		"The contract names the connection's player as borrower")

	# (4) The visitor has farm permissions but no economic identity.
	var dump_before_visitor: Dictionary = await _dump()
	var visitor: Dictionary = await _run_member_job("v-visit", "v", "weed,water,deny",
		START + 750.0, false)
	_expect(_ok(visitor, "weed"), "A visitor may still weed")
	_expect(_ok(visitor, "water"), "A visitor may still water")
	var denied: Dictionary = _step_reply(visitor, "deny").get("commands", {}) as Dictionary
	var all_forbidden: bool = denied.size() == ECONOMY_KINDS.size()
	for kind: String in ECONOMY_KINDS:
		if not denied.has(kind) or _reply_reason(denied, kind) != "forbidden":
			all_forbidden = false
	_expect(all_forbidden, "Every economy command is forbidden to a visitor")
	var dump_after_visitor: Dictionary = await _dump()
	_expect(_same_economy(dump_before_visitor, dump_after_visitor),
		"Refused visitor commands change no economy state")
	_expect(_cash(dump_after_visitor, PLAYER_V) == -1,
		"The visitor owns no account")

	# (5) Advance to the loan due time. The authority, not a client command,
	# marks the contract overdue.
	var b_loan: Dictionary = _loan(dump7, "b-loan")
	var due: float = float(b_loan.get("due_utc", START)) + 10.0
	var advanced: Dictionary = await _advance(due)
	_expect(bool(advanced.get("ok", false)), "The authority advances to the due time")
	_expect(int(advanced.get("loans_settled", 0)) >= 1,
		"The advance runs the loan sweep")
	var dump8: Dictionary = await _dump()
	_expect(_loan_status(dump8, "b-loan") == Loans.STATUS_OVERDUE,
		"The overdue sweep marks B's contract")
	_expect(_conserved(dump8), "Overdue marking moves no cash")

	# (6) An unauthenticated peer never reaches a command.
	var raw = _launch("raw", _member_args("raw", "raw", "", START, true))
	_expect(raw.pid > 0, "An unauthenticated client starts")
	var raw_report: Dictionary = {}
	if int(raw.pid) > 0 and await _wait_file(str(raw.report), 20000):
		raw_report = _read_json(str(raw.report))
	if int(raw.pid) > 0 and OS.is_process_running(int(raw.pid)):
		OS.kill(int(raw.pid))
		await _wait_process(int(raw.pid), 5000)
	_expect(not raw_report.is_empty(), "The unauthenticated client reports")
	_expect(bool(raw_report.get("no_reply", false)),
		"An unauthenticated submit gets no reply")
	var dump_raw: Dictionary = await _dump()
	_expect(_cash(dump_raw, PLAYER_RAW) == -1,
		"An unauthenticated peer created no account")

	# (7) A reconnected member retries a committed id. It replays; it cannot
	# fork the account or issue a second grant.
	var cash_before_retry: int = _cash(dump_raw, PLAYER_A)
	var issued_before_retry: int = int(dump_raw.get("issued", -1))
	var retry: Dictionary = await _run_member_job("a-retry", "a", "retry_open", due + 20.0, false,
		["--retry-at=" + str(START)])
	_expect(bool((_step_reply(retry, "retry_open")).get("duplicate", false)),
		"A committed id replays as a duplicate after reconnect")
	var dump_retry: Dictionary = await _dump()
	_expect(_cash(dump_retry, PLAYER_A) == cash_before_retry
		and int(dump_retry.get("issued", -2)) == issued_before_retry,
		"The replay issued no second opening grant")

	# (8) The bounded command windows are not the payment replay guard. Evict
	# the committed results, as a long-running world eventually would, then
	# replay A's consumed sequence under the same and a fresh command id.
	var evicted: Dictionary = await _evict()
	_expect(bool(evicted.get("ok", false)) and int(evicted.get("cleared", 0)) > 0,
		"The authority evicts both bounded command windows")
	var dump_evicted: Dictionary = await _dump()
	_expect(_same_economy(dump_retry, dump_evicted),
		"Evicting the replay windows alone changes no economy state")
	var stale_same: Dictionary = await _run_member_job("a-stale-same", "a", "stale_same",
		due + 30.0, false)
	_expect(_reason(stale_same, "stale_same") == "stale_sequence",
		"The same id and consumed sequence is refused as stale after eviction")
	var dump_stale_same: Dictionary = await _dump()
	_expect(_same_economy(dump_evicted, dump_stale_same),
		"A stale same-id retry moves no cash")
	var stale_new: Dictionary = await _run_member_job("a-stale-new", "a", "stale_new",
		due + 40.0, false)
	_expect(_reason(stale_new, "stale_new") == "stale_sequence",
		"A new id with the consumed sequence is also refused as stale")
	var dump_stale_new: Dictionary = await _dump()
	_expect(_same_economy(dump_evicted, dump_stale_new),
		"A stale new-id retry moves no cash")
	var next_pay: Dictionary = await _run_member_job("a-next-pay", "a", "next_pay",
		due + 50.0, false)
	_expect(_ok(next_pay, "next_pay"), "A strictly newer sequence is accepted")
	var dump_next_pay: Dictionary = await _dump()
	_expect(_cash(dump_next_pay, PLAYER_A) == _cash(dump_stale_new, PLAYER_A) - 10
		and _cash(dump_next_pay, PLAYER_B) == _cash(dump_stale_new, PLAYER_B) + 10,
		"The accepted sequence moves exactly one payment")
	_expect(_conserved(dump_next_pay), "The sequenced payment keeps total_cash == issued")

	# (8b) A retry whose result survived only in the economy window is an inner
	# duplicate: no commit, no save, no broadcast, regardless of the farm window.
	var seeded_inner: Dictionary = await _run_member_job("a-inner-pay", "a", "inner_pay",
		due + 60.0, false)
	_expect(_ok(seeded_inner, "inner_pay"), "A payment seeds the economy replay window")
	var before_inner: Dictionary = await _dump()
	var inner_evict: Dictionary = await _evict(true)
	_expect(bool(inner_evict.get("ok", false)),
		"The authority clears only the farm transaction window")
	var seq_before_inner: int = int(before_inner.get("sequence", -1))
	# Same id, same sequence and same timestamp: exactly a client retry.
	var inner_retry: Dictionary = await _run_member_job("a-inner-dup", "a", "stale_farm_window",
		due + 60.0, false)
	var inner_reply: Dictionary = _step_reply(inner_retry, "stale_farm_window")
	_expect(bool(inner_reply.get("duplicate", false)),
		"A retry resolved by the inner economy window is a duplicate")
	_expect(bool(inner_reply.get("ok", false)), "The inner duplicate still reports the original success")
	var after_inner: Dictionary = await _dump()
	_expect(_same_economy(before_inner, after_inner),
		"An inner duplicate changes no economy state")
	_expect(int(after_inner.get("sequence", -2)) == seq_before_inner,
		"An inner duplicate commits no farm event")
	_expect(int(after_inner.get("transaction_commands", -2))
		== int(before_inner.get("transaction_commands", -1)),
		"An inner duplicate does not grow the transaction window")

	# (8c) A command timestamp far beyond the authority clock is refused and
	# moves neither the clock nor any economy state.
	var before_future: Dictionary = await _dump()
	var future: Dictionary = await _run_member_job("a-future", "a", "far_future",
		due + 70.0, false)
	_expect(_reason(future, "far_future") == "time_forwards",
		"A command timestamp far in the future is refused")
	var after_future: Dictionary = await _dump()
	_expect(_same_economy(before_future, after_future),
		"A future-dated command changes no economy state")
	_expect(int(after_future.get("sequence", -2)) == int(before_future.get("sequence", -1)),
		"A future-dated command commits no event")
	_expect(float(after_future.get("now_utc", 0.0)) < due + 1000.0,
		"A client timestamp cannot advance the authority clock")

	# (8d) A payload whose command is not an object is a named refusal. Two
	# attempts prove the peer can repeat it without a script error stopping the
	# authority.
	var before_invalid: Dictionary = await _dump()
	var invalid_payload: Dictionary = await _run_member_job("a-invalid", "a", "invalid_payload",
		due + 80.0, false)
	_expect(_reason(invalid_payload, "invalid_payload") == "invalid_command",
		"A non-object command payload is refused with a reason")
	var invalid_again: Dictionary = await _run_member_job("a-invalid-2", "a", "invalid_payload",
		due + 90.0, false)
	_expect(_reason(invalid_again, "invalid_payload") == "invalid_command",
		"The same hostile payload can be refused again")
	var after_invalid: Dictionary = await _dump()
	_expect(int(after_invalid.get("sequence", -2)) == int(before_invalid.get("sequence", -1)),
		"An invalid payload commits no event")
	_expect(_same_economy(before_invalid, after_invalid),
		"An invalid payload changes no economy state")

	# The watcher learned about the changes without submitting anything.
	_write(dir.path_join("watcher.stop"), "stop")
	var watcher_report: Dictionary = {}
	if await _wait_file(str(watcher.report), 20000):
		watcher_report = _read_json(str(watcher.report))
	if int(watcher.pid) > 0 and OS.is_process_running(int(watcher.pid)):
		OS.kill(int(watcher.pid))
		await _wait_process(int(watcher.pid), 5000)
	_expect(not watcher_report.is_empty(), "The watching member reports")
	_expect(int(watcher_report.get("summaries", 0)) > 1,
		"The watcher received fresh summaries it never requested")
	_expect(int(watcher_report.get("remote_changes", 0)) > 0,
		"The watcher also received the change broadcasts")

	# (8) Stop the authority and reopen the same directory from disk.
	var final_dump: Dictionary = await _dump()
	_expect(bool(final_dump.get("economy_valid", false))
		and bool(final_dump.get("market_valid", false))
		and bool(final_dump.get("loans_valid", false)),
		"The live world passes all three document validators")
	_write(dir.path_join("stop"), "stop")
	await _wait_process(host_pid, 20000)
	# A loaded machine can outlive the wait; the child must not keep serving the
	# directory this test is about to reopen from disk.
	if OS.is_process_running(host_pid):
		OS.kill(host_pid)
		await _wait_process(host_pid, 5000)
	var reopened := HeadlessWorld.new()
	var opened: Dictionary = reopened.open(dir.path_join("world"), due + 1000.0)
	_expect(bool(opened.get("ok", false)), "The stopped world reopens from disk")
	if bool(opened.get("ok", false)):
		var econ: Dictionary = reopened.farm.economy_snapshot()
		_expect(Economy.valid(econ), "The restored economy document is valid")
		_expect(Market.valid(econ), "The restored market document is valid")
		_expect(Loans.valid(econ.get("loans", {})), "The restored loan document is valid")
		_expect(_accounts_key(_accounts(reopened.farm.economy_snapshot()))
			== _accounts_key(_accounts(final_dump)),
			"Every balance is identical after restart")
		_expect(int(reopened.farm.economy_issued()) == int(final_dump.get("issued", -1)),
			"The issued total is identical after restart")
		_expect(_loans_key(econ.get("loans", {})) == _loans_key(final_dump.get("loans", [])),
			"Every contract is identical after restart")
		_expect(_orders_key(reopened.farm.market_orders()) == _orders_key(final_dump.get("orders", [])),
			"Every order is identical after restart")
		var reconciled: Dictionary = reopened.farm.economy_reconcile()
		_expect(bool(reconciled.get("ok", false)), "The restored ledger reconciles")
	_finish()


func _run_member_job(label: String, job_who: String, step_text: String,
		at: float, raw: bool, extra: Array = []) -> Dictionary:
	var report: String = dir.path_join("member-%s.json" % label)
	var args: PackedStringArray = _member_args(label, job_who, step_text, at, raw)
	for value: String in extra:
		args.append(value)
	var pid: int = OS.create_process(_exe(), args, false)
	_expect(pid > 0, "Member process '%s' starts" % label)
	var parsed: Dictionary = {}
	if pid > 0 and await _wait_file(report, int((TIMEOUT + 20.0) * 1000.0)):
		parsed = _read_json(report)
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
		await _wait_process(pid, 5000)
	_expect(not parsed.is_empty(), "Member process '%s' reports a result" % label)
	if not parsed.is_empty():
		print("M4_ECONOMY_COMMANDS_MEMBER %s %s" % [label, JSON.stringify(parsed)])
		if not str(parsed.get("reason", "")).is_empty():
			_expect(false, "Member '%s' kept its authority (%s)" % [label, str(parsed.reason)])
	return parsed


func _member_args(label: String, job_who: String, step_text: String,
		at: float, raw: bool) -> PackedStringArray:
	var args := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join("tests/m4_economy_commands_test.gd"),
		"--", "--role=member", "--dir=" + dir, "--port=%d" % port,
		"--url=wss://127.0.0.1:%d" % port, "--world=" + WORLD,
		"--who=" + job_who, "--at=%f" % at,
		"--report=" + dir.path_join("member-%s.json" % label),
	])
	if raw:
		args.append("--no-auth")
		args.append("--player=" + PLAYER_RAW)
		args.append("--name=raw")
		return args
	args.append("--invite=" + _invite_for(job_who))
	args.append("--grant-id=" + _grant_for(job_who))
	args.append("--steps=" + step_text)
	args.append("--player=" + _player_for(job_who))
	args.append("--name=" + _name_for(job_who))
	args.append("--deliver-at=%f" % (START + 700.0))
	if job_who == "watch":
		args.append("--watch-stop=" + dir.path_join("watcher.stop"))
	return args


func _launch(label: String, args: PackedStringArray) -> Dictionary:
	return {"pid": OS.create_process(_exe(), args, false),
		"report": dir.path_join("member-%s.json" % label)}


# -------------------------------------------------------------------- host

func _run_host() -> void:
	var key := CryptoKey.new()
	var cert := X509Certificate.new()
	if key.load(dir.path_join("server.key")) != OK or cert.load(dir.path_join("server.crt")) != OK:
		_host_fail("certificate")
		return
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_server(port, "127.0.0.1", TLSOptions.server(key, cert)) != OK:
		_host_fail("listen")
		return
	root.multiplayer.multiplayer_peer = peer
	host = WorldHost.new()
	host.name = WorldHost.SESSION_NODE_NAME
	root.add_child(host)
	var opened: Dictionary = host.configure(dir.path_join("world"), START, WORLD)
	if not opened.ok:
		_host_fail("open_" + str(opened.reason))
		return
	var grant_roles: Array = [
		[GRANT_A, "invite-a.bin", WorldInvite.MEMBER],
		[GRANT_B, "invite-b.bin", WorldInvite.MEMBER],
		[GRANT_V, "invite-v.bin", WorldInvite.VISITOR],
		[GRANT_W, "invite-watch.bin", WorldInvite.MEMBER],
	]
	for row: Array in grant_roles:
		var file := FileAccess.open(dir.path_join(str(row[1])), FileAccess.READ)
		if file == null:
			_host_fail("invite_" + str(row[1]))
			return
		var secret: PackedByteArray = file.get_buffer(file.get_length())
		file.close()
		var granted: Dictionary = host.add_grant(
			WorldInvite.make(str(row[0]), secret, str(row[2]), WORLD, 0.0, false))
		if not granted.ok:
			_host_fail("grant_" + str(granted.reason))
			return
	_write(dir.path_join("host.ready"), "ready")
	var deadline: int = Time.get_ticks_msec() + int(HOST_LIFETIME * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(dir.path_join("stop")):
			break
		if FileAccess.file_exists(dir.path_join("advance")):
			var target: float = FileAccess.get_file_as_string(dir.path_join("advance")).to_float()
			var advanced: Dictionary = host.world.advance_to(target)
			var saved: Dictionary = host.world.save()
			_write(dir.path_join("advance.done"), JSON.stringify({
				"ok": bool(advanced.get("ok", false)) and bool(saved.ok),
				"reason": str(advanced.get("reason", "")),
				"loans_settled": int(advanced.get("loans_settled", 0)),
				"market_expired": int(advanced.get("market_expired", 0)),
				"market_matched": int(advanced.get("market_matched", 0)),
				"market_delivered": int(advanced.get("market_delivered", 0)),
			}))
			DirAccess.remove_absolute(dir.path_join("advance"))
		if FileAccess.file_exists(dir.path_join("evict")):
			var cleared: int = 0
			var farm_only: bool = FileAccess.file_exists(dir.path_join("evict.farm-only"))
			var farm_state: Variant = host.world.farm
			if farm_state != null and farm_state._data is Dictionary:
				var transaction: Variant = farm_state._data.get("transaction")
				if transaction is Dictionary and transaction.get("command_results") is Dictionary:
					var results: Dictionary = transaction.command_results
					cleared += results.size()
					results.clear()
				if not farm_only:
					var economy: Variant = farm_state._data.get("economy")
					if economy is Dictionary and economy.get("command_results") is Dictionary:
						var economy_results: Dictionary = economy.command_results
						cleared += economy_results.size()
						economy_results.clear()
			var evict_saved: Dictionary = host.world.save()
			_write(dir.path_join("evict.done"), JSON.stringify({
				"ok": bool(evict_saved.ok), "cleared": cleared,
			}))
			DirAccess.remove_absolute(dir.path_join("evict"))
			DirAccess.remove_absolute(dir.path_join("evict.farm-only"))
		if FileAccess.file_exists(dir.path_join("dump")):
			_write(dir.path_join("state.json"), JSON.stringify(_dump_state()))
			DirAccess.remove_absolute(dir.path_join("dump"))
		await create_timer(0.05).timeout
	host.world.save()
	_write(dir.path_join("host.json"), JSON.stringify({
		"sequence": host.world.farm.event_sequence() if host.world.farm != null else 0,
		"commands": host.world.farm.committed_command_count() if host.world.farm != null else 0,
	}))
	quit(0)


func _dump_state() -> Dictionary:
	if host == null or host.world == null or host.world.farm == null:
		return {"error": "not_open"}
	var farm = host.world.farm
	var econ: Dictionary = farm.economy_snapshot()
	return {
		"sequence": farm.event_sequence(),
		"now_utc": host.world.now_utc,
		"transaction_commands": int(farm._data.transaction.sequence),
		"accounts": econ.get("accounts", {}),
		"issued": farm.economy_issued(),
		"total_cash": farm.economy_total_cash(),
		"orders": farm.market_orders(),
		"trades": farm.market_trades(),
		"shipments": farm.market_shipments(),
		"deliveries": farm.market_deliveries(),
		"loans": farm.economy_loans(),
		"bank": farm.economy_bank(),
		"merchant": farm.market_merchant(),
		"bags": farm.snapshot().get("bags", {}),
		"economy_valid": Economy.valid(econ),
		"market_valid": Market.valid(econ),
		"loans_valid": Loans.valid(econ.get("loans", {})),
		"reconcile": farm.economy_reconcile(),
	}


func _host_fail(reason: String) -> void:
	_write(dir.path_join("host.json"), JSON.stringify({"error": reason}))
	quit(1)


# ------------------------------------------------------------------ member

func _run_member() -> void:
	var cert := X509Certificate.new()
	var text: String = FileAccess.get_file_as_string(dir.path_join("server.crt"))
	if text.is_empty() or cert.load_from_string(text) != OK:
		_report({"joined": false, "reason": "cert_load"})
		return
	var secret: PackedByteArray = PackedByteArray()
	if not invite_name.is_empty():
		var file := FileAccess.open(dir.path_join(invite_name), FileAccess.READ)
		if file == null:
			_report({"joined": false, "reason": "invite_load"})
			return
		secret = file.get_buffer(file.get_length())
		file.close()
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client(url, TLSOptions.client(cert, "localhost")) != OK:
		_report({"joined": false, "reason": "create_client"})
		return
	root.multiplayer.multiplayer_peer = peer
	member = WorldMember.new()
	member.name = WorldMember.SESSION_NODE_NAME
	member.secret = secret
	member.grant_id = grant_id
	member.world_id = WORLD
	member.player_id = player_id
	member.player_secret = Marshalls.base64_to_raw(PLAYER_SECRET)
	member.display_name = display_name
	root.add_child(member)
	member.join_failed.connect(func(reason: String) -> void: join_reason = reason)
	member.authority_lost.connect(func(reason: String) -> void: lost = reason)
	member.reply_received.connect(func(request_id: String, payload: Dictionary) -> void:
		replies[request_id] = payload
		if request_id == "summary":
			summaries += 1
		if no_auth:
			raw_reply = true)
	member.remote_change.connect(func(_entry: Dictionary) -> void:
		remote_changes += 1)

	if no_auth:
		await _run_unauthenticated()
		return
	root.multiplayer.auth_callback = _member_auth
	member.connect_to(url, secret, WORLD)
	var started: bool = false
	var ran: bool = false
	var deadline: int = Time.get_ticks_msec() + int(TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if not started and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			started = true
			root.multiplayer.send_auth(1, member.auth_hello())
		if member.is_joined() and not ran:
			ran = true
			if steps.is_empty() and not watch_stop.is_empty():
				_write(dir.path_join("watcher.ready"), "ready")
				await _watch_until_stop()
			else:
				step_results = await _run_steps()
			await create_timer(0.5).timeout
			break
		if not join_reason.is_empty() or not lost.is_empty():
			await create_timer(0.2).timeout
			break
		await create_timer(0.05).timeout
	_report({
		"who": who, "joined": member.is_joined(),
		"reason": join_reason if not join_reason.is_empty() else lost,
		"last_sequence": member.last_sequence,
		"summaries": summaries, "remote_changes": remote_changes,
		"steps": step_results,
	})


func _run_unauthenticated() -> void:
	var deadline: int = Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		if root.multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			break
		await create_timer(0.05).timeout
	var command: Dictionary = FarmCommand.make_account_open("raw-open", START)
	member.submit.rpc_id(1, JSON.stringify({
		"request_id": "raw-open", "command": command, "based_on_sequence": 0,
	}))
	await create_timer(2.5).timeout
	_report({"who": who, "joined": false, "reason": "", "no_reply": not raw_reply,
		"summaries": summaries, "remote_changes": remote_changes, "steps": []})


func _watch_until_stop() -> void:
	var deadline: int = Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(watch_stop):
			return
		await create_timer(0.05).timeout


func _run_steps() -> Array:
	var results: Array = []
	for step: String in steps:
		if step.is_empty():
			continue
		results.append({"step": step, "reply": await _do_step(step)})
	return results


func _do_step(step: String) -> Dictionary:
	match step:
		"harvest":
			return await _send(FarmCommand.make("a-harvest", "field_03", "cell_06", at_utc))
		"open":
			return await _send(FarmCommand.make_account_open(who + "-open", at_utc))
		"pay":
			return await _send(FarmCommand.make_pay("a-pay", PLAYER_B, 10, 1, at_utc))
		"dup_pay":
			# Same id and sequence while both windows still hold the result.
			return await _send(FarmCommand.make_pay("a-pay", PLAYER_B, 10, 1, at_utc))
		"stale_same":
			# Same id and sequence after the authority evicted both windows.
			return await _send(FarmCommand.make_pay("a-pay", PLAYER_B, 10, 1, at_utc))
		"stale_new":
			# A fresh id cannot smuggle the already-consumed sequence through.
			return await _send(FarmCommand.make_pay("a-pay-stale", PLAYER_B, 10, 1, at_utc))
		"next_pay":
			return await _send(FarmCommand.make_pay("a-pay-next", PLAYER_B, 10, 2, at_utc))
		"stale_farm_window":
			# The farm transaction window is cleared but the economy window still
			# holds the accepted result: the inner rule resolves this as a
			# duplicate, so the authority must not commit, save or broadcast.
			return await _send(FarmCommand.make_pay("a-inner-pay", PLAYER_B, 7, 3, at_utc))
		"inner_pay":
			return await _send(FarmCommand.make_pay("a-inner-pay", PLAYER_B, 7, 3, at_utc))
		"far_future":
			# A command timestamp far beyond the server's own clock must be refused
			# without changing any state or advancing the authority's time.
			return await _send(FarmCommand.make_account_open(who + "-future",
				at_utc + 10000000.0))
		"invalid_payload":
			# A hostile peer can send any JSON type. It must be a named refusal, not
			# a script error the peer can trigger again and again.
			return await _raw_submit("a-invalid-payload", "not-a-command")
		"merchant":
			return await _send(FarmCommand.make_market_open("market-open", at_utc))
		"sell":
			return await _send(FarmCommand.make_market_place("a-sell", Market.SIDE_SELL,
				"greens", 6, 1, at_utc + 7200.0, at_utc))
		"buy":
			return await _send(FarmCommand.make_market_place("b-buy", Market.SIDE_BUY,
				"greens", 6, 1, at_utc + 7200.0, at_utc))
		"dup_buy":
			return await _send(FarmCommand.make_market_place("b-buy", Market.SIDE_BUY,
				"greens", 6, 1, at_utc + 7200.0, at_utc))
		"merchant_buy":
			return await _send(FarmCommand.make_market_place("b-merchant-buy", Market.SIDE_BUY,
				"greens", Market.merchant_ask_price("greens"), 1, at_utc + 7200.0, at_utc))
		"cancel_place":
			return await _send(FarmCommand.make_market_place("a-cancel-order", Market.SIDE_BUY,
				"greens", 1, 1, at_utc + 7200.0, at_utc))
		"cancel":
			return await _send(FarmCommand.make_market_cancel("a-cancel-op", "a-cancel-order", at_utc))
		"ship":
			return await _send(FarmCommand.make_market_ship("b-ship", Market.LOCATION_FARM,
				Market.LOCATION_HARBOR, "greens", 1, at_utc))
		"deliver":
			return await _send(FarmCommand.make_market_deliver("b-deliver", deliver_at))
		"bank":
			return await _send(FarmCommand.make_bank_open("bank-open", at_utc))
		"borrow":
			return await _send(FarmCommand.make_loan_borrow(who + "-loan", 50 if who == "a" else 20,
				TERM, at_utc))
		"dup_borrow":
			return await _send(FarmCommand.make_loan_borrow(who + "-loan", 50 if who == "a" else 20,
				TERM, at_utc))
		"repay_other":
			return await _send(FarmCommand.make_loan_repay("b-repay-a", "a-loan", at_utc))
		"repay":
			return await _send(FarmCommand.make_loan_repay(who + "-repay", who + "-loan", at_utc))
		"retry_open":
			return await _send(FarmCommand.make_account_open(who + "-open", retry_at))
		"weed":
			return await _send(FarmCommand.make_tidy(who + "-weed", FarmCommand.WEED,
				"field_06", "cell_13", at_utc))
		"water":
			return await _send(FarmCommand.make_water(who + "-water", "field_05", "cell_06", at_utc))
		"forge":
			var pay_command: Dictionary = FarmCommand.make_pay("a-forge-pay", PLAYER_B, 10, 1, at_utc)
			pay_command["from_id"] = PLAYER_A
			var borrow_command: Dictionary = FarmCommand.make_loan_borrow("b-forge-borrow", 10,
				TERM, at_utc)
			borrow_command["borrower"] = PLAYER_A
			return {"pay": await _raw_submit("a-forge-pay", pay_command),
				"borrow": await _raw_submit("b-forge-borrow", borrow_command)}
		"deny":
			var commands: Dictionary = {}
			for kind: String in ECONOMY_KINDS:
				var command: Dictionary = _deny_command(kind)
				commands[kind] = await _send(command)
			return {"commands": commands}
	return {"ok": false, "reason": "unknown_step"}


func _deny_command(kind: String) -> Dictionary:
	var id: String = "v-deny-" + kind
	match kind:
		"account_open":
			return FarmCommand.make_account_open(id, at_utc)
		"pay":
			return FarmCommand.make_pay(id, PLAYER_A, 1, 1, at_utc)
		"market_open":
			return FarmCommand.make_market_open(id, at_utc)
		"market_place":
			return FarmCommand.make_market_place(id, Market.SIDE_SELL, "greens", 1, 1,
				at_utc + 3600.0, at_utc)
		"market_cancel":
			return FarmCommand.make_market_cancel(id, "b-buy", at_utc)
		"market_ship":
			return FarmCommand.make_market_ship(id, Market.LOCATION_FARM, Market.LOCATION_HARBOR,
				"greens", 1, at_utc)
		"market_deliver":
			return FarmCommand.make_market_deliver(id, at_utc)
		"bank_open":
			return FarmCommand.make_bank_open(id, at_utc)
		"loan_borrow":
			return FarmCommand.make_loan_borrow(id, 10, TERM, at_utc)
		"loan_repay":
			return FarmCommand.make_loan_repay(id, "b-loan", at_utc)
	return {}


func _send(command: Dictionary) -> Dictionary:
	var request_id: String = str(command.get("id", ""))
	replies.erase(request_id)
	var sent: Dictionary = member.submit_command(command)
	if not bool(sent.get("ok", false)):
		return {"ok": false, "reason": str(sent.get("reason", "")), "not_sent": true}
	return await _wait_reply(request_id)


func _raw_submit(request_id: String, command: Variant) -> Dictionary:
	replies.erase(request_id)
	member.submit.rpc_id(1, JSON.stringify({
		"request_id": request_id, "command": command,
		"based_on_sequence": member.last_sequence,
	}))
	return await _wait_reply(request_id)


func _wait_reply(request_id: String, timeout_ms: int = 8000) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if replies.has(request_id):
			return replies[request_id] as Dictionary
		if not join_reason.is_empty() or not lost.is_empty():
			break
		await create_timer(0.03).timeout
	return {}


func _member_auth(_id: int, data: PackedByteArray) -> void:
	root.multiplayer.send_auth(1,
		crypto.hmac_digest(HashingContext.HASH_SHA256, member.secret, data))
	root.multiplayer.complete_auth(1)


# ------------------------------------------------------------------ shared

func _report(payload: Dictionary) -> void:
	if not report_path.is_empty():
		_write(report_path, JSON.stringify(payload))
	print("M4_ECONOMY_COMMANDS " + JSON.stringify(payload))
	quit(0)


func _invite_for(job_who: String) -> String:
	match job_who:
		"a": return "invite-a.bin"
		"b": return "invite-b.bin"
		"v": return "invite-v.bin"
	return "invite-watch.bin"


func _grant_for(job_who: String) -> String:
	match job_who:
		"a": return GRANT_A
		"b": return GRANT_B
		"v": return GRANT_V
	return GRANT_W


func _player_for(job_who: String) -> String:
	match job_who:
		"a": return PLAYER_A
		"b": return PLAYER_B
		"v": return PLAYER_V
		"watch": return "player_00000000000000000000000000000005"
	return PLAYER_RAW


func _name_for(job_who: String) -> String:
	match job_who:
		"a": return NAME_A
		"b": return NAME_B
		"v": return NAME_V
	return "观察者"


func _ok(report: Dictionary, step: String) -> bool:
	var reply: Dictionary = _step_reply(report, step)
	return bool(reply.get("ok", false))


func _reason(report: Dictionary, step: String) -> String:
	return str(_step_reply(report, step).get("reason", ""))


## Reads a reason from a nested reply map (a forge step's `pay`/`borrow`, or a
## deny step's `commands` map).
func _reply_reason(replies: Dictionary, key: String) -> String:
	var reply: Variant = replies.get(key, null)
	return str((reply as Dictionary).get("reason", "")) if reply is Dictionary else ""


func _step_reply(report: Dictionary, step: String) -> Dictionary:
	for row: Variant in report.get("steps", []):
		if row is Dictionary and str(row.get("step", "")) == step:
			var reply: Variant = row.get("reply")
			return reply as Dictionary if reply is Dictionary else {}
	return {}


func _accounts(dump: Dictionary) -> Dictionary:
	var value: Variant = dump.get("accounts", {})
	return value if value is Dictionary else {}


func _cash(dump: Dictionary, player: String) -> int:
	var account: Variant = _accounts(dump).get(player, null)
	return int((account as Dictionary).get("cash", -1)) if account is Dictionary else -1


func _conserved(dump: Dictionary) -> bool:
	var issued: int = int(dump.get("issued", -1))
	return issued >= 0 and int(dump.get("total_cash", -2)) == issued


func _order_status(dump: Dictionary, order_id: String) -> String:
	for row: Variant in dump.get("orders", []):
		if row is Dictionary and str(row.get("id", "")) == order_id:
			return str(row.get("status", ""))
	return ""


func _shipment_status(dump: Dictionary, shipment_id: String) -> String:
	for row: Variant in dump.get("shipments", []):
		if row is Dictionary and str(row.get("id", "")) == shipment_id:
			return str(row.get("status", ""))
	return ""


func _trades_with(dump: Dictionary, buyer: String, seller: String) -> int:
	var count: int = 0
	for row: Variant in dump.get("trades", []):
		if row is Dictionary and str(row.get("buy_owner", "")) == buyer \
				and str(row.get("sell_owner", "")) == seller:
			count += 1
	return count


func _loan(dump: Dictionary, loan_id: String) -> Dictionary:
	for row: Variant in dump.get("loans", []):
		if row is Dictionary and str(row.get("id", "")) == loan_id:
			return row as Dictionary
	return {}


func _loan_status(dump: Dictionary, loan_id: String) -> String:
	return str(_loan(dump, loan_id).get("status", ""))


func _loan_owner(dump: Dictionary, loan_id: String) -> String:
	return str(_loan(dump, loan_id).get("borrower", ""))


func _bag(dump: Dictionary, player: String, crop: String) -> int:
	var bags: Variant = dump.get("bags", {})
	if not bags is Dictionary:
		return -1
	var bag: Variant = (bags as Dictionary).get(player, null)
	return int((bag as Dictionary).get(crop, 0)) if bag is Dictionary else 0


## A stable fingerprint of everything an economy command could change, so a
## refused command can be proved to have changed nothing.
func _same_economy(before: Dictionary, after: Dictionary) -> bool:
	return _economy_fingerprint(before) == _economy_fingerprint(after)


func _economy_fingerprint(dump: Dictionary) -> String:
	return JSON.stringify({
		"accounts": dump.get("accounts", {}),
		"issued": int(dump.get("issued", -1)),
		"total_cash": int(dump.get("total_cash", -1)),
		"orders": dump.get("orders", []),
		"trades": dump.get("trades", []),
		"shipments": dump.get("shipments", []),
		"deliveries": dump.get("deliveries", []),
		"loans": dump.get("loans", []),
		"bank": dump.get("bank", {}),
		"merchant": dump.get("merchant", {}),
	})


func _accounts_key(accounts: Dictionary) -> String:
	var owners: Array = accounts.keys()
	owners.sort()
	var rows: Array = []
	for owner: Variant in owners:
		var account: Variant = accounts[owner]
		if account is Dictionary:
			rows.append([str(owner), int(account.get("cash", 0)), bool(account.get("granted", false)),
				int(account.get("pay_seq", 0))])
	return JSON.stringify(rows)


func _loans_key(loans: Variant) -> String:
	var source: Array = []
	if loans is Array:
		source = loans
	elif loans is Dictionary:
		for loan_id: Variant in loans:
			var row: Variant = loans[loan_id]
			if row is Dictionary:
				source.append(row)
	var rows: Array = []
	for value: Variant in source:
		if not value is Dictionary:
			continue
		var row: Dictionary = value
		# JSON round-trips whole numbers as floats while a restored snapshot
		# holds ints; normalize every field before comparing.
		rows.append([
			str(row.get("id", "")), str(row.get("borrower", "")),
			int(row.get("principal", 0)), int(row.get("fee", 0)), int(row.get("term", 0)),
			float(row.get("due_utc", 0.0)), float(row.get("opened_utc", 0.0)),
			str(row.get("status", "")), int(row.get("paid", 0)),
			float(row.get("repaid_utc", 0.0)), str(row.get("repay_id", "")),
		])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return str(a[0]) < str(b[0]))
	return JSON.stringify(rows)


func _orders_key(orders: Variant) -> String:
	var source: Array = orders if orders is Array else []
	var rows: Array = []
	for value: Variant in source:
		if not value is Dictionary:
			continue
		var row: Dictionary = value
		rows.append([
			str(row.get("id", "")), str(row.get("owner", "")), str(row.get("side", "")),
			str(row.get("good", "")), int(row.get("price", 0)), int(row.get("quantity", 0)),
			int(row.get("remaining", 0)), int(row.get("filled", 0)), int(row.get("reserved", 0)),
			int(row.get("sequence", 0)), float(row.get("created_utc", 0.0)),
			float(row.get("expires_utc", 0.0)), str(row.get("status", "")),
			int(row.get("released", 0)), str(row.get("closed_by", "")),
			float(row.get("closed_utc", 0.0)),
		])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return str(a[0]) < str(b[0]))
	return JSON.stringify(rows)


func _dump() -> Dictionary:
	DirAccess.remove_absolute(dir.path_join("state.json"))
	_write(dir.path_join("dump"), "dump")
	if not await _wait_file(dir.path_join("state.json"), 20000):
		return {}
	var parsed: Dictionary = _read_json(dir.path_join("state.json"))
	DirAccess.remove_absolute(dir.path_join("state.json"))
	return parsed


func _advance(target: float) -> Dictionary:
	DirAccess.remove_absolute(dir.path_join("advance.done"))
	_write(dir.path_join("advance"), str(target))
	if not await _wait_file(dir.path_join("advance.done"), 30000):
		return {}
	var parsed: Dictionary = _read_json(dir.path_join("advance.done"))
	DirAccess.remove_absolute(dir.path_join("advance.done"))
	return parsed


func _evict(farm_only: bool = false) -> Dictionary:
	DirAccess.remove_absolute(dir.path_join("evict.done"))
	DirAccess.remove_absolute(dir.path_join("evict.farm-only"))
	if farm_only:
		# Clear only the farm transaction window; the economy window keeps the
		# accepted pay result, so a retry reaches the inner duplicate path.
		_write(dir.path_join("evict.farm-only"), "1")
	_write(dir.path_join("evict"), "evict")
	if not await _wait_file(dir.path_join("evict.done"), 20000):
		return {}
	var parsed: Dictionary = _read_json(dir.path_join("evict.done"))
	DirAccess.remove_absolute(dir.path_join("evict.done"))
	return parsed


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _args_for(child_role: String) -> PackedStringArray:
	var args := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join("tests/m4_economy_commands_test.gd"),
		"--", "--role=" + child_role, "--dir=" + dir, "--port=%d" % port,
		"--url=wss://127.0.0.1:%d" % port, "--world=" + WORLD,
	])
	return args


func _exe() -> String:
	return OS.get_executable_path()


func _free_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0, "127.0.0.1") != OK:
		return 0
	var chosen: int = probe.get_local_port()
	probe.stop()
	return chosen


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("M4_ECONOMY_COMMANDS_TEST checks=%d failures=%d dir=%s" % [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)


func _wait_file(path: String, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(path):
			return true
		await create_timer(0.05).timeout
	return FileAccess.file_exists(path)


func _wait_process(pid: int, timeout_ms: int) -> void:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline and OS.is_process_running(pid):
		await create_timer(0.05).timeout


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
