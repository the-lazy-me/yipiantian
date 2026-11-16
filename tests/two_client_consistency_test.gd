extends SceneTree
## M13-01 two-client consistency over the real wire.
##
## One real `world_server.gd` serves a real world over loopback WSS. Two named
## members and one named visitor each run in their own Godot process with one
## real `WorldClient`; a parent process orchestrates them through files. The
## clients cannot share a process because `WorldClient` mounts its session node
## at the fixed RPC path `/root/WorldSession` and `SceneMultiplayer` is one peer
## per SceneTree, so "two clients online at once" means two client processes.
##
## Covered here:
##  1. A's account opening commits and the authority broadcasts a fresh summary;
##     B, which sent no refresh request, applies it and later refreshes to the
##     same authoritative sequence and economic view.
##  2. A and B submit the *same* market order id from the same basis. Exactly one
##     commits; the other gets the authority's named `command_conflict` duplicate
##     refusal. One order row, one escrow ledger entry and the exact cash split
##     prove no double spend.
##  3. Both clients refresh alternately; observed sequences and the public
##     summary facts stay monotonic and agree. A commit is not delivered twice
##     to B (no duplicate `change` sequence).
##  4. After a graceful stop and restart on the same port, both clients reconnect
##     to the same economic state, and the winner's committed command replays as
##     `duplicate` without a second settlement.
##  5. A visitor races for the same order id; its write is refused (named
##     refusal) and moves neither member's cash, order nor ledger.
##
## Everything runs under .local/verification/two-client-consistency-<ticks>/.
## Roles: --role=client --name=a|b|v. The parent orchestrates.

const WorldClient = preload("res://world/world_client.gd")
const WorldJoinCode = preload("res://world/world_join_code.gd")
const WorldInvite = preload("res://world/world_invite.gd")
const FarmCommand = preload("res://farm/farm_command.gd")
const FarmState = preload("res://farm/farm_state.gd")

const SERVER_SCRIPT: String = "Game/world/world_server.gd"
const START: float = 1800000000.0
const WORLD: String = "world-two-client-consistency"
## Server-side identity and local installation credential are distinct: the
## credential stays local and only its per-world proof crosses the wire.
const PLAYER_A: String = "player_00000000000000000000000000000201"
const PLAYER_B: String = "player_00000000000000000000000000000202"
const PLAYER_V: String = "player_00000000000000000000000000000203"
const NAME_A: String = "并发甲"
const NAME_B: String = "并发乙"
const NAME_V: String = "旁听者"
const SECRET_SUFFIX_A: String = "12"
const SECRET_SUFFIX_B: String = "23"
const SECRET_SUFFIX_V: String = "34"
const OPENING_GRANT: int = 120
const A_ACCOUNT_ID: String = "two-client-account-a"
const B_ACCOUNT_ID: String = "two-client-account-b"
## The one durable entity both members race to create.
const RACE_ORDER: String = "two-client-race-order"
const RACE_PRICE: int = 30
const RACE_QTY: int = 2
const RACE_COST: int = 60
## A long lifetime keeps the order out of the restart's economy sweep; the
## restart itself only has to prove the committed command and economic state.
const RACE_LIFETIME: float = 86400.0
const VISITOR_FOLLOW_UP: String = "two-client-visitor-follow-up"
const NAMES: Array[String] = ["a", "b", "v"]

var role: String = "parent"
var client_name: String = ""
var dir: String = ""
var world_dir: String = ""
var port: int = 0
var url: String = ""
var server_pid: int = 0
var log_path: String = ""
var checks: int = 0
var failures: Array[String] = []
var _command_counter: int = 0

# ---------------------------------------------------------------- client side
var client: WorldClient
var _ready_count: int = 0
var _ready_sequences: Array = []
var _changed_sequences: Array = []
var _reconnect_sequences: Array = []
var _reconnected_count: int = 0
var _refusals: Array[String] = []
var _lost: Array[String] = []
var _summary_refusals: Array[String] = []
var _commands: Dictionary = {}
var _steps: Array = []
var _last_command: String = ""
var _race_command: Dictionary = {}


func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			role = argument.trim_prefix("--role=")
		elif argument.begins_with("--name="):
			client_name = argument.trim_prefix("--name=")
		elif argument.begins_with("--dir="):
			dir = argument.trim_prefix("--dir=")
	_run.call_deferred()


func _run() -> void:
	if role == "client":
		await _run_client()
		return
	await _run_parent()


# ------------------------------------------------------------------- parent

func _run_parent() -> void:
	dir = _repo().path_join(
		".local/verification/two-client-consistency-%d" % Time.get_ticks_usec())
	world_dir = dir.path_join("world")
	DirAccess.make_dir_recursive_absolute(world_dir)
	root.size = Vector2i(1280, 720)

	if not await _start_authority(START):
		_finish()
		return
	var codes: Dictionary = _join_codes()
	_expect(not str(codes.get("member", "")).is_empty()
			and not str(codes.get("visitor", "")).is_empty(),
		"Member and visitor join codes are built from the operator's material")
	if str(codes.get("member", "")).is_empty() or str(codes.get("visitor", "")).is_empty():
		await _stop_server()
		_finish()
		return
	_write_json(dir.path_join("config.json"), {
		"url": url, "world": WORLD,
		"member_code": str(codes.get("member", "")),
		"visitor_code": str(codes.get("visitor", "")),
	})
	for name: String in NAMES:
		_spawn_client(name)

	if not await _phase_join():
		await _stop_clients()
		await _stop_server()
		_finish()
		return
	await _phase_broadcast()
	var winner: String = await _phase_race()
	if winner.is_empty():
		await _stop_clients()
		await _stop_server()
		_finish()
		return
	await _phase_interleaved_refresh()
	if not await _phase_restart(winner):
		await _stop_clients()
		_finish()
		return
	await _phase_visitor_follow_up()

	await _stop_clients()
	await _stop_server()
	_finish()


func _phase_join() -> bool:
	var ok: bool = true
	for name: String in NAMES:
		var ready: Dictionary = await _wait_json(_ready_path(name), 30000)
		_expect(not ready.is_empty(), "Client %s reports that it is ready" % name)
		if ready.is_empty():
			ok = false
			continue
		_expect(bool(ready.get("joined", false)),
			"Client %s joins over WSS (refusals=%s)"
				% [name, str(ready.get("refusals", []))])
		if not bool(ready.get("joined", false)):
			ok = false
			continue
		_expect(str(ready.get("role", ""))
				== (WorldInvite.VISITOR if name == "v" else WorldInvite.MEMBER),
			"Client %s joined with the role its code confers" % name)
		_expect(int(ready.get("sequence", -1)) == 0,
			"Client %s starts at the empty authority sequence" % name)
	return ok


func _phase_broadcast() -> void:
	var b_before: Dictionary = _status_outcome(
		await _client_cmd("b", "status"))
	_expect(not b_before.is_empty(), "B reports its state before A commits")
	_expect(int(b_before.get("state_ready", -1)) >= 1,
		"B already applied its own join summary")
	var b_baseline: int = int(b_before.get("state_ready", 0))

	var a_account: Dictionary = _reply_outcome(
		await _client_cmd("a", "account", {"command_id": A_ACCOUNT_ID}))
	_expect(bool(a_account.get("ok", false))
			and not bool(a_account.get("duplicate", true)),
		"A opens the first real cash account (%s)"
			% str(a_account.get("reason", "")))
	var a_sequence: int = int(a_account.get("sequence", -1))
	_expect(a_sequence == 1, "A's account is the first committed event")

	# B never asked for a summary after joining: the only way its counter can
	# move now is the authority's broadcast of A's commit.
	var b_after: Dictionary = _status_outcome(
		await _wait_client("b", func(status: Dictionary) -> bool:
			return int(status.get("state_ready", 0)) > b_baseline, 15000))
	_expect(not b_after.is_empty(), "B receives the broadcast without refreshing")
	_expect(int(b_after.get("state_ready", 0)) == b_baseline + 1,
		"A's commit reaches B as exactly one broadcast summary")
	_expect(int(b_after.get("sequence", -1)) == a_sequence,
		"B's broadcast view is at A's authoritative sequence")
	_expect((b_after.get("changed_sequences", []) as Array).is_empty(),
		"A's economy commit is not replayed to B as a second change delivery")

	var b_refresh: Dictionary = _status_outcome(await _client_cmd("b", "refresh"))
	_expect(bool(b_refresh.get("refreshed", false)),
		"B's explicit refresh receives an authoritative summary")
	_expect(int(b_refresh.get("sequence", -1)) == a_sequence,
		"B's refresh shows the same sequence as the broadcast")
	var b_facts: Dictionary = b_refresh.get("summary", {}) as Dictionary
	_expect(int(b_facts.get("committed_sequence", -1)) == a_sequence,
		"B's refreshed summary carries the same committed sequence")

	var b_account: Dictionary = _reply_outcome(
		await _client_cmd("b", "account", {"command_id": B_ACCOUNT_ID}))
	_expect(bool(b_account.get("ok", false))
			and not bool(b_account.get("duplicate", true)),
		"B opens the second real cash account (%s)"
			% str(b_account.get("reason", "")))
	_expect(int(b_account.get("sequence", -1)) == a_sequence + 1,
		"B's account is the second committed event")

	var measured: Dictionary = _measure("after both accounts")
	_expect(int(measured.get("a", -1)) == OPENING_GRANT
			and int(measured.get("b", -1)) == OPENING_GRANT,
		"Both members hold exactly the one-time opening grant")
	_expect(int(measured.get("issued", -1)) == 2 * OPENING_GRANT
			and int(measured.get("total", -1)) == int(measured.get("issued", -2)),
		"Two grants are issued and total cash still equals issued")
	_expect(bool(measured.get("reconcile_ok", false)),
		"The ledger reconciles after both accounts")


func _phase_race() -> String:
	var before: Dictionary = _measure("before the concurrent order")
	_expect((before.get("orders", []) as Array).is_empty(),
		"No market order exists before the race")
	var ids: Dictionary = {}
	for name: String in NAMES:
		ids[name] = _send_cmd(name, "race", {
			"order_id": RACE_ORDER, "side": "buy", "good": "greens",
			"price": RACE_PRICE, "quantity": RACE_QTY,
			"go": dir.path_join("race.go"),
		})
	for name: String in NAMES:
		_expect(await _wait_file(_armed_path(name), 15000),
			"Client %s is armed and waiting on the shared go signal" % name)
	_write_text(dir.path_join("race.go"), "go")

	var reports: Dictionary = {}
	for name: String in NAMES:
		reports[name] = await _await_cmd(name, str(ids[name]), 30000)
	var replies: Dictionary = {}
	for name: String in NAMES:
		replies[name] = _reply_outcome(reports[name])
		_expect(not replies[name].is_empty(),
			"Client %s receives a reply to its concurrent order" % name)

	var winner: String = ""
	var loser: String = ""
	for name: String in ["a", "b"]:
		var reply: Dictionary = replies[name]
		if bool(reply.get("ok", false)) and not bool(reply.get("duplicate", true)):
			_expect(winner.is_empty(), "Only one member commits the shared order")
			winner = name
		elif not bool(reply.get("ok", true)) and bool(reply.get("duplicate", false)) \
				and str(reply.get("reason", "")) == "command_conflict":
			loser = name
			_expect(not str(reply.get("reason_text", "")).is_empty(),
				"The losing member gets the authority's named refusal text")
	_expect(not winner.is_empty() and not loser.is_empty() and winner != loser,
		"One member succeeds and the other gets a duplicate refusal")

	var visitor_reply: Dictionary = replies["v"]
	_expect(not bool(visitor_reply.get("ok", true))
			and str(visitor_reply.get("reason", "")) in ["forbidden", "stale_precondition"],
		"The visitor's concurrent order is refused (%s)"
			% str(visitor_reply.get("reason", "")))

	var after: Dictionary = _measure("after the concurrent order")
	var race_rows: Array = _orders_with(after.get("orders", []) as Array, RACE_ORDER)
	_expect(race_rows.size() == 1,
		"Exactly one order row exists for the raced order id")
	if race_rows.size() == 1:
		var row: Dictionary = race_rows[0]
		var winner_player: String = _player_for(winner)
		var loser_player: String = _player_for(loser)
		_expect(str(row.get("owner", "")) == winner_player,
			"The surviving order belongs to the commit that won")
		_expect(str(row.get("status", "")) == "open"
				and int(row.get("quantity", -1)) == RACE_QTY
				and int(row.get("remaining", -1)) == RACE_QTY
				and int(row.get("reserved", -1)) == RACE_COST,
			"The surviving order has exactly one order's quantity and escrow")
		_expect(int(after.get("a", -1))
					== (OPENING_GRANT - RACE_COST if winner == "a" else OPENING_GRANT)
				and int(after.get("b", -1))
					== (OPENING_GRANT - RACE_COST if winner == "b" else OPENING_GRANT),
			"Only the winner's cash is escrowed; the loser's balance is untouched")
		_expect(int(after.get("winner_cash", -1)) == OPENING_GRANT - RACE_COST
				and int(_named_cash(after, winner_player)) == OPENING_GRANT - RACE_COST
				and int(_named_cash(after, loser_player)) == OPENING_GRANT,
			"Winner and loser balances match a single escrow")
	_expect(int(after.get("issued", -1)) == 2 * OPENING_GRANT,
		"The raced order issues no new cash")
	_expect(int(after.get("total", -1)) == int(after.get("issued", -2)),
		"Escrow conserves total cash and assets")
	_expect(bool(after.get("reconcile_ok", false)),
		"The ledger reconciles after the raced order")
	var escrow_entries: int = _entry_count(
		after.get("entries", []) as Array, RACE_ORDER)
	_expect(escrow_entries == 1,
		"Exactly one escrow ledger entry exists for the raced order")
	var escrow: Dictionary = _entry(
		after.get("entries", []) as Array, RACE_ORDER)
	_expect(str(escrow.get("kind", "")) == "escrow_hold"
			and int(escrow.get("debit", 0)) == RACE_COST
			and int(escrow.get("credit", 0)) == RACE_COST,
		"The single escrow entry is balanced")
	_expect(int(after.get("sequence", -1))
			== int(replies[winner].get("sequence", -2)),
		"The winner's reply names the authority's committed sequence")
	_expect(not bool(after.get("v_granted", true))
			and int(after.get("v", -1)) == 0,
		"The visitor holds no account after its refused order")
	return winner


func _phase_interleaved_refresh() -> void:
	var last_a: int = -1
	var last_b: int = -1
	var a_status: Dictionary = {}
	var b_status: Dictionary = {}
	for round_index: int in 2:
		var a_before: int = int(a_status.get("state_ready", 0))
		a_status = _status_outcome(await _client_cmd("a", "refresh"))
		_expect(bool(a_status.get("refreshed", false)),
			"A's interleaved refresh %d receives a summary" % (round_index + 1))
		var a_sequence: int = int(a_status.get("sequence", -1))
		_expect(a_sequence >= last_a,
			"A's refreshed sequence never moves backwards")
		_expect(int(a_status.get("state_ready", 0)) > a_before,
			"A's refresh applies one newer summary")
		last_a = a_sequence

		var b_before: int = int(b_status.get("state_ready", 0))
		b_status = _status_outcome(await _client_cmd("b", "refresh"))
		_expect(bool(b_status.get("refreshed", false)),
			"B's interleaved refresh %d receives a summary" % (round_index + 1))
		var b_sequence: int = int(b_status.get("sequence", -1))
		_expect(b_sequence >= last_b,
			"B's refreshed sequence never moves backwards")
		_expect(int(b_status.get("state_ready", 0)) > b_before,
			"B's refresh applies one newer summary")
		last_b = b_sequence

		_expect(a_sequence == b_sequence,
			"Both clients agree on the sequence for refresh round %d"
				% (round_index + 1))
		_expect(_facts_agree(a_status, b_status),
			"Both clients agree on the public summary facts for round %d"
				% (round_index + 1))

	var measured: Dictionary = _measure("after interleaved refreshes")
	_expect(int(measured.get("sequence", -1)) == last_a
			and int(measured.get("sequence", -1)) == last_b,
		"Both clients match the authority's committed sequence")
	_expect(_facts_match_authority(a_status, measured)
			and _facts_match_authority(b_status, measured),
		"Both clients' market views match the authority's orders")
	_expect(_unique(a_status.get("changed_sequences", []) as Array),
		"A saw no duplicate change delivery")
	_expect(_unique(b_status.get("changed_sequences", []) as Array),
		"B saw no duplicate change delivery")
	_expect(_non_decreasing(a_status.get("ready_sequences", []) as Array)
			and _non_decreasing(b_status.get("ready_sequences", []) as Array),
		"Both clients' observed summary sequences are monotonic")


func _phase_restart(winner: String) -> bool:
	var before_stop: Dictionary = _measure("before restart")
	var a_pre: Dictionary = _status_outcome(await _client_cmd("a", "status"))
	var b_pre: Dictionary = _status_outcome(await _client_cmd("b", "status"))
	_expect(int(a_pre.get("sequence", -1)) == int(before_stop.get("sequence", -2))
			and int(b_pre.get("sequence", -1)) == int(before_stop.get("sequence", -2)),
		"Both clients are at the authority sequence before the restart")
	var a_ready_before: int = int(a_pre.get("state_ready", 0))
	var b_ready_before: int = int(b_pre.get("state_ready", 0))

	await _stop_server()
	# Move the logical clock forward so the restarted session never runs with a
	# lower clock than the saved world. The order lifetime is far beyond this.
	var restart_now: float = float(
		(a_pre.get("summary", {}) as Dictionary).get("now_utc", START)) + 60.0
	if restart_now <= START:
		restart_now = START + 300.0
	if not await _start_authority(restart_now):
		_finish()
		return false

	var a_rec: Dictionary = _status_outcome(
		await _wait_client("a", func(status: Dictionary) -> bool:
			return (int(status.get("reconnected", 0)) >= 1
				and bool(status.get("joined", false))), 40000))
	var b_rec: Dictionary = _status_outcome(
		await _wait_client("b", func(status: Dictionary) -> bool:
			return (int(status.get("reconnected", 0)) >= 1
				and bool(status.get("joined", false))), 40000))
	var v_rec: Dictionary = _status_outcome(
		await _wait_client("v", func(status: Dictionary) -> bool:
			return (int(status.get("reconnected", 0)) >= 1
				and bool(status.get("joined", false))), 40000))
	_expect(not a_rec.is_empty() and int(a_rec.get("reconnected", 0)) >= 1,
		"A reconnects to the restarted authority")
	_expect(not b_rec.is_empty() and int(b_rec.get("reconnected", 0)) >= 1,
		"B reconnects to the restarted authority")
	_expect(not v_rec.is_empty() and int(v_rec.get("reconnected", 0)) >= 1,
		"The visitor reconnects to the restarted authority")
	_expect(int(a_rec.get("state_ready", 0)) > a_ready_before
			and int(b_rec.get("state_ready", 0)) > b_ready_before,
		"Both reconnect summaries are applied after the restart")

	var after_restart: Dictionary = _measure("after restart")
	_expect(_same_economy(before_stop, after_restart),
		"Cash, issued total, order, ledger and sequence survive the restart")
	_expect(int(a_rec.get("sequence", -1)) == int(before_stop.get("sequence", -2))
			and int(b_rec.get("sequence", -1)) == int(before_stop.get("sequence", -2)),
		"Both clients show the pre-restart sequence after reconnecting")
	_expect(_facts_match_authority(a_rec, after_restart)
			and _facts_match_authority(b_rec, after_restart),
		"Both clients show the same surviving order after reconnecting")
	_expect((after_restart.get("orders", []) as Array).size()
			== (before_stop.get("orders", []) as Array).size(),
		"The restart adds no order row")

	var bytes_before_replay: PackedByteArray = _bytes(_farm_path())
	var sequence_before_replay: int = int(after_restart.get("sequence", -1))
	var replay: Dictionary = _reply_outcome(await _client_cmd(winner, "replay"))
	_expect(bool(replay.get("ok", false)) and bool(replay.get("duplicate", false)),
		"The winner's committed order replays as duplicate after the restart ")
	_expect(str(replay.get("reason", "")) == "",
		"A duplicate replay reports the original success, not a settlement failure")
	var after_replay: Dictionary = _measure("after restart replay")
	_expect(int(after_replay.get("sequence", -1)) == sequence_before_replay,
		"The replay commits no new event")
	_expect(_same_economy(after_restart, after_replay),
		"The replay moves no cash, order or ledger entry")
	_expect(_entry_count(after_replay.get("entries", []) as Array, RACE_ORDER) == 1,
		"The replay adds no second escrow entry")
	_expect(_orders_with(after_replay.get("orders", []) as Array, RACE_ORDER).size() == 1,
		"The replay adds no second order row")
	_expect(_bytes(_farm_path()) == bytes_before_replay,
		"The replayed duplicate leaves farm.json byte-identical")
	return true


func _phase_visitor_follow_up() -> void:
	var v_status: Dictionary = _status_outcome(await _client_cmd("v", "refresh"))
	_expect(bool(v_status.get("refreshed", false)),
		"The visitor refreshes to the current authority view")
	var before_bytes: PackedByteArray = _bytes(_farm_path())
	var before: Dictionary = _measure("before visitor follow-up")
	var refused: Dictionary = _reply_outcome(
		await _client_cmd("v", "order", {"order_id": VISITOR_FOLLOW_UP}))
	_expect(not bool(refused.get("ok", true))
			and str(refused.get("reason", "")) == "forbidden",
		"A visitor with a fresh basis is refused as forbidden")
	_expect(not str(refused.get("reason_text", "")).is_empty(),
		"The visitor's refusal carries the authority's reason text")
	var after: Dictionary = _measure("after visitor follow-up")
	_expect(_same_economy(before, after),
		"The visitor's refused order moves neither member's state")
	_expect(_bytes(_farm_path()) == before_bytes,
		"The visitor's refused order writes no authority document")
	_expect(_orders_with(after.get("orders", []) as Array, VISITOR_FOLLOW_UP).is_empty()
			and _entry_count(after.get("entries", []) as Array, VISITOR_FOLLOW_UP) == 0,
		"The refused visitor order leaves no order or ledger row")
	_expect(int(after.get("v", -1)) == 0 and not bool(after.get("v_granted", true)),
		"The visitor still owns no account or grant")


# ------------------------------------------------------------- client plumbing

func _run_client() -> void:
	var config: Dictionary = _read_json(dir.path_join("config.json"))
	var name: String = client_name
	var code: String = str(config.get("visitor_code", "")) if name == "v" \
		else str(config.get("member_code", ""))
	client = WorldClient.new()
	client.name = "WorldClient"
	root.add_child(client)
	client.state_ready.connect(func(_farm: RefCounted, _decorations: RefCounted,
			_now: float) -> void:
		_ready_count += 1
		_ready_sequences.append(int(client.member.last_sequence)))
	client.changed.connect(func(entry: Dictionary) -> void:
		_changed_sequences.append(int(entry.get("sequence", 0))))
	client.committed.connect(func(request_id: String, payload: Dictionary) -> void:
		_commands[request_id] = payload.duplicate(true))
	client.refused.connect(func(reason: String) -> void: _refusals.append(reason))
	client.lost.connect(func(reason: String) -> void: _lost.append(reason))
	client.reconnected.connect(func(sequence: int) -> void:
		_reconnected_count += 1
		_reconnect_sequences.append(sequence))
	client.summary_refused.connect(func(reason: String) -> void:
		_summary_refusals.append(reason))

	var started: bool = client.start(code, _player_for(name), _display_for(name),
		_secret_for(name))
	if started:
		await _wait(func() -> bool:
			return (client.joined and _ready_count > 0) or not _refusals.is_empty(), 25000)
	_write_ready(client.joined and _ready_count > 0)

	while true:
		var command: Dictionary = _read_json(_cmd_path(name))
		if command.is_empty():
			await create_timer(0.03).timeout
			continue
		DirAccess.remove_absolute(_cmd_path(name))
		var request_id: String = str(command.get("id", ""))
		var action: String = str(command.get("action", ""))
		if action == "stop":
			_last_command = request_id
			_write_report()
			break
		var outcome: Dictionary = await _perform(action, command)
		_steps.append({"command": request_id, "action": action, "outcome": outcome})
		_last_command = request_id
		_write_report()
	client.close()
	quit(0)


func _perform(action: String, command: Dictionary) -> Dictionary:
	if action == "status":
		return {"status": _compact()}
	if client == null:
		return {"error": "no_client", "reply": {"ok": false, "reason": "not_joined"}}
	match action:
		"account":
			return {"reply": await _submit(FarmCommand.make_account_open(
				str(command.get("command_id", "")), client.world_time()))}
		"order":
			return {"reply": await _submit(FarmCommand.make_market_place(
				str(command.get("order_id", "")), "buy", "greens", RACE_PRICE,
				RACE_QTY, client.world_time() + RACE_LIFETIME, client.world_time()))}
		"race":
			var now: float = client.world_time()
			_race_command = FarmCommand.make_market_place(
				str(command.get("order_id", RACE_ORDER)),
				str(command.get("side", "buy")), str(command.get("good", "greens")),
				int(command.get("price", RACE_PRICE)),
				int(command.get("quantity", RACE_QTY)),
				now + RACE_LIFETIME, now)
			_write_text(_armed_path(client_name), "armed")
			var go_path: String = str(command.get("go", ""))
			var deadline: int = Time.get_ticks_msec() + 60000
			while Time.get_ticks_msec() < deadline and not FileAccess.file_exists(go_path):
				await create_timer(0.02).timeout
			return {"reply": await _submit(_race_command)}
		"replay":
			if _race_command.is_empty():
				return {"reply": {"ok": false, "reason": "no_race_command"}}
			return {"reply": await _submit(_race_command)}
		"refresh":
			var before: int = _ready_count
			if not client.joined:
				return {"status": _compact(), "refreshed": false}
			client.request_summary()
			var deadline: int = Time.get_ticks_msec() + 15000
			while Time.get_ticks_msec() < deadline and _ready_count <= before \
					and _summary_refusals.is_empty():
				await create_timer(0.02).timeout
			return {"status": _compact(), "refreshed": _ready_count > before}
	return {"error": "unknown_action"}


func _submit(command: Dictionary) -> Dictionary:
	var request_id: String = str(command.get("id", ""))
	_commands.erase(request_id)
	if client == null or not client.submit(command):
		return {"ok": false, "reason": "not_sent"}
	var deadline: int = Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline and not _commands.has(request_id):
		await create_timer(0.02).timeout
	var stored: Variant = _commands.get(request_id, {})
	return (stored as Dictionary).duplicate(true) if stored is Dictionary else {}


func _compact() -> Dictionary:
	var result: Dictionary = {
		"joined": false,
		"state_ready": _ready_count,
		"reconnected": _reconnected_count,
		"reconnect_sequences": _reconnect_sequences.duplicate(),
		"ready_sequences": _ready_sequences.duplicate(),
		"changed_sequences": _changed_sequences.duplicate(),
		"refusals": _refusals.duplicate(),
		"lost": _lost.duplicate(),
		"summary_refusals": _summary_refusals.duplicate(),
		"summary": {},
	}
	if client == null or client.member == null:
		return result
	result["joined"] = client.joined
	result["role"] = str(client.member.role)
	result["sequence"] = int(client.member.last_sequence)
	result["summary"] = _summary_facts(client.member)
	return result


func _summary_facts(member) -> Dictionary:
	var state: Dictionary = member.state if member.state is Dictionary else {}
	var snapshot: Dictionary = member.snapshot if member.snapshot is Dictionary else {}
	var orders: Dictionary = {}
	var farm_value: Variant = snapshot.get("farm")
	if farm_value is Dictionary:
		var economy_value: Variant = (farm_value as Dictionary).get("economy")
		if economy_value is Dictionary:
			var market_value: Variant = (economy_value as Dictionary).get("market")
			if market_value is Dictionary:
				var orders_value: Variant = (market_value as Dictionary).get("orders")
				if orders_value is Dictionary:
					for order_id: Variant in orders_value:
						var row: Variant = (orders_value as Dictionary)[order_id]
						if row is Dictionary:
							orders[str(order_id)] = {
								"status": str((row as Dictionary).get("status", "")),
								"price": int((row as Dictionary).get("price", 0)),
								"quantity": int((row as Dictionary).get("quantity", 0)),
								"remaining": int((row as Dictionary).get("remaining", 0)),
								"reserved": int((row as Dictionary).get("reserved", 0)),
							}
	return {
		"sequence": int(state.get("sequence", -1)),
		"committed_sequence": int(state.get("committed_sequence", -1)),
		"committed_commands": int(state.get("committed_commands", -1)),
		"world_id": str(state.get("world_id", "")),
		"run_generation": int(state.get("run_generation", -1)),
		"now_utc": float(state.get("now_utc", 0.0)),
		"orders": orders,
		"organizations": state.get("organizations", []),
		"funds": state.get("funds", []),
	}


func _write_ready(joined: bool) -> void:
	var payload: Dictionary = {
		"joined": joined,
		"state_ready": _ready_count,
		"refusals": _refusals.duplicate(),
	}
	if client != null and client.member != null:
		payload["role"] = str(client.member.role)
		payload["sequence"] = int(client.member.last_sequence)
	_write_json(_ready_path(client_name), payload)


func _write_report() -> void:
	_write_json(_report_path(client_name), {
		"name": client_name,
		"last_command": _last_command,
		"steps": _steps,
		"status": _compact(),
	})


# ------------------------------------------------------------ parent plumbing

func _spawn_client(name: String) -> void:
	var arguments := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join("tests/two_client_consistency_test.gd"), "--",
		"--role=client", "--name=" + name, "--dir=" + dir,
	])
	var pid: int = OS.create_process(OS.get_executable_path(), arguments, false)
	_expect(pid > 0, "Client %s process starts" % name)


func _send_cmd(name: String, action: String, extra: Dictionary = {}) -> String:
	_command_counter += 1
	var request_id: String = "cmd-%s-%d-%d" % [
		name, Time.get_ticks_usec(), _command_counter]
	var payload: Dictionary = extra.duplicate(true)
	payload["id"] = request_id
	payload["action"] = action
	_write_json(_cmd_path(name), payload)
	return request_id


func _await_cmd(name: String, request_id: String,
		timeout_ms: int = 20000) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var report: Dictionary = _read_json(_report_path(name))
		if str(report.get("last_command", "")) == request_id:
			return report
		await create_timer(0.03).timeout
	_expect(false, "Client %s completes command %s" % [name, request_id])
	return {}


func _client_cmd(name: String, action: String, extra: Dictionary = {},
		timeout_ms: int = 20000) -> Dictionary:
	return await _await_cmd(name, _send_cmd(name, action, extra), timeout_ms)


func _wait_client(name: String, predicate: Callable,
		timeout_ms: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var report: Dictionary = await _client_cmd(name, "status", {}, 10000)
		if report.is_empty():
			return {}
		var status: Dictionary = _status_outcome(report)
		if predicate.call(status):
			return report
		await create_timer(0.1).timeout
	_expect(false, "Client %s reaches the expected state" % name)
	return {}


func _stop_clients() -> void:
	for name: String in NAMES:
		if not FileAccess.file_exists(_report_path(name)) \
				and not FileAccess.file_exists(_ready_path(name)):
			continue
		var request_id: String = _send_cmd(name, "stop")
		await _await_cmd(name, request_id, 5000)


func _status_outcome(report: Dictionary) -> Dictionary:
	var outcome: Dictionary = _outcome(report)
	var status: Variant = outcome.get("status")
	if not status is Dictionary:
		return {}
	# A refresh action returns its `refreshed` flag next to the status snapshot;
	# keep it so callers can assert that the explicit request really was applied.
	var result: Dictionary = (status as Dictionary).duplicate(true)
	if outcome.has("refreshed"):
		result["refreshed"] = outcome["refreshed"]
	return result


func _reply_outcome(report: Dictionary) -> Dictionary:
	var outcome: Dictionary = _outcome(report)
	var reply: Variant = outcome.get("reply")
	return reply if reply is Dictionary else {}


func _outcome(report: Dictionary) -> Dictionary:
	var steps: Variant = report.get("steps")
	if not steps is Array or (steps as Array).is_empty():
		return {}
	var last: Variant = (steps as Array)[(steps as Array).size() - 1]
	if not last is Dictionary:
		return {}
	var value: Variant = (last as Dictionary).get("outcome")
	return value if value is Dictionary else {}


# ------------------------------------------------------------- authority docs

func _measure(label: String) -> Dictionary:
	var document: Dictionary = _farm_doc()
	var farm := FarmState.new()
	var restored: bool = not document.is_empty() and farm.restore_snapshot(document)
	_expect(restored, "The authoritative farm document restores (%s)" % label)
	if not restored:
		return {}
	var reconciled: Dictionary = farm.economy_reconcile()
	var orders: Array = []
	for value: Variant in farm.market_orders():
		if value is Dictionary:
			orders.append((value as Dictionary).duplicate(true))
	orders.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("id", "")) < str(b.get("id", "")))
	var result: Dictionary = {
		"a": farm.economy_cash(PLAYER_A),
		"b": farm.economy_cash(PLAYER_B),
		"v": farm.economy_cash(PLAYER_V),
		"a_granted": farm.economy_granted(PLAYER_A),
		"b_granted": farm.economy_granted(PLAYER_B),
		"v_granted": farm.economy_granted(PLAYER_V),
		"issued": farm.economy_issued(),
		"total": farm.economy_total_cash(),
		"sequence": farm.event_sequence(),
		"committed_commands": farm.committed_command_count(),
		"orders": orders,
		"entries": farm.economy_ledger_entries(),
		"reconcile_ok": bool(reconciled.get("ok", false)),
	}
	var winner: String = ""
	for row_value: Variant in orders:
		if row_value is Dictionary and str((row_value as Dictionary).get("id", "")) == RACE_ORDER:
			winner = str((row_value as Dictionary).get("owner", ""))
	result["race_winner"] = winner
	result["winner_cash"] = int(_named_cash(result, winner))
	return result


func _named_cash(measure: Dictionary, player_id: String) -> int:
	match player_id:
		PLAYER_A: return int(measure.get("a", -1))
		PLAYER_B: return int(measure.get("b", -1))
		PLAYER_V: return int(measure.get("v", -1))
	return -1


func _orders_with(orders: Array, order_id: String) -> Array:
	var rows: Array = []
	for value: Variant in orders:
		if value is Dictionary \
				and str((value as Dictionary).get("id", "")) == order_id:
			rows.append((value as Dictionary).duplicate(true))
	return rows


func _entry(entries: Array, event_id: String) -> Dictionary:
	for value: Variant in entries:
		if value is Dictionary \
				and str((value as Dictionary).get("event_id", "")) == event_id:
			return (value as Dictionary).duplicate(true)
	return {}


func _entry_count(entries: Array, event_id: String) -> int:
	var count: int = 0
	for value: Variant in entries:
		if value is Dictionary \
				and str((value as Dictionary).get("event_id", "")) == event_id:
			count += 1
	return count


## The concurrency-relevant authoritative state: balances, issued cash, order
## rows, ledger entries and the committed sequence. Growth-stage state is not
## compared because the restart deliberately moves the logical clock forward.
func _same_economy(left: Dictionary, right: Dictionary) -> bool:
	return (
		int(left.get("a", -1)) == int(right.get("a", -2))
		and int(left.get("b", -1)) == int(right.get("b", -2))
		and int(left.get("v", -1)) == int(right.get("v", -2))
		and bool(left.get("a_granted", false)) == bool(right.get("a_granted", true))
		and bool(left.get("b_granted", false)) == bool(right.get("b_granted", true))
		and bool(left.get("v_granted", false)) == bool(right.get("v_granted", true))
		and int(left.get("issued", -1)) == int(right.get("issued", -2))
		and int(left.get("total", -1)) == int(right.get("total", -2))
		and int(left.get("sequence", -1)) == int(right.get("sequence", -2))
		and int(left.get("committed_commands", -1))
			== int(right.get("committed_commands", -2))
		and _orders_key(left.get("orders", []) as Array)
			== _orders_key(right.get("orders", []) as Array)
		and _entry_ids(left.get("entries", []) as Array)
			== _entry_ids(right.get("entries", []) as Array)
		and bool(left.get("reconcile_ok", false))
		and bool(right.get("reconcile_ok", false)))


func _orders_key(orders: Array) -> String:
	var rows: Array = []
	for value: Variant in orders:
		if not value is Dictionary:
			continue
		var row: Dictionary = value
		rows.append([
			str(row.get("id", "")), str(row.get("owner", "")), str(row.get("side", "")),
			str(row.get("good", "")), int(row.get("price", 0)),
			int(row.get("quantity", 0)), int(row.get("remaining", 0)),
			int(row.get("reserved", 0)), str(row.get("status", "")),
		])
	return JSON.stringify(rows)


func _entry_ids(entries: Array) -> String:
	var rows: Array = []
	for value: Variant in entries:
		if value is Dictionary:
			rows.append(str((value as Dictionary).get("id", "")))
	rows.sort()
	return JSON.stringify(rows)


## Public summary facts shared by every viewer: sequence, committed counts, and
## the order rows with viewer-scoped ownership removed.
func _facts_agree(left: Dictionary, right: Dictionary) -> bool:
	var a: Dictionary = left.get("summary", {}) as Dictionary
	var b: Dictionary = right.get("summary", {}) as Dictionary
	return (
		int(a.get("committed_sequence", -1)) == int(b.get("committed_sequence", -2))
		and int(a.get("committed_commands", -1))
			== int(b.get("committed_commands", -2))
		and str(a.get("world_id", "")) == str(b.get("world_id", "#"))
		and JSON.stringify(a.get("orders", {})) == JSON.stringify(b.get("orders", {}))
		and JSON.stringify(a.get("organizations", []))
			== JSON.stringify(b.get("organizations", []))
		and JSON.stringify(a.get("funds", [])) == JSON.stringify(b.get("funds", [])))


func _facts_match_authority(status: Dictionary, measured: Dictionary) -> bool:
	var facts: Dictionary = status.get("summary", {}) as Dictionary
	var expected: Dictionary = {}
	for value: Variant in measured.get("orders", []) as Array:
		if not value is Dictionary:
			continue
		var row: Dictionary = value
		expected[str(row.get("id", ""))] = {
			"status": str(row.get("status", "")),
			"price": int(row.get("price", 0)),
			"quantity": int(row.get("quantity", 0)),
			"remaining": int(row.get("remaining", 0)),
			"reserved": int(row.get("reserved", 0)),
		}
	# The client facts travelled through JSON, so their numbers parse back as
	# floats. Normalise both sides to the same integer shape before comparing.
	var observed: Dictionary = {}
	var rows: Variant = facts.get("orders")
	if rows is Dictionary:
		for order_id: Variant in rows:
			var row: Variant = (rows as Dictionary)[order_id]
			if not row is Dictionary:
				continue
			observed[str(order_id)] = {
				"status": str((row as Dictionary).get("status", "")),
				"price": int((row as Dictionary).get("price", 0)),
				"quantity": int((row as Dictionary).get("quantity", 0)),
				"remaining": int((row as Dictionary).get("remaining", 0)),
				"reserved": int((row as Dictionary).get("reserved", 0)),
			}
	return (
		int(facts.get("sequence", -1)) == int(measured.get("sequence", -2))
		and int(facts.get("committed_commands", -1))
			== int(measured.get("committed_commands", -2))
		and JSON.stringify(observed) == JSON.stringify(expected))


func _unique(values: Array) -> bool:
	var seen: Dictionary = {}
	for value: Variant in values:
		var key: String = str(value)
		if seen.has(key):
			return false
		seen[key] = true
	return true


func _non_decreasing(values: Array) -> bool:
	var last: int = -1
	for value: Variant in values:
		var current: int = int(value)
		if current < last:
			return false
		last = current
	return true


# --------------------------------------------------------------- server/plumbing

func _start_authority(now: float) -> bool:
	if port <= 0:
		port = _free_port()
		_expect(port > 0, "A free loopback port is available for the authority")
		if port <= 0:
			return false
	url = "wss://127.0.0.1:%d" % port
	server_pid = _spawn_server(now)
	_expect(server_pid > 0, "The authority process starts")
	if server_pid <= 0:
		return false
	var running: bool = await _wait(func() -> bool:
		var status: Dictionary = _status()
		return str(status.get("state", "")) == "running" \
			and int(status.get("pid", 0)) == server_pid, 20000)
	_expect(running, "The authority reports ready")
	if not running:
		return false
	var status: Dictionary = _status()
	_expect(str(status.get("world_id", "")) == WORLD,
		"The status file names the world the authority serves")
	_expect(str(status.get("host_player", "")) == PLAYER_A,
		"The status file records the startup host")
	if OS.get_name() != "Windows":
		var ready: bool = await _wait(func() -> bool:
			return _read_text(log_path).contains("WORLD_SERVER_READY"), 3000)
		_expect(ready, "The authority log reports readiness")
		_expect(not _read_text(log_path).contains("SCRIPT ERROR"),
			"The authority log has no script error")
	return true


func _spawn_server(now: float) -> int:
	var arguments := PackedStringArray([
		"--headless", "--path", _repo().path_join("Game"),
		"--script", _repo().path_join(SERVER_SCRIPT), "--",
		"--data-dir=" + world_dir, "--port=%d" % port, "--world=" + WORLD,
		"--now-utc=%f" % now, "--run-seconds=0", "--join-url=" + url,
		"--host-player=" + PLAYER_A,
	])
	log_path = world_dir.path_join("server-%d.log" % Time.get_ticks_usec())
	if OS.get_name() == "Windows":
		return OS.create_process(OS.get_executable_path(), arguments, false)
	var pieces: PackedStringArray = [_shell_quote(OS.get_executable_path())]
	for argument: String in arguments:
		pieces.append(_shell_quote(argument))
	var command: String = "exec " + " ".join(pieces) + " > " \
		+ _shell_quote(log_path) + " 2>&1"
	return OS.create_process("/bin/sh", PackedStringArray(["-c", command]), false)


func _join_codes() -> Dictionary:
	var invite_bytes: PackedByteArray = FileAccess.get_file_as_bytes(
		world_dir.path_join("invite.bin"))
	var pem: String = FileAccess.get_file_as_bytes(
		world_dir.path_join("server.crt")).get_string_from_ascii()
	var member_code: String = WorldJoinCode.encode(WorldInvite.make(
		"server-invite", invite_bytes, WorldInvite.MEMBER, WORLD, 0.0, false),
		url, pem, "localhost")
	var visitor_code: String = FileAccess.get_file_as_string(
		world_dir.path_join("visitor-join-code.txt")).strip_edges()
	return {"member": member_code, "visitor": visitor_code}


func _stop_server() -> void:
	if server_pid <= 0:
		return
	var marker := FileAccess.open(world_dir.path_join("stop"), FileAccess.WRITE)
	if marker != null:
		marker.store_string("stop")
		marker.close()
	var deadline: int = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline and OS.is_process_running(server_pid):
		await create_timer(0.05).timeout
	var stopped: bool = not OS.is_process_running(server_pid)
	_expect(stopped, "The authority process shuts down cleanly")
	_expect(str(_status().get("state", "")) == "stopped",
		"The shutdown is recorded in the status file")
	if not stopped:
		OS.kill(server_pid)
	server_pid = 0


func _status() -> Dictionary:
	return _read_json(world_dir.path_join("server-status.json"))


func _farm_path() -> String:
	return world_dir.path_join("farm.json")


func _farm_doc() -> Dictionary:
	var saved: Dictionary = _read_json(_farm_path())
	var farm: Variant = saved.get("farm")
	return farm if farm is Dictionary else {}


# ------------------------------------------------------------------ helpers

func _player_for(name: String) -> String:
	match name:
		"a": return PLAYER_A
		"b": return PLAYER_B
		"v": return PLAYER_V
	return ""

func _display_for(name: String) -> String:
	match name:
		"a": return NAME_A
		"b": return NAME_B
		"v": return NAME_V
	return ""


func _secret_for(name: String) -> PackedByteArray:
	var suffix: String = SECRET_SUFFIX_A
	match name:
		"b": suffix = SECRET_SUFFIX_B
		"v": suffix = SECRET_SUFFIX_V
	return ("yipiantian-test-player-secret-" + suffix).to_utf8_buffer()


func _ready_path(name: String) -> String:
	return dir.path_join("client-%s.ready.json" % name)


func _report_path(name: String) -> String:
	return dir.path_join("client-%s.report.json" % name)


func _cmd_path(name: String) -> String:
	return dir.path_join("client-%s.cmd.json" % name)


func _armed_path(name: String) -> String:
	return dir.path_join("client-%s.armed" % name)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _write_json(path: String, payload: Dictionary) -> void:
	_write_text(path, JSON.stringify(payload))


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()


func _read_text(path: String) -> String:
	return FileAccess.get_file_as_string(path) \
		if FileAccess.file_exists(path) else ""


func _bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path) \
		if FileAccess.file_exists(path) else PackedByteArray()


func _wait(condition: Callable, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.05).timeout
	return bool(condition.call())


func _wait_file(path: String, timeout_ms: int) -> bool:
	return await _wait(func() -> bool: return FileAccess.file_exists(path),
		timeout_ms)


func _wait_json(path: String, timeout_ms: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var parsed: Dictionary = _read_json(path)
		if not parsed.is_empty():
			return parsed
		await create_timer(0.05).timeout
	return _read_json(path)


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


func _free_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0, "127.0.0.1") != OK:
		return 0
	var chosen: int = probe.get_local_port()
	probe.stop()
	return chosen


func _shell_quote(text: String) -> String:
	return "'" + text.replace("'", "'\\''") + "'"


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("TWO_CLIENT_CONSISTENCY_TEST checks=%d failures=%d dir=%s"
		% [checks, failures.size(), dir])
	quit(0 if failures.is_empty() else 1)
